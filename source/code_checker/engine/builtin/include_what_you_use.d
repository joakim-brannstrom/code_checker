/**
Copyright: Copyright (c) Joakim Brännström. All rights reserved.
License: $(LINK2 http://www.boost.org/LICENSE_1_0.txt, Boost Software License 1.0)
Author: Joakim Brännström (joakim.brannstrom@gmx.com)

This module contains an analyser and runner for
[iwyu](https://github.com/include-what-you-use/include-what-you-use).
*/
module code_checker.engine.builtin.include_what_you_use;

import logger = std.experimental.logger;
import std.array : appender, empty, array;
import std.exception : collectException;
import std.typecons : Tuple;

import my.path : AbsolutePath, Path;
import my.filter : ReFilter;

import code_checker.engine.builtin.clang_tidy_classification : CountErrorsResult;
import code_checker.engine.types;
import code_checker.process : RunResult;

@safe:

class IncludeWhatYouUse : BaseFixture {
    private {
        Environment env;
        Result result_;
        string[] iwyuArgs;
    }

    override string name() {
        return "iwyu";
    }

    override string explain() {
        return "using iwyu (include what you use)";
    }

    /// The environment the analyzer executes in.
    override void putEnv(Environment v) {
        this.env = v;
    }

    /// Setup the environment for analyze.
    override void setup() {
        import std.algorithm : copy, map, joiner;
        import std.file : exists;
        import std.range : put, only;
        import code_checker.utility : replaceConfigWord, warnIfFileDoNotExist;

        auto app = appender!(string[])();
        app.put(env.conf.iwyu.binary);
        only(env.conf.iwyu.maps, env.conf.iwyu.defaultMaps).joiner
            .map!(a => a.replaceConfigWord)
            .warnIfFileDoNotExist
            .map!(a => only("-Xiwyu", "--mapping_file=" ~ a))
            .joiner
            .copy(app);
        env.conf.iwyu.extraFlags.copy(app);
        iwyuArgs = app.data;
    }

    override void execute() {
        // Once-per-run semantics enforced, not assumed: a future multi-run
        // registry would otherwise keep the first run's flag (mirrors
        // clang_tidy.d).
        resetLoggedFailure();

        // The seed for the parallel run: iwyu's per-file merge only ever downgrades via
        // mergeStatus(result_.status, Status.failed), so without this the
        // merged result of a clean run stays Status.none and registry.d loses
        // the "Congratulations!!!" for a passing run. clang-tidy's per-file
        // merge seeds passed from the worker results instead; iwyu has no
        // such write, so the seed must stay here.
        result_.status = Status.passed;

        import my.actor.system : Config;
        import my.actor.system : makeSystem;
        import my.actor.utility.limiter : FlowControl;

        import code_checker.engine.actor_engine : AnalyzerJob, ConsoleWriter, IwyuWorker,
            JobCoordinator, ResultCollector, blockUntilReport, engineConcurrency;

        // One System per analyzer run; scope (exit) shutdown drains the
        // system.
        auto sys = makeSystem();
        scope (exit)
            sys.shutdown();

        // engineConcurrency(): one token per concurrently busy worker,
        // minimum 1 - a 0-token limiter would hang the coordinator on a
        // single-CPU host.
        auto limiter = () @trusted {
            return sys.spawn!FlowControl(engineConcurrency());
        }();

        // Detached placement: the writer drains its backlog on its own
        // thread, and System.shutdown joins detached threads, so every
        // per-file event is printed before execute() returns. A pooled
        // writer would be killed with
        // its queue undrained at shutdown.
        auto writer = () @trusted {
            return sys.spawn!(Config.detached, ConsoleWriter)();
        }();

        // The job is built on the driver thread. The collector's
        // address is written into the job after its spawn: the collector
        // copies the job struct at construction, and the coordinator reads
        // the field only in start(job), dispatched by blockUntilReport -
        // i.e. after the mutation.
        AnalyzerJob job;
        job.env = env;
        job.args = iwyuArgs;
        job.fileIncludeFilter = env.conf.staticCode.fileIncludeFilter;
        job.fileExcludeFilter = env.conf.staticCode.fileExcludeFilter;
        job.console = writer.weakRef;
        job.limiter = limiter.weakRef;
        job.mergeIwyu = &mergeIwyu;

        auto collector = () @trusted {
            return sys.spawn!(ResultCollector!(IwyuWork*))(job, writer.weakRef);
        }();
        job.collector = collector.weakRef;

        auto coord = () @trusted {
            return sys.spawn!(JobCoordinator!(IwyuWorker, IwyuWork*))();
        }();

        // `&sys` escapes the frame only for the duration of the helper (the
        // contract: the system outlives the parked request), so the @safe
        // escape check is bridged here like the spawns above.
        result_ = () @trusted {
            return blockUntilReport(&sys, coord.weakRef, collector.weakRef, job);
        }();
    }

