/**
Copyright: Copyright (c) 2019, Joakim Brännström. All rights reserved.
License: $(LINK2 http://www.boost.org/LICENSE_1_0.txt, Boost Software License 1.0)
Author: Joakim Brännström (joakim.brannstrom@gmx.com)

This module contains an analyser and runner for
[iwyu](https://github.com/include-what-you-use/include-what-you-use).
*/
module code_checker.engine.builtin.include_what_you_use;

import logger = std.experimental.logger;
import std.concurrency : Tid, thisTid;
import std.exception : collectException;
import std.typecons : Tuple;

import code_checker.engine.builtin.clang_tidy_classification : CountErrorsResult;
import code_checker.engine.file_filter;
import code_checker.engine.types;
import code_checker.process : RunResult;
import code_checker.types;

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
        import std.algorithm : copy;
        import std.array : appender;
        import std.range : put;

        auto app = appender!(string[])();
        app.put(env.iwyu.binary);
        env.iwyu.extraFlags.copy(app);
        iwyuArgs = app.data;
    }

    override void execute() {
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
    import std.array : appender;
    import std.concurrency : thisTid, receiveTimeout;
    import std.format : format;
    import std.parallelism : task, TaskPool;
    import code_checker.compile_db : UserFileRange;
    import code_checker.engine.logger : Logger;

    bool logged_failure;
    auto logg = Logger(env.logg.dir);

    void collectResult(immutable(IwyuResult)* res_) @trusted nothrow {
        import std.typecons : nullableRef;
        import colorlog;

        auto res = nullableRef(cast() res_);

        logger.infof("%s '%s'", "iwyu analyzing".color(Color.yellow)
                .bg(Background.black), res.file).collectException;

        result_.score -= res.exitStatus > 0 ? res.exitStatus : 0;

        if (res.exitStatus != 0) {
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

            result_.status = mergeStatus(result_.status, res.exitStatus == 0
                    ? Status.passed : Status.failed);
        }
    }

    auto pool = new TaskPool;
    scope (exit)
        pool.finish;
    ExpectedReplyCounter cond;

    auto file_filter = FileFilter(env.staticCode.fileExcludeFilter);
    foreach (cmd; UserFileRange(env.compileDb, env.files, env.compiler.extraFlags,
            env.flagFilter, env.compiler.useCompilerSystemIncludes)) {
        if (cmd.isNull) {
            result_.score -= 1000;
            result_.msg ~= Msg(MsgSeverity.failReason, "iwyu where unable to find one of the specified files in compile_commands.json on the filesystem. Your compile_commands.json is probably out of sync. Regenerate it.");
        } else if (!file_filter.match(cmd.absoluteFile)) {
            continue;
        }

        cond.expected++;

        immutable(IwyuWork)* w = () @trusted {
            auto args = appender!(string[])();
            iwyuArgs.copy(args);
            cmd.flags.systemIncludes.map!(a => ["-isystem", a]).joiner.copy(args);
            cmd.flags.includes.map!(a => ["-I", a]).joiner.copy(args);
            args.put(cmd.absoluteFile);

            return cast(immutable) new IwyuWork(args.data, cmd.absoluteFile);
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
            writeln(l).collectException;
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
