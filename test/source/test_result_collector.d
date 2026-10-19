/**
Copyright: Copyright (c) 2021, Joakim Brännström. All rights reserved.
License: $(LINK2 http://www.boost.org/LICENSE_1_0.txt, Boost Software License 1.0)

Unit tests for the ResultCollector and ConsoleWriter actors
(engine/actor_engine.d): the per-file fan-in (progress line, verbatim merge,
file-sink logging, output events), the report() answer semantics (park or
immediate, exactly once), the prep-abort missing() mutation, the onException
backstop, and the writer's stdout emission rules.

FIFO invariant (no dedicated test): the coordinator sends begin() before the
first worker is spawned (asserted in test_job_coordinator.d), so a collector
can never see fileDone before begin - it holds by construction.
*/
module test_result_collector;

import core.sync.mutex : Mutex;
import core.thread : Thread;
import core.time : dur, msecs;
import std.algorithm : canFind, joiner, startsWith;
import std.datetime : Clock;
import std.exception : enforce;
import std.file : exists, readText;
import std.format : format;
import std.path : buildPath, pathSplitter;
import my.path : AbsolutePath, Path;
import code_checker.cli : Config;
import code_checker.engine.actor_engine;
import code_checker.engine.types : Environment, MsgSeverity, Result, Status;
import code_checker.engine.builtin.clang_tidy : TidyResult, TidyWork;
import code_checker.engine.builtin.include_what_you_use : IwyuResult, IwyuWork;
import std.string : indexOf;
import std.typecons : Tuple;

import my.actor : RequestResult, WeakAddress;
import my.actor.behavior : ActorRef;
import my.actor.msg : capture, infTimeout;
import my.actor.channel : dynRequest, dynSend;
import std.range : dropOne;
import std.utf : toUTF8;

import my.actor.system : ActorShell, makeAddress, makeSystem;
import config : TestArea;
import config : makeTestArea;

import code_checker.testing : Serial;

final class Recorder {
    private Mutex mtx;
    private string[] events_;
    private size_t fileDoneCount_, noticeCount_;

    this() {
        mtx = new Mutex;
    }

    void add(string e) @trusted {
        synchronized (mtx) {
            events_ ~= e;
            if (e.startsWith("fileDone:"))
                fileDoneCount_++;
            else if (e.startsWith("notice:"))
                noticeCount_++;
        }
    }

    size_t fileDoneCount() @safe {
        synchronized (mtx)
            return fileDoneCount_;
    }

    size_t noticeCount() @safe {
        synchronized (mtx)
            return noticeCount_;
    }

    string firstWith(string prefix) @safe {
        synchronized (mtx) {
            foreach (e; events_)
                if (e.startsWith(prefix))
                    return e;
        }
        return "";
    }

    size_t totalEvents() @safe {
        synchronized (mtx)
            return events_.length;
    }

    string[] snapshot() @safe {
        synchronized (mtx)
            return events_.dup;
    }

    size_t countWith(string prefix) @safe {
        synchronized (mtx) {
            size_t n;
            foreach (e; events_)
                if (e.startsWith(prefix))
                    n++;
            return n;
        }
    }
}

final class StubWriter : IConsoleWriter {
    private Recorder rec_;

    this(Recorder rec) @safe {
        rec_ = rec;
    }

    void fileDone(FileOutputEvent ev) @safe {
        rec_.add("fileDone:" ~ ev.progressLine);
    }

    void notice(MsgSeverity severity, string msg) @safe {
        rec_.add("notice:" ~ msg);
    }
}

private void withQuietLogger(void delegate() @safe run) @trusted {
    import logger = std.experimental.logger;
    import std.experimental.logger.nulllogger : NullLogger;

    auto saved = logger.sharedLog;
    scope (exit)
        logger.sharedLog = saved;
    logger.sharedLog = cast(shared) new NullLogger;
    run();
}

