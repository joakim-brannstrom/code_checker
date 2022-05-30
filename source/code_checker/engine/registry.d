/**
Copyright: Copyright (c) 2018, Joakim Brännström. All rights reserved.
License: $(LINK2 http://www.boost.org/LICENSE_1_0.txt, Boost Software License 1.0)
Author: Joakim Brännström (joakim.brannstrom@gmx.com)

This module contains the registry of analaysers
*/
module code_checker.engine.registry;

import logger = std.experimental.logger;
import std.exception : collectException;

import code_checker.engine.types;

@safe:

/// The type of an analyser which then affect the order they are executed.
enum Type {
    staticCode,
    dynamic,
}

auto makeRegistry() {
    import code_checker.engine;

    Registry reg;
    reg.put(new ClangTidy, Type.staticCode);
    reg.put(new IncludeWhatYouUse, Type.staticCode);
    return reg;
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

    /// Range over the analysers.
    auto range() {
        import std.array : array;
        import std.algorithm : map, joiner, filter;

        static immutable order = [Type.staticCode, Type.dynamic];

        auto getAnalysers(Type t) {
            if (auto v = t in analysers)
                return (*v).map!(a => AnalyserRange.Pair(t, a)).array;
            return null;
        }

        return order.map!(a => getAnalysers(a))
            .filter!(a => a !is null)
            .joiner
            .array;
    }
}

/** Run the `checkers` from `reg` inside `env`.
 *
 * Returns: The total status of running the analyzers.
 */
TotalResult execute(Environment env, string[] analysers, ref Registry reg) @trusted {
    import std.algorithm;
    import std.range;
    import my.set : toSet;

    TotalResult tres;

    void handleResult(Result res_) nothrow {
        // we know the thread finished and have the only copy.
        // immutable is a bit cumbersome for now so throw away it to keep the
        // code somewhat efficient.
        auto res = cast() res_;

        try {
            log(res.msg);

            tres.status = mergeStatus(tres.status, res.status);
            tres.score = Score(tres.score + res.score);
            tres.supp = Suppressed(tres.supp + res.supp);
            tres.sugg ~= res.msg.array.filter!(a => a.severity == MsgSeverity.improveSuggestion)
                .array;
            tres.failed ~= res.failed;
            tres.success ~= res.success;
            tres.timeout ~= res.timeout;
            tres.analyzerFailed ~= res.analyzerFailed;
            foreach (a; res_.details.byKeyValue)
                tres.details.update(a.key, { return a.value.dup.toSet; }, (ref Set!Detail x) {
                    x.add(a.value);
                });

            logger.trace(res);
            logger.trace(tres);
        } catch (Exception e) {
            logger.warning("Failed executing all tests").collectException;
            logger.warning(e.msg).collectException;
            tres.status = Status.failed;
        }
    }

    foreach (a; reg.range.filter!((a) {
            if (analysers.empty)
                return true;
            return analysers.canFind(a.analyzer.name);
        })) {
        logger.infof("%s: %s", a.type, a.analyzer.explain);
        a.analyzer.putEnv(env);
        handleResult(executeOneAnalyzer(a.analyzer));
    }

    log(tres);
    return tres;
}

Result executeOneAnalyzer(BaseFixture a) nothrow @trusted {
    Result r;
    try {
        a.setup;
        a.execute;
        a.tearDown;
        r = a.result;
    } catch (Exception e) {
        logger.error(e.msg).collectException;
        r.status = Status.failed;
    }

    return r;
}

private:

void log(Messages msgs) {
    import std.algorithm : sort;

    foreach (m; msgs.value.sort) {
        final switch (m.severity) {
        case MsgSeverity.improveSuggestion:
            break;
        case MsgSeverity.unableToExecute:
        case MsgSeverity.failReason:
            logger.warning(m.value);
            break;
        case MsgSeverity.trace:
            logger.trace(m.value);
            break;
        }
    }
}

void log(TotalResult tres) {
    import std.array : empty;
    import std.conv : to;
    import colorlog;

    logger.infof("Analyzers reported %s", tres.status == Status.failed
            ? "Failed".color(Color.red) : "Passed".color(Color.green));

    if (!tres.timeout.empty || !tres.analyzerFailed.empty) {
        logger.info("Files failed to be analyzed.");
        logger.info("You can't do anything about it but know that they may start reporting errors in the future when the underlying tool is fixed.");
        foreach (a; tres.timeout)
            logger.info("    ", "timeout".color(Color.yellow).toString, " ", a);
        foreach (a; tres.analyzerFailed)
            logger.info("    ", "tool error".color(Color.yellow).toString, " ", a);
    }

    if (tres.sugg.length > 0) {
        logger.info("Suggestions for how to improve the score");
        foreach (m; tres.sugg)
            logger.info("    ", m.value);
    }

    if (tres.supp > 0) {
        logger.infof("You suppressed %s warnings", tres.supp);
    }

    if (tres.status == Status.passed) {
        logger.info("Congratulations!!!");
    }

    string score() {
        return tres.score < 0 ? tres.score.to!string.color(Color.red)
            .mode(Mode.bold).toString : tres.score.to!string;
    }

    logger.infof("You scored %s points", score);
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
