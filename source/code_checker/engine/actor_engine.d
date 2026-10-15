/**
Typed-actor contracts for the engine's actor system.

This module holds the typed-actor message surface (the interfaces every actor
implements) and the data contracts (job and event payloads). Actor class
logic lives in the actor classes below.
*/
module code_checker.engine.actor_engine;

import core.time : dur;

import std.typecons : Tuple;
import std.variant : Variant;

import my.actor : RequestResult, WeakAddress;
import my.actor.msg : capture, delay;
import my.actor.channel : dynDelayedSend;
import my.actor.system : System;

import my.sumtype;

import code_checker.engine.types : Environment, MsgSeverity, Result;
import code_checker.engine.compile_db : toRange;
import code_checker.engine.builtin.clang_tidy : TidyResult, TidyWork;
import code_checker.engine.builtin.include_what_you_use : IwyuResult, IwyuWork;
import code_checker.utility : osAverageLoad;

/// Compile-time gate for the engine actors' `onUnhandledMessage` debug
/// logging: a test build (`dub test`) enables it via `version (unittest)`; a
/// debug build opts in with `ldc2 -d-version=CodeCheckerActorDebug` (dub's
/// DFLAGS route is toolchain-dependent: the pinned ldc2 rejects
/// `-version=X`). Module-local: it gates exactly this module's hooks.
version (unittest) version = CodeCheckerActorDebug;

/// The payload data the hook logs: the actor role name and the dropped
/// message's payload type (the envelope's signature is unknown at the hook).
private alias DroppedData = Tuple!(string, TypeInfo);

/// The default sink: the module logger at error level.
private void defaultEmit(string fmt, DroppedData data) @safe {
    import logger = std.experimental.logger;

    logger.errorf(fmt, data.expand);
}

/// The body of every engine actor's `onUnhandledMessage` hook: a message
/// that arrives with no matching handler means a dynamic-send typo or a
/// signature mismatch - the vendor drops it silently, so log it loudly while
/// debugging. Compiled out by default: enabled only in test builds and debug
/// builds opted in with -version=CodeCheckerActorDebug (see the gate above) -
/// never user-visible in release runs (no new user-visible output).
private void logUnhandledMessage(alias emit = defaultEmit)(string actorName, scope ref Variant msg) @safe {
    version (CodeCheckerActorDebug) {
        // The vendor hands the hook the message's payload (the args tuple),
        // never the envelope - the dropped envelope's signature is unknown
        // here, so the payload type is the best available breadcrumb.
        emit("code_checker engine actor %s: dropped a message with payload type %s",
                DroppedData(actorName, msg.type));
    }
}

/// One-shot per-file work: run the tool for the file assigned in the
/// constructor, report one result, then exit.
interface IFileWorker {
    /// One-shot: analyze, send fileDone to the collector, returnToken to the
    /// limiter, then sendExit(self, ExitReason.userShutdown).
    void run();
}

/// Compile-db prep loop and fan-out for one analyzer run.
interface IJobCoordinator {
    /// Take ownership of the job: iterate the compile db (same order, same
    /// exists/filter checks, same break-on-missing), take a limiter token per
    /// accepted file (loadavg-gated), spawn one IFileWorker per file,
    /// tell the ResultCollector the expected count, then self-exit.
    void start(AnalyzerJob job);
}

/// Fan-in for one analyzer run.
interface IResultCollector {
    /// Coordinator → collector, sent BEFORE the first worker is spawned: how
    /// many results to expect (files accepted). FIFO mailbox ordering makes
    /// an early `fileDone` impossible by construction (no early-done race).
    void begin(size_t expected);

    /// Worker → collector: the single per-file result (Tidy or Iwyu payload).
    void fileDone(ImmutableFileResult res);

    /// Coordinator → collector: one compile-db entry's file is missing from
    /// the filesystem (the prep loop's break/continue-on-missing path).
    /// Applies the score/status mutation of the enqueue loop
    /// (`result_.score -= scorePenalty`; clang-tidy aborts →
    /// `result_.status = Status.failed`, iwyu never touches status). The
    /// message text itself goes to the ConsoleWriter via notice() (emitted
    /// mid-run instead of carried in the aggregate's msg array - a deliberate
    /// split).
    void missing(string msg, int scorePenalty, bool abort);

    /// Coordinator → collector, sent right after each worker spawn:
    /// registers the monitor on behalf of the collector (the coordinator
    /// spawns, the collector observes) and carries the pre-baked failed
    /// result the collector should fall back to if that worker dies without
    /// reporting (a DownMsg carries only the worker's address, which the
    /// collector cannot map back to a file on its own).
    ///
    /// Ordering: a DownMsg is a system message and the kernel drains the
    /// system queue before the normal queue each tick, so a fast-dying
    /// worker's DownMsg can be processed before its watching() message even
    /// though the coordinator enqueues watching() first (same task as the
    /// spawn). The collector parks such a DownMsg until watching() arrives.
    void watching(WeakAddress worker, ImmutableFileResult ifDead);

    /// Driver → collector: has every expected result arrived? The reply
    /// carries the merged Result report - the analyzer's aggregate; the
    /// registry merges it into its TotalResult and logs the summary
    /// (registry code unchanged).
    /// A report() that arrives before begin() parks the requester until
    /// begin() + the fileDone messages complete (the driver can send its
    /// report() request before the coordinator's begin()).
    RequestResult!Result report();
}

/// The only console writer while a system is alive.
interface IConsoleWriter {
    /// Collector → writer: everything printed for one file, in the same
    /// order: the "n/m analyzed" progress line, then the tool's
    /// stdout/stderr text (res.print).
    void fileDone(FileOutputEvent ev);

    /// Coordinator → writer: missing compile-db file user message,
    /// filter-skip trace message (same severity/level checks throughout).
    void notice(MsgSeverity severity, string msg);
}

/// One analyzer run handed to the coordinator. Built on the driver thread.
/// Value type: the whole job is copied into the coordinator's mailbox payload
/// (no shared mutable state).
struct AnalyzerJob {
    // The per-analyzer parameters executeParallel needs, plus the
    // env/compile-db access the prep loop needs. Value snapshot: everything is
    // copied into the coordinator's mailbox payload (no shared mutable state).
    // reduceOnOverload/workQueued are NOT job fields: they are per-file
    // (every second clang-tidy worker / Clock.currTime at accept) and live in
    // the coordinator-local works array.
    string[] args; // tidyArgs / iwyuArgs
    bool useColors; // clang-tidy: !env.conf.logg.toFile; unused by iwyu
    string[] fileIncludeFilter; // env.conf.staticCode.fileIncludeFilter
    string[] fileExcludeFilter; // env.conf.staticCode.fileExcludeFilter
    Environment env; // compile-db + conf access (toRange, staticCode)
    // Addresses the coordinator needs (the collector and writer are
    // message-driven only - the collector learns the expected count via
    // begin(), the writer learns everything via messages; workers get
    // collector + limiter in their ctor at spawn time):
    WeakAddress collector;
    WeakAddress console;
    WeakAddress limiter; // coordinator takes a token per file
    // Merge one file result into the aggregate:
    void function(ref Result, TidyResult) @safe mergeTidy;
    void function(ref Result, IwyuResult) @safe mergeIwyu;
}