/// Like withQuietLogger, but the logger writes to stdout so captureStdout
/// can grab the writer's emission. The writer's own level gating (trace
/// passes only at log level all) is driven by the globalLogLevel in the test.
private void withStdoutLogger(void delegate() @safe run) @trusted {
    import std.experimental.logger.filelogger : FileLogger;
    import std.stdio : stdout;
    import logger = std.experimental.logger;

    auto saved = logger.sharedLog;
    scope (exit)
        logger.sharedLog = saved;
    logger.sharedLog = cast(shared) new FileLogger(stdout);
    run();
}

private __gshared Mutex captureGate;
shared static this() {
    captureGate = new Mutex;
}

// TODO: change the implementation so capture of stdout is not needed but
// rather that the writer take a sink.
private string captureStdout(void delegate() @safe run) @trusted {
    import core.sys.posix.unistd : STDERR_FILENO, STDOUT_FILENO, close, dup, dup2, pipe, read;
    import std.stdio : stdout;

    // Only one capture window may be active process-wide. Overlapping
    // captures corrupt each other's saved/redirected fd 1/2: the second
    // capture's dup(STDOUT_FILENO) can snapshot the first one's pipe write
    // end instead of stdout, and the interleaved restores can leave that
    // pipe write end on fd 1/2 (so a later capture restores it instead of
    // stdout, or the drain below never sees EOF and blocks forever).
    // @Serial only serializes tests within one module; different modules'
    // test composites run concurrently, so gate here.
    synchronized (captureGate) {
        int[2] fds;
        if (pipe(fds) != 0)
            assert(false, "pipe failed");

        const savedOut = dup(STDOUT_FILENO);
        const savedErr = dup(STDERR_FILENO);

        scope (failure) {
            dup2(savedOut, STDOUT_FILENO);
            dup2(savedErr, STDERR_FILENO);
            close(savedOut);
            close(savedErr);
            close(fds[0]);
        }

        dup2(fds[1], STDOUT_FILENO);
        dup2(fds[1], STDERR_FILENO);
        close(fds[1]);

        run();
        stdout.flush;

        // restore before draining: only when no fd holds the pipe's write
        // end does the read below see EOF
        dup2(savedOut, STDOUT_FILENO);
        close(savedOut);
        dup2(savedErr, STDERR_FILENO);
        close(savedErr);

        string captured;
        ubyte[4096] buf;
        for (;;) {
            const n = read(fds[0], buf.ptr, buf.length);
            if (n <= 0)
                break;
            captured ~= cast(char[]) buf[0 .. n];
        }
        close(fds[0]);
        return captured;
    }
}

private Environment mkEnv(TestArea ta, bool toFile = false) @safe {
    Environment env;
    env.conf = Config.make(Path(ta.sandboxPath).AbsolutePath, Path(ta.sandboxPath).AbsolutePath);
    env.compileDbFile = Path(ta.sandboxPath).AbsolutePath;
    env.conf.logg.toFile = toFile;
    // Config.make leaves logg.dir empty; the real pipeline sets it from the
    // config file. Point the sink at the sandbox so the files are findable.
    env.conf.logg.dir = Path(ta.sandboxPath).AbsolutePath;
    return env;
}

private void mergeTidyTest(ref Result result_, TidyResult res) @safe {
    import code_checker.engine.types : mergeStatus;

    result_.score += res.errors.score;
    if (res.clangTidyStatus == 0) {
        result_.success ~= res.file;
        result_.status = mergeStatus(result_.status, Status.passed);
    } else {
        result_.failed ~= res.file;
        result_.status = mergeStatus(result_.status, Status.failed);
    }
}

private void mergeIwyuTest(ref Result result_, IwyuResult res) @safe {
    import code_checker.engine.types : mergeStatus;

    const allIsOk = res.exitStatus == 0 || res.exitStatus == 2;
    if (!allIsOk) {
        result_.score -= res.exitStatus > 0 ? res.exitStatus : 0;
        result_.failed ~= res.file;
        result_.status = mergeStatus(result_.status, Status.failed);
    }
}

