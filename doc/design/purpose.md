# REQ-purpose
###

The purpose of this program is to define a generic set of checks that are considered best practice to use on C/C++ code.

These checks are then executed on the source code provided by the user.

## Dump 1

For the first version the focus is on C++. In the future other languages will be considred.

The design though should take this into consideration. Try to minimize possible hard code assumptions that are only true for C++.

## Flow

What are the expected checks to run?

 * Is the code formatted correct?
 * Static code analyzers
    * This can be multiple analyzers
 * Does there exist any tests?
    * If so execute the tests. Expected is that they all pass.
 * What is the code coverage? Above the threshold?

# REQ-static_code_analysis
partof: REQ-purpose
###

The user wants to use a static code analysis tool on a project.

## Elaborated

The user has a project consisting of source code.

For this project the user has defined a code standard.

The code standard has in some way been codified in a configuration for a static code analysis tools.

Thus the user has a static code analysis tool and a configuration that he/she in some way wants to use on the project to get as output any deviations.

# SPC-static_code_analysis_clang_tidy
partof: REQ-static_code_analysis
###

The program shall save the convered database to where the program is executed.

TODO: add a **when**

The program shall execute *clang-tidy*.

# SPC-static_code_analysis_compile_db
partof: REQ-static_code_analysis
###

The program shall convert all relative paths to absolute paths when reading a compilation database.

The program shall merge multiple compilation databases to one when given more than one compilation database as input.

# SPC-deterministic_paths
partof: REQ-uc_paths_relative_config
###

The program shall by default check the current working directory for the *config file*.

The program shall use the value of the command line parameter as the path to the *config file* when the user specify `-c|--config`.

The program shall change the working directory to the value of the attribute `defaults.workdir` from the *config file* when the program is started.

**Rationale**: This makes it so that all tools that are executed have their working directory set to a value that the user can decide. There are users that may for example have a git archive somewhere on the filesystem and a cmake generate eclipse build environment somewhere else. Because the config file is part of the git repo and the user wants to be able to specify where to check for *compilation database* to make it easy to run the program the paths need to be relative to the *config file*.


# SPC-severity_mapping
partof: REQ-static_code_analysis
###

The following severity levels are defined:
 * Style: A true positive indicates that the source code is against a specific coding guideline or could improve readability. Example: LLVM Coding Guideline: Do not use else or else if after something that interrupts control flow (break, return, throw, continue).
 * Low: A true positive indicates that the source code is hard to read/understand or could be easily optimized. Example: Unused variables, Dead code.
 * Medium: A true positive indicates that the source code that may not cause a run-time error (yet), but against intuition and hence prone to error. Example: Redundant expression in a condition.
 * High: A true positive indicates that the source code will cause a run-time error. Example of this category: out of bounds array access, division by zero, memory leak.
 * Critical: Currently unused. This severity level is reserved for later use.

**Note**: This is copied from [Ericssons CodeChecker tool](https://github.com/Ericsson/codechecker/blob/master/config/config.md).
