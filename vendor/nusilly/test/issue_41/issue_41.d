module issue_41;

class Foo
{
	@("root class")
		pure @safe unittest
		{
			assert(true);
		}

	static class Bar
	{
		@("nested static class")
			pure @safe unittest
			{
				assert(true);
			}
	}

	class Baz
	{
		@("nested class")
			pure @safe unittest
			{
				assert(true);
			}
	}
}

@("normal unittest")
unittest {
	assert(true);
}

