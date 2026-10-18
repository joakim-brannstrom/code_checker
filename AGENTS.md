# AGENTS.md - code_checker

## Overview

code_checker is a D command-line tool that performs quality checks of C/C++ code
by wrapping `clang-tidy` and `iwyu`. It is intended as an automated sanity check
before a pull request is accepted, or for manual inspection. Its distinguishing
feature is incremental re-analysis: it tracks files that passed together with
their header dependencies and re-analyzes only files (or dependencies) that
changed.

## Tech Stack

- Language: D (dmd 2.079+ / ldc 1.8.0+ per README)
- Build system / package manager: dub (`dub.sdl`)
- Vendored D dependencies in `vendor/`: colorlog, compile_db, d2sqlite3, dyaml,
  miniorm, mylib, nusilly, tinyendian, toml
- Runtime tool dependencies: `clang-tidy` (4.0+) and `iwyu` (optional, for
  include-what-you-use analysis)
- Test runner: nusilly (vendored fork of silly, `vendor/nusilly/`)

## Directory Layout

- `source/` - application sources
  - `source/app.d` - main entry point (excluded from the unittest build)
  - `source/app_normal.d` - CLI wiring, analysis pipeline callbacks
  - `source/code_checker/engine/` - analysis engine; `builtin/` holds the
    clang-tidy and iwyu integrations
  - `source/code_checker/database/` - sqlite persistence of pass/fail state
- `vendor/` - all dub dependencies, vendored so the project builds offline.
  Never edit these; they are upstream packages.
- `test/` - integration tests; run from this directory (see Testing). Has its
  own `dub.sdl`. `test/redirect.d` (config `integration_test`) only chdirs into
  `test/` and runs from there.
- `etc/code_checker/` - shipped config: `default.toml` (default config read at
  runtime), `default_template.toml`, `clang-tidy.json`, `clang_tidy.conf`
- `doc/` - end-user documentation

## Commands

### Build (normal, with registry access)

```sh
dub build            # debug binary in build/
dub build -b release # release binary in build/
```

### Build (without internet access)

The environment may have no network access. All dependencies are vendored in
`vendor/`, so register them locally and skip the registry:

```sh
cd code_checker
for d in vendor/*/; do
    n=$(grep -oP '"name"\s*:\s*"\K[^"]+' "$d/dub.json" 2>/dev/null | head -1)
    v=$(grep -oP '"version"\s*:\s*"\K[^"]+' "$d/dub.json" 2>/dev/null | tail -1)
    if [ -n "$n" ]; then dub add-local "$d" "$v"; fi
done
dub build --skip-registry=all
```

Notes:

- Run the whole block (add-local loop AND the build) in the same shell. Local
  registrations live in `~/.dub` and may not survive between sessions; if a
  later build says `Failed to find any versions for package X`, re-run the loop.
- For `compile_db`, the last `version` match in its `dub.json` is the real one
  (0.0.6); an earlier match (`~>0.0.45`) is a sub-configuration entry. The
  `tail -1` above handles this.
- Every vendored directory has a `dub.json`, so the loop registers all of
  them. The `if` form (not `[ -n "$n" ] && ...`) also keeps the loop's exit
  status at 0 when a directory has no `dub.json` - with `&&`, a failing guard
  would make the loop return non-zero and break `&& dub build` chaining in a
  one-liner.
- `--offline` is NOT a valid dub flag in dub 1.41; use `--skip-registry=all`.

### Test

```sh
dub test                      # unit tests (nusilly); dub auto-generates the
                              # main and dub_test_root modules
dub run -c integration_test   # integration tests; must run from the repo root.
                              # It builds the app (`dub build -c application`),
                              # chdirs into test/ and runs `dub test` there.
dub run -c integration_test -- -h   # pass args through to the test runner
```

Integration tests pin no test runner of their own: the inner `dub test` in
`test/` resolves `test/dub.sdl`, which depends on the same vendored `nusilly`
runner as the root project.

### Run

```sh
./build/code_checker -h
```

The default configuration is read from `etc/code_checker/default.toml` relative
to the binary; `{code_checker}` in a config value expands to the binary's
directory.

## Code Conventions

- Format all edited D code with dfmt; the settings live in `.editorconfig`
  (4-space indent, OTBS braces, space after cast, LF endings, final newline,
  trimmed trailing whitespace). Never hand-reformat unrelated code.
- Header style: every source file starts with a `Copyright:` / `License:` /
  `Author:` DDoc block (BSL-1.0 for this repo; some vendored deps are MPL-2 -
  never change vendored files).
- Use DDoc (`///` or `/** */`) for public declarations; document intent, not
  syntax.
