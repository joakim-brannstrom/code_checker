/**
Copyright: Copyright (c) Joakim Brännström. All rights reserved.
License: $(LINK2 http://www.boost.org/LICENSE_1_0.txt, Boost Software License 1.0)
Author: Joakim Brännström (joakim.brannstrom@gmx.com)
*/
module my.actor.channel;

import std.datetime : SysTime;
import std.meta : staticMap;
import std.traits : Parameters, ReturnType, Unqual;
import std.typecons : Tuple;

import my.actor.actor : ActorShell, Promise;
import my.actor.behavior : ActorRef;
import my.actor.common : methodSignature;
import my.actor.mailbox : DelayedMsg, Msg, MsgOneShot, MsgRequest, MsgType,
    TypedAddress, WeakAddress, isTypedAddress, makePayload;
import my.actor.msg : request, RequestSendThen;
import my.actor.registration : countMethods, messageMethod;

/// Build the request/reply message and chain; the reply lands in the
/// requesting actor's mailbox (the `.capture(...).then(...)` machinery of
/// my.actor.msg finishes the registration).
private auto doRequest(Args...)(ActorShell* self, WeakAddress target,
        SysTime timeout, ulong sig, auto ref Args args) @trusted {
    auto rs = request(self, target, timeout);
    auto msg = Msg(sig, MsgType(MsgRequest(self.addr.weakRef, rs.replyId, makePayload(args))));
    return RequestSendThen(rs, msg);
}

/** Send-side handle for the message methods of `T` (an actor class or an
 * interface). One method per message; zero-arg methods work naturally.
 * Non-void methods return the request chain (.capture(...).then(...)).
 *
 * The checked path: the compile-time guard rejects any `method` that is not
 * exactly one message method of `T`. For unchecked sends by name, use
 * `dynSend` / `dynRequest` / `dynDelayedSend`.
 *
 * Preferred construction is from a `TypedAddress!C` (the result of
 * `spawn!C`): the compiler then verifies that `C` is `T` or implements it.
 * The `WeakAddress` constructors stay as the explicit "you vouch for the
 * type" path: call sites are still checked against `T`, but the actor/type
 * pairing is unverifiable.
 */
struct Channel(T) {
    WeakAddress target;
    /// Requesting actor (needed for request/reply); pass null only for
    /// send-only channels.
    ActorShell* self;
    SysTime timeout = SysTime.max;

    this(WeakAddress target, ActorShell* self, SysTime timeout = SysTime.max) @safe {
        this.target = target;
        this.self = self;
        this.timeout = timeout;
    }

    /// Convenience: the actor's own handle (`self_` saved in onSpawn).
    this(WeakAddress target, ActorRef self, SysTime timeout = SysTime.max) @safe {
        this(target, self.kernel, timeout);
    }

    /// Preferred: the actor's typed address. The compiler enforces that `C`
    /// is `T` or implements it; the WeakAddress ctors only check call sites.
    this(C)(TypedAddress!C h, ActorShell* self, SysTime timeout = SysTime.max) @safe
            if (is(C : T)) {
        this(h.weakRef, self, timeout);
    }

    /// Convenience: the actor's own handle (`self_` saved in onSpawn).
    this(C)(TypedAddress!C h, ActorRef self, SysTime timeout = SysTime.max) @safe
            if (is(C : T)) {
        this(h.weakRef, self.kernel, timeout);
    }

    auto opDispatch(string method, Args...)(auto ref Args args) {
        alias UArgs = staticMap!(Unqual, Args);
        enum found = countMethods!(T, method, UArgs)();
        static assert(found == 1,
                "no message method `" ~ method ~ "(" ~ UArgs.stringof ~ ")` on " ~ T.stringof);
        alias m = messageMethod!(T, method, UArgs);
        alias R = ReturnType!m;
        alias HArgs = staticMap!(Unqual, Parameters!m);
        const sig = methodSignature!HArgs(method);

        static if (is(R == void)) {
            if (auto addr = target.lock.get)
                addr.put(Msg(sig, MsgType(MsgOneShot(makePayload(args)))));
        } else {
            assert(self !is null, "request/reply needs a requesting actor (self)");
            return doRequest(self, target, timeout, sig, args);
        }
    }
}