/// Worker→collector payload; analyzer-specific result wrapped for one typed
/// message (worker flavor is fixed at spawn, so the channel stays typed).
alias ImmutableFileResult = SumType!(TidyResult, IwyuResult); // my.sumtype

/// Collector→writer payload: everything printed for one file, in the
/// engine's emission order (progress line, then the tool's stdout/stderr text).
/// Value type copied through the mailbox Variant.
struct FileOutputEvent {
    string progressLine; // "n/m <analyzer> analyzed '<file>'"
    ImmutableFileResult res; // writer emits res.print() output next
}

/// One-shot coordinator for one analyzer run: the compile-db prep loop,
/// the loadavg gate, limiter fan-out, stop signaling, then self-exit.
///
/// Generic over the worker actor type and the per-file payload. The
/// per-flavor pieces are static-if over the payload flavor: the prep-loop
/// differences (exists-check message/penalty/break-vs-continue,
/// filter-mismatch trace message, work construction) and the loadavg gate
/// (clang-tidy only; the iwyu flavor never had load-shedding).
final class JobCoordinator(Worker, Payload) : IJobCoordinator {
    import std.algorithm : copy, joiner, map;
    import std.array : appender;
    import std.datetime : Clock, Duration, SysTime;
    import std.exception : collectException;
    import std.file : exists;
    import std.format : format;
    import logger = std.experimental.logger;
    import std.parallelism : totalCPUs;
    import std.path : relativePath;
    import std.random : uniform;

    import my.actor.common : ExitReason;
    import my.actor.channel : Channel;
    import my.actor.behavior : ActorRef;
    import my.actor.mailbox : TypedAddress;
    import my.actor.msg : Capture, monitor, sendExit;
    import my.actor.system : System;
    import my.actor.utility.limiter : IFlowControl, Token;
    import my.filter : ReFilter;
    import my.sumtype : SumType;

    import code_checker.engine.types : Environment, MsgSeverity, Status;
    import code_checker.engine.compile_db : toRange;
    import code_checker.engine.builtin.clang_tidy : TidyWork;
    import code_checker.engine.builtin.include_what_you_use : IwyuWork;
    import code_checker.utility : osAverageLoad;

    /// The per-file payload flavors the coordinator builds and fans out.
    alias Works = SumType!(TidyWork*, IwyuWork*);

    AnalyzerJob job_;
    WeakAddress collector_, console_, limiter_;
    ActorRef self_;
    Works[] works_;
    TypedAddress!Worker[] workers_; // running workers, for the stop signal
    size_t fi_; // fan-out cursor; resumable across gate waits
    size_t expected_; // accepted counter (worker ctor arg + begin)
    bool aborted_;
    bool started_; // one-shot guard: start() must run exactly once
    size_t pendingTokens_; // takeToken requests issued but not yet replied

    alias This = JobCoordinator!(Worker, Payload);

    void onSpawn(ActorRef self_) @safe {
        this.self_ = self_;
    }

    void onException(Exception e) @safe nothrow {
        try {
            logger.error(e.msg);
            if (self_ != ActorRef.init)
                sendExit(self_.address(), ExitReason.userShutdown);
        } catch (Exception e2) {
            try
                logger.error(e2.msg).collectException;
            catch (Exception _) {
            }
        }
    }

    /// A message that arrives with no matching handler means a dynamic-send
    /// typo or a signature mismatch - the vendor drops it silently. This
    /// makes that visible, but only when the debug gate is on (see
    /// logUnhandledMessage): release runs print nothing.
    void onUnhandledMessage(ref Variant msg) @safe {
        logUnhandledMessage(typeof(this).stringof, msg);
    }

    override void start(AnalyzerJob job) @safe {
        // One-shot per analyzer run (fresh coordinator per run): a second
        // start would duplicate the run (prep appends to works_; expected_,
        // fi_ and aborted_ are not reset).
        if (started_)
            throw new Exception(
                    "JobCoordinator.start() called twice;" ~ " one coordinator per analyzer run");
        started_ = true;

        job_ = job;
        collector_ = job.collector;
        console_ = job.console;
        limiter_ = job.limiter;
        // A Channel send to an unset address is a silent no-op: an unset
        // collector drops every fileDone/begin/missing (the driver then hangs
        // on its parked report request), an unset console silently loses the
        // abort failReason and every notice. The driver must wire both after
        // spawning the collector (its address is only known then).
        // The limiter is only needed once fan-out starts - asserted there.
        debug assert(!collector_.empty && !console_.empty,
                "the job's collector/console addresses must be set: the"
                ~ " driver wires them after spawning the collector (a Channel"
                ~ " send to an unset address is a silent no-op)");

        // Prep pass: build the per-file work list from the compile db.
        prep();
        if (aborted_) {
            // Workers spawned before the abort are signalled; in the prep
            // phase the list is empty by construction, so this is a no-op.
            signalRunningWorkers();

            // The collector's report() parks when begin() has not arrived -
            // the driver's request is enqueued before start(job), and
            // missing() does not answer a parked request. A prep abort must
            // deliver the expected count too, or the driver blocks forever
            // on a stale compile db. With begin(0) the collector's
            // report() answers at once with the partial result: failed
            // status, the -100 penalty already merged by missing(), and the
            // failReason already on the writer via notice().
            chBegin(0);

            sendExit(self_.address(), ExitReason.userShutdown);
            return;
        }

        // else: takeToken replies spawn the remaining workers and the last
        // one to finish self-exits (spawnOneWorker).

        // The collector must learn the expected count BEFORE the first
        // worker is spawned.
        chBegin(works_.length);

        fanOut();
        if (pendingTokens_ == 0)
            sendExit(self_.address(), ExitReason.userShutdown);
        // else: takeToken replies spawn the remaining workers and the last
        // one to finish self-exits (spawnOneWorker).
    }

    /// Fire-and-forget sends through `Channel`. The vendor's opDispatch chain
    /// is inferred @system inside @safe contexts (mailbox.put internals), so
    /// these need a @trusted bridge - the same pattern as the vendor's own
    /// @trusted `then`.
    private void chBegin(size_t expected) @trusted {
        Channel!IResultCollector(collector_, self_).begin(expected);
    }

    private void chNotice(MsgSeverity sev, string msg) @trusted {
        Channel!IConsoleWriter(console_, self_).notice(sev, msg);
    }

    private void chMissing(string msg, int scorePenalty, bool abort) @trusted {
        Channel!IResultCollector(collector_, self_).missing(msg, scorePenalty, abort);
    }

