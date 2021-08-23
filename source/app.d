/**
Copyright: Copyright (c) 2018, Joakim Brännström. All rights reserved.
License: $(LINK2 http://www.boost.org/LICENSE_1_0.txt, Boost Software License 1.0)
Author: Joakim Brännström (joakim.brannstrom@gmx.com)

This is the main application file.
*/
module app;

import std.algorithm : among;
import std.exception : collectException;
import std.typecons : Flag, Yes, No;
import logger = std.experimental.logger;

import code_checker.cli : Config;
import compile_db : CompileCommandDB;
import code_checker.types : AbsolutePath, Path, AbsoluteFileName;

int main(string[] args) {
    import std.file : thisExePath, exists;
    import std.functional : toDelegate;
    import std.path : buildPath;
    import code_checker.cli : AppMode, parseCLI, parseConfigCLI, loadConfig, Config;
    import colorlog;
    import app_normal;

    auto conf = () {
        Config conf;
        try {
            confLogger(VerboseMode.info);
            auto miniConf = parseConfigCLI(args);
            conf = Config.make(miniConf.workDir, miniConf.confFile);
            if (exists(conf.baseUserConf)) {
                loadConfig(conf, conf.baseUserConf);
            } else {
                logger.trace("No default configuration for code_checker found at: ",
                        conf.baseUserConf);
            }
            loadConfig(conf, miniConf.confFile);
        } catch (Exception e) {
            logger.warning(e.msg);
            logger.error("Unable to read configuration: ", conf.confFile);
        }
        return conf;
    }();
    parseCLI(args, conf);
    confLogger(conf.logg.verbose);
    logger.trace(conf);

    alias Command = int delegate(Config conf);
    Command[AppMode] cmds;
    cmds[AppMode.none] = toDelegate(&modeNone);
    cmds[AppMode.help] = toDelegate(&modeNone);
    cmds[AppMode.helpUnknownCommand] = toDelegate(&modeNone_Error);
    cmds[AppMode.normal] = toDelegate(&modeNormal);
    cmds[AppMode.initConfig] = toDelegate(&modeInitConfig);

    if (auto v = conf.mode in cmds) {
        return (*v)(conf);
    }

    logger.error("Unknown mode %s", conf.mode);
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
    import std.path : stripExtension;

    if (exists(conf.confFile)) {
        logger.error("Configuration file already exists: ", conf.confFile);
        return 1;
    }

    const tmpl = conf.baseUserConf.stripExtension ~ "_template.toml";
    if (!exists(tmpl)) {
        logger.error("Configuration template do not exist: ", tmpl);
        return 1;
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