private void mergeTidyThrows(ref Result, TidyResult) @safe {
    throw new Exception("merge exploded");
}

private AnalyzerJob mkCollectorJob(Environment env, void function(ref Result,
        TidyResult) @safe mergeTidy = &mergeTidyTest, void function(ref Result,
        IwyuResult) @safe mergeIwyu = &mergeIwyuTest) @safe {
    AnalyzerJob job;
    job.env = env;
    job.mergeTidy = mergeTidy;
    job.mergeIwyu = mergeIwyu;
    return job;
}

private TidyResult mkTidyResult(string file, int status, string[] output = []) @safe {
    import my.path : AbsolutePath;

    TidyResult r;
    r.file = AbsolutePath(file);
    r.clangTidyStatus = status;
    r.output = output;
    return r;
}

private IwyuResult mkIwyuResult(string file, int exitStatus, string[] output = [
]) @safe {
    import my.path : AbsolutePath;

    IwyuResult r;
    r.file = AbsolutePath(file);
    r.exitStatus = exitStatus;
    r.output = output;
    return r;
}

/// The expected progress lines, verbatim from the engine's progressLine.
private string progressTidy(string file, size_t n, size_t m) @safe {
    import colorlog : Color, Background, color;

    return format("%s/%s %s '%s'", n, m,
            "clang-tidy analyzed".color(Color.yellow).bg(Background.black), file);
}

private string progressIwyu(string file) @safe {
    import colorlog : Color, Background, color;

    return format("%s '%s'", "iwyu analyzing".color(Color.yellow).bg(Background.black), file);
}

/// The clang-tidy per-file sink name, verbatim from the engine logger
private string logFileFor(const AbsolutePath f, string logdir) @safe {
    return buildPath(logdir, f.dup.dropOne.pathSplitter.joiner("_").toUTF8 ~ ".txt");
}

/// Spawns a ResultCollector!Payload with a StubWriter in its own system,
/// sends begin(expected) and the report() request (which parks the client),
/// then hands the collector's address to `sendDones` for the per-file
/// messages. Returns the merged Result once the report() request is
/// answered.
private Result runCollectorScenario(Payload)(Recorder rec, Environment env,
        AnalyzerJob job, size_t expected, scope void delegate(WeakAddress) @safe sendDones) @trusted {
    auto sys = makeSystem;
    auto writer = sys.spawn!StubWriter(rec);
    auto collector = sys.spawn!(ResultCollector!Payload)(job, writer.weakRef);

    dynSend(collector.weakRef, "begin", expected);

    auto client = ActorShell(makeAddress);
    bool replied_;
    Result got;

    static void onReport(ref Tuple!(bool*, Result*) ctx, Result r) @safe {
        *ctx[0] = true;
        *ctx[1] = r;
    }

    dynRequest(ActorRef(&client), collector.weakRef, infTimeout(), "report").capture(
            &replied_, &got).then(&onReport);

    sendDones(collector.weakRef);

    // Pump the client kernel until the report() request is answered.
    const deadline = Clock.currTime + 5.dur!"seconds";
    while (!replied_ && Clock.currTime < deadline) {
        client.process(Clock.currTime);
        Thread.sleep(1.msecs);
    }
    enforce(replied_, "the collector never answered the report() request");

    // Drain until the recorder is stable, then make late dispatch LOUD,
    // verbatim from the coordinator's scenario runner.
    size_t last;
    foreach (_; 0 .. 10) {
        last = rec.totalEvents;
        Thread.sleep(50.msecs);
        if (rec.totalEvents == last)
            break;
    }
    const quiet = rec.totalEvents;
    Thread.sleep(75.msecs);
    enforce(rec.totalEvents == quiet,
            format("late events after the scenario went quiet: %s -> %s", quiet, rec.totalEvents));

    sys.wait();
    return got;
}

