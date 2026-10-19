/**
Copyright: Copyright (c) 2018, Joakim Brännström. All rights reserved.
License: $(LINK2 http://www.boost.org/LICENSE_1_0.txt, Boost Software License 1.0)
Author: Joakim Brännström (joakim.brannstrom@gmx.com)
*/
module test_clang_check;

import config;

@("runs clang-check and warns about div by zero")
unittest {
    auto ta = makeTestArea;

    // action
    auto res = ta.exec(appPath, "--verbose", "trace", "--compile-db",
            inTestData("cpp/code_mistakes/compile_commands.json"));

    // assert
    assert(res.status != 0);
}

@("saves dependencies in the database")
unittest {
    auto ta = makeTestArea;

    dirContentCopy(buildPath(testData, "cpp", "dep_scan"), ta.sandboxPath);

    // action
    auto res = ta.exec(appPath, "--verbose", "trace", "-c",
            "code_checker.toml", "--progress", "saveDb");

    // assert
    assert(res.status == 0);

    auto lines = res.output.splitLines.array;
    "deps for .*/test.cpp : .*/test.hpp, .*test2.hpp".regexIn(lines);
    "deps for .*/test.hpp : .*test2.hpp".regexIn(lines);
    `deps for .*/test2.hpp : \[\]`.regexIn(lines);
}

@("runs a perf log")
unittest {
    auto ta = makeTestArea;

    dirContentCopy(buildPath(testData, "cpp", "perf"), ta.sandboxPath);

    // action
    auto res = ta.exec(appPath, "--verbose", "trace", "-c", "code_checker.toml");

    // no assert; this is only a performance test, checked manually
}

@("detects a tool malfunction: the tool fails to run but reports no warnings")
unittest {
    auto ta = makeTestArea;

    auto res = ta.exec(appPath, "--verbose", "trace", "--compile-db",
            inTestData("robustness/tool_failure/compile_commands.json"),
            "--clang-tidy-bin", inTestData("robustness/tool_failure/fejk_clang_tidy.sh"));

    assert(res.status == 0);
}
