/**
Copyright: Copyright (c) 2018, Joakim Brännström. All rights reserved.
License: $(LINK2 http://www.boost.org/LICENSE_1_0.txt, Boost Software License 1.0)
Author: Joakim Brännström (joakim.brannstrom@gmx.com)

This file contains the command line parsing and configuration loading from file.

The data flow is to first load the configuration from the file then parse the command line.
This allows the user to override the configuration via the CLI.
*/
module code_checker.cli;

import logger = std.experimental.logger;
import std.array : array, empty;
import std.exception : collectException;
import std.path : buildPath, dirName;

import my.path : AbsolutePath, Path;
import my.set;
import toml : TOMLDocument, TOMLValue;

@safe:

enum AppMode {
    none,
    help,
    helpUnknownCommand,
    normal,
    initConfig,
}

enum Progress {
    // show save info to DB
    saveDb,
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

    /// Only files matching this pattern should be analyzed.
    string[] fileIncludeFilter;
}

/// Configuration options only relevant for clang-tidy.
struct ConfigClangTidy {
    /// System configuration to use if .clang-tidy do not exists in work directory.
    string systemConfig = "{code_checker}/../etc/code_checker/clang_tidy.conf";

    /// Checks to toggle on/off. Used as a compliment to checks.
    string[] checkExtensions;

    /// Used as a compliment to options. options is set in the global while optionExtensions is set locally.
    string[string] optionExtensions;

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

    /// Map files to pass on to iwyu.
    string[] maps;

    /// Map files to pass on to iwyu.
    string[] defaultMaps;
}

/// Configuration data for the compile_commands.json
struct ConfigCompileDb {
    import compile_db : CompileCommandFilter;

    /// Command to generate the compile_commands.json
    string generateDb;

    /// Dependencies that the generate command have. If it is set then the
    /// commmand is only executed when they are changed.
    AbsolutePath[] generateDbDeps;

    /// Raw user input via either config or cli
    string[] rawDbs;

    /// Either a path to a compilation database or a directory to search for one in.
    AbsolutePath[] dbs;

    /// Flags the user wants to be automatically removed from the compile_commands.json.
    CompileCommandFilter flagFilter;

    /// If files should be deduplicated thus only unique files are analyzed.
    bool dedupFiles;
}

/// Settings for the compiler
struct Compiler {
    import compile_db : SystemCompiler = Compiler;

    /// Additional flags the user wants to add besides those that are in the compile_commands.json.
    /// This is intended to be set by a centralized configuration.
    string[] flags;

    /// Additional flags the user wants to add besides those that are in the compile_commands.json.
    /// This is intended to be set locally by a user which act in addition to the centralized flags.
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

    /// Progress info levels
    Set!Progress progress;

    /// If set write a json log
    AbsolutePath jsonFile;
}

/// Configuration of how to use the program.
struct Config {
    AppMode mode;

    /// System default configuration.
    AbsolutePath systemConf;

    /// Working directory as specified by the user.
    AbsolutePath workDir;

    /// Configuration file as specified by the user or the default one.
    AbsolutePath confFile;

    AbsolutePath database;

    ConfigClangTidy clangTidy;
    ConfigCompileDb compileDb;
    ConfigIwyu iwyu;
    ConfigStaticCode staticCode;

    Compiler compiler;
    Logging logg;

    /// Template to use when initializing a new config
    string initTemplate = "default";

    /// If set then only analyze these files.
    AbsolutePath[] analyzeFiles;
    /// If set then all files are analyzed, ignoring the change based algorithm.
    bool runOnAllFiles;

