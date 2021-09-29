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

import code_checker.database : Database, toTrackFile;
import code_checker.utility : toAbsoluteRoot;
import code_checker.cache;

/** Returns: the root files that need to be re-analyzed because either them or
 * their dependency has changed.
 */
bool[AbsolutePath] dependencyAnalyze(ref Database db, AbsolutePath rootDir, ref FileStatCache fcache) @trusted {
    import std.algorithm : map, cache, filter;
    import std.datetime : dur;
    import std.path : buildPath;
    import std.typecons : tuple;
    import std.math : abs;
    import std.conv : to;
    import miniorm : spinSql;
    import code_checker.database : FileId, TrackFile, DepFile;
    import my.hash : Checksum64;

    typeof(return) rval;

    // pessimistic. Add all as needing to be analyzed.
    foreach (a; spinSql!(() => db.fileApi.getRootFiles).map!(
            a => spinSql!(() => db.fileApi.getFile(a)).get)) {
        auto p = buildPath(rootDir, a.file).AbsolutePath;
        rval[p] = false;
    }

    try {
        auto getTrackFile = (Path p) => spinSql!(() => db.fileApi.getFile(p));

        TrackFile[Path] dbDeps;
        foreach (a; spinSql!(() => db.dependencyApi.getAll))
            dbDeps[a.file] = a.toTrackFile;

        bool isChanged(T)(T f) nothrow {
            try {
                if (!isSame(f.root, f.root.file.AbsolutePath, fcache))
                    return true;

                foreach (a; f.deps.filter!(a => !isSame(dbDeps[a],
                        toAbsoluteRoot(rootDir, a), fcache))) {
                    logger.tracef("%s dependency changed -> %s", f.root.file,
                            toAbsoluteRoot(rootDir, a));
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

    debug logger.trace("Dependency analyze: ", rval);

    return rval;
}

/// Convert to an absolute path by finding the first match among the compiler flags
Optional!AbsolutePath toAbsolutePath(Path file, AbsolutePath parentDir,
        AbsolutePath workDir, ParseFlags.Include[] includes, SystemIncludePath[] systemIncludes) @trusted nothrow {
    import std.algorithm : map, filter;
    import std.file : exists, isDir;
    import std.path : buildPath;

    Optional!AbsolutePath lookup(string dir) nothrow {
        const p = buildPath(dir, file);
        try {
            if (exists(p) && !isDir(p))
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
