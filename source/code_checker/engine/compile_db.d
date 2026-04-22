/**
Copyright: Copyright (c) 2021, Joakim Brännström. All rights reserved.
License: $(LINK2 http://www.boost.org/LICENSE_1_0.txt, Boost Software License 1.0)
Author: Joakim Brännström (joakim.brannstrom@gmx.com)

Convert a compile_commands.json to an array. Convenient code that is re-used by all engine types.
*/
module code_checker.engine.compile_db;

import std.algorithm : filter, map;

import code_checker.engine.types : Environment;
import compile_db : ParsedCompileCommandRange, ParsedCompileCommand;
import my.filter : ReFilter;
import compile_db : parseFlag, CompileCommandFilter, limitOrAllRange, parse,
    prependFlags, addCompiler, replaceCompiler,
    addSystemIncludes, fileRange, CompileCommand, SystemIncludePath, ParsedCompileCommand;
import std.array : array;

ParsedCompileCommandRange toRange(Environment env) @safe {
    import my.path;
    import my.set;

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

    auto fileFilter = ReFilter(env.conf.staticCode.fileIncludeFilter,
            env.conf.staticCode.fileExcludeFilter);

    // dfmt off
    return ParsedCompileCommandRange.make(files
        .parse(env.conf.compileDb.flagFilter)
        .addSystemIncludes.prependFlags(env.conf.compiler.extraFlags)
        .map!(a => optimizeScan(fileFilter, a))
        .array);
    // dfmt on
}

// clang-tidy only scan those includes that are accessed by -I. By moving
// those that the user asked us not to scan to be read as -isystem the
// final scan is sped up.
ParsedCompileCommand optimizeScan(ReFilter fileFilter, ParsedCompileCommand cmd) @safe {
    cmd.flags.systemIncludes = cmd.flags.systemIncludes ~ cmd.flags
        .includes
        .filter!(a => !fileFilter.match(a))
        .map!(a => SystemIncludePath(a))
        .array;
    cmd.flags.includes = cmd.flags.includes.filter!(a => fileFilter.match(a)).array;
    return cmd;
}
