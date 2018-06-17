/**
Copyright: Copyright (c) 2018, Joakim Brännström. All rights reserved.
License: $(LINK2 http://www.boost.org/LICENSE_1_0.txt, Boost Software License 1.0)
Author: Joakim Brännström (joakim.brannstrom@gmx.com)
*/
module app;

import std.algorithm : among;

import logger = std.experimental.logger;

int main(string[] args) {
    Config conf;

    parseCLI(args, conf);

    final switch (conf.mode) {
    case AppMode.none:
        return 0;
    case AppMode.help:
        return 0;
    case AppMode.helpUnknownCommand:
        return 1;
    }
}

enum AppMode {
    none,
    help,
    helpUnknownCommand,
}

struct Config {
    AppMode mode;
}

void parseCLI(string[] args, ref Config conf) {
    static import std.getopt;

    int dummy;
    std.getopt.GetoptResult help_info;
    try {
        // dfmt off
        help_info = std.getopt.getopt(args,
            std.getopt.config.keepEndOfOptions,
            "x", "dummy", &dummy,
            );
        // dfmt on
        conf.mode = help_info.helpWanted ? AppMode.help : AppMode.none;
    } catch (std.getopt.GetOptException e) {
        // unknown option
        logger.error(e.msg);
        conf.mode = AppMode.helpUnknownCommand;
    } catch (Exception e) {
        logger.error(e.msg);
        conf.mode = AppMode.helpUnknownCommand;
    }

    logger.trace(conf);

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