    /// Prep pass: the user filters are built once here; a failing
    /// regex propagates to onException.
    private void prep() @safe {
        auto refilter = ReFilter(job_.fileIncludeFilter, job_.fileExcludeFilter);

        foreach (p; toRange(job_.env)) {
            // The file was compiled but is not present on disk anymore.
            if (!exists(p.cmd.absoluteFile.toString)) {
                static if (is(Payload == TidyWork*)) {
                    const failReason = "clang-tidy where unable to find "
                        ~ p.cmd.absoluteFile.toString ~ " in compile_commands.json on the filesystem. "
                        ~ "Your compile_commands.json is probably out of " ~ "sync. Regenerate it.";
                    chNotice(MsgSeverity.failReason, failReason);
                    chMissing(failReason, 100, true);
                    aborted_ = true;
                    break;
                } else {
                    const failReason = "iwyu where unable to find one of "
                        ~ "the specified files in compile_commands.json on "
                        ~ "the filesystem. Your compile_commands.json is "
                        ~ "probably out of sync. Regenerate it.";
                    chNotice(MsgSeverity.failReason, failReason);
                    chMissing(failReason, 1000, false);
                    continue;
                }
            }

            if (!refilter.match(p.cmd.absoluteFile)) {
                static if (is(Payload == TidyWork*)) {
                    if (logger.globalLogLevel == logger.LogLevel.all) {
                        chNotice(MsgSeverity.trace, format("Skipping analyze because it didn't "
                                ~ "pass the file filter (user supplied " ~ "regex): %s ",
                                p.cmd.absoluteFile));
                    }
                }
                continue;
            }

            expected_++;

            static if (is(Payload == TidyWork*)) {
                auto args = appender!(string[])();
                job_.args.copy(args);
                works_ ~= Works(new TidyWork(args.data, p.cmd.absoluteFile, job_.useColors,
                        job_.fileExcludeFilter, job_.fileIncludeFilter,
                        expected_ % 2 == 0, Clock.currTime));
            } else {
                auto args = appender!(string[])();
                job_.args.copy(args);
                p.flags.cflags.copy(args);
                p.flags
                    .includes
                    .map!(a => relativePath(a))
                    .map!(a => ["-I", a])
                    .joiner
                    .copy(args);
                p.flags.systemIncludes.map!(a => ["-isystem", a]).joiner.copy(args);
                args.put(p.cmd.absoluteFile);
                works_ ~= Works(new IwyuWork(args.data, p.cmd.absoluteFile));
            }
        }
    }
    /// Fan-out pass: gate + limiter token + spawn per work item. Resumes
    /// after each loadavg wait via the CheckLoadMsg self message.
    private void fanOut() @safe {
        // The limiter is only used here: an unset address would park the
        // loop on takeToken forever (silent no-op send), so assert it at the
        // fan-out boundary, not in start() - the prep-abort path
        // legitimately never reaches fan-out.
        debug assert(!limiter_.empty,
                "the job's limiter address must be set before fan-out: the"
                ~ " driver wires it after spawning the actors (a Channel send"
                ~ " to an unset address is a silent no-op)");
        for (; fi_ < works_.length; fi_++) {
            // A Tidy-flavor coordinator never sees IwyuWork items (and vice
            // versa); restrictTo keeps the shared Works sum type legal while
            // the catch-all stays unreachable.
            if (!works_[fi_].match!(restrictTo!(Payload, w => gateOpen(w)), _ => false))
                return; // waiting; CheckLoadMsg resumes this loop
            pendingTokens_++;
            // The chain's `capture` is @system in my.actor.msg; isolate it so
            // the enclosing @safe function stays callable.
            () @trusted {
                Channel!IFlowControl(limiter_, self_).takeToken.capture(Capture!(This, "self",
                        Works, "work")(this, works_[fi_])).then(&spawnOneWorker!Payload);
            }();
        }
        if (pendingTokens_ == 0)
            sendExit(self_.address, ExitReason.userShutdown);
    }

    /// The loadavg gate. Returns false while
    /// the coordinator is waiting for the system load to drop.
    private bool gateOpen(in Payload work) @safe {
        static if (is(Payload == TidyWork*)) {
            if (!work.reduceOnOverload)
                return true;

            auto maxWait = 1.dur!"minutes" - ((Clock.currTime - work.workQueued)
                    .total!"minutes" / 2).dur!"seconds";
            if (maxWait < Duration.zero)
                return true;

            const maxWaitTime = Clock.currTime + maxWait;
            const maxLoadLimit = totalCPUs + 1;
            while (osAverageLoad[0] > maxLoadLimit && Clock.currTime < maxWaitTime) {
                const backoff = uniform(1, 60).dur!"seconds";
                // Same user-visible signal as the original's per-wait trace: the only output during a load-shed
                // wait of up to ~2 h.
                logger.tracef("Average load too high, waiting to start the next clang-tidy instance. %s > %s",
                        osAverageLoad[0], maxLoadLimit);
                dynDelayedSend(self_.address, delay(backoff), "CheckLoadMsg");
                return false;
            }
        }
        return true;
    }

    /// Self message resuming the fan-out loop after a loadavg wait.
    void CheckLoadMsg() @safe {
        fanOut();
    }

    /// Take-token reply: spawn the worker holding the token, register the
    /// collector's monitor on its behalf, and tell the collector which file
    /// to fail if this worker dies without reporting (see
    /// IResultCollector.watching).
    private static void spawnOneWorker(Payload)(ref Capture!(This, "self",
            Works, "work") ctx, Token t) @safe {
        auto self = ctx.self;
        auto work = ctx.work.get!Payload;
        auto addr = () @trusted {
            return self.self_.homeSystem().spawn!Worker(self.collector_, self.limiter_, work);
        }();
        self.workers_ ~= addr;
        self.pendingTokens_--;

        // The collector monitors its own workers on behalf of the
        // coordinator (the collector doesn't spawn workers), so a vanished
        // worker cannot hang the run. watch below registers the
        // monitor and tells the collector the pre-baked failed
        // result for this file (the collector can't derive a file from the
        // worker's address alone) - the same task as the spawn, so the
        // watching() message is enqueued strictly before any DownMsg (the
        // worker needs several scheduler quanta to die; see
        // IResultCollector.watching for the parking that covers the rest).
        monitor(self.collector_, addr.weakRef);
        self.chWatching(addr.weakRef, ifDead(work));

        if (self.pendingTokens_ == 0 && self.fi_ >= self.works_.length)
            sendExit(self.self_.address(), ExitReason.userShutdown);
    }

    /// The failed result the collector falls back to if this worker dies
    /// without reporting (the DownMsg backstop), verbatim fields from the
    /// workers' stop()/abort backstops. toolFailed + status 0 routes the
    /// payload to the merge's `analyzerFailed ~= res.file` bucket - accurate
    /// and silent ("the tool never ran for this file"); a nonzero status
    /// would manufacture "warnings found" console noise for a file that was
    /// never analyzed.
    private static ImmutableFileResult ifDead(Payload work) @safe {
        static if (is(Payload == TidyWork*)) {
            import my.path : AbsolutePath;

            auto failed = new TidyResult;
            failed.file = AbsolutePath(work.p.value);
            failed.toolFailed = true;
            failed.clangTidyStatus = 0;
            return ImmutableFileResult(() @trusted { return *failed; }());
        } else {
            auto failed = new IwyuResult;
            failed.file = work.file;
            failed.exitStatus = 0;
            return ImmutableFileResult(() @trusted { return *failed; }());
        }
    }

    /// Tell the collector which file to fail if the given worker dies
    /// without reporting (the DownMsg backstop wiring). The vendor's
    /// opDispatch chain is inferred @system inside @safe contexts, so this
    /// needs a @trusted bridge - the same pattern as chStop.
    private void chWatching(WeakAddress worker, ImmutableFileResult ifDead) @trusted {
        Channel!IResultCollector(collector_, self_).watching(worker, ifDead);
    }

