/**
Copyright: Copyright (c) 2018, Joakim Brännström. All rights reserved.
License: $(LINK2 http://www.boost.org/LICENSE_1_0.txt, Boost Software License 1.0)
Author: Joakim Brännström (joakim.brannstrom@gmx.com)
*/
module code_checker.process;

import logger = std.experimental.logger;

int run(string[] cmd) @trusted {
    import std.algorithm : joiner;
    import std.process : spawnProcess, wait;

    logger.trace("run: ", cmd.joiner(" "));
    return spawnProcess(cmd).wait;
}
