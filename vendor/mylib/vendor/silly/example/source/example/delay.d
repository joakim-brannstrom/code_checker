module example.delay;

import core.thread : Thread;
import core.time   : msecs;

@("This test suspends runner thread for 500 ms #0")
unittest {
	Thread.getThis.sleep(500.msecs);
}

@("This test suspends runner thread for 500 ms #1")
unittest {
	Thread.getThis.sleep(500.msecs);
}

@("This test suspends runner thread for 500 ms #2")
unittest {
	Thread.getThis.sleep(500.msecs);
}

@("This test suspends runner thread for 500 ms #3")
unittest {
	Thread.getThis.sleep(500.msecs);
}

@("This test suspends runner thread for 500 ms #4")
unittest {
	Thread.getThis.sleep(500.msecs);
}

@("This test suspends runner thread for 500 ms #5")
unittest {
	Thread.getThis.sleep(500.msecs);
}