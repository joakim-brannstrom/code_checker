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

    /// Analyzers to use.
    string[] analyzers = ["clang-tidy"];

    /// Files matching this pattern should not be analyzed.
    string[] fileExcludeFilter;
}

/// Configuration options only relevant for clang-tidy.
struct ConfigClangTidy {
    /// Checks to toggle on/off
    string[] checks;

    /// Arguments to be baked into the checks parameter
    string[] options;

    /// Argument to the be passed on to clang-tidy's --header-filter paramter as-is
    string headerFilter;

    /// Apply fix hints.
    bool applyFixit;

    /// Apply fix hints even though they result in errors.
    bool applyFixitErrors;

    /// The clang-tidy binary to use.
    string binary = "clang-tidy";
}

/// Configuration options only relevant for iwyu.
struct ConfigIwyu {
    /// The clang-tidy binary to use.
    string binary = "iwyu";

    /// Extra args to pass on to iwyu.
    string[] extraFlags;
}

/// Configuration data for the compile_commands.json
struct ConfigCompileDb {
    import code_checker.compile_db : CompileCommandFilter;

    /// Command to generate the compile_commands.json
    string generateDb;

    /// Raw user input via either config or cli
    string[] rawDbs;

    /// Either a path to a compilation database or a directory to search for one in.
    AbsolutePath[] dbs;

    /// Do not remove the merged compile_commands.json
    bool keep;

    /// Flags the user wants to be automatically removed from the compile_commands.json.
    CompileCommandFilter flagFilter;
}

/// Settings for the compiler
struct Compiler {
    import code_checker.compile_db : SystemCompiler = Compiler;

    /// Additional flags the user wants to add besides those that are in the compile_commands.json.
    string[] extraFlags;

    /// Deduce compiler flags from this compiler and not the one in the
    /// supplied compilation database.  / This is needed when the one specified
    /// in the DB has e.g. a c++ stdlib that is not compatible with clang.
    SystemCompiler useCompilerSystemIncludes;
}

/// Settings for logging.
struct Logging {
    import colorlog : VerboseMode;

    VerboseMode verbose;

    /// If logging to files should be done.
    bool toFile;

    /// Directory to log to.
    AbsolutePath dir;
}

/// Configuration of how to use the program.
struct Config {
    AppMode mode;

    ConfigClangTidy clangTidy;
    ConfigCompileDb compileDb;
    ConfigIwyu iwyu;
    ConfigStaticCode staticCode;

    Compiler compiler;
    Logging logg;
    MiniConfig miniConf;

    /// If set then only analyze these files.
    AbsolutePath[] analyzeFiles;

    /// Returns: a config object with default values.
    static Config make() @safe {
        import code_checker.compile_db : defaultCompilerFlagFilter, CompileCommandFilter;

        Config c;
        setClangTidyFromDefault(c);
        c.compileDb.flagFilter = CompileCommandFilter(defaultCompilerFlagFilter, 0);
        return c;
    }

