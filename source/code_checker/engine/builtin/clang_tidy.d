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

import code_checker.engine.builtin.clang_tidy_classification : CountErrorsResult;
import code_checker.engine.file_filter;
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
        import code_checker.engine.builtin.clang_tidy_classification : filterSeverity;

        auto app = appender!(string[])();
        app.put(env.clangTidy.binary);

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
        env.clangTidy.checks ~=
            filterSeverity!(a => a < env.staticCode.severity)
            .map!(a => format("-%s", a))
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

        tidyArgs = app.data;
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

struct ExpectedReplyCounter {
    int expected;
    int replies;

    bool isWaitingForReplies() {
        return replies < expected;
    }
}

void executeParallel(Environment env, string[] tidyArgs, ref Result result_) @safe {
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
        import std.array : appender;
        import std.format : format;
        import std.typecons : nullableRef;
        import colorlog : Color, color, Background, Mode;
        import code_checker.engine.builtin.clang_tidy_classification : mapClangTidy;

        auto res = nullableRef(cast() res_);

        logger.infof("%s '%s'", "clang-tidy analyzing".color(Color.yellow)
                .bg(Background.black), res.file).collectException;

        result_.score += res.clangTidyStatus == 0 ? 1 : res.errors.score;

        if (res.clangTidyStatus != 0) {
            res.print;

            if (env.logg.toFile) {
                try {
                    logg.put(res.file, [res.output]);
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

        result_.status = mergeStatus(result_.status, res.clangTidyStatus == 0
                ? Status.passed : Status.failed);
        logger.trace(result_).collectException;
    }

    auto pool = new TaskPool;
    scope (exit)
        pool.finish;

    ExpectedReplyCounter cond;

    auto file_filter = FileFilter(env.staticCode.fileExcludeFilter);
    foreach (cmd; UserFileRange(env.compileDb, env.files, env.compiler.extraFlags, env.flagFilter)) {
        if (cmd.isNull) {
            result_.status = Status.failed;
            result_.score -= 100;
            result_.msg ~= Msg(MsgSeverity.failReason, "clang-tidy where unable to find one of the specified files in compile_commands.json on the filesystem. Your compile_commands.json is probably out of sync. Regenerate it.");
            break;
        } else if (!file_filter.match(cmd.absoluteFile)) {
            if (logger.globalLogLevel == logger.LogLevel.all)
                result_.msg ~= Msg(MsgSeverity.trace,
                        format("Skipping analyze because it didn't pass the file filter (user supplied regex): %s ",
                            cmd.absoluteFile));
            continue;
        }

        cond.expected++;

        immutable(TidyWork)* w = () @trusted{
            return cast(immutable) new TidyWork(tidyArgs, cmd.absoluteFile,
                    !env.logg.toFile, env.staticCode.fileExcludeFilter);
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
    import std.format : format;
    import std.path : buildPath;
    import std.process : spawnProcess, wait;
    import std.range : enumerate;
    import code_checker.compile_db : UserFileRange, CompileCommandFilter;
    import code_checker.engine.logger : Logger;

    AbsolutePath[] files;
    auto logg = Logger(env.logg.dir);

    if (env.logg.toFile) {
        logg.setup;
        tidyArgs ~= ["-export-fixes", buildPath(env.logg.dir, "fixes.yaml")];
    }

    void executeTidy(string file) {
        auto args = tidyArgs ~ file;
        logger.tracef("run: %s", args);

        auto status = spawnProcess(args).wait;
        if (status != 0) {
            result_.status = Status.failed;
            result_.score -= 100;
            result_.msg ~= Msg(MsgSeverity.failReason, "clang-tidy failed to apply fixes for "
                    ~ file ~ ". Use --clang-tidy-fix-errors to forcefully apply the fixes");
        }
    }

    auto file_filter = FileFilter(env.staticCode.fileExcludeFilter);
    auto cmds = UserFileRange(env.compileDb, env.files, env.compiler.extraFlags, env.flagFilter)
        .array;
    const max_nr = cmds.length;
    foreach (idx, cmd; cmds.enumerate) {
        if (cmd.isNull) {
            result_.status = Status.failed;
            result_.score -= 1000;
            result_.msg ~= Msg(MsgSeverity.failReason, "clang-tidy where unable to find one of the specified files in compile_commands.json on the filesystem. Your compile_commands.json is probably out of sync. Regenerate it.");
            continue;
        } else if (!file_filter.match(cmd.absoluteFile)) {
            if (logger.globalLogLevel == logger.LogLevel.all)
                result_.msg ~= Msg(MsgSeverity.trace,
                        format("Skipping analyze because it didn't pass the file filter (user supplied regex): %s ",
                            cmd.absoluteFile));
            continue;
        }

        logger.infof("File %s/%s %s", idx + 1, max_nr, cmd.absoluteFile);
        executeTidy(cmd.absoluteFile);
    }
}

struct TidyResult {
    AbsolutePath file;
    CountErrorsResult errors;

    /// Exit status from running clang tidy
    int clangTidyStatus;

    /// Output to the user
    string[] output;

    void print() @safe nothrow const scope {
        import std.ascii : newline;
        import std.stdio : writeln;

        foreach (l; output)
            writeln(l).collectException;
    }
}

struct TidyWork {
    string[] args;
    AbsolutePath p;
    bool useColors;
    string[] fileExcludeFilter;
}

void taskTidy(Tid owner, immutable TidyWork* work_) nothrow @trusted {
    import std.algorithm : copy;
    import std.array : appender;
    import std.concurrency : send;
    import std.format : format;
    import code_checker.engine.builtin.clang_tidy_classification : mapClangTidy,
        Severity, color;

    auto tres = new TidyResult;
    TidyWork* work = cast(TidyWork*) work_;

    void sendToOwner() {
        while (true) {
            try {
                owner.send(cast(immutable) tres);
                break;
            } catch (Exception e) {
                logger.tracef("failed sending to: %s", owner).collectException;
            }
        }
    }

    FileFilter file_filter;
    try {
        file_filter = FileFilter(work.fileExcludeFilter);
    } catch (Exception e) {
        logger.error(e.msg).collectException;
        tres.clangTidyStatus = -1;
        sendToOwner;
        return;
    }

    try {
        // there may be warnings that are skipped. If all warnings are skipped
        // and thus the counter is zero the result should be an automatic
        // passed. This is because it means that all warnings where from a file
        // that where excluded.
        int count_errors;

        string diagMsg(Severity s, string diag, string file) {
            if (!file_filter.match(file))
                return null;

            count_errors++;
            tres.errors.put(s);
            if (work.useColors)
                return format("%s[%s]", diag, color(s));
            return format("%s[%s]", diag, s);
        }

        tres.file = work.p;

        auto res = runClangTidy(work.args, [work.p]);
        auto app = appender!(string[])();
        mapClangTidy!diagMsg(res.stdout, app);

        if (count_errors > 0) {
            tres.clangTidyStatus = res.status;
            res.stderr.copy(app);
            tres.output = app.data;
        }
    } catch (Exception e) {
        logger.warning(e.msg).collectException;
    }

    sendToOwner;
}

struct ClangTidyConstants {
    static immutable confFile = ".clang-tidy";
}

auto runClangTidy(string[] tidy_args, AbsolutePath[] fname) {
    import std.algorithm : copy;
    import std.array : appender;
    import code_checker.process;

    auto app = appender!(string[])();
    tidy_args.copy(app);
    fname.copy(app);

    return run(app.data);
}
