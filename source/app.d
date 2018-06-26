/**
Copyright: Copyright (c) 2018, Joakim Brännström. All rights reserved.
License: $(LINK2 http://www.boost.org/LICENSE_1_0.txt, Boost Software License 1.0)
Author: Joakim Brännström (joakim.brannstrom@gmx.com)
*/
module app;

import std.algorithm : among;
import std.exception : collectException;

import logger = std.experimental.logger;

import code_checker.cli : Config;
import code_checker.compile_db : CompileCommandDB;
import code_checker.types : AbsolutePath, Path, AbsoluteFileName;

immutable compileCommandsFile = "compile_commands.json";

int main(string[] args) {
    import std.functional : toDelegate;
    import code_checker.cli : AppMode, parseCLI, loadConfig, Config;
    import code_checker.logger;

    auto conf = () {
        auto conf = Config.make;
        try {
            confLogger(VerboseMode.info);
            loadConfig(conf);
        } catch (Exception e) {
            logger.warning(e.msg);
            logger.warning("Unable to read configuration");
        }
        return conf;
    }();
    parseCLI(args, conf);
    confLogger(conf.verbose);
    logger.trace(conf);

    alias Command = int delegate(ref Config conf);
    Command[AppMode] cmds;
    cmds[AppMode.none] = toDelegate(&modeNone);
    cmds[AppMode.help] = toDelegate(&modeNone);
    cmds[AppMode.helpUnknownCommand] = toDelegate(&modeNone_Error);
    cmds[AppMode.normal] = toDelegate(&modeNormal);
    cmds[AppMode.dumpConfig] = toDelegate(&modeDumpConfig);

    if (auto v = conf.mode in cmds) {
        return (*v)(conf);
    }

    logger.error("Unknown mode %s", conf.mode);
    return 1;
}

int modeNone(ref Config conf) {
    return 0;
}

int modeNone_Error(ref Config conf) {
    return 1;
}

int modeNormal(ref Config conf) {
    import std.algorithm : map;
    import std.array : appender, array;
    import std.file : exists, remove;
    import std.process;
    import std.stdio : File;
    import code_checker.compile_db : fromArgCompileDb, parseFlag,
        CompileCommandFilter;
    import code_checker.engine;

    bool removeCompileDb = !exists(compileCommandsFile) && !conf.keepDb;
    scope (exit) {
        if (removeCompileDb)
            remove(compileCommandsFile).collectException;
    }

    if (conf.compileDbs.length != 0) {
        logger.trace("Creating a unified compile_commands.json");

        auto compile_db = appender!string();
        try {
            auto dbs = findCompileDbs(conf.compileDbs);
            if (dbs.length == 0) {
                logger.errorf("No %s found in %s", compileCommandsFile, conf.compileDbs);
                return 1;
            }

            auto db = fromArgCompileDb(dbs.map!(a => cast(string) a.dup).array);
            unifyCompileDb(db, compile_db);
            File(compileCommandsFile, "w").write(compile_db.data);
        } catch (Exception e) {
            logger.error(e.msg);
            return 1;
        }
    }

    Environment env;
    env.compileDbFile = AbsolutePath(Path(compileCommandsFile));
    env.compileDb = fromArgCompileDb([env.compileDbFile]);
    env.files = () {
        if (conf.analyzeFiles.length == 0)
            return env.files = env.compileDb.map!(a => cast(string) a.absoluteFile.payload).array;
        else
            return conf.analyzeFiles.dup;
    }();
    env.genCompileDb = conf.genCompileDb;
    env.staticCode = conf.staticCode;
    env.clangTidy = conf.clangTidy;

    Registry reg;
    reg.put(new ClangTidy(conf.clangTidyFixit), Type.staticCode);
    return execute(env, reg) == Status.passed ? 0 : 1;
}

int modeDumpConfig(ref Config conf) {
    import std.stdio : writeln, stderr;

    // make it easy for a user to pipe the output to the confi file
    stderr.writeln("Dumping the configuration used. The format is TOML (.toml)");
    stderr.writeln("If you want to use it put it in your '.code_checker.toml'");

    writeln(conf.toTOML);

    return 1;
}

auto findCompileDbs(const(AbsolutePath)[] paths) nothrow {
    import std.algorithm : filter, map;
    import std.file : exists, isDir, isFile, dirEntries, SpanMode;

    AbsolutePath[] rval;

    static AbsolutePath[] findRecursive(const AbsolutePath p) {
        import std.path : baseName;

        AbsolutePath[] rval;
        foreach (a; dirEntries(p, SpanMode.depth).filter!(a => a.isFile)
                .filter!(a => a.name.baseName == compileCommandsFile).map!(a => a.name)) {
            try {
                rval ~= AbsolutePath(Path(a));
            } catch (Exception e) {
                logger.warning(e.msg);
            }
        }
        return rval;
    }

    foreach (a; paths.filter!(a => exists(a))) {
        try {
            if (a.isDir) {
                logger.tracef("Looking for compilation database in '%s'", a).collectException;
                rval ~= findRecursive(a);
            } else if (a.isFile)
                rval ~= a;
        } catch (Exception e) {
            logger.warning(e.msg).collectException;
        }
    }

    return rval;
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

        auto raw_flags = () @safe{
            auto app = appender!(string[]);
            e.parseFlag(flag_filter).flags.copy(app);
            // add back dummy -c otherwise clang-tidy do not work
            ["-c", cast(string) e.absoluteFile].copy(app);
            return app.data;
        }();

        formattedWrite(app, `"directory": "%s",`, cast(string) e.directory);

        if (e.arguments.hasValue) {
            formattedWrite(app, `"arguments": %s,`, raw_flags);
        } else {
            formattedWrite(app, `"command": "%-(%s %)",`, raw_flags);
        }

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
