#!/usr/bin/env rdmd

import std.algorithm;
import std.array;
import std.ascii;
import std.conv;
import std.file;
import std.path;
import std.process;
import std.range;
import std.stdio;
import std.string;
import logger = std.experimental.logger;

void main(string[] args) {
    const root = getcwd();
    const this_dir = __FILE_FULL_PATH__.dirName;
    const ut_src = buildPath(this_dir, "vendor", "unit-threaded");
    const gen_ut = buildPath(this_dir, "vendor", "unit-threaded", "gen_ut_main");

    {
        chdir(ut_src);
        scope (exit)
            chdir(root);
        spawnProcess(["dub", "build", "-c", "gen_ut_main"]).wait;
    }

    spawnProcess([gen_ut, "-f", args[1]]).wait;
}
