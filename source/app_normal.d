/**
Copyright: Copyright (c) 2018, Joakim Brännström. All rights reserved.
License: $(LINK2 http://www.boost.org/LICENSE_1_0.txt, Boost Software License 1.0)
Author: Joakim Brännström (joakim.brannstrom@gmx.com)

Normal appliation mode.
*/
module app_normal;

import logger = std.experimental.logger;
import std.algorithm : among;
import std.array : empty;
import std.exception : collectException;

import my.path;

import compile_db : CompileCommandDB, toCompileCommandDB, DbCompiler = Compiler,
    CompileCommandFilter, defaultCompilerFilter, ParsedCompileCommand;

import code_checker.cli : Config;
import code_checker.database : Database;
import code_checker.engine : Environment;

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
        import code_checker.database;

        try {
            db = Database.make(conf.database);
        } catch (Exception e) {
            logger.warning(e.msg);
        }
    }

    void act_changeWorkDir() {
        import std.file : getcwd, chdir;

        root = Path(getcwd).AbsolutePath;
        if (conf.workDir != root)
            chdir(conf.workDir);
    }

    void act_checkForDb() {
        import std.file : exists;

        removeCompileDb = !exists(compileCommandsFile) && !conf.compileDb.keep;
    }

    void act_genDb() {
        import std.process : spawnShell, wait;

        auto res = spawnShell(conf.compileDb.generateDb).wait;
        if (res != 0) {
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
        import std.algorithm : map;
        import std.array : appender, array;
        import std.stdio : File;
        import compile_db : fromArgCompileDb;

        logger.trace("Creating a unified compile_commands.json");

        try {
            this.compileDb = fromArgCompileDb(conf.compileDb.dbs.map!(a => cast(string) a.dup)
                    .array);

            auto compile_db = appender!string();
            unifyCompileDb(compileDb, conf.compiler.useCompilerSystemIncludes,
                    conf.compileDb.flagFilter, compile_db);
            File(compileCommandsFile, "w").write(compile_db.data);
        } catch (Exception e) {
            logger.errorf("Unable to process %s", compileCommandsFile);
            logger.error(e.msg);
            exitStatus = 1;
        }
    }

    void act_runRegistry() {
        import std.algorithm : map;
        import std.array : array;
        import code_checker.engine;
        import compile_db : fromArgCompileDb, parseFlag, CompileCommandFilter;
        import code_checker.change : dependencyAnalyze;
        import code_checker.engine.types : TotalResult;

        auto changed = () {
            bool[AbsolutePath] rval;

            try {
                foreach (v; dependencyAnalyze(db, AbsolutePath(".")).byKeyValue) {
                    rval[v.key.AbsolutePath] = v.value;
                }
            } catch (Exception e) {
            }
            return rval;
        }();

        Environment env;
        env.compileDbFile = AbsolutePath(Path(compileCommandsFile));
        env.compileDb = this.compileDb;
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
            exitStatus = tres.status == Status.passed ? 0 : 1;
        }

        try {
            saveDependencies(db, env, AbsolutePath("."), tres.failed);
            removeDroppedFiles(db, env, AbsolutePath("."));
        } catch (Exception e) {
            logger.warning(e.msg);
        }
    }

    void act_cleanup() {
        import std.file : remove, chdir;

        if (removeCompileDb)
            remove(compileCommandsFile).collectException;

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
    import std.algorithm : map, joiner, filter, copy;
    import std.array : array, appender;
    import std.ascii : newline;
    import std.format : formattedWrite;
    import std.path : stripExtension;
    import std.range : put;
    import compile_db;

    logger.trace(flag_filter);

    void writeEntry(T)(T e) {
        import std.exception : assumeUnique;
        import std.utf : byChar;
        import std.json : JSONValue;

        auto raw_flags = () @safe {
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
    import std.array : appender;

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

struct FileIncludes {
    import compile_db : ParseFlags, SystemIncludePath;

    ParseFlags.Include[] includes;
    SystemIncludePath[] systemIncludes;
}

void saveDependencies(ref Database db, Environment env, AbsolutePath root,
        AbsolutePath[] failedFiles) {
    import std.algorithm : map, filter;
    import std.path : relativePath;
    import std.array : array;
    import my.set;
    import code_checker.engine.compile_db : toRange;
    import code_checker.database : DepFile;

    auto failed = toSet(failedFiles);

    Path toRelativeRoot(AbsolutePath f) {
        return Path(relativePath(f, root));
    }

    auto checksum(AbsolutePath f) {
        import my.hash : checksum, makeChecksum64, Checksum64;

        try {
            return checksum!makeChecksum64(f);
        } catch (Exception e) {
            logger.trace(e.msg);
        }
        return Checksum64(0);
    }

    foreach (pcmd; toRange(env).filter!(a => a.cmd.absoluteFile !in failed)) {
        db.fileApi.put(toRelativeRoot(pcmd.cmd.absoluteFile),
                checksum(pcmd.cmd.absoluteFile), true);
        auto deps = depScan(pcmd, root).map!(a => DepFile(toRelativeRoot(a), checksum(a))).array;
        db.dependencyApi.set(toRelativeRoot(pcmd.cmd.absoluteFile), deps);
    }
}

AbsolutePath[] depScan(ParsedCompileCommand pcmd, AbsolutePath root) {
    import std.algorithm : map, filter, copy;
    import std.array : appender;
    import std.stdio : File;
    import std.string : strip, startsWith, split;
    import my.optional;
    import code_checker.change : toAbsolutePath;

    auto app = appender!(AbsolutePath[])();

    try {
        File(pcmd.cmd.absoluteFile).byLine
            .map!(a => a.strip)
            .filter!(a => a.startsWith("#include"))
            .map!(a => a.split)
            .filter!(a => a.length >= 2)
            .map!(a => a[1])
            .filter!(a => a.length >= 3)
            .map!(a => strip(a.idup)[1 .. $ - 1].Path)
            .map!(a => toAbsolutePath(a, root, pcmd.flags.includes, pcmd.flags.systemIncludes))
            .filter!(a => a.hasValue)
            .map!(a => a.orElse(AbsolutePath.init))
            .copy(app);
    } catch (Exception e) {
        logger.trace(e.msg);
    }

    return app.data;
}

void removeDroppedFiles(ref Database db, Environment env, AbsolutePath root) {
    import std.algorithm : map;
    import std.path : buildPath, relativePath;
    import my.set;

    auto current = env.compileDb.map!(a => a.absoluteFile.relativePath(root).Path).toSet;
    auto dbFiles = db.fileApi.getFiles.toSet;
    foreach (removed; dbFiles.setDifference(current).toRange) {
        db.fileApi.removeFile(removed);
    }
}
