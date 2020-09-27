module issue_2;

@("Throwing an exception with multi-line message")
unittest {
	throw new Exception("Hello,\nWorld!");
}