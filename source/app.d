/**
Copyright: Copyright (c) 2018, Joakim Brännström. All rights reserved.
License: $(LINK2 http://www.boost.org/LICENSE_1_0.txt, Boost Software License 1.0)
Author: Joakim Brännström (joakim.brannstrom@gmx.com)

This is the main application file.
*/
module app;

import std.algorithm : among;
import std.exception : collectException;
import std.typecons : Flag, Yes, No, Nullable;
import logger = std.experimental.logger;

import compile_db : CompileCommandDB;
import my.path : AbsolutePath, Path;

import code_checker.cli : Config;

int main(string[] args) {
    import std.file : thisExePath, exists;
    import std.format : format;
    import std.functional : toDelegate;
    import std.path : buildPath;
    import code_checker.cli : AppMode, parseCLI, parseConfigCLI, loadConfig,
        Config, MiniConfig, loadToml, parseSystemConf;
    import code_checker.utility : replaceConfigWord;
    import colorlog;
    import toml : TOMLDocument;
    import my.profile;
    import app_normal;
    import code_checker.engine.builtin.clang_tidy_classification : initClassification;

    string[] traceMsg;

    auto conf = () {
        confLogger(VerboseMode.info);

        Nullable!Config conf;

        MiniConfig miniConf;
        try {
            miniConf = parseConfigCLI(args);
        } catch (Exception e) {
            logger.error(e.msg);
            // TODO: should actually terminate...
            return conf;
        }

        TOMLDocument localToml;
        try {
            if (miniConf.confFile.exists) {
                localToml = loadToml(miniConf.confFile);
                traceMsg ~= format("reading local config %s", miniConf.confFile);
            } else {
                logger.info("Configuration do not exist: ", miniConf.confFile);
            }
        } catch (Exception e) {
            logger.warning(e.msg);
            logger.error("Unable to read local configuration: ", miniConf.confFile);
            return conf;
        }

        auto systemConfPath = () {
            import std.path : dirName;

            auto default_ = buildPath("{code_checker}", "..", "etc",
                    "code_checker", "default.toml");
            try {
                return parseSystemConf(localToml, default_);
            } catch (Exception e) {
                logger.warning(e.msg);
            }
            return default_;
        }().replaceConfigWord.AbsolutePath;

        TOMLDocument systemToml;
        try {
            systemToml = loadToml(systemConfPath);
            traceMsg ~= format("Reading system config %s", systemConfPath);
        } catch (Exception e) {
            logger.warning(e.msg);
            logger.error("Unable to read system configuration: ", systemConfPath);
            return conf;
        }

        try {
            conf = Config.make(miniConf.workDir, miniConf.confFile);
            conf.get.systemConf = systemConfPath;
            loadConfig(conf.get, systemToml);
            loadConfig(conf.get, localToml);

            auto clangTidyClassPath = (conf.get.systemConf.dirName ~ "clang-tidy.json")
                .AbsolutePath;
            initClassification(clangTidyClassPath);
            traceMsg ~= format("reading clang-tidy classification data %s", clangTidyClassPath);
        } catch (Exception e) {
            logger.warning(e.msg);
            logger.error("Unable to parse configuration");
        }
        return conf;
    }();
    if (conf.isNull)
        return 1;

    parseCLI(args, conf.get);
    confLogger(conf.get.logg.verbose);
    logger.trace(conf.get);
    logger.trace(traceMsg);
    traceMsg = null;

    alias Command = int delegate(Config conf);
    Command[AppMode] cmds;
    cmds[AppMode.none] = toDelegate(&modeNone);
    cmds[AppMode.help] = toDelegate(&modeNone);
    cmds[AppMode.helpUnknownCommand] = toDelegate(&modeNone_Error);
    cmds[AppMode.normal] = toDelegate(&modeNormal);
    cmds[AppMode.initConfig] = toDelegate(&modeInitConfig);
    cmds[AppMode.include] = toDelegate(&modeHeaderInfo);

    scope (success)
        logger.trace(getProfileResult.toString);

    if (auto v = conf.get.mode in cmds) {
        return (*v)(conf.get);
    }

    logger.error("Unknown mode %s", conf.get.mode);
    return 1;
}

int modeNone(Config conf) {
    return 0;
}

int modeNone_Error(Config conf) {
    return 1;
}

int modeInitConfig(Config conf) {
    import std.file : exists, copy;
    import std.path : buildPath;

    if (exists(conf.confFile)) {
        logger.error("Configuration file already exists: ", conf.confFile);
        return 1;
    }

    string tmpl;
    if (exists(conf.initTemplate)) {
        tmpl = conf.initTemplate;
    } else {
        tmpl = buildPath(conf.systemConf.dirName, conf.initTemplate ~ "_template.toml");
        if (!exists(tmpl)) {
            logger.error("Configuration template do not exist: ", tmpl);
            return 1;
        }
    }

    try {
        copy(tmpl, cast(string) conf.confFile);
        logger.info("Wrote configuration to ", conf.confFile);
    } catch (Exception e) {
        logger.error(e.msg);
        return 1;
    }

    return 0;
}

int modeHeaderInfo(Config conf) {
    import std.json : JSONValue, JSONOptions;
    import std.stdio : File;
    import std.file : mkdirRecurse;
    import code_checker.database;
    import std.algorithm : map, filter;
    import miniorm : spinSql;

    Database db;
    try {
        db = Database.make(conf.database);
    } catch (Exception e) {
        logger.warning(e.msg);
        return 1;
    }

    JSONValue json;
    JSONValue roots;
    ulong[Path] summary;

    foreach (root; spinSql!(() => db.fileApi.getRootFiles).map!(
            a => spinSql!(() => db.fileApi.getFile(a)))
            .filter!(a => !a.isNull)
            .map!(a => a.get.file)) {
        auto deps = db.dependencyApi.get(root);
        summary[root] = deps.length;
        roots[root] = deps;
    }
    json["summary"] = summary;
    json["files"] = roots;

    mkdirRecurse(conf.logg.dir);
    const infoFile = conf.logg.dir ~ "includes.json";
    File(infoFile.toString, "w").writeln(
            json.toPrettyString(JSONOptions.doNotEscapeSlashes));
    logger.info("Info written to ", infoFile);
    return 0;
}
