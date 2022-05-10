/**
Copyright: Copyright (c) 2022, Joakim Brännström. All rights reserved.
License: $(LINK2 http://www.boost.org/LICENSE_1_0.txt, Boost Software License 1.0)
Author: Joakim Brännström (joakim.brannstrom@gmx.com)
*/
module code_checker.types;

enum FileStatus : ubyte {
    normal,
    /// clang-tidy triggered the timeout
    clangTidyTimeout,
    /// clang-tidy failed to run on the file, no output.
    clangTidyFailed,
}
