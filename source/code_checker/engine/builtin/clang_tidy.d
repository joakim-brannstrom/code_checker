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

import dyaml;

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

/// Run clang-tidy to fix the code.
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
        // even if it overloads the system.
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
        // the counter is zero and the result is an automatic pass: all the
        // warnings were from excluded files.
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

        // clang-tidy returns exit status '0' and warnings when it runs successfully.

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
            // the tool reported error but no errors were found thus the user
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

/// Presence of the HeaderFilterRegex / ExcludeHeaderFilterRegex keys in the
/// already-parsed base config mapping. A root that is not a mapping has
/// neither key.
private Tuple!(bool, "include", bool, "exclude") hasConfigHeaderOptions(const Node root) @safe {
    bool hasInclude;
    bool hasExclude;

    if (root.type != NodeType.mapping) {
        return typeof(return)(hasInclude, hasExclude);
    }

    foreach (ref p; root.as!(Node.Pair[])) {
        // Non-string keys ("42"/"true"/"null"/complex mappings) can never
        // equal the two target keys, and as!string throws on them.
        if (p.key.type != NodeType.string) {
            continue;
        }
        if (p.key.as!string == "HeaderFilterRegex") {
            hasInclude = true;
        } else if (p.key.as!string == "ExcludeHeaderFilterRegex") {
            hasExclude = true;
        }
    }

    return typeof(return)(hasInclude, hasExclude);
}

/// Builds the spliced Checks value as a dyaml sequence Node: the base
/// config's entries plus computedChecks, forced to flow style.
///
/// Base value handling (checksNode):
/// - string scalar: split on ',', trim each entry, drop empty entries.
/// - empty scalar: no base entries.
/// - sequence: entries kept as-is (each as!string).
/// - anything else: no base entries; warning logged.
private Node buildChecksSequence(const Node checksNode, string[] computedChecks) @safe {
    import std.algorithm.iteration : filter, map, splitter;
    import std.array : array;
    import std.string : strip;

    string[] entries;

    switch (checksNode.type) {
    case NodeType.string:
        entries = checksNode.as!string.splitter(',').map!(a => a.strip)
            .filter!(a => !a.empty)
            .array;
        break;
    case NodeType.sequence:
        auto baseEntries = checksNode.as!(Node[]);
        foreach (entry; baseEntries) {
            entries ~= entry.as!string;
        }
        break;
    case NodeType.null_:
        // A `Checks:` line with no value parses as a null node: an empty
        // scalar contributing no base entries, not an unusable value type.
        break;
    default:
        logger.warningf("clang_tidy.Checks has an unusable value type (%s); only the computed checks are spliced into the generated .clang-tidy",
                checksNode.type);
        break;
    }

    foreach (c; computedChecks) {
        entries ~= c;
    }

    auto result = Node(entries);
    result.setStyle(CollectionStyle.flow);
    return result;
}

// TODO: change to a sumtype instead of the OK flag
/// Outcome of loading the base clang-tidy configuration with dyaml.
private struct LoadedBaseConfig {
    /// Parsed mapping root; an invalid node when ok is false.
    Node root;
    /// Raw file content when the file was readable, else empty. Not consumed
    /// by the generation (the verbatim-copy fallback was replaced by a fatal
    /// error); only the loader tests read it.
    string rawText;
    /// True: the file was read AND parsed AND the root is a mapping.
    bool ok;
}

/// Loads the base clang-tidy configuration at baseConf with dyaml.
///
/// Returns: ok=false on a missing or unreadable file, a dyaml parse failure,
/// or a non-mapping root. The failure reason is logged once here; the caller
/// must not log it again.
private LoadedBaseConfig loadClangTidyConfig(AbsolutePath baseConf) @safe {
    import std.file : readText;

    LoadedBaseConfig loaded;

    auto fail(string reason) {
        logger.errorf("Failed to load clang-tidy system configuration %s: %s", baseConf, reason);
        return loaded;
    }

    try {
        loaded.rawText = readText(baseConf);
    } catch (Exception e) {
        return fail(e.msg);
    }

    try {
        loaded.root = Loader.fromString(loaded.rawText).load();
    } catch (Exception e) {
        return fail(e.msg);
    }

    if (loaded.root.type != NodeType.mapping) {
        return fail("the root of the YAML document is not a mapping");
    }

    loaded.ok = true;
    return loaded;
}

void writeClangTidyConfig(AbsolutePath baseConf, Config conf) @trusted {
    writeClangTidyConfig(baseConf, AbsolutePath(ClangTidyConstants.confFile), conf);
}

