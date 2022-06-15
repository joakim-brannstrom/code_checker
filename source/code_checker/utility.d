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

private:

immutable string[string] MagicConfWord;

shared static this() {
    import std.file : thisExePath;
    import std.path : dirName;

    string[string] magicConfWordTmp;
    magicConfWordTmp["{code_checker}"] = thisExePath.dirName;
    MagicConfWord = cast(immutable) magicConfWordTmp;
}
