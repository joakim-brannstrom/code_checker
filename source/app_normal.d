/**
Copyright: Copyright (c) 2018, Joakim Brännström. All rights reserved.
License: $(LINK2 http://www.boost.org/LICENSE_1_0.txt, Boost Software License 1.0)
Author: Joakim Brännström (joakim.brannstrom@gmx.com)

Normal appliation mode.
*/
module app_normal;

import logger = std.experimental.logger;
import std.algorithm : among, map, filter, copy;
import std.array : empty, appender, array;
import std.exception : collectException;

import miniorm : spinSql;
import my.path;
import my.profile;
import my.set;

import compile_db : CompileCommandDB, toCompileCommandDB, DbCompiler = Compiler,
    CompileCommandFilter, defaultCompilerFilter, ParsedCompileCommand;

import code_checker.cli : Config, Progress;
import code_checker.database : Database, TrackFile;
import code_checker.engine : Environment;
import code_checker.cache : FileStatCache, getTrackFile, isSame;

version (unittest) {
    import unit_threaded : shouldEqual, shouldBeTrue, UnitTestException;
}

immutable compileCommandsFile = "compile_commands.json";

int modeNormal(Config conf) {
    auto fsm = NormalFSM(conf);
    return fsm.run;
}

private:

/** FSM for the control flow when in normal mode.
 */
struct NormalFSM {
    enum State {
        init_,
        openDb,
        /// change the working directory of the whole program
        changeWorkDir,
        /// check if a DB exists at the workdir location. Affects cleanup.
        checkForDb,
        /// if a command is registered to generate a DB run it
        genDb,
        /// check if the generation of a DB went OK
        checkGenDb,
        /// cleanup the database
        fixDb,
        /// check that it went OK to perform the cleanup
        checkFixDb,
        runRegistry,
        cleanup,
        done,
    }

    struct StateData {
        int exitStatus;
        bool hasGenerateDbCommand;
        bool hasCompileDbs;
    }

    State st;
    Config conf;
    CompileCommandDB compileDb;

    /// If the compile_commands.json that is written to the file system should be deleted when code_checker is done.
    bool removeCompileDb;

    /// Root directory from which the program where initially started.
    AbsolutePath root;

    /// Exit status of used to indicate the success to the user.
    int exitStatus;

    Database db;

    FileStatCache fcache;

    this(Config conf) {
        this.conf = conf;
    }

    int run() {
        StateData d;
        d.hasGenerateDbCommand = conf.compileDb.generateDb.length != 0;
        d.hasCompileDbs = conf.compileDb.dbs.length != 0;

        while (st != State.done) {
            debug logger.tracef("state: %s data: %s", st, d);

            st = next(st, d);
            action(st);

            // sync with changed struct members as needed
            d.exitStatus = exitStatus;
        }

        return d.exitStatus;
    }

    /** The next state is calculated. Only dependent on current state and state data.
     *
     * These clean depenencies should make it easier to reason about the flow.
     */
    static State next(const State curr, const StateData d) {
        State next_ = curr;

        final switch (curr) {
        case State.init_:
            next_ = State.openDb;
            break;
        case State.openDb:
            next_ = State.changeWorkDir;
            break;
        case State.changeWorkDir:
            next_ = State.checkForDb;
            break;
        case State.checkForDb:
            next_ = State.fixDb;
            if (d.hasGenerateDbCommand)
                next_ = State.genDb;
            break;
        case State.genDb:
            next_ = State.checkGenDb;
            break;
        case State.checkGenDb:
            next_ = State.fixDb;
            if (d.exitStatus != 0)
                next_ = State.cleanup;
            break;
        case State.fixDb:
            next_ = State.checkFixDb;
            break;
        case State.checkFixDb:
            next_ = State.runRegistry;
            if (d.exitStatus != 0)
                next_ = State.cleanup;
            break;
        case State.runRegistry:
            next_ = State.cleanup;
            break;
        case State.cleanup:
            next_ = State.done;
            break;
        case State.done:
            break;
        }

        return next_;
    }

    void act_openDb() {
        import std.datetime : dur;
        import code_checker.database;

        try {
            db = Database.make(conf.database);
        } catch (Exception e) {
            logger.warning(e.msg);
        }

        try {
            db.compileDbTrackApi.cleanup(2.dur!"weeks");
        } catch (Exception e) {
        }
    }

    void act_changeWorkDir() {
        import std.file : getcwd, chdir;

        root = Path(getcwd).AbsolutePath;
        if (conf.workDir != root)
            chdir(conf.workDir);
    }