void writeClangTidyConfig(AbsolutePath baseConf, AbsolutePath outFile, Config conf) @safe {
    import std.array : appender;
    import std.file : exists, write;
    import code_checker.engine.builtin.clang_tidy_classification : filterSeverity;

    if (!exists(baseConf)) {
        logger.warning("No default clang-tidy configuration found at ", baseConf);
        logger.info("Using clang-tidy with default settings");
        return;
    }

    string[] checks = () {
        if (conf.staticCode.severity != typeof(conf.staticCode.severity).min)
            return filterSeverity!(a => a < conf.staticCode.severity).map!(a => "-" ~ a).array;
        return null;
    }();

    auto loaded = loadClangTidyConfig(baseConf);
    if (!loaded.ok) {
        // The failure reason is logged by loadClangTidyConfig. Throwing an
        // Error (not an Exception) lets it escape the engine's Exception
        // handling and terminate the program: a base config that exists but
        // cannot be used (unreadable, unparseable, non-mapping root) is a
        // setup error, not something the analysis can recover from. The
        // existing .clang-tidy is left untouched.
        throw new Exception("Unusable clang-tidy system configuration: " ~ baseConf);
    }

    auto root = loaded.root;

    Tuple!(bool, "include", bool, "exclude") hasHeaderConf;
    hasHeaderConf = hasConfigHeaderOptions(root);

    bool headerFilterPending;
    bool excludeFilterPending;
    void checkHeaderFilter() {
        // A user-set option whose line the base config lacks is warned about
        // and appended to the generated .clang-tidy instead of being silently
        // dropped. Any value is emitted: dyaml's emitter picks a scalar style
        // (plain, single-quoted or double-quoted) that can represent it.
        headerFilterPending = !conf.clangTidy.headerFilter.empty && !hasHeaderConf.include;
        excludeFilterPending = !conf.clangTidy.headerExcludeFilter.empty && !hasHeaderConf.exclude;
        if (headerFilterPending) {
            logger.warningf("clang_tidy.%s is set but the system configuration %s lacks a %s line; the setting is appended to the generated .clang-tidy",
                    "header_filter", baseConf, "HeaderFilterRegex:");
        }
        if (excludeFilterPending) {
            logger.warningf("clang_tidy.%s is set but the system configuration %s lacks a %s line; the setting is appended to the generated .clang-tidy",
                    "exclude_header_filter", baseConf, "ExcludeHeaderFilterRegex:");
        }
    }

    checkHeaderFilter();

    // Rebuild the root's mapping pairs with the user's filter values and the
    // computed checks. Rebuilding the pair list keeps the loaded pair order
    // and any duplicate keys: every HeaderFilterRegex /
    // ExcludeHeaderFilterRegex pair is substituted, not just the first
    // match, and pending filters are appended at the end of the mapping.
    // The rebuilt pair list is assigned back to the root as a fresh mapping
    // node, which replaces the old line-based output state machine.
    Node[] newKeys;
    Node[] newValues;
    bool checksKeyPresent;
    foreach (p; root.as!(Node.Pair[])) {
        Node key = p.key;
        Node value = p.value;
        if (key.type == NodeType.string) {
            switch (key.as!string) {
            case "Checks":
                checksKeyPresent = true;
                if (!checks.empty) {
                    // Normalize the Checks value to a sequence and splice the
                    // computed checks into it, forced to flow style by
                    // buildChecksSequence.
                    value = buildChecksSequence(value, checks);
                }
                break;
            case "HeaderFilterRegex":
                if (!conf.clangTidy.headerFilter.empty) {
                    value = Node(conf.clangTidy.headerFilter);
                }
                break;
            case "ExcludeHeaderFilterRegex":
                if (!conf.clangTidy.headerExcludeFilter.empty) {
                    value = Node(conf.clangTidy.headerExcludeFilter);
                }
                break;
            default:
                break;
            }
        }
        newKeys ~= key;
        newValues ~= value;
    }

    if (headerFilterPending) {
        newKeys ~= Node("HeaderFilterRegex");
        newValues ~= Node(conf.clangTidy.headerFilter);
    }

    if (excludeFilterPending) {
        newKeys ~= Node("ExcludeHeaderFilterRegex");
        newValues ~= Node(conf.clangTidy.headerExcludeFilter);
    }

    if (!checks.empty && !checksKeyPresent) {
        logger.warningf("clang_tidy.%s is set but the system configuration %s lacks a Checks entry; the computed checks are spliced into a fresh Checks entry in the generated .clang-tidy",
                "severity", baseConf);
        newKeys ~= Node("Checks");
        // The empty scalar contributes no base entries (the same path the
        // empty-Checks-scalar test pins), so the fresh sequence contains only
        // the computed checks.
        newValues ~= buildChecksSequence(Node(""), checks);
    }

    root = Node(newKeys, newValues);

    auto buf = appender!string;
    buf.put(ClangTidyConstants.codeCheckerConfigHeader);
    buf.put('\n');
    auto dumper = Dumper();
    // keep flow sequences on one line; dyaml wraps at 80 columns by default,
    // and a wrapped double-quoted scalar trips the upstream scanner bug that
    // eats commas before a newline (dyaml 0.10.0, scanner.d)
    dumper.textWidth = 1_000_000;
    // no %YAML version directive in the generated file (the old generator
    // wrote none); the --- document-start line remains for a mapping root
    dumper.YAMLVersion = null;
    dumper.dump(buf, root);
    write(outFile, buf.data);
}

@("writeClangTidyConfig substitutes both filter lines when the base config has them")
unittest {
    import std.file : mkdir, write, readText, tempDir, rmdirRecurse;
    import std.path : buildPath;
    import std.string : splitLines;
    import std.uuid : randomUUID;
    import unit_threaded.should : shouldEqual, shouldBeTrue;

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

    auto root = Loader.fromString(readText(outFile)).load();
    root["Checks"].as!string.shouldEqual("-*");
    root["HeaderFilterRegex"].as!string.shouldEqual("my-hdrs");
    root["ExcludeHeaderFilterRegex"].as!string.shouldEqual("3rd/.*");
    // The generated file starts with the code_checker header line.
    readText(outFile).splitLines[0].shouldEqual(ClangTidyConstants.codeCheckerConfigHeader);
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

    auto root = Loader.fromString(readText(outFile)).load();
    root["Checks"].as!string.shouldEqual("-*");
    root["HeaderFilterRegex"].as!string.shouldEqual("my-hdrs");
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

    auto root = Loader.fromString(readText(outFile)).load();
    auto pairs = root.as!(Node.Pair[]);
    pairs.length.shouldEqual(2);
    pairs[0].key.as!string.shouldEqual("Checks");
    pairs[0].value.as!string.shouldEqual("-*");
    pairs[1].key.as!string.shouldEqual("ExcludeHeaderFilterRegex");
    pairs[1].value.as!string.shouldEqual("3rd/.*");
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

    auto root = Loader.fromString(readText(outFile)).load();
    auto pairs = root.as!(Node.Pair[]);
    pairs.length.shouldEqual(3);
    pairs[0].key.as!string.shouldEqual("Checks");
    pairs[1].key.as!string.shouldEqual("HeaderFilterRegex");
    pairs[2].key.as!string.shouldEqual("ExcludeHeaderFilterRegex");
    pairs[1].value.as!string.shouldEqual("my-hdrs");
    pairs[2].value.as!string.shouldEqual("3rd/.*");
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

    auto root = Loader.fromString(readText(outFile)).load();
    auto pairs = root.as!(Node.Pair[]);
    pairs.length.shouldEqual(2);
    pairs[0].key.as!string.shouldEqual("Checks");
    pairs[1].key.as!string.shouldEqual("HeaderFilterRegex");
    pairs[1].value.as!string.shouldEqual("my-hdrs");
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

    auto root = Loader.fromString(readText(outFile)).load();
    root["Checks"].as!string.shouldEqual("-*");
    root["HeaderFilterRegex"].as!string.shouldEqual("my-hdrs");
    root["ExcludeHeaderFilterRegex"].as!string.shouldEqual("3rd/.*");
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

    auto root = Loader.fromString(readText(outFile)).load();
    root["Checks"].as!string.shouldEqual("-*");
    root["HeaderFilterRegex"].as!string.shouldEqual(".*");
    root["ExcludeHeaderFilterRegex"].as!string.shouldEqual("");
    auto pairs = root.as!(Node.Pair[]);
    pairs.length.shouldEqual(3);
    pairs[0].key.as!string.shouldEqual("Checks");
    pairs[1].key.as!string.shouldEqual("HeaderFilterRegex");
    pairs[2].key.as!string.shouldEqual("ExcludeHeaderFilterRegex");
}

@(
        "writeClangTidyConfig rewrites the Checks block and appends the exclude filter when checks are configured")
 // Marked @system because initClassification is @system (unittests are @safe
// by default in modern D).
@system unittest {
    import std.file : mkdir, write, readText, tempDir, rmdirRecurse, exists;
    import std.path : buildPath;
    import std.uuid : randomUUID;
    import unit_threaded.should : shouldEqual, shouldBeTrue;
    import code_checker.engine.types : Severity;
    import code_checker.engine.builtin.clang_tidy_classification : initClassification;

    static string[] checksOf(Node n) @trusted {
        import std.algorithm.iteration : map;
        import std.array : array;

        return n.as!(Node[])
            .map!(e => e.as!string)
            .array;
    }

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

    auto root = Loader.fromString(readText(outFile)).load();
    auto checksNode = root["Checks"];
    // The Checks value is rewritten into a sequence with the computed checks
    // spliced into the base entries.
    checksNode.type.shouldEqual(NodeType.sequence);
    auto entries = checksOf(checksNode);
    (entries.length > 1).shouldBeTrue;
    entries[0].shouldEqual("-*");
    root["HeaderFilterRegex"].as!string.shouldEqual("my-hdrs");
    root["ExcludeHeaderFilterRegex"].as!string.shouldEqual("3rd/.*");
}