/// Dynamic send by method name (no compile-time checking) — the untyped path.
/// Arguments must have the exact Unqual parameter types of the target method;
/// an implicit conversion (e.g. a byte for an int parameter) produces a
/// mismatching signature and the message is silently dropped.
void dynSend(Args...)(WeakAddress target, string method, auto ref Args args) @trusted {
    alias UArgs = staticMap!(Unqual, Args);
    const sig = methodSignature!UArgs(method);
    if (auto addr = target.lock.get)
        addr.put(Msg(sig, MsgType(MsgOneShot(makePayload(args)))));
}

/// Dynamic request by method name (no compile-time checking). Arguments must
/// have the exact Unqual parameter types of the target method; an implicit
/// conversion (e.g. a byte for an int parameter) produces a mismatching
/// signature and the message is silently dropped.
auto dynRequest(Args...)(ActorShell* self, WeakAddress target, SysTime timeout,
        string method, auto ref Args args) @trusted {
    alias UArgs = staticMap!(Unqual, Args);
    return doRequest(self, target, timeout, methodSignature!UArgs(method), args);
}

/// Convenience: dynamic request from the actor's own handle (same exact
/// Unqual parameter-type requirement as the `ActorShell*` overload).
auto dynRequest(Args...)(ActorRef self, WeakAddress target, SysTime timeout,
        string method, auto ref Args args) @trusted {
    return dynRequest(self.kernel, target, timeout, method, args);
}

/// Delayed dynamic send by method name. The message waits in the target's
/// delayed queue until `delayTo`. Arguments must have the exact Unqual
/// parameter types of the target method; an implicit conversion (e.g. a byte
/// for an int parameter) produces a mismatching signature and the message is
/// silently dropped.
void dynDelayedSend(Args...)(WeakAddress target, SysTime delayTo, string method, auto ref Args args) @trusted {
    alias UArgs = staticMap!(Unqual, Args);
    if (auto addr = target.lock.get)
        addr.put(DelayedMsg(Msg(methodSignature!UArgs(method),
                MsgType(MsgOneShot(makePayload(args)))), delayTo));
}

/// Dynamic send by method name through a typed handle (unchecked; erased to
/// the weak form before sending).
void dynSend(C, Args...)(TypedAddress!C h, string method, auto ref Args args) @trusted {
    dynSend(h.weakRef, method, args);
}

/// Dynamic request by method name through a typed handle (unchecked).
auto dynRequest(C, Args...)(ActorShell* self, TypedAddress!C h, SysTime timeout,
        string method, auto ref Args args) @trusted {
    return dynRequest(self, h.weakRef, timeout, method, args);
}

/// Convenience: dynamic request from the actor's own handle (same exact
/// Unqual parameter-type requirement as the `ActorShell*` overload).
auto dynRequest(C, Args...)(ActorRef self, TypedAddress!C h, SysTime timeout,
        string method, auto ref Args args) @trusted {
    return dynRequest(self.kernel, h.weakRef, timeout, method, args);
}

/// Delayed dynamic send by method name through a typed handle (unchecked;
/// erased to the weak form before sending).
void dynDelayedSend(C, Args...)(TypedAddress!C h, SysTime delayTo, string method, auto ref Args args) @trusted {
    dynDelayedSend(h.weakRef, delayTo, method, args);
}

