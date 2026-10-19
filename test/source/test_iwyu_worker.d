/**
Copyright: Copyright (c) 2021, Joakim Brännström. All rights reserved.
License: $(LINK2 http://www.boost.org/LICENSE_1_0.txt, Boost Software License 1.0)

Unit tests for the IwyuWorker one-shot actor (engine/actor_engine.d): the
analyzers' `taskIwyu` body as a typed actor - the success and
exit-status classification paths (0 and 2 are OK, 1 is not), the onException
liveness backstop, and the coordinator-requested exit (stop()).

The worker is driven in its own actor system with stub collector/limiter
actors; the tool itself is a fake shell script in the sandbox (the same trick
as testdata/robustness/tool_failure/fejk_clang_tidy.sh).
*/
module test_iwyu_worker;

import core.sync.mutex : Mutex;
import core.thread : Thread;
import core.time : msecs;
import std.algorithm : canFind;
import std.exception : enforce;
import std.file : setAttributes, write;
import std.format : format;
import std.sumtype : match;

import code_checker.engine.actor_engine;
import code_checker.engine.builtin.include_what_you_use : IwyuResult, IwyuWork;
import code_checker.engine.types : Result;

import my.actor : RequestResult, WeakAddress;
import my.actor.behavior : ActorRef;
import my.actor.channel : dynSend;
import my.actor.common : ExitReason;
import my.actor.mailbox : TypedAddress;
import my.actor.msg : sendExit;
import my.actor.system : makeSystem;
import my.actor.utility.limiter : IFlowControl, Token;
import my.path : AbsolutePath;

import config : TestArea, makeTestArea;
import code_checker.testing : Serial;

/// Thread-safe event log, the same pattern as the coordinator tests' Recorder.
final class WorkerRecorder {
    import core.sync.mutex : Mutex;
    import std.algorithm : startsWith;

    private Mutex mtx_;
    private string[] events_;

    this() @safe {
        mtx_ = new Mutex;
    }

    void add(string e) @trusted {
        synchronized (mtx_)
            events_ ~= e;
    }

    size_t countWith(string prefix) @trusted {
        synchronized (mtx_) {
            size_t n;
            foreach (e; events_)
                if (e.startsWith(prefix))
                    n++;
            return n;
        }
    }

    string[] snapshot() @trusted {
        synchronized (mtx_)
            return events_.dup;
    }

    private ImmutableFileResult[] payloads_;

    void addPayload(ImmutableFileResult p) @trusted {
        synchronized (mtx_)
            payloads_ ~= p;
    }

    /// The recorded fileDone payloads, in arrival order.
    ImmutableFileResult[] payloads() @trusted {
        synchronized (mtx_)
            return payloads_.dup;
    }
}

final class StubCollector : IResultCollector {
    private WorkerRecorder rec_;

    this(WorkerRecorder rec) @safe {
        rec_ = rec;
    }

    void begin(size_t expected) @safe {
        rec_.add("begin");
    }

    void fileDone(ImmutableFileResult res) @trusted {
        rec_.add("fileDone");
        rec_.addPayload(res);
    }

    void missing(string msg, int scorePenalty, bool abort) @safe {
        rec_.add("missing");
    }

    /// Not wired in this module's scenarios (the DownMsg backstop is
    /// exercised in test_result_collector.d); no-op to satisfy the interface.
    void watching(WeakAddress worker, ImmutableFileResult ifDead) @safe {
    }

    RequestResult!Result report() @safe {
        rec_.add("report");
        return RequestResult!Result(Result.init);
    }
}

final class StubLimiter : IFlowControl {
    private WorkerRecorder rec_;

    this(WorkerRecorder rec) @safe {
        rec_ = rec;
    }

    RequestResult!Token takeToken() @safe {
        rec_.add("takeToken");
        return RequestResult!Token(Token.init);
    }

    void returnToken() @safe {
        rec_.add("returnToken");
    }

    void refresh() @safe {
    }

    void tickRefresh() @safe {
    }
}

private void withQuietLogger(void delegate() run) @trusted {
    import logger = std.experimental.logger;
    import std.experimental.logger.nulllogger : NullLogger;

    auto saved = logger.sharedLog;
    scope (exit)
        logger.sharedLog = saved;
    logger.sharedLog = cast(shared) new NullLogger;
    run();
}

/// Writes a fake iwyu into the sandbox and returns its path. The worker runs
/// it as `tool <args...>` with the analyzed file last (IwyuWork.args).
private string writeFakeTool(TestArea ta, string body) @safe {
    const tool = ta.inSandboxPath("fejk_iwyu.sh");
    write(tool, "#!/bin/bash\n" ~ body);
    setAttributes(tool, 493 /* 0o755 */ );
    return tool;
}