@("writeClangTidyConfig substitutes HeaderFilterRegex when header_filter contains a single quote")
unittest {
    import std.file : mkdir, write, readText, tempDir, rmdirRecurse;
    import std.path : buildPath;
    import std.uuid : randomUUID;
    import std.algorithm.searching : canFind;
    import unit_threaded.should : shouldEqual, shouldBeTrue;

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

    auto root = Loader.fromString(readText(outFile)).load();
    root["Checks"].as!string.shouldEqual("-*");
    root["HeaderFilterRegex"].as!string.shouldEqual("foo'bar");
    // Any filter value is emitted: dyaml's emitter picked the plain scalar
    // style here (pinned; a value needing escaping is written single- or
    // double-quoted instead).
    readText(outFile).canFind("HeaderFilterRegex: foo'bar").shouldBeTrue;
}

@("writeClangTidyConfig substitutes HeaderFilterRegex when header_filter ends with a backslash")
unittest {
    import std.file : mkdir, write, readText, tempDir, rmdirRecurse;
    import std.path : buildPath;
    import std.uuid : randomUUID;
    import std.algorithm.searching : canFind;
    import unit_threaded.should : shouldEqual, shouldBeTrue;

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

    auto root = Loader.fromString(readText(outFile)).load();
    root["Checks"].as!string.shouldEqual("-*");
    root["HeaderFilterRegex"].as!string.shouldEqual("foo\\");
    readText(outFile).canFind("HeaderFilterRegex: foo\\").shouldBeTrue;
}

@(
        "writeClangTidyConfig appends the exclude filter when exclude_header_filter contains a single quote")
unittest {
    import std.file : mkdir, write, readText, tempDir, rmdirRecurse;
    import std.path : buildPath;
    import std.uuid : randomUUID;
    import std.algorithm.searching : canFind;
    import unit_threaded.should : shouldEqual, shouldBeTrue;

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

    auto root = Loader.fromString(readText(outFile)).load();
    auto pairs = root.as!(Node.Pair[]);
    pairs.length.shouldEqual(3);
    pairs[0].key.as!string.shouldEqual("Checks");
    pairs[0].value.as!string.shouldEqual("-*");
    pairs[1].key.as!string.shouldEqual("HeaderFilterRegex");
    pairs[1].value.as!string.shouldEqual(".*");
    pairs[2].key.as!string.shouldEqual("ExcludeHeaderFilterRegex");
    pairs[2].value.as!string.shouldEqual("foo'bar");
    // Any value is emitted: pinned as the plain scalar style here.
    readText(outFile).canFind("ExcludeHeaderFilterRegex: foo'bar").shouldBeTrue;
}

@(
        "writeClangTidyConfig appends the exclude filter when exclude_header_filter ends with a backslash")
unittest {
    import std.file : mkdir, write, readText, tempDir, rmdirRecurse;
    import std.path : buildPath;
    import std.uuid : randomUUID;
    import std.algorithm.searching : canFind;
    import unit_threaded.should : shouldEqual, shouldBeTrue;

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

    auto root = Loader.fromString(readText(outFile)).load();
    auto pairs = root.as!(Node.Pair[]);
    pairs.length.shouldEqual(3);
    pairs[0].key.as!string.shouldEqual("Checks");
    pairs[0].value.as!string.shouldEqual("-*");
    pairs[1].key.as!string.shouldEqual("HeaderFilterRegex");
    pairs[1].value.as!string.shouldEqual(".*");
    pairs[2].key.as!string.shouldEqual("ExcludeHeaderFilterRegex");
    pairs[2].value.as!string.shouldEqual("foo\\");
    readText(outFile).canFind("ExcludeHeaderFilterRegex: foo\\").shouldBeTrue;
}

@("writeClangTidyConfig substitutes both filters when both values need dyaml's escaping")
unittest {
    import std.file : mkdir, write, readText, tempDir, rmdirRecurse;
    import std.path : buildPath;
    import std.uuid : randomUUID;
    import std.algorithm.searching : canFind;
    import unit_threaded.should : shouldEqual, shouldBeTrue;

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

    auto root = Loader.fromString(readText(outFile)).load();
    auto pairs = root.as!(Node.Pair[]);
    pairs.length.shouldEqual(3);
    pairs[0].key.as!string.shouldEqual("Checks");
    pairs[0].value.as!string.shouldEqual("-*");
    pairs[1].key.as!string.shouldEqual("HeaderFilterRegex");
    pairs[1].value.as!string.shouldEqual("foo'bar");
    pairs[2].key.as!string.shouldEqual("ExcludeHeaderFilterRegex");
    pairs[2].value.as!string.shouldEqual("foo\\");
    // Any value is emitted: pinned as the plain scalar style here.
    readText(outFile).canFind("HeaderFilterRegex: foo'bar").shouldBeTrue;
    readText(outFile).canFind("ExcludeHeaderFilterRegex: foo\\").shouldBeTrue;
}

@(
        "writeClangTidyConfig substitutes a header_filter containing a single quote in the Checks-rewriting path")
 // Marked @system because initClassification is @system (unittests are @safe
// by default in modern D).
@system unittest {
    import std.file : mkdir, write, readText, tempDir, rmdirRecurse, exists;
    import std.path : buildPath;
    import std.uuid : randomUUID;
    import unit_threaded.should : shouldEqual, shouldBeTrue;
    import code_checker.engine.types : Severity;
    import code_checker.engine.builtin.clang_tidy_classification : initClassification;

    static string[] checksOf(Node n) @trusted {
        import std.algorithm.iteration : map;
        import std.array : array;

        return n.as!(Node[])
            .map!(e => e.as!string)
            .array;
    }

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

    auto root = Loader.fromString(readText(outFile)).load();
    auto checksNode = root["Checks"];
    // The Checks value is rewritten into a sequence with the computed checks
    // spliced into the base entries.
    checksNode.type.shouldEqual(NodeType.sequence);
    auto entries = checksOf(checksNode);
    entries[0].shouldEqual("-*");
    (entries.length > 1).shouldBeTrue;
    // The single quote no longer blocks the substitution.
    root["HeaderFilterRegex"].as!string.shouldEqual("foo'bar");
}

@("writeClangTidyConfig keeps the shipped config's base entries and splices the computed checks when severity filtering is configured")
 // Marked @system because initClassification is @system (unittests are @safe
