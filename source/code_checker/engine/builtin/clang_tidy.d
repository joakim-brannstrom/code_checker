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

import code_checker.engine.builtin.clang_tidy_classification : countErrors,
    CountErrorsResult;
import code_checker.engine.types;
import code_checker.process : RunResult;
import code_checker.types;

@safe:

class ClangTidy : BaseFixture {
    private {
        Environment env;
        Result result_;
        string[] tidyArgs;
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
        import std.format : format;
        import code_checker.engine.builtin.clang_tidy_classification : severityMap,
            Severity;

        auto app = appender!(string[])();

        app.put("-p=.");

        if (env.clangTidy.applyFixit) {
            app.put(["-fix"]);
        } else if (env.clangTidy.applyFixitErrors) {
            app.put(["-fix-errors"]);
        } else {
            app.put("-warnings-as-errors=*");
        }

        env.compiler.extraFlags.map!(a => ["-extra-arg", a]).joiner.copy(app);

        ["-header-filter", env.clangTidy.headerFilter].copy(app);

        // inactivate those that are below the configured severity level.
        // dfmt off
        env.clangTidy.checks ~= severityMap
            .byKeyValue
            .filter!(a => a.value < env.staticCode.severity)
            .map!(a => format("-%s", a.key))
            .array;
        // dfmt on

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
        if (env.clangTidy.applyFixit || env.clangTidy.applyFixitErrors) {
            executeFixit(env, tidyArgs, result_);
        } else {
            executeParallel(env, tidyArgs, result_);
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

void executeParallel(Environment env, string[] tidyArgs, ref Result result_) {
    import core.time : dur;
    import std.concurrency : Tid, thisTid, receiveTimeout;
    import std.format : format;
    import std.parallelism : task, TaskPool;
    import code_checker.compile_db : UserFileRange, parseFlag,
        CompileCommandFilter, SearchResult;
    import code_checker.engine.logger : Logger;

    bool logged_failure;
    auto logg = Logger(env.logg.dir);

    void handleResult(immutable(TidyResult)* res_) @trusted nothrow {
        import std.format : format;
        import std.typecons : nullableRef;
        import colorize : Color, color, Background, Mode;

        auto res = nullableRef(cast() res_);

        logger.infof("%s '%s'", "clang-tidy analyzing".color(Color.yellow,
                Background.black), res.file).collectException;

        result_.score += res.result.status == 0 ? 1 : res.errors.score;

        if (res.result.status != 0) {
            res.result.print;

            if (env.logg.toFile) {
                try {
                    logg.put(res.file, [res.result.stdout, res.result.stdout]);
                } catch (Exception e) {
                    logger.warning(e.msg).collectException;
                    logger.warning("Unable to log to file").collectException;
                }
            }

            if (!logged_failure) {
                result_.msg ~= Msg(MsgSeverity.failReason, "clang-tidy warn about file(s)");
                logged_failure = true;
            }

            try {
                result_.msg ~= Msg(MsgSeverity.improveSuggestion,
                        format("clang-tidy: %-(%s, %) in %s", res.errors.toRange, res.file));
            } catch (Exception e) {
                logger.warning(e.msg).collectException;
                logger.warning("Unable to add user message to the result").collectException;
            }
        }

        result_.status = mergeStatus(result_.status, res.result.status == 0
                ? Status.passed : Status.failed);
        logger.trace(result_).collectException;
    }

    auto pool = new TaskPool;
    scope (exit)
        pool.finish;

    static struct DoneCondition {
        int expected;
        int replies;

        bool isWaitingForReplies() {
            return replies < expected;
        }
    }

    DoneCondition cond;

    foreach (cmd; UserFileRange(env.compileDb, env.files, env.compiler.extraFlags, env.flagFilter)) {
        if (cmd.isNull) {
            result_.status = Status.failed;
            result_.score -= 100;
            result_.msg ~= Msg(MsgSeverity.failReason,
                    "clang-tidy where unable to find one of the specified files in compile_commands.json");
            break;
        }

        cond.expected++;

        immutable(TidyWork)* w = () @trusted{
            return cast(immutable) new TidyWork(tidyArgs, cmd.absoluteFile);
        }();
        auto t = task!taskTidy(thisTid, w);
        pool.put(t);
    }

    while (cond.isWaitingForReplies) {
        () @trusted{
            try {
                if (receiveTimeout(1.dur!"seconds", &handleResult)) {
                    cond.replies++;
                }
            } catch (Exception e) {
                logger.error(e.msg);
            }
        }();
    }
}

/// Run clang-tidy with to fix the code.
void executeFixit(Environment env, string[] tidyArgs, ref Result result_) {
    import std.algorithm : copy, map;
    import std.array : array;
    import std.path : buildPath;
    import std.process : spawnProcess, wait;
    import code_checker.compile_db : UserFileRange, CompileCommandFilter;
    import code_checker.engine.logger : Logger;

    AbsolutePath[] files;
    auto logg = Logger(env.logg.dir);

    if (env.logg.toFile) {
        logg.setup;
        tidyArgs ~= ["-export-fixes", buildPath(env.logg.dir, "fixes.yaml")];
    }

    foreach (cmd; UserFileRange(env.compileDb, env.files, null, CompileCommandFilter.init)) {
        if (cmd.isNull) {
            result_.status = Status.failed;
            result_.score -= 100;
            result_.msg ~= Msg(MsgSeverity.failReason,
                    "clang-tidy where unable to find one of the specified files in compile_commands.json");
            break;
        }
        files ~= cmd.absoluteFile;
    }

    auto args = [ClangTidyConstants.bin] ~ tidyArgs ~ files.map!(a => cast(string) a).array;
    logger.tracef("run: %s", args);

    auto status = spawnProcess(args).wait;
    if (status != 0) {
        result_.status = Status.failed;
        result_.score -= 1000;
        result_.msg ~= Msg(MsgSeverity.failReason, "clang-tidy failed to apply fixes");
    }
}

struct TidyResult {
    AbsolutePath file;
    RunResult result;
    CountErrorsResult errors;
}

struct TidyWork {
    string[] args;
    AbsolutePath p;
}

void taskTidy(Tid owner, immutable TidyWork* work_) nothrow @trusted {
    import std.concurrency : send;

    auto tres = new TidyResult;
    TidyWork* work = cast(TidyWork*) work_;

    try {
        tres.file = work.p;
        tres.result = runClangTidy(work.args, [work.p]);
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

auto runClangTidy(string[] tidy_args, AbsolutePath[] fname) {
    import std.algorithm : copy;
    import std.format : format;
    import std.array : appender;
    import code_checker.process;

    auto app = appender!(string[])();
    app.put(ClangTidyConstants.bin);
    tidy_args.copy(app);
    fname.copy(app);

    return run(app.data);
}