@("collector: merges tidy results, forwards output events, answers report() once")
@Serial unittest {
    auto ta = makeTestArea;
    const file1 = buildPath(ta.sandboxPath, "a1.cpp");
    const file2 = buildPath(ta.sandboxPath, "a2.cpp");

    auto rec = new Recorder;
    auto env = mkEnv(ta, true);
    auto job = mkCollectorJob(env);

    Result result_;
    void sendDones(WeakAddress collector) @safe {
        dynSend(collector, "fileDone", ImmutableFileResult(mkTidyResult(file1, 1, [
            "OUT1"
        ])));
        dynSend(collector, "fileDone", ImmutableFileResult(mkTidyResult(file2, 0)));
    }

    withQuietLogger(delegate() @safe {
        result_ = runCollectorScenario!(TidyWork*)(rec, env, job, 2, &sendDones);
    });
    const result = result_;

    assert(result.status == Status.failed, format("status: %s", result.status));
    assert(result.failed == [AbsolutePath(file1)], "the failing file is recorded");
    assert(result.success == [AbsolutePath(file2)], "the passing file is recorded");
    assert(rec.fileDoneCount == 2, "the writer got both output events");
    assert(rec.countWith("notice:") == 0, "no notices in the happy path");

    // The progress lines, in send order, with the n/m counters.
    const snap = rec.snapshot;
    assert(snap.length == 2, format("events: %s", snap));
    assert(snap[0] == "fileDone:" ~ progressTidy(file1, 1, 2),
            format("first progress line: %s", snap[0]));
    assert(snap[1] == "fileDone:" ~ progressTidy(file2, 2, 2),
            format("second progress line: %s", snap[1]));

    // The failing file's tool output is logged to the file sink.
    const logFile = logFileFor(AbsolutePath(file1), ta.sandboxPath);
    assert(exists(logFile), "the tool output is logged to the file sink");
    assert(readText(logFile) == "OUT1\n", format("file sink content: %s", readText(logFile)));
}

@("collector: merges iwyu results and logs failing runs to the .iwyu sink")
@Serial unittest {
    auto ta = makeTestArea;
    const file1 = buildPath(ta.sandboxPath, "a1.cpp");

    auto rec = new Recorder;
    auto env = mkEnv(ta, true);
    auto job = mkCollectorJob(env);

    Result result_;
    void sendDones(WeakAddress collector) @safe {
        dynSend(collector, "fileDone", ImmutableFileResult(mkIwyuResult(file1, 3, [
            "IWYU-OUT"
        ])));
    }

    withQuietLogger(delegate() @safe {
        result_ = runCollectorScenario!(IwyuWork*)(rec, env, job, 1, &sendDones);
    });
    const result = result_;

    assert(result.score == -3, format("score: %s", result.score));
    assert(result.status == Status.failed, "the failing exit status decides the status");
    assert(result.failed == [AbsolutePath(file1)], "the failing file is recorded");
    assert(result.success.length == 0, "no passing files");

    const snap = rec.snapshot;
    assert(snap.length == 1, format("events: %s", snap));
    assert(snap[0] == "fileDone:" ~ progressIwyu(file1), format("progress line: %s", snap[0]));

    // The failing run's output goes to the file sink. The engine's Logger.put
    // derives the file name itself (flattens the path, appends .txt), so the
    // .iwyu suffix is only visible in the flattened name.
    const logFile = logFileFor(AbsolutePath(file1 ~ ".iwyu"), ta.sandboxPath);
    assert(exists(logFile), "the failing run's output is logged");
    assert(readText(logFile) == "IWYU-OUT\n", format("sink content: %s", readText(logFile)));
}