    /// Signal running workers to stop.
    private void chStop(WeakAddress to) @trusted {
        Channel!Worker(to, self_).stop();
    }

    private void signalRunningWorkers() @safe {
        foreach (w; workers_)
            chStop(w.weakRef);
    }
}

/// Fan-in for one analyzer run: merges every per-file result through the
/// job's merge functions, does the file-sink logging, builds the per-file
/// progress lines, answers the driver's `report()` status request exactly
/// once and self-exits.
///
/// One-shot per analyzer run. Message flow: the coordinator sends
/// `missing()`/`begin(accepted)` during the prep pass, workers send
/// `fileDone(res)` per file, the driver sends one `report()` request. The
/// collector is generic over the per-file payload; the per-flavor
/// pieces (progress line, merge call, file-sink logging) are static-if over
/// the payload flavor, mirroring the coordinator.
final class ResultCollector(Payload) : IResultCollector {
    import std.exception : collectException;
    import std.format : format;
    import logger = std.experimental.logger;

    import my.actor.behavior : ActorRef;

    import my.actor.channel : Channel;
    import my.actor.common : ExitReason;
    import my.actor.msg : sendExit;
    import my.actor.system_msg : DownMsg;
    import my.actor : Promise, makePromise;

    import code_checker.engine.logger : Logger;
    import code_checker.engine.types : Msg, Status;

    AnalyzerJob job_;
    WeakAddress writer_;
    Result result_;
    size_t expected_, received_;
    /// Set by begin(); report() parks until it arrives. The driver sends its
    /// report() request right after start(job), while begin() only follows
    /// prep()'s compile-db iteration - in any realistic interleaving the
    /// report() request lands first, and the collector must park on it.
    bool begun_;
    /// Guards the exactly-once delivery of the onException backstop.
    bool delivered_;
    /// The DownMsg backstop (watching + onDownMessage): the coordinator
    /// registers one entry per spawned worker, mapping the worker's address
    /// hash to the pre-baked failed result for its file. Parallel arrays
    /// instead of an AA: the result SumType's opAssign is @system (the
    /// TidyResult payload holds an AA), so AA slot assignment
    /// (default-init + assign) is illegal in @safe code.
    static struct Watching {
        size_t workerHash;
        ImmutableFileResult ifDead;
    }

    Watching[] watching_;
    /// Dead workers whose watching() entry hadn't arrived yet: a DownMsg is
    /// a system message and the kernel drains the system queue before the
    /// normal queue each tick, so a fast-dying worker's DownMsg can be
    /// processed before its watching() message even though the coordinator
    /// enqueues watching() first (in the same task as the spawn). Parked
    /// here; resolved by watching().
    DownMsg[] pendingDown_;
    /// The files already merged, for the exactly-once rule: the DownMsg
    /// backstop must not double-report a file the worker already reported
    /// (and vice versa). Keyed by the analyzed file string.
    bool[string] merged_;
    /// The driver's parked report() request, if it arrived early.
    Promise!Result pending_;
    ActorRef self_;
    Logger logg_;

    this(AnalyzerJob job, WeakAddress writer) @safe {
        job_ = job;
        writer_ = writer;
        logg_ = Logger(job.env.conf.logg.dir);
    }

    void onSpawn(ActorRef self_) @safe {
        this.self_ = self_;
    }

    void onException(Exception e) @safe nothrow {
        try {
            logger.error(e.msg);
            if (!delivered_) {
                delivered_ = true;
                Result failed;
                failed.status = Status.failed;
                failed.msg ~= Msg(MsgSeverity.unableToExecute, "internal error: " ~ e.msg);
                if (!pending_.empty)
                    pending_.deliver(failed);
            }
            if (self_ != ActorRef.init)
                sendExit(self_.address(), ExitReason.userShutdown);
        } catch (Exception e2) {
            try
                logger.error(e2.msg).collectException;
            catch (Exception _) {
            }
        }
    }

    /// A message that arrives with no matching handler means a dynamic-send
    /// typo or a signature mismatch - the vendor drops it silently. This
    /// makes that visible, but only when the debug gate is on (see
    /// logUnhandledMessage): release runs print nothing.
    void onUnhandledMessage(ref Variant msg) @safe {
        logUnhandledMessage(typeof(this).stringof, msg);
    }

    override void begin(size_t expected) @safe {
        begun_ = true;
        expected_ = expected;
        // A prep abort sends begin(0) AFTER the driver's report() request has
        // already parked (the driver requests report() before start(job)) -
        // begin() must answer that parked request when the count is already
        // complete, or the driver blocks forever (the abort-path hang).
        // When begin() arrives first (the normal path), report() answers at
        // once via the begun_ gate in report().
        if (received_ >= expected_)
            answerPending();
    }

    override void fileDone(ImmutableFileResult res_) @safe {
        pushFileDone(res_);
    }

    /// The single per-file receipt path (worker fileDone + the DownMsg
    /// backstop), exactly-once per file on BOTH receipt paths via merged_:
    /// the DownMsg backstop must not double-report a file the worker already
    /// reported, and the real fileDone must not re-merge a file the backstop
    /// reported. merged_ is appended BEFORE merge(): a throwing merge (the
    /// "answered with a failed result exactly once" backstop) still marks the
    /// file done, so a late DownMsg for the same file is skipped instead of
    /// double-merging it.
    void pushFileDone(ImmutableFileResult res_) @safe {
        const file = fileString(res_);
        if (file in merged_)
            return; // exactly-once per file, both receipt paths
        merged_[file] = true;
        received_++;

        // Progress line first, then the tool's output: sent to the writer
        // BEFORE the merge, so a throwing merge still emits the progress
        // line - chFileDone is fire-and-forget to a different actor.
        const pLine = progressLine(res_);

        chFileDone(FileOutputEvent(pLine, res_));
        // Merge into the aggregate. The merge functions (builtin/) cannot
        // reach env/logg from here, so the file-sink logging stays in the
        // collector.
        merge(res_);
        if (received_ >= expected_)
            answerPending();
    }

    override void watching(WeakAddress worker, ImmutableFileResult ifDead) @safe {
        watching_ ~= Watching(worker.toHash, ifDead);
        resolvePendingDown(worker.toHash);
    }

    /// The liveness backstop: the coordinator registers a monitor on behalf
    /// of the collector (the collector doesn't spawn workers), so a worker
    /// that dies without replying - a crash, a kill, a stop() with no report
    /// - cannot hang the run: its file is marked failed via the
    /// normal fileDone path (pushFileDone: merge + progress log + expected
    /// count bookkeeping).
    ///
    /// A DownMsg for a worker whose watching() entry hasn't arrived yet is
    /// parked (see pendingDown_) and resolved by watching(). Once resolved,
    /// the exactly-once rule in pushFileDone skips a file the worker already
    /// reported. (The one remaining racy interleaving - watching() resolved
    /// while the real fileDone is still queued behind it - counts the file
    /// exactly once as failed: the backstop's result is merged and the
    /// worker's real fileDone is then skipped; production tool runs take
    /// seconds, so the collector processes the real fileDone long before the
    /// worker exits.)
    void onDownMessage(DownMsg msg) @safe {
        if (auto ifDead = workerToIfDead(msg.source.toHash))
            pushFileDone(*ifDead);
        else
            pendingDown_ ~= msg;
    }

