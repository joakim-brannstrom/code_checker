/**
Copyright: Copyright (c) 2018, Joakim Brännström. All rights reserved.
License: $(LINK2 http://www.boost.org/LICENSE_1_0.txt, Boost Software License 1.0)
Author: Joakim Brännström (joakim.brannstrom@gmx.com)
*/
module test_clang_tidy_rules;

import config;

@("runs clang-tidy successfully on a c++ file")
unittest {
    auto ta = makeTestArea;
    // action
    auto res = ta.exec(appPath, "--verbose", "trace", "--compile-db",
            buildPath(testData, "cpp", "empty", compileCommandsFile));

    // assert
    assert(res.status == 0);
}

@("warns about name style in a c++ file")
unittest {
    auto ta = makeTestArea;
    // action
    auto res = ta.exec(appPath, "--verbose", "trace", "--compile-db", buildPath(testData, "cpp",
            "name_style", compileCommandsFile), "-c", buildPath(testData, "all_checks.toml"));

    // assert
    assert(res.status != 0);
}