unittest {
    import core.thread : Thread;
    import std.datetime : Clock, dur;

    import my.actor.common : ExitReason;
    import my.actor.mailbox : makeAddress;
    import my.actor.msg : capture, infTimeout, sendExit, then;
    import my.actor.registration : implActor;

    interface IDing {
        void ding(int v); // same parameter list as IDong.dong below
        int total(); // zero-arg request
    }

    interface IDong {
        void dong(int v);
        void tick(); // zero-arg one-shot
    }

    class Multi : IDing, IDong { // plain class — no framework base class
        int sum;
        int ticks;
        bool spawned;

        void onSpawn(ActorRef self) @safe { // optional hook
            spawned = true;
        }

        override void ding(int v) {
            sum += v;
        }

        override void dong(int v) {
            sum += v * 10;
        }

        override void tick() {
            ticks++;
        }

        override int total() {
            return sum;
        }
    }

    class Plain { // no interface: untyped actor class; no onSpawn (optional)
        int count;
        void add(int v) {
            count += v;
        }

        void reset() {
            count = 0;
        }

        int getCount() {
            return count;
        }
    }

    class Lifecycle { // ctor/onSpawn ordering demo
        string log;
        this() {
            log ~= "ctor;"; // runs on the spawning thread, before the shell is bound
        }

        void onSpawn(ActorRef self) @safe {
            log ~= "onSpawn;"; // first execution on the actor's own context
        }

        void ping() { // zero-arg message
            log ~= "ping;";
        }
    }

    interface ICount {
        void kick();
        int getCount();
        void introduce(WeakAddress other);
    }

    class Bare : ICount { // no framework base class, no inheritance at all
        int count;
        int helloBacks;
        private ActorRef self_; // saved handle — the only path to self-ops
        void onSpawn(ActorRef self) @safe {
            self_ = self; // use it -> save; otherwise just discard the argument
        }

        override void kick() {
            dynSend(self_.address, "bump"); // self-send through the saved handle
        }

        void bump() {
            count++;
        }

        override int getCount() {
            return count;
        }

        override void introduce(WeakAddress other) {
            dynSend(other, "remember", self_.address); // pass one's own address on
        }

        void helloBack() {
            helloBacks++;
        }
    }

    class Echoer { // replies to the address it was given; needs no handle itself
        void remember(WeakAddress back) {
            dynSend(back, "helloBack"); // send a message back to that address
        }
    }

    class Crashy {
        int caught;
        void boom() { // a throwing message handler
            throw new Exception("bang");
        }

        void onException(Exception e) { // optional hook; member access works
            caught++;
        }
    }

    class NoHook { // same but without the hook: the default error path applies
        void boom() {
            throw new Exception("bang");
        }
    }

    // Hook names are never message methods; ordinary methods are counted.
    static assert(countMethods!(Multi, "onSpawn")() == 0);
    static assert(countMethods!(Lifecycle, "onSpawn")() == 0);
    static assert(countMethods!(Bare, "onSpawn")() == 0);
    static assert(countMethods!(Crashy, "onException")() == 0);
    static assert(countMethods!(Multi, "ding", int)() == 1);
    static assert(countMethods!(Multi, "total")() == 1);

    { // --- typed class actor: two interfaces, zero-arg methods, shared params
        auto addr = makeAddress;
        auto actorV = ActorShell(addr);
        auto multi = new Multi;
        implActor(multi, &actorV);

        auto chan = Channel!Multi(addr.weakRef, &actorV, infTimeout());
        actorV.process(Clock.currTime); // the kernel runs the launch hook on first tick
        assert(multi.spawned, "onSpawn hook invoked on launch");

        // the checked path rejects methods that are not message methods of T.
        static assert(!__traits(compiles, chan.missingMethod()));

        chan.ding(1);
        chan.tick();
        foreach (_; 0 .. 4)
            actorV.process(Clock.currTime);
        assert(multi.sum == 1, "ding dispatched");
        assert(multi.ticks == 1, "zero-arg one-shot dispatched");

        chan.dong(2); // identical parameter list as ding(1) -> must stay distinct
        foreach (_; 0 .. 4)
            actorV.process(Clock.currTime);
        assert(multi.sum == 21, "dong dispatched despite same params as ding");

        int t = -1;
        static void onTotal(ref Tuple!(int*) ctx, int v) {
            *ctx[0] = v;
        }

        chan.total().capture(&t).then(&onTotal); // zero-arg request/reply
        foreach (_; 0 .. 4)
            actorV.process(Clock.currTime);
        assert(t == 21, "zero-arg request/reply dispatched");

        // a delegate handler needs no capture at all
        int t2 = -1;
        then(chan.total(), (int v) { t2 = v; });
        foreach (_; 0 .. 4)
            actorV.process(Clock.currTime);
        assert(t2 == 21, "a capturing delegate handler is invoked");

        // a delegate handler still receives a captured context when one is given
        int t3 = -1;
        chan.total().capture(&t3).then((ref Tuple!(int*) ctx, int v) {
            *ctx[0] = v;
        });
        foreach (_; 0 .. 4)
            actorV.process(Clock.currTime);
        assert(t3 == 21, "a delegate handler also receives the captured context");

        sendExit(addr.weakRef, ExitReason.userShutdown); // shutdown = system message
        int guardV;
        while (actorV.isAlive() && guardV++ < 100)
            actorV.process(Clock.currTime);
        assert(!actorV.isAlive(), "shutdown via the system shutdown message");
    }

    { // --- untyped class actor: dynamic sends/requests by name
        auto addr2 = makeAddress;
        auto actor2V = ActorShell(addr2);
        auto plain = new Plain;
        implActor(plain, &actor2V);
        actor2V.process(Clock.currTime); // no onSpawn declared: hook is optional

        dynSend(addr2.weakRef, "add", 5);
        foreach (_; 0 .. 4)
            actor2V.process(Clock.currTime);
        assert(plain.count == 5, "dynamic send by name");

        dynSend(addr2.weakRef, "reset"); // zero-arg dynamic send
        foreach (_; 0 .. 4)
            actor2V.process(Clock.currTime);
        assert(plain.count == 0, "zero-arg dynamic send");

        int t2 = -1;
        static void onCount(ref Tuple!(int*) ctx, int v) {
            *ctx[0] = v;
        }

        dynSend(addr2.weakRef, "add", 7);
        dynRequest(&actor2V, addr2.weakRef, infTimeout(), "getCount").capture(&t2).then(&onCount);
        foreach (_; 0 .. 4)
            actor2V.process(Clock.currTime);
        assert(t2 == 7, "dynamic request by name");

        sendExit(addr2.weakRef, ExitReason.userShutdown);
        int guard2;
        while (actor2V.isAlive() && guard2++ < 100)
            actor2V.process(Clock.currTime);
    }

    { // --- lifecycle: ctor (spawning thread) -> bind -> onSpawn -> messages
        auto addr3 = makeAddress;
        auto actor3V = ActorShell(addr3);
        auto life = new Lifecycle; // ctor runs here, before any shell is bound
        assert(life.log == "ctor;", "ctor runs on the spawning thread, before binding");
        implActor(life, &actor3V);
        actor3V.process(Clock.currTime); // spawn: onSpawn as the actor's first execution
        assert(life.log == "ctor;onSpawn;", "onSpawn invoked before any message");

        // the ActorRef overload of the Channel constructor (own-handle form).
        auto chan3 = Channel!Lifecycle(addr3.weakRef, ActorRef(&actor3V));
        chan3.ping();
        foreach (_; 0 .. 4)
            actor3V.process(Clock.currTime);
        assert(life.log == "ctor;onSpawn;ping;", "message processed after onSpawn");

        sendExit(addr3.weakRef, ExitReason.userShutdown);
        int guard3;
        while (actor3V.isAlive() && guard3++ < 100)
            actor3V.process(Clock.currTime);
    }

    { // --- no base class at all: actor powers only via the ActorRef self-handle
        auto addr4 = makeAddress;
        auto actor4V = ActorShell(addr4);
        auto bare = new Bare;
        implActor(bare, &actor4V);
        actor4V.process(Clock.currTime); // first tick: onSpawn saves the self handle

        auto chan4 = Channel!ICount(addr4.weakRef, &actor4V, infTimeout());
        chan4.kick();
        foreach (_; 0 .. 6)
            actor4V.process(Clock.currTime);
        assert(bare.count == 1, "self-send via the saved handle");

        int c4 = -1;
        static void onCount4(ref Tuple!(int*) ctx, int v) {
            *ctx[0] = v;
        }

        chan4.getCount().capture(&c4).then(&onCount4);
        foreach (_; 0 .. 4)
            actor4V.process(Clock.currTime);
        assert(c4 == 1, "request/reply for a class without any framework base");

        // the check: pass the address on so another actor can send messages back
        auto addr5 = makeAddress;
        auto actor5V = ActorShell(addr5);
        auto echoer = new Echoer;
        implActor(echoer, &actor5V);
        chan4.introduce(addr5.weakRef); // Bare sends its own address to Echoer
        foreach (_; 0 .. 8) {
            actor4V.process(Clock.currTime);
            actor5V.process(Clock.currTime);
        }
        assert(bare.helloBacks == 1, "address passed on; other actor sent a message back");

        sendExit(addr4.weakRef, ExitReason.userShutdown); // shutdown via system message
        sendExit(addr5.weakRef, ExitReason.userShutdown);
        int guard4;
        while ((actor4V.isAlive() || actor5V.isAlive()) && guard4++ < 100) {
            actor4V.process(Clock.currTime);
            actor5V.process(Clock.currTime);
        }
        assert(!actor4V.isAlive() && !actor5V.isAlive(),
                "shutdown via the system shutdown message");
    }

    { // --- optional onException hook (called by the shell; never a message)
        auto addr6 = makeAddress;
        auto actor6V = ActorShell(addr6);
        auto crashy = new Crashy;
        implActor(crashy, &actor6V);
        dynSend(addr6.weakRef, "boom");
        foreach (_; 0 .. 4)
            actor6V.process(Clock.currTime);
        assert(crashy.caught == 1, "onException hook called for a throwing handler");
        assert(actor6V.isAlive(), "actor survives when the hook handles the exception");
        sendExit(addr6.weakRef, ExitReason.userShutdown);
        int guard6;
        while (actor6V.isAlive() && guard6++ < 100)
            actor6V.process(Clock.currTime);
    }

    {
        auto addr7 = makeAddress;
        auto actor7V = ActorShell(addr7);
        auto noHook = new NoHook;
        implActor(noHook, &actor7V);
        dynSend(addr7.weakRef, "boom");
        foreach (_; 0 .. 6)
            actor7V.process(Clock.currTime);
        assert(!actor7V.isAlive(), "without the hook the shell's default error path applies");
    }

    { // --- dynDelayedSend: a zero-arg message scheduled a few ms ahead
        class Ticker {
            int ticks;
            void tick() {
                ticks++;
            }
        }

        auto addr = makeAddress;
        auto kernel = ActorShell(addr);
        auto c = new Ticker;
        implActor(c, &kernel);

        dynDelayedSend(addr.weakRef, Clock.currTime + 10.dur!"msecs", "tick");
        kernel.process(Clock.currTime); // not due yet: parked in the delay queue
        assert(c.ticks == 0, "delayed message not delivered before its trigger time");

        Thread.sleep(20.dur!"msecs");
        int guardA;
        while (c.ticks == 0 && guardA++ < 100) {
            kernel.process(Clock.currTime);
            Thread.sleep(1.dur!"msecs");
        }
        assert(c.ticks == 1, "delayed message delivered after its trigger time");

        sendExit(addr.weakRef, ExitReason.userShutdown);
        int guardB;
        while (kernel.isAlive() && guardB++ < 100)
            kernel.process(Clock.currTime);
    }

    { // --- typed address: the handle carries the actor's type
        auto addrT = makeAddress;
        auto actorTV = ActorShell(addrT);
        auto multiT = new Multi;
        implActor(multiT, &actorTV);
        actorTV.process(Clock.currTime); // the kernel runs the launch hook on first tick

        auto h = TypedAddress!Multi(addrT); // wraps the kernel address
        static assert(isTypedAddress!(TypedAddress!int));
        static assert(!isTypedAddress!int);

        // negative: an interface Multi does not implement cannot be paired
        interface IUnrelated {
            void nope();
        }

        static assert(!__traits(compiles, Channel!IUnrelated(h, &actorTV, infTimeout())));

        auto chanT = Channel!IDing(h, &actorTV, infTimeout()); // implements IDing
        chanT.ding(1);
        foreach (_; 0 .. 4)
            actorTV.process(Clock.currTime);
        assert(multiT.sum == 1, "checked send through a typed address");

        int tT = -1;
        static void onTotalT(ref Tuple!(int*) ctx, int v) {
            *ctx[0] = v;
        }

        chanT.total().capture(&tT).then(&onTotalT);
        foreach (_; 0 .. 4)
            actorTV.process(Clock.currTime);
        assert(tT == 1, "request/reply through a typed address");

        dynSend(h, "ding", 2);
        dynSend(h, "tick"); // zero-arg dynamic send
        foreach (_; 0 .. 4)
            actorTV.process(Clock.currTime);
        assert(multiT.sum == 3, "dynamic send through a typed address");
        assert(multiT.ticks == 1, "zero-arg dynamic send through a typed address");

        int tT2 = -1;
        static void onTotalT2(ref Tuple!(int*) ctx, int v) {
            *ctx[0] = v;
        }

        dynRequest(ActorRef(&actorTV), h, infTimeout(), "total").capture(&tT2).then(&onTotalT2);
        foreach (_; 0 .. 4)
            actorTV.process(Clock.currTime);
        assert(tT2 == 3, "dynamic request through a typed address");

        dynDelayedSend(h, Clock.currTime + 10.dur!"msecs", "tick");
        actorTV.process(Clock.currTime); // not due yet: parked in the delay queue
        assert(multiT.ticks == 1, "delayed message not delivered before its trigger time");

        Thread.sleep(20.dur!"msecs");
        int guardT;
        while (multiT.ticks == 1 && guardT++ < 100) {
            actorTV.process(Clock.currTime);
            Thread.sleep(1.dur!"msecs");
        }
        assert(multiT.ticks == 2, "dynamic delayed send through a typed address");

        sendExit(h, ExitReason.userShutdown); // system message accepts the typed handle
        int guardT2;
        while (actorTV.isAlive() && guardT2++ < 100)
            actorTV.process(Clock.currTime);
        assert(!actorTV.isAlive(), "shutdown through the typed handle");
    }
}

