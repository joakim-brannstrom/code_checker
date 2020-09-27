/**
Copyright: Copyright (c) 2020, Joakim Brännström. All rights reserved.
License: $(LINK2 http://www.boost.org/LICENSE_1_0.txt, Boost Software License 1.0)
Author: Joakim Brännström (joakim.brannstrom@gmx.com)

A simple, featureless actor framework. It allows you to write an async
application using the actor pattern. It is suitable for applications that need
async:ness but not the highest achievable performance.

It is modelled after [C++ Actor Framework]() which I have used and am very
happy with how my applications turned out. Credit to Dominik Charousset, author
of CAF.

Most of the code is copied from Phobos std.concurrency.

A thread executes one actor at a time. The actor ID of the current actor is
accessible via `thisAid()`.
*/
module my.actor;

import core.atomic : cas, atomicStore, MemoryOrder, atomicLoad, atomicOp;
import core.sync.condition : Condition;
import core.sync.mutex : Mutex;
import core.thread : Thread;
import core.time : dur, Duration;
import logger = std.experimental.logger;
import std.array : appender, empty, array;
import std.datetime : SysTime, Clock;
import std.exception : collectException;
import std.format : formattedWrite;
import std.range : isOutputRange;
import std.stdio;
import std.traits;
import std.typecons : Tuple;
import std.variant : Variant;

import my.actor.mbox : MessageBox, Message, DelayedMessageBox, DelayedMessage;
import my.actor.typed;
import my.gc.refc;

class ActorException : Exception {
    this(string msg) @safe pure nothrow @nogc {
        super(msg);
    }
}

alias RcActorInfo = RefCounted!ActorInfo;

struct ActorSystem {
    /// Statistics about the actor system that is only updated in debug build.
    static struct Stat {
        // Method calls.
        long putCnt;
        long removeCnt;
        long spawnCnt;
    }

    private {
        Mutex lock_;
        ulong nextId_;
        shared Stat stat_;

        RcActorInfo[ulong] actors_;
        RcActorInfo[] toBeRemoved_;
    }

    this(this) @disable;

    /// Spawn a scoped actor that can be used by the local thread/context to send/receive messages.
    Aid scopedActor() @trusted {
        synchronized (lock_) {
            return Aid(++nextId_);
        }
    }

    /** Spawn a new actor with the behavior `Behavior`.
     *
     * Params:
     *  TActor = the messages that the spawned actor must implement behaviors for.
     *  Behavior = behavior for each message.
     *
     * Returns:
     *  An `Aid` representing the new actor.
     */
    Aid spawn(TActor, Behavior...)() if (isTypedActor!TActor) {
        debug atomicOp!"+="(stat_.spawnCnt, 1);

        auto aid = () {
            synchronized (lock_) {
                return Aid(++nextId_);
            }
        }();

        _spawnDetached(this, aid, false, makeTypedActor!(TActor, Behavior)(aid));
        return aid;
    }

    /** Spawn a new stateful actor with the behavior `Behavior` and state `State`.
     *
     * Params:
     *  TActor = the messages that the spawned actor must implement behaviors for.
     *  Behavior = behavior for each message.
     *
     * Returns:
     *  An `Aid` representing the new actor.
     */
    Aid spawn(TActor, StateT, Behavior...)(StateT state = StateT.init)
            if (isTypedActor!TActor) {
        debug atomicOp!"+="(stat_.spawnCnt, 1);

        auto aid = () {
            synchronized (lock_) {
                return Aid(++nextId_);
            }
        }();

        _spawnDetached(this, aid, false, makeStatefulTypedActor!(TActor,
                StateT, Behavior)(aid, state));
        return aid;
    }

    size_t length() @safe pure const @nogc {
        synchronized (lock_) {
            return actors_.length;
        }
    }

    /** Statistics about the actor system.
     *
     * Only updated in debug build.
     */
    Stat systemStat() @safe pure nothrow const @nogc {
        return stat_;
    }

    private RcActorInfo actor(Aid aid) @safe {
        synchronized (lock_) {
            if (auto v = aid.id in actors_) {
                return *v;
            }
        }
        throw new ActorException(null);
    }

    // TODO: change to safe
    private void put(RcActorInfo actor) @safe {
        debug atomicOp!"+="(stat_.putCnt, 1);

        const id = actor.ident.id;
        synchronized (lock_) {
            actors_[id] = actor;
        }
    }

