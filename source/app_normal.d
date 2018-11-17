/**
Copyright: Copyright (c) 2018, Joakim Brännström. All rights reserved.
License: $(LINK2 http://www.boost.org/LICENSE_1_0.txt, Boost Software License 1.0)
Author: Joakim Brännström (joakim.brannstrom@gmx.com)

Normal appliation mode.
*/
module app_normal;

import std.algorithm : among;
import std.exception : collectException;
import logger = std.experimental.logger;

import code_checker.cli : Config;
import code_checker.compile_db : CompileCommandDB;
import code_checker.types : AbsolutePath, Path, AbsoluteFileName;

immutable compileCommandsFile = "compile_commands.json";

int modeNormal(ref Config conf) {
    auto fsm = NormalFSM(conf);
    return fsm.run;
}

private:

/** FSM for the control flow when in normal mode.
 */
struct NormalFSM {
    enum State {
        init_,
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
    bool removeCompileDb;
    /// Root directory from which the program where initially started.
    AbsolutePath root;
    /// Exit status of used to indicate the success to the user.
    int exitStatus;

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

    void act_changeWorkDir() {
        import std.file : getcwd, chdir;

        root = Path(getcwd).AbsolutePath;
        if (conf.miniConf.workDir != root)
            chdir(conf.miniConf.workDir);
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
        import code_checker.compile_db : fromArgCompileDb;

        logger.trace("Creating a unified compile_commands.json");

        auto compile_db = appender!string();
        try {
            auto db = fromArgCompileDb(conf.compileDb.dbs.map!(a => cast(string) a.dup).array);
            unifyCompileDb(db, compile_db);
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
        import code_checker.compile_db : fromArgCompileDb, parseFlag, CompileCommandFilter;

        Environment env;
        env.compileDbFile = AbsolutePath(Path(compileCommandsFile));
        env.compileDb = fromArgCompileDb([env.compileDbFile]);
        env.files = () {
            if (conf.analyzeFiles.length == 0)
                return env.files = env.compileDb.map!(a => cast(string) a.absoluteFile).array;
            else
                return conf.analyzeFiles.map!(a => cast(string) a).array;
        }();
        env.genCompileDb = conf.compileDb.generateDb;
        env.flagFilter = conf.compileDb.flagFilter;

        env.staticCode = conf.staticCode;
        env.clangTidy = conf.clangTidy;
        env.compiler = conf.compiler;
        env.logg = conf.logg;

        Registry reg;
        reg.put(new ClangTidy, Type.staticCode);
        exitStatus = execute(env, reg) == Status.passed ? 0 : 1;
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
void unifyCompileDb(AppT)(CompileCommandDB db, ref AppT app) {
    import std.algorithm : map, joiner, filter, copy;
    import std.array : array, appender;
    import std.ascii : newline;
    import std.format : formattedWrite;
    import std.json : JSONValue;
    import std.path : stripExtension;
    import std.range : put;
    import code_checker.compile_db;

    auto flag_filter = CompileCommandFilter(defaultCompilerFilter.filter.dup, 0);
    logger.trace(flag_filter);

    void writeEntry(T)(ref const T e) {
        import std.exception : assumeUnique;
        import std.utf : byChar;

        auto raw_flags = () @safe {
            auto app = appender!(string[]);
            e.parseFlag(flag_filter).flags.copy(app);
            // add back dummy -c otherwise clang-tidy do not work
            ["-c", cast(string) e.absoluteFile].copy(app);
            return app.data;
        }();

        formattedWrite(app, `"directory": "%s",`, cast(string) e.directory);
        formattedWrite(app, `"command": "%-(%s %)",`, raw_flags);

        if (e.output.hasValue)
            formattedWrite(app, `"output": "%s",`, cast(string) e.absoluteOutput);
        formattedWrite(app, `"file": "%s"`, cast(string) e.absoluteFile);
    }

    if (db.length == 0) {
        return;
    }

    formattedWrite(app, "[");

    foreach (ref const e; db[0 .. $ - 1]) {
        formattedWrite(app, "{");
        writeEntry(e);
        formattedWrite(app, "},");
        put(app, newline);
    }

    formattedWrite(app, "{");
    writeEntry(db[$ - 1]);
    formattedWrite(app, "}");

    formattedWrite(app, "]");
}
