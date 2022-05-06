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

    void print() @safe nothrow const scope {
        import std.ascii : newline;
        import std.stdio : writeln;

        foreach (l; stdout) {
            writeln(l).collectException;
        }
        foreach (l; stderr) {
            writeln(l).collectException;
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

    auto app_out = appender!(string[])();
    auto app_err = appender!(string[])();

    auto p = pipeProcess(cmd, Redirect.all);
    int exit_status = -1;

    const stopAt = Clock.currTime + timeout;
    while (Clock.currTime < stopAt) {
        auto pres = p.pid.tryWait;

        p.stdout.byLineCopy.copy(app_out);
        p.stderr.byLineCopy.copy(app_err);

        if (pres.terminated) {
            exit_status = pres.status;
            break;
        }

        Thread.sleep(25.dur!"msecs");
    }

    if (Clock.currTime >= stopAt) {
        import core.sys.posix.signal : SIGKILL;
        import std.process : kill;

        kill(p.pid, SIGKILL);
    }

    return RunResult(exit_status, app_out.data, app_err.data);
}