    private void remove(RcActorInfo actor) @safe {
        debug atomicOp!"+="(stat_.removeCnt, 1);

        const id = actor.ident.id;
        synchronized (lock_) {
            if (auto v = id in actors_) {
                toBeRemoved_ ~= *v;
                (*v).release;
                actors_.remove(id);
            }
        }
    }

    /** Periodic cleanup of stopped actors.
     *
     */
    private void cleanup() @trusted {
        synchronized (lock_) {
            foreach (ref a; toBeRemoved_) {
                a.cleanup;
                a.release;
            }
            toBeRemoved_ = null;
        }
    }
}

RefCounted!ActorSystem makeActorSystem() {
    return ActorSystem(new Mutex).refCounted;
}

@("shall spawn a typed actor, process messages and cleanup")
unittest {
    alias MyActor = TypedActor!(Tuple!(immutable(int)*));

    int cnt;
    static void incr(immutable(int)* cnt) {
        (*(cast(int*) cnt)) = 1;
        thisAid.stop;
    }

    auto sys = makeActorSystem;
    {
        auto a = sys.spawn!(MyActor, incr);
        auto self = sys.scopedActor;
        send(self, a, cast(immutable(int*))&cnt);
        delayedSend(self, a, 50.dur!"msecs", cast(immutable(int*))&cnt);
        delayedSend(self, a, Clock.currTime + 50.dur!"msecs", cast(immutable(int*))&cnt);

        Thread.sleep(200.dur!"msecs");

        assert(sys.systemStat.spawnCnt == 1);
        assert(sys.systemStat.putCnt == 1);
        assert(sys.systemStat.removeCnt == 1);
        assert(cnt == 1);
    }

    assert(sys.length == 0);
    assert(sys.toBeRemoved_.length == 1);
    auto x = sys.toBeRemoved_[0];
    assert(x.refCount > 0);
    sys.cleanup;
    assert(sys.toBeRemoved_.length == 0);
    assert(x.refCount == 1);
}

@("shall spawn a stateful typed actor and cleanup")
unittest {
    alias MyActor = TypedActor!(Tuple!(int));

    struct State {
        int cnt;
    }

    static void incr(ref RefCounted!State state, int value) {
        state.cnt += value;
        thisAid.stop;
    }

    auto sys = makeActorSystem;
    {
        auto st = State(8).refCounted;
        auto a = sys.spawn!(MyActor, typeof(st), incr)(st);
        auto self = sys.scopedActor;
        send(self, a, 2);
        delayedSend(self, a, 50.dur!"msecs", 2);
        delayedSend(self, a, Clock.currTime + 50.dur!"msecs", 2);

        Thread.sleep(200.dur!"msecs");

        assert(sys.systemStat.spawnCnt == 1);
        assert(sys.systemStat.putCnt == 1);
        assert(sys.systemStat.removeCnt == 1);
        assert(st.cnt == 10);
    }

    assert(sys.length == 0);
    assert(sys.toBeRemoved_.length == 1);
    auto x = sys.toBeRemoved_[0];
    assert(x.refCount > 0);
    sys.cleanup;
    assert(sys.toBeRemoved_.length == 0);
    assert(x.refCount == 1);
}

@("shall process messages in a stateful typed actor as fast as possible")
unittest {
    import std.datetime : Clock, SysTime;

    alias MyActor = TypedActor!(Tuple!(int));

    enum maxCnt = 1000;

    struct State {
        int cnt;
        SysTime stopAt;
    }

    static void incr(ref RefCounted!State state, int value) {
        state.cnt += value;
        if (state.cnt == maxCnt) {
            state.stopAt = Clock.currTime;
            thisAid.stop;
        }
    }

    auto sys = makeActorSystem;
    {
        const startAt = Clock.currTime;
        auto st = State(0).refCounted;
        auto a = sys.spawn!(MyActor, typeof(st), incr)(st);

        auto self = sys.scopedActor;
        foreach (_; 0 .. maxCnt) {
            send(self, a, 1);
        }

        while (a.isAlive) {
            Thread.sleep(1.dur!"msecs");
        }

        assert(st.cnt == maxCnt);
        const diff = (st.stopAt - startAt);
        debug writefln!"%s:%s %s msg in %s (%s msg/s)"(__FUNCTION__, __LINE__, st.cnt,
                diff, cast(double) st.cnt / (cast(double) diff.total!"nsecs" / 1000000000.0));
    }

    sys.cleanup;
}

/// Actor ID
struct Aid {
    private static struct Value {
        shared ulong id;
        Mutex lock;
        MessageBox normal;
        MessageBox priority;
        DelayedMessageBox delayed;
        MessageBox system;
        shared ActorState state;

        this(this) @disable;

