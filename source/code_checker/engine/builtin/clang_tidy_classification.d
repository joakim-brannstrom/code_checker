/**
Copyright: Copyright (c) 2018, Joakim Brännström. All rights reserved.
License: $(LINK2 http://www.boost.org/LICENSE_1_0.txt, Boost Software License 1.0)
Author: Joakim Brännström (joakim.brannstrom@gmx.com)
*/
module code_checker.engine.builtin.clang_tidy_classification;

public import code_checker.engine.types : Severity;

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

shared static this() {
    // copied from https://github.com/Ericsson/codechecker/blob/master/config/checker_severity_map.json

    // sorted alphabetically

    // dfmt off
    diagnosticSeverity = [
        // these do not seem to exist. keeping if they are impl. in clang-tidy
    "alpha.clone.CloneChecker":                                   Severity.low,
    "alpha.core.BoolAssignment":                                  Severity.low,
    "alpha.core.CallAndMessageUnInitRefArg":                      Severity.high,
    "alpha.core.CastSize":                                        Severity.low,
    "alpha.core.CastToStruct":                                    Severity.low,
    "alpha.core.Conversion":                                      Severity.low,
    "alpha.core.FixedAddr":                                       Severity.low,
    "alpha.core.IdenticalExpr":                                   Severity.low,
    "alpha.core.PointerArithm":                                   Severity.low,
    "alpha.core.PointerSub":                                      Severity.low,
    "alpha.core.SizeofPtr":                                       Severity.low,
    "alpha.core.TestAfterDivZero":                                Severity.medium,
    "alpha.cplusplus.DeleteWithNonVirtualDtor":                   Severity.high,
    "alpha.cplusplus.IteratorRange":                              Severity.medium,
    "alpha.cplusplus.MisusedMovedObject":                         Severity.medium,
    "alpha.deadcode.UnreachableCode":                             Severity.low,
    "alpha.osx.cocoa.DirectIvarAssignment":                       Severity.low,
    "alpha.osx.cocoa.DirectIvarAssignmentForAnnotatedFunctions":  Severity.low,
    "alpha.osx.cocoa.InstanceVariableInvalidation":               Severity.low,
    "alpha.osx.cocoa.MissingInvalidationMethod":                  Severity.low,
    "alpha.osx.cocoa.localizability.PluralMisuseChecker":         Severity.low,
    "alpha.security.ArrayBound":                                  Severity.high,
    "alpha.security.ArrayBoundV2":                                Severity.high,
    "alpha.security.MallocOverflow":                              Severity.high,
    "alpha.security.ReturnPtrRange":                              Severity.low,
    "alpha.unix.BlockInCriticalSection":                          Severity.low,
    "alpha.unix.Chroot":                                          Severity.medium,
    "alpha.unix.PthreadLock":                                     Severity.high,
    "alpha.unix.SimpleStream":                                    Severity.medium,
    "alpha.unix.Stream":                                          Severity.medium,
    "alpha.unix.cstring.BufferOverlap":                           Severity.high,
    "alpha.unix.cstring.NotNullTerminated":                       Severity.high,
    "alpha.unix.cstring.OutOfBounds":                             Severity.high,
    // ---
    "android-cloexec-creat":                                      Severity.medium,
    "android-cloexec-fopen":                                      Severity.medium,
    "android-cloexec-open":                                       Severity.medium,
    "android-cloexec-socket":                                     Severity.medium,
    "boost-use-to-string":                                        Severity.low,
    "bugprone-argument-comment":                                  Severity.low,
    "bugprone-assert-side-effect":                                Severity.medium,
    "bugprone-bool-pointer-implicit-conversion":                  Severity.low,
    "bugprone-copy-constructor-init":                             Severity.medium,
    "bugprone-dangling-handle":                                   Severity.high,
    "bugprone-fold-init-type":                                    Severity.high,
    "bugprone-forward-declaration-namespace":                     Severity.low,
    "bugprone-inaccurate-erase":                                  Severity.high,
    "bugprone-integer-division":                                  Severity.medium,
    "bugprone-misplaced-operator-in-strlen-in-alloc":             Severity.medium,
    "bugprone-misplaced-operator-in-strlen-in-alloc":             Severity.medium,
    "bugprone-move-forwarding-reference":                         Severity.medium,
    "bugprone-multiple-statement-macro":                          Severity.medium,
    "bugprone-string-constructor":                                Severity.high,
    "bugprone-suspicious-memset-usage":                           Severity.high,
    "bugprone-undefined-memory-manipulation":                     Severity.medium,
    "bugprone-use-after-move":                                    Severity.high,
    "bugprone-virtual-near-miss":                                 Severity.medium,
    "cert-dcl03-c":                                               Severity.medium,
    "cert-dcl21-cpp":                                             Severity.low,
    "cert-dcl50-cpp":                                             Severity.low,
    "cert-dcl54-cpp":                                             Severity.medium,
    "cert-dcl58-cpp":                                             Severity.high,
    "cert-dcl59-cpp":                                             Severity.medium,
    "cert-env33-c":                                               Severity.medium,
    "cert-err09-cpp":                                             Severity.high,
    "cert-err34-c":                                               Severity.low,
    "cert-err52-cpp":                                             Severity.low,
    "cert-err58-cpp":                                             Severity.low,
    "cert-err60-cpp":                                             Severity.medium,
    "cert-err61-cpp":                                             Severity.high,
    "cert-fio38-c":                                               Severity.high,
    "cert-flp30-c":                                               Severity.high,
    "cert-msc30-c":                                               Severity.low,
    "cert-msc50-cpp":                                             Severity.low,
    "cert-oop11-cpp":                                             Severity.medium,
    "clang-analyzer-core.CallAndMessage":                         Severity.high,
    "clang-analyzer-core.DivideZero":                             Severity.high,
    "clang-analyzer-core.DynamicTypePropagation":                 Severity.medium,
    "clang-analyzer-core.NonNullParamChecker":                    Severity.high,
    "clang-analyzer-core.NullDereference":                        Severity.high,
    "clang-analyzer-core.StackAddressEscape":                     Severity.high,
    "clang-analyzer-core.UndefinedBinaryOperatorResult":          Severity.medium,
    "clang-analyzer-core.VLASize":                                Severity.medium,
    "clang-analyzer-core.builtin.BuiltinFunctions":               Severity.medium,
    "clang-analyzer-core.builtin.NoReturnFunctions":              Severity.medium,
    "clang-analyzer-core.uninitialized.ArraySubscript":           Severity.medium,
    "clang-analyzer-core.uninitialized.Assign":                   Severity.medium,
    "clang-analyzer-core.uninitialized.Branch":                   Severity.medium,
    "clang-analyzer-core.uninitialized.CapturedBlockVariable":    Severity.medium,
    "clang-analyzer-core.uninitialized.UndefReturn":              Severity.high,
    "clang-analyzer-cplusplus.NewDelete":                         Severity.high,
    "clang-analyzer-cplusplus.NewDeleteLeaks":                    Severity.high,
    "clang-analyzer-cplusplus.SelfAssignment":                    Severity.medium,
    "clang-analyzer-deadcode.DeadStores":                         Severity.low,
    "cppcoreguidelines-c-copy-assignment-signature":              Severity.medium,
    "cppcoreguidelines-interfaces-global-init":                   Severity.low,
    "cppcoreguidelines-no-malloc":                                Severity.low,
    "cppcoreguidelines-pro-bounds-array-to-pointer-decay":        Severity.low,
    "cppcoreguidelines-pro-bounds-constant-array-index":          Severity.low,
    "cppcoreguidelines-pro-bounds-pointer-arithmetic":            Severity.low,
    "cppcoreguidelines-pro-type-const-cast":                      Severity.low,
    "cppcoreguidelines-pro-type-cstyle-cast":                     Severity.low,
    "cppcoreguidelines-pro-type-member-init":                     Severity.low,
    "cppcoreguidelines-pro-type-reinterpret-cast":                Severity.low,
    "cppcoreguidelines-pro-type-static-cast-downcast":            Severity.low,
    "cppcoreguidelines-pro-type-union-access":                    Severity.low,
    "cppcoreguidelines-pro-type-vararg":                          Severity.low,
    "cppcoreguidelines-slicing":                                  Severity.low,
    "cppcoreguidelines-special-member-functions":                 Severity.low,
    "google-build-explicit-make-pair":                            Severity.medium,
    "google-build-namespaces":                                    Severity.medium,
    "google-build-using-namespace":                               Severity.style,
    "google-default-arguments":                                   Severity.low,
    "google-explicit-constructor":                                Severity.medium,
    "google-global-names-in-headers":                             Severity.high,
    "google-readability-braces-around-statements":                Severity.style,
    "google-readability-casting":                                 Severity.low,
    "google-readability-function-size":                           Severity.style,
    "google-readability-namespace-comments":                      Severity.style,
    "google-readability-redundant-smartptr-get":                  Severity.medium,
    "google-readability-todo":                                    Severity.style,
    "google-runtime-int":                                         Severity.low,
    "google-runtime-member-string-references":                    Severity.low,
    "google-runtime-memset":                                      Severity.high,
    "google-runtime-operator":                                    Severity.medium,
    "hicpp-braces-around-statements":                             Severity.style,
    "hicpp-deprecated-headers":                                   Severity.low,
    "hicpp-exception-baseclass":                                  Severity.low,
    "hicpp-explicit-conversions":                                 Severity.low,
    "hicpp-function-size":                                        Severity.low,
    "hicpp-invalid-access-moved":                                 Severity.high,
    "hicpp-member-init":                                          Severity.low,
    "hicpp-move-const-arg":                                       Severity.medium,
    "hicpp-named-parameter":                                      Severity.low,
    "hicpp-new-delete-operators":                                 Severity.low,
    "hicpp-no-array-decay":                                       Severity.low,
    "hicpp-no-assembler":                                         Severity.low,
    "hicpp-no-malloc":                                            Severity.low,
    "hicpp-noexcept-move":                                        Severity.medium,
    "hicpp-signed-bitwise":                                       Severity.low,
    "hicpp-special-member-functions":                             Severity.low,
    "hicpp-static-assert":                                        Severity.low,
    "hicpp-undelegated-constructor":                              Severity.medium,
    "hicpp-use-auto":                                             Severity.style,
    "hicpp-use-emplace":                                          Severity.style,
    "hicpp-use-equals-default":                                   Severity.low,
    "hicpp-use-equals-delete":                                    Severity.low,
    "hicpp-use-noexcept":                                         Severity.style,
    "hicpp-use-nullptr":                                          Severity.low,
    "hicpp-use-override":                                         Severity.low,
    "hicpp-vararg":                                               Severity.low,
    "llvm-header-guard":                                          Severity.low,
    "llvm-include-order":                                         Severity.low,
    "llvm-namespace-comment":                                     Severity.style,
    "llvm-twine-local":                                           Severity.low,
    "clang-analyzer-llvm.Conventions":                            Severity.low,
    "misc-argument-comment":                                      Severity.low,
    "misc-assert-side-effect":                                    Severity.medium,
    "misc-bool-pointer-implicit-conversion":                      Severity.low,
    "misc-dangling-handle":                                       Severity.high,
    "misc-definitions-in-headers":                                Severity.medium,
    "misc-fold-init-type":                                        Severity.high,
    "misc-forward-declaration-namespace":                         Severity.low,
    "misc-forwarding-reference-overload":                         Severity.low,
    "misc-inaccurate-erase":                                      Severity.high,
    "misc-incorrect-roundings":                                   Severity.high,
    "misc-inefficient-algorithm":                                 Severity.medium,
    "misc-lambda-function-name":                                  Severity.low,
    "misc-macro-parentheses":                                     Severity.medium,
    "misc-macro-repeated-side-effects":                           Severity.medium,
    "misc-misplaced-const":                                       Severity.low,
    "misc-misplaced-widening-cast":                               Severity.high,
    "misc-move-const-arg":                                        Severity.medium,
    "misc-move-constructor-init":                                 Severity.medium,
    "misc-move-forwarding-reference":                             Severity.medium,
    "misc-multiple-statement-macro":                              Severity.medium,
    "misc-new-delete-overloads":                                  Severity.medium,
    "misc-noexcept-move-constructor":                             Severity.medium,
    "misc-non-copyable-objects":                                  Severity.high,
    "misc-redundant-expression":                                  Severity.medium,
    "misc-sizeof-container":                                      Severity.high,
    "misc-sizeof-expression":                                     Severity.high,
    "misc-static-assert":                                         Severity.low,
    "misc-string-compare":                                        Severity.low,
    "misc-string-constructor":                                    Severity.high,
    "misc-string-integer-assignment":                             Severity.low,
    "misc-string-literal-with-embedded-nul":                      Severity.medium,
    "misc-suspicious-enum-usage":                                 Severity.high,
    "misc-suspicious-missing-comma":                              Severity.high,
    "misc-suspicious-semicolon":                                  Severity.high,
    "misc-suspicious-string-compare":                             Severity.medium,
    "misc-swapped-arguments":                                     Severity.high,
    "misc-throw-by-value-catch-by-reference":                     Severity.high,
    "misc-unconventional-assign-operator":                        Severity.medium,
    "misc-undelegated-constructor":                               Severity.medium,
    "misc-uniqueptr-reset-release":                               Severity.medium,
    "misc-unused-alias-decls":                                    Severity.low,
    "misc-unused-parameters":                                     Severity.low,
    "misc-unused-raii":                                           Severity.high,
    "misc-unused-using-decls":                                    Severity.low,
    "misc-use-after-move":                                        Severity.high,
    "misc-virtual-near-miss":                                     Severity.high,
    "modernize-avoid-bind":                                       Severity.style,
    "modernize-deprecated-headers":                               Severity.low,
    "modernize-loop-convert":                                     Severity.style,
    "modernize-make-shared":                                      Severity.low,
    "modernize-make-unique":                                      Severity.low,
    "modernize-pass-by-value":                                    Severity.low,
    "modernize-raw-string-literal":                               Severity.style,
    "modernize-redundant-void-arg":                               Severity.style,
    "modernize-replace-auto-ptr":                                 Severity.low,
    "modernize-replace-random-shuffle":                           Severity.low,
    "modernize-return-braced-init-list":                          Severity.style,
    "modernize-shrink-to-fit":                                    Severity.style,
    "modernize-unary-static-assert":                              Severity.style,
    "modernize-use-auto":                                         Severity.style,
    "modernize-use-bool-literals":                                Severity.style,
    "modernize-use-default-member-init":                          Severity.style,
    "modernize-use-emplace":                                      Severity.style,
    "modernize-use-equals-default":                               Severity.style,
    "modernize-use-equals-delete":                                Severity.style,
    "modernize-use-noexcept":                                     Severity.style,
    "modernize-use-nullptr":                                      Severity.low,
    "modernize-use-override":                                     Severity.low,
    "modernize-use-transparent-functors":                         Severity.low,
    "modernize-use-using":                                        Severity.style,
    "mpi-buffer-deref":                                           Severity.low,
    "mpi-type-mismatch":                                          Severity.low,
    "clang-analyzer-nullability.NullPassedToNonnull":             Severity.high,
    "clang-analyzer-nullability.NullReturnedFromNonnull":         Severity.high,
    "clang-analyzer-nullability.NullableDereferenced":            Severity.medium,
    "clang-analyzer-nullability.NullablePassedToNonnull":         Severity.medium,
    "clang-analyzer-nullability.NullableReturnedFromNonnull":     Severity.medium,
    "clang-analyzer-optin.cplusplus.VirtualCall":                 Severity.medium,
    "clang-analyzer-optin.mpi.MPI-Checker":                       Severity.medium,
    "clang-analyzer-optin.performance.Padding":                   Severity.low,
    "clang-analyzer-optin.portability.UnixAPI":                   Severity.medium,
    "performance-faster-string-find":                             Severity.low,
    "performance-for-range-copy":                                 Severity.low,
    "performance-implicit-cast-in-loop":                          Severity.low,
    "performance-implicit-conversion-in-loop":                    Severity.low,
    "performance-inefficient-algorithm":                          Severity.medium,
    "performance-inefficient-string-concatenation":               Severity.low,
    "performance-inefficient-vector-operation":                   Severity.low,
    "performance-move-const-arg":                                 Severity.medium,
    "performance-move-constructor-init":                          Severity.medium,
    "performance-noexcept-move-constructor":                      Severity.medium,
    "performance-type-promotion-in-math-fn":                      Severity.low,
    "performance-unnecessary-copy-initialization":                Severity.low,
    "performance-unnecessary-value-param":                        Severity.low,
    "readability-avoid-const-params-in-decls":                    Severity.style,
    "readability-braces-around-statements":                       Severity.style,
    "readability-container-size-empty":                           Severity.style,
    "readability-delete-null-pointer":                            Severity.style,
    "readability-deleted-default":                                Severity.style,
    "readability-else-after-return":                              Severity.style,
    "readability-function-size":                                  Severity.style,
    "readability-identifier-naming":                              Severity.style,
    "readability-implicit-bool-cast":                             Severity.style,
    "readability-implicit-bool-conversion":                       Severity.style,
    "readability-inconsistent-declaration-parameter-name":        Severity.style,
    "readability-misleading-indentation":                         Severity.low,
    "readability-misplaced-array-index":                          Severity.style,
    "readability-named-parameter":                                Severity.style,
    "readability-non-const-parameter":                            Severity.style,
    "readability-redundant-control-flow":                         Severity.style,
    "readability-redundant-declaration":                          Severity.style,
    "readability-redundant-function-ptr-dereference":             Severity.style,
    "readability-redundant-member-init":                          Severity.style,
    "readability-redundant-smartptr-get":                         Severity.style,
    "readability-redundant-string-cstr":                          Severity.style,
    "readability-redundant-string-init":                          Severity.style,
    "readability-simplify-boolean-expr":                          Severity.medium,
    "readability-static-accessed-through-instance":               Severity.style,
    "readability-static-definition-in-anonymous-namespace":       Severity.style,
    "readability-uniqueptr-delete-release":                       Severity.style,
    "clang-analyzer-security.FloatLoopCounter":                   Severity.medium,
    "clang-analyzer-security.insecureAPI.UncheckedReturn":        Severity.medium,
    "clang-analyzer-security.insecureAPI.getpw":                  Severity.medium,
    "clang-analyzer-security.insecureAPI.gets":                   Severity.medium,
    "clang-analyzer-security.insecureAPI.mkstemp":                Severity.medium,
    "clang-analyzer-security.insecureAPI.mktemp":                 Severity.medium,
    "clang-analyzer-security.insecureAPI.rand":                   Severity.medium,
    "clang-analyzer-security.insecureAPI.strcpy":                 Severity.medium,
    "clang-analyzer-security.insecureAPI.vfork":                  Severity.medium,
    "clang-analyzer-unix.API":                                    Severity.medium,
    "clang-analyzer-unix.Malloc":                                 Severity.medium,
    "clang-analyzer-unix.MallocSizeof":                           Severity.medium,
    "clang-analyzer-unix.MismatchedDeallocator":                  Severity.medium,
    "clang-analyzer-unix.Vfork":                                  Severity.medium,
    "clang-analyzer-unix.cstring.BadSizeArg":                     Severity.medium,
    "clang-analyzer-unix.cstring.NullArg":                        Severity.medium,
    "clang-analyzer-valist.CopyToSelf":                           Severity.medium,
    "clang-analyzer-valist.Uninitialized":                        Severity.medium,
    "clang-analyzer-valist.Unterminated":                         Severity.medium,
            ];

    import colorlog : Color, Background, Mode;

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
    import code_checker.engine.types : Severity;

    private {
        int total;
        int[Severity] score_;
        int suppressedWarnings;
    }

    /// Returns: the score when summing up the found occurancies.
    int score() @safe pure nothrow const @nogc scope {
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

        // suppressing warnings should not be encouraged
        sum -= suppressedWarnings;

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

    r.toRange.shouldEqual(["1 critical", "1 high", "1 medium", "1 low", "1 style"]);
}

struct DiagMessage {
    Severity severity;

    /// Filename that clang-tidy reported for the warning.
    string file;
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
    import std.regex : ctRegex, matchFirst;
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

    const re_error = ctRegex!(`(?P<file>.*):\d*:\d*:.*(error|warning):.*\[(?P<severity>.*)\]`);

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
            msg.severity = classify(m_error["severity"]);
            msg.diagnostic = l;
            msg.file = m_error["file"];
            break;
        case State.partOfMatch:
            app.put(l);
            break;
        case State.newMatch:
            callDiagFnAndReset(msg, app);

            msg.severity = classify(m_error["severity"]);
            msg.diagnostic = l;
            msg.file = m_error["file"];
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
    import std.regex : ctRegex, matchFirst;

    const re_nolint = ctRegex!(`Supp.*\D(?P<nolint>\d+)\s*NOLINT.*`);

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
Severity classify(string diagnostic_msg) {
    import std.string : startsWith;

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