    override void tearDown() {
    }

    override Result result() {
        return result_;
    }
}

// TODO: refactor this so a global is not used by e.g. changing mergeIwyu.
/// Set once the once-per-run "iwyu suggested improvements" message has been
/// emitted. __gshared because the collector's merges are serialized (a
/// worker pops an actor, executes it, then puts it back) but not pinned to
/// one thread: the pool schedules each merge on any worker, and D
/// module-level variables are thread-local by default, so a plain bool
/// re-emits the message once per pool thread. execute() resets it on the
/// main thread before the run starts, so once-per-run is once-per-run.
private __gshared bool logged_failure;

/// @safe code may not touch __gshared, so these trusted shims gate the only
/// accesses. Sound because the accesses are serialized: the collector's
/// merges run one at a time (a worker pops an actor, executes it, then puts
/// it back), and execute()'s reset runs before the run's first merge.
private bool loggedFailure() @trusted nothrow {
    return logged_failure;
}

private void markLoggedFailure() @trusted nothrow {
    logged_failure = true;
}

package void resetLoggedFailure() @trusted nothrow {
    logged_failure = false;
}

/// Merge one iwyu file result into the aggregate run result.
///
/// Per-file console prints and file-sink logging live in the
/// ConsoleWriter/collector in code_checker.engine.actor_engine. Runs on the
/// ResultCollector actor's thread through the job's mergeIwyu function
/// pointer.
private void mergeIwyu(ref Result result_, IwyuResult res) @safe nothrow {
    import std.format : format;
    import code_checker.engine.types : Msg, MsgSeverity, Status, mergeStatus;

    // seems like 2 also means OK.
    const allIsOk = res.exitStatus == 0 || res.exitStatus == 2;

    if (!allIsOk)
        result_.score -= res.exitStatus > 0 ? res.exitStatus : 0;

    if (!allIsOk) {
        result_.failed ~= res.file;

        if (!loggedFailure()) {
            result_.msg ~= Msg(MsgSeverity.failReason, "iwyu suggested improvements");
            markLoggedFailure();
        }

        try {
            result_.msg ~= Msg(MsgSeverity.improveSuggestion,
                    format("iwyu: %s in %s", res.exitStatus, res.file));
        } catch (Exception e) {
            logger.warning(e.msg).collectException;
            logger.warning("Unable to add user message to the result").collectException;
        }

        result_.status = mergeStatus(result_.status, Status.failed);
    }
}

/// The result of one include-what-you-use run.
public struct IwyuResult {
    AbsolutePath file;

    /// Exit status from running iwyu.
    int exitStatus;
    /// Captured output from iwyu.
    string[] output;

    void print() @safe nothrow const scope {
        import std.stdio : writeln;

        foreach (l; output)
            try {
                writeln(l);
            } catch (Exception e) {
            }
    }
}

public struct IwyuWork {
    string[] args;
    AbsolutePath file;
}