        ~this() @trusted {
            import std.algorithm : filter;
            import std.range : only;

            if (lock is null)
                return;

            synchronized (lock) {
                if (normal !is null && !normal.isClosed)
                    normal.close;
                if (priority !is null && !priority.isClosed)
                    priority.close;
                if (delayed !is null && !delayed.isClosed)
                    delayed.close;
                if (system !is null && !system.isClosed)
                    system.close;
            }
        }
    }

    private RefCounted!Value value_;

    this(ulong id) {
        this.value_ = Value(id, new Mutex, new MessageBox, new MessageBox,
                new DelayedMessageBox, new MessageBox);
    }

    /// Copy constructor
    this(ref return scope typeof(this) rhs) @safe pure nothrow @nogc {
        this.value_ = rhs.value_;
    }

    string toString() @safe pure const {
        auto buf = appender!string;
        toString(buf);
        return buf.data;
    }

    void toString(Writer)(ref Writer w) const if (isOutputRange!(Writer, char)) {
        if (value_.refCount == 0) {
            formattedWrite(w, "%s(<uninitialized>)", typeof(this).stringof);
        } else {
            formattedWrite(w, "%s(refCount:%s, id:%s, state:%s)", typeof(this)
                    .stringof, value_.refCount, id, state);
        }
    }

    bool isAlive() @safe pure const @nogc {
        import std.algorithm : among;

        if (value_.refCount == 0)
            return false;

        synchronized (value_.lock) {
            return value_.state.among(ActorState.waiting, ActorState.running) != 0;
        }
    }

    /// Mark an actor as running if it where previously waiting.
    void running() @safe pure @nogc {
        synchronized (value_.lock) {
            if (value_.state == ActorState.waiting) {
                value_.state = ActorState.running;
            }
        }
    }

    /** Stop an actor.
     *
     * The actor will be marked as stopping which will mean that it will at
     * most process one more message and then be terminated.
     */
    void stop() @safe pure @nogc {
        synchronized (value_.lock) {
            final switch (value_.state) with (ActorState) {
            case waiting:
                goto case;
            case running:
                value_.state = ActorState.stopping;
                break;
            case stopping:
                goto case;
            case terminated:
                break;
            }
        }
    }

    /** Move the actor to the terminated state only if it where in the stopped state previously.
     */
    package(my.actor) void terminated() @safe pure @nogc {
        synchronized (value_.lock) {
            if (value_.state == ActorState.stopping) {
                value_.state = ActorState.terminated;
            }
        }
    }

    /// Release the references counted values of the actor id.
    package(my.actor) void release() @trusted {
        if (value_.refCount == 0)
            return;

        auto lock = value_.lock;
        synchronized (lock) {
            value_.release;
        }
    }

    private ulong id() @safe pure nothrow @nogc const {
        return atomicLoad(value_.get.id);
    }

    package(my.actor) MessageBox normalMbox() @safe pure @nogc {
        return value_.normal;
    }

    package(my.actor) MessageBox priorityMbox() @safe pure @nogc {
        return value_.priority;
    }

    package(my.actor) DelayedMessageBox delayedMbox() @safe pure @nogc {
        return value_.delayed;
    }

    package(my.actor) MessageBox systemMbox() @safe pure @nogc {
        return value_.system;
    }

    private ActorState state() @safe pure nothrow @nogc const {
        return atomicLoad(value_.state);
    }

    private void setState(ActorState st) @safe pure nothrow @nogc {
        atomicStore(value_.state, st);
    }
}

enum ActorState : ubyte {
    /// the actor has spawned and is waiting to start executing.
    waiting,
    /// the actor is running/active
    running,
    /// the actor is signaled to stop. It will process at most one more message.
    stopping,
    /// the actor has terminated and thus all its resources can be freed.
    terminated,
}

/// Configure how an actor, when spawned, will be executed.
enum SpawnMode : ubyte {
    /// the spawned actor is executed in the worker pool
    pool,
    /// executing in its own thread
    detached
}

/** Send a message `msg` to actor `aid`.
 */
void send(T...)(Aid from, Aid to, T params) {
    static assert(!hasLocalAliasing!(T), "Aliases to mutable thread-local data not allowed.");
    auto msg = Message(params);
    if (!to.normalMbox.put(msg)) {
        // TODO: add error handling when it fail.
    }
}

/** Send a delayed message `msg` to actor `aid`.
 *
 * Params:
 *  delay = how much to delay the message with.
 */