@("collector: a throwing merge is answered with a failed result exactly once")
@Serial unittest {
    auto ta = makeTestArea;
    const file1 = buildPath(ta.sandboxPath, "a1.cpp");

    auto rec = new Recorder;
    auto env = mkEnv(ta);
    auto job = mkCollectorJob(env, &mergeTidyThrows);

    Result result_;
    void sendDones(WeakAddress collector) @safe {
        dynSend(collector, "fileDone", ImmutableFileResult(mkTidyResult(file1, 1)));
    }

    withQuietLogger(delegate() @safe {
        result_ = runCollectorScenario!(TidyWork*)(rec, env, job, 1, &sendDones);
    });
    const result = result_;

    assert(result.status == Status.failed, "the failed result is reported");
    assert(rec.fileDoneCount == 1, "the progress line + output event reach the writer even when the merge throws (the engine prints the progress line before the merge body runs)");

    // The exception's message is carried in the aggregate for the user.
    bool found;
    foreach (m; result.msg.value)
        if (m.value == "internal error: merge exploded")
            found = true;
    assert(found, "the internal error message is carried in the aggregate");
}

@("collector: an extra fileDone after completion cannot double-answer report()")
@Serial unittest {
    auto ta = makeTestArea;
    const file1 = buildPath(ta.sandboxPath, "a1.cpp");

    auto rec = new Recorder;
    auto env = mkEnv(ta);
    auto job = mkCollectorJob(env);

    Result result_;
    void sendDones(WeakAddress collector) @safe {
        dynSend(collector, "fileDone", ImmutableFileResult(mkTidyResult(file1, 0)));
        // Racy in principle (the exit may land in between), but the collector
        // answers report() at most once either way: the promise is released on
        // delivery, so the second fileDone can only merge into the aggregate.
        dynSend(collector, "fileDone", ImmutableFileResult(mkTidyResult(file1, 0)));
    }

    withQuietLogger(delegate() @safe {
        result_ = runCollectorScenario!(TidyWork*)(rec, env, job, 1, &sendDones);
    });
    const result = result_;

    assert(result.status == Status.passed, "the passing run decides the status");
    assert(result.success == [AbsolutePath(file1)], "the file is recorded");
    assert(rec.fileDoneCount >= 1, "at least the first output event is forwarded");
}

/// Mirrors runCollectorScenario, but sends the report() request BEFORE
/// begin(): the driver fires its report() request right after start(job)
/// (fire-and-forget), while begin(expected) only follows prep()'s
/// compile-db iteration - in any realistic interleaving the report() request
/// lands first, and the collector must park until begin + fileDone arrive.
private Result runReportFirstScenario(Payload)(Recorder rec, Environment env,
        AnalyzerJob job, scope void delegate(WeakAddress) @safe sendBeginAndDones) @trusted {
    auto sys = makeSystem;
    auto writer = sys.spawn!StubWriter(rec);
    auto collector = sys.spawn!(ResultCollector!Payload)(job, writer.weakRef);

    auto client = ActorShell(makeAddress);
    bool replied_;
    Result got;

    static void onReport(ref Tuple!(bool*, Result*) ctx, Result r) @safe {
        *ctx[0] = true;
        *ctx[1] = r;
    }

    dynRequest(ActorRef(&client), collector.weakRef, infTimeout(), "report").capture(
            &replied_, &got).then(&onReport);

    sendBeginAndDones(collector.weakRef);

    // Pump the client kernel until the report() request is answered.
    const deadline = Clock.currTime + 5.dur!"seconds";
    while (!replied_ && Clock.currTime < deadline) {
        client.process(Clock.currTime);
        Thread.sleep(1.msecs);
    }
    enforce(replied_, "the collector never answered the report() request");

    // Drain until the recorder is stable, then make late dispatch LOUD,
    // verbatim from the coordinator's scenario runner.
    size_t last;
    foreach (_; 0 .. 10) {
        last = rec.totalEvents;
        Thread.sleep(50.msecs);
        if (rec.totalEvents == last)
            break;
    }
    const quiet = rec.totalEvents;
    Thread.sleep(75.msecs);
    enforce(rec.totalEvents == quiet,
            format("late events after the scenario went quiet: %s -> %s", quiet, rec.totalEvents));

    sys.wait();
    return got;
}

