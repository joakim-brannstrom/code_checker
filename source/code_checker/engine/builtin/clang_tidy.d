/**
Copyright: Copyright (c) 2018, Joakim Brännström. All rights reserved.
License: $(LINK2 http://www.boost.org/LICENSE_1_0.txt, Boost Software License 1.0)
Author: Joakim Brännström (joakim.brannstrom@gmx.com)

This file contains an analyzer that uses clang-tidy.
*/
module code_checker.engine.builtin.clang_tidy;

import std.typecons : Tuple;
import std.exception : collectException;
import std.concurrency : Tid, thisTid;
import logger = std.experimental.logger;

import code_checker.engine.types;
import code_checker.types;
import code_checker.process : RunResult;
import code_checker.from;

@safe:

class ClangTidy : BaseFixture {
    private {
        Environment env;
        Result result_;
        string[] tidyArgs;
    }

    override string explain() {
        return "using clang-tidy";
    }

    /// The environment the analyzers execute in.
    override void putEnv(Environment v) {
        this.env = v;
    }

    /// Setup the environment for analyze.
    override void setup() {
        import std.algorithm;
        import std.array : appender, array;
        import std.ascii;
        import std.file : exists;
        import std.range : put;

        auto app = appender!(string[])();

        app.put("-warnings-as-errors=*");
        app.put("-p=.");

        if (env.clangTidy.applyFixit) {
            app.put(["-fix"]);
        }

        env.compiler.extraFlags.map!(a => ["-extra-arg", a]).joiner.copy(app);

        ["-header-filter", env.clangTidy.headerFilter].copy(app);

        if (!env.staticCode.checkNameStandard) {
            env.clangTidy.checks ~= ["-readability-identifier-naming"];
            // if names are ignored then the user is probably not interested in namespaces either
            env.clangTidy.checks ~= ["llvm-namespace-comment"];
        }

        if (exists(ClangTidyConstants.confFile)) {
            logger.infof("Using clang-tidy settings from the local '%s'",
                    ClangTidyConstants.confFile);
        } else {
            logger.trace("Using config from the TOML file");

            auto c = appender!string();
            c.put(`{Checks: "`);
            env.clangTidy.checks.joiner(",").copy(c);
            c.put(`",`);
            c.put("CheckOptions: [");
            env.clangTidy.options.joiner(",").copy(c);
            c.put("]");
            c.put("}");

            app.put("-config");
            app.put(c.data);
        }

        tidyArgs ~= app.data;
    }

