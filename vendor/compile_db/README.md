# compile_db

**compile_db** is a library for reading and parsing `compile_commands.json`.

The standard for the format is [here](https://clang.llvm.org/docs/JSONCompilationDatabase.html)

# Note

The code is not the prettiest but it works. Reversing a "string" to the
original argument array is not the easiest when there are spaces, utf-8
characters such as arabic or chinese, deviations from how CLI arguments work
2021 because compilers are old etc.

Code cleanup, refactoring etc is welcome but try not to break the API too much
or leave an easy to follow upgrade path because there are a significant amount
of code depending on the current API.
