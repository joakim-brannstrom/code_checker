/**
Copyright: Copyright (c) 2018, Joakim Brännström. All rights reserved.
License: $(LINK2 http://www.boost.org/LICENSE_1_0.txt, Boost Software License 1.0)
Author: Joakim Brännström (joakim.brannstrom@gmx.com)
*/
module test_clang_tidy_rules;

import config;

@("shall successfully run clang-tidy on a c++ file")
unittest {
    // action
    auto res = executeShell(codeCherckerBin ~ " --vverbose -c " ~ buildPath(testData,
            "cpp", "empty", compileCommandsFile));

    // assert
    writeln(res.output);
    res.status.shouldEqual(0);
}
