/**
Copyright: Copyright (c) 2018, Joakim Brännström. All rights reserved.
License: $(LINK2 http://www.boost.org/LICENSE_1_0.txt, Boost Software License 1.0)
Author: Joakim Brännström (joakim.brannstrom@gmx.com)
*/
module test_toml_config;

import config;

@("shall load all sections from the TOML config and successfully execute")
unittest {
    auto ta = TestArea(__FILE__, __LINE__);
    mkdir(buildPath(ta, "db"));
    copy(buildPath(testData, "conf", "all_sections.toml"), buildPath(ta, ".code_checker.toml"));
    copy(buildPath(testData, "conf", "compile_commands.json"), buildPath(ta,
            "db", "compile_commands.json"));
    copy(buildPath(testData, "conf", "empty.cpp"), buildPath(ta, "empty.cpp"));

    auto res = run([codeCherckerBin, "--vverbose"], ta);

    res.print;
    res.status.shouldEqual(0);
}
