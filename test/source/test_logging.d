/**
Copyright: Copyright (c) 2018, Joakim Brännström. All rights reserved.
License: $(LINK2 http://www.boost.org/LICENSE_1_0.txt, Boost Software License 1.0)
Author: Joakim Brännström (joakim.brannstrom@gmx.com)
*/
module test_logging;

import config;

@("shall create a log file")
unittest {
    auto ta = TestArea(__FILE__, __LINE__);

    run([codeCherckerBin, "--init"], ta).status.shouldEqual(0);
    run([codeCherckerBin, "--vverbose", "--log", "--compile-db",
            buildPath(testData, "log", "compile_commands.json").absolutePath], ta)
        .status.shouldEqual(1);

    // 2 because it should be one configuration file and one logfile
    dirEntries(ta, SpanMode.shallow).count.shouldEqual(2);
}

@("shall create logs in the specified directory")
unittest {
    auto ta = TestArea(__FILE__, __LINE__);

    run([codeCherckerBin, "--init"], ta).status.shouldEqual(0);
    run([codeCherckerBin, "--log", "--logdir", "log", "--compile-db",
            buildPath(testData, "log", "compile_commands.json").absolutePath], ta)
        .status.shouldEqual(1);

    // 1 because it is separated from the config file
    dirEntries(buildPath(ta, "log"), SpanMode.shallow).count.shouldEqual(1);
}

@("shall create a log file and a yaml fixit log")
unittest {
    auto ta = TestArea(__FILE__, __LINE__);
    copy(buildPath(testData, "log", "compile_commands.json"), buildPath(ta,
            "compile_commands.json"));
    copy(buildPath(testData, "log", "empty.cpp"), buildPath(ta, "empty.cpp"));

    run([codeCherckerBin, "--init"], ta).status.shouldEqual(0);
    run([codeCherckerBin, "--clang-tidy-fix", "--log"], ta).status.shouldEqual(1);

    // 4 because it should be one configuration file, one logfile, one compile_commands.json and one yaml file
    dirEntries(ta, SpanMode.shallow).count.shouldEqual(4);
}