// by default in modern D).
@system unittest {
    import std.array : appender, array;
    import std.file : exists, mkdir, readText, tempDir, rmdirRecurse;
    import std.path : buildPath;
    import std.uuid : randomUUID;
    import unit_threaded.should : shouldEqual;
    import code_checker.engine.types : Severity;
    import code_checker.engine.builtin.clang_tidy_classification : filterSeverity,
        initClassification;

    static string[] entriesOf(Node n) @trusted {
        import std.algorithm.iteration : map;

        return n.as!(Node[])
            .map!(e => e.as!string)
            .array;
    }

    static string[] computedOf(Config conf) @safe {
        return filterSeverity!(a => a < conf.staticCode.severity).map!(a => "-" ~ a).array;
    }

    static string dumped(Node n) @trusted {
        auto app = appender!string;
        Dumper().dump(app, n);
        return app.data;
    }

    // Same CWD/classification caveat as the Checks-rewriting cell above: the
    // classification data path resolves against the process CWD and
    // initClassification only logs a warning when the file is missing. It
    // writes process-global state that is never restored and that is not
    // thread safe - do not read it from other unittests, and only run this
    // suite single-threaded if any future test needs classification data.
    assert(exists("etc/code_checker/clang-tidy.json"),
            "classification data not found relative to the CWD; run the "
            ~ "unittest binary from the package root, as dub test does");
    initClassification(AbsolutePath("etc/code_checker/clang-tidy.json"));

    // The shipped config is parsed once here to compare every non-Checks pair
    // of the generated file against it.
    auto baseRoot = Loader.fromString(readText("etc/code_checker/clang_tidy.conf")).load();

    auto dir = buildPath(tempDir(), "code_checker_ut_" ~ randomUUID().toString);
    mkdir(dir);
    scope (exit)
        rmdirRecurse(dir);
    auto outFile = AbsolutePath(buildPath(dir, ".clang-tidy"));

    auto conf = Config.make(AbsolutePath(dir), AbsolutePath(buildPath(dir, "ut.toml")));
    conf.staticCode.severity = Severity.medium;

    writeClangTidyConfig(AbsolutePath("etc/code_checker/clang_tidy.conf"), outFile, conf);

    auto root = Loader.fromString(readText(outFile)).load();

    // The Checks value is rewritten into a flow sequence: the shipped 8 quoted
    // entries first, in order, then the computed disabled checks.
    auto checksNode = root["Checks"];
    checksNode.type.shouldEqual(NodeType.sequence);
    // The base prefix is derived from the freshly parsed shipped config by
    // re-splitting its quoted Checks scalar (the shipped entries themselves
    // are pinned by the buildChecksSequence cells).
    auto baseEntries = entriesOf(buildChecksSequence(baseRoot["Checks"], null));
    auto entries = entriesOf(checksNode);
    entries.length.shouldEqual(baseEntries.length + computedOf(conf).length);
    entries[0 .. baseEntries.length].shouldEqual(baseEntries);

    // Every other pair keeps the base config's key, order and value.
    auto basePairs = baseRoot.as!(Node.Pair[]);
    auto genPairs = root.as!(Node.Pair[]);
    genPairs.length.shouldEqual(basePairs.length);
    foreach (i, p; genPairs) {
        if (p.key.as!string == "Checks") {
            continue;
        }
        dumped(p.key).shouldEqual(dumped(basePairs[i].key));
        dumped(p.value).shouldEqual(dumped(basePairs[i].value));
    }
}

@("writeClangTidyConfig splices a fresh Checks entry when the base config lacks one")
 // Marked @system because initClassification is @system (unittests are @safe
// by default in modern D).
@system unittest {
    import std.algorithm.iteration : map;
    import std.algorithm.searching : canFind;
    import std.array : array;
    import std.experimental.logger.core : Logger, LogLevel, stdThreadLocalLog;
    import std.file : exists, mkdir, readText, tempDir, write, rmdirRecurse;
    import std.path : buildPath;
    import std.uuid : randomUUID;
    import unit_threaded.should : shouldEqual, shouldBeTrue;
    import code_checker.engine.types : Severity;
    import code_checker.engine.builtin.clang_tidy_classification : filterSeverity,
        initClassification;

    static final class CapturingLogger : Logger {
        string[] msgs;

        this() {
            super(LogLevel.all);
        }

        protected override void writeLogMsg(ref LogEntry payload) @safe {
            msgs ~= payload.msg;
        }
    }

    static string[] computedOf(Config conf) @safe {
        return filterSeverity!(a => a < conf.staticCode.severity).map!(a => "-" ~ a).array;
    }

    static string[] entriesOf(Node n) @trusted {
        import std.algorithm.iteration : map;

        return n.as!(Node[])
            .map!(e => e.as!string)
            .array;
    }

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
    write(baseConf, "HeaderFilterRegex: '.*'\n");
    auto outFile = AbsolutePath(buildPath(dir, ".clang-tidy"));

    auto conf = Config.make(AbsolutePath(dir), AbsolutePath(buildPath(dir, "ut.toml")));
    conf.staticCode.severity = Severity.medium;
    conf.clangTidy.headerFilter = "my-hdrs";

    auto savedLog = stdThreadLocalLog;
    scope (exit)
        stdThreadLocalLog = savedLog;
    auto captured = new CapturingLogger;
    stdThreadLocalLog = captured;

    writeClangTidyConfig(baseConf, outFile, conf);

    (captured.msgs.canFind!(m => m.canFind("lacks a Checks entry"))).shouldBeTrue;

    // The computed checks are spliced into a fresh Checks entry at the end
    // of the mapping instead of being dropped.
    auto root = Loader.fromString(readText(outFile)).load();
    auto pairs = root.as!(Node.Pair[]);
    pairs.length.shouldEqual(2);
    pairs[0].key.as!string.shouldEqual("HeaderFilterRegex");
    pairs[0].value.as!string.shouldEqual("my-hdrs");
    pairs[1].key.as!string.shouldEqual("Checks");
    entriesOf(pairs[1].value).shouldEqual(computedOf(conf));
}

@("writeClangTidyConfig splices only the computed checks when the base Checks scalar is empty")
 // Marked @system because initClassification is @system (unittests are @safe
// by default in modern D).
@system unittest {
    import std.array : array;
    import std.file : exists, mkdir, readText, tempDir, write, rmdirRecurse;
    import std.path : buildPath;
    import std.uuid : randomUUID;
    import std.algorithm.searching : canFind;
    import unit_threaded.should : shouldEqual, shouldBeTrue;
    import code_checker.engine.types : Severity;
    import code_checker.engine.builtin.clang_tidy_classification : filterSeverity,
        initClassification;

    static string[] entriesOf(Node n) @trusted {
        import std.algorithm.iteration : map;

        return n.as!(Node[])
            .map!(e => e.as!string)
            .array;
    }

    static string[] computedOf(Config conf) @safe {
        return filterSeverity!(a => a < conf.staticCode.severity).map!(a => "-" ~ a).array;
    }

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
    write(baseConf, "Checks: ''\n" ~ "HeaderFilterRegex: '.*'\n");
    auto outFile = AbsolutePath(buildPath(dir, ".clang-tidy"));

    auto conf = Config.make(AbsolutePath(dir), AbsolutePath(buildPath(dir, "ut.toml")));
    conf.staticCode.severity = Severity.medium;

    writeClangTidyConfig(baseConf, outFile, conf);

    auto root = Loader.fromString(readText(outFile)).load();

    // The empty base scalar contributes no entries; only the computed checks
    // are spliced in.
    auto checksNode = root["Checks"];
    checksNode.type.shouldEqual(NodeType.sequence);
    entriesOf(checksNode).shouldEqual(computedOf(conf));
}

