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
    initConfig,
    dumpConfig,
}

/// Configuration options only relevant for static code checkers.
struct ConfigStaticCode {
    import code_checker.engine.types : Severity;

    /// Filter results from analyzers on this severity.
    Severity severity;
}

/// Configuration options only relevant for clang-tidy.
struct ConfigClangTidy {
    string[] checks;
    string[] options;
    string headerFilter;
    bool applyFixit;
    bool applyFixitErrors;
}

/// Configuration data for the compile_commands.json
struct ConfigCompileDb {
    /// Command to generate the compile_commands.json
    string generateDb;

    /// Raw user input via either config or cli
    string[] rawDbs;

    /// Either a path to a compilation database or a directory to search for one in.
    AbsolutePath[] dbs;

    /// Do not remove the merged compile_commands.json
    bool keep;
}

/// Settings for the compiler
struct Compiler {
    string[] extraFlags;
}

/// Configuration of how to use the program.
struct Config {
    import code_checker.logger : VerboseMode;

    AppMode mode;
    VerboseMode verbose;

    ConfigStaticCode staticCode;
    ConfigClangTidy clangTidy;
    ConfigCompileDb compileDb;
    Compiler compiler;
    MiniConfig miniConf;

    /// If set then only analyze these files.
    string[] analyzeFiles;

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
        app.put("# only report issues with a severity >= to this value");
        app.put(format(`severity = "%s"`, staticCode.severity));
        app.put(null);

        app.put("[compiler]");
        app.put("# extra flags to pass on to the compiler");
        app.put(`# extra_flags = [ "-std=c++11", "-Wextra", "-Werror" ]`);
        app.put(null);

        app.put("[compile_commands]");
        app.put("# command to execute to generate compile_commands.json");
        app.put(format(`generate_cmd = "%s"`, compileDb.generateDb));
        app.put("# search for compile_commands.json in this paths");
        if (compileDb.dbs.length == 0 || compileDb.dbs.length == 1
                && compileDb.dbs[0] == Path("./compile_commands.json").AbsolutePath)
            app.put(format("search_paths = %s", ["./compile_commands.json"]));
        else
            app.put(format("search_paths = %s", compileDb.dbs));
        app.put(null);

        app.put("[clang_tidy]");
        app.put("# arguments to -header-filter");
        app.put(format(`header_filter = "%s"`, clangTidy.headerFilter));
        if (full) {
            app.put("# checks to use");
            app.put(format("checks = [%(%s,\n%)]", clangTidy.checks));
            app.put("# options affecting the checks");
            app.put(format("options = [%(%s,\n%)]", clangTidy.options));
        }
        app.put(null);

        return app.data.joiner(newline).toUTF8;
    }
}

/// Minimal config to setup path to config file and workdir.
struct MiniConfig {
    /// Value from the user via CLI, unmodified.
    string rawWorkDir;

    /// Converted to an absolute path.
    AbsolutePath workDir;

    /// Value from the user via CLI, unmodified.
    string rawConfFile = ".code_checker.toml";

    /// The configuration file that has been loaded
    AbsolutePath confFile;
}

/// Returns: minimal config to load settings and setup working directory.
MiniConfig parseConfigCLI(string[] args) @trusted nothrow {
    import std.path : dirName;
    static import std.getopt;

    MiniConfig conf;

    try {
        std.getopt.getopt(args, std.getopt.config.keepEndOfOptions, std.getopt.config.passThrough,
                "workdir", "none not visible to the user", &conf.rawWorkDir,
                "c|config", "none not visible to the user", &conf.rawConfFile);
        conf.confFile = Path(conf.rawConfFile).AbsolutePath;
        if (conf.rawWorkDir.length == 0) {
            conf.rawWorkDir = conf.confFile.dirName;
        }
        conf.workDir = Path(conf.rawWorkDir).AbsolutePath;
    } catch (Exception e) {
        logger.error("Invalid cli values: ", e.msg).collectException;
        logger.trace(conf).collectException;
    }

    return conf;
}

