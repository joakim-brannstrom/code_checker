/**
Copyright: Copyright (c) 2018, Joakim Brännström. All rights reserved.
License: $(LINK2 http://www.boost.org/LICENSE_1_0.txt, Boost Software License 1.0)
Author: Joakim Brännström (joakim.brannstrom@gmx.com)
*/
module code_checker.engine.types;

@safe:

/** The base fixture that an analyzer implement
 */
interface BaseFixture {
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
    import code_checker.types : AbsolutePath;
    import code_checker.compile_db : CompileCommandDB;

    /// The compile_commands.json that contains all files to analyse.
    AbsolutePath compileDbFile;

    /// The compile commands that is used for the analyse.
    CompileCommandDB compileDb;

    /// The files to analyse
    AbsolutePath[] files;
}

/// The summary of an analyzers result.
enum Status {
    /// The analyze failed
    failed,
    /// The analyze passed without any remarks.
    passed
}

/// The amount of points the analyzer adjusts the overall score
struct Score {
    int value;
    alias value this;
}

/// The severity of a user message.
enum Severity {
    /// Trace info used for debugging
    trace,
    /// General info about the analyzer that is useful to the user
    info,
    /// Why an analyzer failed to execute
    unableToExecute,
    /// Why an analyzer reports failed
    failReason,
    /// Improvement suggestions for how to fix the score intended for the user
    improvSuggestion,
}

/// A message from an analyzer.
struct Msg {
    Severity severity;
    string[] value;
    alias value this;
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
    /// Messages from the analyzer to the user.
    Messages msg;
}

/// The result of all analyzers.
struct TotalResult {
    /// Total status of all analyzers
    Status status;

    /// Total score of the analyzers
    Score score;

    /// Improvement suggestions for the user
    Suggestions sugg;
}
