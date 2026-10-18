/**
Copyright: Copyright (c) 2018, Joakim Brännström. All rights reserved.
License: $(LINK2 http://www.boost.org/LICENSE_1_0.txt, Boost Software License 1.0)
Author: Joakim Brännström (joakim.brannstrom@gmx.com)
*/
module test_logging;

import config;

@("creates a log file")
unittest {
    auto ta = makeTestArea;

    assert(ta.exec([appPath, "--init"]).status == 0);
    assert(ta.exec([
        appPath, "--verbose", "trace", "--log", "-c",
        buildPath(testData, "all_checks.toml"), "--compile-db",
        buildPath(testData, "log", "compile_commands.json").absolutePath
    ]).status == 1);

    assert(dirEntries(ta.inSandboxPath("code_checker_log"), SpanMode.shallow)
            .filter!(a => a.extension.among(".txt")).count == 1);
}

@("creates logs in the specified directory")
unittest {
    auto ta = makeTestArea;

    assert(ta.exec([appPath, "--init"]).status == 0);
    assert(ta.exec([
        appPath, "--log", "--log-dir", "log", "-c",
        buildPath(testData, "all_checks.toml"), "--compile-db",
        buildPath(testData, "log", "compile_commands.json").absolutePath
    ]).status == 1);

    assert(dirEntries(ta.inSandboxPath("log"), SpanMode.shallow)
            .filter!(a => a.extension == ".txt").count == 1);
}

@("creates a json log")
unittest {
    auto ta = makeTestArea;

    assert(ta.exec([appPath, "--init"]).status == 0);
    assert(ta.exec([
        appPath, "--log-json", "data.json", "-c",
        buildPath(testData, "all_checks.toml"), "--compile-db",
        buildPath(testData, "log", "compile_commands.json").absolutePath
    ]).status == 1);

    assert(exists(ta.inSandboxPath("data.json")));
}

@("creates a yaml fixit log")
unittest {
    auto ta = makeTestArea;
    copy(buildPath(testData, "log", "compile_commands.json"),
            ta.inSandboxPath("compile_commands.json"));
    copy(buildPath(testData, "log", "empty.cpp"), ta.inSandboxPath("empty.cpp"));

    assert(ta.exec([appPath, "--init"]).status == 0);
    assert(ta.exec([
        appPath, "--verbose", "trace", "--clang-tidy-fix", "-c",
        buildPath(testData, "all_checks.toml"), "--log", "log", "--log-dir", "log"
    ]).status == 0);

    assert(dirEntries(ta.inSandboxPath("log"), SpanMode.shallow)
            .filter!(a => a.extension == ".yaml").count == 1);
}
