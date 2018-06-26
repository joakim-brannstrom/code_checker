/**
Copyright: Copyright (c) 2018, Joakim Brännström. All rights reserved.
License: $(LINK2 http://www.boost.org/LICENSE_1_0.txt, Boost Software License 1.0)
Author: Joakim Brännström (joakim.brannstrom@gmx.com)

This file contains an analyzer that uses clang-tidy.
*/
module code_checker.engine.builtin.clang_tidy;

import logger = std.experimental.logger;

import code_checker.engine.types;
import code_checker.types;

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

        if (env.clangTidy.applyFixit)
            app.put(["-fix"]);

        ["-header-filter", env.clangTidy.headerFilter].copy(app);

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
        import std.format : format;
        import code_checker.compile_db : UserFileRange, parseFlag,
            CompileCommandFilter;
        import colorize : Color, color, Background, Mode;

        bool logged_failure;

        foreach (cmd; UserFileRange(env.compileDb, env.files, null, CompileCommandFilter.init)) {
            if (cmd.isNull) {
                result_.status = Status.failed;
                result_.score -= 100;
                result_.msg ~= Msg(Severity.failReason,
                        "clang-tidy where unable to find one of the specified files in compile_commands.json");
                break;
            }

            logger.infof("%s '%s'", "Analyzing".color(Color.yellow,
                    Background.black), cmd.absoluteFile);

            auto st = runClangTidy(tidyArgs, cmd.cflags, cmd.absoluteFile);
            // just chose some numbers. The intent is that warnings should be a high penalty
            result_.score += st == 0 ? 1 : -10;

            if (st != 0) {
                if (!logged_failure) {
                    result_.msg ~= Msg(Severity.failReason, "clang-tidy warn about file(s)");
                    logged_failure = true;
                }

                result_.msg ~= Msg(Severity.improveSuggestion,
                        format("clang-tidy: fix warnings in '%s'", cmd.absoluteFile.payload));
            }

            result_.status = mergeStatus(result_.status, st == 0 ? Status.passed : Status.failed);
            logger.trace(result_);
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

package:

struct ClangTidyConstants {
    static immutable bin = "clang-tidy";
    static immutable confFile = ".clang-tidy";
}

int runClangTidy(string[] tidy_args, string[] compiler_args, AbsolutePath fname) {
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
