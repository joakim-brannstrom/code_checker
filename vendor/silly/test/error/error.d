module error;

@("1")
unittest { }

@("2")
unittest { assert(false); }

@("3")
unittest {
	import core.exception : RangeError;

	throw new RangeError;
}

@("4")
unittest { }
