/**
Copyright: Copyright (c) 2021, Joakim Brännström. All rights reserved.
License: $(LINK2 http://www.boost.org/LICENSE_1_0.txt, Boost Software License 1.0)
Author: Joakim Brännström (joakim.brannstrom@gmx.com)

Convert a compile_commands.json to an array. Convenient code that is re-used by all engine types.
*/
module code_checker.engine.compile_db;

import code_checker.engine.types : Environment;
import compile_db : ParsedCompileCommandRange;

ParsedCompileCommandRange toRange(Environment env) @safe {
    import std.algorithm : filter, map;
    import std.array : array;
    import my.path;
    import my.set;
    import compile_db : parseFlag, CompileCommandFilter, limitOrAllRange, parse, prependFlags,
        addCompiler, replaceCompiler, addSystemIncludes, fileRange, CompileCommand;
    import compile_db.user_filerange : ParsedCompileCommandRange;

    // the following are not needed for now:
    //.addCompiler
    //.replaceCompiler
    //.prependFlags
    // because they are covered by the unification of the database.

    auto userFiles = toSet(env.files.map!(a => AbsolutePath(a)));

    bool userFileFilter(CompileCommand a) {
        if (userFiles.empty)
            return true;
        return a.absoluteFile in userFiles;
    }

    Set!AbsolutePath analyzed;
    auto uniqueFilter = () {
        if (env.conf.compileDb.dedupFiles) {
            return (CompileCommand a) {
                if (a.absoluteFile in analyzed)
                    return false;
                analyzed.add(a.absoluteFile);
                return true;
            };
        }
        return (CompileCommand a) => true;
    }();

    auto files = env.compileDb
        .fileRange
        .filter!userFileFilter
        .filter!uniqueFilter
        .array;

    // dfmt off
    return ParsedCompileCommandRange.make(files
        .parse(env.conf.compileDb.flagFilter)
        .addSystemIncludes.prependFlags(env.conf.compiler.extraFlags)
        .array);
    // dfmt on
}
