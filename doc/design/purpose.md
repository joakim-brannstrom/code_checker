# REQ-purpose
###

The purpose of this program is to define a generic set of checks that are considered best practice to use on source code.

These checks are then executed on the source code provided by the user.

The checks are language agnostic.

## Reading

This chapter is a reading guide to the requirements.

A cursive text in a requirement is a definition. The explanation for the definition can be found under the [Definitions chapter](#Definitions).

## Dump 1

For the first version the focus is on C++. In the future other languages will be considred.
It will probably be kind a the same assumptions for all statically typed languages. But we will see.

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

# <a name="D-Definitions"></a> Definitions

## Converted Database

A compilation database that consist of only absolute paths. All relative have been converted.

## Compilation Database

See [for more](https://clang.llvm.org/docs/JSONCompilationDatabase.html)
