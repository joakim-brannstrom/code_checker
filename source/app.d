/**
Copyright: Copyright (c) 2018, Joakim Brännström. All rights reserved.
License: $(LINK2 http://www.boost.org/LICENSE_1_0.txt, Boost Software License 1.0)
Author: Joakim Brännström (joakim.brannstrom@gmx.com)
*/
module app;

import std.algorithm : among;

import logger = std.experimental.logger;

int main(string[] args) {
    import std.functional : toDelegate;
    import code_checker.logger;

    Config conf;
    parseCLI(args, conf);
    confLogger(conf.verbose);
    logger.trace(conf);

    alias Command = int delegate(const ref Config conf);
    Command[AppMode] cmds;
    cmds[AppMode.none] = toDelegate(&modeNone);
    cmds[AppMode.help] = toDelegate(&modeNone);
    cmds[AppMode.helpUnknownCommand] = toDelegate(&modeNone_Error);

    if (auto v = conf.mode in cmds) {
        return (*v)(conf);
    }

    logger.error("Unknown mode %s", conf.mode);

    return 1;
}

int modeNone(const ref Config conf) {
    return 0;
}

int modeNone_Error(const ref Config conf) {
    return 1;
}

enum AppMode {
    none,
    help,
    helpUnknownCommand,
}

struct Config {
    import code_checker.logger : VerboseMode;

    AppMode mode;
    VerboseMode verbose;
}

void parseCLI(string[] args, ref Config conf) {
    import code_checker.logger : VerboseMode;
    static import std.getopt;

    bool verbose_info;
    bool verbose_trace;
    std.getopt.GetoptResult help_info;
    try {
        // dfmt off
        help_info = std.getopt.getopt(args,
            std.getopt.config.keepEndOfOptions,
            "v|verbose", "verbose mode is set to information", &verbose_info,
            "vverbose", "verbose mode is set to trace", &verbose_trace,
            );
        // dfmt on
        conf.mode = help_info.helpWanted ? AppMode.help : AppMode.none;
        conf.verbose = () {
            if (verbose_trace)
                return VerboseMode.trace;
            if (verbose_info)
                return VerboseMode.info;
            return VerboseMode.minimal;
        }();
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
