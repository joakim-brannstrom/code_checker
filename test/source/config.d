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