private IwyuWork* mkWork(string tool, string file) @safe {
    auto w = new IwyuWork([tool, file], AbsolutePath(file));
    return w;
}

private struct WorkerScenario {
    WorkerRecorder rec;
    TypedAddress!StubCollector collector;
    TypedAddress!StubLimiter limiter;
}

/// The stub collector/limiter are spawned in the same system (their
/// addresses must be registered there); the payloads land in the shared
/// recorder. `beforeDrain` runs right after the spawn (e.g. to signal a
/// requested exit before the worker's first tick - that ordering relies on
/// the spawn→first-tick handoff (the pool worker only wakes on its poll
/// interval or a watcher notify); the workers' reported_/stopped_ guards make
/// both message orders valid). The drain only bounds event collection: a
/// worker that delivers its report but never self-exits is caught by the
/// watchdog around sys.wait() below, which fails the test loudly instead of
/// hanging the suite (sys.wait has no timeout).
private WorkerScenario driveIwyuWorker(alias Worker)(TestArea ta, IwyuWork* work,
        scope void delegate(WorkerScenario sc, TypedAddress!Worker worker) beforeDrain = null) {
    auto sc = WorkerScenario(new WorkerRecorder,
            TypedAddress!StubCollector.init, TypedAddress!StubLimiter.init);
    withQuietLogger({
        auto sys = makeSystem;
        sc.collector = sys.spawn!StubCollector(sc.rec);
        sc.limiter = sys.spawn!StubLimiter(sc.rec);
        auto worker = sys.spawn!Worker(sc.collector.weakRef, sc.limiter.weakRef, work);
        if (beforeDrain !is null)
            beforeDrain(sc, worker);

        // Drain until the recorder has seen at least one event and then goes
        // quiet, verbatim from the coordinator's scenario runner
        // (test_job_coordinator.d runScenario) - but the quiet break
        // additionally requires at least one event: the first scenario in the
        // process pays one-time start costs (pool spin-up, cold bash) and may
        // legitimately be silent for its first windows.
        size_t last;
        foreach (_; 0 .. 40) {
            last = sc.rec.countWith("");
            Thread.sleep(50.msecs);
            if (last > 0 && sc.rec.countWith("") == last)
                break;
        }
        const quiet = sc.rec.countWith("");
        Thread.sleep(75.msecs);
        enforce(sc.rec.countWith("") == quiet, "late events after the scenario went quiet");

        // sys.wait() has no timeout: bound it with a watchdog so a liveness
        // regression (a worker that delivers its report but never self-exits)
        // fails the test loudly instead of hanging the suite. This druntime's
        // Thread has no timed join and core.sync has no timed wait, so poll a
        // mutex-guarded flag (synchronized gives the memory barriers).
        auto mtx = new Mutex;
        auto exited = false;
        auto waiter = new Thread(() @trusted {
            (&sys).wait();
            synchronized (mtx)
                exited = true;
        });
        waiter.start();
        foreach (_; 0 .. 100) {
            Thread.sleep(100.msecs);
            synchronized (mtx) {
                if (exited)
                    break;
            }
        }
        bool done_;
        synchronized (mtx)
            done_ = exited;
        enforce(done_,
            "the system did not shut down within 10s - a worker never "
            ~ "self-exited (liveness regression)");
    });
    return sc;
}

/// The exitStatus of the single iwyu payload in `res`.
private int iwyuExitStatus(ImmutableFileResult res) @safe {
    return res.match!((IwyuResult r) => r.exitStatus, (_) {
        assert(false, "expected an iwyu payload");
        return int.init;
    });
}

@("worker: success path - exactly one fileDone, one token return, then exits")
@Serial unittest {
    auto ta = makeTestArea;
    const file = ta.inSandboxPath("b1.cpp");
    const tool = writeFakeTool(ta, "echo hi-iwyu\necho err-iwyu >&2\nexit 0\n");
    auto sc = driveIwyuWorker!IwyuWorker(ta, mkWork(tool, file));

    assert(sc.rec.countWith("fileDone") == 1, format("events: %s", sc.rec.snapshot));
    assert(sc.rec.countWith("returnToken") == 1, format("events: %s", sc.rec.snapshot));

    auto payloads = sc.rec.payloads;
    assert(payloads.length == 1, format("payloads: %s", payloads.length));
    assert(iwyuExitStatus(payloads[0]) == 0, format("exitStatus: %s",
            iwyuExitStatus(payloads[0])));
    payloads[0].match!((IwyuResult r) {
        assert(r.file == AbsolutePath(file), format("file: %s", r.file));
        assert(r.output.canFind("hi-iwyu"), format("output: %s", r.output));
        assert(r.output.canFind("err-iwyu"), format("stderr: %s", r.output));
    }, (_) { assert(false, "expected an iwyu payload"); });
}