    /// Execute the analyzer.
    override void execute() {
        import core.time : dur;
        import std.format : format;
        import code_checker.compile_db : UserFileRange, parseFlag,
            CompileCommandFilter, SearchResult;
        import std.parallelism : task, TaskPool;
        import std.concurrency : Tid, thisTid, receiveTimeout;

        bool logged_failure;

        void handleResult(immutable(TidyResult)* res_) @trusted nothrow {
            import std.format : format;
            import std.typecons : nullableRef;
            import colorize : Color, color, Background, Mode;

            auto res = nullableRef(cast() res_);

            logger.infof("%s '%s'", "clang-tidy analyzing".color(Color.yellow,
                    Background.black), res.file).collectException;

            // just chose some numbers. The intent is that warnings should be a high penalty
            result_.score += res.result.status == 0 ? 1
                : -(
                        res.errors.style + res.errors.low * 2 + res.errors.medium
                        * 5 + res.errors.high * 10 + res.errors.critical * 100);

            if (res.result.status != 0) {
                res.result.print;

                if (!logged_failure) {
                    result_.msg ~= Msg(Severity.failReason, "clang-tidy warn about file(s)");
                    logged_failure = true;
                }

                try {
                    result_.msg ~= Msg(Severity.improveSuggestion,
                            format("clang-tidy: fix %-(%s, %) in %s", res.errors.toRange, res.file));
                } catch (Exception e) {
                    logger.warning(e.msg).collectException;
                    logger.warning("Unable to add user message to the result").collectException;
                }
            }

            result_.status = mergeStatus(result_.status, res.result.status == 0
                    ? Status.passed : Status.failed);
            logger.trace(result_).collectException;
        }

        auto pool = () {
            import std.parallelism : taskPool;

            // must run single threaded when writing fixits or the result is unpredictable
            if (env.clangTidy.applyFixit)
                return new TaskPool(0);
            return taskPool;
        }();

        scope (exit) {
            if (env.clangTidy.applyFixit)
                pool.finish;
        }

        static struct DoneCondition {
            int expected;
            int replies;

            bool isWaitingForReplies() {
                return replies < expected;
            }
        }

        DoneCondition cond;

        foreach (cmd; UserFileRange(env.compileDb, env.files, null, CompileCommandFilter.init)) {
            if (cmd.isNull) {
                result_.status = Status.failed;
                result_.score -= 100;
                result_.msg ~= Msg(Severity.failReason,
                        "clang-tidy where unable to find one of the specified files in compile_commands.json");
                break;
            }

            cond.expected++;

            immutable(TidyWork)* w = () @trusted{
                return cast(immutable) new TidyWork(tidyArgs, cmd.cflags, cmd.absoluteFile);
            }();
            auto t = task!taskTidy(thisTid, w);
            pool.put(t);
        }

        while (cond.isWaitingForReplies) {
            () @trusted{
                try {
                    if (receiveTimeout(1.dur!"seconds", &handleResult)) {
                        cond.replies++;
                    }
                } catch (Exception e) {
                    logger.error(e.msg);
                }
            }();
        }
    }

    /// Cleanup after analyze.
    override void tearDown() {
    }

    /// Returns: the result of the analyzer.
    override Result result() {
        return result_;
    }
}

struct TidyResult {
    AbsolutePath file;
    RunResult result;
    CountErrorsResult errors;
}

struct TidyWork {
    string[] args;
    string[] cflags;
    AbsolutePath p;
}

void taskTidy(Tid owner, immutable TidyWork* work_) nothrow @trusted {
    import std.concurrency : send;

    auto tres = new TidyResult;
    TidyWork* work = cast(TidyWork*) work_;

    try {
        tres.file = work.p;
        tres.result = runClangTidy(work.args, work.cflags, work.p);
        tres.errors = countErrors(tres.result.stdout);
    } catch (Exception e) {
        logger.warning(e.msg).collectException;
    }

    while (true) {
        try {
            owner.send(cast(immutable) tres);
            break;
        } catch (Exception e) {
            logger.tracef("failed sending to: %s", owner).collectException;
        }
    }
}

struct ClangTidyConstants {
    static immutable bin = "clang-tidy";
    static immutable confFile = ".clang-tidy";
}

auto runClangTidy(string[] tidy_args, string[] compiler_args, AbsolutePath fname) {
    import std.algorithm : map, copy;
    import std.format : format;
    import std.array : appender;
    import code_checker.process;

    auto app = appender!(string[])();
    app.put(ClangTidyConstants.bin);
    tidy_args.copy(app);
    app.put(fname);

    return run(app.data);
}

struct CountErrorsResult {
    int total;
    int style;
    int low;
    int medium;
    int high;
    int critical;

    auto toRange() const {
        import std.algorithm;
        import std.format : format;
        import std.range;

        alias Pair = Tuple!(int, string);

        return only(Pair(critical, "critical"), Pair(high, "high"),
                Pair(medium, "medium"), Pair(low, "low"), Pair(style, "style"),).filter!(a => a[0] > 0)
            .map!(a => format("%s %s", a[0], a[1]));
    }
}

