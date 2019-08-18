/**
Copyright: Copyright (c) 2018, Joakim Brännström. All rights reserved.
License: $(LINK2 http://www.boost.org/LICENSE_1_0.txt, Boost Software License 1.0)
Author: Joakim Brännström (joakim.brannstrom@gmx.com)
*/
module test_clang_tidy_rules;

import config;

@("shall successfully run clang-tidy on a c++ file")
unittest {
    auto ta = makeTestArea;
    // action
    auto res = ta.exec(appPath, "--vverbose", "--compile-db",
            buildPath(testData, "cpp", "empty", compileCommandsFile));

    // assert
    res.status.shouldEqual(0);
}

@("shall warn about name style in a c++ file")
unittest {
    auto ta = makeTestArea;
    // action
    auto res = ta.exec(appPath, "--vverbose", "--compile-db",
            buildPath(testData, "cpp", "name_style", compileCommandsFile));

    // assert
    res.status.shouldNotEqual(0);
}