    string toTOML(Flag!"fullConfig" full) @trusted {
        import std.algorithm : joiner, map;
        import std.ascii : newline;
        import std.array : appender, array;
        import std.format : format;
        import std.utf : toUTF8;
        import std.traits : EnumMembers;
        import code_checker.engine : Severity;

        // this is an ugly hack to get all the available analysers.
        import code_checker.engine : makeRegistry;

        auto app = appender!(string[])();
        app.put("[defaults]");
        app.put(format("# only report issues with a severity >= to this value (%(%s, %))",
                [EnumMembers!Severity]));
        app.put(format(`severity = "%s"`, staticCode.severity));
        app.put(format("# analysers to run. Available are: %s",
                makeRegistry.range.map!(a => a.analyzer.name)));
        app.put(format(`# analysers = %s`, staticCode.analyzers));
        app.put(null);

        app.put("[compiler]");
        app.put("# extra flags to pass on to the compiler");
        app.put(
                "# the following is recommended based on CppCon2018: Jason Turner Applied Best Practise 32m47s");
        app.put(`extra_flags = [ "-Wall",
    "-Wextra", # resonable and standard
    "-Wshadow", # warn the user if a variable declaration shadows one from a parent context
    "-Wnon-virtual-dtor", # warn the user if a class with virtual functions has a non-virtual destructor
    "-Wold-style-cast", # warn for c-style casts
    "-Wcast-align", # warn for potential performance problem casts
#    "-Wunused", # warn on anything being unused
    "-Woverloaded-virtual", # warn if you overload (not override) a virtual func
    "-Wpedantic", # warn if non-standard C++ is used
    "-Wconversion", # warn on type conversions that may lose data
    "-Wsign-conversion", # warn on sign conversion
    "-Wnull-dereference", # warn if a null dereference is detected
    "-Wdouble-promotion", # Warn if float is implicit promoted to double
    "-Wformat=2", # warn on security issues around functions that format output (ie printf)
    "-Wduplicated-cond", # warn if if /else chain has duplicated conditions
    "-Wduplicated-branches", # warn if if / else branches have duplicated code
    "-Wlogical-op", # warn about logical operations being used where bitwise were probably wanted
    "-Wuseless-cast", # warn if you perform a cast to the same type
    "-Wdocumentation" # warn about mismatch between the signature and doxygen comment
 ]`);
        app.put(
                "# use this compilers system includes instead of the one used in the compile_commands.json");
        app.put(format(`# use_compiler_system_includes = "%s"`, compiler.useCompilerSystemIncludes.length == 0
                ? "/path/to/c++" : compiler.useCompilerSystemIncludes.value));
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
        app.put("# files matching any of the regex will not be analyzed");
        app.put(`# exclude = [ ".*/foo/.*", ".*/bar/wun.cpp" ]`);

        if (full) {
            app.put("# flags to remove when analyzing a file in the DB");
            app.put(format("# filter = [%(%s,\n%)]", compileDb.flagFilter.filter));
            app.put("# compiler arguments to skip from the beginning. Needed when the first argument is NOT a compiler but rather a wrapper");
            app.put(format("# skip_compiler_args = %s", compileDb.flagFilter.skipCompilerArgs));
        }
        app.put(null);

        app.put("[clang_tidy]");
        app.put("# clang-tidy binary to use");
        app.put(format(`# binary = "%s"`, clangTidy.binary));
        app.put("# arguments to -header-filter");
        app.put(format(`header_filter = "%s"`, clangTidy.headerFilter));
        if (full) {
            app.put("# checks to use");
            app.put(format("checks = [%(%s,\n%)]", clangTidy.checks));
            app.put("# options affecting the checks");
            app.put(format("options = [%(%s,\n%)]", clangTidy.options));
        }
        app.put(null);

        app.put("[iwyu]");
        app.put("# iwyu (include what you use) binary");
        app.put(format(`# binary = "%s"`, iwyu.binary));
        app.put("# extra flags to pass on to the iwyu command");
        app.put(format(`# flags = [%(%s, %)]`, iwyu.extraFlags));
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
    import std.file : getcwd;
    import std.path : dirName;
    static import std.getopt;

    MiniConfig conf;

    try {
        std.getopt.getopt(args, std.getopt.config.keepEndOfOptions, std.getopt.config.passThrough,
                "workdir", "none not visible to the user", &conf.rawWorkDir,
                "c|config", "none not visible to the user", &conf.rawConfFile);
        conf.confFile = Path(conf.rawConfFile).AbsolutePath;
        if (conf.rawWorkDir.length == 0) {
            conf.rawWorkDir = getcwd;
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
    import colorlog : VerboseMode;
    static import std.getopt;

    bool verbose_info;
    bool verbose_trace;
    std.getopt.GetoptResult help_info;
    try {
        string[] analyze_files;
        string[] compile_dbs;
        string[] src_filter;
        string config_file = ".code_checker.toml";
        string logdir = ".";
        string workdir;
        bool dump_conf;
        bool init_conf;

        // dfmt off
        help_info = std.getopt.getopt(args,
            "a|analyzer", "Analysers to run", &conf.staticCode.analyzers,
            "clang-tidy-bin", "clang-tidy binary to use", &conf.clangTidy.binary,
            "clang-tidy-fix", "apply suggested clang-tidy fixes", &conf.clangTidy.applyFixit,
            "clang-tidy-fix-errors", "apply suggested clang-tidy fixes even if they result in compilation errors", &conf.clangTidy.applyFixitErrors,
            "compile-db", "path to a compilationi database or where to search for one", &compile_dbs,
            "c|config", "load configuration (default: .code_checker.toml)", &config_file,
            "dump-config", "dump the full, detailed configuration used", &dump_conf,
            "f|file", "if set then analyze only these files (default: all)", &analyze_files,
            "init", "create an initial config to use", &init_conf,
            "iwyu-bin", "iwyu binary to use", &conf.iwyu.binary,
            "keep-db", "do not remove the merged compile_commands.json when done", &conf.compileDb.keep,
            "log", "create a logfile for each analyzed file", &conf.logg.toFile,
            "logdir", "path to create logfiles in (default: .)", &logdir,
            "severity", format("report issues with a severity >= to this value (default: style) %s", [EnumMembers!Severity]), &conf.staticCode.severity,
            "v|verbose", format("verbose mode is set to trace (%-(%s,%))", [EnumMembers!VerboseMode]), &conf.logg.verbose,
            "workdir", "use this path as the working directory when programs used by analyzers are executed (default: .)", &workdir,
            );
        // dfmt on
        conf.mode = AppMode.normal;
        if (help_info.helpWanted)
            conf.mode = AppMode.help;
        else if (init_conf)
            conf.mode = AppMode.initConfig;
        else if (dump_conf)
            conf.mode = AppMode.dumpConfig;

        // use a sane default which is to look in the current directory
        if (compile_dbs.length == 0 && conf.compileDb.dbs.length == 0) {
            compile_dbs = ["./compile_commands.json"];
        } else if (compile_dbs.length != 0) {
            conf.compileDb.rawDbs = compile_dbs;
        }

        if (conf.logg.toFile)
            conf.logg.dir = Path(logdir).AbsolutePath;

        // dfmt off
        conf.compileDb.dbs = conf
            .compileDb.rawDbs
            .filter!(a => a.length != 0)
            .map!(a => Path(buildPath(conf.miniConf.workDir, a)).AbsolutePath)
            .array;
        // dfmt on

        conf.analyzeFiles = analyze_files.map!(a => Path(buildPath(conf.miniConf.workDir,
                a)).AbsolutePath).array;
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
    callbacks["defaults.analyzers"] = (ref Config c, ref TOMLValue v) {
        c.staticCode.analyzers = v.array.map!"a.str".array;
    };

    callbacks["compile_commands.search_paths"] = (ref Config c, ref TOMLValue v) {
        c.compileDb.rawDbs = v.array.map!"a.str".array;
    };
    callbacks["compile_commands.generate_cmd"] = (ref Config c, ref TOMLValue v) {
        c.compileDb.generateDb = v.str;
    };
    callbacks["compile_commands.exclude"] = (ref Config c, ref TOMLValue v) {
        c.staticCode.fileExcludeFilter = v.array.map!"a.str".array;
    };
    callbacks["compile_commands.filter"] = (ref Config c, ref TOMLValue v) {
        import code_checker.compile_db : FilterClangFlag;

        c.compileDb.flagFilter.filter = v.array.map!(a => FilterClangFlag(a.str)).array;
    };
    callbacks["compile_commands.skip_compiler_args"] = (ref Config c, ref TOMLValue v) {
        c.compileDb.flagFilter.skipCompilerArgs = cast(int) v.integer;
    };

    callbacks["clang_tidy.binary"] = (ref Config c, ref TOMLValue v) {
        c.clangTidy.binary = v.str;
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
    callbacks["compiler.use_compiler_system_includes"] = (ref Config c, ref TOMLValue v) {
        c.compiler.useCompilerSystemIncludes = v.str;
    };

    callbacks["iwyu.binary"] = (ref Config c, ref TOMLValue v) {
        c.iwyu.binary = v.str;
    };
    callbacks["iwyu.flags"] = (ref Config c, ref TOMLValue v) {
        c.iwyu.extraFlags = v.array.map!(a => a.str).array;
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
    iterSection(rval, "compile_commands");
    iterSection(rval, "compiler");
    iterSection(rval, "clang_tidy");
    iterSection(rval, "iwyu");
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
