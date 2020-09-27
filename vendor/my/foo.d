#!/usr/bin/env rdmd
/**
Copyright: Copyright (c) 2021, Joakim Brännström. All rights reserved.
License: $(LINK2 http://www.boost.org/LICENSE_1_0.txt, Boost Software License 1.0)
Author: Joakim Brännström (joakim.brannstrom@gmx.com)
*/

import std;

int main(string[] args) {
    auto p = "/foo/bar/smurf";

    const root = p.rootName;
    while (p != root) {
        p = p.dirName;
        writeln(p);
    }

    return 0;
}
