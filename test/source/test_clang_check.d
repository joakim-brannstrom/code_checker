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
            inTestData("cpp/code_mistakes"));

    // assert
    res.status.shouldNotEqual(0);
}

@("shall save dependencies in database")
unittest {
    auto ta = makeTestArea;

    dirContentCopy(buildPath(testData, "cpp", "dep_scan"), ta.sandboxPath);

    // action
    auto res = ta.exec(appPath, "--verbose", "trace", "-c", "code_checker.toml");

    // assert
    res.status.shouldEqual(0);
}
