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

import my.path;
import my.optional;
import compile_db;

import code_checker.database : Database;
import code_checker.utility : toAbsoluteRoot;

/** Returns: the root files that need to be re-analyzed because either them or
 * their dependency has changed.
 */
bool[Path] dependencyAnalyze(ref Database db, AbsolutePath rootDir) @trusted {
    import std.algorithm : map, cache, filter;
    import std.typecons : tuple;
    import std.path : buildPath;
    import my.hash : checksum, makeChecksum64, Checksum64;
    import code_checker.database : FileId;

    typeof(return) rval;

    // pessimistic. Add all as needing to be analyzed.
    foreach (a; db.fileApi.getRootFiles.map!(a => db.fileApi.getFile(a).get)) {
        rval[a] = false;
    }

    try {
        auto getFileId = (string p) => db.fileApi.getFileId(p.Path);
        auto getFileName = (FileId id) => db.fileApi.getFile(id);
        auto getFileDbChecksum = (string p) => db.fileApi.getFileChecksum(p.Path);
        auto getFileFsChecksum = (AbsolutePath p) {
            return checksum!makeChecksum64(p);
        };

        Checksum64[Path] dbDeps;
        foreach (a; db.dependencyApi.getAll)
            dbDeps[a.file] = a.checksum;

        bool isChanged(T)(T f) {
            if (f.rootCs != getFileFsChecksum(toAbsoluteRoot(rootDir, f.root)))
                return true;

            foreach (a; f.deps.filter!(a => getFileFsChecksum(toAbsoluteRoot(rootDir,
                    a)) != dbDeps[a])) {
                return true;
            }

            return false;
        }

        foreach (f; db.fileApi
                .getRootFiles
                .map!(a => db.fileApi.getFile(a).get)
                .map!(a => tuple!("root", "rootCs", "deps")(a,
                    getFileDbChecksum(a), db.dependencyApi.get(a)))
                .cache
                .filter!(a => isChanged(a))
                .map!(a => a.root)) {
            rval[f] = true;
        }
    } catch (Exception e) {
        logger.warning(e.msg);
    }

    logger.trace("Dependency analyze: ", rval);

    return rval;
}

/// Convert to an absolute path by finding the first match among the compiler flags
Optional!AbsolutePath toAbsolutePath(Path file, AbsolutePath workDir,
        ParseFlags.Include[] includes, SystemIncludePath[] systemIncludes) @trusted nothrow {
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