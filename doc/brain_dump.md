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
