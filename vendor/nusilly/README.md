NuSilly [![Repository](https://img.shields.io/badge/repository-on%20GitHub-black.svg)](https://github.com/Inochi2D/nusilly) [![ISC
Licence](https://img.shields.io/badge/licence-ISC-blue.svg)](https://github.com/Inochi2D/nusilly/blob/main/LICENSE) [![Package
version](https://img.shields.io/dub/v/nusilly.svg)](https://github.com/Inochi2D/nusilly/tags)
=====

**NuSilly** is a modern and light test runner for the D programming language.

NuSilly is forked from `silly`, a package by Anton Fediushin.  
This package aims to update NuSilly to work better with newer releases of DLang and other tooling such as redub.

# Features

- Easy to install and use with dub
- No changes of your code are required to start using silly
- Seamless integration with `dub test`
- Named tests
- Multi-threaded test execution
- Filtering tests
- Colourful output

# Getting started

Add **nusilly** to your project:

```
$ dub add nusilly
```

This should be it! Try to run tests:

```
$ dub test
```

If it succeeded then congratulations, you have just finished setting up **silly**! Make sure to add more tests and give them nice names.

# Troubleshooting

Unfortunately, setup isn't that easy sometimes and running `dub test` will fail. Don't panic, most of the issues are caused by the quirks and twists of dub. Here are some suggestions on what to check first:

## Make sure `main()` function isn't defined when built in `unittest` mode

So, instead of this:
```d
void main() {

}
```

Do this:
```d
version(unittest) {
	// Do nothing here, dub takes care of that
} else {
	void main() {

	}
}
```

## Make sure there is a special `unittest` configuration in your dub.json/dub.sdl

```json
{
    ...
	"configurations": [
		{
			"name": "executable"
		},
		{
			"name": "unittest"
		}
	]
}
```

See also [#32](https://gitlab.com/AntonMeep/silly/issues/32).

> **Pro Tip**: dub configurations can have `dependencies` as well! You may want to add silly as a dependency only for the `unittest` configuration to indicate that it's only used for tests.

## Make sure there is no `targetType: executable` in `unittest` configuration in your dub.json/dub.sdl

Instead of this:

```json
{
	...
	"configurations": [
		...
		{
			"name": "unittest",
			"targetType": "executable",
			...
		}
	]
}
```

Do this:

```json
{
	...
	"configurations": [
		...
		{
			"name": "unittest",
			...
		}
	]
}
```

See [#12](https://gitlab.com/AntonMeep/silly/issues/12) for more information.

## Nothing helped?

Open a new [issue](https://gitlab.com/AntonMeep/silly/issues), we will be happy to help you!

# Naming tests

It is as easy as adding a `string` [user-defined attribute](https://dlang.org/spec/attribute.html#UserDefinedAttribute) to your `unittest` declaration.

```d
@("Johny")
unittest {
	// This unittest is named Johny
}
```

If there are multiple such UDAs, the first one is chosen to be the name of the unittest.

```d
@("Hello, ") @("World!")
unittest {
	// This unittest's name is "Hello, "
}
```

# Command line options

**Silly** accept various command-line options that let you customize its behaviour:

```
$ dub test -- <options>

Options:
  --no-colours                    Disable colours
  -t <n>      --threads <n>       Number of worker threads. 0 to auto-detect (default)
  -i <regexp> --include <regexp>  Run tests if their name matches specified regular expression. See filtering tests
  -e <regexp> --exclude <regexp>  Skip tests if their name matches specified regular expression. See filtering tests
              --fail-fast         Stop executing all tests when a test fails
  -v          --verbose           Show verbose output (full stack traces, location and durations)
  -h          --help              Help information
```

# Filtering tests

With `--include` and `--exclude` options it's possible to control what tests will be run. These options take regular expressions in [std.regex'](https://dlang.org/phobos/std_regex.html#Syntax%20and%20general%20information) format.

`--include` only tests that match provided regular expression will be run, other tests will be skipped.
`--exclude` all of the tests that don't match provided regular expression will be run.

> Using both options at the same time will produce unexpected results!

# Best practices

- Running tests in multi-threaded mode (default) can potentially cause issues, try running tests with `--threads 1`
- Although unittests inside of nested classes and structs are discovered and executed by Silly, it may be unreliable. Consider having unittest blocks on the toplevel

