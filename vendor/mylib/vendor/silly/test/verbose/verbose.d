module verbose;

import core.time;
import core.thread;

@("1", "this UDA should be ignored")
unittest {
	Thread.getThis.sleep(1.seconds);
}

@("2")
unittest {
	Thread.getThis.sleep(500.msecs);
}

@("3")
unittest {
	Thread.getThis.sleep(250.msecs);
}

@("4")
unittest {
	assert(false);
}