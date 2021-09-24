/**
Copyright: Copyright (c) 2021, Joakim Brännström. All rights reserved.
License: MPL-2
Author: Joakim Brännström (joakim.brannstrom@gmx.com)

This Source Code Form is subject to the terms of the Mozilla Public License,
v.2.0. If a copy of the MPL was not distributed with this file, You can obtain
one at http://mozilla.org/MPL/2.0/.

Copied from dextool.

Algorithm for detecting what files need to be analyzed based on previous state.
*/
module code_checker.change;

import logger = std.experimental.logger;
import std.exception : collectException;

import my.path;
import my.optional;
import compile_db;

import code_checker.database : Database;
import code_checker.utility : toAbsoluteRoot;

/** Returns: the root files that need to be re-analyzed because either them or
 * their dependency has changed.
 */
bool[AbsolutePath] dependencyAnalyze(ref Database db, AbsolutePath rootDir) @trusted {
    import std.algorithm : map, cache, filter;
    import std.datetime : dur;
    import std.file : timeLastModified;
    import std.path : buildPath;
    import std.typecons : tuple;
    import std.math : abs;
    import std.conv : to;
    import miniorm : spinSql;
    import my.hash : checksum, makeChecksum64, Checksum64;
    import code_checker.database : FileId, TrackFile;

    typeof(return) rval;

    // pessimistic. Add all as needing to be analyzed.
    foreach (a; spinSql!(() => db.fileApi.getRootFiles).map!(
            a => spinSql!(() => db.fileApi.getFile(a)).get)) {
        auto p = buildPath(rootDir, a.file).AbsolutePath;
        rval[p] = false;
    }

    try {
        auto getTrackFile = (Path p) => spinSql!(() => db.fileApi.getFile(p));
        auto getFileFsChecksum = (AbsolutePath p) {
            return checksum!makeChecksum64(p);
        };

        Checksum64[Path] dbDeps;
        foreach (a; spinSql!(() => db.dependencyApi.getAll))
            dbDeps[a.file] = a.checksum;

        bool isChanged(T)(T f) nothrow {
            try {
                /* TODO: temporary inactivate because of clock drift problem etc.
                 * Activate when clock diff is added.
                if ((f.root.timeStamp - timeLastModified(f.root.file)).total!"seconds".abs > 1) {
                    debug logger.trace("timestamp changed ", f.root.file);
                    return true;
                }
                 */

                if (f.root.checksum != getFileFsChecksum(toAbsoluteRoot(rootDir, f.root.file))) {
                    debug logger.trace("checksum changed of root", f.root.file);
                    return true;
                }

                foreach (a; f.deps.filter!(a => getFileFsChecksum(toAbsoluteRoot(rootDir,
                        a)) != dbDeps[a])) {
                    debug logger.tracef("checksum changed of dependency %s for %s", a, f.root.file);
                    return true;
                }

                return false;
            } catch (Exception e) {
                logger.trace(e.msg).collectException;
            }
            return true;
        }

        foreach (f; spinSql!(() => db.fileApi).getRootFiles
                .map!(a => spinSql!(() => db.fileApi.getFile(a)).get)
                .map!(a => tuple!("root", "deps")(a, spinSql!(() => db.dependencyApi.get(a.file))))
                .cache
                .filter!(a => isChanged(a))
                .map!(a => a.root.file)) {
            rval[buildPath(rootDir, f).AbsolutePath] = true;
        }
    } catch (Exception e) {
        logger.warning(e.msg);
    }

    logger.trace("Dependency analyze: ", rval);

    return rval;
}

/// Convert to an absolute path by finding the first match among the compiler flags
Optional!AbsolutePath toAbsolutePath(Path file, AbsolutePath parentDir,
        AbsolutePath workDir, ParseFlags.Include[] includes, SystemIncludePath[] systemIncludes) @trusted nothrow {
    import std.algorithm : map, filter;
    import std.file : exists;
    import std.path : buildPath;

    Optional!AbsolutePath lookup(string dir) nothrow {
        const p = buildPath(dir, file);
        try {
            if (exists(p))
                return some(AbsolutePath(p));
        } catch (Exception e) {
        }
        return none!AbsolutePath;
    }

    {
        auto a = lookup(parentDir.toString);
        if (a.hasValue)
            return a;
    }

    {
        auto a = lookup(workDir.toString);
        if (a.hasValue)
            return a;
    }

    foreach (a; includes.map!(a => lookup(a.payload))
            .filter!(a => a.hasValue)) {
        return a;
    }

    foreach (a; systemIncludes.map!(a => lookup(a.value))
            .filter!(a => a.hasValue)) {
        return a;
    }

    return none!AbsolutePath;
}
