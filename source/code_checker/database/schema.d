/**
Copyright: Copyright (c) 2021, Joakim Brännström. All rights reserved.
License: MPL-2
Author: Joakim Brännström (joakim.brannstrom@gmx.com)

This Source Code Form is subject to the terms of the Mozilla Public License,
v.2.0. If a copy of the MPL was not distributed with this file, You can obtain
one at http://mozilla.org/MPL/2.0/.

Code copied from dextool
*/
module code_checker.database.schema;

import logger = std.experimental.logger;
import std.array : array, empty;
import std.datetime : SysTime, dur, Clock;
import std.exception : collectException;
import std.format : format;

import d2sqlite3 : SqlDatabase = Database;
import miniorm : Miniorm, TableName, buildSchema, ColumnParam, TableForeignKey, TableConstraint,
    TablePrimaryKey, KeyRef, KeyParam, ColumnName, delete_, insert, select, spinSql;
import my.path : AbsolutePath;

/** Initialize or open an existing database.
 *
 * Params:
 *  p = path where to initialize a new database or open an existing
 *
 * Returns: an open sqlite3 database object.
 */
Miniorm initializeDB(AbsolutePath p) @trusted
in {
    assert(p.length != 0);
}
do {
    import std.file : exists;
    import my.file : followSymlink;
    import my.optional;
    import my.path : Path;
    import d2sqlite3 : SQLITE_OPEN_CREATE, SQLITE_OPEN_READWRITE;

    static void setPragmas(ref SqlDatabase db) {
        // dfmt off
        auto pragmas = [
            // required for foreign keys with cascade to work
            "PRAGMA foreign_keys=ON;",
        ];
        // dfmt on

        foreach (p; pragmas) {
            db.run(p);
        }
    }

    const isOldDb = exists(followSymlink(Path(p)).orElse(Path(p)).toString);
    SqlDatabase sqliteDb;
    scope (success)
        setPragmas(sqliteDb);

    logger.trace("Opening database ", p);
    try {
        sqliteDb = SqlDatabase(p, SQLITE_OPEN_READWRITE);
    } catch (Exception e) {
        logger.trace(e.msg);
        logger.trace("Initializing a new sqlite3 database");
        sqliteDb = SqlDatabase(p, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE);
    }

    auto db = Miniorm(sqliteDb);

    auto tbl = makeUpgradeTable;
    const longTimeout = 10.dur!"minutes";
    try {
        if (isOldDb
                && spinSql!(() => getSchemaVersion(db))(10.dur!"seconds") >= tbl
                .latestSchemaVersion)
            return db;
    } catch (Exception e) {
        logger.info("The database is probably locked. Will keep trying to open for ", longTimeout);
    }
    if (isOldDb && spinSql!(() => getSchemaVersion(db))(longTimeout) >= tbl.latestSchemaVersion)
        return db;

    // TODO: remove all key off in upgrade schemas.
    const giveUpAfter = Clock.currTime + longTimeout;
    bool failed = true;
    while (failed && Clock.currTime < giveUpAfter) {
        try {
            auto trans = db.transaction;
            db.run("PRAGMA foreign_keys=OFF;");
            upgrade(db, tbl);
            trans.commit;
            failed = false;
        } catch (Exception e) {
            logger.trace(e.msg);
        }
    }

    if (failed) {
        logger.error("Unable to upgrade the database to the latest schema");
        throw new Exception(null);
    }

    return db;
}

struct UpgradeTable {
    alias UpgradeFunc = void function(ref Miniorm db);
    UpgradeFunc[long] tbl;
    alias tbl this;

    immutable long latestSchemaVersion;
}

/** Inspects a module for functions starting with upgradeV to create a table of
 * functions that can be used to upgrade a database.
 */
