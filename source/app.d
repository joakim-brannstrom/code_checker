/**
Copyright: Copyright (c) 2018, Joakim Brännström. All rights reserved.
License: $(LINK2 http://www.boost.org/LICENSE_1_0.txt, Boost Software License 1.0)
Author: Joakim Brännström (joakim.brannstrom@gmx.com)
*/
module app;

import std.algorithm : among;
import std.exception : collectException;
import std.typecons : Flag, Yes, No;
import logger = std.experimental.logger;

import code_checker.cli : Config;
import code_checker.compile_db : CompileCommandDB;
import code_checker.types : AbsolutePath, Path, AbsoluteFileName;

int main(string[] args) {
    import std.functional : toDelegate;
    import code_checker.cli : AppMode, parseCLI, parseConfigCLI, loadConfig,
        Config;
    import code_checker.logger;
    import app_normal;

    auto conf = () {
        auto conf = Config.make();
        try {
            confLogger(VerboseMode.info);
            conf.miniConf = parseConfigCLI(args);
            loadConfig(conf);
        } catch (Exception e) {
            logger.warning(e.msg);
            logger.warning("Unable to read configuration");
        }
        return conf;
    }();
    parseCLI(args, conf);
    confLogger(conf.logg.verbose);
    logger.trace(conf);

    alias Command = int delegate(ref Config conf);
    Command[AppMode] cmds;
    cmds[AppMode.none] = toDelegate(&modeNone);
    cmds[AppMode.help] = toDelegate(&modeNone);
    cmds[AppMode.helpUnknownCommand] = toDelegate(&modeNone_Error);
    cmds[AppMode.normal] = toDelegate(&modeNormal);
    cmds[AppMode.initConfig] = toDelegate(&modeInitConfig);
    cmds[AppMode.dumpConfig] = toDelegate(&modeDumpFullConfig);

    if (auto v = conf.mode in cmds) {
        return (*v)(conf);
    }

    logger.error("Unknown mode %s", conf.mode);
    return 1;
}

int modeNone(ref Config conf) {
    return 0;
}

int modeNone_Error(ref Config conf) {
    return 1;
}

int modeInitConfig(ref Config conf) {
    import std.stdio : File;
    import std.file : exists;

    if (exists(conf.miniConf.confFile)) {
        logger.error("Configuration file already exists: ", conf.miniConf.confFile);
        return 1;
    }

    try {
        File(conf.miniConf.confFile, "w").write(conf.toTOML(No.fullConfig));
        logger.info("Wrote configuration to ", conf.miniConf.confFile);
        return 0;
    } catch (Exception e) {
        logger.error(e.msg);
    }

    return 1;
}

int modeDumpFullConfig(ref Config conf) {
    import std.stdio : writeln, stderr;

    // make it easy for a user to pipe the output to the confi file
    stderr.writeln("Dumping the configuration used. The format is TOML (.toml)");
    stderr.writeln("If you want to use it put it in your '.code_checker.toml'");

    writeln(conf.toTOML(Yes.fullConfig));

    return 0;
}