@("worker: tool failure - exitStatus 1")
@Serial unittest {
    auto ta = makeTestArea;
    const file = ta.inSandboxPath("b2.cpp");
    const tool = writeFakeTool(ta, "exit 1\n");
    auto sc = driveIwyuWorker!IwyuWorker(ta, mkWork(tool, file));

    assert(sc.rec.countWith("fileDone") == 1, format("events: %s", sc.rec.snapshot));
    assert(sc.rec.countWith("returnToken") == 1);

    auto payloads = sc.rec.payloads;
    assert(payloads.length == 1);
    payloads[0].match!((IwyuResult r) {
        assert(r.exitStatus == 1, format("exitStatus: %s", r.exitStatus));
        assert(r.file == AbsolutePath(file), format("file: %s", r.file));
    }, (_) { assert(false, "expected an iwyu payload"); });
}

@("worker: exit status 2 also means OK")
@Serial unittest {
    auto ta = makeTestArea;
    const file = ta.inSandboxPath("b3.cpp");
    const tool = writeFakeTool(ta, "exit 2\n");
    auto sc = driveIwyuWorker!IwyuWorker(ta, mkWork(tool, file));

    auto payloads = sc.rec.payloads;
    assert(payloads.length == 1);
    assert(iwyuExitStatus(payloads[0]) == 2, format("exitStatus: %s",
            iwyuExitStatus(payloads[0])));
    assert(sc.rec.countWith("returnToken") == 1);
}

private static class ThrowingWorker : IwyuWorker {
    this(WeakAddress collector, WeakAddress limiter, IwyuWork* work) @safe {
        super(collector, limiter, work);
    }

    override void run() @trusted {
        throw new Exception("bang");
    }
}

@("worker: handler exception - onException delivers one failed fileDone + exit")
@Serial unittest {
    auto ta = makeTestArea;
    const file = ta.inSandboxPath("b4.cpp");
    const tool = writeFakeTool(ta, "exit 0\n");
    auto sc = driveIwyuWorker!ThrowingWorker(ta, mkWork(tool, file));

    // The backstop reports a failed result instead of hanging the collector.
    auto payloads = sc.rec.payloads;
    assert(payloads.length == 1, format("events: %s", sc.rec.snapshot));
    payloads[0].match!((IwyuResult r) {
        assert(r.exitStatus == 0, "the backstop reports the silent-OK flavor for a never-run file");
        assert(r.file == AbsolutePath(file));
    }, (_) { assert(false, "expected an iwyu payload"); });
    assert(sc.rec.countWith("returnToken") == 1);
}

@("worker: requested exit - exactly one fileDone, no double-report")
@Serial unittest {
    auto ta = makeTestArea;
    const file = ta.inSandboxPath("b5.cpp");
    const tool = writeFakeTool(ta, "touch " ~ ta.inSandboxPath("sentinel") ~ "\nexit 0\n");
    auto sc = driveIwyuWorker!IwyuWorker(ta, mkWork(tool, file), (sc, worker) {
        // The coordinator's chStop abort path, signalled right after the
        // spawn. Which message wins the spawn→first-tick race is not
        // deterministic: if "stop" is dequeued first, run never fires (the
        // sentinel stays absent, abort flavor); if the pool worker's first
        // tick wins, the tool runs (the sentinel appears) and the
        // already-reported/stopped_ guards turn "stop" into a no-op (success
        // flavor). Both orders must deliver exactly one fileDone and one exit.
        dynSend(worker.weakRef, "stop");
    });

    auto payloads = sc.rec.payloads;
    assert(payloads.length == 1, format("events: %s", sc.rec.snapshot));
    payloads[0].match!((IwyuResult r) {
        assert(r.exitStatus == 0, format("flavor: %s", r.exitStatus));
        assert(r.file == AbsolutePath(file));
    }, (_) { assert(false, "expected an iwyu payload"); });
    assert(sc.rec.countWith("returnToken") == 1);
}

@("worker: sendExit(userShutdown) to a spawned worker - one success report, no double-report")
@Serial unittest {
    auto ta = makeTestArea;
    const file = ta.inSandboxPath("b6.cpp");
    const tool = writeFakeTool(ta, "exit 0\n");
    auto sc = driveIwyuWorker!IwyuWorker(ta, mkWork(tool, file), (sc, worker) {
        // The default exit handler (no onExit hook) force-shuts the worker
        // and the already-queued run() is still dispatched (processIncoming
        // has no state guard) in whatever order the spawn→first-tick handoff
        // produces - the worker reports its success result exactly once.
        sendExit(worker.weakRef, ExitReason.userShutdown);
    });

    auto payloads = sc.rec.payloads;
    assert(payloads.length == 1, format("events: %s", sc.rec.snapshot));
    assert(iwyuExitStatus(payloads[0]) == 0);
    assert(sc.rec.countWith("returnToken") == 1);
}
