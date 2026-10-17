/**
Tests for the bounded incoming mailbox (see README, "Bounded mailbox").

Covers the required scenarios:
- the 2-worker deadlock setup: bounded mailbox + busy worker + a send from
  another actor worker => no deadlock, the send drops, the sender proceeds;
- no loss beyond policy: processed + dropped == total sent;
- shutdown of a bounded actor does not deadlock;
- a non-actor sender blocks on a full bounded mailbox and is delivered when
  space opens (never dropped);
- the default (unbounded) mailbox is unchanged.

Polling style (failAfter + sleep) follows the existing system/actor tests —
no closures, so the latches need no capture shenanigans.
*/
module my.actor.bounded_mailbox;

import core.thread : Thread;
import std.conv : to;
import std.datetime : Clock, dur;
import std.parallelism : TaskPool;

import my.actor;
import my.gc.refc : RefCounted, refCounted;

/// Actor that blocks in its `busy` handler until the gate is raised, so its
/// mailbox can be observed in the full state.
static class BusyCanary {
    private RefCounted!bool gate;
    private RefCounted!bool started;
    private RefCounted!int processed;

    this(RefCounted!bool g, RefCounted!bool s, RefCounted!int p) {
        gate = g;
        started = s;
        processed = p;
    }

    void busy() {
        started.get = true;
        while (!gate.get)
            Thread.sleep(1.dur!"msecs");
    }

    void tick() {
        processed.get++;
    }
}

/// Actor that relays n messages to a target from a pool worker.
static class Sender {
    private WeakAddress target;
    private RefCounted!bool done;

    this(WeakAddress t, RefCounted!bool d) {
        target = t;
        done = d;
    }

    void send(int n) {
        foreach (i; 0 .. n)
            dynSend(target, "tick");
        done.get = true;
    }
}

@(
        "bounded mailbox: full queue + busy worker + actor-worker send => no deadlock, send drops, sender proceeds")
@system unittest {
    // Exactly the deadlock setup the bound must prevent: a 2-worker pool in
    // which the canary occupies one worker (stuck handler) and its bounded
    // mailbox is full. If an actor worker blocked on the full mailbox, the
    // second pool slot would be consumed as well and nothing could ever
    // drain the queue. Workers drop instead of blocking.
    auto sys = System(SystemConfig.init, new TaskPool(2), true);

    auto gate = refCounted(false);
    auto canaryStarted = refCounted(false);
    auto processed = refCounted(0);
    auto canary = sys.spawnBounded!BusyCanary(5, gate, canaryStarted, processed);
    auto senderDone = refCounted(false);
    auto sender = sys.spawn!Sender(canary.weakRef, senderDone);

    // Block the canary inside its handler so its mailbox can fill up.
    dynSend(canary.weakRef, "busy");
    const failAfter = Clock.currTime + 3.dur!"seconds";
    while (!canaryStarted.get && Clock.currTime < failAfter)
        Thread.sleep(1.dur!"msecs");
    assert(canaryStarted.get, "canary never entered the busy handler");

    // The agent sends while the canary is stuck: 5 fit in the bound, the
    // rest must be dropped by the sending worker — which must proceed.
    dynSend(sender.weakRef, "send", 10);
    const failAfter2 = Clock.currTime + 3.dur!"seconds";
    while (!senderDone.get && Clock.currTime < failAfter2)
        Thread.sleep(1.dur!"msecs");
    assert(senderDone.get, "DEADLOCK: the sending worker did not proceed");

    // While the canary is stuck: nothing is processed, exactly 5 are queued,
    // and the remaining 5 were dropped.
    assert(processed.get == 0, "busy canary must not process while stuck");
    assert(canary.addr.get.dropped == 5UL, "worker sends to a full bounded mailbox must drop");

    // Release the canary: it drains the queued messages; the drops stand.
    gate.get = true;
    const failAfter3 = Clock.currTime + 3.dur!"seconds";
    while (processed.get != 5 && Clock.currTime < failAfter3)
        Thread.sleep(1.dur!"msecs");
    assert(processed.get == 5, "the canary must drain the 5 queued messages");

    // No loss beyond policy: everything sent was either processed or dropped.
    const dropped = canary.addr.get.dropped;
    assert(processed.get + dropped == 10, "no loss beyond the drop policy: " ~ to!string(
            processed.get) ~ " processed + " ~ to!string(dropped) ~ " dropped != 10 sent");

    sys.shutdown;
}

@("bounded mailbox: shutdown of a full bounded actor does not deadlock")
@system unittest {
    static class ExitingCanary {
        private RefCounted!bool gate;
        private RefCounted!bool started;
        private RefCounted!bool exited;

        this(RefCounted!bool g, RefCounted!bool s, RefCounted!bool e) {
            gate = g;
            started = s;
            exited = e;
        }

        void busy() {
            started.get = true;
            while (!gate.get)
                Thread.sleep(1.dur!"msecs");
        }

        void tick() {
        }

        void onExit(ExitMsg msg) @safe {
            exited.get = true;
        }
    }

    auto sys = System(SystemConfig.init, new TaskPool(2), true);

    auto gate = refCounted(false);
    auto started = refCounted(false);
    auto exited = refCounted(false);
    auto canary = sys.spawnBounded!ExitingCanary(3, gate, started, exited);
    auto senderDone = refCounted(false);
    auto sender = sys.spawn!Sender(canary.weakRef, senderDone);

    dynSend(canary.weakRef, "busy");
    const failAfter = Clock.currTime + 3.dur!"seconds";
    while (!started.get && Clock.currTime < failAfter)
        Thread.sleep(1.dur!"msecs");
    assert(started.get, "canary never entered the busy handler");

    // Fill the bounded mailbox exactly (3 fit, nothing drops).
    dynSend(sender.weakRef, "send", 3);
    const failAfter2 = Clock.currTime + 3.dur!"seconds";
    while (!senderDone.get && Clock.currTime < failAfter2)
        Thread.sleep(1.dur!"msecs");
    assert(senderDone.get, "DEADLOCK: the sender did not proceed");

    // Ask the stuck actor to exit — system messages are never bounded — and
    // let it finish: it must drain the queue, run onExit and stop.
    sendExit(canary.weakRef, ExitReason.userShutdown);
    gate.get = true;
    const failAfter3 = Clock.currTime + 3.dur!"seconds";
    while (!exited.get && Clock.currTime < failAfter3)
        Thread.sleep(1.dur!"msecs");
    assert(exited.get, "onExit of the bounded actor never ran");

    // Shutting down a system whose bounded actor just finished must not
    // deadlock.
    sys.shutdown;
}