@("writeClangTidyConfig keeps the base block-sequence entries and forces flow style when the Checks value is a block sequence")
 // Marked @system because initClassification is @system (unittests are @safe
// by default in modern D).
@system unittest {
    import std.algorithm.iteration : map;
    import std.algorithm.searching : canFind;
    import std.array : array;
    import std.file : exists, mkdir, readText, tempDir, write, rmdirRecurse;
    import std.path : buildPath;
    import std.uuid : randomUUID;
    import unit_threaded.should : shouldEqual, shouldBeTrue, shouldBeFalse;
    import code_checker.engine.types : Severity;
    import code_checker.engine.builtin.clang_tidy_classification : filterSeverity,
        initClassification;

    static string[] entriesOf(Node n) @trusted {
        import std.algorithm.iteration : map;

        return n.as!(Node[])
            .map!(e => e.as!string)
            .array;
    }

    static string[] computedOf(Config conf) @safe {
        return filterSeverity!(a => a < conf.staticCode.severity).map!(a => "-" ~ a).array;
    }

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
    write(baseConf, "Checks:\n" ~ "  - a\n" ~ "  -  b \n" ~ "HeaderFilterRegex: '.*'\n");
    auto outFile = AbsolutePath(buildPath(dir, ".clang-tidy"));

    auto conf = Config.make(AbsolutePath(dir), AbsolutePath(buildPath(dir, "ut.toml")));
    conf.staticCode.severity = Severity.medium;

    writeClangTidyConfig(baseConf, outFile, conf);

    auto root = Loader.fromString(readText(outFile)).load();

    // The block-sequence entries are kept and the computed checks are
    // appended in place.
    auto entries = entriesOf(root["Checks"]);
    entries.length.shouldEqual(2 + computedOf(conf).length);
    entries[0 .. 2].shouldEqual(["a", "b"]);

    // Flow style is forced on the rewritten Checks node; nothing else in the
    // file is turned into a flow collection.
    auto text = readText(outFile);
    text.canFind("Checks: [").shouldBeTrue;
    text.canFind("\n- ").shouldBeFalse;
}

// Marked @system because catching an Error is not allowed in @safe code
// (unittests are @safe by default in modern D).
@("writeClangTidyConfig aborts generation when the base config is unparseable")
@system unittest {
    import std.algorithm.iteration : map;
    import std.algorithm.searching : canFind;
    import std.experimental.logger.core : Logger, LogLevel, stdThreadLocalLog;
    import std.file : exists, mkdir, write, readText, tempDir, rmdirRecurse;
    import std.path : buildPath;
    import std.uuid : randomUUID;
    import unit_threaded.should : shouldEqual, shouldBeTrue, shouldBeFalse;

    static final class CapturingLogger : Logger {
        string[] msgs;

        this() {
            super(LogLevel.all);
        }

        protected override void writeLogMsg(ref LogEntry payload) @safe {
            msgs ~= payload.msg;
        }
    }

    auto dir = buildPath(tempDir(), "code_checker_ut_" ~ randomUUID().toString);
    mkdir(dir);
    scope (exit)
        rmdirRecurse(dir);
    auto baseConf = AbsolutePath(buildPath(dir, "base.conf"));
    write(baseConf, "HeaderFilterRegex: '.*'\n" ~ "Checks:\n" ~ "\t- \"-*\"\n");
    auto outFile = AbsolutePath(buildPath(dir, ".clang-tidy"));

    auto conf = Config.make(AbsolutePath(dir), AbsolutePath(buildPath(dir, "ut.toml")));
    conf.clangTidy.headerFilter = "my-hdrs";

    auto savedLog = stdThreadLocalLog;
    scope (exit)
        stdThreadLocalLog = savedLog;
    auto captured = new CapturingLogger;
    stdThreadLocalLog = captured;

    auto caught = false;
    try {
        writeClangTidyConfig(baseConf, outFile, conf);
    } catch (Exception e) {
        caught = true;
    }
    caught.shouldBeTrue;

    // The failure is logged and the existing .clang-tidy is left untouched.
    (captured.msgs.canFind!(m => m.canFind("Failed to load clang-tidy system configuration")))
        .shouldBeTrue;
    exists(outFile).shouldBeFalse;
}

// Marked @system because catching an Error is not allowed in @safe code
// (unittests are @safe by default in modern D).
@("writeClangTidyConfig aborts generation when the base config root is not a mapping")
@system unittest {
    import std.algorithm.iteration : map;
    import std.algorithm.searching : canFind;
    import std.experimental.logger.core : Logger, LogLevel, stdThreadLocalLog;
    import std.file : exists, mkdir, write, readText, tempDir, rmdirRecurse;
    import std.path : buildPath;
    import std.uuid : randomUUID;
    import unit_threaded.should : shouldEqual, shouldBeTrue, shouldBeFalse;

    static final class CapturingLogger : Logger {
        string[] msgs;

        this() {
            super(LogLevel.all);
        }

        protected override void writeLogMsg(ref LogEntry payload) @safe {
            msgs ~= payload.msg;
        }
    }

    auto dir = buildPath(tempDir(), "code_checker_ut_" ~ randomUUID().toString);
    mkdir(dir);
    scope (exit)
        rmdirRecurse(dir);
    auto baseConf = AbsolutePath(buildPath(dir, "base.conf"));
    write(baseConf, "- a\n" ~ "- b\n");
    auto outFile = AbsolutePath(buildPath(dir, ".clang-tidy"));

    auto conf = Config.make(AbsolutePath(dir), AbsolutePath(buildPath(dir, "ut.toml")));
    conf.clangTidy.headerFilter = "my-hdrs";

    auto savedLog = stdThreadLocalLog;
    scope (exit)
        stdThreadLocalLog = savedLog;
    auto captured = new CapturingLogger;
    stdThreadLocalLog = captured;

    auto caught = false;
    try {
        writeClangTidyConfig(baseConf, outFile, conf);
    } catch (Exception e) {
        caught = true;
    }
    caught.shouldBeTrue;

    // The failure is logged and the existing .clang-tidy is left untouched.
    (captured.msgs.canFind!(m => m.canFind("not a mapping"))).shouldBeTrue;
    exists(outFile).shouldBeFalse;
}

@("writeClangTidyConfig replaces a mapping HeaderFilterRegex value with the user scalar")
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
    write(baseConf, "Checks: \"-*\"\n" ~ "HeaderFilterRegex:\n" ~ "  a: b\n");
    auto outFile = AbsolutePath(buildPath(dir, ".clang-tidy"));

    auto conf = Config.make(AbsolutePath(dir), AbsolutePath(buildPath(dir, "ut.toml")));
    conf.clangTidy.headerFilter = "my-hdrs";

    writeClangTidyConfig(baseConf, outFile, conf);

    auto root = Loader.fromString(readText(outFile)).load();
    // The mapping value is replaced by the plain user scalar (as!string on a
    // mapping would throw).
    root["HeaderFilterRegex"].as!string.shouldEqual("my-hdrs");
    root["Checks"].as!string.shouldEqual("-*");
}

