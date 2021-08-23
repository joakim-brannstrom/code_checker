silly [![Repository](https://img.shields.io/badge/repository-on%20GitLab-orange.svg)](https://gitlab.com/AntonMeep/silly) [![pipeline
status](https://gitlab.com/AntonMeep/silly/badges/master/pipeline.svg)](https://gitlab.com/AntonMeep/silly/commits/master) [![coverage
report](https://gitlab.com/AntonMeep/silly/badges/master/coverage.svg)](https://gitlab.com/AntonMeep/silly/commits/master) [![ISC
Licence](https://img.shields.io/badge/licence-ISC-blue.svg)](https://gitlab.com/AntonMeep/silly/blob/master/LICENSE) [![Package
version](https://img.shields.io/dub/v/silly.svg)](https://gitlab.com/AntonMeep/silly/tags)
=====

**silly** is a modern and light test runner for the D programming language.

# Used by

[Optional](http://optional.dub.pm/), [expected](http://expected.dub.pm/), [ddash](http://ddash.dub.pm/), and more!

> Got a cool project that uses **silly**? [Let us know!](https://gitlab.com/AntonMeep/silly/issues)

# Features

- Easy to install and use with dub
- No changes of your code are required to start using silly
- Seamless integration with `dub test`
- Named tests
- Multi-threaded test execution
- Filtering tests
- Colourful output

# Getting started

Add **silly** to your project:

```
$ dub add silly
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
  -v          --verbose           Show verbose output (full stack traces and durations)
  -h          --help              Help information
```

# Filtering tests

With `--include` and `--exclude` options it's possible to control what tests will be run. These options take regular expressions in [std.regex'](https://dlang.org/phobos/std_regex.html#Syntax%20and%20general%20information) format.

`--include` only tests that match provided regular expression will be run, other tests will be skipped.
`--exclude` all of the tests that don't match provided regular expression will be run.

> Using both options at the same time will produce unexpected results!