void parseCLI(string[] args, ref Config conf) @trusted {
    import std.algorithm : map, among, filter;
    import std.array : array;
    import std.format : format;
    import std.path : dirName, buildPath;
    import std.traits : EnumMembers;
    import code_checker.engine.types : Severity;
    import code_checker.logger : VerboseMode;
    static import std.getopt;

    bool verbose_info;
    bool verbose_trace;
    std.getopt.GetoptResult help_info;
    try {
        string config_file = ".code_checker.toml";
        string[] compile_dbs;
        string[] src_filter;
        string workdir;
        bool dump_conf;
        bool init_conf;

        // dfmt off
        help_info = std.getopt.getopt(args,
            "clang-tidy-fix", "apply suggested clang-tidy fixes", &conf.clangTidy.applyFixit,
            "severity", format("report issues with a severity >= to this value (default: style) %s", [EnumMembers!Severity]), &conf.staticCode.severity,
            "clang-tidy-fix-errors", "apply suggested clang-tidy fixes even if they result in compilation errors", &conf.clangTidy.applyFixitErrors,
            "compile-db", "path to a compilationi database or where to search for one", &compile_dbs,
            "c|config", "load configuration (default: .code_checker.toml)", &config_file,
            "dump-config", "dump the full, detailed configuration used", &dump_conf,
            "f|file", "if set then analyze only these files (default: all)", &conf.analyzeFiles,
            "init", "create an initial config to use", &init_conf,
            "keep-db", "do not remove the merged compile_commands.json when done", &conf.compileDb.keep,
            "vverbose", "verbose mode is set to trace", &verbose_trace,
            "v|verbose", "verbose mode is set to information", &verbose_info,
            "workdir", "use this path as the working directory when programs used by analyzers are executed (default: where .code_checker.toml is)", &workdir,
            );
        // dfmt on
        conf.mode = AppMode.normal;
        if (help_info.helpWanted)
            conf.mode = AppMode.help;
        else if (init_conf)
            conf.mode = AppMode.initConfig;
        else if (dump_conf)
            conf.mode = AppMode.dumpConfig;
        conf.verbose = () {
            if (verbose_trace)
                return VerboseMode.trace;
            if (verbose_info)
                return VerboseMode.info;
            return VerboseMode.minimal;
        }();

        // use a sane default which is to look in the current directory
        if (compile_dbs.length == 0 && conf.compileDb.dbs.length == 0) {
            compile_dbs = ["./compile_commands.json"];
        } else if (compile_dbs.length != 0) {
            conf.compileDb.rawDbs = compile_dbs;
        }

        // dfmt off
        conf.compileDb.dbs = conf
            .compileDb.rawDbs
            .filter!(a => a.length != 0)
            .map!(a => Path(buildPath(conf.miniConf.workDir, a)).AbsolutePath)
            .array;
        // dfmt on
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
    import std.path : dirName, buildPath;
    import toml;

    if (!exists(rval.miniConf.confFile))
        return;

    static auto tryLoading(string configFile) {
        auto txt = readText(configFile);
        auto doc = parseTOML(txt);
        return doc;
    }

    TOMLDocument doc;
    try {
        doc = tryLoading(rval.miniConf.confFile);
    } catch (Exception e) {
        logger.warning("Unable to read the configuration from ", rval.miniConf.confFile);
        logger.warning(e.msg);
        return;
    }

    alias Fn = void delegate(ref Config c, ref TOMLValue v);
    Fn[string] callbacks;

    void defaults__check_name_standard(ref Config c, ref TOMLValue v) {
        import std.traits : EnumMembers;
        import code_checker.engine.types : toSeverity, Severity;

        auto s = toSeverity(v.str);
        if (s.isNull) {
            logger.warningf("Unknown severity level %s. Using default: style", v.str);
            logger.warningf("valid values are: %s", [EnumMembers!Severity]);
            c.staticCode.severity = Severity.style;
        } else {
            c.staticCode.severity = s;
        }
    }

    callbacks["defaults.severity"] = &defaults__check_name_standard;

    callbacks["compile_commands.search_paths"] = (ref Config c, ref TOMLValue v) {
        c.compileDb.rawDbs = v.array.map!(a => a.str).array;
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
    callbacks["compiler.extra_flags"] = (ref Config c, ref TOMLValue v) {
        c.compiler.extraFlags = v.array.map!(a => a.str).array;
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
    iterSection(rval, "compiler");
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