    /// Returns: a config object with default values.
    static Config make(AbsolutePath workDir, AbsolutePath confFile) @safe {
        import compile_db : defaultCompilerFlagFilter, CompileCommandFilter;

        Config c;
        c.workDir = workDir;
        c.confFile = confFile;
        c.compileDb.flagFilter = CompileCommandFilter(defaultCompilerFlagFilter, 0);

        return c;
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
    import std.format : format;
    import std.traits : EnumMembers;
    import code_checker.engine.types : Severity;
    import colorlog : VerboseMode;
    static import std.getopt;

    bool verbose_info;
    bool verbose_trace;
    std.getopt.GetoptResult help_info;
    try {
        Progress[] progress;
        bool initConf;
        string database;
        string dummyValue;
        string jsonFile;
        string logdir = ".";
        string workdir;
        string[] analyzeFiles;
        string[] analyzers;
        string[] compileDbs;

        // dfmt off
        help_info = std.getopt.getopt(args,
            "a|analyzer", "Analysers to run", &analyzers,
            "clang-tidy-bin", "clang-tidy binary to use", &conf.clangTidy.binary,
            "clang-tidy-fix", "apply suggested clang-tidy fixes", &conf.clangTidy.applyFixit,
            "clang-tidy-fix-errors", "apply suggested clang-tidy fixes even if they result in compilation errors", &conf.clangTidy.applyFixitErrors,
            "compile-db", "path to a compilationi database or where to search for one", &compileDbs,
            "c|config", format!"load configuration (default: %s)"(MiniConfig.init.rawConfFile), &dummyValue,
            "db|database", "Database path", &database,
            "f|file", "if set then analyze only these files (default: all)", &analyzeFiles,
            "init", "create an initial config to use", &initConf,
            "init-template", "path to a config to use as the template", &conf.initTemplate,
            "iwyu-bin", "iwyu binary to use", &conf.iwyu.binary,
            "iwyu-map", "give iwyu one or more mapping files", &conf.iwyu.maps,
            "log", "create a logfile for each analyzed file", &conf.logg.toFile,
            "log-dir", "path to create logfiles in (default: .)", &logdir,
            "log-json", "write the report to a json file", &jsonFile,
            "progress", format!"verbosity of the progress information (%-(%s,%))"([EnumMembers!Progress]), &progress,
            "severity", format("report issues with a severity >= to this value (default: style) %s", [EnumMembers!Severity]), &conf.staticCode.severity,
            "v|verbose", format("verbose mode is set to trace (%-(%s,%))", [EnumMembers!VerboseMode]), &conf.logg.verbose,
            "workdir", "use this path as the working directory when programs used by analyzers are executed (default: .)", &workdir,
            );
        // dfmt on
        conf.mode = AppMode.normal;
        if (help_info.helpWanted)
            conf.mode = AppMode.help;
        else if (initConf)
            conf.mode = AppMode.initConfig;

        conf.logg.progress = progress.toSet;
        if (!jsonFile.empty)
            conf.logg.jsonFile = AbsolutePath(jsonFile);
        if (conf.logg.toFile)
            conf.logg.dir = Path(logdir).AbsolutePath;

        if (conf.clangTidy.applyFixitErrors || conf.clangTidy.applyFixit)
            conf.runOnAllFiles = true;

        // use a sane default which is to look in the current directory
        if (compileDbs.length == 0 && conf.compileDb.dbs.length == 0) {
            compileDbs = ["./compile_commands.json"];
        } else if (compileDbs.length != 0) {
            conf.compileDb.rawDbs = compileDbs;
        }

        if (!analyzers.empty)
            conf.staticCode.analyzers = analyzers;

        if (conf.database.empty && database.empty)
            conf.database = "code_checker.sqlite3".AbsolutePath;
        else if (!database.empty)
            conf.database = AbsolutePath(database);

        // dfmt off
        conf.compileDb.dbs = conf
            .compileDb.rawDbs
            .filter!(a => a.length != 0)
            .map!(a => Path(buildPath(conf.workDir, a)).AbsolutePath)
            .array;
        // dfmt on

        conf.analyzeFiles = analyzeFiles.map!(a => Path(buildPath(conf.workDir,
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

TOMLDocument loadToml(AbsolutePath fname) @trusted {
    import std.file : exists, readText;
    import toml : parseTOML;

    if (exists(fname)) {
        auto txt = readText(fname.toString);
        return parseTOML(txt);
    }

    throw new Exception("file " ~ fname ~ " do not exist");
}

string parseSystemConf(ref TOMLDocument doc, string fallback) @trusted {
    if (auto section = "defaults" in doc) {
        if (auto field = "system_config" in *section) {
            try {
                return field.str;
            } catch (Exception e) {
                logger.warning(e.msg);
            }
        }
    }

    return fallback;
}

/** Load the configuration from file.
 *
 * Example of a TOML configuration
 * ---
 * [defaults]
 * check_name_standard = true
 * ---
 */
void loadConfig(ref Config rval, ref TOMLDocument doc) @trusted {
    import std.algorithm : map;
    import toml;

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
            c.staticCode.severity = s.get;
        }
    }

    callbacks["defaults.severity"] = &defaults__check_name_standard;
    callbacks["defaults.system_config"] = (ref Config c, ref TOMLValue v) {
        import code_checker.utility : replaceConfigWord;

        c.systemConf = v.str.replaceConfigWord.AbsolutePath;
    };
    callbacks["defaults.analyzers"] = (ref Config c, ref TOMLValue v) {
        c.staticCode.analyzers = v.array.map!"a.str".array;
    };
    callbacks["defaults.database"] = (ref Config c, ref TOMLValue v) {
        c.database = v.str.AbsolutePath;
    };

    callbacks["compile_commands.search_paths"] = (ref Config c, ref TOMLValue v) {
        c.compileDb.rawDbs = v.array.map!"a.str".array;
    };
    callbacks["compile_commands.generate_cmd"] = (ref Config c, ref TOMLValue v) {
        c.compileDb.generateDb = v.str;
    };
    callbacks["compile_commands.generate_cmd_deps"] = (ref Config c, ref TOMLValue v) {
        try {
            c.compileDb.generateDbDeps = v.array
                .map!"a.str"
                .map!(a => AbsolutePath(a))
                .array;
        } catch (Exception e) {
            logger.warning(e.msg);
        }
    };
    callbacks["compile_commands.exclude"] = (ref Config c, ref TOMLValue v) {
        c.staticCode.fileExcludeFilter = v.array.map!"a.str".array;
    };
    callbacks["compile_commands.include"] = (ref Config c, ref TOMLValue v) {
        c.staticCode.fileIncludeFilter = v.array.map!"a.str".array;
    };
    callbacks["compile_commands.filter"] = (ref Config c, ref TOMLValue v) {
        import compile_db : FilterClangFlag;

        c.compileDb.flagFilter.filter = v.array.map!(a => FilterClangFlag(a.str)).array;
    };
    callbacks["compile_commands.skip_compiler_args"] = (ref Config c, ref TOMLValue v) {
        c.compileDb.flagFilter.skipCompilerArgs = cast(int) v.integer;
    };
    callbacks["compile_commands.dedup"] = (ref Config c, ref TOMLValue v) {
        c.compileDb.dedupFiles = v == true;
    };

    callbacks["clang_tidy.binary"] = (ref Config c, ref TOMLValue v) {
        c.clangTidy.binary = v.str;
    };
    callbacks["clang_tidy.header_filter"] = (ref Config c, ref TOMLValue v) {
        c.clangTidy.headerFilter = v.str;
    };
    callbacks["clang_tidy.checks"] = (ref Config c, ref TOMLValue v) {
        logger.warning("clang_tidy.checks is deprecated. It is replaced by ",
                c.clangTidy.systemConfig);
    };
    callbacks["clang_tidy.check_extensions"] = (ref Config c, ref TOMLValue v) {
        c.clangTidy.checkExtensions = v.array.map!(a => a.str).array;
    };
    callbacks["clang_tidy.options"] = (ref Config c, ref TOMLValue v) {
        logger.warning("clang_tidy.options is deprecated. It is replaced by ",
                c.clangTidy.systemConfig);
    };
    callbacks["clang_tidy.option_extensions"] = (ref Config c, ref TOMLValue v) {
        // dummo to suppress warning about unknown key
    };
    callbacks["clang_tidy.system_config"] = (ref Config c, ref TOMLValue v) {
        c.clangTidy.systemConfig = v.str;
    };

    callbacks["compiler.flags"] = (ref Config c, ref TOMLValue v) {
        c.compiler.flags = v.array.map!(a => a.str).array;
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
    callbacks["iwyu.mapping_files"] = (ref Config c, ref TOMLValue v) {
        c.iwyu.maps = v.array.map!(a => a.str).array;
    };
    callbacks["iwyu.default_mapping_files"] = (ref Config c, ref TOMLValue v) {
        c.iwyu.defaultMaps = v.array.map!(a => a.str).array;
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

    if (auto section = "clang_tidy" in doc)
        rval.clangTidy.optionExtensions = parseDict(*section, "option_extensions");
}

string[string] parseDict(ref TOMLValue root, string section) @trusted {
    import toml;

    typeof(return) rval;

    if (section !in root)
        return rval;

    foreach (k, s; *(section in root)) {
        try {
            rval[k] = s.str;
        } catch (Exception e) {
            logger.warningf("error in %s: %s", section, e.msg);
        }
    }

    return rval;
}