/// A payload struct with an `immutable` member is not assignable (D forbids
/// `a = b` for it), so it can only reach an actor if the payload is stored as
/// the value itself — `Variant(Tuple!T)` cannot be instantiated for it.
private struct ImmutablePayload {
    string tag;
    immutable(int[]) values;
}

private interface IImmutablePayload {
    void take(ImmutablePayload p);
    ImmutablePayload give();
    Promise!ImmutablePayload deferred();
    void add(int a, int b);
    void tick();
    void takeTuple(Tuple!(int, string) t);
    void takeTwo(int a, string b);
}

private class ImmutableActor : IImmutablePayload {
    size_t calls;
    int sum;
    int tupleInt;
    string tupleText;
    Promise!ImmutablePayload prom;

    this(Promise!ImmutablePayload prom) {
        this.prom = prom;
    }

    // do not store the struct itself: `field = p;` is the very assignment
    // that is illegal for an immutable-bearing payload
    override void take(ImmutablePayload p) {
        ++calls;
        sum = p.values[0];
    }

    override ImmutablePayload give() {
        return ImmutablePayload("g", [7]);
    }

    override Promise!ImmutablePayload deferred() {
        return prom;
    }

    override void add(int a, int b) {
        sum = a + b;
    }

    override void tick() {
        ++calls;
    }

