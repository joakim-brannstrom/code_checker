/**
Copyright: Copyright (c) 2018, Joakim Brännström. All rights reserved.
License: $(LINK2 http://www.boost.org/LICENSE_1_0.txt, Boost Software License 1.0)
Author: Joakim Brännström (joakim.brannstrom@gmx.com)

This file contains an analyzer that uses clang-tidy.
*/
module code_checker.engine.builtin.clang_tidy;

import logger = std.experimental.logger;
import std.algorithm : copy, map, joiner, filter;
import std.array : appender, array;
import std.concurrency : Tid, thisTid;
import std.exception : collectException;
import std.file : exists;
import std.format : format;
import std.path : buildPath;
import std.process : spawnProcess, wait;
import std.range : put, only, enumerate;
import std.typecons : Tuple;

import colorlog;

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

    override string name() {
        return "clang-tidy";
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
        import code_checker.engine.builtin.clang_tidy_classification : filterSeverity,
            diagnosticSeverity;

        auto app = appender!(string[])();
        app.put(env.conf.clangTidy.binary);

        app.put("-p=.");

        if (env.conf.clangTidy.applyFixit) {
            app.put(["-fix"]);
        } else if (env.conf.clangTidy.applyFixitErrors) {
            app.put(["-fix-errors"]);
        }

        env.conf.compiler.extraFlags.map!(a => ["-extra-arg", a]).joiner.copy(app);

        ["-header-filter", env.conf.clangTidy.headerFilter].copy(app);

        auto checks = env.conf.clangTidy.checks;
        // inactivate those that are below the configured severity level.
        if (env.conf.staticCode.severity != typeof(env.conf.staticCode.severity).min) {
            checks = only(["-*"],
                    filterSeverity!(a => a >= env.conf.staticCode.severity).array, checks).joiner.filter!(a => a != "*")
                .array;
        }

        if (exists(ClangTidyConstants.confFile)) {
            logger.infof("Using clang-tidy settings from the local '%s'",
                    ClangTidyConstants.confFile);
        } else {
            logger.trace("Using config from the TOML file");

            auto c = appender!string();
            c.put(`{Checks: "`);
            only(checks, env.conf.clangTidy.checkExtensions).joiner.joiner(",").copy(c);
            c.put(`",`);
            c.put("CheckOptions: [");
            only(env.conf.clangTidy.options, env.conf.clangTidy.optionExtensions).joiner.joiner(",")
                .copy(c);
            c.put("]");
            c.put("}");

            app.put("-config");
            app.put(c.data);
        }

        tidyArgs = app.data;
    }

    /// Execute the analyzer.
    override void execute() {
        if (env.conf.clangTidy.applyFixit || env.conf.clangTidy.applyFixitErrors) {
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
    import code_checker.engine.compile_db;
    import code_checker.engine.logger : Logger;

    bool logged_failure;
    auto logg = Logger(env.conf.logg.dir);

    void handleResult(immutable(TidyResult)* res_) @trusted nothrow {
        import std.array : appender;
        import std.format : format;
        import std.typecons : nullableRef;
        import colorlog : Color, color, Background, Mode;
        import code_checker.engine.builtin.clang_tidy_classification : mapClangTidy;

        auto res = nullableRef(cast() res_);

        logger.infof("%s '%s'", "clang-tidy analyzing".color(Color.yellow)
                .bg(Background.black), res.file).collectException;

        result_.score += res.errors.score;
        result_.supp += res.suppressedWarnings;

        if (res.clangTidyStatus != 0) {
            res.print;

            if (env.conf.logg.toFile) {
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
    }

    auto pool = new TaskPool;
    scope (exit)
        pool.finish;

    ExpectedReplyCounter cond;

    auto file_filter = FileFilter(env.conf.staticCode.fileExcludeFilter);
    auto fixedDb = toRange(env);

    foreach (p; fixedDb) {
        if (!exists(p.cmd.absoluteFile.toString)) {
            result_.status = Status.failed;
            result_.score -= 100;
            result_.msg ~= Msg(MsgSeverity.failReason, "clang-tidy where unable to find one of the specified files in compile_commands.json on the filesystem. Your compile_commands.json is probably out of sync. Regenerate it.");
            break;
        } else if (!file_filter.match(p.cmd.absoluteFile)) {
            if (logger.globalLogLevel == logger.LogLevel.all)
                result_.msg ~= Msg(MsgSeverity.trace,
                        format("Skipping analyze because it didn't pass the file filter (user supplied regex): %s ",
                            p.cmd.absoluteFile));
        } else {
            cond.expected++;

            immutable(TidyWork)* w = () @trusted {
                return cast(immutable) new TidyWork(tidyArgs, p.cmd.absoluteFile,
                        !env.conf.logg.toFile, env.conf.staticCode.fileExcludeFilter);
            }();
            auto t = task!taskTidy(thisTid, w);
            pool.put(t);
        }
    }

    while (cond.isWaitingForReplies) {
        () @trusted {
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
    import code_checker.engine.logger : Logger;
    import code_checker.engine.compile_db;

    auto logg = Logger(env.conf.logg.dir);

    if (env.conf.logg.toFile) {
        logg.setup;
        tidyArgs ~= [
            "-export-fixes", buildPath(env.conf.logg.dir, "fixes.yaml")
        ];
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

    auto file_filter = FileFilter(env.conf.staticCode.fileExcludeFilter);
    auto fixedDb = toRange(env);

    const max_nr = fixedDb.length;
    foreach (idx, cmd; fixedDb.enumerate) {
        if (!file_filter.match(cmd.cmd.absoluteFile)) {
            if (logger.globalLogLevel == logger.LogLevel.all)
                result_.msg ~= Msg(MsgSeverity.trace,
                        format("Skipping analyze because it didn't pass the file filter (user supplied regex): %s ",
                            cmd.cmd.absoluteFile));
        } else {
            logger.infof("File %s/%s %s", idx + 1, max_nr, cmd.cmd.absoluteFile);
            executeTidy(cmd.cmd.absoluteFile);
        }
    }
}

struct TidyResult {
    AbsolutePath file;
    CountErrorsResult errors;

    int suppressedWarnings;

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
        mapClangTidyStats, DiagMessage, StatMessage, color;

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

        bool diagMsg(ref DiagMessage msg) {
            if (!file_filter.match(msg.file))
                return false;

            count_errors++;
            tres.errors.put(msg.severity);
            if (work.useColors)
                msg.diagnostic = format("%s[%s]", msg.diagnostic, color(msg.severity));
            else
                msg.diagnostic = format("%s[%s]", msg.diagnostic, msg.severity);
            return true;
        }

        void statMsg(StatMessage msg) {
            tres.suppressedWarnings = msg.nolint;
            tres.errors.setSuppressed(msg.nolint);
        }

        tres.file = work.p;

        auto res = runClangTidy(work.args, [work.p]);

        auto app = appender!(string[])();
        mapClangTidy!diagMsg(res.stdout, app);

        mapClangTidyStats!statMsg(res.stderr);

        tres.clangTidyStatus = res.status != 0 ? res.status : count_errors;

        if (tres.clangTidyStatus != 0) {
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
