module example.named;

@("Hello! It's me, your named unittest")
unittest {
	assert(true);
}

@("And this is my little brother Jim. Jim is silly, he always fails")
unittest {
	assert(false);
}