# code_checker [![Build Status](https://travis-ci.org/joakim-brannstrom/code_checker.svg?branch=master)](https://travis-ci.org/joakim-brannstrom/code_checker)

**code_checker** is a tool that perform a quality check of source code. The intended use is as an automated sanity check of code before e.g. a PR is accepted, a manual inspection by a human etc.

It is intended to be language agnostic by first defining certain hooks that encode best practise.

For now it has hooks ready made for C++ using clang static analyzers.

# Getting Started

code_checker depends on the following software packages:

 * [D compiler](https://dlang.org/download.html) (dmd 2.079+, ldc 1.8.0+)
 * clang-tidy

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
