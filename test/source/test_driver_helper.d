/**
Copyright: Copyright (c) 2021, Joakim Brännström. All rights reserved.
License: $(LINK2 http://www.boost.org/LICENSE_1_0.txt, Boost Software License 1.0)

Unit tests for the driver-side blocking helper blockUntilReport
(engine/actor_engine.d): start(job) fire-and-forget to a stub coordinator, a
report() request to a stub collector, the manually-driven client kernel wait
loop, and the returned merged Result.

Exception semantics: a spawned actor's handler
exception never crosses to the driver thread - the vendor routes handler
exceptions to the actor's own onException hook. So the throwing-start scenario
is realized as: the stub coordinator's onException drives a failed answer
through the collector (the collector liveness backstop), and blockUntilReport
returns - no hang - with a failed Result and the exception observed via the
ctor-injected Recorder. The helper's own try/catch covers driver-side failures
only (parity with executeOneAnalyzer's catch).
*/

module test_driver_helper;

import core.sync.mutex : Mutex;

import std.algorithm : startsWith;
import std.exception : enforce;
import std.format : format;

import my.actor : RequestResult, WeakAddress;
import my.actor.behavior : ActorRef;
import my.actor.channel : Channel;
import my.actor.system : makeSystem;

import code_checker.engine.actor_engine;
import code_checker.engine.types : Environment, Result, Status, mergeStatus;
import code_checker.engine.builtin.clang_tidy : TidyResult;
import code_checker.engine.builtin.include_what_you_use : IwyuResult;

import config : TestArea;
import config : makeTestArea;

import unit_threaded.runner.attrs : Serial;

final class Recorder {
    private Mutex mtx;
    private string[] events_;

    this() {
        mtx = new Mutex;
    }

    void add(string e) @trusted {
        synchronized (mtx) {
            events_ ~= e;
        }
    }

    string firstWith(string prefix) @safe {
        synchronized (mtx) {
            foreach (e; events_)
                if (e.startsWith(prefix))
                    return e;
        }
        return "";
    }

    string[] snapshot() @safe {
        synchronized (mtx)
            return events_.dup;
    }
}

/// Answers the driver's report() request with the Result it was constructed
/// with (an immediate-value RequestResult reply - no parking).
final class StubCollector : IResultCollector {
    private Result answer_;

    this(Result answer) @safe {
        answer_ = answer;
    }

    void begin(size_t expected) @safe {
    }

    void fileDone(ImmutableFileResult res) @safe {
    }

    void missing(string msg, int scorePenalty, bool abort) @safe {
    }

    /// Not wired in this module's scenarios (the DownMsg backstop is
    /// exercised in test_result_collector.d); no-op to satisfy the interface.
    void watching(WeakAddress worker, ImmutableFileResult ifDead) @safe {
    }

    RequestResult!Result report() @safe {
        return RequestResult!Result(answer_);
    }
}

/// Records the start() delivery.
final class StubCoordinator : IJobCoordinator {
    private Recorder rec_;

    this(Recorder rec) @safe {
        rec_ = rec;
    }

    void start(AnalyzerJob job) @safe {
        rec_.add("start");
    }
}

/// A coordinator whose start() throws. Its onException drives a failed answer
/// through the collector - the liveness backstop that keeps the driver's
/// parked report() request from hanging.
final class ThrowingCoordinator : IJobCoordinator {
    private Recorder rec_;
    private WeakAddress collector_;
    private ActorRef self_;

    this(Recorder rec, WeakAddress collector) @safe {
        rec_ = rec;
        collector_ = collector;
    }

    void onSpawn(ActorRef self_) @safe {
        this.self_ = self_;
    }

    void start(AnalyzerJob job) @safe {
        throw new Exception("start exploded");
    }

    void onException(Exception e) @safe {
        rec_.add("exception:" ~ e.msg);
        () @trusted {
            auto ch = Channel!IResultCollector(collector_, self_);
            ch.begin(1UL);
            ch.fileDone(ImmutableFileResult(mkTidyResult("a.cpp", 1)));
        }();
    }
}

/// Parks the driver's report() request on a promise (the production path:
/// report() lands before the workers finish) and answers it on the next
/// dispatch via a self-sent message - exercising the parked-promise → Reply →
/// driver-handler round-trip (Promise.deliver) at the
/// helper level.
final class ParkingCollector : IResultCollector {
    import my.actor.actor : Promise, RequestResult, makePromise;

    private Promise!Result pending_;
    private Result answer_;
    private ActorRef self_;

    this(Result answer) @safe {
        answer_ = answer;
    }

