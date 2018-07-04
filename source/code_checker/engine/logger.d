/**
Copyright: Copyright (c) 2018, Joakim Brännström. All rights reserved.
License: $(LINK2 http://www.boost.org/LICENSE_1_0.txt, Boost Software License 1.0)
Author: Joakim Brännström (joakim.brannstrom@gmx.com)

This module contains functionality for logging analyzer results to files.
*/
module code_checker.engine.logger;

import code_checker.types : AbsolutePath;

@safe:

struct Logger {
    private {
        AbsolutePath logdir;
    }

    this(AbsolutePath p) {
        this.logdir = p;
    }

    /** Log `content` to a file in logdir with a filename derived from f.
     *
     */
    void put(const AbsolutePath f, const string[][] content) @trusted {
        import std.algorithm : joiner;
        import std.file : mkdirRecurse, exists;
        import std.path : pathSplitter, buildPath;
        import std.range : dropOne;
        import std.stdio : File;
        import std.utf : toUTF8;

        if (!exists(logdir))
            mkdirRecurse(logdir);

        string lfile = buildPath(logdir, f.dup.dropOne.pathSplitter.joiner("_").toUTF8 ~ ".txt");
        auto fout = File(lfile, "w");

        foreach (l; (cast(string[][]) content).joiner)
            fout.writeln(l);
    }
}
