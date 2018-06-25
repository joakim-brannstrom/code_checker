/**
Copyright: Copyright (c) 2018, Joakim Brännström. All rights reserved.
License: $(LINK2 http://www.boost.org/LICENSE_1_0.txt, Boost Software License 1.0)
Author: Joakim Brännström (joakim.brannstrom@gmx.com)

This file contains the command line parsing and configuration loading from file.

The data flow is to first load the configuration from the file then parse the command line.
This allows the user to override the configuration via the CLI.
*/
module code_checker.cli;

import std.exception : collectException, ifThrown;
import logger = std.experimental.logger;

import code_checker.types : AbsolutePath, Path;

@safe:

enum AppMode {
    none,
    help,
    helpUnknownCommand,
    normal,
}

/// Configuration options only relevant for static code checkers.
struct ConfigStaticCode {
    bool checkNameStandard;
}

/// Configuration options only relevant for clang-tidy.
struct ConfigClangTidy {
    string[] checks;
    string[] options;
    string headerFilter;
}

/// Configuration of how to use the program.
struct Config {
    import code_checker.logger : VerboseMode;

    AppMode mode;
    VerboseMode verbose;

    ConfigStaticCode staticCode;
    ConfigClangTidy clangTidy;

    /// Command to generate the compile_commands.json
    string genCompileDb;

    /// Either a path to a compilation database or a directory to search for one in.
    AbsolutePath[] compileDbs;

    /// Do not remove the merged compile_commands.json file
    bool keepDb;

    /// Apply the clang tidy fixits.
    bool clangTidyFixit;

    /// If set then only analyze these files
    string[] analyzeFiles;
}

void parseCLI(string[] args, ref Config conf) @trusted {
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
        string[] src_filter;

        // dfmt off
        help_info = std.getopt.getopt(args,
            std.getopt.config.keepEndOfOptions,
            "clang-tidy-fix", "apply clang-tidy fixit hints", &conf.clangTidyFixit,
            "c|compile-db", "path to a compilationi database or where to search for one", &compile_dbs,
            "f|file", "if set then analyze only these files (default: all)", &conf.analyzeFiles,
            "keep-db", "do not remove the merged compile_commands.json when done", &conf.keepDb,
            "clang-tidy-header-filter", "Regular expression matching the names of the files to output diagnostics from (default: .*)", &conf.clangTidy.headerFilter,
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
        if (compile_dbs.length != 0)
            conf.compileDbs = compile_dbs.map!(a => Path(a).AbsolutePath).array;
    } catch (std.getopt.GetOptException e) {
        // unknown option
        logger.error(e.msg);
        conf.mode = AppMode.helpUnknownCommand;
    } catch (Exception e) {
        logger.error(e.msg);
        conf.mode = AppMode.helpUnknownCommand;
    }

    void printHelp() @trusted {
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

/** Load the configuration from file.
 *
 * Example of a TOML configuration
 * ---
 * [defaults]
 * check_name_standard = true
 *
 * [compile_commands]
 * search_paths = [ "./foo/bar" ]
 * cmd_generate = "gen_db #a command that generates a database"
 *
 * # detailed configuration
 * [clang_tidy]
 * header_filter = [ ".* ]
 * checks = [ "*", "-readability-*" ]
 * options = [ "{key: cert-err61-cpp.CheckThrowTemporaries, value: \"1\"}" ]
 * ---
 */
Config loadConfig() @trusted {
    import std.algorithm;
    import std.array : array;
    import std.file : exists, readText;
    import toml;

    immutable conf_file = ".code_checker.toml";
    if (!exists(conf_file))
        return Config.init;

    static auto tryLoading(string conf_file) {
        auto txt = readText(conf_file);
        auto doc = parseTOML(txt);
        logger.trace("Loaded config: ", doc.toString);
        return doc;
    }

    TOMLDocument doc;
    try {
        doc = tryLoading(conf_file);
    } catch (Exception e) {
        logger.warning("Unable to read the configuration from ", conf_file);
        logger.warning(e.msg);
        return Config.init;
    }

    static bool isTomlBool(TOML_TYPE t) {
        return t.among(TOML_TYPE.TRUE, TOML_TYPE.FALSE) != -1;
    }

    Config rval;

    alias Fn = void delegate(ref TOMLValue v);
    Fn[string] callbacks;

    void defaults__check_name_standard(ref TOMLValue v) {
        if (isTomlBool(v.type))
            rval.staticCode.checkNameStandard = v == true;
    }

    void clang_tidy__header_filter(ref TOMLValue v) {
    }

    callbacks["defaults.check_name_standard"] = &defaults__check_name_standard;
    callbacks["compile_commands.search_paths"] = (ref TOMLValue v) {
        rval.compileDbs = v.array.map!(a => Path(a.str).AbsolutePath).array;
    };
    callbacks["compile_commands.cmd_generate"] = (ref TOMLValue v) {
        rval.genCompileDb = v.str;
    };
    callbacks["clang_tidy.header_filter"] = (ref TOMLValue v) {
        rval.clangTidy.headerFilter = v.str;
    };
    callbacks["clang_tidy.checks"] = (ref TOMLValue v) {
        rval.clangTidy.checks = v.array.map!(a => a.str).array;
    };
    callbacks["clang_tidy.options"] = (ref TOMLValue v) {
        rval.clangTidy.options = v.array.map!(a => a.str).array;
    };

    void iterSection(string sectionName) {
        if (auto section = sectionName in doc) {
            foreach (k, v; *section) {
                if (auto cb = sectionName ~ "." ~ k in callbacks)
                    (*cb)(v);
                else
                    logger.infof("Unknown key '%s' in configuration section '%s'", k, sectionName);
            }
        }
    }

    iterSection("defaults");
    iterSection("clang_tidy");
    iterSection("compile_commands");

    return rval;
}
