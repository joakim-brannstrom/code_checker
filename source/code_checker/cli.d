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
import std.typecons : Tuple;
import logger = std.experimental.logger;

import code_checker.types : AbsolutePath, Path;

@safe:

enum AppMode {
    none,
    help,
    helpUnknownCommand,
    normal,
    dumpConfig,
}

/// Configuration options only relevant for static code checkers.
struct ConfigStaticCode {
    bool checkNameStandard = true;
}

/// Configuration options only relevant for clang-tidy.
struct ConfigClangTidy {
    string[] checks;
    string[] options;
    string headerFilter;
    bool applyFixit;
}

/// Configuration data for the compile_commands.json
struct ConfigCompileDb {
    /// Command to generate the compile_commands.json
    string generateDb;

    /// Either a path to a compilation database or a directory to search for one in.
    AbsolutePath[] dbs;

    /// Do not remove the merged compile_commands.json
    bool keep;
}

/// Configuration of how to use the program.
struct Config {
    import code_checker.logger : VerboseMode;

    AppMode mode;
    VerboseMode verbose;

    ConfigStaticCode staticCode;
    ConfigClangTidy clangTidy;
    ConfigCompileDb compileDb;

    /// If set then only analyze these files
    string[] analyzeFiles;

    /// Returns: a config object with default values.
    static Config make() @safe nothrow {
        Config c;
        setClangTidyFromDefault(c);
        return c;
    }

    string toTOML() @trusted {
        import std.algorithm : joiner;
        import std.ascii : newline;
        import std.array : appender, array;
        import std.format : format;
        import std.utf : toUTF8;

        auto app = appender!(string[])();
        app.put("[defaults]");
        app.put(format("check_name_standard = %s", staticCode.checkNameStandard));

        app.put("[compile_commands]");
        app.put(format("search_paths = %s", compileDb.dbs));
        app.put(format(`generate_cmd = "%s"`, compileDb.generateDb));

        app.put("[clang_tidy]");
        app.put(format(`header_filter = "%s"`, clangTidy.headerFilter));
        app.put(format("checks = [%(%s,\n%)]", clangTidy.checks));
        app.put(format("options = [%(%s,\n%)]", clangTidy.options));

        return app.data.joiner(newline).toUTF8;
    }
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
        bool dump_conf;

        // dfmt off
        help_info = std.getopt.getopt(args,
            std.getopt.config.keepEndOfOptions,
            "clang-tidy-fix", "apply clang-tidy fixit hints", &conf.clangTidy.applyFixit,
            "c|compile-db", "path to a compilationi database or where to search for one", &compile_dbs,
            "dump-conf", "dump the configuration used", &dump_conf,
            "f|file", "if set then analyze only these files (default: all)", &conf.analyzeFiles,
            "keep-db", "do not remove the merged compile_commands.json when done", &conf.compileDb.keep,
            "vverbose", "verbose mode is set to trace", &verbose_trace,
            "v|verbose", "verbose mode is set to information", &verbose_info,
            );
        // dfmt on
        conf.mode = AppMode.normal;
        if (help_info.helpWanted)
            conf.mode = AppMode.help;
        else if (dump_conf)
            conf.mode = AppMode.dumpConfig;
        conf.verbose = () {
            if (verbose_trace)
                return VerboseMode.trace;
            if (verbose_info)
                return VerboseMode.info;
            return VerboseMode.minimal;
        }();
        if (compile_dbs.length != 0)
            conf.compileDb.dbs = compile_dbs.map!(a => Path(a).AbsolutePath).array;
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
 * ---
 */
void loadConfig(ref Config rval) @trusted {
    import std.algorithm;
    import std.array : array;
    import std.file : exists, readText;
    import toml;

    immutable conf_file = ".code_checker.toml";
    if (!exists(conf_file))
        return;

    static auto tryLoading(string conf_file) {
        auto txt = readText(conf_file);
        auto doc = parseTOML(txt);
        return doc;
    }

    TOMLDocument doc;
    try {
        doc = tryLoading(conf_file);
    } catch (Exception e) {
        logger.warning("Unable to read the configuration from ", conf_file);
        logger.warning(e.msg);
        return;
    }

    static bool isTomlBool(TOML_TYPE t) {
        return t.among(TOML_TYPE.TRUE, TOML_TYPE.FALSE) != -1;
    }

    alias Fn = void delegate(ref Config c, ref TOMLValue v);
    Fn[string] callbacks;

    void defaults__check_name_standard(ref Config c, ref TOMLValue v) {
        if (isTomlBool(v.type))
            c.staticCode.checkNameStandard = v == true;
    }

    callbacks["defaults.check_name_standard"] = &defaults__check_name_standard;

    callbacks["compile_commands.search_paths"] = (ref Config c, ref TOMLValue v) {
        c.compileDb.dbs = v.array.map!(a => Path(a.str).AbsolutePath).array;
    };
    callbacks["compile_commands.generate_cmd"] = (ref Config c, ref TOMLValue v) {
        c.compileDb.generateDb = v.str;
    };
    callbacks["clang_tidy.header_filter"] = (ref Config c, ref TOMLValue v) {
        c.clangTidy.headerFilter = v.str;
    };
    callbacks["clang_tidy.checks"] = (ref Config c, ref TOMLValue v) {
        c.clangTidy.checks = v.array.map!(a => a.str).array;
    };
    callbacks["clang_tidy.options"] = (ref Config c, ref TOMLValue v) {
        c.clangTidy.options = v.array.map!(a => a.str).array;
    };

    void iterSection(ref Config c, string sectionName) {
        if (auto section = sectionName in doc) {
            // specific configuration from section members
            foreach (k, v; *section) {
                if (auto cb = sectionName ~ "." ~ k in callbacks)
                    (*cb)(c, v);
                else
                    logger.infof("Unknown key '%s' in configuration section '%s'", k, sectionName);
            }
        }
    }

    iterSection(rval, "defaults");
    iterSection(rval, "clang_tidy");
    iterSection(rval, "compile_commands");
}

/// Returns: default configuration as embedded in the binary
void setClangTidyFromDefault(ref Config c) @safe nothrow {
    import std.algorithm;
    import std.array;
    import std.ascii : newline;

    static auto readConf(immutable string raw) {
        // dfmt off
        return raw
            .splitter(newline)
            // remove empty lines
            .filter!(a => a.length != 0)
            // remove comments
            .filter!(a => !a.startsWith("#"))
            .array;
        // dfmt on
    }

    immutable raw_checks = import("clang_tidy_checks.conf");
    immutable raw_options = import("clang_tidy_options.conf");

    c.clangTidy.checks = readConf(raw_checks);
    c.clangTidy.options = readConf(raw_options);
    c.clangTidy.headerFilter = ".*";
}