    void act_genDb() {
        import std.file : exists;
        import std.process : spawnShell, wait;

        auto profile = profileSet(__FUNCTION__);

        bool isUnchanged() nothrow {
            try {
                if (!exists(compileCommandsFile))
                    return false;
                if (conf.compileDb.generateDbDeps.empty)
                    return true;
                return !isChanged(db,
                        conf.compileDb.generateDbDeps ~ AbsolutePath(compileCommandsFile), fcache);
            } catch (Exception e) {
                logger.trace(e.msg).collectException;
            }
            return false;
        }

        if (isUnchanged)
            return;

        auto res = spawnShell(conf.compileDb.generateDb).wait;
        fcache = typeof(fcache).init; // drop cache because the update cmd may have changed a dependency

        if (res == 0) {
            updateCompileDbTrack(db, conf.compileDb.generateDbDeps, fcache);
        } else {
            // the user need some helpful feedback for what failed
            logger.errorf("Failed running the command to generate %(%s, %)", conf.compileDb.dbs);
            logger.error("Executed the following commands:");
            logger.error("# if this directory is wrong use --workdir", root);
            logger.error("cd", root);
            logger.error(conf.compileDb.generateDb);
            exitStatus = 1;
        }
    }

    void act_fixDb() {
        import std.stdio : File;
        import std.file : exists;
        import compile_db : fromArgCompileDb;

        auto profile = profileSet(__FUNCTION__);

        compileDb = fromArgCompileDb(conf.compileDb.dbs.map!(a => cast(string) a.idup).array);

        bool isUnchanged() nothrow {
            try {
                if (!exists(compileCommandsFile))
                    return false;
                return !isChanged(db, conf.compileDb.dbs ~ AbsolutePath(compileCommandsFile),
                        fcache);
            } catch (Exception e) {
                logger.trace(e.msg).collectException;
            }
            return false;
        }

        if (isUnchanged)
            return;

        logger.trace("Creating a unified compile_commands.json");

        try {
            auto compile_db = appender!string();
            unifyCompileDb(compileDb, conf.compiler.useCompilerSystemIncludes,
                    conf.compileDb.flagFilter, compile_db);
            File(compileCommandsFile, "w").write(compile_db.data);

            fcache.drop(AbsolutePath(compileCommandsFile)); // do NOT use previously cached value
            updateCompileDbTrack(db, conf.compileDb.dbs ~ AbsolutePath(compileCommandsFile), fcache);
        } catch (Exception e) {
            logger.errorf("Unable to process %s", compileCommandsFile);
            logger.error(e.msg);
            exitStatus = 1;
        }
    }

    void act_runRegistry() {
        import code_checker.engine;
        import compile_db : fromArgCompileDb, parseFlag, CompileCommandFilter;
        import code_checker.change : dependencyAnalyze;
        import code_checker.engine.types : TotalResult;

        auto profile = profileSet(__FUNCTION__);

        auto changed = () {
            bool[AbsolutePath] rval;

            try {
                foreach (v; dependencyAnalyze(db, AbsolutePath("."), fcache).byKeyValue) {
                    rval[v.key.AbsolutePath] = v.value;
                }
            } catch (Exception e) {
            }
            return rval;
        }();

        Environment env;
        env.compileDbFile = AbsolutePath(Path(compileCommandsFile));
        env.compileDb = compileDb;
        env.files = () {
            if (!conf.analyzeFiles.empty)
                return conf.analyzeFiles.map!(a => cast(string) a).array;

            string[] rval;
            foreach (dbFile; env.compileDb) {
                if (auto v = dbFile.absoluteFile in changed) {
                    if (*v)
                        rval ~= dbFile.absoluteFile.toString;
                } else {
                    rval ~= dbFile.absoluteFile.toString;
                }
            }
            return rval;
        }();

        env.conf = conf;

        TotalResult tres;
        if (!env.files.empty) {
            auto reg = makeRegistry;
            tres = execute(env, conf.staticCode.analyzers, reg);
        }
        exitStatus = tres.status.among(Status.passed, Status.none) ? 0 : 1;

        spinSql!(() {
            auto trans = db.transaction;
            try {
                removeDroppedFiles(db, env, root);
                removeFailing(db, root, tres.failed);
            } catch (Exception e) {
                logger.trace(e.msg);
            }
            trans.commit;
        });

        if (!tres.success.empty) {
            logger.trace("Saving result for ", tres.success);
            spinSql!(() {
                auto trans = db.transaction;
                try {
                    saveDependencies(db, env, root, tres.success, fcache, conf.logg.progress);
                    db.dependencyApi.cleanup;
                } catch (Exception e) {
                    logger.trace(e.msg);
                }
                trans.commit;
            });
        }
    }

    void act_cleanup() {
        import std.file : chdir;

        chdir(root);
    }

