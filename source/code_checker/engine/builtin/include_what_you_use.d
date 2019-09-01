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
        import std.algorithm;
        import std.array : appender, array;
        import std.ascii;
        import std.file : exists;
        import std.range : put;
        import std.format : format;
        import code_checker.engine.builtin.clang_tidy_classification : filterSeverity;

        auto app = appender!(string[])();
        app.put(env.iwyu.binary);

        env.iwyu.extraFlags.copy(app);
        // TODO: this is probably wrong
        //env.compiler.extraFlags.copy(app);

        iwyuArgs = app.data;
    }

    override void execute() {
        import std.algorithm : copy, map, joiner;
        import std.array : array, appender;
        import std.format : format;
        import std.path : buildPath;
        import std.process : spawnProcess, wait;
        import std.range : enumerate;
        import code_checker.compile_db : UserFileRange, CompileCommandFilter, SearchResult;
        import code_checker.engine.logger : Logger;

        // for now iwyu can never fail.
        result_.status = Status.passed;

        void executeIwyu(SearchResult cmd) {
            auto args = appender!(string[])();

            iwyuArgs.copy(args);
            cmd.flags.systemIncludes.map!(a => ["-isystem", a]).joiner.copy(args);
            cmd.flags.includes.map!(a => ["-I", a]).joiner.copy(args);

            args.put(cmd.absoluteFile);

            logger.tracef("run: %-(%s %)", args.data);
            auto status = spawnProcess(args.data).wait;
        }

        auto file_filter = FileFilter(env.staticCode.fileExcludeFilter);
        auto cmds = UserFileRange(env.compileDb, env.files, env.compiler.extraFlags,
                env.flagFilter, env.compiler.useCompilerSystemIncludes).array;
        const max_nr = cmds.length;
        foreach (idx, cmd; cmds.enumerate) {
            if (cmd.isNull) {
                result_.score -= 1000;
                result_.msg ~= Msg(MsgSeverity.failReason, "iwyu where unable to find one of the specified files in compile_commands.json on the filesystem. Your compile_commands.json is probably out of sync. Regenerate it.");
            } else if (!file_filter.match(cmd.absoluteFile)) {
                continue;
            }

            logger.infof("File %s/%s %s", idx + 1, max_nr, cmd.absoluteFile);
            executeIwyu(cmd);
        }
    }

    override void tearDown() {
    }

    override Result result() {
        return result_;
    }
}
