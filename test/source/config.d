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

immutable string codeCherckerBin;
immutable compileCommandsFile = "compile_commands.json";
immutable testData = "testdata";
immutable tmpDir = "./build/test_area";

shared static this() {
    codeCherckerBin = absolutePath("../build/code_checker");
}

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
        import std.ascii : newline;

        writeln("stdout: ", stdout.joiner(newline));
        writeln("stderr: ", stderr.joiner(newline));
    }
}

RunResult run(string[] cmd, string workdir = null) {
    import std.array : appender;
    import std.algorithm : joiner, copy;
    import std.ascii : newline;
    import std.process : pipeProcess, tryWait, Redirect;
    import std.stdio : writeln;
    import core.thread : Thread;
    import core.time : dur;

    logger.trace("run: ", cmd.joiner(" "));
    if (workdir !is null)
        logger.trace("workdir is ", workdir);

    auto app_out = appender!(string[])();
    auto app_err = appender!(string[])();

    auto p = pipeProcess(cmd, Redirect.all, null, Config.none, workdir);
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

void dirContentCopy(string src, string dst) {
    import std.algorithm;
    import std.file;
    import std.path;
    import core.sys.posix.sys.stat;

    assert(src.isDir);
    assert(dst.isDir);

    foreach (f; dirEntries(src, SpanMode.shallow).filter!"a.isFile") {
        auto dst_f = buildPath(dst, f.name.baseName);
        copy(f.name, dst_f);
        auto attrs = getAttributes(f.name);
        if (attrs & S_IXUSR)
            setAttributes(dst_f, attrs | S_IXUSR);
    }
}
