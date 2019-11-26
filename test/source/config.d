/**
Copyright: Copyright (c) 2018, Joakim Brännström. All rights reserved.
License: $(LINK2 http://www.boost.org/LICENSE_1_0.txt, Boost Software License 1.0)
Author: Joakim Brännström (joakim.brannstrom@gmx.com)
*/
module config;

public import core.stdc.stdlib;
public import logger = std.experimental.logger;
public import std.algorithm;
public import std.array;
public import std.ascii;
public import std.conv;
public import std.file;
public import std.path;
public import std.process;
public import std.range;
public import std.stdio;
public import std.string;
public import std.string;

public import unit_threaded.light;

immutable compileCommandsFile = "compile_commands.json";

string appPath() {
    foreach (a; ["../build/code_checker"].filter!(a => exists(a)))
        return a.absolutePath;
    assert(0, "unable to find an app binary");
}

/// Path to where data used for integration tests exists
string testData() {
    return "testdata".absolutePath;
}

string inTestData(string p) {
    return buildPath(testData, p);
}

string tmpDir() {
    return "build/test".absolutePath;
}

auto makeTestArea(string file = __FILE__, int line = __LINE__) {
    return TestArea(file, line);
}

struct TestArea {
    const string sandboxPath;
    private int commandLogCnt;

    this(string file, int line) {
        prepare();
        sandboxPath = buildPath(tmpDir, file.baseName ~ line.to!string).absolutePath;

        if (exists(sandboxPath)) {
            rmdirRecurse(sandboxPath);
        }
        mkdirRecurse(sandboxPath);
    }

    auto exec(Args...)(auto ref Args args_) {
        string[] args;
        static foreach (a; args_)
            args ~= a;
        auto res = execute(args, null, Config.none, size_t.max, sandboxPath);
        try {
            auto fout = File(inSandboxPath(format("command%s.log", commandLogCnt++)), "w");
            fout.writefln("%-(%s %)", args);
            fout.write(res.output);
        } catch (Exception e) {
        }
        return res;
    }

    auto exec(string[] args, string[string] env) {
        auto res = execute(args, env, Config.none, size_t.max, sandboxPath);
        try {
            auto fout = File(inSandboxPath(format("command%s.log", commandLogCnt++)), "w");
            fout.writefln("%-(%s %)", args);
            fout.write(res.output);
        } catch (Exception e) {
        }
        return res;
    }

    string inSandboxPath(const string fileName) @safe pure nothrow const {
        import std.path : buildPath;

        return buildPath(sandboxPath, fileName);
    }
}

void dirContentCopy(string src, string dst) {
    import std.algorithm;
    import std.file;
    import std.path;
    import core.sys.posix.sys.stat;

    assert(src.isDir);
    assert(dst.isDir);

    foreach (f; dirEntries(src, SpanMode.shallow).filter!"a.isFile") {
        auto dst_f = buildPath(dst, f.name.baseName);
        copy(f.name, dst_f);
        auto attrs = getAttributes(f.name);
        if (attrs & S_IXUSR)
            setAttributes(dst_f, attrs | S_IXUSR);
    }
}

auto regexIn(T)(string rawRegex, T[] array, string file = __FILE__, in size_t line = __LINE__) {
    import std.regex : regex, matchFirst;

    auto r = regex(rawRegex);

    foreach (v; array) {
        if (!matchFirst(v, r).empty)
            return;
    }

    import unit_threaded.exception : fail;

    fail(formatValueInItsOwnLine("Value ",
            rawRegex) ~ formatValueInItsOwnLine("not in ", array), file, line);
}

auto regexNotIn(T)(string rawRegex, T[] array, string file = __FILE__, in size_t line = __LINE__) {
    import std.regex : regex, matchFirst;
    import unit_threaded.exception : fail;

    auto r = regex(rawRegex);

    foreach (v; array) {
        if (!matchFirst(v, r).empty) {
            fail(formatValueInItsOwnLine("Value ",
                    rawRegex) ~ formatValueInItsOwnLine("in ", array), file, line);
            return;
        }
    }
}

string[] formatValueInItsOwnLine(T)(in string prefix, scope auto ref T value) {
    import std.conv : to;
    import std.traits : isSomeString;
    import std.range.primitives : isInputRange;
    import std.traits; // too many to list
    import std.range; // also

    static if (isSomeString!T) {
        // isSomeString is true for wstring and dstring,
        // so call .to!string anyway
        return [prefix ~ `"` ~ value.to!string ~ `"`];
    } else static if (isInputRange!T) {
        return formatRange(prefix, value);
    } else {
        return [prefix ~ convertToString(value)];
    }
}

string[] formatRange(T)(in string prefix, scope auto ref T value) {
    import std.conv : text;
    import std.range : ElementType;
    import std.algorithm : map, reduce, max;

    //some versions of `text` are @system
    auto defaultLines = () @trusted { return [prefix ~ value.text]; }();

    static if (!isInputRange!(ElementType!T))
        return defaultLines;
    else {
        import std.array : array;

        const maxElementSize = value.empty ? 0 : value.map!(a => a.array.length)
            .reduce!max;
        const tooBigForOneLine = (value.array.length > 5 && maxElementSize > 5)
            || maxElementSize > 10;
        if (!tooBigForOneLine)
            return defaultLines;
        return [prefix ~ "["] ~ value.map!(a => formatValueInItsOwnLine("              ",
                a).join("") ~ ",").array ~ "          ]";
    }
}

private:

shared(bool) g_isPrepared = false;

void prepare() {
    import core.thread : Thread;
    import core.time : dur;

    synchronized {
        if (g_isPrepared)
            return;
        scope (exit)
            g_isPrepared = true;

        // prepare by cleaning up
        if (exists(tmpDir)) {
            while (true) {
                try {
                    rmdirRecurse(tmpDir);
                    break;
                } catch (Exception e) {
                    logger.info(e.msg);
                }
                Thread.sleep(100.dur!"msecs");
            }
        }
    }
}
