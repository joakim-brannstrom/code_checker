/**
Copyright: Copyright (c) 2018, Joakim Brännström. All rights reserved.
License: $(LINK2 http://www.boost.org/LICENSE_1_0.txt, Boost Software License 1.0)
Author: Joakim Brännström (joakim.brannstrom@gmx.com)
*/
module test_clang_check;

import config;

@("shall run clang-check and warning about div by zero")
unittest {
    // action
    auto res = run([codeCherckerBin, "--vverbose", "--compile-db",
            buildPath(testData, "cpp", "code_mistakes")]);

    // assert
    res.print;
    res.status.shouldNotEqual(0);
}