    void onSpawn(ActorRef self_) @safe {
        this.self_ = self_;
    }

    void begin(size_t expected) @safe {
    }

    void fileDone(ImmutableFileResult res) @safe {
    }

    void missing(string msg, int scorePenalty, bool abort) @safe {
    }

    /// Not wired in this module's scenarios (the DownMsg backstop is
    /// exercised in test_result_collector.d); no-op to satisfy the interface.
    void watching(WeakAddress worker, ImmutableFileResult ifDead) @safe {
    }

    RequestResult!Result report() @safe {
        pending_ = makePromise!Result;
        // Queue the answer behind the currently-dispatching report(): the
        // parked promise is delivered on the next dispatch (the real
        // collector's answerPending path, at the
        // helper level). dynSend is fire-and-forget by method name; the
        // no-arg signature matches deliverAnswer().
        import my.actor.channel : dynSend;

        dynSend(self_.address(), "deliverAnswer");
        return RequestResult!Result(pending_);
    }

    void deliverAnswer() @safe {
        pending_.deliver(answer_);
    }
}

private void mergeTidyTest(ref Result result_, TidyResult res) @safe {
    result_.score += res.errors.score;
    if (res.clangTidyStatus == 0) {
        result_.success ~= res.file;
        result_.status = mergeStatus(result_.status, Status.passed);
    } else {
        result_.failed ~= res.file;
        result_.status = mergeStatus(result_.status, Status.failed);
    }
}

private void mergeIwyuNoop(ref Result, IwyuResult) @safe {
}

private AnalyzerJob mkJob(Environment env) @safe {
    AnalyzerJob job;
    job.env = env;
    job.mergeTidy = &mergeTidyTest;
    job.mergeIwyu = &mergeIwyuNoop;
    return job;
}

private Environment mkEnv(TestArea ta) @safe {
    import code_checker.cli : Config;
    import my.path : AbsolutePath, Path;

    Environment env;
    env.conf = Config.make(Path(ta.sandboxPath).AbsolutePath, Path(ta.sandboxPath).AbsolutePath);
    env.compileDbFile = Path(ta.sandboxPath).AbsolutePath;
    return env;
}

private TidyResult mkTidyResult(string file, int status) @safe {
    import my.path : AbsolutePath;

    TidyResult r;
    r.file = AbsolutePath(file);
    r.clangTidyStatus = status;
    return r;
}

@("driver helper: returns the merged Result the collector answered with")
@Serial unittest {
    auto ta = makeTestArea;
    auto env = mkEnv(ta);

    Result answer;
    answer.score = 7;
    answer.status = Status.passed;

    auto sys = makeSystem;
    auto coll = sys.spawn!StubCollector(answer);
    auto cons = sys.spawn!StubCoordinator(new Recorder);

    auto job = mkJob(env);
    const result = blockUntilReport(&sys, cons.weakRef, coll.weakRef, job);

    assert(result.status == Status.passed, format("status: %s", result.status));
    assert(result.score == 7, "the answer's payload round-trips the Variant");

    sys.wait();
}

@("driver helper: a report() that parks is answered through the parked promise")
@Serial unittest {
    auto ta = makeTestArea;
    auto env = mkEnv(ta);

    Result answer;
    answer.score = 7;
    answer.status = Status.passed;

    auto sys = makeSystem;
    auto coll = sys.spawn!ParkingCollector(answer);
    auto cons = sys.spawn!StubCoordinator(new Recorder);

    auto job = mkJob(env);
    const result = blockUntilReport(&sys, cons.weakRef, coll.weakRef, job);

    assert(result.status == Status.passed, format("status: %s", result.status));
    assert(result.score == 7, "the delivered answer round-trips the Variant");

    sys.wait();
}

@("driver helper: a throwing coordinator start surfaces as a failed Result, no hang")
@Serial unittest {
    auto ta = makeTestArea;
    auto env = mkEnv(ta);

    Result failedAnswer;
    failedAnswer.status = Status.failed;

    auto rec = new Recorder;
    auto sys = makeSystem;
    auto coll = sys.spawn!StubCollector(failedAnswer);
    auto cons = sys.spawn!ThrowingCoordinator(rec, coll.weakRef);

    auto job = mkJob(env);
    const result = blockUntilReport(&sys, cons.weakRef, coll.weakRef, job);

    assert(result.status == Status.failed, format("status: %s", result.status));
    enforce(rec.firstWith("exception:") == "exception:start exploded",
            format("events: %s", rec.snapshot));

    sys.wait();
}
