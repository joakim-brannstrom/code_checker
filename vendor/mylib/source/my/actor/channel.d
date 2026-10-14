/**
Copyright: Copyright (c) Joakim Brännström. All rights reserved.
License: $(LINK2 http://www.boost.org/LICENSE_1_0.txt, Boost Software License 1.0)
Author: Joakim Brännström (joakim.brannstrom@gmx.com)
*/
module my.actor.channel;

import std.datetime : SysTime;
import std.meta : staticMap;
import std.traits : Parameters, ReturnType, Unqual;
import std.typecons : Tuple, tuple;
import std.variant : Variant;

import my.actor.actor : ActorShell;
import my.actor.behavior : ActorRef;
import my.actor.common : methodSignature;
import my.actor.mailbox : DelayedMsg, Msg, MsgOneShot, MsgRequest, MsgType,
    TypedAddress, WeakAddress, isTypedAddress;
import my.actor.msg : request, RequestSendThen;
import my.actor.registration : countMethods, messageMethod;

/// Box the send arguments the same way `implActor` unboxes them at dispatch:
/// an empty tuple for zero-arg messages, a `Tuple!UArgs` otherwise.
/// Package-visible: `my.actor.behavior` reuses it for `ActorRef` sends.
package Variant makePayload(Args...)(auto ref Args args) @trusted {
    alias UArgs = staticMap!(Unqual, Args);
    static if (UArgs.length == 0)
        return Variant(tuple());
    else
        return Variant(Tuple!UArgs(args));
}

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
    import my.actor.msg : capture, infTimeout, sendExit;
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
