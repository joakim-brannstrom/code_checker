/**
Copyright: Copyright (c) 2021, Joakim Brännström. All rights reserved.
License: $(LINK2 http://www.boost.org/LICENSE_1_0.txt, Boost Software License 1.0)

Unit tests for the JobCoordinator actor (engine/actor_engine.d): the
compile-db prep pass (missing-file handling per flavor, user filters), the
begin-before-first-worker ordering, one worker per accepted file, and the
prep-phase abort behavior. Stubs implement the collector/writer/limiter
interfaces and a worker that records its spawn.
*/
module test_job_coordinator;

import core.sync.mutex : Mutex;
import core.time : dur, msecs;
import std.algorithm : endsWith;
import std.datetime : Clock;
import std.file : write;
import std.format : format;
import std.path : buildPath;
import std.string : startsWith;
import std.conv : to;

import my.path : AbsolutePath, Path;
import code_checker.cli : Config;
import code_checker.engine.actor_engine;
import code_checker.engine.types : Environment, MsgSeverity, Result, Status;
import code_checker.engine.builtin.clang_tidy : TidyResult, TidyWork;
import code_checker.engine.builtin.include_what_you_use : IwyuWork;
import compile_db : CompileCommand, CompileCommandDB;
import my.actor : RequestResult, WeakAddress;
import my.actor.system : makeSystem;
import my.actor.utility.limiter : IFlowControl, Token;
import config : TestArea;
import config : makeTestArea;

import unit_threaded.runner.attrs : Serial;

final class Recorder {
    private Mutex mtx;
    private string[] events_;
    private size_t beginCount_, spawnCount_, missingCount_;

    this() {
        mtx = new Mutex;
    }

    void add(string e) @trusted {
        synchronized (mtx) {
            events_ ~= e;
            if (e.startsWith("begin"))
                beginCount_++;
            else if (e.startsWith("spawn"))
                spawnCount_++;
            else if (e.startsWith("missing:"))
                missingCount_++;
        }
    }

    size_t beginCount() @safe {
        synchronized (mtx)
            return beginCount_;
    }

    size_t spawnCount() @safe {
        synchronized (mtx)
            return spawnCount_;
    }

    size_t missingCount() @safe {
        synchronized (mtx)
            return missingCount_;
    }

    /// Index of the first event with the prefix, or size_t.max.
    size_t indexOf(string prefix) @safe {
        synchronized (mtx) {
            foreach (i, e; events_)
                if (e.startsWith(prefix))
                    return i;
        }
        return size_t.max;
    }

    string firstWith(string prefix) @safe {
        synchronized (mtx) {
            foreach (e; events_)
                if (e.startsWith(prefix))
                    return e;
        }
        return "";
    }

    /// Number of events recorded so far.
    size_t totalEvents() @safe {
        synchronized (mtx)
            return events_.length;
    }

    string[] snapshot() @safe {
        synchronized (mtx)
            return events_.dup;
    }

    /// Number of events with the prefix.
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

static class StubCollector : IResultCollector {
    private Recorder rec_;

    this(Recorder rec) @safe {
        rec_ = rec;
    }

    /// Sent by the stub worker (which cannot hold the recorder) when the
    /// coordinator spawns it; recorded as the "spawn" event.
    void workerSpawned() @safe {
        rec_.add("spawn");
    }

    void begin(size_t expected) @safe {
        rec_.add("begin:" ~ expected.to!string);
    }

    void fileDone(ImmutableFileResult res) @safe {
    }

    RequestResult!Result report() @safe {
        return RequestResult!Result(Result.init);
    }

    void missing(string msg, int scorePenalty, bool abort) @safe {
        rec_.add(format("missing:%s:%s:%s", msg, scorePenalty, abort));
    }

    /// The coordinator registers each spawned worker's DownMsg backstop
    /// (see IResultCollector.watching); recorded with the pre-baked failed
    /// result's file so the tests can assert the wiring per spawn.
    void watching(WeakAddress worker, ImmutableFileResult ifDead) @safe {
        import my.sumtype : match;
        import code_checker.engine.builtin.include_what_you_use : IwyuResult;

        string file;
        ifDead.match!((TidyResult r) { file = r.file.toString; }, (IwyuResult r) {
            file = r.file.toString;
        });
        rec_.add("watching:" ~ file);
    }
}

static class StubWriter : IConsoleWriter {
    private Recorder rec_;