    /// Generate a callback for each state.
    void action(const State st) {
        string genCallAction() {
            import std.format : format;
            import std.traits : EnumMembers;

            string s;
            s ~= "final switch(st) {";
            static foreach (a; EnumMembers!State) {
                {
                    const actfn = format("act_%s", a);
                    static if (__traits(hasMember, NormalFSM, actfn))
                        s ~= format("case State.%s: %s();break;", a, actfn);
                    else {
                        pragma(msg, __FILE__ ~ ": no callback found: " ~ actfn);
                        s ~= format("case State.%s: break;", a);
                    }
                }
            }
            s ~= "}";
            return s;
        }

        mixin(genCallAction);
    }
}

/// Unify multiple compilation databases to one json file.
void unifyCompileDb(AppT)(CompileCommandDB db, const DbCompiler user_compiler,
        CompileCommandFilter flag_filter, ref AppT app) {
    import std.ascii : newline;
    import std.format : formattedWrite;
    import std.path : stripExtension;
    import std.range : put;
    import compile_db;

    logger.trace(flag_filter);

    void writeEntry(T)(T e) {
        auto raw_flags = () @safe {
            import std.json : JSONValue;

            auto app = appender!(string[]);
            //auto pflags = e.parseFlag(flag_filter);
            app.put(e.flags.compiler);
            e.flags.completeFlags.copy(app);
            // add back dummy -c otherwise clang-tidy do not work.
            // clang-tidy says "Passed" on everything.
            ["-c", e.cmd.absoluteFile.toString].copy(app);
            // correctly quotes interior strings as JSON requires.
            return JSONValue(app.data).toString;
        }();

        formattedWrite(app, `"directory": "%s",`, cast(string) e.cmd.directory);
        formattedWrite(app, `"arguments": %s,`, raw_flags);

        if (!e.cmd.output.empty)
            formattedWrite(app, `"output": "%s",`, cast(string) e.cmd.absoluteOutput);
        formattedWrite(app, `"file": "%s"`, cast(string) e.cmd.absoluteFile);
    }

    logger.trace("database ", db);

    if (db.empty)
        return;
    auto entries = ParsedCompileCommandRange.make(db.fileRange.parse(flag_filter)
            .addCompiler(user_compiler).replaceCompiler(user_compiler).addSystemIncludes.array)
        .array;
    if (entries.empty)
        return;

    formattedWrite(app, "[");

    bool isFirst = true;
    foreach (e; entries) {
        logger.trace(e);

        if (isFirst) {
            isFirst = false;
        } else {
            put(app, ",");
            put(app, newline);
        }

        formattedWrite(app, "{");
        writeEntry(e);
        formattedWrite(app, "}");
    }

    formattedWrite(app, "]");
}

@(`shall quote compile_commands entries as JSON requires when the value is a string containing "`)
unittest {
    import std.algorithm : canFind;

    // arrange
    enum test_compile_db = `[
    {
        "directory": "dir1/dir2",
        "arguments": [ "cc", "-c", "-DFOO=\"bar\"" ],
        "file": "file1.cpp"
    }
]`;
    auto db = test_compile_db.toCompileCommandDB(Path("."));
    // act
    auto unified = appender!string();
    unifyCompileDb(db, DbCompiler.init,
            CompileCommandFilter(defaultCompilerFilter.filter.dup, 0), unified);
    // assert
    try {
        unified.data.canFind(`-DFOO=\"bar\"`).shouldBeTrue;
    } catch (UnitTestException e) {
        unified.data.shouldEqual("a trick to print the unified string when the test fail");
    }
}

Path toIncludePath(AbsolutePath f, AbsolutePath root) {
    import std.algorithm : startsWith;
    import std.path : relativePath, buildNormalizedPath;

    if (f.toString.startsWith(root.toString))
        return relativePath(f, root).Path;
    return f;
}

void saveDependencies(ref Database db, Environment env, AbsolutePath root,
        AbsolutePath[] successFiles, ref FileStatCache fcache, Set!Progress progress) {
    import std.algorithm : sort;
    import code_checker.engine.compile_db : toRange;
    import code_checker.database : DepFile, DepFileId;

    auto profile = profileSet(__FUNCTION__);

    const printProgress = Progress.saveDb in progress;

    if (printProgress) {
        logger.info("Saving dependencies to database");
    }

    auto success = toSet(successFiles);

    DepFileId[Path] written;
    DepScan dscan;

    size_t saved = 1;
    size_t total = success.length;
    foreach (pcmd; toRange(env).filter!(a => a.cmd.absoluteFile in success)) {
        auto path = toIncludePath(pcmd.cmd.absoluteFile, root);

        if (printProgress) {
            logger.infof("Saving %s/%s %s", saved, total, path);
            saved++;
        }

        db.fileApi.put(path, fcache.get(pcmd.cmd.absoluteFile).checksum,
                fcache.get(pcmd.cmd.absoluteFile).timeStamp);
        auto deps = dscan.get(pcmd, root).map!(a => DepFile(toIncludePath(a,
                root), fcache.get(a).checksum, fcache.get(a).timeStamp)).array;
        db.dependencyApi.set(path, db.dependencyApi.put(deps, written));
    }

    debug {
        foreach (a; dscan.cache.byKey.array.sort) {
            logger.tracef("deps for %s : %s", a, dscan.cache[a].sort);
        }
    }
}

