/**
Copyright: Copyright (c) Joakim Brännström. All rights reserved.
License: $(LINK2 http://www.boost.org/LICENSE_1_0.txt, Boost Software License 1.0)
Author: Joakim Brännström (joakim.brannstrom@gmx.com)

This module contains an analyser and runner for
[iwyu](https://github.com/include-what-you-use/include-what-you-use).
*/
module code_checker.engine.builtin.include_what_you_use;

import logger = std.experimental.logger;
import std.array : appender, empty, array;
import std.concurrency : Tid, thisTid;
import std.exception : collectException;
import std.typecons : Tuple;

import my.path : AbsolutePath, Path;
import my.filter : ReFilter;

import code_checker.engine.builtin.clang_tidy_classification : CountErrorsResult;
import code_checker.engine.types;
import code_checker.process : RunResult;

@safe:

class IncludeWhatYouUse : BaseFixture {
    private {
        Environment env;
        Result result_;
        string[] iwyuArgs;
    }

    override string name() {
        return "iwyu";
    }

    override string explain() {
        return "using iwyu (include what you use)";
    }

    /// The environment the analyzers execute in.
    override void putEnv(Environment v) {
        this.env = v;
    }

    /// Setup the environment for analyze.
    override void setup() {
        import std.algorithm : copy, map, joiner;
        import std.file : exists;
        import std.range : put, only;
        import code_checker.utility : replaceConfigWord, warnIfFileDoNotExist;

        auto app = appender!(string[])();
        app.put(env.conf.iwyu.binary);
        only(env.conf.iwyu.maps, env.conf.iwyu.defaultMaps).joiner
            .map!(a => a.replaceConfigWord)
            .warnIfFileDoNotExist
            .map!(a => only("-Xiwyu", "--mapping_file=" ~ a))
            .joiner
            .copy(app);
        env.conf.iwyu.extraFlags.copy(app);
        iwyuArgs = app.data;
    }

    override void execute() {
        result_.status = Status.passed;
        executeParallel(env, iwyuArgs, result_);
    }

    override void tearDown() {
    }

    override Result result() {
        return result_;
    }
}

private:

void executeParallel(Environment env, string[] iwyuArgs, ref Result result_) @safe {
    import std.algorithm : copy, map, joiner;
    import std.concurrency : thisTid, receiveTimeout;
    import std.file : exists;
    import std.format : format;
    import std.parallelism : task, TaskPool;
    import code_checker.engine.compile_db;
    import code_checker.engine.logger : Logger;

    bool logged_failure;
    auto logg = Logger(env.conf.logg.dir);

    void collectResult(immutable(IwyuResult)* res_) @trusted nothrow {
        import std.typecons : nullableRef;
        import colorlog;

        auto res = nullableRef(cast() res_);

        logger.infof("%s '%s'", "iwyu analyzing".color(Color.yellow)
                .bg(Background.black), res.file).collectException;

        // seems like 2 also means OK.
        const allIsOk = res.exitStatus == 0 || res.exitStatus == 2;

        if (!allIsOk)
            result_.score -= res.exitStatus > 0 ? res.exitStatus : 0;

        if (!allIsOk) {
            result_.failed ~= res.file;
            res.print;

            if (env.conf.logg.toFile) {
                try {
                    const logFile = Path(res.file.toString ~ ".iwyu").AbsolutePath;
                    logg.put(logFile, [res.output]);
                } catch (Exception e) {
                    logger.warning(e.msg).collectException;
                    logger.warning("Unable to log to file").collectException;
                }
            }

            if (!logged_failure) {
                result_.msg ~= Msg(MsgSeverity.failReason, "iwyu suggested improvements");
                logged_failure = true;
            }

            try {
                result_.msg ~= Msg(MsgSeverity.improveSuggestion,
                        format("iwyu: %s in %s", res.exitStatus, res.file));
            } catch (Exception e) {
                logger.warning(e.msg).collectException;
                logger.warning("Unable to add user message to the result").collectException;
            }

            result_.status = mergeStatus(result_.status, Status.failed);
        }
    }

    auto pool = new TaskPool;
    scope (exit)
        pool.finish;
    ExpectedReplyCounter cond;

    auto file_filter = ReFilter(env.conf.staticCode.fileIncludeFilter,
            env.conf.staticCode.fileExcludeFilter);
    auto fixedDb = toRange(env);

    foreach (cmd; fixedDb) {
        if (!exists(cmd.cmd.absoluteFile.toString)) {
            result_.score -= 1000;
            result_.msg ~= Msg(MsgSeverity.failReason, "iwyu where unable to find one of the specified files in compile_commands.json on the filesystem. Your compile_commands.json is probably out of sync. Regenerate it.");
            continue;
        } else if (!file_filter.match(cmd.cmd.absoluteFile)) {
            continue;
        }

        cond.expected++;

        immutable(IwyuWork)* w = () @trusted {
            import std.path : relativePath;

            auto args = appender!(string[])();
            iwyuArgs.copy(args);
            cmd.flags.cflags.copy(args);
            cmd.flags
                .includes
                .map!(a => relativePath(a))
                .map!(a => ["-I", a])
                .joiner
                .copy(args);
            cmd.flags.systemIncludes.map!(a => ["-isystem", a]).joiner.copy(args);
            args.put(cmd.cmd.absoluteFile);

            return cast(immutable) new IwyuWork(args.data, cmd.cmd.absoluteFile);
        }();

        auto t = task!taskIwyu(thisTid, w);
        pool.put(t);
    }

    while (cond.isWaitingForReplies) {
        import core.time : dur;

        () @trusted {
            try {
                if (receiveTimeout(1.dur!"seconds", &collectResult)) {
                    cond.replies++;
                }
            } catch (Exception e) {
                logger.error(e.msg);
            }
        }();
    }
}

struct ExpectedReplyCounter {
    int expected;
    int replies;

    bool isWaitingForReplies() {
        return replies < expected;
    }
}

struct IwyuResult {
    AbsolutePath file;

    /// Exit status from running iwyu.
    int exitStatus;
    /// Captured output from iwyu.
    string[] output;

    void print() @safe nothrow const scope {
        import std.stdio : writeln;

        foreach (l; output)
            try {
                writeln(l);
            } catch (Exception e) {
            }
    }
}

struct IwyuWork {
    string[] args;
    AbsolutePath file;
}

void taskIwyu(Tid owner, immutable IwyuWork* work_) nothrow @trusted {
    import std.concurrency : send;
    import code_checker.process;

    IwyuWork* work = cast(IwyuWork*) work_;
    auto rval = new IwyuResult;
    rval.file = work.file;

    try {
        auto res = run(work.args);
        rval.exitStatus = res.status;
        rval.output = res.stdout ~ res.stderr;
    } catch (Exception e) {
        logger.warning(e.msg).collectException;
    }

    while (true) {
        try {
            owner.send(cast(immutable) rval);
            break;
        } catch (Exception e) {
            logger.tracef("failed sending to: %s", owner).collectException;
        }
    }
}