@("collector: report() before begin() parks until begin + fileDone arrive")
@Serial unittest {
    auto ta = makeTestArea;
    const file1 = buildPath(ta.sandboxPath, "a1.cpp");

    auto rec = new Recorder;
    auto env = mkEnv(ta);
    auto job = mkCollectorJob(env);

    Result result_;
    void sendBeginAndDones(WeakAddress collector) @safe {
        size_t expected = 1;
        dynSend(collector, "begin", expected);
        dynSend(collector, "fileDone", ImmutableFileResult(mkTidyResult(file1, 0)));
    }

    withQuietLogger(delegate() @safe {
        result_ = runReportFirstScenario!(TidyWork*)(rec, env, job, &sendBeginAndDones);
    });
    const result = result_;

    assert(result.status == Status.passed, "the parked request is answered after begin + fileDone");
    assert(result.success == [AbsolutePath(file1)], "the file is recorded");
    assert(rec.fileDoneCount == 1, "the writer got the output event");
    const snap = rec.snapshot;
    assert(snap.length == 1, format("events: %s", snap));
    assert(snap[0] == "fileDone:" ~ progressTidy(file1, 1, 1), format("progress line: %s", snap[0]));
}

@("collector: a prep-abort missing applies the penalty and fails the status")
@Serial unittest {
    auto ta = makeTestArea;
    const file1 = buildPath(ta.sandboxPath, "a1.cpp");

    auto rec = new Recorder;
    auto env = mkEnv(ta);
    auto job = mkCollectorJob(env);

    Result result_;
    void sendDones(WeakAddress collector) @safe {
        dynSend(collector, "missing",
                "clang-tidy was unable to find the file in compile_commands.json", 100, true);
        dynSend(collector, "fileDone", ImmutableFileResult(mkTidyResult(file1, 0)));
    }

    withQuietLogger(delegate() @safe {
        result_ = runCollectorScenario!(TidyWork*)(rec, env, job, 1, &sendDones);
    });
    const result = result_;

    assert(result.score == -100, format("score: %s", result.score));
    assert(result.status == Status.failed, "the abort flag fails the status");
    assert(result.msg.value.length == 0,
            "the message text goes to the writer via notice(), not the aggregate");
    assert(rec.countWith("notice:") == 0, "the collector does not notice; the coordinator does");
}

@("writer: a passing clang-tidy file prints only the progress line")
@Serial unittest {
    string out_;
    withStdoutLogger(delegate() @safe {
        out_ = captureStdout(delegate() @safe {
            (new ConsoleWriter).fileDone(FileOutputEvent(progressTidy("a.cpp",
            1, 1), ImmutableFileResult(mkTidyResult("a.cpp", 0))));
        });
    });

    assert(out_.canFind("1/1 clang-tidy analyzed"), format("output: %s", out_));
    assert(out_.canFind("a.cpp"), "the analyzed file is named");
    assert(!out_.canFind("OUT"), "no tool output for a passing file");
}

@("writer: a failing clang-tidy file prints the progress line then the tool output")
@Serial unittest {
    string out_;
    withStdoutLogger(delegate() @safe {
        out_ = captureStdout(delegate() @safe {
            (new ConsoleWriter).fileDone(FileOutputEvent(progressTidy("a.cpp", 1, 1),
            ImmutableFileResult(mkTidyResult("a.cpp", 1, ["OUT1", "OUT2"]))));
        });
    });

    assert(out_.canFind("1/1 clang-tidy analyzed"), "the progress line comes first");
    assert(out_.canFind("OUT1") && out_.canFind("OUT2"), "the tool output follows");
    assert(out_.indexOf("clang-tidy analyzed") < out_.indexOf("OUT1"),
            "the progress line is emitted before the tool output");
}