struct DepScan {
    import std.stdio : File;
    import std.string : strip, startsWith, split;
    import my.optional;
    import my.container.vector;
    import code_checker.change : toAbsolutePath;

    AbsolutePath[][AbsolutePath] cache;

    AbsolutePath[] get(ParsedCompileCommand pcmd, AbsolutePath root) {
        if (auto v = pcmd.cmd.absoluteFile in cache)
            return *v;
        return depScan(pcmd, root, pcmd.cmd.absoluteFile);
    }

    AbsolutePath[] flatScan(ParsedCompileCommand pcmd, AbsolutePath root, AbsolutePath startFile) {
        Set!AbsolutePath found;

        try {
            foreach (d; File(startFile).byLine
                    .map!(a => a.strip)
                    .filter!(a => a.startsWith("#include"))
                    .map!(a => a.split)
                    .filter!(a => a.length >= 2)
                    .map!(a => a[1])
                    .filter!(a => a.length >= 3)
                    .map!(a => strip(a.idup)[1 .. $ - 1].Path)
                    .map!(a => toAbsolutePath(a, pcmd.cmd.absoluteFile.dirName.AbsolutePath,
                        pcmd.cmd.directory, pcmd.flags.includes, pcmd.flags.systemIncludes))
                    .filter!(a => a.hasValue)
                    .map!(a => a.orElse(AbsolutePath.init))) {
                found.add(d);
            }
        } catch (Exception e) {
            logger.trace(e.msg);
        }

        return found.toArray;
    }

    AbsolutePath[] depScan(ParsedCompileCommand pcmd, AbsolutePath root, AbsolutePath startFile) {
        if (auto v = startFile in cache)
            return *v;

        AbsolutePath[][AbsolutePath] scans;
        AbsolutePath[] merge(AbsolutePath p) {
            Set!AbsolutePath visited;
            Set!AbsolutePath rval;
            Vector!AbsolutePath que;
            que.put(p);
            while (!que.empty) {
                auto curr = que.back;
                que.popBack;

                if (curr in visited) {
                    continue;
                }

                if (auto v = curr in scans) {
                    que.put(*v);
                    rval.add(*v);
                }
                visited.add(curr);
            }

            return rval.toArray;
        }

        Set!AbsolutePath visited;
        Vector!AbsolutePath que;
        que.put(startFile);

        while (!que.empty) {
            auto curr = que.back;
            que.popBack;

            if (auto v = curr in cache) {
                scans[curr] = *v;
                visited.add(*v);
            } else {
                auto deps = flatScan(pcmd, root, curr);
                foreach (f; deps) {
                    if (f !in visited) {
                        que.put(f);
                        visited.add(f);
                    }
                }
                scans[curr] = deps;
            }
        }

        foreach (a; scans.byKey.array.filter!(a => a !in cache))
            cache[a] = merge(a);

        return cache[startFile];
    }
}

void removeDroppedFiles(ref Database db, Environment env, AbsolutePath root) {
    auto profile = profileSet(__FUNCTION__);

    auto current = env.compileDb.map!(a => a.absoluteFile.toIncludePath(root)).toSet;
    auto dbFiles = db.fileApi.getFiles.toSet;
    foreach (removed; dbFiles.setDifference(current).toRange) {
        db.fileApi.removeFile(removed);
    }
}

void removeFailing(ref Database db, AbsolutePath root, AbsolutePath[] failing) {
    import std.path : relativePath, buildNormalizedPath;

    foreach (a; failing) {
        db.fileApi.removeFile(relativePath(a, root).Path);
    }
}

bool isChanged(ref Database db, AbsolutePath[] files, ref FileStatCache fcache) nothrow {
    foreach (a; toSet(files).toRange) {
        try {
            logger.trace("checking ", a);
            const prev = db.compileDbTrackApi.get(a);
            const res = isSame(prev, a, fcache);
            logger.tracef(!res, "%s is %s (prev:%s curr:%s)", a, res
                    ? "unchaged" : "changed", prev, fcache.get(a));
            if (!res)
                return true;
        } catch (Exception e) {
            logger.trace(e.msg).collectException;
            return true;
        }
    }
    return false;
}

void updateCompileDbTrack(ref Database db, AbsolutePath[] files, ref FileStatCache fcache) nothrow {
    foreach (a; toSet(files).toRange) {
        try {
            auto d = fcache.get(a);
            db.compileDbTrackApi.put(d);
            logger.tracef("saved track data for %s %s", a, d);
        } catch (Exception e) {
            logger.trace(e.msg).collectException;
        }
    }
}
