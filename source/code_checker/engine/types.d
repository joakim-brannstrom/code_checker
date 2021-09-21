/**
Copyright: Copyright (c) 2018, Joakim Brännström. All rights reserved.
License: $(LINK2 http://www.boost.org/LICENSE_1_0.txt, Boost Software License 1.0)
Author: Joakim Brännström (joakim.brannstrom@gmx.com)
*/
module code_checker.engine.types;

public import my.path : AbsolutePath;

public import code_checker.cli : Config;

@safe:

/** The base fixture that an analyzer implement
 */
interface BaseFixture {
    /// the name of the analyser.
    string name();

    /// Explain what the analyser is.
    string explain();

    /// The environment the analysers execute in.
    void putEnv(Environment);

    /// Setup the environment for analyze.
    void setup();

    /// Execute the analyser.
    void execute();

    /// Cleanup after analyze.
    void tearDown();

    /// Returns: the result of the analyzer.
    Result result();
}

/// Environment data useful for an anylser.
struct Environment {
    import my.path : AbsolutePath;
    import compile_db : CompileCommandDB, CompileCommandFilter;

    Config conf;

    /// The compile_commands.json that contains all files to analyse.
    AbsolutePath compileDbFile;

    /// The compile commands that is used for the analyse.
    CompileCommandDB compileDb;

    /// The files to analyse.
    string[] files;
}

/// The summary of an analyzers result.
enum Status {
    none,
    /// The analyze failed
    failed,
    /// The analyze passed without any remarks.
    passed
}

Status mergeStatus(Status old, Status new_) @safe pure nothrow @nogc {
    if (old == Status.none)
        return new_;
    return old == Status.failed ? old : new_;
}

/// The amount of points the analyzer adjusts the overall score
struct Score {
    int value;
    alias value this;
}

/// The number of suppressed warnings from a static code analyzer.
struct Suppressed {
    int value;
    alias value this;
}

/// The severity of a user message.
enum MsgSeverity {
    /// Why an analyzer failed to execute
    unableToExecute,
    /// Why an analyzer reports failed
    failReason,
    /// Improvement suggestions for how to fix the score intended for the user
    improveSuggestion,
    /// Trace data that should only be printed when the loglevel is trace
    trace,
}

/// A message from an analyzer.
struct Msg {
    MsgSeverity severity;
    string value;
    alias value this;

    int opCmp(ref const Msg rhs) @safe pure nothrow const {
        if (severity < rhs.severity)
            return -1;
        else if (severity > rhs.severity)
            return 1;
        else
            return value < rhs.value ? -1 : (value > rhs.value ? 1 : 0);
    }

    bool opEquals(ref const Msg o) @safe pure nothrow const @nogc scope {
        return severity == o.severity && value == o.value;
    }

    string toString() @safe const {
        import std.format : format;

        return format("%s: %s", severity, value);
    }
}

/// Messages from an analyzer intended to be displayed to the user.
struct Messages {
    Msg[] value;
    alias value this;
}

/// Suggestions of how to improve the score.
struct Suggestions {
    Msg[] value;
    alias value this;
}

/// The result of an analyzer.
struct Result {
    /// The summary state of an analyzer after it has executed.
    Status status;

    Score score;

    Messages msg;

    /// Warnings suppressed by the user.
    Suppressed supp;

    /// Files that failed an analyze.
    AbsolutePath[] failed;
}

/// The result of all analyzers.
struct TotalResult {
    /// Total status of all analyzers
    Status status;

    /// Total score of the analyzers
    Score score;

    /// Improvement suggestions for the user
    Suggestions sugg;

    /// Warnings suppressed by the user.
    Suppressed supp;

    /// Files that failed an analyze.
    AbsolutePath[] failed;
}

/// Classification of warnings. Used by the user to filter on.
/// This enum must be ordered such that style < low < medium < high < critical
enum Severity {
    style,
    low,
    medium,
    high,
    critical
}

/// Returns: a nullable severity translation from a string.
auto toSeverity(string s) @safe pure nothrow {
    import std.typecons : Nullable;
    import std.conv : to;

    Nullable!Severity r;

    try {
        r = s.to!Severity;
    } catch (Exception e) {
    }

    return r;
}