// Marked @system because catching an Error is not allowed in @safe code
// (unittests are @safe by default in modern D).
@(
        "writeClangTidyConfig aborts generation when the base config has duplicate HeaderFilterRegex keys")
@system unittest {
    import std.algorithm.iteration : map, filter;
    import std.algorithm.searching : canFind;
    import std.array : array;
    import std.experimental.logger.core : Logger, LogLevel, stdThreadLocalLog;
    import std.file : exists, mkdir, write, readText, tempDir, rmdirRecurse;
    import std.path : buildPath;
    import std.uuid : randomUUID;
    import unit_threaded.should : shouldEqual, shouldBeTrue, shouldBeFalse;

    static final class CapturingLogger : Logger {
        string[] msgs;

        this() {
            super(LogLevel.all);
        }

        protected override void writeLogMsg(ref LogEntry payload) @safe {
            msgs ~= payload.msg;
        }
    }

    auto dir = buildPath(tempDir(), "code_checker_ut_" ~ randomUUID().toString);
    mkdir(dir);
    scope (exit)
        rmdirRecurse(dir);
    auto baseConf = AbsolutePath(buildPath(dir, "base.conf"));
    // dyaml's composer rejects duplicate mapping keys, so the base config
    // does not even load: generation aborts with a fatal Error (as with an
    // unparseable base) and no filter option can be applied.
    auto raw = "Checks: \"-*\"\n" ~ "HeaderFilterRegex: '.*'\n" ~ "HeaderFilterRegex: 'y.*'\n";
    write(baseConf, raw);
    auto outFile = AbsolutePath(buildPath(dir, ".clang-tidy"));

    auto conf = Config.make(AbsolutePath(dir), AbsolutePath(buildPath(dir, "ut.toml")));
    conf.clangTidy.headerFilter = "my-hdrs";
    conf.clangTidy.headerExcludeFilter = "3rd/.*";

    auto savedLog = stdThreadLocalLog;
    scope (exit)
        stdThreadLocalLog = savedLog;
    auto captured = new CapturingLogger;
    stdThreadLocalLog = captured;

    auto caught = false;
    try {
        writeClangTidyConfig(baseConf, outFile, conf);
    } catch (Exception e) {
        caught = true;
    }
    caught.shouldBeTrue;

    // The failure is logged and the existing .clang-tidy is left untouched.
    (captured.msgs.canFind!(m => m.canFind("Failed to load clang-tidy system configuration")))
        .shouldBeTrue;
    exists(outFile).shouldBeFalse;
}

@("writeClangTidyConfig preserves the base config's mapping key order")
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
    write(baseConf, "User:                   system\n" ~ "Checks:                 \"-*\"\n"
            ~ "FormatStyle:            none\n" ~ "HeaderFilterRegex:      '.*'\n");
    auto outFile = AbsolutePath(buildPath(dir, ".clang-tidy"));

    auto conf = Config.make(AbsolutePath(dir), AbsolutePath(buildPath(dir, "ut.toml")));

    writeClangTidyConfig(baseConf, outFile, conf);

    auto root = Loader.fromString(readText(outFile)).load();
    auto pairs = root.as!(Node.Pair[]);
    pairs.length.shouldEqual(4);
    pairs[0].key.as!string.shouldEqual("User");
    pairs[0].value.as!string.shouldEqual("system");
    pairs[1].key.as!string.shouldEqual("Checks");
    pairs[1].value.as!string.shouldEqual("-*");
    pairs[2].key.as!string.shouldEqual("FormatStyle");
    pairs[2].value.as!string.shouldEqual("none");
    pairs[3].key.as!string.shouldEqual("HeaderFilterRegex");
    pairs[3].value.as!string.shouldEqual(".*");
}

@("writeClangTidyConfig emits the GENERATED header as the first line of a valid YAML document")
unittest {
    import std.algorithm.searching : canFind, endsWith;
    import std.file : mkdir, write, readText, tempDir, rmdirRecurse;
    import std.path : buildPath;
    import std.string : splitLines;
    import std.uuid : randomUUID;
    import unit_threaded.should : shouldEqual, shouldBeTrue, shouldBeFalse;

    auto dir = buildPath(tempDir(), "code_checker_ut_" ~ randomUUID().toString);
    mkdir(dir);
    scope (exit)
        rmdirRecurse(dir);
    auto baseConf = AbsolutePath(buildPath(dir, "base.conf"));
    write(baseConf, "Checks: \"-*\"\n");
    auto outFile = AbsolutePath(buildPath(dir, ".clang-tidy"));

    auto conf = Config.make(AbsolutePath(dir), AbsolutePath(buildPath(dir, "ut.toml")));

    writeClangTidyConfig(baseConf, outFile, conf);

    auto text = readText(outFile);
    // The generated file parses and its first line is the code_checker
    // header: with YAMLVersion = null dyaml emits no %YAML directive and no
    // --- document-start before the mapping (probe-verified).
    Loader.fromString(text).load();
    text.splitLines[0].shouldEqual(ClangTidyConstants.codeCheckerConfigHeader);
    // Pinned trailing-newline behavior: dyaml's dump ends the document with a
    // line break.
    text.endsWith("\n").shouldBeTrue;
    text.canFind("---").shouldBeFalse;
}

@("loadClangTidyConfig parses a valid mapping base config")
unittest {
    import dyaml : NodeType;
    import std.file : mkdir, write, readText, tempDir, rmdirRecurse;
    import std.path : buildPath;
    import std.uuid : randomUUID;
    import unit_threaded.should : shouldBeTrue, shouldEqual;

    auto dir = buildPath(tempDir(), "code_checker_ut_" ~ randomUUID().toString);
    mkdir(dir);
    scope (exit)
        rmdirRecurse(dir);
    auto baseConf = AbsolutePath(buildPath(dir, "base.conf"));
    write(baseConf, "Checks:                 \"-*\"\n" ~ "HeaderFilterRegex:      '.*'\n");

    auto loaded = loadClangTidyConfig(baseConf);

    loaded.ok.shouldBeTrue;
    loaded.root.type.shouldEqual(NodeType.mapping);
    loaded.root["Checks"].as!string.shouldEqual("-*");
    loaded.rawText.shouldEqual(
            "Checks:                 \"-*\"\n" ~ "HeaderFilterRegex:      '.*'\n");
}

@("loadClangTidyConfig fails on a missing file")
unittest {
    import std.array : empty;
    import std.file : tempDir;
    import std.path : buildPath;
    import std.uuid : randomUUID;
    import unit_threaded.should : shouldBeTrue, shouldBeFalse;

    auto baseConf = AbsolutePath(buildPath(tempDir(),
            "code_checker_ut_" ~ randomUUID().toString, "missing.conf"));

    auto loaded = loadClangTidyConfig(baseConf);

    loaded.ok.shouldBeFalse;
    loaded.rawText.empty.shouldBeTrue;
}

