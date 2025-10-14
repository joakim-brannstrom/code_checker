/**
Copyright: Copyright (c) 2019, Joakim Brännström. All rights reserved.
License: $(LINK2 http://www.boost.org/LICENSE_1_0.txt, Boost Software License 1.0)
Author: Joakim Brännström (joakim.brannstrom@gmx.com)
*/
module code_checker.utility;

import logger = std.experimental.logger;

import my.path;

string replaceConfigWord(string s) @safe {
    import std.array : replace;

    foreach (kv; MagicConfWord.byKeyValue) {
        s = s.replace(kv.key, kv.value);
    }

    return s;
}

auto warnIfFileDoNotExist(T)(T range) {
    import std.algorithm : filter;
    import std.file : exists;

    return range.filter!((a) {
        if (exists(a))
            return true;
        logger.tracef("File '%s' do not exist", a);
        return false;
    });
}

AbsolutePath toAbsoluteRoot(Path root, Path p) {
    import std.path : buildPath;

    return AbsolutePath(buildPath(root, p));
}

double[3] osAverageLoad() nothrow @nogc @trusted {
    import my.libc : getloadavg;

    double[3] load;
    const nr = getloadavg(&load[0], 3);
    if (nr <= 0 || nr > load.length) {
        return [0.0, 0.0, 0.0];
    }
    return load;
};

private:

immutable string[string] MagicConfWord;

shared static this() {
    import std.file : thisExePath;
    import std.path : dirName;
    import std.process : environment;

    string[string] magicConfWordTmp;
    magicConfWordTmp["{code_checker}"] = thisExePath.dirName;
    magicConfWordTmp["${CODE_CHECKER_CLANGTIDY}"] = environment.get(
            "CODE_CHECKER_CLANGTIDY", "clang-tidy");
    magicConfWordTmp["${CODE_CHECKER_IWYU}"] = environment.get("CODE_CHECKER_IWYU", "iwyu");
    MagicConfWord = cast(immutable) magicConfWordTmp;
}
