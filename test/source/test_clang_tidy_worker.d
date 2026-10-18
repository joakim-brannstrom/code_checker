/**
Copyright: Copyright (c) 2021, Joakim Brännström. All rights reserved.
License: $(LINK2 http://www.boost.org/LICENSE_1_0.txt, Boost Software License 1.0)

Unit tests for the ClangTidyWorker one-shot actor (engine/actor_engine.d): the
analyzers' `taskTidy` body as a typed actor - the success,
tool-failure and warning classification paths, the include-filter suppression,
the filter-regex-error early return, the onException liveness backstop, and the
coordinator-requested exit (stop()).

The worker is driven in its own actor system with stub collector/limiter
actors; the tool itself is a fake shell script in the sandbox (the same trick
as testdata/robustness/tool_failure/fejk_clang_tidy.sh).
*/
module test_clang_tidy_worker;

import core.sync.mutex : Mutex;
import core.thread : Thread;
import core.time : dur, msecs;
import std.algorithm : canFind, startsWith;
import std.datetime : Clock;
import std.exception : enforce;
import std.file : exists, setAttributes, write;
import std.format : format;
import std.sumtype : match;

import code_checker.engine.actor_engine;
import code_checker.engine.builtin.clang_tidy : TidyResult, TidyWork;
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
import unit_threaded.runner.attrs : Serial;

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

/// Writes a fake clang-tidy into the sandbox and returns its path. The worker
/// runs it as `tool <analyzed file>` (runClangTidy appends the file).
private string writeFakeTool(TestArea ta, string body) @safe {
    const tool = ta.inSandboxPath("fejk_clang_tidy.sh");
    write(tool, "#!/bin/bash\n" ~ body);
    setAttributes(tool, 493 /* 0o755 */ );
    return tool;
}

private TidyWork* mkWork(string tool, string file, string[] includeFilter = [],
        string[] excludeFilter = []) @safe {
    auto w = new TidyWork([tool], AbsolutePath(file), false, excludeFilter,
            includeFilter, false, Clock.currTime);
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
/// the spawn→first-tick handoff; the workers' reported_/stopped_ guards make
/// both message orders valid). The drain only bounds event collection: a
/// worker that delivers its report but never self-exits is caught by the
/// watchdog around sys.wait() in the iwyu twin (test_iwyu_worker.d), and
/// would hang the suite here - sys.wait has no timeout.
private WorkerScenario driveWorker(alias Worker)(TestArea ta, TidyWork* work,
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
        // quiet, then make late dispatch LOUD, verbatim from the coordinator's
        // scenario runner (test_job_coordinator.d runScenario) - but the quiet
        // break additionally requires at least one event: the first scenario in
        // the process pays one-time start costs (pool spin-up, cold bash) and
        // may legitimately be silent for its first windows.
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

        sys.wait();
    });
    return sc;
}

/// The clangTidyStatus of the single tidy payload in `res`.
private int tidyStatus(ImmutableFileResult res) @safe {
    return res.match!((TidyResult r) => r.clangTidyStatus, (_) {
        assert(false, "expected a tidy payload");
        return int.init;
    });
}

@("worker: success path - exactly one fileDone, one token return, then exits")
@Serial unittest {
    auto ta = makeTestArea;
    const file = ta.inSandboxPath("a1.cpp");
    const tool = writeFakeTool(ta, "exit 0\n");
    auto sc = driveWorker!ClangTidyWorker(ta, mkWork(tool, file));

    assert(sc.rec.countWith("fileDone") == 1, format("events: %s", sc.rec.snapshot));
    assert(sc.rec.countWith("returnToken") == 1, format("events: %s", sc.rec.snapshot));

    auto payloads = sc.rec.payloads;
    assert(payloads.length == 1, format("payloads: %s", payloads.length));
    assert(tidyStatus(payloads[0]) == 0, format("clangTidyStatus: %s", tidyStatus(payloads[0])));
}

