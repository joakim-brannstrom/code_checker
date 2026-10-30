/**
Copyright: Copyright (c) 2026, code_checker contributors. All rights reserved.
License: $(LINK2 http://www.boost.org/LICENSE_1_0.txt, Boost Software License 1.0)
Author: code_checker contributors
*/
module test_process;

import config; // public imports: std.algorithm, std.array, std.conv, std.file,
// std.path, std.process, std.range, std.stdio, std.string, ...

import code_checker.process : run, RunResult, splitLines;
import std.datetime : msecs, seconds;

/// Lines the >64 KB tests make the child write per stream. The child's output
/// (~148 KB per stream at 74 B/line) far exceeds the Linux pipe capacity, the
/// load that must drain concurrently without deadlock.
immutable size_t manyLines = 2000;

/// Child writing >64 KB (the Linux pipe capacity) to stderr, then a single
/// line to stdout.
string[] genErr(size_t n = manyLines) {
    return [
        "sh", "-c",
        `i=0; while [ $i -lt ` ~ n.to!string ~ ` ]; do echo "stderr line $$ i=$i xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx" >&2; i=$((i+1)); done; echo done-on-stdout`
    ];
}

/// Child writing >64 KB to stdout, then a single line to stderr.
string[] genOut(size_t n = manyLines) {
    return [
        "sh", "-c",
        `i=0; while [ $i -lt ` ~ n.to!string ~ ` ]; do echo "stdout line $$ i=$i xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"; i=$((i+1)); done; echo done-on-stderr >&2`
    ];
}

/// Child writing >64 KB to BOTH streams simultaneously.
string[] genBoth(size_t n = manyLines) {
    return [
        "sh", "-c",
        `i=0; while [ $i -lt ` ~ n.to!string ~ ` ]; do echo "stdout line $$ i=$i xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"; echo "stderr line $$ i=$i xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx" >&2; i=$((i+1)); done`
    ];
}

@(">64 KB stderr does not deadlock")
unittest {
    auto res = run(genErr());

    assert(res.timeout == false);
    assert(res.status == 0);
    assert(res.stderr.length == manyLines);
    assert(res.stderr[0].startsWith("stderr line "), res.stderr[0]);
    assert(res.stderr[0].canFind("i=0"));
    assert(res.stderr[$ - 1].canFind("i=" ~ (manyLines - 1).to!string));
    assert(res.stdout == ["done-on-stdout"]);
}

@(">64 KB stdout does not deadlock")
unittest {
    auto res = run(genOut());

    assert(res.timeout == false);
    assert(res.status == 0);
    assert(res.stdout.length == manyLines);
    assert(res.stdout[0].startsWith("stdout line "), res.stdout[0]);
    assert(res.stdout[0].canFind("i=0"));
    assert(res.stdout[$ - 1].canFind("i=" ~ (manyLines - 1).to!string));
    assert(res.stderr == ["done-on-stderr"]);
}

@(">64 KB on both streams simultaneously")
unittest {
    auto res = run(genBoth());

    assert(res.timeout == false);
    assert(res.status == 0);
    assert(res.stdout.length == manyLines);
    assert(res.stderr.length == manyLines);
    assert(res.stdout[0].startsWith("stdout line "), res.stdout[0]);
    assert(res.stdout[$ - 1].canFind("i=" ~ (manyLines - 1).to!string));
    assert(res.stderr[0].startsWith("stderr line "), res.stderr[0]);
    assert(res.stderr[$ - 1].canFind("i=" ~ (manyLines - 1).to!string));
}

@("line splitting matches byLineCopy format")
unittest {
    auto res = run([
        "sh", "-c",
        `printf '%s\n' "line1" "line2 with spaces"; printf "no-newline-tail"`
    ]);

    assert(res.stdout == ["line1", "line2 with spaces", "no-newline-tail"]);
    assert(res.stdout.length == 3); // the two newlines + the unterminated tail
}

