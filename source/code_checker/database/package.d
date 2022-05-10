/**
Copyright: Copyright (c) 2021, Joakim Brännström. All rights reserved.
License: MPL-2
Author: Joakim Brännström (joakim.brannstrom@gmx.com)

This Source Code Form is subject to the terms of the Mozilla Public License,
v.2.0. If a copy of the MPL was not distributed with this file, You can obtain
one at http://mozilla.org/MPL/2.0/.

Code copied from dextool
*/
module code_checker.database;

import logger = std.experimental.logger;
import std.algorithm : map, joiner, filter;
import std.array : appender, array, empty;
import std.datetime : SysTime, Duration;
import std.exception : collectException;
import std.format : format;
import std.typecons : Nullable, Flag, No;

import miniorm : Miniorm, select, insert, insertOrReplace, delete_,
    insertOrIgnore, toSqliteDateTime, fromSqLiteDateTime, Bind;
import my.hash : Checksum64;
import my.named_type;
import my.optional;
import my.path;
import my.profile;

import code_checker.database.schema;

/** Database wrapper with minimal dependencies.
 */
struct Database {
    package Miniorm db;

    /** Create a database by either opening an existing or initializing a new.
     *
     * Params:
     *  db = path to the database
     */
    static auto make(AbsolutePath db) @safe {
        return Database(initializeDB(db));
    }

    auto transaction() @trusted {
        return db.transaction;
    }

    DbDependency dependencyApi() return @safe {
        return typeof(return)(&db, &this);
    }

    DbFile fileApi() return @safe {
        return typeof(return)(&db, &this);
    }

    DbCompileDbTrack compileDbTrackApi() return @safe {
        return typeof(return)(&db, &this);
    }
}

struct DbFile {
    private Miniorm* db;
    private Database* wrapperDb;

    void put(const Path p, Checksum64 cs, SysTime lastModified) @trusted {
        static immutable sql = "INSERT OR REPLACE INTO " ~ filesTable
            ~ " (path, checksum, root, time_stamp) VALUES (:path, :checksum, 1, :ts)";
        auto stmt = db.prepare(sql);
        stmt.get.bind(":path", p.toString);
        stmt.get.bind(":checksum", cast(long) cs.c0);
        stmt.get.bind(":ts", lastModified.toSqliteDateTime);
        stmt.get.execute;
    }

    /// Returns: the file path that the id correspond to.
    Nullable!TrackFile getFile(const FileId id) @trusted {
        static immutable sql = format(
                "SELECT path,checksum,time_stamp FROM %s WHERE id = :id", filesTable);
        auto stmt = db.prepare(sql);
        stmt.get.bind(":id", id.get);

        typeof(return) rval;
        foreach (ref r; stmt.get.execute)
            rval = TrackFile(Path(r.peek!string(0)),
                    Checksum64(r.peek!long(1)), r.peek!string(2).fromSqLiteDateTime);
        return rval;
    }

    Nullable!TrackFile getFile(const Path path) @trusted {
        static immutable sql = format(
                "SELECT path,checksum,time_stamp FROM %s WHERE path=:path", filesTable);
        auto stmt = db.prepare(sql);
        stmt.get.bind(":path", path);

        typeof(return) rval;
        foreach (ref r; stmt.get.execute)
            rval = TrackFile(Path(r.peek!string(0)),
                    Checksum64(r.peek!long(1)), r.peek!string(2).fromSqLiteDateTime);
        return rval;
    }

    Nullable!FileId getFileId(const Path p) @trusted {
        static immutable sql = format("SELECT id FROM %s WHERE path=:path", filesTable);
        auto stmt = db.prepare(sql);
        stmt.get.bind(":path", p.toString);
        auto res = stmt.get.execute;

        typeof(return) rval;
        if (!res.empty)
            rval = FileId(res.oneValue!long);
        return rval;
    }

    /// Remove the file with all mutations that are coupled to it.
    void removeFile(const Path p) @trusted {
        auto stmt = db.prepare(format!"DELETE FROM %s WHERE path=:path"(filesTable));
        stmt.get.bind(":path", p.toString);
        stmt.get.execute;
    }

