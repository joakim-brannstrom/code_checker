/**
Copyright: Copyright (c) 2018, Joakim Brännström. All rights reserved.
License: $(LINK2 http://www.boost.org/LICENSE_1_0.txt, Boost Software License 1.0)
Author: Joakim Brännström (joakim.brannstrom@gmx.com)

This module contains the registry of analaysers
*/
module code_checker.engine.registry;

import logger = std.experimental.logger;
import std.concurrency : Tid;
import std.exception : collectException;

import code_checker.engine.types;

@safe:

/// The type of an analyser which then affect the order they are executed.
enum Type {
    staticCode,
    dynamic,
}

struct Registry {
    private {
        BaseFixture[][Type] analysers;
    }

    void put(BaseFixture a, Type t) {
        assert(a !is null);

        if (auto v = t in analysers) {
            (*v) ~= a;
        } else {
            analysers[t] = [a];
        }
    }

    /// Range over the analysers. !
    auto range() {
        import std.array : array;
        import std.algorithm : map, joiner, filter;

        const order = [Type.staticCode, Type.dynamic];

        auto getAnalysers(Type t) {
            if (auto v = t in analysers)
                return (*v).map!(a => AnalyserRange.Pair(t, a)).array;
            return null;
        }

        return order.map!(a => getAnalysers(a)).filter!(a => a !is null).joiner.array;
    }
}

/// Returns: The total status of running the analyzers.
Status execute(Environment env, ref Registry reg) @trusted {
    import std.algorithm;
    import std.range;
    import std.parallelism : task, TaskPool;
    import std.concurrency : Tid, thisTid;

    TotalResult tres;
    auto pool = new TaskPool;
    scope (exit)
        pool.finish;

    foreach (a; reg.range) {
        logger.infof("%s: %s", a.type, a.analyzer.explain);
        a.analyzer.putEnv(env);
        auto t = task!executeOneAnalyzer(thisTid, a.analyzer);
        pool.put(t);
    }

    int replies;

    void handleResult(immutable Result res_) nothrow {
        replies++;
        // we know the thread finished and have the only copy.
        // immutable is a bit cumbersome for now so throw away it to keep the
        // code somewhat efficient.
        auto res = cast() res_;

        try {
            log(res.msg);

            tres.status = mergeStatus(tres.status, res.status);
            tres.score = Score(tres.score + res.score);
            tres.sugg ~= res.msg.array.filter!(a => a.severity == Severity.improveSuggestion).array;

            logger.trace(res);
            logger.trace(tres);
        } catch (Exception e) {
            logger.warning("Failed executing all tests").collectException;
            logger.warning(e.msg).collectException;
            tres.status = Status.failed;
        }
    }

    while (replies < reg.analysers.length) {
        import core.time : dur;
        import std.concurrency : LinkTerminated, receiveTimeout;

        try {
            receiveTimeout(1.dur!"seconds", &handleResult);
        } catch (Exception e) {
            logger.error(e.msg);
        }
    }

    log(tres);
    return tres.status;
}

void executeOneAnalyzer(Tid owner, BaseFixture a) nothrow @trusted {
    import std.concurrency : send;
    import std.exception : assumeUnique;

    try {
        a.setup;
        a.execute;
        a.tearDown;
        auto res = a.result;
        send(owner, cast(immutable) res);
    } catch (Exception e) {
        logger.error(e.msg).collectException;
    }
}

private:

void log(Messages msgs) {
    import std.algorithm : sort;

    foreach (m; msgs.value.sort) {
        final switch (m.severity) {
        case Severity.improveSuggestion:
            break;
        case Severity.unableToExecute:
        case Severity.failReason:
            logger.warning(m.value);
            break;
        }
    }
}

void log(TotalResult tres) {
    import std.conv : to;
    import colorize;

    logger.infof("Executing analysers %s", tres.status == Status.failed
            ? "Failed".color(Color.red) : "Passed".color(Color.green));

    if (tres.sugg.length > 0) {
        logger.info("Suggestions for how to improve the score");
        foreach (m; tres.sugg)
            logger.info("    ", m.value);
    }

    if (tres.status == Status.passed) {
        logger.info("Congratulations!!!");
        logger.infof("Your code reached Quality Level %s", 1 + tres.score / 10);
    }

    const string score = () {
        if (tres.score < 0)
            return tres.score.to!string.color(Color.red, Background.init, Mode.bold);
        return tres.score.to!string;
    }();
    logger.infof("You scored %s points", score);

    if (tres.score < 0) {
        logger.info("Sorry, your code needs a major rework to reach an acceptable quality level");
    }
}

/// Input range over the analysers.
struct AnalyserRange {
    import std.typecons : Tuple;

    alias Pair = Tuple!(Type, "type", BaseFixture, "analyzer");

    Pair[] r;

    auto front() @safe pure nothrow {
        assert(!empty, "Can't get front of an empty range");
        return r[0];
    }

    void popFront() @safe pure nothrow {
        assert(!empty, "Can't pop front of an empty range");
        r = r[1 .. $];
    }

    bool empty() @safe pure nothrow const @nogc {
        return r.length == 0;
    }
}