- Commit messages: short imperative summary line, no conventional-commit
  prefixes (e.g. "Update classification", "Fix bug when parsing compiler
  builtin flags").

## Architecture & Patterns

- Pipeline: `app_normal.d` registers analysis callbacks (`act_*`) that the
  engine invokes in phases (init, check compile db, generate/fix db, run
  analyzers, done). Callback wiring is in `source/app_normal.d` and
  `source/code_checker/engine/`.
- Incremental analysis state (which files/dependencies passed) is stored in a
  sqlite database via `source/code_checker/database/` (d2sqlite3) and the
  vendored `miniorm` layer.
- Compile-command parsing lives in
  `source/code_checker/engine/compile_db.d` on top of the vendored `compile_db`
  package.
- Generated `.clang-tidy` config (clang-tidy integration): at startup the base
  config (`[clang_tidy] system_config`) is parsed with the vendored `dyaml`
  package and rewritten with the user's filter/severity settings;
  `HeaderFilterRegex`/`ExcludeHeaderFilterRegex` values are substituted, and
  when `[static_code] severity` is set the disabled checks are spliced into a
  `Checks` value normalized to a one-line flow sequence. An unreadable,
  unparseable, or non-mapping base config is used as-is for the generated
  `.clang-tidy` with a warning instead (verbatim, as far as the file is
  readable as text; no settings applied). The
  output starts with a `# GENERATED by code_checker` comment; a local
  `.clang-tidy` lacking it is used as-is and not overwritten.
- Configuration: TOML files parsed with the vendored `toml` package. The
  runtime default is `etc/code_checker/default.toml`; severity thresholds,
  enabled analyzers (`clang-tidy`, `iwyu`), compiler flag lists, and database
  path are all set there. Environment variables may be referenced in config
  values.
- Logging goes through the vendored `colorlog` package; user-facing colored
  output uses `colorlog.color`, not hand-rolled ANSI codes.

## Testing

- Unit tests: colocated `unittest` blocks, executed with `dub test`. Failing
  asserts print plain diagnostics (file:line). The unittest build excludes
  `source/app.d`; dub auto-generates the test main and `dub_test_root` module.
  Runner flags: `dub test -- -t1` (serial), `-i <regex>` (filter).
- Integration tests: `test/source/*.d` with fixtures in `test/testdata/`
  (cpp sources, toml configs, expected logs). Run with
  `dub run -c integration_test` from the repo root, NOT from `test/`.
  See the offline caveat under Commands > Test.
- When adding a test, prefer extending existing files in `test/source/` over
  creating new modules.

## Git Workflow

- Work happens on short-lived feature branches merged into `master` via PRs;
  branch names are kebab-case topics (e.g. `fix-builtin-flags`,
  `add-cpu-limit`).
- `vendor/` updates are their own commits ("vendor: update").

## Environment & Services

- No network access can be assumed. Never add a dependency that is not already
  under `vendor/`; if you must, vendor it first (copy the package into
  `vendor/` with its `dub.json`/`dub.sdl` and pin a known-good version) and add
  it to `dub.sdl` with a version matching the vendored copy.
- `clang-tidy` must be installed for the tool to do anything useful
  (`sudo apt install clang-tidy`); `iwyu` is optional. The shipped analyzers'
  configs live in `etc/code_checker/`.

## Agent Rules

- Do NOT edit anything under `vendor/` - it is upstream code; build problems
  there are solved by version selection, not patching.
- Do NOT edit `build/` or any generated artifact (e.g. dub's generated test
  main); it is regenerated by dub.
- Always build (`dub build`) after changing sources, and run `dub test` before
  claiming a change works; for changes under `source/code_checker/engine/`,
  also run `dub run -c integration_test`.
- Never fix compile errors by weakening attributes (`nothrow`, `@safe`,
  `shared`) in `source/` without understanding the invariant being enforced.
  Toolchain note: LDC 1.42 (DMD 2.112) failed to build in `clang_tidy.d`
  (AA `update` nothrow) and `clang_tidy_classification.d` (shared-AA lookup
  @safe) independent of any local edits; the current toolchain (LDC 1.43.0 /
  DMD 2.113.0) builds the application and both unittest configurations
  cleanly - check the compiler version before attributing attribute-inference
  failures to local edits.
- Keep `dub.sdl` and the vendored package versions in sync: the version
  registered with `dub add-local` must satisfy the constraint in `dub.sdl`.
- Do not introduce shell scripts or tooling outside dub/dfmt; the project's
  tooling is dub.
- When documentation in `doc/` and behavior in `source/` disagree, verify
  against the source and fix the doc in the same change.
