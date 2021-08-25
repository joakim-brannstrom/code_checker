module issue_10;

struct S {
	@("Hello")
	unittest {
		assert(true);
	}
}
