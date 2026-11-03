/**
Copyright: Copyright (c) 2018, Joakim Brännström. All rights reserved.
License: $(LINK2 http://www.boost.org/LICENSE_1_0.txt, Boost Software License 1.0)
Author: Joakim Brännström (joakim.brannstrom@gmx.com)
*/
module code_checker.process;

import std.datetime : dur, Duration, Clock;

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

/// Runs the command $(D cmd) and captures its stdout and stderr.
///
/// Concurrency model: stdout and stderr are drained concurrently by ONE
/// thread via a poll + raw-read loop over the two pipes' file descriptors
/// (read directly via $(D File.fileno), the $(D FILE*) buffers are left
/// untouched). The output is buffered raw and split into lines once at the
/// end by the internal $(D splitLines) helper, which byte-matches
/// $(D std.stdio.byLineCopy): the $(D '\n') terminator is stripped,
/// $(D '\r') is retained, a trailing unterminated line is kept, and empty
/// output yields zero lines.
///
/// Timeout guarantee: returns at most $(D timeout) in total (measured from
/// spawn), even if the child keeps producing output until the deadline. The
/// deadline is enforced by $(D poll)'s timeout (no busy-wait sleep), with
/// only poll-granularity slack: a child exiting within the final poll window
/// may be reported as timed out (the kill fires on an exited-but-unreaped
/// zombie, which POSIX permits). Only poll-granularity slack remains. Except
/// in the grandchild-holding-fds case documented below, where the drain loop
/// can exceed the deadline.
///
/// Post-SIGKILL status: on the timeout path, $(D status) is the reaped,
/// signal-negative exit status of the SIGKILLed child (typically -9),
/// distinct from $(D exitCodeSegFault) (-11) so the segfault retry is
/// unaffected.
///
/// Partial output collected before the deadline is always returned.
///
/// Documented limitation: there is NO bound on the collected output size --
/// a pathological child can still balloon memory until the deadline.
///
/// stdin: the child's stdin pipe is closed immediately after the spawn; a
/// child reading stdin sees EOF instead of blocking.
///
/// Failure containment: any failure after the spawn (poll/read errors,
/// allocation) SIGKILLs and reaps the child before propagating -- a
/// throwing $(D run) never leaks a running child or open pipes.
///
/// Documented limitation: if the killed child forked a grandchild that
/// inherited and holds the pipe fds, EOF (and thus the drain loop) can be
/// delayed past the timeout (the loop keeps polling with the bounded
/// post-kill quantum). Out of scope for clang-tidy/iwyu invocations.
///
/// Params:
///     cmd = command to run
///     timeout = how long the child may run before it is killed
///
/// Returns: the child's $(D RunResult); see $(D RunResult).
// @trusted because of the raw poll/read calls on the child's fds.
RunResult run(string[] cmd, Duration timeout = 10.dur!"minutes") @trusted {
    import core.stdc.errno : EINTR, errno;
    import core.sys.posix.poll : POLLERR, POLLHUP, POLLIN, poll, pollfd;
    import core.sys.posix.signal : SIGKILL;
    import core.sys.posix.unistd : read;
    import std.algorithm.comparison : max, min;
    import std.algorithm.iteration : joiner;
    import std.array : Appender, appender;
    import std.conv : to;
    import std.exception : collectException;
    import std.process : Redirect, kill, pipeProcess, tryWait, wait;

    logger.trace("run: ", cmd.joiner(" ")).collectException;

    RunResult rval;
    rval.status = -1;

    auto p = pipeProcess(cmd, Redirect.all);

    // Anything failing after the spawn (poll/read errors, allocation) would
    // leak the child together with its open pipes: kill + reap it before the
    // exception propagates.
    scope (failure) {
        kill(p.pid, SIGKILL).collectException;
        p.pid.wait().collectException;
    }

    // The loggable pid number: the Pid object itself is invalidated by the
    // wait() below (its processID resets to invalid), so capture the number
    // while it is still valid.
    const pidNum = p.pid.processID;

    // Close the child's stdin immediately: clang-tidy and iwyu never read
    // stdin, but a future child that does would otherwise block forever on
    // this never-closed pipe.
    p.stdin.close();

    Appender!(string)[2] raw; // per-stream raw bytes; split once at the end
    bool[2] eof;
    bool reaped;
    bool killed;

    const fd_out = p.stdout.fileno;
    const fd_err = p.stderr.fileno;
    pollfd[2] fds = [pollfd(fd_out, POLLIN, 0), pollfd(fd_err, POLLIN, 0)];

    const stopAt = Clock.currTime + timeout;
    while (!eof[0] || !eof[1]) {
        if (!reaped) {
            // Fresh each iteration; its only remaining job is setting the
            // reaped flag: the status it observes is never used here (the
            // blocking wait after the loop is the single source of truth for
            // status on both the normal and the timeout path).
            auto pres = p.pid.tryWait;
            reaped = pres.terminated;
        }

        if (!reaped && Clock.currTime >= stopAt) {
            kill(p.pid, SIGKILL);
            killed = true;
        }

        // Bounded quantum past the deadline: a self-exited child with
        // grandchild-held fds must not spin (the kill itself stays
        // !reaped-gated). One clock sample per iteration: a tick between two
        // samples could otherwise make `stopAt - now` negative, and poll
        // would then block indefinitely for that iteration.
        const now = Clock.currTime;
        const pastDeadline = now >= stopAt;
        const pollTimeout = (killed || pastDeadline) ? 100.dur!"msecs" : max(1.dur!"msecs",
                stopAt - now);

        const nready = poll(&fds[0], fds.length,
                cast(int) min(pollTimeout.total!"msecs", int.max));
        if (nready == -1) {
            if (errno == EINTR)
                continue;
            throw new Exception("poll on the child's pipes failed, errno " ~ errno.to!string);
        }

        foreach (i, ref f; fds) {
            // POLLIN and POLLHUP both mean "readable"; POLLERR is handled by
            // read failing below instead of spinning on an unreadable fd.
            if ((f.revents & (POLLIN | POLLHUP | POLLERR)) == 0)
                continue;

            char[8192] chunk = void;
            const n = read(f.fd, chunk.ptr, chunk.length);
            if (n == -1) {
                if (errno == EINTR)
                    continue;
                throw new Exception("read from the child's pipe failed, errno " ~ errno.to!string);
            }
            if (n == 0) {
                eof[i] = true;
                // poll ignores negative fds; a hung-up fd would otherwise
                // report ready on every poll: hot spin
                f.fd = -1;
                continue;
            }
            raw[i].put(chunk[0 .. n]);
        }
    }

    // The child has exited by now (EOF on both pipes requires every write
    // end closed), so the blocking wait() below returns immediately -- but it
    // is essential: tryWait can still report a just-exited child as running,
    // and without the wait the status would be lost (-1) and a zombie left
    // behind. It reaps on both paths; on the timeout path it typically
    // returns -9 (never exitCodeSegFault), so the segfault retry is never
    // spuriously triggered.
    rval.timeout = killed;

    rval.status = p.pid.wait();

    if (killed) // timeout-path kill+reap observability
        logger.warning("timed out, killed and reaped child pid ", pidNum).collectException;

    rval.stdout = splitLines(raw[0].data);
    rval.stderr = splitLines(raw[1].data);

    // Per-stream drain observability: the byte and line counts of what the
    // poll+read loop drained. The collectException guards keep this cheap
    // when trace logging is disabled.
    logger.trace("drained stdout: ", raw[0].data.length, " bytes / ",
            rval.stdout.length, " lines").collectException;
    logger.trace("drained stderr: ", raw[1].data.length, " bytes / ",
            rval.stderr.length, " lines").collectException;

    return rval;
}

/// Splits $(D buf) into lines exactly like std.stdio.byLineCopy would
/// (terminator '\n' stripped, '\r' retained, trailing unterminated line kept,
/// empty input yields zero lines).
string[] splitLines(in string buf) @safe {
    import std.algorithm.iteration : splitter;
    import std.algorithm.searching : endsWith;
    import std.array : appender;

    auto dst = appender!(string[])();
    if (buf.length == 0)
        return [];
    const b = buf.endsWith("\n") ? buf[0 .. $ - 1] : buf;
    if (b.length == 0)
        return [""]; // buffer was exactly "\n": one empty line
    foreach (l; splitter(b, '\n')) // lazy, non-allocating slices
        dst.put(l.idup); // owned copies; raw buffer then freed
    return dst.data;
}
