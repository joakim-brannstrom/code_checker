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
    copy(buildPath(testData, "conf", "read_sections", "all_sections.toml"),
            buildPath(ta, ".code_checker.toml"));
    copy(buildPath(testData, "conf", "read_sections", "compile_commands.json"),
            buildPath(ta, "db", "compile_commands.json"));
    copy(buildPath(testData, "conf", "read_sections", "empty.cpp"), buildPath(ta, "empty.cpp"));

    auto res = run([codeCherckerBin, "--vverbose"], ta);

    res.print;
    res.status.shouldEqual(0);
}

@("shall exclude files based on the regex from the config file")
unittest {
    auto ta = TestArea(__FILE__, __LINE__);
    copy(buildPath(testData, "conf", "file_filter", "exclude_a_file.toml"),
            buildPath(ta, ".code_checker.toml"));
    copy(buildPath(testData, "conf", "file_filter", "compile_commands.json"),
            buildPath(ta, "compile_commands.json"));
    copy(buildPath(testData, "conf", "file_filter", "empty.cpp"), buildPath(ta, "empty.cpp"));
    copy(buildPath(testData, "conf", "file_filter", "error_in_file.cpp"),
            buildPath(ta, "error_in_file.cpp"));
    copy(buildPath(testData, "conf", "file_filter", "error_in_header.cpp"),
            buildPath(ta, "error_in_header.cpp"));
    copy(buildPath(testData, "conf", "file_filter", "error_in_header.hpp"),
            buildPath(ta, "error_in_header.hpp"));

    auto res = run([codeCherckerBin, "--vverbose"], ta);

    res.print;
    res.status.shouldEqual(0);
}