@("writer: iwyu output gating")
@Serial unittest {
    string failing_, exit2_, ok_;
    withStdoutLogger(delegate() @safe {
        failing_ = captureStdout(delegate() @safe {
            (new ConsoleWriter).fileDone(FileOutputEvent(progressIwyu("a.cpp"),
            ImmutableFileResult(mkIwyuResult("a.cpp", 1, ["IWYU-OUT"]))));
        });
        exit2_ = captureStdout(delegate() @safe {
            (new ConsoleWriter).fileDone(FileOutputEvent(progressIwyu("a.cpp"),
            ImmutableFileResult(mkIwyuResult("a.cpp", 2))));
        });
        ok_ = captureStdout(delegate() @safe {
            (new ConsoleWriter).fileDone(FileOutputEvent(progressIwyu("a.cpp"),
            ImmutableFileResult(mkIwyuResult("a.cpp", 0))));
        });
    });

    assert(failing_.canFind("iwyu analyzing"), "the progress line is printed");
    assert(failing_.canFind("IWYU-OUT"), "the output of a failing run is printed");

    assert(exit2_.canFind("iwyu analyzing"), "the progress line is printed");
    assert(!exit2_.canFind("IWYU-OUT"), "exit status 2 means OK; no output");

    assert(ok_.canFind("iwyu analyzing"), "the progress line is printed");
    assert(!ok_.canFind("IWYU-OUT"), "no output for a passing run");
}

@("writer: notice dispatches per severity, trace only at log level all")
@Serial unittest {
    import logger = std.experimental.logger;

    string failReason_, suggestion_, traceAtAll_, traceAtInfo_;
    withStdoutLogger(delegate() @safe {
        failReason_ = captureStdout(delegate() @safe {
            (new ConsoleWriter).notice(MsgSeverity.failReason, "boom");
        });
        suggestion_ = captureStdout(delegate() @safe {
            (new ConsoleWriter).notice(MsgSeverity.improveSuggestion, "suggestion");
        });
    });

    // trace passes only when the log level is all (verbatim from the
    // registry's private log body).
    const saved = logger.globalLogLevel;
    scope (exit)
        logger.globalLogLevel = saved;

    withStdoutLogger(delegate() @safe {
        logger.globalLogLevel = logger.LogLevel.all;
        traceAtAll_ = captureStdout(delegate() @safe {
            (new ConsoleWriter).notice(MsgSeverity.trace, "skipping");
        });
        logger.globalLogLevel = logger.LogLevel.info;
        traceAtInfo_ = captureStdout(delegate() @safe {
            (new ConsoleWriter).notice(MsgSeverity.trace, "skipping");
        });
    });

    assert(failReason_.canFind("boom"), "failReason is warned");
    assert(!suggestion_.canFind("suggestion"), "suggestions are not logged at all");
    assert(traceAtAll_.canFind("skipping"), "trace passes at log level all");
    assert(!traceAtInfo_.canFind("skipping"), "trace is dropped below log level all");
}

