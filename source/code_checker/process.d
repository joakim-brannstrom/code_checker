/**
Copyright: Copyright (c) 2018, Joakim Brännström. All rights reserved.
License: $(LINK2 http://www.boost.org/LICENSE_1_0.txt, Boost Software License 1.0)
Author: Joakim Brännström (joakim.brannstrom@gmx.com)
*/
module code_checker.process;

import std.datetime : dur, Duration, Clock;
import std.exception : collectException;

import logger = std.experimental.logger;

immutable int exitCodeSegFault = -11;

struct RunResult {
    int status;
    string[] stdout;
    string[] stderr;

    /// true if a timeout triggered.
    bool timeout;

    void print() @safe nothrow const scope {
        import std.ascii : newline;
        import std.stdio : writeln;

        foreach (l; stdout) {
            try {
                writeln(l);
            } catch (Exception e) {
            }
        }
        foreach (l; stderr) {
            try {
                writeln(l);
            } catch (Exception e) {
            }
        }
    }
}

RunResult run(string[] cmd, Duration timeout = 10.dur!"minutes") @trusted {
    import std.array : appender;
    import std.algorithm : joiner, copy;
    import std.ascii : newline;
    import std.process : pipeProcess, tryWait, Redirect;
    import std.stdio : writeln;
    import core.thread : Thread;
    import core.time : dur;

    logger.trace("run: ", cmd.joiner(" "));

    RunResult rval;
    rval.status = -1;

    auto app_out = appender!(string[])();
    auto app_err = appender!(string[])();

    auto p = pipeProcess(cmd, Redirect.all);

    const stopAt = Clock.currTime + timeout;
    while (Clock.currTime < stopAt) {
        auto pres = p.pid.tryWait;

        p.stdout.byLineCopy.copy(app_out);
        p.stderr.byLineCopy.copy(app_err);

        if (pres.terminated) {
            rval.status = pres.status;
            break;
        }

        Thread.sleep(25.dur!"msecs");
    }

    if (Clock.currTime >= stopAt) {
        import core.sys.posix.signal : SIGKILL;
        import std.process : kill;

        kill(p.pid, SIGKILL);
        rval.timeout = true;
    }

    rval.stdout = app_out.data;
    rval.stderr = app_err.data;

    return rval;
}
