/**
Copyright: Copyright (c) 2018, Joakim Brännström. All rights reserved.
License: $(LINK2 http://www.boost.org/LICENSE_1_0.txt, Boost Software License 1.0)
Author: Joakim Brännström (joakim.brannstrom@gmx.com)
*/
module test_logging;

import config;

@("shall create a log file")
unittest {
    auto ta = makeTestArea;

    ta.exec([appPath, "--init"]).status.shouldEqual(0);
    ta.exec([
        appPath, "--verbose", "trace", "--log", "-c",
        buildPath(testData, "all_checks.toml"), "--compile-db",
        buildPath(testData, "log", "compile_commands.json").absolutePath
    ]).status.shouldEqual(1);

    dirEntries(ta.inSandboxPath("code_checker_log"), SpanMode.shallow).filter!(
            a => a.extension.among(".txt")).count.shouldEqual(1);
}

@("shall create logs in the specified directory")
unittest {
    auto ta = makeTestArea;

    ta.exec([appPath, "--init"]).status.shouldEqual(0);
    ta.exec([
        appPath, "--log", "--log-dir", "log", "-c",
        buildPath(testData, "all_checks.toml"), "--compile-db",
        buildPath(testData, "log", "compile_commands.json").absolutePath
    ]).status.shouldEqual(1);

    dirEntries(ta.inSandboxPath("log"), SpanMode.shallow).filter!(
            a => a.extension == ".txt").count.shouldEqual(1);
}

@("shall create json log")
unittest {
    auto ta = makeTestArea;

    ta.exec([appPath, "--init"]).status.shouldEqual(0);
    ta.exec([
        appPath, "--log-json", "data.json", "-c",
        buildPath(testData, "all_checks.toml"), "--compile-db",
        buildPath(testData, "log", "compile_commands.json").absolutePath
    ]).status.shouldEqual(1);

    exists(ta.inSandboxPath("data.json")).shouldBeTrue;
}

@("shall create a yaml fixit log")
unittest {
    auto ta = makeTestArea;
    copy(buildPath(testData, "log", "compile_commands.json"),
            ta.inSandboxPath("compile_commands.json"));
    copy(buildPath(testData, "log", "empty.cpp"), ta.inSandboxPath("empty.cpp"));

    ta.exec([appPath, "--init"]).status.shouldEqual(0);
    ta.exec([
        appPath, "--verbose", "trace", "--clang-tidy-fix", "-c",
        buildPath(testData, "all_checks.toml"), "--log", "log", "--log-dir", "log"
    ]).status.shouldEqual(0);

    dirEntries(ta.inSandboxPath("log"), SpanMode.shallow).filter!(
            a => a.extension == ".yaml").count.shouldEqual(1);
}