@("loadClangTidyConfig fails on an empty file")
unittest {
    import std.array : empty;
    import std.file : mkdir, write, tempDir, rmdirRecurse;
    import std.path : buildPath;
    import std.uuid : randomUUID;
    import unit_threaded.should : shouldBeTrue, shouldBeFalse;

    auto dir = buildPath(tempDir(), "code_checker_ut_" ~ randomUUID().toString);
    mkdir(dir);
    scope (exit)
        rmdirRecurse(dir);
    auto baseConf = AbsolutePath(buildPath(dir, "base.conf"));
    write(baseConf, "");

    auto loaded = loadClangTidyConfig(baseConf);

    loaded.ok.shouldBeFalse;
    loaded.rawText.empty.shouldBeTrue;
}

@("loadClangTidyConfig fails on malformed YAML")
unittest {
    import std.array : empty;
    import std.file : mkdir, write, tempDir, rmdirRecurse;
    import std.path : buildPath;
    import std.uuid : randomUUID;
    import unit_threaded.should : shouldBeTrue, shouldBeFalse;

    auto dir = buildPath(tempDir(), "code_checker_ut_" ~ randomUUID().toString);
    mkdir(dir);
    scope (exit)
        rmdirRecurse(dir);
    auto baseConf = AbsolutePath(buildPath(dir, "base.conf"));
    write(baseConf, "Checks:\n\t- \"-*\"\n");

    auto loaded = loadClangTidyConfig(baseConf);

    loaded.ok.shouldBeFalse;
    // The file was readable, so the verbatim-copy fallback still has it.
    loaded.rawText.empty.shouldBeFalse;
}

@("loadClangTidyConfig fails on a non-mapping root")
unittest {
    import dyaml : NodeType;
    import std.array : empty;
    import std.file : mkdir, write, tempDir, rmdirRecurse;
    import std.path : buildPath;
    import std.uuid : randomUUID;
    import unit_threaded.should : shouldBeTrue, shouldBeFalse, shouldEqual;

    auto dir = buildPath(tempDir(), "code_checker_ut_" ~ randomUUID().toString);
    mkdir(dir);
    scope (exit)
        rmdirRecurse(dir);
    auto baseConf = AbsolutePath(buildPath(dir, "base.conf"));
    write(baseConf, "- a\n- b\n");

    auto loaded = loadClangTidyConfig(baseConf);

    loaded.ok.shouldBeFalse;
    loaded.root.type.shouldEqual(NodeType.sequence);
    loaded.rawText.empty.shouldBeFalse;
}

@("loadClangTidyConfig fails on a multi-document base config")
unittest {
    import std.array : empty;
    import std.file : mkdir, write, tempDir, rmdirRecurse;
    import std.path : buildPath;
    import std.uuid : randomUUID;
    import unit_threaded.should : shouldEqual, shouldBeFalse;

    auto dir = buildPath(tempDir(), "code_checker_ut_" ~ randomUUID().toString);
    mkdir(dir);
    scope (exit)
        rmdirRecurse(dir);
    auto baseConf = AbsolutePath(buildPath(dir, "base.conf"));
    // dyaml's scanner rejects multi-document streams, so the loader helper
    // reports the failure and hands back the raw text for the caller.
    auto content = "---\n" ~ "Checks: \"-*\"\n" ~ "---\n" ~ "foo: 1\n";
    write(baseConf, content);

    auto loaded = loadClangTidyConfig(baseConf);

    loaded.ok.shouldBeFalse;
    loaded.rawText.shouldEqual(content);
}

@("loadClangTidyConfig fails on a non-UTF-8 file")
unittest {
    import std.array : empty;
    import std.file : mkdir, tempDir, rmdirRecurse;
    import std.path : buildPath;
    import std.stdio : File;
    import std.uuid : randomUUID;
    import unit_threaded.should : shouldBeTrue, shouldBeFalse;

    auto dir = buildPath(tempDir(), "code_checker_ut_" ~ randomUUID().toString);
    mkdir(dir);
    scope (exit)
        rmdirRecurse(dir);
    auto rawPath = buildPath(dir, "base.conf");
    auto baseConf = AbsolutePath(rawPath);
    // readText throws UTFException, which the loader helper maps to a plain
    // failure (no raw text is kept).
    auto f = File(rawPath, "wb");
    f.rawWrite([cast(ubyte) 0xff, cast(ubyte) 0xfe]);
    f.close;

    auto loaded = loadClangTidyConfig(baseConf);

    loaded.ok.shouldBeFalse;
    loaded.rawText.empty.shouldBeTrue;
}

@("hasConfigHeaderOptions finds both header option keys")
unittest {
    import dyaml : Loader;
    import unit_threaded.should : shouldBeTrue;

    auto root = Loader.fromString(
            "Checks: '*'\n" ~ "HeaderFilterRegex:      '.*'\n" ~ "ExcludeHeaderFilterRegex: 'x'\n").load();

    auto r = hasConfigHeaderOptions(root);

    r.include.shouldBeTrue;
    r.exclude.shouldBeTrue;
}

@("hasConfigHeaderOptions finds each header option key separately")
unittest {
    import dyaml : Loader;
    import unit_threaded.should : shouldBeTrue, shouldBeFalse;

    auto withInclude = Loader.fromString("HeaderFilterRegex:      '.*'\n").load();
    auto withExclude = Loader.fromString("ExcludeHeaderFilterRegex: 'x'\n").load();

    auto rInclude = hasConfigHeaderOptions(withInclude);
    auto rExclude = hasConfigHeaderOptions(withExclude);

    rInclude.include.shouldBeTrue;
    rInclude.exclude.shouldBeFalse;
    rExclude.include.shouldBeFalse;
    rExclude.exclude.shouldBeTrue;
}

@("hasConfigHeaderOptions reports absent keys")
unittest {
    import dyaml : Loader;
    import unit_threaded.should : shouldBeFalse;

    auto root = Loader.fromString(
            "Checks: '*'\n" ~ "CheckOptions:\n" ~ "  - key: a\n" ~ "    value: b\n").load();

    auto r = hasConfigHeaderOptions(root);

    r.include.shouldBeFalse;
    r.exclude.shouldBeFalse;
}

@("hasConfigHeaderOptions tolerates a non-mapping root")
unittest {
    import dyaml : Loader;
    import unit_threaded.should : shouldBeFalse;

    auto sequenceRoot = Loader.fromString("- a\n- b\n").load();
    auto scalarRoot = Loader.fromString("42\n").load();

    auto rSequence = hasConfigHeaderOptions(sequenceRoot);
    auto rScalar = hasConfigHeaderOptions(scalarRoot);

    rSequence.include.shouldBeFalse;
    rSequence.exclude.shouldBeFalse;
    rScalar.include.shouldBeFalse;
    rScalar.exclude.shouldBeFalse;
}