    /// Resolve the parked DownMsgs of one worker whose watching() entry just
    /// arrived.
    void resolvePendingDown(size_t workerHash) @safe {
        if (pendingDown_.length == 0)
            return;

        DownMsg[] remaining;
        foreach (msg; pendingDown_) {
            if (msg.source.toHash == workerHash)
                pushFileDone(*workerToIfDead(workerHash));
            else
                remaining ~= msg;
        }
        pendingDown_ = remaining;
    }

    /// The watching() entry of a worker, or null. The pointer points into
    /// watching_ (heap elements), valid until the next watching() append.
    ImmutableFileResult* workerToIfDead(size_t workerHash) @safe {
        foreach (ref w; watching_)
            if (w.workerHash == workerHash)
                return &w.ifDead;
        return null;
    }

    override void missing(string msg, int scorePenalty, bool abort) @safe {
        // `msg` is unused here by design: its text goes to the ConsoleWriter
        // via notice() from the coordinator (see IResultCollector.missing);
        // the parameter stays for call-site symmetry with that send.
        result_.score -= scorePenalty;
        if (abort)
            result_.status = Status.failed;
    }

    override RequestResult!Result report() @safe {
        if (begun_ && received_ >= expected_) {
            // Already complete: answer immediately (idempotent for extra
            // requests) and self-exit.
            if (self_ != ActorRef.init)
                sendExit(self_.address(), ExitReason.userShutdown);
            return RequestResult!Result(result_);
        }

        // Park the requester on a promise; answerPending() delivers through
        // it when the last fileDone arrives.
        if (pending_.empty)
            pending_ = makePromise!Result;

        return RequestResult!Result(pending_);
    }

    /// Deliver the stored result through the parked request, exactly once
    /// (deliver releases the promise), then self-exit.
    private void answerPending() @safe {
        if (pending_.empty)
            return;

        pending_.deliver(result_);

        if (self_ != ActorRef.init)
            sendExit(self_.address(), ExitReason.userShutdown);
    }

    private void merge(ImmutableFileResult res_) @safe {
        static if (is(Payload == TidyWork*)) {
            res_.match!((TidyResult r) { fileDoneTidy(r); }, (_) {
                throw new Exception("unreachable payload flavor");
            });
        } else {
            res_.match!((IwyuResult r) { fileDoneIwyu(r); }, (_) {
                throw new Exception("unreachable payload flavor");
            });
        }
    }

    private void fileDoneTidy(TidyResult r) @safe {
        import code_checker.process : exitCodeSegFault;

        job_.mergeTidy(result_, r);

        // File-sink logging for a failing clang-tidy result.
        if (job_.env.conf.logg.toFile && r.clangTidyStatus != 0
                && r.clangTidyStatus != exitCodeSegFault) {

            try {
                logg_.put(r.file, [r.output]);
            } catch (Exception e) {
                logger.warning(e.msg).collectException;
                logger.warning("Unable to log to file").collectException;
            }
        }
    }

    private void fileDoneIwyu(IwyuResult r) @safe {
        job_.mergeIwyu(result_, r);

        // File-sink logging for a failing iwyu run.
        if (job_.env.conf.logg.toFile && !(r.exitStatus == 0 || r.exitStatus == 2)) {
            import my.path : AbsolutePath, Path;

            try {
                const logFile = Path(r.file.toString ~ ".iwyu").AbsolutePath;
                logg_.put(logFile, [r.output]);
            } catch (Exception e) {
                logger.warning(e.msg).collectException;
                logger.warning("Unable to log to file").collectException;
            }
        }
    }

    /// "n/m analyzed '<file>'" progress line.
    private string progressLine(ImmutableFileResult res_) @safe {
        static if (is(Payload == TidyWork*)) {
            import colorlog : Color, Background, color;

            return format("%s/%s %s '%s'", received_, expected_,
                    "clang-tidy analyzed".color(Color.yellow)
                        .bg(Background.black), fileString(res_));
        } else {
            import colorlog : Color, Background, color;

            return format("%s '%s'", "iwyu analyzing".color(Color.yellow)
                    .bg(Background.black), fileString(res_));
        }
    }

    /// The analyzed file of the per-file result.
    private static string fileString(ImmutableFileResult res_) @safe {
        string file;
        res_.match!((TidyResult r) { file = r.file.toString; }, (IwyuResult r) {
            file = r.file.toString;
        });
        return file;
    }

    /// Fire-and-forget send through `Channel`. The vendor's opDispatch chain
    /// is inferred @system inside @safe contexts (mailbox.put internals), so
    /// this needs a @trusted bridge - the same pattern as the coordinator's.
    private void chFileDone(FileOutputEvent ev) @trusted {
        Channel!IConsoleWriter(writer_, self_).fileDone(ev);
    }
}

/// The sole stdout/stderr writer while a system is alive: emits the
/// per-file output events from the collector and the coordinator's notices,
/// in the engine's text and order.
///
/// Receives only; the sole-writer rule is enforced by construction (only the
/// coordinator and collector know its address).
final class ConsoleWriter : IConsoleWriter {
    import std.exception : collectException;
    import logger = std.experimental.logger;

    override void fileDone(FileOutputEvent ev) @safe {
        logger.info(ev.progressLine).collectException;

        // The tool's stdout/stderr, gated: only failing/segfaulting
        // clang-tidy runs and failing iwyu runs print their output.
        ev.res.match!((TidyResult r) {
            if (r.clangTidyStatus != 0)
                r.print;
        }, (IwyuResult r) {
            if (!(r.exitStatus == 0 || r.exitStatus == 2))
                r.print;
        });
    }

    /// Per-message dispatch, verbatim from the registry's private log: suggestions are only carried in the aggregate,
    /// warnings at warning level, traces at the logger's own level (trace
    /// passes only when the log level is all).
    override void notice(MsgSeverity severity, string msg) @safe {
        final switch (severity) {
        case MsgSeverity.improveSuggestion:
            break;
        case MsgSeverity.unableToExecute:
        case MsgSeverity.failReason:
            logger.warning(msg);
            break;
        case MsgSeverity.trace:
            logger.trace(msg);
            break;
        }
    }

    /// A message that arrives with no matching handler means a dynamic-send
    /// typo or a signature mismatch - the vendor drops it silently. This
    /// makes that visible, but only when the debug gate is on (see
    /// logUnhandledMessage): release runs print nothing.
    void onUnhandledMessage(ref Variant msg) @safe {
        logUnhandledMessage(typeof(this).stringof, msg);
    }
}

/// The engine's concurrency cap for the analyzer drivers: one token per
/// concurrently busy worker, explicit `totalCPUs() - 1`. Always at least 1:
/// a 0-token limiter would park the coordinator in fanOut forever (no worker
/// could ever run and return a token).
uint engineConcurrency() @safe {
    import std.algorithm : max;
    import std.parallelism : totalCPUs;

    return max(1, totalCPUs() - 1);
}