    override void takeTuple(Tuple!(int, string) t) {
        tupleInt = t[0];
        tupleText = t[1];
    }

    override void takeTwo(int a, string b) {
        tupleInt = a;
        tupleText = b;
    }
}

@("Channel: a payload struct with immutable members (value form, box fallback kept)") unittest {
    import std.datetime : Clock, dur;

    import my.actor.actor : makePromise;
    import my.actor.common : ExitReason;
    import my.actor.mailbox : makeAddress;
    import my.actor.msg : capture, infTimeout, sendExit;
    import my.actor.registration : implActor;

    auto addr = makeAddress;
    auto kernel = ActorShell(addr);
    auto deferredProm = makePromise!ImmutablePayload;
    auto a = new ImmutableActor(deferredProm);
    implActor(a, &kernel);

    auto ch = Channel!IImmutablePayload(addr.weakRef, &kernel, infTimeout());
    kernel.process(Clock.currTime);

    // one argument: stored as Variant(ImmutablePayload), not as a Tuple box
    ch.take(ImmutablePayload("a", [1, 2]));
    kernel.process(Clock.currTime);
    assert(a.calls == 1, "immutable-bearing payload dispatched");
    assert(a.sum == 1, "the handler read the immutable member");

    // dynamic path boxes identically
    dynSend(addr.weakRef, "take", ImmutablePayload("b", [3]));
    kernel.process(Clock.currTime);
    assert(a.calls == 2 && a.sum == 3, "dynSend of an immutable-bearing payload");

    // request/reply carrying the payload in both directions
    int got;
    static void onGive(ref Tuple!(int*) ctx, ImmutablePayload p) {
        *ctx[0] = p.values[0]; // read a member: assigning the struct is illegal
    }

    ch.give().capture(&got).then(&onGive);
    kernel.process(Clock.currTime);
    assert(got == 7, "reply carrying an immutable-bearing payload");

    // deferred reply: Promise.deliver boxes the payload the same way
    int gotLater = -1;
    static void onLater(ref Tuple!(int*) ctx, ImmutablePayload p) {
        *ctx[0] = p.values[0];
    }

    ch.deferred().capture(&gotLater).then(&onLater);
    kernel.process(Clock.currTime);
    assert(gotLater == -1, "the deferred reply is not delivered yet");
    auto laterPayload = ImmutablePayload("d", [9]);
    deferredProm.deliver(laterPayload);
    kernel.process(Clock.currTime);
    assert(gotLater == 9, "Promise.deliver of an immutable-bearing payload");

    // dynamic request: same boxing rule as the checked path
    int gotDyn = -1;
    dynRequest(&kernel, addr.weakRef, infTimeout(), "give").capture(&gotDyn).then(&onGive);
    kernel.process(Clock.currTime);
    assert(gotDyn == 7, "dynRequest of an immutable-bearing payload");

    // multi-argument and zero-argument messages keep the Tuple box / empty box
    ch.add(2, 3);
    ch.tick();
    foreach (_; 0 .. 4)
        kernel.process(Clock.currTime);
    assert(a.sum == 5, "multi-argument payload still dispatches");
    assert(a.calls == 3, "zero-argument payload still dispatches");

    // a one-parameter message whose parameter is a tuple, and a two-parameter
    // message with the same element types: same stored Variant type, distinct
    // message signatures
    ch.takeTuple(Tuple!(int, string)(4, "x"));
    kernel.process(Clock.currTime);
    assert(a.tupleInt == 4 && a.tupleText == "x", "tuple-typed single parameter");

    ch.takeTwo(5, "y");
    kernel.process(Clock.currTime);
    assert(a.tupleInt == 5 && a.tupleText == "y", "two parameters of the same element types");

    sendExit(addr.weakRef, ExitReason.userShutdown);
    int guard;
    while (kernel.isAlive() && guard++ < 100)
        kernel.process(Clock.currTime);
}

