/**
Copyright: Copyright (c) 2018, Joakim Brännström. All rights reserved.
License: $(LINK2 http://www.boost.org/LICENSE_1_0.txt, Boost Software License 1.0)
Author: Joakim Brännström (joakim.brannstrom@gmx.com)
*/
module test_toml_config;

import config;

@("shall load all sections from the TOML config and successfully execute")
unittest {
    auto ta = makeTestArea;
    mkdir(ta.inSandboxPath("db"));
    copy(buildPath(testData, "conf", "read_sections", "all_sections.toml"),
            ta.inSandboxPath(".code_checker.toml"));
    copy(buildPath(testData, "conf", "read_sections", "compile_commands.json"),
            ta.inSandboxPath("db/compile_commands.json"));
    copy(buildPath(testData, "conf", "read_sections", "empty.cpp"), ta.inSandboxPath("empty.cpp"));

    auto res = ta.exec([appPath, "--verbose", "trace"]);

    res.status.shouldEqual(0);
    foreach (l; res.output.splitLines) {
        l.canFind("Unknown key").shouldBeFalse;
    }
}

@("shall exclude files based on the regex from the config file")
unittest {
    auto ta = makeTestArea;
    copy(buildPath(testData, "conf", "file_filter", "exclude_a_file.toml"),
            ta.inSandboxPath(".code_checker.toml"));
    copy(buildPath(testData, "conf", "file_filter", "compile_commands.json"),
            ta.inSandboxPath("compile_commands.json"));
    copy(buildPath(testData, "conf", "file_filter", "empty.cpp"), ta.inSandboxPath("empty.cpp"));
    copy(buildPath(testData, "conf", "file_filter", "error_in_file.cpp"),
            ta.inSandboxPath("error_in_file.cpp"));
    copy(buildPath(testData, "conf", "file_filter", "error_in_header.cpp"),
            ta.inSandboxPath("error_in_header.cpp"));
    copy(buildPath(testData, "conf", "file_filter", "error_in_header.hpp"),
            ta.inSandboxPath("error_in_header.hpp"));

    auto res = ta.exec([appPath, "--verbose", "trace"]);

    res.status.shouldEqual(0);
}

@("shall run the generate command before reading the DB")
unittest {
    auto ta = makeTestArea;
    dirContentCopy(buildPath(testData, "conf", "gen_db_cmd"), ta.sandboxPath);

    auto res = ta.exec([appPath, "--verbose", "trace", "-c", "gen_cmd.toml"]);
    res.status.shouldEqual(0);
}

@("shall log the output from a failed command to generate a compile commands DB to the user")
unittest {
    auto ta = makeTestArea;
    dirContentCopy(buildPath(testData, "conf", "fail_gen_db_cmd"), ta.sandboxPath);

    auto res = ta.exec([appPath, "--verbose", "trace", "-c", "gen_cmd.toml"]);
    res.status.shouldEqual(1);

    res.output.splitLines.any!(a => a.canFind("--workdir")).shouldBeTrue;
    res.output.splitLines.any!(a => a.canFind("error: exit 1")).shouldBeTrue;
}

@("shall use the user specified compiler to determine system includes")
unittest {
    auto ta = makeTestArea;
    dirContentCopy(buildPath(testData, "conf", "specify_system_compiler"), ta.sandboxPath);

    auto res = ta.exec([appPath, "--verbose", "trace"]);

    res.status.shouldEqual(0);

    foreach (l; res.output.splitLines) {
        if (l.canFind(`compiler: ./fake_cc.d flags: [] includes: [] system-includes: ["/foo/bar"]`))
            return;
    }

    // no -isystem /foo/bar found
    shouldBeTrue(false);
}

@("shall only execute the specified analyser iwyu when checking")
unittest {
    auto ta = makeTestArea;
    dirContentCopy(buildPath(testData, "conf", "specify_analysers"), ta.sandboxPath);
    {
        auto txt = readText(ta.inSandboxPath(".code_checker.toml"));
        File(ta.inSandboxPath(".code_checker.toml"), "w").writef(txt,
                ta.inSandboxPath("fake_iwyu.d"));
    }

    auto res = ta.exec([appPath, "--verbose", "trace"]);

    res.status.shouldEqual(1);

    foreach (l; res.output.splitLines) {
        if (l.canFind(`staticCode: using iwyu`))
            return;
        l.canFind(`staticCode: using iwyu`).shouldBeFalse;
    }

    // failed
    shouldBeTrue(false);
}