/// Runs a ResultCollector scenario where one spawned worker dies: the test
/// registers the monitor on behalf of the collector (the same wiring the
/// coordinator uses, IResultCollector.watching) and the DownMsg backstop must
/// complete the run. `workerReportsFirst` sends the worker's real fileDone
/// before killing it (the exactly-once case); otherwise the worker never
/// reports and the backstop is the only receipt for the file.
private Result runDownScenario(Recorder rec, Environment env, AnalyzerJob job,
        string file, bool workerReportsFirst) @trusted {
    import my.actor.common : ExitReason;
    import my.actor.msg : monitor, sendExit;

    auto sys = makeSystem;
    auto writer = sys.spawn!StubWriter(rec);
    auto collector = sys.spawn!(ResultCollector!(TidyWork*))(job, writer.weakRef);

    // A worker that dies without reporting on the test's signal: idle until
    // "die" arrives, so the monitor registration below cannot race the death.
    static class DeadWorker {
        import my.actor.behavior : ActorRef;

        private ActorRef self_;
        void onSpawn(ActorRef self) @safe {
            self_ = self;
        }

        /// Dies without reporting on the test's signal.
        void die() @safe {
            sendExit(self_.address(), ExitReason.userShutdown);
        }
    }

    auto worker = sys.spawn!DeadWorker;

    monitor(collector.weakRef, worker.weakRef);
    dynSend(collector.weakRef, "watching", worker.weakRef,
            ImmutableFileResult(mkTidyResult(file, 1)));

    size_t expected = 1;
    dynSend(collector.weakRef, "begin", expected);

    auto client = ActorShell(makeAddress);
    bool replied_;
    Result got;

    static void onReport(ref Tuple!(bool*, Result*) ctx, Result r) @safe {
        *ctx[0] = true;
        *ctx[1] = r;
    }

    dynRequest(ActorRef(&client), collector.weakRef, infTimeout(), "report").capture(
            &replied_, &got).then(&onReport);

    if (workerReportsFirst) {
        dynSend(collector.weakRef, "fileDone", ImmutableFileResult(mkTidyResult(file, 0)));

        // Deterministic exactly-once setup: wait until the collector has
        // merged the worker's report before killing it - the racy interleaving
        // (die landing before the fileDone is processed) is the documented
        // accepted hole, not this test's target.
        const drainDeadline = Clock.currTime + 5.dur!"seconds";
        while (rec.fileDoneCount < 1 && Clock.currTime < drainDeadline)
            Thread.sleep(1.msecs);
        enforce(rec.fileDoneCount == 1, "the worker's fileDone never reached the writer");
    }

    // Kill the worker: the DownMsg backstop must complete the run (or be
    // skipped when the file was already reported).
    dynSend(worker.weakRef, "die");

    // Pump the client kernel until the report() request is answered.
    const deadline = Clock.currTime + 5.dur!"seconds";
    while (!replied_ && Clock.currTime < deadline) {
        client.process(Clock.currTime);
        Thread.sleep(1.msecs);
    }
    enforce(replied_, "the collector never answered the report() request");

    // Drain until the recorder is stable, then make late dispatch LOUD,
    // verbatim from the coordinator's scenario runner.
    size_t last;
    foreach (_; 0 .. 10) {
        last = rec.totalEvents;
        Thread.sleep(50.msecs);
        if (rec.totalEvents == last)
            break;
    }
    const quiet = rec.totalEvents;
    Thread.sleep(75.msecs);
    enforce(rec.totalEvents == quiet,
            format("late events after the scenario went quiet: %s -> %s", quiet, rec.totalEvents));

    sys.wait();
    return got;
}

@("collector: a worker that dies without replying fails its file via the DownMsg backstop")
@Serial unittest {
    auto ta = makeTestArea;
    const file1 = buildPath(ta.sandboxPath, "a1.cpp");

    auto rec = new Recorder;
    auto env = mkEnv(ta);
    auto job = mkCollectorJob(env);

    Result result_;
    withQuietLogger(delegate() @safe {
        result_ = runDownScenario(rec, env, job, file1, false);
    });
    const result = result_;

    assert(result.status == Status.failed, "the backstop fails the status");
    assert(result.failed == [AbsolutePath(file1)], "the dead worker's file is recorded as failed");
    assert(result.success.length == 0, "no passing files");
    assert(rec.fileDoneCount == 1, "the backstop's result reaches the writer");
}

@("collector: the DownMsg backstop does not double-report a file the worker already reported")
@Serial unittest {
    auto ta = makeTestArea;
    const file1 = buildPath(ta.sandboxPath, "a1.cpp");

    auto rec = new Recorder;
    auto env = mkEnv(ta);
    auto job = mkCollectorJob(env);

    Result result_;
    withQuietLogger(delegate() @safe {
        result_ = runDownScenario(rec, env, job, file1, true);
    });
    const result = result_;

    assert(result.status == Status.passed, "the passing run decides the status");
    assert(result.success == [AbsolutePath(file1)], "the file is recorded once");
    assert(result.failed.length == 0, "no failed files");
    assert(rec.fileDoneCount == 1, "exactly one output event for the file");
}