    this(Recorder rec) @safe {
        rec_ = rec;
    }

    void fileDone(FileOutputEvent ev) @safe {
    }

    void notice(MsgSeverity severity, string msg) @safe {
        rec_.add("notice:" ~ msg);
    }
}

static class StubLimiter : IFlowControl {
    RequestResult!Token takeToken() @safe {
        return RequestResult!Token(Token.init);
    }

    void returnToken() @safe {
    }

    void refresh() @safe {
    }

    void tickRefresh() @safe {
    }
}

/// Records being spawned; the payload is the coordinator's per-file flavor.
static class StubWorker(Payload) {
    this(WeakAddress collector, WeakAddress limiter, Payload work) @safe {
        import my.actor.channel : dynSend;

        // The worker cannot hold the per-scenario recorder (the engine fixes
        // this ctor signature), so it reports the spawn to the collector stub
        // instead, which records it on this worker's behalf.
        dynSend(collector, "workerSpawned");
    }

    void run() @safe {
    }

    void stop() @safe {
    }
}

private CompileCommand mkCmd(string file) @safe {
    return CompileCommand(Path(file ~ ".o"), AbsolutePath(file),
            AbsolutePath("/"), CompileCommand.Command(["clang++", "-c", file]),
            Path(file ~ ".o"), AbsolutePath(file ~ ".o"));
}

private Environment mkEnv(TestArea ta, CompileCommandDB db,
        string[] includeFilter = null, string[] excludeFilter = null) @safe {
    Environment env;
    env.conf = Config.make(Path(ta.sandboxPath).AbsolutePath, Path(ta.sandboxPath).AbsolutePath);
    env.compileDbFile = Path(ta.sandboxPath).AbsolutePath;
    env.conf.staticCode.fileIncludeFilter = includeFilter;
    env.conf.staticCode.fileExcludeFilter = excludeFilter;
    env.compileDb = db;
    return env;
}

private AnalyzerJob mkJob(WeakAddress coll, WeakAddress cons, WeakAddress lim,
        Environment env, string[] includeFilter = [], string[] excludeFilter = [
]) @safe {
    AnalyzerJob job;
    job.collector = coll;
    job.console = cons;
    job.limiter = lim;
    job.args = ["-checks=-*"];
    job.useColors = true;
    job.fileIncludeFilter = includeFilter.length ? includeFilter
        : env.conf.staticCode.fileIncludeFilter;
    job.fileExcludeFilter = excludeFilter.length ? excludeFilter
        : env.conf.staticCode.fileExcludeFilter;
    job.env = env;
    return job;
}

/// Runs one scenario to completion. The system must outlive the start
/// message: the coordinator runs on the system's pool threads, so a system
/// destroyed right after dynSend would kill the coordinator mid-scenario
/// (and race the pool threads during shutdown). `done` is the scenario's
/// completion condition; it is polled until met before the system dies.
private void runScenario(alias Payload)(Recorder rec, Environment env,
        scope bool delegate(Recorder) @safe done,
        scope void delegate(WeakAddress) @safe postStart = null) {
    import core.thread : Thread;
    import std.exception : enforce;
    import my.actor.channel : dynSend;

    auto sys = makeSystem;
    // Stubs hold their recorder by construction: a shared recorder would
    // race, because a previous scenario's parked pool threads can still
    // dispatch through it after the next scenario starts (sys.wait() does
    // not quiesce mailboxes; the watcher re-polls parked actors).
    auto coll = sys.spawn!StubCollector(rec);
    auto cons = sys.spawn!StubWriter(rec);
    auto lim = sys.spawn!StubLimiter;

    alias W = StubWorker!(Payload);
    auto coord = sys.spawn!(JobCoordinator!(W, Payload));

    dynSend(coord.weakRef, "start", mkJob(coll.weakRef, cons.weakRef, lim.weakRef, env));
    // Optional post-start hook: queues another coordinator message right
    // behind "start" (FIFO mailbox ⇒ processed after start's dispatch),
    // e.g. a CheckLoadMsg self-tick to exercise the resumable fan-out.
    if (postStart !is null)
        postStart(coord.weakRef);

    const deadline = Clock.currTime + 5.dur!"seconds";
    while (!done(rec) && Clock.currTime < deadline)
        Thread.sleep(1.msecs);

    // Drain until the recorder is stable, then make late dispatch LOUD:
    // parked pool threads can still deliver messages after the done predicate
    // fired (the watcher re-polls parked actors), so any event that lands
    // after the quiet window means events crossed a scenario boundary and
    // fails the test instead of hiding in the asserts.
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

    // The scenario is complete; drain the system so its pool threads do not
    // leak into the unit-threaded runner (which waits for all threads).
    // Stubs killed here drop undelivered mailbox messages by design
    // (SystemExitMsg(kill)); the drain above already waited for them.
    sys.wait();
}

private string[] twoRealFiles(TestArea ta) @safe {
    auto f1 = buildPath(ta.sandboxPath, "a1.cpp");
    auto f2 = buildPath(ta.sandboxPath, "a2.cpp");
    write(f1, "int x;\n");
    write(f2, "int x;\n");
    return [f1, f2];
}

@("coordinator: begin before first worker, one worker per accepted file")
@Serial unittest {
    auto ta = makeTestArea;
    auto files = twoRealFiles(ta);

    auto rec = new Recorder;
    auto db = CompileCommandDB([mkCmd(files[0]), mkCmd(files[1])]);
    runScenario!(TidyWork*)(rec, mkEnv(ta, db), rec => rec.spawnCount == 2);
    assert(rec.beginCount == 1, format("expected one begin, got %s", rec.beginCount));
    assert(rec.firstWith("begin:") == "begin:2", "begin must carry the accepted count");
    assert(rec.indexOf("begin:") < rec.indexOf("spawn"),
            "begin must be sent before the first worker is spawned");
    assert(rec.missingCount == 0, "no file is missing");
}

@("coordinator: each spawned worker registers its DownMsg backstop with the collector")
@Serial unittest {
    auto ta = makeTestArea;
    auto files = twoRealFiles(ta);

    auto rec = new Recorder;
    auto db = CompileCommandDB([mkCmd(files[0]), mkCmd(files[1])]);
    runScenario!(TidyWork*)(rec, mkEnv(ta, db), rec => rec.spawnCount == 2);
    // One watching per spawn, carrying the pre-baked failed result for the
    // spawned worker's file, after the spawn event itself.
    assert(rec.countWith("watching:") == 2,
            format("expected one watching per spawn: %s", rec.snapshot));
    assert(rec.firstWith("watching:") == "watching:" ~ files[0],
            "the first watching carries the first worker's file");
    assert(rec.indexOf("spawn") < rec.indexOf("watching:"),
            "the monitor backstop is registered after the spawn");
}

@(
        "coordinator: missing file aborts the clang-tidy prep with notice and collector penalty, no begin")
@Serial unittest {
    auto ta = makeTestArea;
    auto files = twoRealFiles(ta);
    const missing = buildPath(ta.sandboxPath, "gone.cpp");

    auto rec = new Recorder;
    auto db = CompileCommandDB([mkCmd(missing), mkCmd(files[0])]);
    runScenario!(TidyWork*)(rec, mkEnv(ta, db), rec => rec.missingCount == 1);
    const missEv = rec.firstWith("missing:clang-tidy where unable to find ");
    assert(missEv.startsWith("missing:clang-tidy where unable to find "),
            "unexpected missing message: " ~ missEv);
    assert(missEv.endsWith(":100:true"), "clang-tidy aborts with -100");
    assert(rec.countWith("notice:clang-tidy where unable to find ") == 1,
            "the message text goes to the writer via notice");
    // The abort path delivers begin(0) so the real collector's
    // report() answers the driver's parked request with the partial failed
    // result (score -100 already merged by missing(), failed status). The
    // stub recorder here just observes it.
    assert(rec.beginCount == 1, "exactly the abort's begin(0)");
    assert(rec.firstWith("begin:") == "begin:0", "the abort begin carries the empty accepted count");
    assert(rec.spawnCount == 0, "no worker is spawned after a prep abort");
}

@("coordinator: missing file in the iwyu prep applies its own penalty without abort")
@Serial unittest {
    auto ta = makeTestArea;
    auto files = twoRealFiles(ta);
    const missing = buildPath(ta.sandboxPath, "gone.cpp");

    auto rec = new Recorder;
    auto db = CompileCommandDB([mkCmd(missing), mkCmd(files[0])]);
    runScenario!(IwyuWork*)(rec, mkEnv(ta, db), rec => rec.missingCount == 1 && rec.spawnCount == 1);
    const missEv = rec.firstWith("missing:iwyu where unable to find ");
    assert(missEv.startsWith("missing:iwyu where unable to find "),
            "unexpected missing message: " ~ missEv);
    assert(missEv.endsWith(":1000:false"), "iwyu does not abort on missing files");
    assert(rec.beginCount == 1, "the prep continues to the next file");
    assert(rec.spawnCount == 1, "the surviving file still gets a worker");
}

@("coordinator: files filtered out by the user filters get no worker")
@Serial unittest {
    auto ta = makeTestArea;
    auto files = twoRealFiles(ta);

    auto rec = new Recorder;
    auto db = CompileCommandDB([mkCmd(files[0]), mkCmd(files[1])]);
    runScenario!(TidyWork*)(rec, mkEnv(ta, db, ["never_matches_anything"], []),
            rec => rec.beginCount == 1);
    assert(rec.beginCount == 1, "the accepted count is still reported");
    assert(rec.firstWith("begin:") == "begin:0", "nothing was accepted");
    assert(rec.missingCount == 0, "a filtered file is not missing");
}

@("coordinator: a late CheckLoadMsg self-tick resumes the fan-out without duplicates")
@Serial unittest {
    // The fan-out cursor machinery (fi_ + CheckLoadMsg → fanOut()): a
    // self-tick arriving after start's dispatch must neither re-spawn the
    // already-scheduled workers nor re-send begin. The stub limiter's replies
    // are always async (thenUnsafe registers a reply handler and puts the
    // request; one message per process() poll), so at start's dispatch
    // pendingTokens_ > 0 and the coordinator parks - the resume tick is
    // processed in that parked state (or, if both takeToken replies were
    // delivered first, at an already-exited coordinator - harmless either
    // way; the assertions hold in both interleavings).
    auto ta = makeTestArea;
    auto files = twoRealFiles(ta);

    auto rec = new Recorder;
    auto db = CompileCommandDB([mkCmd(files[0]), mkCmd(files[1])]);
    auto env = mkEnv(ta, db);

    runScenario!(TidyWork*)(rec, env, rec => rec.spawnCount == 2 && rec.beginCount == 1, (coord) {
        import my.actor.channel : dynSend;

        dynSend(coord, "CheckLoadMsg");
    });
    assert(rec.spawnCount == 2, "no duplicate workers after the resume tick");
    assert(rec.beginCount == 1, "no extra begin after the resume tick");
}

/// Regression backstop: the coordinator's prep-abort path must answer the
/// driver's parked report request (without begin(), report() would park
/// forever and execute() would hang with no diagnostic).
@("coordinator: a prep abort answers the driver's parked report request")
@Serial unittest {
    // Shadows the file-level `code_checker.cli : Config` (same pattern as
    // builtin/clang_tidy.d's execute()).
    import my.actor.system : Config, makeSystem;

    // Real actors: a writer that swallows the abort-path notice, a real
    // collector, and a coordinator over the real ClangTidyWorker (never
    // instantiated - the abort happens in the prep pass, before any worker
    // spawn).
    auto ta = makeTestArea;
    withQuietLogger({
        auto sys = makeSystem;

        // A compile db whose only file is not on disk: the coordinator's
        // prep aborts before any worker is spawned.
        auto db = CompileCommandDB([
            mkCmd(buildPath(ta.sandboxPath, "gone.cpp"))
        ]);
        auto env = mkEnv(ta, db);

        auto writer = () @trusted {
            return sys.spawn!(Config.detached, ConsoleWriter)();
        }();

        AnalyzerJob job;
        job.env = env;
        job.args = ["-checks=-*"];
        job.useColors = true;
        job.console = writer.weakRef;
        job.mergeTidy = (ref Result r, TidyResult t) {};

        auto collector = () @trusted {
            return sys.spawn!(ResultCollector!(TidyWork*))(job, writer.weakRef);
        }();
        job.collector = collector.weakRef;

        auto coord = () @trusted {
            return sys.spawn!(JobCoordinator!(ClangTidyWorker, TidyWork*))();
        }();

        // The regression: this must RETURN with the partial failed result
        // instead of parking forever.
        const result = () @trusted {
            return blockUntilReport(&sys, coord.weakRef, collector.weakRef, job);
        }();

        assert(result.status == Status.failed, format("status: %s", result.status));
        // The missing-file penalty via missing(): the collector's score starts
        // at 0 and missing() subtracts 100 when abort is set.
        assert(result.score == -100, format("score: %s", result.score));

        sys.shutdown();
    });
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
