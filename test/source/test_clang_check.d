/**
Copyright: Copyright (c) 2018, Joakim Brännström. All rights reserved.
License: $(LINK2 http://www.boost.org/LICENSE_1_0.txt, Boost Software License 1.0)
Author: Joakim Brännström (joakim.brannstrom@gmx.com)
*/
module test_clang_check;

import config;

@("shall run clang-check and warning about div by zero")
unittest {
    auto ta = makeTestArea;

    // action
    auto res = ta.exec(appPath, "--verbose", "trace", "--compile-db",
            inTestData("cpp/code_mistakes/compile_commands.json"));

    // assert
    res.status.shouldNotEqual(0);
}

@("shall save dependencies in database")
unittest {
    auto ta = makeTestArea;

    dirContentCopy(buildPath(testData, "cpp", "dep_scan"), ta.sandboxPath);

    // action
    auto res = ta.exec(appPath, "--verbose", "trace", "-c",
            "code_checker.toml", "--progress", "saveDb");

    // assert
    res.status.shouldEqual(0);

    auto lines = res.output.splitLines.array;
    "deps for .*/test.cpp : .*/test.hpp, .*test2.hpp".regexIn(lines);
    "deps for .*/test.hpp : .*test2.hpp".regexIn(lines);
    `deps for .*/test2.hpp : \[\]`.regexIn(lines);
}

@("shall run a perf log")
unittest {
    auto ta = makeTestArea;

    dirContentCopy(buildPath(testData, "cpp", "perf"), ta.sandboxPath);

    // action
    auto res = ta.exec(appPath, "--verbose", "trace", "-c", "code_checker.toml");

    // no assert, this is just performance test that is manually checked
}

@("shall detect tool malfunction when failed to run but no warnings")
unittest {
    auto ta = makeTestArea;

    auto res = ta.exec(appPath, "--verbose", "trace", "--compile-db",
            inTestData("robustness/tool_failure/compile_commands.json"),
            "--clang-tidy-bin", inTestData("robustness/tool_failure/fejk_clang_tidy.sh"));

    res.status.shouldEqual(0);
}
