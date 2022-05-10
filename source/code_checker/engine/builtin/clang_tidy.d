/**
Copyright: Copyright (c) 2018, Joakim Brännström. All rights reserved.
License: $(LINK2 http://www.boost.org/LICENSE_1_0.txt, Boost Software License 1.0)
Author: Joakim Brännström (joakim.brannstrom@gmx.com)

This file contains an analyzer that uses clang-tidy.
*/
module code_checker.engine.builtin.clang_tidy;

import logger = std.experimental.logger;
import std.algorithm : copy, map, joiner, filter, among;
import std.array : appender, array, empty;
import std.concurrency : Tid, thisTid;
import std.exception : collectException;
import std.file : exists;
import std.format : format;
import std.path : buildPath;
import std.process : spawnProcess, wait;
import std.range : put, only, enumerate, chain;
import std.typecons : Tuple;

import colorlog;
import my.path : AbsolutePath;
import my.filter : ReFilter;

import code_checker.cli : Config;
import code_checker.engine.builtin.clang_tidy_classification : CountErrorsResult;
import code_checker.engine.types;
import code_checker.process : RunResult;

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
        import std.conv : text;
        import code_checker.engine.builtin.clang_tidy_classification : filterSeverity,
            diagnosticSeverity;
        import code_checker.utility : replaceConfigWords;

        const systemConf = AbsolutePath(only(env.conf.clangTidy.systemConfig)
                .replaceConfigWords.front);

        auto app = appender!(string[])();
        app.put(env.conf.clangTidy.binary);

        app.put("-p=.");

        if (env.conf.clangTidy.applyFixit) {
            app.put(["--fix"]);
        } else if (env.conf.clangTidy.applyFixitErrors) {
            app.put(["--fix-errors"]);
        }

        if (!env.conf.clangTidy.checkExtensions.empty)
            ["--checks", env.conf.clangTidy.checkExtensions.joiner(",").text].copy(app);

        chain(env.conf.compiler.flags, env.conf.compiler.extraFlags).map!(
                a => ["--extra-arg", a]).joiner.copy(app);

        ["--header-filter", env.conf.clangTidy.headerFilter].copy(app);

        if (exists(ClangTidyConstants.confFile)
                && !isCodeCheckerConfig(AbsolutePath(ClangTidyConstants.confFile))) {
            logger.infof("Using local '%s' config", ClangTidyConstants.confFile);

            if (env.conf.staticCode.severity != typeof(env.conf.staticCode.severity).min) {
                logger.warningf("--severity do not work when using a local '%s'",
                        ClangTidyConstants.confFile);
            }
        } else {
            logger.tracef("Writing to %s using %s", ClangTidyConstants.confFile, systemConf);
            writeClangTidyConfig(systemConf, env.conf);
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
    ExpectedReplyCounter cond;

    void handleResult(immutable(TidyResult)* res_) @trusted nothrow {
        import std.format : format;
        import std.typecons : nullableRef;
        import colorlog : Color, color, Background, Mode;
        import code_checker.engine.builtin.clang_tidy_classification : mapClangTidy;
        import code_checker.process : exitCodeSegFault;

        auto res = nullableRef(cast() res_);

        logger.infof("%s/%s %s '%s'", cond.replies + 1, cond.expected,
                "clang-tidy analyzed".color(Color.yellow).bg(Background.black), res.file)
            .collectException;

        result_.supp += res.suppressedWarnings;

        if (res.clangTidyStatus == 0) {
            if (res.toolFailed)
                result_.analyzerFailed ~= res.file;
            else if (res.timeout)
                result_.timeout ~= res.file;
            else
                result_.success ~= res.file;
        } else if (res.clangTidyStatus == exitCodeSegFault) {
            res.print;
            result_.msg ~= Msg(MsgSeverity.failReason, "clang-tidy segfaulted for " ~ res.file);
        } else {
            result_.score += res.errors.score;
            result_.failed ~= res.file;
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

        // by treating a segfault as OK it wont block a pull request. this may be a bad idea....
        result_.status = mergeStatus(result_.status, res.clangTidyStatus.among(0,
                exitCodeSegFault) ? Status.passed : Status.failed);
    }

    auto pool = new TaskPool;
    scope (exit)
        pool.finish;

    auto file_filter = ReFilter(env.conf.staticCode.fileIncludeFilter,
            env.conf.staticCode.fileExcludeFilter);
    auto fixedDb = toRange(env);

    foreach (p; fixedDb) {
        if (!exists(p.cmd.absoluteFile.toString)) {
            result_.status = Status.failed;
            result_.score -= 100;
            result_.msg ~= Msg(MsgSeverity.failReason, "clang-tidy where unable to find " ~ p.cmd.absoluteFile.toString ~ " in compile_commands.json on the filesystem. Your compile_commands.json is probably out of sync. Regenerate it.");
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
                        !env.conf.logg.toFile, env.conf.staticCode.fileExcludeFilter,
                        env.conf.staticCode.fileIncludeFilter);
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

    void executeTidy(AbsolutePath file) {
        auto args = tidyArgs ~ file;
        logger.tracef("run: %s", args);

        auto status = spawnProcess(args).wait;
        if (status == 0) {
            result_.success ~= file;
        } else {
            result_.failed ~= file;
            result_.status = Status.failed;
            result_.score -= 100;
            result_.msg ~= Msg(MsgSeverity.failReason, "clang-tidy failed to apply fixes for "
                    ~ file ~ ". Use --clang-tidy-fix-errors to forcefully apply the fixes");
        }
    }

    auto file_filter = ReFilter(env.conf.staticCode.fileIncludeFilter,
            env.conf.staticCode.fileExcludeFilter);
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

    /// clang-tidy triggered timeout.
    bool timeout;

    /// The tool failed to analyze the file.
    bool toolFailed;

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
    string[] fileIncludeFilter;
}

void taskTidy(Tid owner, immutable TidyWork* work_) nothrow @trusted {
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

    ReFilter file_filter;
    try {
        file_filter = ReFilter(work.fileIncludeFilter, work.fileExcludeFilter);
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

        // clang-tidy returns exit status '0' and warnings if it successfully run.

        if (count_errors != 0) {
            tres.clangTidyStatus = 1;
        } else if (res.timeout) {
            // a timeout is not an error to the user thus use a clean exit status.
            tres.clangTidyStatus = 0;
            tres.timeout = res.timeout;
        } else if (res.status != 0 && count_errors != 0) {
            // happens when there is e.g. a compilation error and warnings
            tres.clangTidyStatus = res.status;
        } else if (res.status != 0 && count_errors == 0) {
            // the tool reported error but no errors where found thus the user
            // can't actually do anything.
            tres.toolFailed = true;
            tres.clangTidyStatus = 0;
        }

        res.stderr.copy(app);
        tres.output = app.data;
    } catch (Exception e) {
        logger.warning(e.msg).collectException;
    }

    sendToOwner;
}

struct ClangTidyConstants {
    static immutable confFile = ".clang-tidy";
    static immutable codeCheckerConfigHeader = "# GENERATED by code_checker";
}

auto runClangTidy(string[] tidy_args, AbsolutePath[] fname) {
    import code_checker.process;

    auto app = appender!(string[])();
    tidy_args.copy(app);
    fname.copy(app);

    auto rval = run(app.data);
    if (rval.status == exitCodeSegFault)
        return run(app.data);
    return rval;
}

bool isCodeCheckerConfig(AbsolutePath fname) @trusted nothrow {
    import std.stdio : File;

    try {
        foreach (l; File(fname).byLine) {
            return l == ClangTidyConstants.codeCheckerConfigHeader;
        }
        return false;
    } catch (Exception e) {
        logger.trace(fname).collectException;
        logger.trace(e.msg).collectException;
    }

    return false;
}

void writeClangTidyConfig(AbsolutePath baseConf, Config conf) @trusted {
    import std.file : exists;
    import std.stdio : File;
    import std.ascii;
    import std.string;
    import code_checker.engine.builtin.clang_tidy_classification : filterSeverity;

    if (!exists(baseConf)) {
        logger.warning("No default clang-tidy configuration found at ", baseConf);
        logger.info("Using clang-tidy with default settings");
        return;
    }

    auto fconfig = File(ClangTidyConstants.confFile, "w");
    fconfig.writeln(ClangTidyConstants.codeCheckerConfigHeader);

    string[] checks = () {
        if (conf.staticCode.severity != typeof(conf.staticCode.severity).min)
            return filterSeverity!(a => a < conf.staticCode.severity).map!(a => "-" ~ a).array;
        return null;
    }();

    if (checks.empty) {
        foreach (d; File(baseConf).byChunk(4096))
            fconfig.rawWrite(d);
    } else {
        enum State {
            other,
            checkKey,
            openCheck,
            insideCheck,
            closeCheck,
            afterCheck
        }

        State st;
        foreach (l; File(baseConf).byLine) {
            auto curr = l;

            if (st == State.afterCheck) {
                fconfig.writeln(l);
            } else {
                while (!curr.empty) {
                    const auto old = st;
                    final switch (st) {
                    case State.other:
                        if (curr.startsWith("Checks:")) {
                            st = State.checkKey;
                        } else {
                            fconfig.write(curr[0]);
                            curr = curr[1 .. $];
                        }
                        break;
                    case State.checkKey:
                        if (curr[0].among('"', '\'')) {
                            st = State.openCheck;
                        } else {
                            fconfig.write(curr[0]);
                            curr = curr[1 .. $];
                        }
                        break;
                    case State.openCheck:
                        fconfig.write(curr[0]);
                        curr = curr[1 .. $];
                        st = State.insideCheck;
                        break;
                    case State.insideCheck:
                        if (curr[0].among('"', '\'')) {
                            st = State.closeCheck;
                        } else {
                            fconfig.write(curr[0]);
                            curr = curr[1 .. $];
                        }
                        break;
                    case State.closeCheck:
                        curr = curr[1 .. $];
                        st = State.afterCheck;
                        break;
                    case State.afterCheck:
                        fconfig.write(curr[0]);
                        curr = curr[1 .. $];
                        break;
                    }

                    debug logger.tracef(old != st, "%s -> %s : %s", old, st, curr);

                    if (st == State.closeCheck) {
                        fconfig.writeln(",\\");
                        fconfig.write(checks.joiner(","));
                        fconfig.write(curr[0]);
                    }
                }

                fconfig.writeln;
            }
        }
        fconfig.writeln;
    }

    foreach (kv; conf.clangTidy.optionExtensions.byKeyValue) {
        fconfig.writeln("   - key:             ", kv.key);
        fconfig.writefln("     value:           '%s'", kv.value);
    }
}
