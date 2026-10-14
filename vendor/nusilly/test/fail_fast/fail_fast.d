module error;

@("test ok")
unittest { assert(true); }

@("assert failing")
unittest { assert(false); }

@("throw Exception")
unittest {
	throw new Exception("An exception");
}

@("throw Error")
unittest {
	import core.exception : RangeError;

	throw new RangeError;
}

@("throw OutOfMemoryError")
unittest {
	import core.exception : OutOfMemoryError;

	throw new OutOfMemoryError;
}

@("test that not should be executed")
unittest { assert(true); }