/// Driver-side blocking helper for one analyzer run: requests
/// `report()` from the collector, sends `start(job)` fire-and-forget to the
/// coordinator, parks in the documented manually-driven client kernel until
/// the request is answered, and returns the merged `Result`.
///
/// `sys` is part of the helper contract (the existing call sites pass it);
/// the helper does not own the system's lifetime - reply-handler dispatch
/// happens-before this helper returns happens-before the caller's
/// `scope (exit) sys.shutdown`, so the system only has to stay alive while
/// this helper runs (the coordinator and collector are its pooled actors).
///
/// No overall timeout (the coordinator and
/// collector own progress tracking and liveness).
///
/// A failure on the driver side of this helper (send + wait block) is caught,
/// logged and converted to a failed `Result` - exactly what
/// `executeOneAnalyzer`'s catch does. Note that an exception thrown INSIDE a
/// spawned actor never crosses the actor boundary: the vendor routes handler
/// exceptions to the actor's own `onException` hook, so liveness on that path
/// is the collector's job, not this helper's.
Result blockUntilReport(System* sys, WeakAddress coordinatorAddr,
        WeakAddress collectorAddr, ref AnalyzerJob job) @trusted
in (sys !is null, "the caller's system owns the pooled actors' lifetime") {
    import core.thread : Thread;
    import core.time : msecs;
    import std.datetime : Clock;
    import std.exception : collectException;
    import std.typecons : Tuple;
    import logger = std.experimental.logger;

    import code_checker.engine.types : Status;
    import my.actor.behavior : ActorRef;
    import my.actor.channel : Channel, dynRequest;
    import my.actor.mailbox : makeAddress;
    import my.actor.msg : infTimeout;
    import my.actor.system : ActorShell, System;

    bool replied_;
    Result got_;

    static void onReport(ref Tuple!(bool*, Result*) ctx, Result r) @safe {
        *ctx[0] = true;
        *ctx[1] = r;
    }

    try {
        // The client kernel runs on this (the driver) thread; the reply
        // handler is dispatched from its process() below - the verbatim
        // manually-driven pattern.
        auto client = ActorShell(makeAddress);

        // The report request is enqueued BEFORE start(job): report() parks
        // safely pre-begin (pending_ = makePromise!Result) and begin + fileDone
        // answer it, so a driver preemption between the two sends cannot race
        // the collector into answering and self-exiting before the request
        // arrives (the request-first order also makes the throwing-start test
        // deterministic). Coordinator ordering is unaffected: begin() is sent
        // before the first worker is spawned (IJobCoordinator contract).
        // Fail fast instead of hanging forever if an addressee is already
        // down (the sends below are silent no-ops on a dead target).
        if (collectorAddr.lock.empty)
            throw new Exception("collector is down before report()");
        dynRequest(ActorRef(&client), collectorAddr, infTimeout(), "report").capture(&replied_,
                &got_).then(&onReport);

        if (coordinatorAddr.lock.empty)
            throw new Exception("coordinator is down before start(job)");
        Channel!IJobCoordinator(coordinatorAddr, ActorRef(&client)).start(job);

        while (!replied_) {
            client.process(Clock.currTime);
            Thread.sleep(1.msecs);
        }
    } catch (Exception e) {
        // Same conversion as executeOneAnalyzer's catch:
        // log and surface a failed Result to the caller (only if no reply
        // arrived - a late dispatch failure must not clobber a good reply).
        logger.error(e.msg).collectException;
        if (!replied_)
            got_.status = Status.failed;
    }

    return got_;
}

/// One-shot clang-tidy worker: `taskTidy` as a typed actor. The coordinator spawns
/// one per accepted file together with the limiter token it took; the worker
/// analyzes its one file, sends exactly one `fileDone` to the collector,
/// returns the token to the limiter and self-exits (the userShutdown exit
/// rides the default exit handler since the worker defines no `onExit` hook).
///
/// The load-shedding sleep (`sleepUntilNotOverloaded`)
/// is NOT here: the coordinator's fan-out loop gates on the load average
/// before taking the token and spawning (the gateOpen check), so a spawned
/// worker never waits.
///
/// `run` is the only analysis message; `stop` is the coordinator's
/// requested-exit signal (the missing-file abort path, chStop). Requested
/// exits are delivered after `run` returns when the worker is busy (no
/// preemption) - the `reported_`/`stopped_` guards make every
/// interleaving yield exactly one report and one exit. The class is not
/// `final` so tests can subclass it to exercise the `onException` backstop.
class ClangTidyWorker : IFileWorker {
    import std.array : appender;
    import std.exception : collectException;
    import std.format : format;
    import logger = std.experimental.logger;

    import code_checker.engine.builtin.clang_tidy_classification : DiagMessage,
        StatMessage, color, mapClangTidy, mapClangTidyStats;
    import code_checker.engine.builtin.clang_tidy : runClangTidy;
    import my.actor.behavior : ActorRef;
    import my.actor.channel : Channel, dynSend;
    import my.actor.common : ExitReason;
    import my.actor.msg : sendExit;
    import my.actor.utility.limiter : IFlowControl;
    import my.filter : ReFilter;
    import my.path : AbsolutePath;
    import code_checker.engine.types : Detail, Msg;

    private {
        WeakAddress collector_, limiter_;
        TidyWork* work_;
        ActorRef self_;
        /// Exactly-once guards: `reported_` funnels the normal path, the
        /// filter-failure early return, the `onException` backstop and the
        /// coordinator-requested exit into one reportDone; `stopped_` makes a
        /// requested exit idempotent and stops `run` from analyzing after it.
        bool reported_;
        bool stopped_;
    }

    this(WeakAddress collector, WeakAddress limiter, TidyWork* work) @safe {
        collector_ = collector;
        limiter_ = limiter;
        work_ = work;
    }

    /// One-shot kick-off: the coordinator spawns without sending a message, so
    /// the launch hook self-sends run() (the documented one-shot pattern,
    /// my/actor/system.d SelfSender).
    void onSpawn(ActorRef self_) @safe {
        this.self_ = self_;
        dynSend(self_.address(), "run");
    }

    /// The single reply for this file, on every path: fileDone to the
    /// collector, the limiter token back, then self-exit. Exactly once
    /// (reported_) - the normal path, the filter-failure early return, the
    /// onException backstop and the coordinator-requested exit all funnel
    /// through it.
    private void reportDone(ImmutableFileResult res) @safe {
        if (reported_)
            return;
        reported_ = true;
        chFileDone(res);
        chReturnToken();
        // `self_` is unset if the launch hook itself threw (the framework
        // routes that exception here); a null self-address send is a silent
        // no-op rather than a null-deref.
        if (self_ != ActorRef.init)
            sendExit(self_.address(), ExitReason.userShutdown);
    }

    private void chFileDone(ImmutableFileResult res) @trusted {
        Channel!IResultCollector(collector_, self_).fileDone(res);
    }

    private void chReturnToken() @trusted {
        Channel!IFlowControl(limiter_, self_).returnToken();
    }

    private static ImmutableFileResult payloadOf(TidyResult* r) @trusted {
        return ImmutableFileResult(*r);
    }

