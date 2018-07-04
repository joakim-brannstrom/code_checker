# Timeout

There should probably be a timeout for checks.

What if they get stuck?

When the user is running in *fast mode*.

# User Defined Analyses

The user should be able to define analysers in the configuration file.

# compile_commands.json

Have an option that force it to be regenereated. This fixes those that are in the root but contain relative paths.

Check the timestamp on "other" compile_commands.json to see if the one in the root is newer than them.
If it isn't then regenereate it.

Be able to filter the files analyzed from the compile_commands.json.
There are sometimes more files than necessary.

Be able to configure the compiler flag filter.

Be able to deduplicate analysis of files. There are sometimes multiple occurances of the same file in a compile_commands.json.

# binary

must be possible to configure what clang-tidy executable to use.

# git

only analyze those files that have been changed compared to a target branch.
