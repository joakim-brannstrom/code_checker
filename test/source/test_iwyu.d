/**
Copyright: Copyright (c) 2019, Joakim Brännström. All rights reserved.
License: $(LINK2 http://www.boost.org/LICENSE_1_0.txt, Boost Software License 1.0)
Author: Joakim Brännström (joakim.brannstrom@gmx.com)
*/
module test_iwyu;

import config;

@("shall suggest including the leaf headerfile when running the iwyu analyzer")
unittest {
    auto ta = makeTestArea;
    dirContentCopy(buildPath(testData, "cpp", "suggest_improved_include"), ta.sandboxPath);

    auto res = ta.exec([appPath, "--verbose", "trace"]);
    res.status.shouldEqual(1);

    auto lines = res.output.splitLines.array;

    "first.cpp should add these lines:".regexIn(lines);
    `#include "third.hpp"  // for third`.regexIn(lines);
    `- #include "second.hpp"  // lines 2-2`.regexIn(lines);
    `The full include-list`.regexIn(lines);
    `Analyzers reported Failed`.regexIn(lines);
    `iwyu: 4 in.*first.cpp`.regexIn(lines);
    `You scored -4 points`.regexIn(lines);
}
