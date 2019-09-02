/**
Copyright: Copyright (c) 2017, Joakim Brännström. All rights reserved.
License: MPL-2
Author: Joakim Brännström (joakim.brannstrom@gmx.com)

This Source Code Form is subject to the terms of the Mozilla Public License,
v.2.0. If a copy of the MPL was not distributed with this file, You can obtain
one at http://mozilla.org/MPL/2.0/.

This is a handy range to interate over either all files from the user OR all
files in a compilation database.
*/
module code_checker.compile_db.user_filerange;

import logger = std.experimental.logger;

import code_checker.compile_db : CompileCommandFilter, CompileCommandDB,
    parseFlag, SearchResult, DbCompiler = Compiler, ParseFlags;
import code_checker.types : FileName, AbsolutePath;

@safe:

struct UserFileRange {
    import std.typecons : Nullable;
    import code_checker.compile_db : SearchResult;

    enum RangeOver {
        inFiles,
        database
    }

    this(CompileCommandDB db, string[] in_files, string[] cflags,
            const CompileCommandFilter ccFilter, const DbCompiler userCompiler) {
        this.db = db;
        this.cflags = cflags;
        this.ccFilter = ccFilter;
        this.inFiles = in_files;
        this.userCompiler = userCompiler;

        if (in_files.length == 0) {
            kind = RangeOver.database;
        } else {
            kind = RangeOver.inFiles;
        }
    }

    const RangeOver kind;
    CompileCommandDB db;
    string[] inFiles;
    string[] cflags;
    const CompileCommandFilter ccFilter;
    const DbCompiler userCompiler;

    Nullable!SearchResult front() {
        assert(!empty, "Can't get front of an empty range");

        Nullable!SearchResult curr;

        final switch (kind) {
        case RangeOver.inFiles:
            if (db.length > 0) {
                curr = findFlags(db, FileName(inFiles[0]), cflags, ccFilter, userCompiler);
            } else {
                curr = SearchResult(ParseFlags(null, cflags), AbsolutePath(FileName(inFiles[0])));
            }
            break;
        case RangeOver.database:
            import std.array : appender;

            auto tmp = db.payload[0];
            auto flags = parseFlag(db.payload[0], ccFilter, userCompiler);
            flags.cflags ~= cflags;
            curr = SearchResult(flags, tmp.absoluteFile);
            break;
        }

        return curr;
    }

    void popFront() {
        assert(!empty, "Can't pop front of an empty range");

        final switch (kind) {
        case RangeOver.inFiles:
            inFiles = inFiles[1 .. $];
            break;
        case RangeOver.database:
            db.payload = db.payload[1 .. $];
            break;
        }
    }

    bool empty() @safe pure nothrow const @nogc {
        final switch (kind) {
        case RangeOver.inFiles:
            return inFiles.length == 0;
        case RangeOver.database:
            return db.length == 0;
        }
    }

    size_t length() @safe pure nothrow const @nogc {
        final switch (kind) {
        case RangeOver.inFiles:
            return inFiles.length;
        case RangeOver.database:
            return db.length;
        }
    }
}

private:

import std.typecons : Nullable;

/// Find flags for fname by searching in the compilation DB.
Nullable!SearchResult findFlags(ref CompileCommandDB compdb, FileName fname,
        const string[] flags, ref const CompileCommandFilter flag_filter, DbCompiler userCompiler) {
    import std.file : exists;
    import std.path : baseName;
    import std.string : join;
    import code_checker.compile_db : appendOrError;

    typeof(return) rval;

    auto db_search_result = compdb.appendOrError(flags, fname, flag_filter, userCompiler);
    if (db_search_result.isNull) {
        logger.error("Unable to find any compiler flags for: ", fname);
    } else {
        rval = SearchResult(db_search_result.get.flags, db_search_result.get.absoluteFile);
    }

    return rval;
}