@("hasConfigHeaderOptions skips non-scalar mapping keys")
unittest {
    import dyaml : Loader;
    import unit_threaded.should : shouldBeTrue, shouldBeFalse;

    auto withComplexKey = Loader.fromString("{a: b}: c\n" ~ "HeaderFilterRegex:      '.*'\n").load();
    auto withNullKey = Loader.fromString("~: c\n" ~ "ExcludeHeaderFilterRegex: 'x'\n").load();

    auto rComplex = hasConfigHeaderOptions(withComplexKey);
    auto rNull = hasConfigHeaderOptions(withNullKey);

    rComplex.include.shouldBeTrue;
    rComplex.exclude.shouldBeFalse;
    rNull.include.shouldBeFalse;
    rNull.exclude.shouldBeTrue;
}

@("buildChecksSequence splits the shipped config's Checks scalar")
unittest {
    import std.algorithm.searching : canFind;
    import dyaml : NodeType;
    import unit_threaded.should : shouldEqual, shouldBeTrue, shouldBeFalse;

    static string[] entriesOf(Node n) @trusted {
        import std.algorithm.iteration : map;
        import std.array : array;

        return n.as!(Node[])
            .map!(e => e.as!string)
            .array;
    }

    static string dumped(Node n) @trusted {
        import std.array : appender;

        auto app = appender!string;
        Dumper().dump(app, n);
        return app.data;
    }

    auto loaded = loadClangTidyConfig(AbsolutePath("etc/code_checker/clang_tidy.conf"));
    loaded.ok.shouldBeTrue;

    auto r = buildChecksSequence(loaded.root["Checks"], null);

    r.type.shouldEqual(NodeType.sequence);
    entriesOf(r).shouldEqual([
        "-*", "clang-diagnostic-*", "clang-analyzer-*", "cppcoreguidelines*",
        "readability-*", "modernize-*", "-modernize-use-trailing-return-type",
        "hicpp*"
    ]);
    dumped(r).canFind("\n- ").shouldBeFalse;
}

@("buildChecksSequence splices computed checks after the shipped entries")
unittest {
    import std.algorithm.searching : canFind;
    import std.string : endsWith;
    import dyaml : NodeType;
    import unit_threaded.should : shouldEqual, shouldBeTrue, shouldBeFalse;

    static string[] entriesOf(Node n) @trusted {
        import std.algorithm.iteration : map;
        import std.array : array;

        return n.as!(Node[])
            .map!(e => e.as!string)
            .array;
    }

    static string dumped(Node n) @trusted {
        import std.array : appender;

        auto app = appender!string;
        Dumper().dump(app, n);
        return app.data;
    }

    auto loaded = loadClangTidyConfig(AbsolutePath("etc/code_checker/clang_tidy.conf"));
    loaded.ok.shouldBeTrue;

    auto r = buildChecksSequence(loaded.root["Checks"], ["-computed*"]);

    r.type.shouldEqual(NodeType.sequence);
    dumped(r).endsWith("]\n").shouldBeTrue;
    dumped(r).canFind("\n- ").shouldBeFalse;
    entriesOf(r).shouldEqual([
        "-*", "clang-diagnostic-*", "clang-analyzer-*", "cppcoreguidelines*",
        "readability-*", "modernize-*",
        "-modernize-use-trailing-return-type", "hicpp*", "-computed*"
    ]);
}

@("buildChecksSequence contributes no entries from an empty Checks scalar")
unittest {
    import std.algorithm.searching : canFind;
    import std.string : endsWith;
    import dyaml : Loader, NodeType;
    import unit_threaded.should : shouldEqual, shouldBeTrue, shouldBeFalse;

    static string[] entriesOf(Node n) @trusted {
        import std.algorithm.iteration : map;
        import std.array : array;

        return n.as!(Node[])
            .map!(e => e.as!string)
            .array;
    }

    static string dumped(Node n) @trusted {
        import std.array : appender;

        auto app = appender!string;
        Dumper().dump(app, n);
        return app.data;
    }

    auto root = Loader.fromString("Checks: ''\n").load();

    auto r = buildChecksSequence(root["Checks"], ["-a", "-b"]);

    r.type.shouldEqual(NodeType.sequence);
    dumped(r).endsWith("]\n").shouldBeTrue;
    dumped(r).canFind("\n- ").shouldBeFalse;
    entriesOf(r).shouldEqual(["-a", "-b"]);
}

@("buildChecksSequence keeps a sequence Checks value")
unittest {
    import std.algorithm.searching : canFind;
    import std.string : endsWith;
    import dyaml : Loader, NodeType;
    import unit_threaded.should : shouldEqual, shouldBeTrue, shouldBeFalse;

    static string[] entriesOf(Node n) @trusted {
        import std.algorithm.iteration : map;
        import std.array : array;

        return n.as!(Node[])
            .map!(e => e.as!string)
            .array;
    }

    static string dumped(Node n) @trusted {
        import std.array : appender;

        auto app = appender!string;
        Dumper().dump(app, n);
        return app.data;
    }

    auto root = Loader.fromString("Checks:\n" ~ "  - a\n" ~ "  -  b \n").load();

    auto r = buildChecksSequence(root["Checks"], ["c"]);

    r.type.shouldEqual(NodeType.sequence);
    dumped(r).endsWith("]\n").shouldBeTrue;
    dumped(r).canFind("\n- ").shouldBeFalse;
    entriesOf(r).shouldEqual(["a", "b", "c"]);
}

@("buildChecksSequence skips an unusable Checks value")
unittest {
    import std.algorithm.searching : canFind;
    import std.string : endsWith;
    import dyaml : Loader, NodeType;
    import unit_threaded.should : shouldEqual, shouldBeTrue, shouldBeFalse;

    static string[] entriesOf(Node n) @trusted {
        import std.algorithm.iteration : map;
        import std.array : array;

        return n.as!(Node[])
            .map!(e => e.as!string)
            .array;
    }

    static string dumped(Node n) @trusted {
        import std.array : appender;

        auto app = appender!string;
        Dumper().dump(app, n);
        return app.data;
    }

    auto root = Loader.fromString("Checks:\n" ~ "  a: b\n").load();

    auto r = buildChecksSequence(root["Checks"], ["-a"]);

    r.type.shouldEqual(NodeType.sequence);
    dumped(r).endsWith("]\n").shouldBeTrue;
    dumped(r).canFind("\n- ").shouldBeFalse;
    entriesOf(r).shouldEqual(["-a"]);
}

@("buildChecksSequence contributes no entries from a Checks null node")
unittest {
    import dyaml : Loader, NodeType;
    import unit_threaded.should : shouldEqual;

    static string[] entriesOf(Node n) @trusted {
        import std.algorithm.iteration : map;
        import std.array : array;

        return n.as!(Node[])
            .map!(e => e.as!string)
            .array;
    }

    auto root = Loader.fromString("Checks:\n" ~ "HeaderFilterRegex: '.*'\n").load();

    auto r = buildChecksSequence(root["Checks"], ["-a"]);

    r.type.shouldEqual(NodeType.sequence);
    entriesOf(r).shouldEqual(["-a"]);
}
