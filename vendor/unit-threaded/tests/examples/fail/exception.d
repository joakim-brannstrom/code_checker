module tests.fail.exception;


import unit_threaded;


class CustomException: Exception {
    this(string msg) { super(msg); }
}

@HiddenTest("Don't want to pollute the output")
@("custom")
unittest {
    throw new CustomException("This should have a stack trace in the output");
}

class NormalException: UnitTestException {
    this(string msg, in string file = __FILE__, in ulong line = __LINE__) {
        super([msg], file, line);
    }
}

@("normal")
unittest {
    throw new NormalException("This should not have a stack trace in the output");
}