@("worker: tool failure without warnings - toolFailed, clean status")
@Serial unittest {
    auto ta = makeTestArea;
    const file = ta.inSandboxPath("a2.cpp");
    const tool = writeFakeTool(ta, "exit 2\n");
    auto sc = driveWorker!ClangTidyWorker(ta, mkWork(tool, file));

    auto payloads = sc.rec.payloads;
    assert(payloads.length == 1);
    payloads[0].match!((TidyResult r) {
        assert(r.toolFailed, format("toolFailed: %s", r.toolFailed));
        assert(r.clangTidyStatus == 0, format("clangTidyStatus: %s", r.clangTidyStatus));
    }, (_) { assert(false, "expected a tidy payload"); });
    assert(sc.rec.countWith("returnToken") == 1);
}

@("worker: warnings found - clangTidyStatus 1, details and formatted output")
@Serial unittest {
    auto ta = makeTestArea;
    const file = ta.inSandboxPath("a3.cpp");
    const tool = writeFakeTool(ta,
            "echo '" ~ file ~ ":1:1: warning: some text [check-name]'\nexit 0\n");
    auto sc = driveWorker!ClangTidyWorker(ta, mkWork(tool, file));

    auto payloads = sc.rec.payloads;
    assert(payloads.length == 1);
    payloads[0].match!((TidyResult r) {
        assert(r.clangTidyStatus == 1, format("clangTidyStatus: %s", r.clangTidyStatus));
        assert(r.file == AbsolutePath(file), format("file: %s", r.file));
        assert(r.details.length == 1, format("details: %s", r.details));
        assert(r.output.length == 1, format("output: %s", r.output));
        assert(r.output[0].canFind("some text"), format("output: %s", r.output));
    }, (_) { assert(false, "expected a tidy payload"); });
}

@("worker: include filter suppresses the only warning - automatic pass")
@Serial unittest {
    auto ta = makeTestArea;
    const file = ta.inSandboxPath("a4.cpp");
    const tool = writeFakeTool(ta,
            "echo '" ~ file ~ ":1:1: warning: some text [check-name]'\nexit 0\n");
    auto sc = driveWorker!ClangTidyWorker(ta, mkWork(tool, file, [
        "zzz-no-match"
    ]));

    auto payloads = sc.rec.payloads;
    assert(payloads.length == 1);
    payloads[0].match!((TidyResult r) {
        assert(r.clangTidyStatus == 0, "the suppressed warning is an automatic pass");
        assert(r.details.length == 0, "the warning is not recorded");
    }, (_) { assert(false, "expected a tidy payload"); });
}

@("worker: filter regex error - clangTidyStatus -1, tool not run")
@Serial unittest {
    auto ta = makeTestArea;
    const file = ta.inSandboxPath("a5.cpp");
    const tool = writeFakeTool(ta, "touch " ~ ta.inSandboxPath("sentinel") ~ "\nexit 1\n");
    auto sc = driveWorker!ClangTidyWorker(ta, mkWork(tool, file, ["["]));

    assert(sc.rec.countWith("fileDone") == 1, format("events: %s", sc.rec.snapshot));
    assert(sc.rec.countWith("returnToken") == 1);

    auto payloads = sc.rec.payloads;
    assert(payloads.length == 1);
    payloads[0].match!((TidyResult r) {
        assert(r.clangTidyStatus == -1, format("clangTidyStatus: %s", r.clangTidyStatus));
    }, (_) { assert(false, "expected a tidy payload"); });
    assert(!exists(ta.inSandboxPath("sentinel")), "the tool must not run");
}

private static class ThrowingWorker : ClangTidyWorker {
    this(WeakAddress collector, WeakAddress limiter, TidyWork* work) @safe {
        super(collector, limiter, work);
    }

    override void run() @trusted {
        throw new Exception("bang");
    }
}

@("worker: handler exception - onException delivers one failed fileDone + exit")
@Serial unittest {
    auto ta = makeTestArea;
    const file = ta.inSandboxPath("a6.cpp");
    const tool = writeFakeTool(ta, "exit 0\n");
    auto sc = driveWorker!ThrowingWorker(ta, mkWork(tool, file));

    // The backstop reports a failed result instead of hanging the collector.
    auto payloads = sc.rec.payloads;
    assert(payloads.length == 1, format("events: %s", sc.rec.snapshot));
    payloads[0].match!((TidyResult r) {
        assert(r.toolFailed && r.clangTidyStatus == 0,
            "the backstop reports the tool-never-ran failure flavor");
        assert(r.file == AbsolutePath(file));
    }, (_) { assert(false, "expected a tidy payload"); });
    assert(sc.rec.countWith("returnToken") == 1);
}

