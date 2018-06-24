/**
Copyright: Copyright (c) 2018, Joakim Brännström. All rights reserved.
License: $(LINK2 http://www.boost.org/LICENSE_1_0.txt, Boost Software License 1.0)
Author: Joakim Brännström (joakim.brannstrom@gmx.com)
*/
module app;

import std.algorithm : among;
import std.exception : collectException;

import logger = std.experimental.logger;
import code_checker.compile_db : CompileCommandDB;
import code_checker.types : AbsolutePath, Path, AbsoluteFileName;

immutable compileCommandsFile = "compile_commands.json";

int main(string[] args) {
    import std.functional : toDelegate;
    import code_checker.logger;

    Config conf;
    parseCLI(args, conf);
    confLogger(conf.verbose);
    logger.trace(conf);

    alias Command = int delegate(const ref Config conf);
    Command[AppMode] cmds;
    cmds[AppMode.none] = toDelegate(&modeNone);
    cmds[AppMode.help] = toDelegate(&modeNone);
    cmds[AppMode.helpUnknownCommand] = toDelegate(&modeNone_Error);
    cmds[AppMode.normal] = toDelegate(&modeNormal);

    if (auto v = conf.mode in cmds) {
        return (*v)(conf);
    }

    logger.error("Unknown mode %s", conf.mode);
    return 1;
}

int modeNone(const ref Config conf) {
    return 0;
}

int modeNone_Error(const ref Config conf) {
    return 1;
}

int modeNormal(const ref Config conf) {
    import std.algorithm : map;
    import std.array : appender, array;
    import std.file : exists;
    import std.process;
    import std.stdio : File;
    import code_checker.compile_db : fromArgCompileDb, parseFlag,
        CompileCommandFilter;
    import code_checker.engine;

    if (!exists(compileCommandsFile)) {
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
    env.files = env.compileDb.map!(a => cast(AbsolutePath) a.absoluteFile.payload).array;

    Registry reg;
    reg.put(new ClangTidy, Type.staticCode);
    execute(env, reg);

    return 0;
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
            auto app = appender!string;
            e.parseFlag(flag_filter).flags.joiner(" ").copy(app);

            // add back dummy -c and -o otherwise clang-tidy do not work
            app.put(" ");
            ["-c", cast(string) e.absoluteFile, "-o", e.absoluteFile.stripExtension ~ ".o"].joiner(" ")
                .copy(app);
            return app.data;
        }();

        formattedWrite(app, `"directory": "%s",`, cast(string) e.directory);

        if (e.arguments.hasValue) {
            formattedWrite(app, `"arguments": "%s",`, raw_flags);
        } else {
            formattedWrite(app, `"command": "%s",`, raw_flags);
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

enum AppMode {
    none,
    help,
    helpUnknownCommand,
    normal,
}

struct Config {
    import code_checker.logger : VerboseMode;

    AppMode mode;
    VerboseMode verbose;

    /// Either a path to a compilation database or a directory to search for one in.
    AbsolutePath[] compileDbs;
}

void parseCLI(string[] args, ref Config conf) {
    import std.algorithm : map;
    import std.array : array;
    import code_checker.logger : VerboseMode;
    static import std.getopt;

    bool verbose_info;
    bool verbose_trace;
    std.getopt.GetoptResult help_info;
    try {
        string[] compile_dbs;
        // dfmt off
        help_info = std.getopt.getopt(args,
            std.getopt.config.keepEndOfOptions,
            "c|compile-db", "path to a compilationi database or where to search for one", &compile_dbs,
            "v|verbose", "verbose mode is set to information", &verbose_info,
            "vverbose", "verbose mode is set to trace", &verbose_trace,
            );
        // dfmt on
        conf.mode = help_info.helpWanted ? AppMode.help : AppMode.normal;
        conf.verbose = () {
            if (verbose_trace)
                return VerboseMode.trace;
            if (verbose_info)
                return VerboseMode.info;
            return VerboseMode.minimal;
        }();
        conf.compileDbs = compile_dbs.map!(a => Path(a).AbsolutePath).array;
        if (compile_dbs.length == 0)
            conf.compileDbs = [AbsolutePath(Path("."))];
    } catch (std.getopt.GetOptException e) {
        // unknown option
        logger.error(e.msg);
        conf.mode = AppMode.helpUnknownCommand;
    } catch (Exception e) {
        logger.error(e.msg);
        conf.mode = AppMode.helpUnknownCommand;
    }

    void printHelp() {
        import std.getopt : defaultGetoptPrinter;
        import std.format : format;
        import std.path : baseName;

        defaultGetoptPrinter(format("usage: %s\n", args[0].baseName), help_info.options);
    }

    if (conf.mode.among(AppMode.help, AppMode.helpUnknownCommand)) {
        printHelp;
        return;
    }
}
