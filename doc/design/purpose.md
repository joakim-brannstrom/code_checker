# REQ-purpose
###

The purpose of this program is to define a generic set of checks that are considered best practice to use on source code.

These checks are then executed on the source code provided by the user.

The checks are language agnostic.

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
