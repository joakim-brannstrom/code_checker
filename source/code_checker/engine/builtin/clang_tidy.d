/**
Copyright: Copyright (c) 2018, Joakim Brännström. All rights reserved.
License: $(LINK2 http://www.boost.org/LICENSE_1_0.txt, Boost Software License 1.0)
Author: Joakim Brännström (joakim.brannstrom@gmx.com)

This file contains an analyzer that uses clang-tidy.
*/
module code_checker.engine.builtin.clang_tidy;

import std.typecons : Tuple;
import std.exception : collectException;
import std.concurrency : Tid, thisTid;
import logger = std.experimental.logger;

import code_checker.engine.types;
import code_checker.types;
import code_checker.process : RunResult;
import code_checker.from;

@safe:

class ClangTidy : BaseFixture {
    public {
        Environment env;
        Result result_;
        string[] tidyArgs;
    }

    this() {
    }

    override string explain() {
        return "using clang-tidy";
    }

    /// The environment the analyzers execute in.
    override void putEnv(Environment v) {
        this.env = v;
    }

    /// Setup the environment for analyze.
    override void setup() {
        import std.algorithm;
        import std.array : appender, array;
        import std.ascii;
        import std.file : exists;
        import std.range : put;

        auto app = appender!(string[])();

        if (env.clangTidy.applyFixit) {
            app.put(["-fix"]);
        }

        ["-header-filter", env.clangTidy.headerFilter].copy(app);

        if (!env.staticCode.checkNameStandard)
            env.clangTidy.checks ~= ["-readability-identifier-naming"];

        if (exists(ClangTidyConstants.confFile)) {
            logger.infof("Using clang-tidy settings from the local '%s'",
                    ClangTidyConstants.confFile);
        } else {
            logger.trace("Using config from the TOML file");

            auto c = appender!string();
            c.put(`{Checks: "`);
            env.clangTidy.checks.joiner(",").copy(c);
            c.put(`",`);
            c.put("CheckOptions: [");
            env.clangTidy.options.joiner(",").copy(c);
            c.put("]");
            c.put("}");

            app.put("-config");
            app.put(c.data);
        }

        tidyArgs ~= app.data;
    }

    /// Execute the analyzer.
    override void execute() {
        import core.time : dur;
        import std.format : format;
        import code_checker.compile_db : UserFileRange, parseFlag,
            CompileCommandFilter, SearchResult;
        import std.parallelism : task, TaskPool;
        import std.concurrency : Tid, thisTid, receiveTimeout;

        bool logged_failure;

        void handleResult(immutable(TidyResult)* res_) @trusted nothrow {
            import std.format : format;
            import std.typecons : nullableRef;
            import colorize : Color, color, Background, Mode;

            auto res = nullableRef(cast() res_);

            logger.infof("%s '%s'", "Analyzing".color(Color.yellow,
                    Background.black), res.file).collectException;

            // just chose some numbers. The intent is that warnings should be a high penalty
            result_.score += res.result.status == 0 ? 1
                : -(res.errors.readability + res.errors.other * 3);

            if (res.result.status != 0) {
                res.result.print;

                if (!logged_failure) {
                    result_.msg ~= Msg(Severity.failReason, "clang-tidy warn about file(s)");
                    logged_failure = true;
                }

                try {
                    result_.msg ~= Msg(Severity.improveSuggestion,
                            format("clang-tidy: fix %s readability and %s warnings in '%s'",
                                res.errors.readability, res.errors.other, res.file));
                } catch (Exception e) {
                    logger.warning(e.msg).collectException;
                    logger.warning("Unable to add user message to the result").collectException;
                }
            }

            result_.status = mergeStatus(result_.status, res.result.status == 0
                    ? Status.passed : Status.failed);
            logger.trace(result_).collectException;
        }

        int expected_replies;
        auto pool = () {
            import std.parallelism : taskPool;

            // must run single threaded when writing fixits or the result is unpredictable
            if (env.clangTidy.applyFixit)
                return new TaskPool(0);
            return taskPool;
        }();

        scope (exit) {
            if (env.clangTidy.applyFixit)
                pool.finish;
        }

        foreach (cmd; UserFileRange(env.compileDb, env.files, null, CompileCommandFilter.init)) {
            if (cmd.isNull) {
                result_.status = Status.failed;
                result_.score -= 100;
                result_.msg ~= Msg(Severity.failReason,
                        "clang-tidy where unable to find one of the specified files in compile_commands.json");
                break;
            }

            ++expected_replies;

            immutable(TidyWork)* w = () @trusted{
                return cast(immutable) new TidyWork(tidyArgs, cmd.cflags, cmd.absoluteFile);
            }();
            auto t = task!taskTidy(thisTid, w);
            pool.put(t);
        }

        int replies;
        while (replies < expected_replies) {
            () @trusted{
                try {
                    if (receiveTimeout(1.dur!"seconds", &handleResult)) {
                        ++replies;
                    }
                } catch (Exception e) {
                    logger.error(e.msg);
                }
            }();
        }
    }

    /// Cleanup after analyze.
    override void tearDown() {
    }

    /// Returns: the result of the analyzer.
    override Result result() {
        return result_;
    }
}

struct TidyResult {
    AbsolutePath file;
    RunResult result;
    CountErrorsResult errors;
}

struct TidyWork {
    string[] args;
    string[] cflags;
    AbsolutePath p;
}

void taskTidy(Tid owner, immutable TidyWork* work_) nothrow @trusted {
    import std.concurrency : send;

    auto tres = new TidyResult;
    TidyWork* work = cast(TidyWork*) work_;

    try {
        tres.file = work.p;
        tres.result = runClangTidy(work.args, work.cflags, work.p);
        tres.errors = countErrors(tres.result.stdout);
    } catch (Exception e) {
        logger.warning(e.msg).collectException;
    }

    while (true) {
        try {
            owner.send(cast(immutable) tres);
            break;
        } catch (Exception e) {
            logger.tracef("failed sending to: %s", owner).collectException;
        }
    }
}

struct ClangTidyConstants {
    static immutable bin = "clang-tidy";
    static immutable confFile = ".clang-tidy";
}

auto runClangTidy(string[] tidy_args, string[] compiler_args, AbsolutePath fname) {
    import std.algorithm : map, copy;
    import std.format : format;
    import std.array : appender;
    import code_checker.process;

    auto app = appender!(string[])();
    app.put(ClangTidyConstants.bin);
    app.put("-warnings-as-errors=*");
    app.put("-p=.");
    tidy_args.copy(app);
    app.put(fname);

    return run(app.data);
}

alias CountErrorsResult = Tuple!(int, "total", int, "readability", int, "other");

/// Count the number of lines with a error: message in it.
CountErrorsResult countErrors(string[] lines) @trusted {
    import std.algorithm;
    import std.regex : ctRegex, matchFirst;
    import std.string : startsWith;

    CountErrorsResult r;

    auto re_error = ctRegex!(`.*:\d*:.*error:.*\[(.*)\]`);

    foreach (a; lines.map!(a => matchFirst(a, re_error)).filter!(a => a.length > 1)) {
        if (a[1].startsWith("readability-"))
            r.readability++;
        else
            r.other++;
    }

    return r;
}
