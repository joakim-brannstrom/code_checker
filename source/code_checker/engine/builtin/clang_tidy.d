/**
Copyright: Copyright (c) 2018, Joakim Brännström. All rights reserved.
License: $(LINK2 http://www.boost.org/LICENSE_1_0.txt, Boost Software License 1.0)
Author: Joakim Brännström (joakim.brannstrom@gmx.com)

This file contains an analyzer that uses clang-tidy.
*/
module code_checker.engine.builtin.clang_tidy;

import logger = std.experimental.logger;
import std.algorithm : copy, map, joiner, filter, among, max;
import std.array : appender, array, empty;
import std.concurrency : Tid, thisTid;
import std.exception : collectException;
import std.file : exists;
import std.format : format;
import std.path : buildPath;
import std.process : spawnProcess, wait;
import std.range : put, only, enumerate, chain;
import std.typecons : Tuple;
import std.datetime : Clock, SysTime;
import core.time : dur, Duration;

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
        import code_checker.engine.builtin.clang_tidy_classification : filterSeverity;
        import code_checker.utility : replaceConfigWord;

        const systemConf = AbsolutePath(env.conf.clangTidy.systemConfig.replaceConfigWord);

        auto app = appender!(string[])();
        app.put(env.conf.clangTidy.binary);

        app.put("-p=.");

        if (env.conf.clangTidy.applyFixit) {
            app.put(["--fix"]);
        } else if (env.conf.clangTidy.applyFixitErrors) {
            app.put(["--fix-errors"]);
        }

        if (exists(ClangTidyConstants.confFile)
                && !isCodeCheckerConfig(AbsolutePath(ClangTidyConstants.confFile))) {
            logger.infof("Using local '%s' config", ClangTidyConstants.confFile);

            if (env.conf.staticCode.severity != typeof(env.conf.staticCode.severity).min) {
                logger.warningf("--severity, clang_tidy.header_filter and clang_tidy.exclude_header_filter do not work when using a local '%s' config",
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
        foreach (a; res_.details.byKeyValue) {
            if (auto d = a.key in result_.details)
                *d ~= a.value;
            else
                result_.details[a.key] = a.value.dup;
        }

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
                        env.conf.staticCode.fileIncludeFilter, cond.expected % 2 == 0,
                        Clock.currTime);
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

    /// Detailed information about errors/warnings etc.
    Detail[][AbsolutePath] details;

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
            try {
                writeln(l);
            } catch (Exception e) {
            }
    }
}

struct TidyWork {
    string[] args;
    AbsolutePath p;
    bool useColors;
    string[] fileExcludeFilter;
    string[] fileIncludeFilter;
    bool reduceOnOverload;
    SysTime workQueued;
}

void taskTidy(Tid owner, immutable TidyWork* work_) nothrow @trusted {
    import core.thread : Thread;
    import core.time : dur;
    import std.concurrency : send;
    import std.format : format;
    import std.parallelism : totalCPUs;
    import code_checker.engine.builtin.clang_tidy_classification : mapClangTidy,
        mapClangTidyStats, DiagMessage, StatMessage, color;

    auto tres = new TidyResult;
    TidyWork* work = cast(TidyWork*) work_;

    void sleepUntilNotOverloaded() {
        import code_checker.utility : osAverageLoad;
        import std.algorithm : max;
        import std.random : uniform;

        if (!work_.reduceOnOverload)
            return;

        // progressively shorten the max wait time until it is <0 after two
        // hours. After two hours the users probably just want to push through
        // even if it overload the system.
        const maxWait = 1.dur!"minutes" - ((Clock.currTime - work_.workQueued)
                .total!"minutes" / 2).dur!"seconds";
        if (maxWait < Duration.zero)
            return;

        const maxWaitTime = Clock.currTime + maxWait;
        const int maxLoadLimit = totalCPUs + 1;
        while (osAverageLoad()[0] > maxLoadLimit && Clock.currTime < maxWaitTime) {
            Thread.sleep(uniform(1, 60).dur!"seconds");
            logger.tracef("Average load too high, waiting to start the next clang-tidy instance. %s > %s",
                    osAverageLoad[0], maxLoadLimit);
        }
    }

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

            auto d = Detail(Msg(MsgSeverity.trace, msg.diagnostic), msg.severity, msg.kind, msg.pos);
            tres.details.update(AbsolutePath(msg.file), { return [d]; }, (ref Detail[] a) {
                a ~= d;
            });

            count_errors++;
            tres.errors.put(msg.severity);
            if (work.useColors)
                msg.diagnostic = format("%s[%s]", msg.fullToolOutput, color(msg.severity));
            else
                msg.diagnostic = format("%s[%s]", msg.fullToolOutput, msg.severity);
            return true;
        }

        void statMsg(StatMessage msg) {
            tres.suppressedWarnings = msg.nolint;
            tres.errors.setSuppressed(msg.nolint);
        }

        tres.file = work.p;

        sleepUntilNotOverloaded();
        auto res = runClangTidy(work.args, work.p);

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