    /// Returns: all files tagged as a root.
    FileId[] getRootFiles() @trusted {
        static immutable sql = "SELECT id FROM " ~ filesTable ~ " WHERE root=1";

        auto app = appender!(FileId[])();
        auto stmt = db.prepare(sql);
        foreach (ref r; stmt.get.execute) {
            app.put(r.peek!long(0).FileId);
        }
        return app.data;
    }

    /// Returns: All files in the database as relative paths.
    Path[] getFiles() @trusted {
        auto stmt = db.prepare(format!"SELECT path FROM %s"(filesTable));
        auto res = stmt.get.execute;

        auto app = appender!(Path[]);
        foreach (ref r; res) {
            app.put(Path(r.peek!string(0)));
        }

        return app.data;
    }

    Nullable!Checksum64 getFileChecksum(const Path p) @trusted {
        static immutable sql = "SELECT checksum FROM " ~ filesTable ~ " WHERE path=:path";
        auto stmt = db.prepare(sql);
        stmt.get.bind(":path", p.toString);
        auto res = stmt.get.execute;

        typeof(return) rval;
        if (!res.empty) {
            rval = Checksum64(res.front.peek!long(0));
        }

        return rval;
    }

    FileStatus getStatus(const Path p) @trusted {
        static immutable sql = "SELECT status FROM " ~ filesStatusTable
            ~ " t0, " ~ filesTable ~ " t1 WHERE t1.path=:path AND t1.id=t0.files_id";
        auto stmt = db.prepare(sql);
        stmt.get.bind(":path", p.toString);

        auto res = stmt.get.execute;
        if (res.empty)
            return FileStatus.normal;
        return res.front.peek!FileStatus(0);
    }

    void setStatus(const Path p, const FileStatus status) @trusted {
        static immutable sql = "INSERT OR REPLACE INTO " ~ filesStatusTable
            ~ " (files_id,status) SELECT t0.id,:status FROM " ~ filesTable
            ~ " t0 WHERE t0.path=:path";
        auto stmt = db.prepare(sql);
        stmt.get.bind(":path", p);
        stmt.get.bind(":status", cast(long) status);
        stmt.get.execute;
    }
}

/** Dependencies between root and those files that should trigger a re-analyze
 * of the root if they are changed.
 */
struct DbDependency {
    private Miniorm* db;
    private Database* wrapperDb;

    /** Write new dependencies to the database, those that do not exist in written.
     *
     * Returns: a list of the dependencies as IDs
     */
    DepFileId[] put(const DepFile[] deps, ref DepFileId[Path] written) {
        auto p = profileAdd(__FUNCTION__);

        static immutable insertDepSql = "INSERT OR REPLACE INTO "
            ~ depFileTable ~ " (file,checksum,time_stamp) VALUES(:file,:cs,:ts)";

        auto stmt = db.prepare(insertDepSql);
        auto ids = appender!(DepFileId[])();
        foreach (a; deps) {
            if (auto v = a.file in written) {
                ids.put(*v);
            } else {
                stmt.get.bind(":file", a.file.toString);
                stmt.get.bind(":cs", cast(long) a.checksum.c0);
                stmt.get.bind(":ts", a.timeStamp.toSqliteDateTime);
                stmt.get.execute;
                stmt.get.reset;

                // can't use lastInsertRowid because a conflict would not update
                // the ID.
                auto id = getId(a.file);
                if (id.hasValue) {
                    ids.put(id.orElse(0L).DepFileId);
                    written[a.file] = DepFileId(id.orElse(0L));
                }
            }
        }

        return ids.data;
    }

    /// The root must already exist or the whole operation will fail with an sql error.
    void set(const Path path, const DepFileId[] deps) @trusted {
        const fid = () {
            auto a = wrapperDb.fileApi.getFileId(path);
            if (a.isNull) {
                throw new Exception(
                        "File is not tracked (is missing from the files table in the database) "
                        ~ path);
            }
            return a.get;
        }();

        // start by clearing out all dependencies for the file
        {
            auto p = profileAdd(__FUNCTION__ ~ ".drop");
            auto stmt = db.prepare(format!"DELETE FROM %s WHERE file_id=:fid"(depRootTable));
            stmt.get.bind(":fid", fid.get);
            stmt.get.execute;
        }

        static immutable addRelSql = "INSERT OR IGNORE INTO " ~ depRootTable
            ~ " (dep_id,file_id) VALUES(:did, :fid)";
        {
            auto stmt = db.prepare(addRelSql);
            auto p = profileAdd(__FUNCTION__ ~ ".insert");

            foreach (id; deps) {
                stmt.get.bind(":did", id.get);
                stmt.get.bind(":fid", fid.get);
                stmt.get.execute;
                stmt.get.reset;
            }
        }
    }

