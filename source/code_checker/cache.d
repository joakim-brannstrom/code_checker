/**
Copyright: Copyright (c) 2021, Joakim Brännström. All rights reserved.
License: $(LINK2 http://www.boost.org/LICENSE_1_0.txt, Boost Software License 1.0)
Author: Joakim Brännström (joakim.brannstrom@gmx.com)
*/
module code_checker.cache;

import logger = std.experimental.logger;
import std.exception : collectException;

import my.path;

import code_checker.database : TrackFileByStat, TrackFile;

struct FileStatCache(T, alias query) {
    T[AbsolutePath] cache_;

    T get(AbsolutePath p) @safe nothrow {
        try {
            return cache_.require(p, query(p));
        } catch (Exception e) {
        }
        return T.init;
    }

    void drop(AbsolutePath p) @safe nothrow {
        cache_.remove(p);
    }
}

TrackFileByStat getTrackFileByStat(Path p) @safe nothrow {
    import std.datetime : Clock;
    import std.file : timeLastModified, getSize;

    auto ts = () {
        try {
            return timeLastModified(p);
        } catch (Exception e) {
            logger.trace(e.msg).collectException;
        }
        return Clock.currTime;
    }();

    try {
        auto sz = getSize(p);
        return TrackFileByStat(p, sz, ts);
    } catch (Exception e) {
        logger.trace(e.msg).collectException;
    }
    return TrackFileByStat(p, 0, ts);
}

TrackFile getTrackFile(Path p) @trusted nothrow {
    import std.datetime : Clock;
    import std.file : timeLastModified;
    import my.hash : checksum, makeChecksum64, Checksum64;

    auto cs = () {
        try {
            return checksum!makeChecksum64(AbsolutePath(p));
        } catch (Exception e) {
            logger.trace(e.msg).collectException;
        }
        return Checksum64.init;
    }();

    auto ts = () {
        try {
            return timeLastModified(p);
        } catch (Exception e) {
            logger.trace(e.msg).collectException;
        }
        return Clock.currTime;
    }();

    return TrackFile(p, cs, ts);
}
