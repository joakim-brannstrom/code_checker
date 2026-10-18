/**
Copyright: Copyright (c) 2018, Joakim Brännström. All rights reserved.
License: $(LINK2 http://www.boost.org/LICENSE_1_0.txt, Boost Software License 1.0)
Author: Joakim Brännström (joakim.brannstrom@gmx.com)
*/
module test_toml_config;

import config;

@("loads all sections from the TOML config and executes successfully")
unittest {
    auto ta = makeTestArea;
    mkdir(ta.inSandboxPath("db"));
    copy(buildPath(testData, "conf", "read_sections", "all_sections.toml"),
            ta.inSandboxPath(".code_checker.toml"));
    copy(buildPath(testData, "conf", "read_sections", "compile_commands.json"),
            ta.inSandboxPath("db/compile_commands.json"));
    copy(buildPath(testData, "conf", "read_sections", "empty.cpp"), ta.inSandboxPath("empty.cpp"));

    auto res = ta.exec([appPath, "--verbose", "trace"]);

    assert(res.status == 0);
    foreach (l; res.output.splitLines) {
        assert(!l.canFind("Unknown key"));
    }

    assert(ta.inSandboxPath("mydb.sqlite3").exists);
}

@("excludes files based on the regex from the config file")
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

    assert(res.status == 0);
}

@("runs the generate command before reading the DB")
unittest {
    auto ta = makeTestArea;
    dirContentCopy(buildPath(testData, "conf", "gen_db_cmd"), ta.sandboxPath);

    auto res = ta.exec([appPath, "--verbose", "trace", "-c", "gen_cmd.toml"]);
    assert(res.status == 0);
}

@("logs the output from a failed command to generate a compile commands DB to the user")
unittest {
    auto ta = makeTestArea;
    dirContentCopy(buildPath(testData, "conf", "fail_gen_db_cmd"), ta.sandboxPath);

    auto res = ta.exec([appPath, "--verbose", "trace", "-c", "gen_cmd.toml"]);
    assert(res.status == 1);

    assert(res.output.splitLines.any!(a => a.canFind("--workdir")));
    assert(res.output.splitLines.any!(a => a.canFind("error: exit 1")));
}

@("uses the user specified compiler to determine system includes")
unittest {
    auto ta = makeTestArea;
    dirContentCopy(buildPath(testData, "conf", "specify_system_compiler"), ta.sandboxPath);

    auto res = ta.exec([appPath, "--verbose", "trace"]);
    assert(res.status == 0);

    foreach (l; res.output.splitLines) {
        if (l.canFind(`Compiler:./fake_cc.d flags: -isystem /foo/bar`))
            return;
    }

    // no -isystem /foo/bar found
    assert(false);
}

@("only executes the specified analyser iwyu when checking")
unittest {
    auto ta = makeTestArea;
    dirContentCopy(buildPath(testData, "conf", "specify_analysers"), ta.sandboxPath);
    {
        auto txt = readText(ta.inSandboxPath(".code_checker.toml"));
        File(ta.inSandboxPath(".code_checker.toml"), "w").writef(txt,
                ta.inSandboxPath("fake_iwyu.d"));
    }

    auto res = ta.exec([appPath, "--verbose", "trace"]);
    assert(res.status == 0);

    foreach (l; res.output.splitLines) {
        if (l.canFind(`staticCode: using iwyu`))
            return;
        assert(!l.canFind(`staticCode: using iwyu`));
    }

    // failed
    assert(false);
}

@("generates a new config file from the default settings when called with --init")
unittest {
    auto ta = makeTestArea;

    auto res = ta.exec([appPath, "--verbose", "trace", "--init"]);
    assert(res.status == 0);

    ".*system_conf.*=.*code_checker/default.toml".regexIn(
            File(ta.inSandboxPath(".code_checker.toml")).byLineCopy.array);
}

@("generates a new config file from a custom template when called with --init")
unittest {
    auto ta = makeTestArea;

    auto res = ta.exec([
        appPath, "--verbose", "trace", "--init", "--init-template",
        buildPath(testData, "conf", "default_conf", "my_conf_template.toml")
    ]);
    assert(res.status == 0);

    ".*foo.imp.*".regexIn(File(ta.inSandboxPath(".code_checker.toml")).byLineCopy.array);
}

@("uses the compiler flag filter from the config when analyzing a file")
unittest {
    auto ta = makeTestArea;
    dirContentCopy(buildPath(testData, "conf", "compiler_filter"), ta.sandboxPath);
    mkdir(ta.inSandboxPath("db"));
    dirContentCopy(buildPath(testData, "conf", "compiler_filter", "db"), ta.inSandboxPath("db"));

    auto res = ta.exec([
        appPath, "--verbose", "trace", "-c", "code_checker.toml"
    ]);
    assert(res.status == 0);

    ".*mremove-dummy=foobar.*".regexNotIn(
            File(ta.inSandboxPath("compile_commands.json")).byLineCopy.array);
}

@("dedups files for analyze")
unittest {
    auto ta = makeTestArea;
    dirContentCopy(buildPath(testData, "conf", "dedup"), ta.sandboxPath);
    mkdir(ta.inSandboxPath("db"));
    dirContentCopy(buildPath(testData, "conf", "dedup", "db"), ta.inSandboxPath("db"));

    auto res = ta.exec([
        appPath, "--verbose", "trace", "-c", "code_checker.toml"
    ]);
    assert(res.status == 0);

    int cnt;
    foreach (l; res.output.splitLines) {
        if (l.canFind(`run: clang-tidy`))
            cnt++;
    }

    assert(cnt == 2);
}

@("reads the binary path from the env variable in config")
unittest {
    auto ta = makeTestArea;
    dirContentCopy(buildPath(testData, "conf", "binary_from_env"), ta.sandboxPath);

    string[string] env;
    env["CODE_CHECKER_CLANGTIDY"] = ta.inSandboxPath("fake_code_checker.d");
    auto res = ta.exec([
        appPath, "--verbose", "trace", "-c", "code_checker.toml"
    ], env);

    assert(res.status == 0);
    ".*fake_code_checker.*".regexIn(res.output.splitLines);
}
