/**
Copyright: Copyright (c) 2019, Joakim Brännström. All rights reserved.
License: $(LINK2 http://www.boost.org/LICENSE_1_0.txt, Boost Software License 1.0)
Author: Joakim Brännström (joakim.brannstrom@gmx.com)
*/
module code_checker.utility;

import logger = std.experimental.logger;

import my.path;

/// Replace words in a configuration string with the appropriate values.
auto replaceConfigWords(T)(T range) {
    import std.algorithm : map;
    import std.array : replace;
    import std.file : thisExePath;
    import std.path : dirName;

    return range.map!(a => a.replace("{code_checker}", thisExePath.dirName));
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