auto runClangTidy(string[] tidy_args, AbsolutePath fname) {
    import code_checker.process;

    auto app = appender!(string[])();
    tidy_args.copy(app);
    app.put(fname);

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

private Tuple!(bool, "include", bool, "exclude") hasConfigHeaderOptions(
        AbsolutePath baseConf, Config conf) {
    import std.stdio : File;
    import std.string : startsWith;

    // Which header filter lines the base config already has, computed once
    // per generated file.
    bool baseHasHeaderFilterRegex;
    bool baseHasExcludeHeaderFilterRegex;
    if (!conf.clangTidy.headerFilter.empty || !conf.clangTidy.headerExcludeFilter.empty) {
        foreach (l; File(baseConf).byLine) {
            if (l.startsWith("HeaderFilterRegex:")) {
                baseHasHeaderFilterRegex = true;
            } else if (l.startsWith("ExcludeHeaderFilterRegex:")) {
                baseHasExcludeHeaderFilterRegex = true;
            }
        }
    }
    return typeof(return)(baseHasHeaderFilterRegex, baseHasExcludeHeaderFilterRegex);
}

/// Returns: true if the value can be written to the generated .clang-tidy unescaped.
private bool isWritableHeaderValue(in char[] value) @safe {
    import std.algorithm.searching : canFind;
    import std.string : endsWith;

    return !value.canFind('\'') && !value.endsWith("\\");
}

void writeClangTidyConfig(AbsolutePath baseConf, Config conf) @trusted {
    writeClangTidyConfig(baseConf, AbsolutePath(ClangTidyConstants.confFile), conf);
}

void writeClangTidyConfig(AbsolutePath baseConf, AbsolutePath outFile, Config conf) @trusted {
    import std.file : exists;
    import std.stdio : File;
    import std.string : startsWith;
    import code_checker.engine.builtin.clang_tidy_classification : filterSeverity;

    if (!exists(baseConf)) {
        logger.warning("No default clang-tidy configuration found at ", baseConf);
        logger.info("Using clang-tidy with default settings");
        return;
    }

    auto fconfig = File(outFile, "w");
    fconfig.writeln(ClangTidyConstants.codeCheckerConfigHeader);

    string[] checks = () {
        if (conf.staticCode.severity != typeof(conf.staticCode.severity).min)
            return filterSeverity!(a => a < conf.staticCode.severity).map!(a => "-" ~ a).array;
        return null;
    }();

    auto hasHeaderConf = hasConfigHeaderOptions(baseConf, conf);

    bool headerFilterPending;
    bool excludeFilterPending;
    bool headerFilterRejected;
    bool excludeFilterRejected;
    void checkHeaderFilter() {
        // A user-set option whose line the base config lacks is warned about and
        // appended to the generated .clang-tidy instead of being silently dropped.
        // A value that cannot be written unescaped (a single quote or a trailing
        // backslash) is rejected instead: the pending append is not scheduled and
        // the reject warning is logged here for every base-config layout - also
        // when the option's line exists but is never reached by the substitution
        // helper, or is reached but rejected (which then skips its own warning).
        const headerFilterUsable = isWritableHeaderValue(conf.clangTidy.headerFilter);
        const excludeFilterUsable = isWritableHeaderValue(conf.clangTidy.headerExcludeFilter);
        const headerFilterMissing = !conf.clangTidy.headerFilter.empty
            && !hasHeaderConf.include && headerFilterUsable;
        headerFilterPending = headerFilterMissing;
        const excludeFilterMissing = !conf.clangTidy.headerExcludeFilter.empty
            && !hasHeaderConf.exclude && excludeFilterUsable;
        excludeFilterPending = excludeFilterMissing;
        headerFilterRejected = !conf.clangTidy.headerFilter.empty && !headerFilterUsable;
        excludeFilterRejected = !conf.clangTidy.headerExcludeFilter.empty && !excludeFilterUsable;
        if (headerFilterRejected) {
            logger.warningf("clang_tidy.%s is ignored; the value contains a single quote or ends with a backslash, which cannot be written unescaped: %s",
                    "header_filter", conf.clangTidy.headerFilter);
        }
        if (excludeFilterRejected) {
            logger.warningf("clang_tidy.%s is ignored; the value contains a single quote or ends with a backslash, which cannot be written unescaped: %s",
                    "exclude_header_filter", conf.clangTidy.headerExcludeFilter);
        }
        if (headerFilterMissing) {
            logger.warningf("clang_tidy.%s is set but the system configuration %s lacks a %s line; the setting is appended to the generated .clang-tidy",
                    "header_filter", baseConf, "HeaderFilterRegex:");
        }
        if (excludeFilterMissing) {
            logger.warningf("clang_tidy.%s is set but the system configuration %s lacks a %s line; the setting is appended to the generated .clang-tidy",
                    "exclude_header_filter", baseConf, "ExcludeHeaderFilterRegex:");
        }
    }

    checkHeaderFilter();

    void writeHeaderfilterOrLine(char[] l) {
        const anchor = l.startsWith("HeaderFilterRegex:");
        if (!conf.clangTidy.headerFilter.empty && anchor) {
            // A value with a single quote or a trailing backslash cannot be
            // written unescaped and would corrupt the generated .clang-tidy:
            // keep the base line instead of writing the user value. The
            // reject warning is logged by checkHeaderFilter for every
            // base-config layout, so this branch stays silent.
            if (isWritableHeaderValue(conf.clangTidy.headerFilter)) {
                fconfig.writeln(format!"HeaderFilterRegex: '%s'"(conf.clangTidy.headerFilter));
            } else {
                if (!headerFilterRejected) {
                    logger.warningf("clang_tidy.%s is ignored; the value contains a single quote or ends with a backslash, which cannot be written unescaped: %s",
                            "header_filter", conf.clangTidy.headerFilter);
                }
                fconfig.writeln(l);
            }
        } else if (!conf.clangTidy.headerExcludeFilter.empty
                && l.startsWith("ExcludeHeaderFilterRegex:")) {
            if (isWritableHeaderValue(conf.clangTidy.headerExcludeFilter)) {
                fconfig.writeln(format!"ExcludeHeaderFilterRegex: '%s'"(
                        conf.clangTidy.headerExcludeFilter));
            } else {
                if (!excludeFilterRejected) {
                    logger.warningf("clang_tidy.%s is ignored; the value contains a single quote or ends with a backslash, which cannot be written unescaped: %s",
                            "exclude_header_filter", conf.clangTidy.headerExcludeFilter);
                }
                fconfig.writeln(l);
            }
        } else {
            fconfig.writeln(l);
        }
        if (anchor && excludeFilterPending) {
            // exclude_header_filter is set but the base config has no
            // ExcludeHeaderFilterRegex line: append it right after the anchor
            // line. header_filter never takes this path because its key line
            // is the anchor itself; it appends at end of file instead. Only
            // the exclude option may pend while the anchor line exists; if
            // this helper ever appends for header_filter too, the pending-flag
            // logic above must change with it.
            fconfig.writeln(format!"ExcludeHeaderFilterRegex: '%s'"(
                    conf.clangTidy.headerExcludeFilter));
            excludeFilterPending = false;
        }
    }

    if (checks.empty) {
        foreach (l; File(baseConf).byLine) {
            writeHeaderfilterOrLine(l);
        }
    } else {
        enum State {
            other,
            checkKey,
            openCheck,
            insideCheck,
            closeCheck,
            afterCheck,
        }

        State st;
        foreach (l; File(baseConf).byLine) {
            auto curr = l;

            if (st == State.afterCheck) {
                writeHeaderfilterOrLine(l);
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
    // A header filter option still pending here has neither its own line nor
    // the HeaderFilterRegex anchor in the base config; append it at end of
    // file so the generated .clang-tidy stays valid YAML. If the base config
    // puts its HeaderFilterRegex: line before the Checks: block, the
    // Checks-rewriting state machine consumes that line before State.afterCheck
    // and the append lands here too - still valid YAML, still exactly one.
    if (headerFilterPending) {
        fconfig.writeln(format!"HeaderFilterRegex: '%s'"(conf.clangTidy.headerFilter));
    }
    if (excludeFilterPending) {
        fconfig.writeln(format!"ExcludeHeaderFilterRegex: '%s'"(
                conf.clangTidy.headerExcludeFilter));
    }
}

@("writeClangTidyConfig substitutes both filter lines when the base config has them")
unittest {
    import std.file : mkdir, write, readText, tempDir, rmdirRecurse;
    import std.path : buildPath;
    import std.uuid : randomUUID;
    import unit_threaded.should : shouldEqual;

    auto dir = buildPath(tempDir(), "code_checker_ut_" ~ randomUUID().toString);
    mkdir(dir);
    scope (exit)
        rmdirRecurse(dir);
    auto baseConf = AbsolutePath(buildPath(dir, "base.conf"));
    write(baseConf,
            "Checks:                 \"-*\"\n" ~ "HeaderFilterRegex:      '.*'\n"
            ~ "ExcludeHeaderFilterRegex: ''\n");
    auto outFile = AbsolutePath(buildPath(dir, ".clang-tidy"));

    auto conf = Config.make(AbsolutePath(dir), AbsolutePath(buildPath(dir, "ut.toml")));
    conf.clangTidy.headerFilter = "my-hdrs";
    conf.clangTidy.headerExcludeFilter = "3rd/.*";

    writeClangTidyConfig(baseConf, outFile, conf);

    readText(outFile).shouldEqual(ClangTidyConstants.codeCheckerConfigHeader ~ "\n" ~ "Checks:                 \"-*\"\n"
            ~ "HeaderFilterRegex: 'my-hdrs'\n" ~ "ExcludeHeaderFilterRegex: '3rd/.*'\n");
}

@("writeClangTidyConfig substitutes HeaderFilterRegex in place when only it is in the base config")
unittest {
    import std.file : mkdir, write, readText, tempDir, rmdirRecurse;
    import std.path : buildPath;
    import std.uuid : randomUUID;
    import unit_threaded.should : shouldEqual;

    auto dir = buildPath(tempDir(), "code_checker_ut_" ~ randomUUID().toString);
    mkdir(dir);
    scope (exit)
        rmdirRecurse(dir);
    auto baseConf = AbsolutePath(buildPath(dir, "base.conf"));
    write(baseConf, "Checks:                 \"-*\"\n" ~ "HeaderFilterRegex:      '.*'\n");
    auto outFile = AbsolutePath(buildPath(dir, ".clang-tidy"));

    auto conf = Config.make(AbsolutePath(dir), AbsolutePath(buildPath(dir, "ut.toml")));
    conf.clangTidy.headerFilter = "my-hdrs";

    writeClangTidyConfig(baseConf, outFile, conf);

    readText(outFile).shouldEqual(ClangTidyConstants.codeCheckerConfigHeader
            ~ "\n" ~ "Checks:                 \"-*\"\n" ~ "HeaderFilterRegex: 'my-hdrs'\n");
}

@("writeClangTidyConfig appends ExcludeHeaderFilterRegex after the HeaderFilterRegex anchor when the exclude line is missing")
unittest {
    import std.file : mkdir, write, readText, tempDir, rmdirRecurse;
    import std.path : buildPath;
    import std.uuid : randomUUID;
    import unit_threaded.should : shouldEqual;

    auto dir = buildPath(tempDir(), "code_checker_ut_" ~ randomUUID().toString);
    mkdir(dir);
    scope (exit)
        rmdirRecurse(dir);
    auto baseConf = AbsolutePath(buildPath(dir, "base.conf"));
    write(baseConf, "Checks:                 \"-*\"\n" ~ "HeaderFilterRegex:      '.*'\n");
    auto outFile = AbsolutePath(buildPath(dir, ".clang-tidy"));

    auto conf = Config.make(AbsolutePath(dir), AbsolutePath(buildPath(dir, "ut.toml")));
    conf.clangTidy.headerFilter = "my-hdrs";
    conf.clangTidy.headerExcludeFilter = "3rd/.*";

    writeClangTidyConfig(baseConf, outFile, conf);

    readText(outFile).shouldEqual(ClangTidyConstants.codeCheckerConfigHeader ~ "\n" ~ "Checks:                 \"-*\"\n"
            ~ "HeaderFilterRegex: 'my-hdrs'\n" ~ "ExcludeHeaderFilterRegex: '3rd/.*'\n");
}

@(
        "writeClangTidyConfig appends ExcludeHeaderFilterRegex at end of file when the base config has neither filter line")
unittest {
    import std.file : mkdir, write, readText, tempDir, rmdirRecurse;
    import std.path : buildPath;
    import std.uuid : randomUUID;
    import unit_threaded.should : shouldEqual;

    auto dir = buildPath(tempDir(), "code_checker_ut_" ~ randomUUID().toString);
    mkdir(dir);
    scope (exit)
        rmdirRecurse(dir);
    auto baseConf = AbsolutePath(buildPath(dir, "base.conf"));
    write(baseConf, "Checks:                 \"-*\"\n");
    auto outFile = AbsolutePath(buildPath(dir, ".clang-tidy"));

    auto conf = Config.make(AbsolutePath(dir), AbsolutePath(buildPath(dir, "ut.toml")));
    conf.clangTidy.headerExcludeFilter = "3rd/.*";

    writeClangTidyConfig(baseConf, outFile, conf);

    readText(outFile).shouldEqual(ClangTidyConstants.codeCheckerConfigHeader ~ "\n"
            ~ "Checks:                 \"-*\"\n" ~ "ExcludeHeaderFilterRegex: '3rd/.*'\n");
}

@("writeClangTidyConfig appends both filter lines at end of file when the base config has neither line and both options are set")
unittest {
    import std.file : mkdir, write, readText, tempDir, rmdirRecurse;
    import std.path : buildPath;
    import std.uuid : randomUUID;
    import unit_threaded.should : shouldEqual;

    auto dir = buildPath(tempDir(), "code_checker_ut_" ~ randomUUID().toString);
    mkdir(dir);
    scope (exit)
        rmdirRecurse(dir);
    auto baseConf = AbsolutePath(buildPath(dir, "base.conf"));
    write(baseConf, "Checks:                 \"-*\"\n");
    auto outFile = AbsolutePath(buildPath(dir, ".clang-tidy"));

    auto conf = Config.make(AbsolutePath(dir), AbsolutePath(buildPath(dir, "ut.toml")));
    conf.clangTidy.headerFilter = "my-hdrs";
    conf.clangTidy.headerExcludeFilter = "3rd/.*";

    writeClangTidyConfig(baseConf, outFile, conf);

    readText(outFile).shouldEqual(ClangTidyConstants.codeCheckerConfigHeader ~ "\n" ~ "Checks:                 \"-*\"\n"
            ~ "HeaderFilterRegex: 'my-hdrs'\n" ~ "ExcludeHeaderFilterRegex: '3rd/.*'\n");
}

@("writeClangTidyConfig appends HeaderFilterRegex at end of file when the base config has neither filter line and only header_filter is set")
unittest {
    import std.file : mkdir, write, readText, tempDir, rmdirRecurse;
    import std.path : buildPath;
    import std.uuid : randomUUID;
    import unit_threaded.should : shouldEqual;

    auto dir = buildPath(tempDir(), "code_checker_ut_" ~ randomUUID().toString);
    mkdir(dir);
    scope (exit)
        rmdirRecurse(dir);
    auto baseConf = AbsolutePath(buildPath(dir, "base.conf"));
    write(baseConf, "Checks:                 \"-*\"\n");
    auto outFile = AbsolutePath(buildPath(dir, ".clang-tidy"));

    auto conf = Config.make(AbsolutePath(dir), AbsolutePath(buildPath(dir, "ut.toml")));
    conf.clangTidy.headerFilter = "my-hdrs";

    writeClangTidyConfig(baseConf, outFile, conf);

    readText(outFile).shouldEqual(ClangTidyConstants.codeCheckerConfigHeader
            ~ "\n" ~ "Checks:                 \"-*\"\n" ~ "HeaderFilterRegex: 'my-hdrs'\n");
}

@("writeClangTidyConfig substitutes both filter lines in place when the base config has both lines and both options are set")
unittest {
    import std.file : mkdir, write, readText, tempDir, rmdirRecurse;
    import std.path : buildPath;
    import std.uuid : randomUUID;
    import unit_threaded.should : shouldEqual;

    auto dir = buildPath(tempDir(), "code_checker_ut_" ~ randomUUID().toString);
    mkdir(dir);
    scope (exit)
        rmdirRecurse(dir);
    auto baseConf = AbsolutePath(buildPath(dir, "base.conf"));
    write(baseConf,
            "Checks:                 \"-*\"\n" ~ "HeaderFilterRegex:      '.*'\n"
            ~ "ExcludeHeaderFilterRegex: ''\n");
    auto outFile = AbsolutePath(buildPath(dir, ".clang-tidy"));

    auto conf = Config.make(AbsolutePath(dir), AbsolutePath(buildPath(dir, "ut.toml")));
    conf.clangTidy.headerFilter = "my-hdrs";
    conf.clangTidy.headerExcludeFilter = "3rd/.*";

    writeClangTidyConfig(baseConf, outFile, conf);

    readText(outFile).shouldEqual(ClangTidyConstants.codeCheckerConfigHeader ~ "\n" ~ "Checks:                 \"-*\"\n"
            ~ "HeaderFilterRegex: 'my-hdrs'\n" ~ "ExcludeHeaderFilterRegex: '3rd/.*'\n");
}

@("writeClangTidyConfig copies the base config verbatim when both filter options are empty")
unittest {
    import std.file : mkdir, write, readText, tempDir, rmdirRecurse;
    import std.path : buildPath;
    import std.uuid : randomUUID;
    import unit_threaded.should : shouldEqual;

    auto dir = buildPath(tempDir(), "code_checker_ut_" ~ randomUUID().toString);
    mkdir(dir);
    scope (exit)
        rmdirRecurse(dir);
    auto baseConf = AbsolutePath(buildPath(dir, "base.conf"));
    write(baseConf,
            "Checks:                 \"-*\"\n" ~ "HeaderFilterRegex:      '.*'\n"
            ~ "ExcludeHeaderFilterRegex: ''\n");
    auto outFile = AbsolutePath(buildPath(dir, ".clang-tidy"));

    auto conf = Config.make(AbsolutePath(dir), AbsolutePath(buildPath(dir, "ut.toml")));
    conf.clangTidy.headerFilter = "";
    conf.clangTidy.headerExcludeFilter = "";

    writeClangTidyConfig(baseConf, outFile, conf);

    readText(outFile).shouldEqual(ClangTidyConstants.codeCheckerConfigHeader ~ "\n"
            ~ "Checks:                 \"-*\"\n"
            ~ "HeaderFilterRegex:      '.*'\n" ~ "ExcludeHeaderFilterRegex: ''\n");
}

@(
        "writeClangTidyConfig rewrites the Checks block and appends the exclude filter when checks are configured")
 // Marked @system because initClassification is @system (unittests are @safe
// by default in modern D).
@system unittest {
    import std.algorithm.searching : canFind;
    import std.file : mkdir, write, readText, tempDir, rmdirRecurse, exists;
    import std.path : buildPath;
    import std.uuid : randomUUID;
    import unit_threaded.should : shouldBeTrue, shouldBeFalse;
    import code_checker.engine.types : Severity;
    import code_checker.engine.builtin.clang_tidy_classification : initClassification;

    // The Checks rewriting consumes the check classification, which is
    // loaded at runtime from the shipped classification data relative to
    // the package root (where dub test runs). Without it no checks are
    // configured and the plain-copy path runs instead of the state machine.
    //
    // The classification data path resolves against the process CWD.
    // initClassification only logs a warning when the file is missing, which
    // would turn the assertions below into confusing failures, so assert the
    // file is there first. The classification is written into process-global
    // state that is never restored and that is not thread safe - do not read
    // it from other unittests, and only run this suite single-threaded if any
    // future test needs classification data.
    assert(exists("etc/code_checker/clang-tidy.json"),
            "classification data not found relative to the CWD; run the "
            ~ "unittest binary from the package root, as dub test does");
    initClassification(AbsolutePath("etc/code_checker/clang-tidy.json"));

    auto dir = buildPath(tempDir(), "code_checker_ut_" ~ randomUUID().toString);
    mkdir(dir);
    scope (exit)
        rmdirRecurse(dir);
    auto baseConf = AbsolutePath(buildPath(dir, "base.conf"));
    write(baseConf, "Checks:                 \"-*\"\n" ~ "HeaderFilterRegex:      '.*'\n");
    auto outFile = AbsolutePath(buildPath(dir, ".clang-tidy"));

    auto conf = Config.make(AbsolutePath(dir), AbsolutePath(buildPath(dir, "ut.toml")));
    conf.staticCode.severity = Severity.medium;
    conf.clangTidy.headerFilter = "my-hdrs";
    conf.clangTidy.headerExcludeFilter = "3rd/.*";

    writeClangTidyConfig(baseConf, outFile, conf);

    auto output = readText(outFile);
    output.canFind("ExcludeHeaderFilterRegex: '3rd/.*'").shouldBeTrue;
    output.canFind("HeaderFilterRegex: 'my-hdrs'").shouldBeTrue;
    // The Checks value is rewritten by the state machine; the original
    // line must not survive verbatim.
    output.canFind("Checks:                 \"-*\"").shouldBeFalse;
    // The state machine appends the configured checks as a YAML flow
    // sequence over multiple lines.
    output.canFind(",\\").shouldBeTrue;
}

@(
        "writeClangTidyConfig keeps the base HeaderFilterRegex line when header_filter contains a single quote")
unittest {
    import std.file : mkdir, write, readText, tempDir, rmdirRecurse;
    import std.path : buildPath;
    import std.uuid : randomUUID;
    import unit_threaded.should : shouldEqual;

    auto dir = buildPath(tempDir(), "code_checker_ut_" ~ randomUUID().toString);
    mkdir(dir);
    scope (exit)
        rmdirRecurse(dir);
    auto baseConf = AbsolutePath(buildPath(dir, "base.conf"));
    write(baseConf, "Checks:                 \"-*\"\n" ~ "HeaderFilterRegex:      '.*'\n");
    auto outFile = AbsolutePath(buildPath(dir, ".clang-tidy"));

    auto conf = Config.make(AbsolutePath(dir), AbsolutePath(buildPath(dir, "ut.toml")));
    conf.clangTidy.headerFilter = "foo'bar";

    writeClangTidyConfig(baseConf, outFile, conf);

    readText(outFile).shouldEqual(ClangTidyConstants.codeCheckerConfigHeader
            ~ "\n" ~ "Checks:                 \"-*\"\n" ~ "HeaderFilterRegex:      '.*'\n");
}

@(
        "writeClangTidyConfig keeps the base HeaderFilterRegex line when header_filter ends with a backslash")
unittest {
    import std.file : mkdir, write, readText, tempDir, rmdirRecurse;
    import std.path : buildPath;
    import std.uuid : randomUUID;
    import unit_threaded.should : shouldEqual;

    auto dir = buildPath(tempDir(), "code_checker_ut_" ~ randomUUID().toString);
    mkdir(dir);
    scope (exit)
        rmdirRecurse(dir);
    auto baseConf = AbsolutePath(buildPath(dir, "base.conf"));
    write(baseConf, "Checks:                 \"-*\"\n" ~ "HeaderFilterRegex:      '.*'\n");
    auto outFile = AbsolutePath(buildPath(dir, ".clang-tidy"));

    auto conf = Config.make(AbsolutePath(dir), AbsolutePath(buildPath(dir, "ut.toml")));
    conf.clangTidy.headerFilter = "foo\\";

    writeClangTidyConfig(baseConf, outFile, conf);

    readText(outFile).shouldEqual(ClangTidyConstants.codeCheckerConfigHeader
            ~ "\n" ~ "Checks:                 \"-*\"\n" ~ "HeaderFilterRegex:      '.*'\n");
}

@("writeClangTidyConfig keeps the base lines and appends no exclude filter when exclude_header_filter contains a single quote")
unittest {
    import std.file : mkdir, write, readText, tempDir, rmdirRecurse;
    import std.path : buildPath;
    import std.uuid : randomUUID;
    import unit_threaded.should : shouldEqual;

    auto dir = buildPath(tempDir(), "code_checker_ut_" ~ randomUUID().toString);
    mkdir(dir);
    scope (exit)
        rmdirRecurse(dir);
    auto baseConf = AbsolutePath(buildPath(dir, "base.conf"));
    write(baseConf, "Checks:                 \"-*\"\n" ~ "HeaderFilterRegex:      '.*'\n");
    auto outFile = AbsolutePath(buildPath(dir, ".clang-tidy"));

    auto conf = Config.make(AbsolutePath(dir), AbsolutePath(buildPath(dir, "ut.toml")));
    conf.clangTidy.headerExcludeFilter = "foo'bar";

    writeClangTidyConfig(baseConf, outFile, conf);

    readText(outFile).shouldEqual(ClangTidyConstants.codeCheckerConfigHeader
            ~ "\n" ~ "Checks:                 \"-*\"\n" ~ "HeaderFilterRegex:      '.*'\n");
}

@("writeClangTidyConfig keeps the base lines and appends no exclude filter when exclude_header_filter ends with a backslash")
unittest {
    import std.file : mkdir, write, readText, tempDir, rmdirRecurse;
    import std.path : buildPath;
    import std.uuid : randomUUID;
    import unit_threaded.should : shouldEqual;

    auto dir = buildPath(tempDir(), "code_checker_ut_" ~ randomUUID().toString);
    mkdir(dir);
    scope (exit)
        rmdirRecurse(dir);
    auto baseConf = AbsolutePath(buildPath(dir, "base.conf"));
    write(baseConf, "Checks:                 \"-*\"\n" ~ "HeaderFilterRegex:      '.*'\n");
    auto outFile = AbsolutePath(buildPath(dir, ".clang-tidy"));

    auto conf = Config.make(AbsolutePath(dir), AbsolutePath(buildPath(dir, "ut.toml")));
    conf.clangTidy.headerExcludeFilter = "foo\\";

    writeClangTidyConfig(baseConf, outFile, conf);

    readText(outFile).shouldEqual(ClangTidyConstants.codeCheckerConfigHeader
            ~ "\n" ~ "Checks:                 \"-*\"\n" ~ "HeaderFilterRegex:      '.*'\n");
}

@(
        "writeClangTidyConfig keeps the base lines and appends neither filter when both options are unwritable")
unittest {
    import std.file : mkdir, write, readText, tempDir, rmdirRecurse;
    import std.path : buildPath;
    import std.uuid : randomUUID;
    import unit_threaded.should : shouldEqual;

    auto dir = buildPath(tempDir(), "code_checker_ut_" ~ randomUUID().toString);
    mkdir(dir);
    scope (exit)
        rmdirRecurse(dir);
    auto baseConf = AbsolutePath(buildPath(dir, "base.conf"));
    write(baseConf, "Checks:                 \"-*\"\n" ~ "HeaderFilterRegex:      '.*'\n");
    auto outFile = AbsolutePath(buildPath(dir, ".clang-tidy"));

    auto conf = Config.make(AbsolutePath(dir), AbsolutePath(buildPath(dir, "ut.toml")));
    conf.clangTidy.headerFilter = "foo'bar";
    conf.clangTidy.headerExcludeFilter = "foo\\";

    writeClangTidyConfig(baseConf, outFile, conf);

    readText(outFile).shouldEqual(ClangTidyConstants.codeCheckerConfigHeader
            ~ "\n" ~ "Checks:                 \"-*\"\n" ~ "HeaderFilterRegex:      '.*'\n");
}

@("writeClangTidyConfig drops an unwritable header_filter in the Checks-rewriting path")
 // Marked @system because initClassification is @system (unittests are @safe
// by default in modern D).
@system unittest {
    import std.algorithm.searching : canFind;
    import std.file : mkdir, write, readText, tempDir, rmdirRecurse, exists;
    import std.path : buildPath;
    import std.uuid : randomUUID;
    import unit_threaded.should : shouldBeTrue, shouldBeFalse;
    import code_checker.engine.types : Severity;
    import code_checker.engine.builtin.clang_tidy_classification : initClassification;

    // Same CWD/classification caveat as the Checks-rewriting cell above: the
    // classification data path resolves against the process CWD and
    // initClassification only logs a warning when the file is missing.
    assert(exists("etc/code_checker/clang-tidy.json"),
            "classification data not found relative to the CWD; run the "
            ~ "unittest binary from the package root, as dub test does");
    initClassification(AbsolutePath("etc/code_checker/clang-tidy.json"));

    auto dir = buildPath(tempDir(), "code_checker_ut_" ~ randomUUID().toString);
    mkdir(dir);
    scope (exit)
        rmdirRecurse(dir);
    auto baseConf = AbsolutePath(buildPath(dir, "base.conf"));
    write(baseConf, "Checks:                 \"-*\"\n" ~ "HeaderFilterRegex:      '.*'\n");
    auto outFile = AbsolutePath(buildPath(dir, ".clang-tidy"));

    auto conf = Config.make(AbsolutePath(dir), AbsolutePath(buildPath(dir, "ut.toml")));
    conf.staticCode.severity = Severity.medium;
    conf.clangTidy.headerFilter = "foo'bar";

    writeClangTidyConfig(baseConf, outFile, conf);

    auto output = readText(outFile);
    // The Checks block is rewritten by the state machine; the original line
    // does not survive verbatim.
    output.canFind("Checks:                 \"-*,\\").shouldBeTrue;
    // The unwritable user value is neither substituted nor appended; the base
    // HeaderFilterRegex line passes through after the Checks block.
    output.canFind("foo'bar").shouldBeFalse;
    output.canFind("HeaderFilterRegex:      '.*'").shouldBeTrue;
}