/// Count the number of lines with a error: message in it.
CountErrorsResult countErrors(string[] lines) @trusted {
    import std.algorithm;
    import std.regex : ctRegex, matchFirst;
    import std.string : startsWith;

    // copied from https://github.com/Ericsson/codechecker/blob/master/config/checker_severity_map.json

    // dfmt off
    immutable severity_map = [
        "readability-static-accessed-through-instance":               "STYLE",
        "bugprone-virtual-near-miss":                                 "MEDIUM",
        "bugprone-misplaced-operator-in-strlen-in-alloc":             "MEDIUM",
        "bugprone-integer-division":                                  "MEDIUM",
        "bugprone-copy-constructor-init":                             "MEDIUM",
        "optin.portability.UnixAPI":                                  "MEDIUM",
        "cplusplus.SelfAssignment":                                   "MEDIUM",
        "alpha.cplusplus.DeleteWithNonVirtualDtor":                   "HIGH",
        "alpha.clone.CloneChecker":                                   "LOW",
        "alpha.core.BoolAssignment":                                  "LOW",
        "alpha.core.CallAndMessageUnInitRefArg":                      "HIGH",
        "alpha.core.CastSize":                                        "LOW",
        "alpha.core.CastToStruct":                                    "LOW",
        "alpha.core.Conversion":                                      "LOW",
        "alpha.core.FixedAddr":                                       "LOW",
        "alpha.core.IdenticalExpr":                                   "LOW",
        "alpha.core.PointerArithm":                                   "LOW",
        "alpha.core.PointerSub":                                      "LOW",
        "alpha.core.SizeofPtr":                                       "LOW",
        "alpha.core.TestAfterDivZero":                                "MEDIUM",
        "alpha.cplusplus.IteratorRange":                              "MEDIUM",
        "alpha.cplusplus.MisusedMovedObject":                         "MEDIUM",
        "alpha.deadcode.UnreachableCode":                             "LOW",
        "alpha.osx.cocoa.DirectIvarAssignment":                       "LOW",
        "alpha.osx.cocoa.DirectIvarAssignmentForAnnotatedFunctions":  "LOW",
        "alpha.osx.cocoa.InstanceVariableInvalidation":               "LOW",
        "alpha.osx.cocoa.MissingInvalidationMethod":                  "LOW",
        "alpha.osx.cocoa.localizability.PluralMisuseChecker":         "LOW",
        "alpha.security.ArrayBound":                                  "HIGH",
        "alpha.security.ArrayBoundV2":                                "HIGH",
        "alpha.security.MallocOverflow":                              "HIGH",
        "alpha.security.ReturnPtrRange":                              "LOW",
        "alpha.unix.BlockInCriticalSection":                          "LOW",
        "alpha.unix.Chroot":                                          "MEDIUM",
        "alpha.unix.PthreadLock":                                     "HIGH",
        "alpha.unix.SimpleStream":                                    "MEDIUM",
        "alpha.unix.Stream":                                          "MEDIUM",
        "alpha.unix.cstring.BufferOverlap":                           "HIGH",
        "alpha.unix.cstring.NotNullTerminated":                       "HIGH",
        "alpha.unix.cstring.OutOfBounds":                             "HIGH",
        "security.FloatLoopCounter":                                  "MEDIUM",
        "security.insecureAPI.UncheckedReturn":                       "MEDIUM",
        "security.insecureAPI.getpw":                                 "MEDIUM",
        "security.insecureAPI.gets":                                  "MEDIUM",
        "security.insecureAPI.mkstemp":                               "MEDIUM",
        "security.insecureAPI.mktemp":                                "MEDIUM",
        "security.insecureAPI.rand":                                  "MEDIUM",
        "security.insecureAPI.strcpy":                                "MEDIUM",
        "security.insecureAPI.vfork":                                 "MEDIUM",
        "unix.API":                                                   "MEDIUM",
        "unix.Malloc":                                                "MEDIUM",
        "unix.MallocSizeof":                                          "MEDIUM",
        "unix.MismatchedDeallocator":                                 "MEDIUM",
        "unix.Vfork":                                                 "MEDIUM",
        "unix.cstring.BadSizeArg":                                    "MEDIUM",
        "unix.cstring.NullArg":                                       "MEDIUM",
        "valist.CopyToSelf":                                          "MEDIUM",
        "valist.Uninitialized":                                       "MEDIUM",
        "valist.Unterminated":                                        "MEDIUM",
        "nullability.NullPassedToNonnull":                            "HIGH",
        "nullability.NullReturnedFromNonnull":                        "HIGH",
        "nullability.NullableDereferenced":                           "MEDIUM",
        "nullability.NullablePassedToNonnull":                        "MEDIUM",
        "nullability.NullableReturnedFromNonnull":                    "MEDIUM",
        "core.CallAndMessage":                                        "HIGH",
        "core.DivideZero":                                            "HIGH",
        "core.DynamicTypePropagation":                                "MEDIUM",
        "core.NonNullParamChecker":                                   "HIGH",
        "core.NullDereference":                                       "HIGH",
        "core.StackAddressEscape":                                    "HIGH",
        "core.UndefinedBinaryOperatorResult":                         "MEDIUM",
        "core.VLASize":                                               "MEDIUM",
        "core.builtin.BuiltinFunctions":                              "MEDIUM",
        "core.builtin.NoReturnFunctions":                             "MEDIUM",
        "core.uninitialized.ArraySubscript":                          "MEDIUM",
        "core.uninitialized.Assign":                                  "MEDIUM",
        "core.uninitialized.Branch":                                  "MEDIUM",
        "core.uninitialized.CapturedBlockVariable":                   "MEDIUM",
        "core.uninitialized.UndefReturn":                             "HIGH",
        "cplusplus.NewDelete":                                        "HIGH",
        "cplusplus.NewDeleteLeaks":                                   "HIGH",
        "deadcode.DeadStores":                                        "LOW",
        "llvm.Conventions":                                           "LOW",
        "optin.cplusplus.VirtualCall":                                "MEDIUM",
        "optin.mpi.MPI-Checker":                                      "MEDIUM",
        "optin.performance.Padding":                                  "LOW",
        "android-cloexec-creat":                                      "MEDIUM",
        "android-cloexec-open":                                       "MEDIUM",
        "android-cloexec-fopen":                                      "MEDIUM",
        "android-cloexec-socket":                                     "MEDIUM",
        "boost-use-to-string":                                        "LOW",
        "bugprone-assert-side-effect":                                "MEDIUM",
        "bugprone-argument-comment":                                  "LOW",
        "bugprone-bool-pointer-implicit-conversion":                  "LOW",
        "bugprone-dangling-handle":                                   "HIGH",
        "bugprone-fold-init-type":                                    "HIGH",
        "bugprone-forward-declaration-namespace":                     "LOW",
        "bugprone-inaccurate-erase":                                  "HIGH",
        "bugprone-move-forwarding-reference":                         "MEDIUM",
        "bugprone-misplaced-operator-in-strlen-in-alloc":             "MEDIUM",
        "bugprone-multiple-statement-macro":                          "MEDIUM",
        "bugprone-string-constructor":                                "HIGH",
        "bugprone-suspicious-memset-usage":                           "HIGH",
        "bugprone-undefined-memory-manipulation":                     "MEDIUM",
        "bugprone-use-after-move":                                    "HIGH",
        "cert-dcl03-c":                                               "MEDIUM",
        "cert-dcl21-cpp":                                             "LOW",
        "cert-dcl50-cpp":                                             "LOW",
        "cert-dcl54-cpp":                                             "MEDIUM",
        "cert-dcl58-cpp":                                             "HIGH",
        "cert-dcl59-cpp":                                             "MEDIUM",
        "cert-env33-c":                                               "MEDIUM",
        "cert-err09-cpp":                                             "HIGH",
        "cert-err34-c":                                               "LOW",
        "cert-err52-cpp":                                             "LOW",
        "cert-err58-cpp":                                             "LOW",
        "cert-err60-cpp":                                             "MEDIUM",
        "cert-err61-cpp":                                             "HIGH",
        "cert-fio38-c":                                               "HIGH",
        "cert-flp30-c":                                               "HIGH",
        "cert-oop11-cpp":                                             "MEDIUM",
        "cert-msc30-c":                                               "LOW",
        "cert-msc50-cpp":                                             "LOW",
        "cppcoreguidelines-interfaces-global-init":                   "LOW",
        "cppcoreguidelines-no-malloc":                                "LOW",
        "hicpp-no-malloc":                                            "LOW",
        "cppcoreguidelines-pro-bounds-array-to-pointer-decay":        "LOW",
        "hicpp-no-array-decay":                                       "LOW",
        "cppcoreguidelines-pro-bounds-constant-array-index":          "LOW",
        "cppcoreguidelines-pro-bounds-pointer-arithmetic":            "LOW",
        "cppcoreguidelines-pro-type-const-cast":                      "LOW",
        "cppcoreguidelines-pro-type-cstyle-cast":                     "LOW",
        "cppcoreguidelines-pro-type-member-init":                     "LOW",
        "cppcoreguidelines-pro-type-reinterpret-cast":                "LOW",
        "cppcoreguidelines-pro-type-static-cast-downcast":            "LOW",
        "cppcoreguidelines-pro-type-union-access":                    "LOW",
        "cppcoreguidelines-pro-type-vararg":                          "LOW",
        "hicpp-vararg":                                               "LOW",
        "cppcoreguidelines-slicing":                                  "LOW",
        "cppcoreguidelines-special-member-functions":                 "LOW",
        "google-build-explicit-make-pair":                            "MEDIUM",
        "google-build-namespaces":                                    "MEDIUM",
        "google-build-using-namespace":                               "STYLE",
        "google-default-arguments":                                   "LOW",
        "google-explicit-constructor":                                "MEDIUM",
        "google-global-names-in-headers":                             "HIGH",
        "google-readability-braces-around-statements":                "STYLE",
        "google-readability-casting":                                 "LOW",
        "google-readability-function-size":                           "STYLE",
        "google-readability-namespace-comments":                      "STYLE",
        "google-readability-redundant-smartptr-get":                  "MEDIUM",
        "google-readability-todo":                                    "STYLE",
        "google-runtime-int":                                         "LOW",
        "google-runtime-member-string-references":                    "LOW",
        "google-runtime-memset":                                      "HIGH",
        "google-runtime-operator":                                    "MEDIUM",
        "hicpp-braces-around-statements":                             "STYLE",
        "hicpp-exception-baseclass":                                  "LOW",
        "hicpp-signed-bitwise":                                       "LOW",
        "hicpp-explicit-conversions":                                 "LOW",
        "hicpp-function-size":                                        "LOW",
        "hicpp-named-parameter":                                      "LOW",
        "hicpp-invalid-access-moved":                                 "HIGH",
        "hicpp-member-init":                                          "LOW",
        "hicpp-new-delete-operators":                                 "LOW",
        "hicpp-noexcept-move":                                        "MEDIUM",
        "hicpp-no-assembler":                                         "LOW",
        "hicpp-special-member-functions":                             "LOW",
        "hicpp-undelegated-constructor":                              "MEDIUM",
        "hicpp-use-equals-default":                                   "LOW",
        "hicpp-use-equals-delete":                                    "LOW",
        "hicpp-use-override":                                         "LOW",
        "llvm-header-guard":                                          "LOW",
        "llvm-include-order":                                         "LOW",
        "llvm-namespace-comment":                                     "LOW",
        "llvm-twine-local":                                           "LOW",
        "misc-argument-comment":                                      "LOW",
        "misc-assert-side-effect":                                    "MEDIUM",
        "misc-bool-pointer-implicit-conversion":                      "LOW",
        "misc-dangling-handle":                                       "HIGH",
        "misc-definitions-in-headers":                                "MEDIUM",
        "misc-fold-init-type":                                        "HIGH",
        "misc-forward-declaration-namespace":                         "LOW",
        "misc-forwarding-reference-overload":                         "LOW",
        "misc-inaccurate-erase":                                      "HIGH",
        "misc-incorrect-roundings":                                   "HIGH",
        "misc-inefficient-algorithm":                                 "MEDIUM",
        "misc-lambda-function-name":                                  "LOW",
        "misc-macro-parentheses":                                     "MEDIUM",
        "misc-macro-repeated-side-effects":                           "MEDIUM",
        "misc-misplaced-const":                                       "LOW",
        "misc-misplaced-widening-cast":                               "HIGH",
        "misc-move-const-arg":                                        "MEDIUM",
        "hicpp-move-const-arg":                                       "MEDIUM",
        "misc-move-constructor-init":                                 "MEDIUM",
        "misc-move-forwarding-reference":                             "MEDIUM",
        "misc-multiple-statement-macro":                              "MEDIUM",
        "misc-new-delete-overloads":                                  "MEDIUM",
        "misc-noexcept-move-constructor":                             "MEDIUM",
        "misc-non-copyable-objects":                                  "HIGH",
        "misc-redundant-expression":                                  "MEDIUM",
        "misc-sizeof-container":                                      "HIGH",
        "misc-sizeof-expression":                                     "HIGH",
        "misc-static-assert":                                         "LOW",
        "hicpp-static-assert":                                        "LOW",
        "misc-string-compare":                                        "LOW",
        "misc-string-constructor":                                    "HIGH",
        "misc-string-integer-assignment":                             "LOW",
        "misc-string-literal-with-embedded-nul":                      "MEDIUM",
        "misc-suspicious-enum-usage":                                 "HIGH",
        "misc-suspicious-missing-comma":                              "HIGH",
        "misc-suspicious-semicolon":                                  "HIGH",
        "misc-suspicious-string-compare":                             "MEDIUM",
        "misc-swapped-arguments":                                     "HIGH",
        "misc-throw-by-value-catch-by-reference":                     "HIGH",
        "misc-unconventional-assign-operator":                        "MEDIUM",
        "cppcoreguidelines-c-copy-assignment-signature":              "MEDIUM",
        "misc-undelegated-constructor":                               "MEDIUM",
        "misc-uniqueptr-reset-release":                               "MEDIUM",
        "misc-unused-alias-decls":                                    "LOW",
        "misc-unused-parameters":                                     "LOW",
        "misc-unused-raii":                                           "HIGH",
        "misc-unused-using-decls":                                    "LOW",
        "misc-use-after-move":                                        "HIGH",
        "misc-virtual-near-miss":                                     "HIGH",
        "modernize-avoid-bind":                                       "STYLE",
        "modernize-deprecated-headers":                               "LOW",
        "hicpp-deprecated-headers":                                   "LOW",
        "modernize-loop-convert":                                     "STYLE",
        "modernize-make-shared":                                      "LOW",
        "modernize-make-unique":                                      "LOW",
        "modernize-pass-by-value":                                    "LOW",
        "modernize-raw-string-literal":                               "STYLE",
        "modernize-redundant-void-arg":                               "STYLE",
        "modernize-replace-auto-ptr":                                 "LOW",
        "modernize-replace-random-shuffle":                           "LOW",
        "modernize-return-braced-init-list":                          "STYLE",
        "modernize-shrink-to-fit":                                    "STYLE",
        "modernize-unary-static-assert":                              "STYLE",
        "modernize-use-auto":                                         "STYLE",
        "hicpp-use-auto":                                             "STYLE",
        "modernize-use-bool-literals":                                "STYLE",
        "modernize-use-default-member-init":                          "STYLE",
        "modernize-use-emplace":                                      "STYLE",
        "hicpp-use-emplace":                                          "STYLE",
        "modernize-use-equals-default":                               "STYLE",
        "modernize-use-equals-delete":                                "STYLE",
        "modernize-use-noexcept":                                     "STYLE",
        "hicpp-use-noexcept":                                         "STYLE",
        "modernize-use-nullptr":                                      "LOW",
        "hicpp-use-nullptr":                                          "LOW",
        "modernize-use-override":                                     "LOW",
        "modernize-use-transparent-functors":                         "LOW",
        "modernize-use-using":                                        "STYLE",
        "mpi-buffer-deref":                                           "LOW",
        "mpi-type-mismatch":                                          "LOW",
        "performance-inefficient-vector-operation":                   "LOW",
        "performance-faster-string-find":                             "LOW",
        "performance-for-range-copy":                                 "LOW",
        "performance-implicit-cast-in-loop":                          "LOW",
        "performance-implicit-conversion-in-loop":                    "LOW",
        "performance-inefficient-algorithm":                          "MEDIUM",
        "performance-inefficient-string-concatenation":               "LOW",
        "performance-move-const-arg":                                 "MEDIUM",
        "performance-move-constructor-init":                          "MEDIUM",
        "performance-noexcept-move-constructor":                      "MEDIUM",
        "performance-type-promotion-in-math-fn":                      "LOW",
        "performance-unnecessary-copy-initialization":                "LOW",
        "performance-unnecessary-value-param":                        "LOW",
        "readability-avoid-const-params-in-decls":                    "STYLE",
        "readability-braces-around-statements":                       "STYLE",
        "readability-container-size-empty":                           "STYLE",
        "readability-delete-null-pointer":                            "STYLE",
        "readability-deleted-default":                                "STYLE",
        "readability-else-after-return":                              "STYLE",
        "readability-function-size":                                  "STYLE",
        "readability-identifier-naming":                              "STYLE",
        "readability-implicit-bool-cast":                             "STYLE",
        "readability-implicit-bool-conversion":                       "STYLE",
        "readability-inconsistent-declaration-parameter-name":        "STYLE",
        "readability-misleading-indentation":                         "LOW",
        "readability-misplaced-array-index":                          "STYLE",
        "readability-named-parameter":                                "STYLE",
        "readability-non-const-parameter":                            "STYLE",
        "readability-redundant-control-flow":                         "STYLE",
        "readability-redundant-declaration":                          "STYLE",
        "readability-redundant-function-ptr-dereference":             "STYLE",
        "readability-redundant-member-init":                          "STYLE",
        "readability-redundant-smartptr-get":                         "STYLE",
        "readability-redundant-string-cstr":                          "STYLE",
        "readability-redundant-string-init":                          "STYLE",
        "readability-simplify-boolean-expr":                          "MEDIUM",
        "readability-static-definition-in-anonymous-namespace":       "STYLE",
        "readability-uniqueptr-delete-release": "STYLE",
            ];
    // dfmt on

    CountErrorsResult r;

    auto re_error = ctRegex!(`.*:\d*:.*error:.*\[(.*)\]`);

    foreach (a; lines.map!(a => matchFirst(a, re_error)).filter!(a => a.length > 1)) {
        r.total++;

        if (auto v = a[1] in severity_map) {
            switch (*v) {
            case "STYLE":
                r.style++;
                break;
            case "LOW":
                r.low++;
                break;
            case "MEDIUM":
                r.medium++;
                break;
            case "HIGH":
                r.high++;
                break;
            case "CRITICAL":
                r.critical++;
                break;
            default:
                r.high++;
                logger.warning("This should never happen");
            }
        } else {
            if (a[1].startsWith("readability-"))
                r.style++;
            else if (a[1].startsWith("clang-analyzer-"))
                r.high++;
            else
                r.medium++;
        }
    }

    return r;
}