@("bounded mailbox: non-actor sender blocks on a full queue and is delivered when space opens")
@system unittest {
    auto sys = System(SystemConfig.init, new TaskPool(2), true);

    auto gate = refCounted(false);
    auto started = refCounted(false);
    auto processed = refCounted(0);
    auto canary = sys.spawnBounded!BusyCanary(2, gate, started, processed);
    auto senderDone = refCounted(false);
    auto sender = sys.spawn!Sender(canary.weakRef, senderDone);

    dynSend(canary.weakRef, "busy");
    const failAfter = Clock.currTime + 3.dur!"seconds";
    while (!started.get && Clock.currTime < failAfter)
        Thread.sleep(1.dur!"msecs");
    assert(started.get, "canary never entered the busy handler");

    // Fill the mailbox exactly: 2 fit, no drops.
    dynSend(sender.weakRef, "send", 2);
    const failAfter2 = Clock.currTime + 3.dur!"seconds";
    while (!senderDone.get && Clock.currTime < failAfter2)
        Thread.sleep(1.dur!"msecs");
    assert(senderDone.get, "DEADLOCK: the sender did not proceed");

    // A non-actor thread sending to the now-full mailbox must block, not
    // drop. Run it in a helper thread so the test can observe the block.
    auto sent = refCounted(false);
    auto blockingSender = new Thread(() {
        dynSend(canary.weakRef, "tick");
        sent.get = true;
    });
    blockingSender.start;

    Thread.sleep(300.dur!"msecs");
    assert(!sent.get, "non-actor sender must block while the bounded mailbox is full");

    // Space opens when the canary drains: the blocked send must then be
    // delivered, not dropped.
    gate.get = true;
    const failAfter3 = Clock.currTime + 3.dur!"seconds";
    while (!sent.get && Clock.currTime < failAfter3)
        Thread.sleep(1.dur!"msecs");
    assert(sent.get, "the blocked non-actor sender never completed");
    blockingSender.join;
    const failAfter4 = Clock.currTime + 3.dur!"seconds";
    while (processed.get != 3 && Clock.currTime < failAfter4)
        Thread.sleep(1.dur!"msecs");
    assert(processed.get == 3, "all three ticks must be processed");
    assert(canary.addr.get.dropped == 0, "non-actor sends must never be dropped");

    sys.shutdown;
}

@("default mailbox stays unbounded: a burst is fully delivered, no drops")
@system unittest {
    static class Counter {
        private RefCounted!int processed;

        this(RefCounted!int p) {
            processed = p;
        }

        void tick() {
            processed.get++;
        }
    }

    auto sys = makeSystem;

    auto processed = refCounted(0);
    auto addr = sys.spawn!Counter(processed);

    foreach (i; 0 .. 200)
        dynSend(addr.weakRef, "tick");

    const failAfter = Clock.currTime + 3.dur!"seconds";
    while (processed.get != 200 && Clock.currTime < failAfter)
        Thread.sleep(1.dur!"msecs");
    assert(processed.get == 200, "a burst of 200 must be fully delivered");
    assert(addr.addr.get.mailboxBound == 0, "default spawn must leave the mailbox unbounded");
    assert(addr.addr.get.dropped == 0, "an unbounded mailbox must never drop");

    sys.shutdown;
}

@("the actor-worker mark is thread-local: it never crosses threads")
@system unittest {
    // Pins the per-thread semantics the full-mailbox drop policy relies
    // on: a mark set on one thread must be invisible to every other
    // thread, and a thread starting up must not clobber another thread's
    // mark. (The bounded-mailbox review found a shared mark table that a
    // new thread's first touch of the module wiped — a wiped mark makes a
    // pool worker block on a full mailbox and deadlock the pool; a leaked
    // mark makes a plain thread drop its messages. The thread-local mark
    // cannot suffer either: every thread has its own copy.)
    auto otherSawIt = refCounted(false);
    auto t = new Thread(() {
        otherSawIt = !isActorWorker();
        setActorWorker(true); // this thread's own copy; left set on purpose
    });
    setActorWorker(true);
    t.start;
    t.join;
    assert(otherSawIt, "a fresh thread must see the worker mark as unset");
    assert(isActorWorker(), "a new thread must not clobber this thread's mark");
    setActorWorker(false);
    assert(!isActorWorker(), "the cleared mark must stay cleared");

    // Re-entrancy on one thread: the depth survives inner exits.
    setActorWorker(true);
    setActorWorker(true);
    setActorWorker(false);
    assert(isActorWorker(), "an inner exit must not clear the outer mark");
    setActorWorker(false);
    assert(!isActorWorker());
}
