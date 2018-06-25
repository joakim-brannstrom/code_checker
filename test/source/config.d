/**
Copyright: Copyright (c) 2018, Joakim Brännström. All rights reserved.
License: $(LINK2 http://www.boost.org/LICENSE_1_0.txt, Boost Software License 1.0)
Author: Joakim Brännström (joakim.brannstrom@gmx.com)
*/
module config;

public import core.stdc.stdlib;
public import std.algorithm;
public import std.array;
public import std.ascii;
public import std.conv;
public import std.file;
public import std.process;
public import std.path;
public import std.range;
public import std.stdio;
public import std.string;
public import logger = std.experimental.logger;

public import unit_threaded.light;

immutable codeCherckerBin = "../build/code_checker";
immutable compileCommandsFile = "compile_commands.json";
immutable testData = "testdata";
immutable tmpDir = "./build/test_area";

struct TestArea {
    const string workdir;

    alias workdir this;

    this(string file, ulong id) {
        this.workdir = buildPath(tmpDir, file ~ id.to!string).absolutePath;
        setup();
    }

    void setup() {
        if (exists(workdir)) {
            rmdirRecurse(workdir);
        }
        mkdirRecurse(workdir);
    }
}

struct RunResult {
    int status;
    string[] stdout;
    string[] stderr;

    void print() {
        writeln("stdout: ", stdout);
        writeln("stderr: ", stderr);
    }
}

RunResult run(string[] cmd) {
    import std.array : appender;
    import std.algorithm : joiner, copy;
    import std.ascii : newline;
    import std.process : pipeProcess, tryWait, Redirect;
    import std.stdio : writeln;
    import core.thread : Thread;
    import core.time : dur;

    logger.trace("run: ", cmd.joiner(" "));

    auto app_out = appender!(string[])();
    auto app_err = appender!(string[])();

    auto p = pipeProcess(cmd, Redirect.all);
    int exit_status = -1;

    while (true) {
        auto pres = p.pid.tryWait;

        p.stdout.byLineCopy.copy(app_out);
        p.stderr.byLineCopy.copy(app_err);

        if (pres.terminated) {
            exit_status = pres.status;
            break;
        }

        Thread.sleep(25.dur!"msecs");
    }

    return RunResult(exit_status, app_out.data, app_err.data);
}
