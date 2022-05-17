/**
Copyright: Copyright (c) 2018, Joakim Brännström. All rights reserved.
License: $(LINK2 http://www.boost.org/LICENSE_1_0.txt, Boost Software License 1.0)
Author: Joakim Brännström (joakim.brannstrom@gmx.com)
*/
module code_checker.engine.builtin.clang_tidy_classification;

public import code_checker.engine.types : Severity, Position;

version (unittest) {
    import unit_threaded : shouldEqual, shouldBeTrue;
}

@safe:

struct SeverityColor {
    import colorlog : Color, Background, Mode;

    Color c = Color.white;
    Background bg = Background.black;
    Mode m;
}

immutable Severity[string] diagnosticSeverity;
immutable SeverityColor[Severity] severityColor;

shared static this() @trusted {
    import logger = std.experimental.logger;
    import std.algorithm : filter;
    import std.array : empty;
    import std.conv : to;
    import std.file : thisExePath, readText;
    import std.json : parseJSON, JSONType;
    import std.path : buildPath, dirName;
    import std.string : split, toLower, startsWith;

    const clangTidyPath = buildPath(thisExePath.dirName.dirName, "etc",
            "code_checker", "clang-tidy.json");
    auto json = parseJSON(readText(clangTidyPath));

    import colorlog : Color, Background, Mode;

    foreach (a; json["labels"].object.byKeyValue.filter!(a => a.value.type == JSONType.ARRAY)) {
        Severity s = () {
            foreach (v; a.value.array) {
                auto splt = v.str.split(":");
                if (!splt.empty && splt[0] == "severity") {
                    try {
                        auto r = splt[1].toLower.to!Severity;
                        return r;
                    } catch (Exception e) {
                    }
                }
            }
            return Severity.min;
        }();

        if (a.key.startsWith("core."))
            diagnosticSeverity["clang-analyzer-" ~ a.key] = s;
        else
            diagnosticSeverity[a.key] = s;
    }

    // dfmt off
    severityColor = [
        Severity.style: SeverityColor(Color.lightCyan, Background.black, Mode.none),
        Severity.low: SeverityColor(Color.lightBlue, Background.black, Mode.bold),
        Severity.medium: SeverityColor(Color.lightYellow, Background.black, Mode.none),
        Severity.high: SeverityColor(Color.red, Background.black, Mode.bold),
        Severity.critical: SeverityColor(Color.magenta, Background.black, Mode.bold),
    ];
    // dfmt on
}

struct CountErrorsResult {
    private {
        int total;
        int[Severity] score_;
        int suppressedWarnings;
    }

    /// Returns: the score when summing up the found occurancies.
    int score() @safe pure nothrow const @nogc {
        int sum;
        // just chose some numbers. The intent is that warnings should be a high penalty
        foreach (kv; score_.byKeyValue) {
            final switch (kv.key) {
            case Severity.style:
                sum -= kv.value;
                break;
            case Severity.low:
                sum -= kv.value * 2;
                break;
            case Severity.medium:
                sum -= kv.value * 5;
                break;
            case Severity.high:
                sum -= kv.value * 10;
                break;
            case Severity.critical:
                sum -= kv.value * 100;
                break;
            }
        }

        return sum;
    }

    void put(const Severity s) {
        total++;

        if (auto v = s in score_)
            (*v)++;
        else
            score_[s] = 1;
    }

    void setSuppressed(const int v) {
        suppressedWarnings = v;
    }

    auto toRange() const {
        import std.algorithm : map, sort;
        import std.array : array;
        import std.format : format;

        return score_.byKeyValue
            .array
            .sort!((a, b) => a.key > b.key)
            .map!(a => format("%s %s", a.value, a.key));
    }
}

@("shall sort the error counts")
unittest {
    import std.traits : EnumMembers;
    import code_checker.engine.types : Severity;
    import unit_threaded;

    CountErrorsResult r;
    foreach (s; [EnumMembers!Severity])
        r.put(s);

    r.toRange.shouldEqual([
            "1 critical", "1 high", "1 medium", "1 low", "1 style"
            ]);
}

