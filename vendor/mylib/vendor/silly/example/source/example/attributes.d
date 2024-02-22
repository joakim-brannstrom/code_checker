module example.attributes;

@("@safe works for passing tests")
@safe unittest {
	assert(true);
}

@("@safe works for failing tests")
@safe unittest {
	assert(false);
}

@("pure as well works for passing tests")
pure unittest {
	assert(true);
}

@("pure as well works for failing tests")
pure unittest {
	assert(false);
}

@("@nogc? There's some")
@nogc unittest {
	assert(true);
}

@("@nogc? There's some even for the ones who failed")
@nogc unittest {
	assert(false);
}