void delayedSend(T...)(Aid from, Aid to, Duration delay, T params) {
    import std.datetime : Clock;

    static assert(!hasLocalAliasing!(T), "Aliases to mutable thread-local data not allowed.");
    auto msg = DelayedMessage(Clock.currTime + delay, Message(params));
    if (!to.delayedMbox.put(msg)) {
        // TODO: add error handling when it fail.
    }
}

/** Delay the message being processed until `delay`.
 *
 * Params:
 *  delay = how much to delay the message with.
 */
void delayedSend(T...)(Aid from, Aid to, SysTime delay, T params) {
    import std.datetime : Clock;

    static assert(!hasLocalAliasing!(T), "Aliases to mutable thread-local data not allowed.");
    auto msg = DelayedMessage(delay, Message(params));
    if (!to.delayedMbox.put(msg)) {
        // TODO: add error handling when it fail.
    }
}

/// Currently active actor..
Aid thisAid() @safe {
    auto info = thisInfo;
    if (info.refCount != 0) {
        return info.ident;
    }
    return Aid.init;
}

ref ActorSystem thisActorSystem() @safe {
    auto info = thisInfo;
    if (info.refCount != 0) {
        return *info.system;
    }
    throw new ActorException(null);
}

/** Encapsulates all implementation-level data needed for scheduling.
 *
 * When defining a Scheduler, an instance of this struct must be associated
 * with each logical thread.  It contains all implementation-level information
 * needed by the internal API.
 */
struct ActorInfo {
    /// The system the actor belongs to.
    ActorSystem* system;
    Aid ident;
    Aid owner;
    bool[Aid] links;

    /** Cleans up this ThreadInfo.
     *
     * This must be called when a scheduled thread terminates.  It tears down
     * the messaging system for the thread and notifies interested parties of
     * the thread's termination.
     */
    void cleanup() {
        Aid discard;
        foreach (aid; links.byKey) {
            if (aid.isAlive) {
                send(discard, aid, SystemMsgType.linkDead, ident);
            }
        }
        if (owner.isAlive) {
            send(discard, owner, SystemMsgType.linkDead, ident);
        }

        ident.release;
        owner.release;
    }
}

enum SystemMsgType {
    linkDead,
}

private:

static ~this() {
    thisInfo.release;
}

ref RefCounted!ActorInfo thisInfo() @safe nothrow @nogc {
    static RefCounted!ActorInfo self;
    return self;
}

/*
 *
 */
void _spawnDetached(ref ActorSystem system, ref Aid newAid, bool linked, ActorRuntime actor) {
    import std.stdio;

    auto ownerAid = thisAid;

    void exec() {
        auto info = ActorInfo().refCounted;

        info.ident = newAid;
        info.ident.setState(ActorState.running);
        info.owner = ownerAid;
        system.put(info);
        thisInfo() = info;

        scope (exit)
            () { info.ident.stop; system.remove(info); }();

        while (info.ident.state != ActorState.stopping) {
            try {
                actor.act(100.dur!"msecs");
            } catch (Exception e) {
                debug logger.warning(e.msg);
            }
        }
    }

    auto t = new Thread(&exec);
    t.start();

    auto info = thisInfo;
    if (info.refCount != 0) {
        thisInfo.links[newAid] = linked;
    }
}

bool hasLocalAliasing(Types...)() {
    import std.typecons : Rebindable;

    // Works around "statement is not reachable"
    bool doesIt = false;
    static foreach (T; Types) {
        static if (is(T == Aid)) { /* Allowed */ } else static if (is(T : Rebindable!R, R))
            doesIt |= hasLocalAliasing!R;
        else static if (is(T == struct))
            doesIt |= hasLocalAliasing!(typeof(T.tupleof));
        else
            doesIt |= std.traits.hasUnsharedAliasing!(T);
    }
    return doesIt;
}

template isSpawnable(F, T...) {
    template isParamsImplicitlyConvertible(F1, F2, int i = 0) {
        alias param1 = Parameters!F1;
        alias param2 = Parameters!F2;
        static if (param1.length != param2.length)
            enum isParamsImplicitlyConvertible = false;
        else static if (param1.length == i)
            enum isParamsImplicitlyConvertible = true;
        else static if (isImplicitlyConvertible!(param2[i], param1[i]))
            enum isParamsImplicitlyConvertible = isParamsImplicitlyConvertible!(F1, F2, i + 1);
        else
            enum isParamsImplicitlyConvertible = false;
    }

    enum isSpawnable = isCallable!F && is(ReturnType!F == void) && isParamsImplicitlyConvertible!(F,
                void function(T)) && (isFunctionPointer!F || !hasUnsharedAliasing!F);
}