@("peekOneArg: value form, single-element box, tuple-typed payload") unittest {
    import std.variant : Variant;

    import my.actor.mailbox : peekOneArg;

    auto value = Variant(7);
    assert(peekOneArg!int(value) !is null);
    assert(*peekOneArg!int(value) == 7, "the value form is found");

    auto box = Variant(Tuple!(int)(9));
    assert(peekOneArg!int(box) !is null);
    assert(*peekOneArg!int(box) == 9, "the single-element box is found");

    // a tuple-typed parameter only ever matches the value form: the box probe
    // would ask for a nested Tuple and never matches, so the two are disjoint
    auto tup = Variant(Tuple!(int, string)(1, "x"));
    assert(peekOneArg!(Tuple!(int, string))(tup) !is null);
    assert(peekOneArg!(Tuple!(int, string))(box) is null);

    auto nope = Variant("nope");
    assert(peekOneArg!int(nope) is null, "no match is null, not an exception");

    // a payload type that cannot be copied into a Variant is rejected at compile
    // time, whatever the shape of the message
    struct NoCopy {
        int x;
        @disable this(this);
    }

    static assert(!__traits(compiles, peekOneArg!NoCopy(value)),
            "a non-copyable payload type must not instantiate the probe");
}

@("makePayload: value form for one argument, Tuple box for several") unittest {
    // guard predicate: a struct with immutable members is storable (a Variant
    // copies it, it never assigns it); a non-copyable type is not
    import my.actor.mailbox : isPayloadStorable;

    static assert(isPayloadStorable!ImmutablePayload);
    struct NoCopy {
        int x;
        @disable this(this);
    }

    static assert(!isPayloadStorable!NoCopy);

    // the protocol pin: a single argument must not be wrapped in a Tuple,
    // otherwise a payload with const/immutable members cannot be boxed at all
    assert(makePayload(ImmutablePayload("a", [1]))
            .type == typeid(ImmutablePayload), "a single argument is stored unwrapped");
    assert(makePayload(1, "x").type == typeid(Tuple!(int, string)),
            "several arguments are stored in the Tuple box");
    assert(makePayload().type == typeid(Tuple!()), "zero arguments store the empty tuple");
}
