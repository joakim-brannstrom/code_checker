/**
Copyright: Copyright (c) Joakim Brännström. All rights reserved.
License: $(LINK2 http://www.boost.org/LICENSE_1_0.txt, Boost Software License 1.0)
Author: Joakim Brännström (joakim.brannstrom@gmx.com)
*/
module code_checker.cache;

import logger = std.experimental.logger;
import std.exception : collectException;

import my.path;

import code_checker.database : TrackFile;

struct FileStatCache {
    import std.datetime : Clock, SysTime;
    import std.file : timeLastModified;
    import my.hash : checksum, makeChecksum64, Checksum64;

    TrackFile[AbsolutePath] cache_;
    SysTime[AbsolutePath] timeStamp_;
    Checksum64[AbsolutePath] checkSum_;

    TrackFile get(AbsolutePath p) @safe nothrow {
        try {
            return cache_.require(p, TrackFile(p, getChecksum(p), getTimeStamp(p)));
        } catch (Exception e) {
        }
        return TrackFile.init;
    }

    SysTime getTimeStamp(AbsolutePath p) @safe nothrow {
        try {
            return timeStamp_.require(p, timeLastModified(p));
        } catch (Exception e) {
            try {
                logger.trace(e.msg);
            } catch (Exception e) {
            }
        }
        return Clock.currTime;
    }

    Checksum64 getChecksum(AbsolutePath p) @trusted nothrow {
        try {
            return checkSum_.require(p, checksum!makeChecksum64(p));
        } catch (Exception e) {
            logger.trace(e.msg).collectException;
        }
        return Checksum64.init;
    }

    void drop(AbsolutePath p) @safe nothrow {
        cache_.remove(p);
        timeStamp_.remove(p);
        checkSum_.remove(p);
    }
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

bool isSame(const TrackFile tf, const AbsolutePath p, ref FileStatCache fcache) {
    import std.math : abs;

    if ((tf.timeStamp - fcache.getTimeStamp(p)).total!"msecs".abs < 20) {
        debug logger.trace("timestamp unchanged ", p);
        return true;
    }

    if (tf.checksum == fcache.getChecksum(p)) {
        debug logger.trace("checksum unchanged ", p);
        return true;
    }

    return false;
}
