/**
Copyright: Copyright (c) 2017, Joakim Brännström. All rights reserved.
License: $(LINK2 http://www.boost.org/LICENSE_1_0.txt, Boost Software License 1.0)
Author: Joakim Brännström (joakim.brannstrom@gmx.com)

The only purpose of this file is to redirect the execution of integration tests
from the main directory to the subdirectory test.

It is NOT intended to be used for anything else.
*/
module autoformat.test.redirect;

import std.exception;
import std.file;
import std.path;
import std.process;
import std.stdio;

int main(string[] args) {
    writeln("===============================");
    writeln("Redirecting testing to: ", buildPath(getcwd, "test"));

    // make sure the build is pristine
    if (spawnProcess(["dub", "build", "-c", "application"]).wait != 0) {
        return -1;
    }

    chdir("test");
    cleanupAfterOldTest;

    args = () {
        if (args.length > 1)
            return args[1 .. $];
        return null;
    }();

    return spawnProcess(["dub", "test", "--"] ~ args).wait;
}

private:

void cleanupAfterOldTest() {
    import core.thread : Thread;
    import core.time : dur;

    immutable tmpDir = "build/test";

    // prepare by cleaning up
    if (exists(tmpDir)) {
        while (true) {
            try {
                rmdirRecurse(tmpDir);
                break;
            } catch (Exception e) {
                writeln(e.msg);
            }
            Thread.sleep(100.dur!"msecs");
        }
    }
}