    /// The coordinator-requested exit (the missing-file abort path): finish
    /// without analyzing if run() has not started, otherwise a no-op - the
    /// successful result is already reported (no double-report).
    void stop() @safe {
        if (stopped_)
            return;
        stopped_ = true;

        // A failed result for this file: the file was accepted (a token was
        // taken for it), so the collector's expected count is only reached if
        // this worker reports. toolFailed + status 0 routes the payload to
        // the merge's `analyzerFailed ~= res.file` bucket
        // - accurate and silent ("the tool never ran for this file"); a
        // nonzero clangTidyStatus would manufacture "warnings found" console
        // noise for a file that was never analyzed.
        auto failed = new TidyResult;
        failed.file = AbsolutePath(work_.p.value);
        failed.toolFailed = true;
        failed.clangTidyStatus = 0;
        reportDone(payloadOf(failed));
    }

    override void run() @trusted {
        if (stopped_)
            return; // the requested exit landed before run() was dispatched

        auto work = work_;

        auto tres = new TidyResult;

        ReFilter file_filter;
        try {
            file_filter = ReFilter(work.fileIncludeFilter, work.fileExcludeFilter);
        } catch (Exception e) {
            logger.error(e.msg).collectException;
            tres.clangTidyStatus = -1;
            reportDone(payloadOf(tres));
            return;
        }

        try {
            import std.algorithm : copy;

            // there may be warnings that are skipped. If all warnings are skipped
            // the counter is zero and the result is an automatic pass: all the
            // warnings were from excluded files.
            int count_errors;

            bool diagMsg(ref DiagMessage msg) {
                if (!file_filter.match(msg.file))
                    return false;

                auto d = Detail(Msg(MsgSeverity.trace, msg.diagnostic),
                        msg.severity, msg.kind, msg.pos);
                tres.details.update(AbsolutePath(msg.file), { return [d]; }, (ref Detail[] a) {
                    a ~= d;
                });

                count_errors++;
                tres.errors.put(msg.severity);
                if (work.useColors)
                    msg.diagnostic = format("%s[%s]", msg.fullToolOutput, color(msg.severity));
                else
                    msg.diagnostic = format("%s[%s]", msg.fullToolOutput, msg.severity);
                return true;
            }

            void statMsg(StatMessage msg) {
                tres.suppressedWarnings = msg.nolint;
                tres.errors.setSuppressed(msg.nolint);
            }

            tres.file = work.p;

            auto res = runClangTidy(work.args, work.p);

            auto app = appender!(string[])();
            mapClangTidy!diagMsg(res.stdout, app);

            mapClangTidyStats!statMsg(res.stderr);

            // clang-tidy returns exit status '0' and warnings when it runs successfully.

            if (count_errors != 0) {
                tres.clangTidyStatus = 1;
            } else if (res.timeout) {
                // a timeout is not an error to the user thus use a clean exit status.
                tres.clangTidyStatus = 0;
                tres.timeout = res.timeout;
            } else if (res.status != 0 && count_errors != 0) {
                // happens when there is e.g. a compilation error and warnings
                tres.clangTidyStatus = res.status;
            } else if (res.status != 0 && count_errors == 0) {
                // the tool reported error but no errors were found thus the user
                // can't actually do anything.
                tres.toolFailed = true;
                tres.clangTidyStatus = 0;
            }

            res.stderr.copy(app);
            tres.output = app.data;
        } catch (Exception e) {
            logger.warning(e.msg).collectException;
        }

        reportDone(payloadOf(tres));
    }

    /// Liveness backstop: a handler exception must never hang the
    /// collector - one failed fileDone for this file, then self-exit.
    /// Belt-and-braces: run() itself already funnels every tool failure into a
    /// reported result, so this only fires on a future regression.
    void onException(Exception e) @safe nothrow {
        try {
            logger.error(e.msg).collectException;
            auto failed = new TidyResult;
            failed.file = AbsolutePath(work_.p.value);
            failed.toolFailed = true;
            failed.clangTidyStatus = 0;
            reportDone(payloadOf(failed));
        } catch (Exception e2) {
            logger.error(e2.msg).collectException;
        }
    }

    /// A message that arrives with no matching handler means a dynamic-send
    /// typo or a signature mismatch - the vendor drops it silently. This
    /// makes that visible, but only when the debug gate is on (see
    /// logUnhandledMessage): release runs print nothing.
    void onUnhandledMessage(ref Variant msg) @safe {
        logUnhandledMessage(typeof(this).stringof, msg);
    }
}

/// One-shot include-what-you-use worker: the worker runs the tool
/// for its one file, sends exactly one `fileDone` to the collector, returns the
/// token to the limiter and self-exits.
class IwyuWorker : IFileWorker {
    import std.exception : collectException;
    import logger = std.experimental.logger;

    import code_checker.engine.builtin.include_what_you_use : IwyuResult, IwyuWork;
    import my.actor.behavior : ActorRef;
    import my.actor.channel : Channel, dynSend;
    import my.actor.common : ExitReason;
    import my.actor.msg : sendExit;
    import my.actor.utility.limiter : IFlowControl;
    import my.path : AbsolutePath;

    private {
        WeakAddress collector_, limiter_;
        IwyuWork* work_;
        ActorRef self_;
        /// Exactly-once guards: `reported_` funnels the normal path, the
        /// `onException` backstop and the coordinator-requested exit into one
        /// reportDone; `stopped_` makes a requested exit idempotent and stops
        /// `run` from analyzing after it.
        bool reported_;
        bool stopped_;
    }

    this(WeakAddress collector, WeakAddress limiter, IwyuWork* work) @safe {
        collector_ = collector;
        limiter_ = limiter;
        work_ = work;
    }

    /// One-shot kick-off: the coordinator spawns without sending a message, so
    /// the launch hook self-sends run() (the documented one-shot pattern,
    /// my/actor/system.d SelfSender).
    void onSpawn(ActorRef self_) @safe {
        this.self_ = self_;
        dynSend(self_.address(), "run");
    }

    /// The single reply for this file, on every path: fileDone to the
    /// collector, the limiter token back, then self-exit. Exactly once
    /// (reported_) - the normal path, the onException backstop and the
    /// coordinator-requested exit all funnel through it.
    private void reportDone(ImmutableFileResult res) @safe {
        if (reported_)
            return;
        reported_ = true;
        chFileDone(res);
        chReturnToken();
        // `self_` is unset if the launch hook itself threw (the framework
        // routes that exception here); a null self-address send is a silent
        // no-op rather than a null-deref.
        if (self_ != ActorRef.init)
            sendExit(self_.address(), ExitReason.userShutdown);
    }

    private void chFileDone(ImmutableFileResult res) @trusted {
        Channel!IResultCollector(collector_, self_).fileDone(res);
    }

    private void chReturnToken() @trusted {
        Channel!IFlowControl(limiter_, self_).returnToken();
    }

    private static ImmutableFileResult payloadOf(IwyuResult* r) @safe {
        return ImmutableFileResult(*r);
    }

    /// The coordinator-requested exit (the missing-file abort path): finish
    /// without analyzing if run() has not started, otherwise a no-op - the
    /// result is already reported (no double-report).
    ///
    /// The synthetic exitStatus 0 is the silent-OK flavor: every iwyu consumer
    /// (the merge's allIsOk gate, the file-sink
    /// gate and the ConsoleWriter gate) treats 0 and 2 as OK, so a never-run
    /// file changes no score, prints nothing and is not file-logged - the
    /// iwyu merge has no silent-but-accounted failed bucket (unlike tidy's
    /// analyzerFailed, where clangTidyStatus=0 routes); the missing-file
    /// accounting for this file is the coordinator's `missing()` −1000 path,
    /// which already fired before the stop was signalled. 0 is the same silent
    /// flavor the tidy worker picked.
    void stop() @safe {
        if (stopped_)
            return;
        stopped_ = true;

        auto failed = new IwyuResult;
        failed.file = work_.file;
        failed.exitStatus = 0;
        reportDone(payloadOf(failed));
    }

