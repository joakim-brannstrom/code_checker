/**
Copyright: Copyright (c) 2018, Joakim Brännström. All rights reserved.
License: $(LINK2 http://www.boost.org/LICENSE_1_0.txt, Boost Software License 1.0)
Author: Joakim Brännström (joakim.brannstrom@gmx.com)
*/
module app;

import std.algorithm : among;
import std.exception : collectException;

import logger = std.experimental.logger;
import code_checker.types : AbsolutePath, Path;

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
    auto compile_dbs = findCompileDbs(conf.compileDbs);

    return 0;
}

auto findCompileDbs(const(AbsolutePath)[] paths) {
    import std.algorithm : filter, map;
    import std.file : exists, isDir, isFile, dirEntries, SpanMode;

    AbsolutePath[] rval;

    static AbsolutePath[] findRecursive(const AbsolutePath p) {
        import std.path : baseName;

        AbsolutePath[] rval;
        foreach (a; dirEntries(p, SpanMode.depth).filter!(a => a.isFile)
                .filter!(a => a.name.baseName == "compile_commands.json").map!(a => a.name)) {
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
            logger.warning(e.msg);
        }
    }

    return rval;
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
