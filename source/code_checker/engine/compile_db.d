/**
Copyright: Copyright (c) 2021, Joakim Brännström. All rights reserved.
License: $(LINK2 http://www.boost.org/LICENSE_1_0.txt, Boost Software License 1.0)
Author: Joakim Brännström (joakim.brannstrom@gmx.com)

Convert a compile_commands.json to an array. Convenient code that is re-used by all engine types.
*/
module code_checker.engine.compile_db;

import compile_db : ParsedCompileCommandRange;

ParsedCompileCommandRange toRange(T)(T env) {
    import std.array : array;
    import compile_db : parseFlag, CompileCommandFilter, limitOrAllRange, parse,
        prependFlags, addCompiler, replaceCompiler, addSystemIncludes, fileRange;
    import compile_db.user_filerange : ParsedCompileCommandRange;

    // the following are not needed for now:
    //.addCompiler
    //.replaceCompiler
    //.prependFlags
    // because they are covered by the unification of the database.

    // dfmt off
    return ParsedCompileCommandRange
        .make(env.compileDb.parse(
        env.conf.compileDb.flagFilter)
        .addSystemIncludes.prependFlags(env.conf.compiler.extraFlags)
        .array);
    // dfmt on
}