struct DiagMessage {
    Severity severity;

    /// Kind of warning.
    string kind;

    /// Filename that clang-tidy reported for the warning.
    string file;
    /// Position inside the file
    Position pos;

    /// The diagnostic message such as file.cpp:2:3 error: some text [foo-check]
    string diagnostic;
    /// The trailing info such as fixits
    string[] trailing;
}

struct StatMessage {
    // Number of NOLINTs
    int nolint;
}

/** Apply `fn` on the diagnostic messages.
 *
 * The return value from fn replaces the message. This makes it possible to
 * rewrite a message if needed.
 *
 * Params:
 *  diagFn = mapped onto a diagnostic message
 *  statFn = statistics gathered from clang-tidy
 *  lines = an input range of lines to analyze for diagnostic messages
 *  w = output range that the resulting log is written to.
 */
void mapClangTidy(alias diagFn, Writer)(string[] lines, ref scope Writer w) {
    import std.algorithm : startsWith;
    import std.array : appender, Appender;
    import std.conv : to;
    import std.exception : ifThrown;
    import std.range : put;
    import std.regex : regex, matchFirst, Captures;
    import std.string : startsWith;

    void callDiagFnAndReset(ref DiagMessage msg, ref Appender!(string[]) app) {
        msg.trailing = app.data;
        app.clear;
        if (diagFn(msg)) {
            put(w, msg.diagnostic);
            foreach (t; msg.trailing)
                put(w, t);
        }

        msg = DiagMessage.init;
    }

    static void updateMsg(ref DiagMessage msg, ref Captures!string m, string l) nothrow {
        msg.diagnostic = l;
        try {
            msg.severity = classify(m["severity"], m["kind"]);
            msg.kind = m["severity"];
            msg.file = m["file"];
            msg.pos = Position(m["line"].to!uint, m["column"].to!uint);
        } catch (Exception e) {
        }
    }

    const re_error = regex(
            `(?P<file>.*):(?P<line>\d*):(?P<column>\d*):.*(?P<kind>(error|warning)):.*\[(?P<severity>.*)\]`);

    enum State {
        none,
        match,
        partOfMatch,
        newMatch,
    }

    State st;
    auto app = appender!(string[])();
    DiagMessage msg;
    foreach (l; lines) {
        auto m_error = matchFirst(l, re_error);

        final switch (st) {
        case State.none:
            if (m_error.length > 1)
                st = State.match;
            break;
        case State.match:
            if (m_error.length > 1)
                st = State.newMatch;
            else
                st = State.partOfMatch;
            break;
        case State.partOfMatch:
            if (m_error.length > 1)
                st = State.newMatch;
            break;
        case State.newMatch:
            if (m_error.length <= 1)
                st = State.partOfMatch;
            break;
        }

        final switch (st) {
        case State.none:
            break;
        case State.match:
            updateMsg(msg, m_error, l);
            break;
        case State.partOfMatch:
            app.put(l);
            break;
        case State.newMatch:
            callDiagFnAndReset(msg, app);
            updateMsg(msg, m_error, l);
            break;
        }
    }

    msg.trailing = app.data;
    if (st != State.none && diagFn(msg)) {
        put(w, msg.diagnostic);
        foreach (t; msg.trailing)
            put(w, t);
    }
}

void mapClangTidyStats(alias statFn)(string[] lines) {
    import std.conv : to;
    import std.exception : ifThrown;
    import std.regex : regex, matchFirst;

    const re_nolint = regex(`Supp.*\D(?P<nolint>\d+)\s*NOLINT.*`);

    foreach (l; lines) {
        auto m_nolint = matchFirst(l, re_nolint);

        if (m_nolint.length > 1) {
            auto nolint_cnt = m_nolint["nolint"].to!int.ifThrown(0);
            statFn(StatMessage(nolint_cnt));
        }
    }
}

