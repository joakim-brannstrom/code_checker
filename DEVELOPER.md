# Testing

A developer of `code_checker` that wants to run the tests.
```sh
dub test && dub run -c integration_test
```

Extra arguments can be passed to the integration test runner:
```sh
dub run -c integration_test -- -h
```

# Style

Use dfmt to format the file. The configuration is in `.editorconfig`.

# Analyzer execution on the my.actor system

The static-code analyzers (clang-tidy, include-what-you-use) run on the
[vendored my.actor](vendor/mylib/source/my/actor/README.md) actor system:

- One `System` per analyzer run, driven to completion by the driver helper
  `blockUntilReport` (`source/code_checker/engine/actor_engine.d`).
- Four actor roles: `JobCoordinator` (compile-db prep loop, load-shedding gate
  and fan-out), one-shot workers (`ClangTidyWorker` / `IwyuWorker`, one spawned
  per accepted file), `ResultCollector` (fan-in and the merged aggregate), and
  the `ConsoleWriter` - the sole stdout/stderr writer while the system is alive.
- Mailboxes are unbounded: sends never block and never drop.
- A message that arrives with no matching handler is dropped by the vendor.
  The `onUnhandledMessage` hooks in `actor_engine.d` log it loudly, but only in
  test builds (`dub test`) or debug builds opted in by invoking the compiler
  directly with `ldc2 -d-version=CodeCheckerActorDebug` - the `DFLAGS` route
  through dub is toolchain-dependent (the pinned ldc2 rejects `-version=X`) -
  and release output is unaffected.
