# code_checker [![Build Status](https://dev.azure.com/wikodes/wikodes/_apis/build/status/joakim-brannstrom.code_checker?branchName=master)](https://dev.azure.com/wikodes/wikodes/_build/latest?definitionId=5&branchName=master)

**code_checker** is a tool that perform a quality check of C/C++ code. The
intended use is as an automated sanity check of code before e.g. a pull request
is accepted, a manual inspection by a human etc.

The feature that set it apart from other `clang-tidy` wrappers is its ability
for re-analyze of failing or changed files. It keep track of passed files and
their dependencies (header). If any dependency, or the file itselt, is changed
it is re-analyzed. This significantly reduces the time it takes to run
`clang-tidy`.

It also provides a convenient integration with `iwyu`.

# Getting Started

code_checker depends on the following software packages:

 * [D compiler](https://dlang.org/download.html) (dmd 2.079+, ldc 1.8.0+)
 * clang-tidy (4.0+)

For users running Ubuntu one of the dependencies can be installed with apt.
```sh
sudo apt install clang-tidy
```

Download the D compiler of your choice, extract it and add to your PATH shell
variable.
```sh
# example with an extracted DMD
export PATH=/path/to/dmd/linux/bin64/:$PATH
```

Once the dependencies are installed it is time to download the source code to install code_checker.
```sh
git clone https://github.com/joakim-brannstrom/code_checker.git
cd code_checker
dub build -b release
```

Done! The binary is place in build/.
Have fun.
Don't be shy to report any issue that you find.

# Config

The default configuration file that `code_checker` use is located at
`<binary>/../etc/code_checker/default.toml`.

The following configuration options can use `{code_checker}` in the config to
replace it with the directory where the `code_checker` binary is.

 * `[clang_tidy] system_config`
 * `[defaults] system_config`
 * `[iwyu] default_mapping_files`
 * `[iwyu] mapping_files`