@("shall filter warnings")
unittest {
    import std.algorithm : startsWith;
    import std.array : appender;

    // dfmt off
    string[] lines = [
        "gmock-matchers.h:3410:15: error: invalid case style for private method 'AnalyzeElements' [readability-identifier-naming,-warnings-as-errors]",
        "  MatchMatrix AnalyzeElements(ElementIter elem_first, ElementIter elem_last,",
        "              ^~~~~~~~~~~~~~~~",
        "              analyzeElements",
        "gmock-matchers.h:3410:43: error: invalid case style for parameter 'elem_first' [readability-identifier-naming,-warnings-as-errors]",
        "  MatchMatrix AnalyzeElements(ElementIter elem_first, ElementIter elem_last,",
        "                                          ^~~~~~~~~~~",
        "                                          elemFirst",
        "gmock-matchers2.h:3410:67: error: invalid case style for parameter 'elem_last' [readability-identifier-naming,-warnings-as-errors]",
        "  MatchMatrix AnalyzeElements(ElementIter elem_first, ElementIter elem_last,",
        "                                                                  ^~~~~~~~~~",
        "                                                                  elemLast",
        ];
    // dfmt on

    DiagMessage[] msgs;
    bool diagMsg(DiagMessage msg) {
        msgs ~= msg;
        // skipping a message to see that it works
        if (msgs.length == 1)
            return false;
        return true;
    }

    auto app = appender!(string[])();
    mapClangTidy!diagMsg(lines, app);

    msgs.length.shouldEqual(3);

    msgs[0].file.shouldEqual("gmock-matchers.h");
    msgs[0].diagnostic.startsWith("gmock-matchers.h:3410:15:").shouldBeTrue;
    msgs[0].trailing.length.shouldEqual(3);

    msgs[2].file.shouldEqual("gmock-matchers2.h");
    msgs[2].diagnostic.startsWith("gmock-matchers2.h:3410:67").shouldBeTrue;
    msgs[2].trailing.length.shouldEqual(3);

    app.data.length.shouldEqual(8);
}

@("shall report the number of suppressed warnings")
unittest {
    // dfmt off
    string[] lines = [
        "42598 warnings generated.",
        "Suppressed 27578 warnings (27523 in non-user code, 55 NOLINT).",
        "Use -header-filter=.* to display errors from all non-system headers. Use -system-headers to display errors from system headers as well.",
        ];
    // dfmt on

    StatMessage stat;
    void statFn(StatMessage msg) {
        stat = msg;
    }

    // act
    mapClangTidyStats!statFn(lines);

    // assert
    stat.nolint.shouldEqual(55);
}

/// Returns: the classification of the diagnostic message.
Severity classify(string diagnostic_msg, string kind) {
    import std.string : startsWith;

    if (kind == "error")
        return Severity.critical;

    if (auto v = diagnostic_msg in diagnosticSeverity) {
        return *v;
    }

    // this is a fallback when new rules are added to clang-tidy but
    // they haven't been thoroughly analyzed in
    // `code_checker.engine.builtin.clang_tidy_classification`.
    if (diagnostic_msg.startsWith("readability-"))
        return Severity.style;
    else if (diagnostic_msg.startsWith("clang-analyzer-"))
        return Severity.high;

    return Severity.medium;
}

/**
 * Params:
 *  predicate = param is the classification of the diagnostic message. True means that it is kept, false thrown away
 * Returns: a range of rules to inactivate that are below `s`
 */
auto filterSeverity(alias predicate)() {
    import std.algorithm : filter, map;

    // dfmt off
    return diagnosticSeverity
        .byKeyValue
        .filter!(a => predicate(a.value))
        .map!(a => a.key);
    // dfmt on
}

/// Returns: severity as a string with colors.
string color(Severity s) {
    import std.conv : to;
    static import colorlog;

    SeverityColor sc;

    if (auto v = s in severityColor) {
        sc = *v;
    }

    return colorlog.color(s.to!string, sc.c).bg(sc.bg).mode(sc.m).toString;
}
