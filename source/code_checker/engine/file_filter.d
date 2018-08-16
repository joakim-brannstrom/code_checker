/**
Copyright: Copyright (c) 2018, Joakim Brännström. All rights reserved.
License: MPL-2
Author: Joakim Brännström (joakim.brannstrom@gmx.com)

This Source Code Form is subject to the terms of the Mozilla Public License,
v.2.0. If a copy of the MPL was not distributed with this file, You can obtain
one at http://mozilla.org/MPL/2.0/.

This file is under the MPL-2 license because it is code copied from deXtool.

This file contains functions for filtering files over a regex.
*/
module code_checker.engine.file_filter;

import std.regex : Regex, regex;

@safe:

struct FileFilter {
    import std.array : array;
    import std.algorithm : map;

    Regex!char[] exclude;

    this(string[] raw_regex) {
        foreach (a; raw_regex) {
            try {
                this.exclude ~= regex(a);
            } catch (Exception e) {
                throw new Exception("Bad regex:" ~ a ~ ":" ~ e.msg);
            }
        }
    }

    /// Returns: true if the file matches the permissions in the file filter and thus should be used.
    bool match(string fname) {
        if (exclude.length > 0)
            return !matchAny(fname, exclude);
        return true;
    }
}

auto fileFilter(Range)(Range r, string[] raw_regex) {
    import std.algorithm : filter;

    auto ff = FileFilter(raw_regex);
    return r.filter!(a => ff.isOk(a));
}

/// Returns: true if the value match any regex.
bool matchAny(const string value, Regex!char[] re) @safe nothrow {
    import std.algorithm : canFind;
    import std.regex : matchFirst, RegexException;

    bool passed = false;

    foreach (ref a; re) {
        try {
            auto m = matchFirst(value, a);
            if (!m.empty && m.pre.length == 0 && m.post.length == 0) {
                passed = true;
                break;
            }
        } catch (Exception ex) {
        }
    }

    return passed;
}

version (unittest) {
    import unit_threaded : shouldBeTrue;
}

@("Shall match all regex")
@safe unittest {
    import std.regex : regex;

    Regex!char[] re = [regex(".*/foo/.*"), regex(".*/src/.*")];

    matchAny("/p/foo/more/src/file.c", re).shouldBeTrue;
}
