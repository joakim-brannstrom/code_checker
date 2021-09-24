/**
Copyright: Copyright (c) 2021, Joakim Brännström. All rights reserved.
License: $(LINK2 http://www.boost.org/LICENSE_1_0.txt, Boost Software License 1.0)
Author: Joakim Brännström (joakim.brannstrom@gmx.com)
*/
module code_checker.cache;

import logger = std.experimental.logger;
import std.exception : collectException;

import my.path;

import code_checker.database : TrackFileByStat;

struct FileStatCache {
    TrackFileByStat[AbsolutePath] cache_;

    TrackFileByStat get(AbsolutePath p) @safe nothrow {
        try {
            return cache_.require(p, getTrackFileByStat(p));
        } catch (Exception e) {
        }
        return TrackFileByStat.init;
    }
}

private:

TrackFileByStat getTrackFileByStat(Path p) @safe nothrow {
    import std.file : timeLastModified, getSize;

    try {
        auto ts = timeLastModified(p);
        auto sz = getSize(p);
        return TrackFileByStat(p, sz, ts);
    } catch (Exception e) {
        logger.trace(e.msg).collectException;
    }
    return TrackFileByStat(p);
}