    override void run() @trusted {
        if (stopped_)
            return; // the requested exit landed before run() was dispatched

        auto work = work_;

        auto rval = new IwyuResult;
        rval.file = work.file;

        try {
            import code_checker.process : run;

            auto res = run(work.args);
            rval.exitStatus = res.status;
            rval.output = res.stdout ~ res.stderr;
        } catch (Exception e) {
            logger.warning(e.msg).collectException;
        }

        reportDone(payloadOf(rval));
    }

    /// Liveness backstop: a handler exception must never hang the
    /// collector - one failed fileDone for this file, then self-exit.
    /// Belt-and-braces: run() itself already funnels every tool failure into a
    /// reported result, so this only fires on a future regression.
    void onException(Exception e) @safe nothrow {
        try {
            logger.error(e.msg).collectException;
            auto failed = new IwyuResult;
            failed.file = work_.file;
            failed.exitStatus = 0;
            reportDone(payloadOf(failed));
        } catch (Exception e2) {
            logger.error(e2.msg).collectException;
        }
    }

    /// A message that arrives with no matching handler means a dynamic-send
    /// typo or a signature mismatch - the vendor drops it silently. This
    /// makes that visible, but only when the debug gate is on (see
    /// logUnhandledMessage): release runs print nothing.
    void onUnhandledMessage(ref Variant msg) @safe {
        logUnhandledMessage(typeof(this).stringof, msg);
    }
}

/// Compile-time gate for the engine actors' `onUnhandledMessage` debug logging
/// (see logUnhandledMessage above): the direct-fire and end-to-end wiring tests
/// below only exist where the gate is on - a test-project dependency build
/// compiles this module without `version (unittest)`, so the gate is off there
/// and the hooks are no-ops.
version (CodeCheckerActorDebug) {
    import std.experimental.logger : Logger, LogLevel;
    import unit_threaded.runner.attrs : Serial;

    @("actor_engine: a dropped payload is logged with its payload type")
    unittest {
        import std.algorithm : canFind;
        import std.format : format;

        string logged;
        void sink(string fmt, DroppedData data) @safe {
            logged = format(fmt, data.expand);
        }

        auto env = emptyPayload();
        logUnhandledMessage!sink("ConsoleWriter", env);

        assert(logged.canFind("dropped a message with payload type"), "logged: " ~ logged);
    }

    @Serial @("actor_engine: a typo'd dynamic send to a registered actor is logged, not lost")
    unittest {
        import std.algorithm : canFind;
        import std.format : format;

        import my.actor.mailbox : makeAddress;
        import my.actor.msg : sendExit;
        import my.actor.channel : dynSend;
        import my.actor.common : ExitReason;
        import my.actor.registration : implActor;
        import my.actor.system : ActorShell;
        import std.datetime.systime : Clock;

        auto addr = makeAddress;
        auto kernel = ActorShell(addr);
        implActor(new ConsoleWriter, &kernel);

        const logged = captureLogged(delegate() @safe {
            // A typo'd method name produces a signature with no matching handler:
            // the vendor drops the message; the hook must make that visible.
            dynSend(addr.weakRef, "fileDno");
            kernel.process(Clock.currTime);
        });

        assert(logged.canFind("dropped a message with payload type"), format("logged: %s", logged));

        // The actor has no exit hook, so the default handler force-terminates it.
        sendExit(addr.weakRef, ExitReason.userShutdown);
        foreach (_; 0 .. 100)
            kernel.process(Clock.currTime);
    }

    @Serial @("actor_engine: every actor role logs a dropped message")
    unittest {
        import std.format : format;

        import my.actor.mailbox : makeAddress;
        import code_checker.engine.builtin.clang_tidy : TidyWork;
        import code_checker.engine.builtin.include_what_you_use : IwyuWork;

        auto coordinator = new JobCoordinator!(ClangTidyWorker, TidyWork*)();
        auto collector = new ResultCollector!(TidyWork*)(AnalyzerJob.init, makeAddress.weakRef);
        auto writer = new ConsoleWriter;
        auto tidyWorker = new ClangTidyWorker(makeAddress.weakRef,
                makeAddress.weakRef, mkTidyWork());
        auto iwyuWorker = new IwyuWorker(makeAddress.weakRef, makeAddress.weakRef, mkIwyuWork());

        assertDroppedLogged(coordinator);
        assertDroppedLogged(collector);
        assertDroppedLogged(writer);
        assertDroppedLogged(tidyWorker);
        assertDroppedLogged(iwyuWorker);
    }

    /// Swaps the global loggers for a capturing one for the duration of `run`
    /// (both hops the free log functions take: the thread-local forwarder and the
    /// shared log it forwards to).
    private string captureLogged(void delegate() @safe run) @trusted {
        import logger = std.experimental.logger;
        import std.experimental.logger.core : stdThreadLocalLog;

        auto savedShared = logger.sharedLog;
        auto savedThread = stdThreadLocalLog;
        scope (exit) {
            logger.sharedLog = savedShared;
            stdThreadLocalLog = savedThread;
        }
        auto cap = new CaptureLogger;
        logger.sharedLog = cast(shared) cap;
        stdThreadLocalLog = cap;
        run();
        return cap.lines;
    }

    private final class CaptureLogger : Logger {
        import std.format : format;

        string lines;

        this() @safe {
            super(LogLevel.all);
        }

        override void writeLogMsg(ref LogEntry payload) @safe {
            lines ~= format("%s %s", payload.logLevel, payload.msg);
        }
    }

    /// The payload the vendor hands the unhandled hook for a zero-arg dynamic
    /// send: an empty args tuple (the shape of makePayload's result).
    /// @trusted because `Variant(tuple())` is not provably @safe (the compiler
    /// cannot verify the Variant construction), though it cannot fail.
    private Variant emptyPayload() @trusted {
        import std.typecons : tuple;

        return Variant(tuple());
    }

    private void assertDroppedLogged(T)(T actor) @safe {
        import std.algorithm : canFind;
        import std.format : format;

        const logged = captureLogged(delegate() @safe {
            auto env = emptyPayload();
            actor.onUnhandledMessage(env);
        });

        assert(logged.canFind("dropped a message with payload type"), format("logged: %s", logged));
    }

    private TidyWork* mkTidyWork() @safe {
        import std.datetime : Clock;

        import code_checker.engine.builtin.clang_tidy : TidyWork;
        import my.path : AbsolutePath;

        auto w = new TidyWork([], AbsolutePath("a.cpp"), false, [], [], false, Clock.currTime);
        return w;
    }

    private IwyuWork* mkIwyuWork() @safe {
        import code_checker.engine.builtin.include_what_you_use : IwyuWork;
        import my.path : AbsolutePath;

        auto w = new IwyuWork([], AbsolutePath("a.cpp"));
        return w;
    }
}
