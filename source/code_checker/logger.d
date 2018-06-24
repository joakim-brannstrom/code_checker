/**
Copyright: Copyright (c) 2017, Joakim Brännström. All rights reserved.
License: MPL-2
Author: Joakim Brännström (joakim.brannstrom@gmx.com)

This Source Code Form is subject to the terms of the Mozilla Public License,
v.2.0. If a copy of the MPL was not distributed with this file, You can obtain
one at http://mozilla.org/MPL/2.0/.

Handles console logging in pretty colors.

The module disables colors when stdout and stderr isn't a TTY that support
colors. This is to avoid ASCII escape sequences in piped output.

Credit goes to the developers of Dub. A significant part of the color handling
is copied from that project.
*/
module code_checker.logger;

import std.algorithm : among;
import std.stdio : writeln, writefln, stderr, stdout;
import logger = std.experimental.logger;
import std.experimental.logger : LogLevel;

import colorize : Color, Background, Mode;

/// The verbosity level of the logging to use.
enum VerboseMode {
    /// Warning+
    minimal,
    /// Info+
    info,
    /// Trace+
    trace,
    /// Warnings+
    warning,
}

void confLogger(VerboseMode mode) {
    switch (mode) {
    case VerboseMode.info:
        logger.globalLogLevel = logger.LogLevel.info;
        logger.sharedLog = new SimpleLogger(logger.LogLevel.info);
        break;
    case VerboseMode.trace:
        logger.globalLogLevel = logger.LogLevel.all;
        logger.sharedLog = new DebugLogger(logger.LogLevel.all);
        logger.info("Debug mode activated");
        break;
    case VerboseMode.warning:
        logger.globalLogLevel = logger.LogLevel.warning;
        logger.sharedLog = new SimpleLogger(logger.LogLevel.info);
        break;
    default:
        logger.globalLogLevel = logger.LogLevel.info;
        logger.sharedLog = new SimpleLogger(logger.LogLevel.info);
    }
}

private:

/**
 * Whether to print text with colors or not, defaults to true but will be set
 * to false in initLogging() if stdout or stderr are not a TTY (which means the
 * output is probably being piped and we don't want ASCII escape chars in it)
*/
shared bool _printColors = true;
shared bool _isColorsInitialized = false;

// isatty() is used in initLogging() to detect whether or not we are on a TTY
extern (C) int isatty(int);

// The width of the prefix.
immutable _prefixWidth = 8;

/**
 * It will detect whether or not stdout/stderr are a console/TTY and will
 * consequently disable colored output if needed.
 *
 * Forgetting to call the function will result in ASCII escape sequences in the
 * piped output, probably an undesiderable thing.
 */
void initLogging() @trusted {
    import core.stdc.stdio;

    if (_isColorsInitialized)
        return;
    scope (exit)
        _isColorsInitialized = true;

    // Initially enable colors, we'll disable them during this functions if we
    // find any reason to
    _printColors = true;

    import core.sys.posix.unistd;

    if (!isatty(STDERR_FILENO) || !isatty(STDOUT_FILENO))
        _printColors = false;
}

class SimpleLogger : logger.Logger {
    this(const LogLevel lvl = LogLevel.warning) @safe {
        super(lvl);
        initLogging;
    }

    override void writeLogMsg(ref LogEntry payload) @trusted {
        auto out_ = stderr;
        auto use_color = Color.red;
        auto use_mode = Mode.bold;
        const use_bg = Background.black;

        switch (payload.logLevel) {
        case LogLevel.trace:
            out_ = stdout;
            use_color = Color.white;
            use_mode = Mode.init;
            break;
        case LogLevel.info:
            out_ = stdout;
            use_color = Color.white;
            break;
        default:
        }

        import std.conv : to;
        import colorize;

        out_.writefln("%s: %s", payload.logLevel.to!string.color(use_color,
                use_bg, use_mode), payload.msg);
    }
}

class DebugLogger : logger.Logger {
    this(const logger.LogLevel lvl = LogLevel.trace) {
        super(lvl);
        initLogging;
    }

    override void writeLogMsg(ref LogEntry payload) @trusted {
        auto out_ = stderr;
        auto use_color = Color.red;
        auto use_mode = Mode.bold;
        const use_bg = Background.black;

        switch (payload.logLevel) {
        case LogLevel.trace:
            out_ = stdout;
            use_color = Color.white;
            use_mode = Mode.init;
            break;
        case LogLevel.info:
            out_ = stdout;
            use_color = Color.white;
            break;
        default:
        }

        import std.conv : to;
        import colorize;

        out_.writefln("%s: %s [%s:%d]", payload.logLevel.to!string.color(use_color,
                use_bg, use_mode), payload.msg, payload.funcName, payload.line);
    }
}