@("worker: requested exit before run() - one failed fileDone, run never fires")
@Serial unittest {
    auto ta = makeTestArea;
    const file = ta.inSandboxPath("a7.cpp");
    const tool = writeFakeTool(ta, "touch " ~ ta.inSandboxPath("sentinel") ~ "\nexit 0\n");
    auto sc = driveWorker!ClangTidyWorker(ta, mkWork(tool, file), (sc, worker) {
        // The coordinator's chStop abort path, sent before the worker's first
        // tick so stop() lands before the self-sent run().
        dynSend(worker.weakRef, "stop");
    });

    auto payloads = sc.rec.payloads;
    assert(payloads.length == 1, format("events: %s", sc.rec.snapshot));
    payloads[0].match!((TidyResult r) {
        assert(r.toolFailed && r.clangTidyStatus == 0,
            format("abort flavor: %s/%s", r.toolFailed, r.clangTidyStatus));
    }, (_) { assert(false, "expected a tidy payload"); });
    assert(sc.rec.countWith("returnToken") == 1);
    assert(!exists(ta.inSandboxPath("sentinel")), "run() must never fire");
}

@("worker: sendExit(userShutdown) to a spawned worker - one success report, no double-report")
@Serial unittest {
    auto ta = makeTestArea;
    const file = ta.inSandboxPath("a8.cpp");
    const tool = writeFakeTool(ta, "exit 0\n");
    auto sc = driveWorker!ClangTidyWorker(ta, mkWork(tool, file), (sc, worker) {
        // The exit lands before the worker's first tick: the default exit
        // handler (no onExit hook) force-shuts it, but the queued run() is
        // still dispatched in the same tick (processIncoming has no state
        // guard) - the worker reports its success result exactly once.
        sendExit(worker.weakRef, ExitReason.userShutdown);
    });

    auto payloads = sc.rec.payloads;
    assert(payloads.length == 1, format("events: %s", sc.rec.snapshot));
    assert(tidyStatus(payloads[0]) == 0);
    assert(sc.rec.countWith("returnToken") == 1);
}

@("userShutdown reaches an onExit hook without auto-kill (TrappedExit pin)")
@Serial unittest {
    import my.actor.channel : dynSend;
    import my.actor.system_msg : ExitMsg;

    auto ta = makeTestArea;
    auto rec = new WorkerRecorder;

    static final class ExitPinStub {
        private WorkerRecorder rec_;

        this(WorkerRecorder rec) @safe {
            rec_ = rec;
        }

        // An onExit hook TRAPS userShutdown: it runs but the actor is only
        // killed if the hook itself requests shutdown (my/actor/actor.d
        // defaultExitHandler vs the hook forwarding).
        void onExit(ExitMsg m) @safe {
            rec_.add("onExit");
        }

        void ping() @safe {
            rec_.add("ping");
        }
    }

    withQuietLogger({
        auto sys = makeSystem;
        auto stub = sys.spawn!ExitPinStub(rec);
        sendExit(stub.weakRef, ExitReason.userShutdown);

        // Drain: the system pool ticks the stub, the exit reaches the hook.
        size_t last;
        foreach (_; 0 .. 10) {
            last = rec.countWith("");
            Thread.sleep(50.msecs);
            if (rec.countWith("") == last)
                break;
        }

        // The hook ran, and the actor is still alive afterwards (the hook did
        // not request shutdown): a later message is still dispatched.
        assert(rec.countWith("onExit") == 1, format("events: %s", rec.snapshot));
        dynSend(stub.weakRef, "ping");
        Thread.sleep(100.msecs);
        assert(rec.countWith("ping") == 1, "the hook did not auto-kill the actor");
    });
}