UpgradeTable makeUpgradeTable() {
    import std.algorithm : sort, startsWith;
    import std.conv : to;
    import std.typecons : Tuple;

    immutable prefix = "upgradeV";

    alias Module = code_checker.database.schema;

    // the second parameter is the database version to upgrade FROM.
    alias UpgradeFx = Tuple!(UpgradeTable.UpgradeFunc, long);

    UpgradeFx[] upgradeFx;
    long last_from;

    static foreach (member; __traits(allMembers, Module)) {
        static if (member.startsWith(prefix))
            upgradeFx ~= UpgradeFx(&__traits(getMember, Module, member),
                    member[prefix.length .. $].to!long);
    }

    typeof(UpgradeTable.tbl) tbl;
    foreach (fn; upgradeFx.sort!((a, b) => a[1] < b[1])) {
        last_from = fn[1];
        tbl[last_from] = fn[0];
    }

    return UpgradeTable(tbl, last_from + 1);
}

void updateSchemaVersion(ref Miniorm db, long ver) nothrow {
    try {
        db.run(delete_!VersionTbl);
        db.run(insert!VersionTbl.insert, VersionTbl(ver));
    } catch (Exception e) {
        logger.error(e.msg).collectException;
    }
}

long getSchemaVersion(ref Miniorm db) {
    auto v = db.run(select!VersionTbl);
    return v.empty ? 0 : v.front.version_;
}

void upgrade(ref Miniorm db, UpgradeTable tbl) {
    import d2sqlite3;

    immutable maxIndex = 30;

    alias upgradeFunc = void function(ref Miniorm db);

    bool hasUpdated;

    bool running = true;
    while (running) {
        const version_ = () {
            // first time the version table do not exist thus fail.
            try {
                return getSchemaVersion(db);
            } catch (Exception e) {
            }
            return 0;
        }();

        if (version_ >= tbl.latestSchemaVersion) {
            running = false;
            break;
        }

        logger.infof("Upgrading database from %s", version_).collectException;

        if (!hasUpdated)
            try {
                // only do this once and always before any changes to the database.
                foreach (i; 0 .. maxIndex) {
                    db.run(format!"DROP INDEX IF EXISTS i%s"(i));
                }
            } catch (Exception e) {
                logger.warning(e.msg).collectException;
                logger.warning("Unable to drop database indexes").collectException;
            }

        if (auto f = version_ in tbl) {
            try {
                hasUpdated = true;

                (*f)(db);
                if (version_ != 0)
                    updateSchemaVersion(db, version_ + 1);
            } catch (Exception e) {
                logger.trace(e).collectException;
                logger.error(e.msg).collectException;
                logger.warningf("Unable to upgrade a database of version %s",
                        version_).collectException;
                logger.warning("This might impact the functionality. It is unwise to continue")
                    .collectException;
                throw e;
            }
        } else {
            logger.info("Upgrade successful").collectException;
            running = false;
        }
    }
}

immutable schemaVersionTable = "schema_version";
@TableName(schemaVersionTable)
struct VersionTbl {
    @ColumnName("version")
    long version_;
}

immutable filesTable = "files";
@TableName(filesTable)
@TableConstraint("unique_ UNIQUE (path)")
struct FilesTbl {
    long id;
    string path;
    long checksum;

    /// True if the file is a root.
    bool root;
}

immutable depFileTable = "dependency_file";
/** Files that roots are dependent on. They do not need to contain mutants.
 */
@TableName(depFileTable)
@TableConstraint("unique_ UNIQUE (file)")
struct DependencyFileTable {
    long id;
    string file;
    long checksum;
}

immutable depRootTable = "rel_dependency_root";
@TableName(depRootTable)
@TableForeignKey("dep_id", KeyRef("dependency_file(id)"), KeyParam("ON DELETE CASCADE"))
@TableForeignKey("file_id", KeyRef("files(id)"), KeyParam("ON DELETE CASCADE"))
@TableConstraint("unique_ UNIQUE (dep_id, file_id)")
struct DependencyRootTable {
    @ColumnName("dep_id")
    long depFileId;

    @ColumnName("file_id")
    long fileId;
}

/** If the database start it version 0, not initialized, then initialize to the
 * latest schema version.
 */
void upgradeV0(ref Miniorm db) {
    auto tbl = makeUpgradeTable;

    db.run(buildSchema!(VersionTbl, FilesTbl, DependencyFileTable, DependencyRootTable));
    updateSchemaVersion(db, tbl.latestSchemaVersion);
}