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
import std.typecons : Tuple, Flag;
import logger = std.experimental.logger;

import code_checker.types : AbsolutePath, Path;

@safe:

enum AppMode {
    none,
    help,
    helpUnknownCommand,
    normal,
    dumpConfig,
    dumpFullConfig,
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

    /// If set then only analyze these files.
    string[] analyzeFiles;

    /// Directory to use as root when running the tests.
    AbsolutePath workDir;

    /// Returns: a config object with default values.
    static Config make() @safe {
        Config c;
        setClangTidyFromDefault(c);
        return c;
    }

    string toTOML(Flag!"fullConfig" full) @trusted {
        import std.algorithm : joiner;
        import std.ascii : newline;
        import std.array : appender, array;
        import std.format : format;
        import std.utf : toUTF8;

        auto app = appender!(string[])();
        app.put("[defaults]");
        app.put("# working directory when executing commands");
        app.put(format(`workdir = "%s"`, workDir));
        app.put("# affects static code analysis to check against the name standard");
        app.put(format("check_name_standard = %s", staticCode.checkNameStandard));

        app.put("[compile_commands]");
        app.put("# command to execute to generate compile_commands.json");
        app.put(format(`generate_cmd = "%s"`, compileDb.generateDb));
        app.put("# search for compile_commands.json in this paths");
        app.put(format("search_paths = %s", compileDb.dbs));

        app.put("[clang_tidy]");
        app.put("# arguments to -header-filter");
        app.put(format(`header_filter = "%s"`, clangTidy.headerFilter));
        if (full) {
            app.put("# checks to use");
            app.put(format("checks = [%(%s,\n%)]", clangTidy.checks));
            app.put("# options affecting the checks");
            app.put(format("options = [%(%s,\n%)]", clangTidy.options));
        }

        return app.data.joiner(newline).toUTF8;
    }
}

/// Returns: path to the configuration file.
string parseConfigCLI(string[] args) @trusted nothrow {
    static import std.getopt;

    string conf_file = ".code_checker.toml";
    try {
        std.getopt.getopt(args, std.getopt.config.keepEndOfOptions, std.getopt.config.passThrough,
                "c|config", "none not visible to the user", &conf_file,);
    } catch (Exception e) {
    }

    return conf_file;
}

void parseCLI(string[] args, ref Config conf) @trusted {
    import std.algorithm : map, among;
    import std.array : array;
    import std.path : dirName;
    import code_checker.logger : VerboseMode;
    static import std.getopt;

    bool verbose_info;
    bool verbose_trace;
    std.getopt.GetoptResult help_info;
    try {
        string[] compile_dbs;
        string[] src_filter;
        bool dump_conf;
        bool dump_full_config;
        bool junk_parameter;

        // dfmt off
        help_info = std.getopt.getopt(args,
            std.getopt.config.keepEndOfOptions,
            "c|config", "load configuration (default: .code_checker.toml)", &junk_parameter,
            "clang-tidy-fix", "apply clang-tidy fixit hints", &conf.clangTidy.applyFixit,
            "compile-db", "path to a compilationi database or where to search for one", &compile_dbs,
            "dump-config", "dump a default configuration to use", &dump_conf,
            "dump-full-config", "dump the full, detailed configuration used", &dump_full_config,
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
        else if (dump_full_config)
            conf.mode = AppMode.dumpFullConfig;
        conf.verbose = () {
            if (verbose_trace)
                return VerboseMode.trace;
            if (verbose_info)
                return VerboseMode.info;
            return VerboseMode.minimal;
        }();
        if (compile_dbs.length != 0)
            conf.compileDb.dbs = compile_dbs.map!(a => Path(a).AbsolutePath).array;
        if (conf.workDir.length == 0)
            conf.workDir = Path(".").AbsolutePath;
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
void loadConfig(ref Config rval, string configFile) @trusted {
    import std.algorithm;
    import std.array : array;
    import std.file : exists, readText;
    import toml;

    if (!exists(configFile))
        return;

    static auto tryLoading(string configFile) {
        auto txt = readText(configFile);
        auto doc = parseTOML(txt);
        return doc;
    }

    TOMLDocument doc;
    try {
        doc = tryLoading(configFile);
    } catch (Exception e) {
        logger.warning("Unable to read the configuration from ", configFile);
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

    callbacks["defaults.workdir"] = (ref Config c, ref TOMLValue v) {
        c.workDir = Path(v.str).AbsolutePath;
    };
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
