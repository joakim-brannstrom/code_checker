# REQ-uc_qa_during_development
partof: REQ-purpose
###

The user is working in isolation/by himself on a feature branch in git.
The user wants to continuously know the *quality* of the source code.
Such as any problems in the source code that the user is changing.

The user wants this check to be *fast*. It should be done in less than 3s.
Otherwise the user experience will be too slow which will lead to the user using the tool less.
Thus it wouldn't fulfill its purpose for this use case.

# REQ-uc_deep_quality_check
partof: REQ-purpose
###

The user is nearly finished with a feature branch.

The user wants to know the quality of the source code changes before the user create the pull request to merge the feature branch into master.

The user wants to run all quality checks.

The user is aware that this may take some time to run. It is thus OK that it may take more than 3s.
A rough maximum time would be around 5 minutes.

The user wants wants continuous feedback on each quality check that is finished.
 * Which one that is currently running
 * the status of the check (Ok/Failed). If it fails the user wants to know why (summary) and where to find more details.
 * the time it took to run a check

# REQ-uc_leverage_compiler
partof: REQ-purpose
###

Modern compilers are able to warn of problematic code constructs and thus able to prevent them. This is among the cheapest and easiest ways of catching bugs.

The user wants the compiler warnings to be part of the quality check test suite.

The user wants statistics for the current problems and how they over time has changed.

The user wants to continuously work with improving the source code. To make this easier the user wants to track how the compiler warnings change and get a warning when they increase.

The user may want to add additional warning flags when using the compiler via this program

# REQ-uc_filter
partof: REQ-purpose
###

The user wants to filter what is quality checked.

## Rationale

There may be source code that isn't under the users control. This may be [vendored libraries](definitions.md#D-vendor).
The user may have source code that is more or less accidentally analyzed but isn't of interest to quality check.

# REQ-uc_paths_relative_config
partof: REQ-purpose
###

The user wnats to be able to specify paths in the configuration file for the program such that they can be used by other users than the one editing the configuration file.

The user may namely invoke the program from some other location. It is then important that all paths are calculated relative to the config file. Not from what the users currently working directory is.

# REQ-uc_logfiles
partof: REQ-purpose
###

The user wants the warnings to be stored in a file per source code file that is analyzed.
This is to make it easier to read and understand the errors in those cases the user do not run inside e.g. an IDE which visualizes the result.
