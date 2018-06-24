/**
Copyright: Copyright (c) 2018, Joakim Brännström. All rights reserved.
License: $(LINK2 http://www.boost.org/LICENSE_1_0.txt, Boost Software License 1.0)
Author: Joakim Brännström (joakim.brannstrom@gmx.com)

This file contains an analyzer that uses clang-tidy.
*/
module code_checker.engine.builtin.clang_tidy;

import code_checker.engine.types;
import code_checker.types;

@safe:

class ClangTidy : BaseFixture {
    public {
        Environment env;
        Result result_;
    }

    /// The environment the analysers execute in.
    override void putEnv(Environment v) {
        this.env = v;
    }

    /// Setup the environment for analyze.
    override void setup() {
        import std.file : exists;
        import std.stdio : File;

        if (!exists(ClangTidyConstants.confFile)) {
            File(ClangTidyConstants.confFile, "w").write(ClangTidyConstants.conf);
        }
    }

    /// Execute the analyser.
    override void execute() {
        import code_checker.compile_db;

        foreach (cmd; env.compileDb) {
            runClangTidy(cmd.parseFlag(CompileCommandFilter.init).flags, cmd.absoluteFile.payload);
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
    static immutable conf = import("default_clang_tidy.conf");
    static immutable confFile = ".clang-tidy";
}

int runClangTidy(string[] compiler_args, AbsoluteFileName fname) {
    import std.algorithm : map, copy;
    import std.format : format;
    import std.array : appender;
    import code_checker.process;

    auto app = appender!(string[])();
    app.put(ClangTidyConstants.bin);
    app.put("-p=.");
    app.put("-config=");
    app.put(fname);

    return run(app.data);
}
