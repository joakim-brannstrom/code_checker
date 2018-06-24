# Definitions

## <a href="D-vendor"></a> Vendor

This is dependencies that a program have that is stored together with the programs own source code (repo).

A common place to put them is in the subdirectory "vendor".

This is done to:
 * make it easier to build the program because all that is needed is to clone the repo.
 * have control over the dependencies and what version is used.
 * simplify reproducible builds.

## Fast Mode

It is defined as the total execution time is at most 3 seconds.