    private Optional!long getId(const Path file) {
        foreach (a; db.run(select!DependencyFileTable.where("file = :file",
                Bind("file")), file.toString)) {
            return some(a.id);
        }
        return none!long;
    }

    /// Returns: all dependencies.
    DepFile[] getAll() @trusted {
        return db.run(select!DependencyFileTable)
            .map!(a => DepFile(Path(a.file), Checksum64(a.checksum), a.timeStamp)).array;
    }

    /// Returns: all files that a root is dependent on.
    Path[] get(const Path root) @trusted {
        static immutable sql = format!"SELECT t0.file
            FROM %1$s t0, %2$s t1, %3$s t2
            WHERE
            t0.id = t1.dep_id AND
            t1.file_id = t2.id AND
            t2.path = :file"(depFileTable,
                depRootTable, filesTable);

        auto stmt = db.prepare(sql);
        stmt.get.bind(":file", root.toString);
        auto app = appender!(Path[])();
        foreach (ref a; stmt.get.execute) {
            app.put(Path(a.peek!string(0)));
        }

        return app.data;
    }

    /// Remove all dependencies that have no relation to a root.
    void cleanup() @trusted {
        db.run(format!"DELETE FROM %1$s
               WHERE id NOT IN (SELECT dep_id FROM %2$s)"(depFileTable,
                depRootTable));
    }
}

/// A file that a root is dependent on.
struct DepFile {
    Path file;
    Checksum64 checksum;
    SysTime timeStamp;
}

alias DepFileId = NamedType!(long, Tag!"DepFileId", long.init, TagStringable, Comparable);

TrackFile toTrackFile(DepFile a) {
    return TrackFile(a.file, a.checksum, a.timeStamp);
}

/// Primary key in the files table
alias FileId = NamedType!(long, Tag!"FileId", long.init, Comparable, Hashable, TagStringable);

struct TrackFile {
    Path file;
    Checksum64 checksum;
    SysTime timeStamp;
}

struct DbCompileDbTrack {
    private Miniorm* db;
    private Database* wrapperDb;

    void put(TrackFile f) {
        static immutable sql = "INSERT OR REPLACE INTO " ~ compileDbTrack
            ~ " (path,time_stamp,checksum) VALUES(:path,:ts,:cs)";

        auto stmt = db.prepare(sql);
        stmt.get.bind(":path", f.file.toString);
        stmt.get.bind(":ts", f.timeStamp.toSqliteDateTime);
        stmt.get.bind(":cs", cast(long) f.checksum.c0);
        stmt.get.execute;
    }

    TrackFile get(const Path path) {
        static immutable sql = "SELECT time_stamp,checksum FROM "
            ~ compileDbTrack ~ " WHERE path=:path";
        auto stmt = db.prepare(sql);
        stmt.get.bind(":path", path);
        auto rval = TrackFile(path);
        foreach (ref a; stmt.get.execute) {
            rval.timeStamp = a.peek!string(0).fromSqLiteDateTime.toLocalTime;
            rval.checksum = a.peek!long(1).Checksum64;
        }
        return rval;
    }

    /// Remove old entries to avoid infinite growth of the database.
    void cleanup(const Duration dropAfter) {
        import std.datetime : Clock, dur;

        static immutable sql = "DELETE FROM " ~ compileDbTrack
            ~ " WHERE datetime(time_stamp) < datetime(:older_then)";

        auto stmt = db.prepare(sql);
        // two is a magic number that I think is ok. Over two days not that
        // many files should have been added/removed that the database grow to
        // Gbyte in size.
        stmt.get.bind(":older_then", (Clock.currTime - dropAfter).toSqliteDateTime);
        stmt.get.execute;
    }
}
