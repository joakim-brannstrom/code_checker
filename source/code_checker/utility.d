/**
Copyright: Copyright (c) 2019, Joakim Brännström. All rights reserved.
License: $(LINK2 http://www.boost.org/LICENSE_1_0.txt, Boost Software License 1.0)
Author: Joakim Brännström (joakim.brannstrom@gmx.com)
*/
module code_checker.utility;

import logger = std.experimental.logger;

/// Replace words in a configuration string with the appropriate values.
auto replaceConfigWords(T)(T range) {
    import std.algorithm : map;
    import std.array : replace;
    import std.file : thisExePath;

    return range.map!(a => a.replace("{code_checker}", thisExePath));
}

auto warnIfFileDoNotExist(T)(T range) {
    import std.algorithm : filter;
    import std.file : exists;

    return range.filter!((a) {
        if (exists(a))
            return true;
        logger.tracef("Unable to load the mapping file '%s' because it do not exist", a);
        return false;
    });
}
