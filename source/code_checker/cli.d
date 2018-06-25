/**
Copyright: Copyright (c) 2018, Joakim Brännström. All rights reserved.
License: $(LINK2 http://www.boost.org/LICENSE_1_0.txt, Boost Software License 1.0)
Author: Joakim Brännström (joakim.brannstrom@gmx.com)

This file contains the command line parsing.
*/
module code_checker.cli;

import logger = std.experimental.logger;

import code_checker.types : AbsolutePath, Path;

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

    /// Do not remove the merged compile_commands.json file
    bool keepDb;

    /// Apply the clang tidy fixits.
    bool clangTidyFixit;
}

void parseCLI(string[] args, ref Config conf) {
    import std.algorithm : map;
    import std.algorithm : among;
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
            "keep-db", "do not remove the merged compile_commands.json when done", &conf.keepDb,
            "clang-tidy-fix", "apply clang-tidy fixit hints", &conf.clangTidyFixit,
            "vverbose", "verbose mode is set to trace", &verbose_trace,
            "v|verbose", "verbose mode is set to information", &verbose_info,
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