@("splitLines byte-matches byLineCopy")
unittest {
    // Raw bytes -> the lines byLineCopy reports for them. The empty buffer and
    // the exactly-"\n" buffer are the two cases plain splitter gets wrong.
    static immutable cases = [
        "", // -> []
        "a\n", // -> ["a"]
        "a", // -> ["a"]
        "a\n\n", // -> ["a", ""]
        "\n", // -> [""] one empty line
        "a\nb", // -> ["a", "b"]
        "a\r\nb\n", // -> ["a\r", "b"] '\r' is retained (byLineCopy semantics)
        "a\r\n", // -> ["a\r"]
        "a\0b\n", // -> ["a\0b"] NUL passes through
    ];

    foreach (i, input; cases) {
        auto ta = makeTestArea;
        const path = ta.inSandboxPath(format("case%s.txt", i));
        std.file.write(path, input);
        auto expected = File(path).byLineCopy.array;

        auto actual = splitLines(input);

        assert(actual.length == expected.length, format("case %s (%s): %s lines, expected %s",
                i, input[0 .. min(10, $)], actual.length, expected.length));
        foreach (j, l; expected)
            assert(actual[j] == l, format("case %s (%s) line %s: '%s', expected '%s'",
                    i, input[0 .. min(10, $)], j, actual[j], l));
    }
}

// Child: `head -c 5` reads stdin until EOF, then exits. run() never writes to
// the pipe and closes it right after the spawn, so head observes EOF having
// read 0 bytes (its 5-byte quota is never reached): stdout stays empty and the
// exit status is 0. With the pipe never closed, head would block on read until
// the timeout, so the explicit 5 s timeout keeps that failure mode fast: a
// regression surfaces as timeout == true within seconds.
@("child reading stdin observes EOF instead of blocking")
unittest {
    // fails fast (timeout == true) if the stdin close ever regresses
    auto res = run(["head", "-c", "5"], 5.seconds);

    assert(res.timeout == false);
    assert(res.status == 0);
    assert(res.stdout.length == 0);
}

// Child prints one line to each stream, then sleeps past the 1 s timeout.
// The SIGKILL only reaches sh: its orphaned `sleep 2` keeps both pipe write
// ends open, so the poll loop drains until sleep exits (~1 s past the kill).
// Partial output is kept across that drain, timeout is true, and the reaped
// status is the real signal-negative wait result (-9 == -SIGKILL), neither
// the -1 initial value nor the -11 segfault code.
@("child sleeping past the timeout yields timeout=true, reaped status, partial output")
unittest {
    auto res = run(["sh", "-c", `echo out-1; echo err-1 >&2; sleep 2`], 1.seconds);

    assert(res.timeout == true);
    assert(res.status == -9); // -9 == -SIGKILL: reaped signal-negative wait status
    assert(res.stdout == ["out-1"]);
    assert(res.stderr == ["err-1"]);
}

// The timeout path logs the kill+reap at warning level. Capture it by
// swapping sharedLog for a FileLogger over a sandbox file (the default
// sharedLog is not inspectable). Restored via scope (exit).
@("timeout path logs a warning about the kill+reap")
unittest {
    import std.experimental.logger.core : LogLevel, Logger, sharedLog;
    import std.experimental.logger.filelogger : FileLogger;

    auto ta = makeTestArea;
    const path = ta.inSandboxPath("timeout-warning.log");
    shared(Logger) oldLog = sharedLog;
    auto flog = new FileLogger(path, LogLevel.all);
    sharedLog = cast(shared) flog;
    scope (exit)
        sharedLog = oldLog;

    auto res = run(["sh", "-c", `echo out-1; echo err-1 >&2; sleep 2`], 1.seconds);

    assert(res.timeout == true);
    assert(res.status == -9);
    sharedLog = oldLog; // restore before flushing the capture logger below
    destroy(flog); // flush + close the captured log file before reading it
    const logged = std.file.readText(path);
    assert(logged.canFind("timed out, killed and reaped child pid "), logged);
    // The pid NUMBER is logged, not the Pid type name (a class without a
    // toString override formats as "std.process.Pid", which would defeat the
    // message's purpose).
    const after = logged[logged.indexOf("child pid ") + 10 .. $];
    assert(after.length && after[0] >= '0' && after[0] <= '9', logged);
}
