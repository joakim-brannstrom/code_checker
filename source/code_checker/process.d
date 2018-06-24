/**
Copyright: Copyright (c) 2018, Joakim Brännström. All rights reserved.
License: $(LINK2 http://www.boost.org/LICENSE_1_0.txt, Boost Software License 1.0)
Author: Joakim Brännström (joakim.brannstrom@gmx.com)
*/
module code_checker.process;

import logger = std.experimental.logger;

int run(string[] cmd) @trusted {
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

    while (true) {
        auto pres = p.pid.tryWait;

        p.stdout.byLineCopy.copy(app_out);
        p.stderr.byLineCopy.copy(app_err);

        if (pres.terminated) {
            exit_status = pres.status;
            break;
        }

        Thread.sleep(25.dur!"msecs");
    }

    if (exit_status != 0) {
        writeln(app_out.data.joiner(newline));
        writeln(app_err.data.joiner(newline));
    } else {
        logger.trace("stdout: ", app_out.data.joiner(newline));
        logger.trace("stderr: ", app_err.data.joiner(newline));
    }

    return exit_status;
}
