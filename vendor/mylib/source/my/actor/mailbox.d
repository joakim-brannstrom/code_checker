/**
Copyright: Copyright (c) 2021, Joakim Brännström. All rights reserved.
License: $(LINK2 http://www.boost.org/LICENSE_1_0.txt, Boost Software License 1.0)
Author: Joakim Brännström (joakim.brannstrom@gmx.com)
*/
module my.actor.mailbox;

import core.sync.condition : Condition;
import core.sync.mutex : Mutex;
import std.datetime : SysTime;
import std.sumtype;
import std.variant : Variant;

import my.actor.common;
public import my.actor.system_msg;

struct MsgOneShot {
    Variant data;
}

struct MsgRequest {
    WeakAddress replyTo;
    ulong replyId;
    Variant data;
}

alias MsgType = SumType!(MsgOneShot, MsgRequest);

struct Msg {
    ulong signature;
    MsgType type;

    this(ref return typeof(this) a) @trusted {
        signature = a.signature;
        type = a.type;
    }

    @disable this(this);
}

alias SystemMsg = SumType!(ErrorMsg, DownMsg, ExitMsg, SystemExitMsg,
        MonitorRequest, DemonitorRequest, LinkRequest, UnlinkRequest);

struct Reply {
    ulong id;
    Variant data;

    this(ref return typeof(this) a) {
        id = a.id;
        data = a.data;
    }

    @disable this(this);
}

struct DelayedMsg {
    Msg msg;
    SysTime triggerAt;

    /// Repeating self-tick entry (see `ActorShell.scheduleRepeating`): the
    /// shell dispatches it directly on fire and re-arms it at +interval.
    bool repeating;

    /// Schedule generation of a repeating entry; stale entries (the shell's
    /// generation was bumped by a re-schedule or `cancelTick`) are dropped
    /// without dispatch when they come due.
    ulong seq;

    this(ref return DelayedMsg a) @trusted {
        msg = a.msg;
        triggerAt = a.triggerAt;
        repeating = a.repeating;
        seq = a.seq;
    }

    this(const ref return DelayedMsg a) inout @safe {
        assert(0, "not supported");
    }

    @disable this(this);
}

/** Per-thread mark for "this thread is executing `ActorShell.process`",
 * i.e. it is an actor worker. Lets a full bounded mailbox drop the
 * message of a worker instead of blocking it — blocking a pool worker
 * while the only thread that could free a mailbox slot may itself be
 * stuck is the deadlock the bound exists to prevent.
 *
 * Reference counted: `process()` is re-entrant on one thread (the
 * scoped actor request loop), and a mark must survive inner exits. */
private ulong actorWorkerDepth_;

/// True while the calling thread is inside `ActorShell.process` (i.e. it is
/// an actor worker). Reference counted: true while at least one `process()`
/// frame is on this thread's stack.
package bool isActorWorker() @safe nothrow @nogc {
    return actorWorkerDepth_ > 0;
}

/// Push or pop the actor-worker mark for the calling thread. `process()`
/// is re-entrant on one thread (the scoped actor request loop), so the
/// mark is a per-thread depth: set at each `process()` entry, cleared only
/// when the outermost frame exits.
package void setActorWorker(bool active) @safe nothrow @nogc {
    if (active)
        actorWorkerDepth_++;
    else if (actorWorkerDepth_ > 0)
        actorWorkerDepth_--;
}

struct Address {
    private {
        // If the actor that use the address is active and processing messages.
        bool open_;
        ulong id_;
        Mutex mtx;

        // Bounded incoming mailbox (see README, "Bounded mailbox"): 0 =
        // unbounded (default). Installed by `spawnBounded` before the actor
        // is scheduled, so no message can outrun the bound.
        size_t mailboxBound_;

        // Messages dropped by the full-mailbox policy (worker senders only).
        ulong dropped_;

        // Wakes a non-actor sender blocked on a full bounded queue when a
        // slot frees or the address shuts down. Lazily created by
        // `setMailboxBound` — unbounded addresses pay nothing for it.
        // Managed reference, not a raw pointer: the address roots it for
        // its whole lifetime. A raw pointer to a heap-allocated Condition
        // dangles once the GC scavenges it — notify/wait on the freed
        // object segfaulted the bounded-mailbox tests (task 12).
        Condition mailboxCond_;
    }

    package {
        Queue!Msg incoming;

        Queue!SystemMsg sysMsg;

        // Delayed messages for this actor that will be triggered in the future.
        Queue!DelayedMsg delayed;

        // Incoming replies on requests.
        Queue!Reply replies;
    }

    invariant {
        assert(mtx !is null,
                "mutex must always be set or the address will fail on sporadic method calls");
    }

    private this(Mutex mtx) @safe
    in (mtx !is null) {
        this.mtx = mtx;

        // lazy way of generating an ID. a mutex is a class thus allocated on
        // the heap at a unique location. just... use the pointer as the ID.
        () @trusted { id_ = cast(ulong) cast(void*) mtx; }();
        incoming = typeof(incoming)(mtx);
        sysMsg = typeof(sysMsg)(mtx);
        delayed = typeof(delayed)(mtx);
        replies = typeof(replies)(mtx);
    }

    @disable this(this);

    void shutdown() @safe nothrow {
        try {
            synchronized (mtx) {
                open_ = false;
                // Wake non-actor senders blocked on a full bounded queue:
                // the address is closed, their put must return.
                if (mailboxCond_ !is null)
                    () @trusted { mailboxCond_.notifyAll; }();
                incoming.teardown((ref Msg a) { a.type = MsgType.init; });
                sysMsg.teardown((ref SystemMsg a) { a = SystemMsg.init; });
                delayed.teardown((ref DelayedMsg a) { a.msg.type = MsgType.init; });
                replies.teardown((ref Reply a) { a.data = a.data.type.init; });
            }
        } catch (Exception e) {
            assert(0, "this should never happen");
        }
    }

    package bool put(T)(T msg) {
        synchronized (mtx) {
            if (!open_)
                return false;

            static if (is(T : Msg)) {
                if (mailboxBound_ == 0 || incoming.length < mailboxBound_)
                    return incoming.put(msg);

                // The bounded incoming mailbox is full. An actor worker must
                // never block here: it holds a pool slot, and the only thread
                // that could free a slot may itself be a worker — blocking
                // would exhaust the pool and deadlock. Drop it instead.
                if (isActorWorker()) {
                    dropped_++;
                    return false;
                }

                // A non-actor sender (supervisor thread, test main) may
                // block until a slot frees or the address shuts down.
                while (open_ && incoming.length >= mailboxBound_)
                    mailboxCond_.wait;
                if (!open_)
                    return false;
                return incoming.put(msg);
            } else static if (is(T : SystemMsg))
                return sysMsg.put(msg);
            else static if (is(T : DelayedMsg))
                return delayed.put(msg);
            else static if (is(T : Reply))
                return replies.put(msg);
            else
                static assert(0, "msg type not supported " ~ T.stringof);
        }
    }

    package auto pop(T)() @safe {
        synchronized (mtx) {
            static if (is(T : Msg)) {
                if (!open_)
                    return incoming.PopReturnType.init;
                // Bounded queue: the pop is the moment a slot frees — wake
                // non-actor senders inside the pop's critical section (no
                // lost wakeup). Unbounded keeps the plain pop. The Item is
                // returned directly: binding it to a local first would let
                // the local's destructor null the popped slot before the
                // caller's copy could read it.
                if (mailboxBound_ == 0)
                    return incoming.pop;
                return incoming.popNotifying(mailboxCond_);
            } else static if (is(T : SystemMsg)) {
                if (!open_)
                    return sysMsg.PopReturnType.init;
                return sysMsg.pop;
            } else static if (is(T : DelayedMsg)) {
                if (!open_)
                    return delayed.PopReturnType.init;
                return delayed.pop;
            } else static if (is(T : Reply)) {
                if (!open_)
                    return replies.PopReturnType.init;
                return replies.pop;
            } else {
                static assert(0, "msg type not supported " ~ T.stringof);
            }
        }
    }

    package bool empty(T)() @safe {
        synchronized (mtx) {
            if (!open_)
                return true;

            static if (is(T : Msg))
                return incoming.empty;
            else static if (is(T : SystemMsg))
                return sysMsg.empty;
            else static if (is(T : DelayedMsg))
                return delayed.empty;
            else static if (is(T : Reply))
                return replies.empty;
            else
                static assert(0, "msg type not supported " ~ T.stringof);
        }
    }

    package bool hasMessage() @safe pure nothrow const @nogc
    in (mtx !is null) {
        try {
            synchronized (mtx) {
                return !(incoming.empty && sysMsg.empty && delayed.empty && replies.empty);
            }
        } catch (Exception e) {
        }
        return false;
    }

    package size_t length() @safe pure nothrow const {
        try {
            synchronized (mtx) {
                return incoming.length + sysMsg.length + delayed.length + replies.length;
            }
        } catch (Exception e) {
        }
        return 0;
    }

    package void setOpen() @safe pure nothrow @nogc {
        open_ = true;
    }

    package void setClosed() @safe pure nothrow @nogc {
        open_ = false;
    }

    /** Install the bounded-incoming-mailbox bound (see README,
     * "Bounded mailbox"). Called by `System.spawnBounded` before the actor
     * is scheduled — no other thread can observe the address yet, so no
     * synchronization is needed. `bound <= 0` leaves the mailbox unbounded. */
    package void setMailboxBound(size_t bound) @safe {
        if (bound > 0 && mailboxBound_ == 0) {
            mailboxBound_ = bound;
            mailboxCond_ = new Condition(mtx);
        }
    }

    /// Bound installed by `spawnBounded` (0 = unbounded).
    @property public size_t mailboxBound() @safe {
        return mailboxBound_;
    }

    /// Number of messages dropped on the full bounded-incoming-mailbox path
    /// (always 0 for unbounded addresses).
    @property public ulong dropped() @safe {
        try {
            synchronized (mtx)
                return dropped_;
        } catch (Exception e) {
        }
        return dropped_;
    }
}

struct WeakAddress {
    private Address* addr;

    StrongAddress lock() scope @trusted nothrow @nogc {
        return StrongAddress(addr);
    }

    T opCast(T : bool)() @safe nothrow const @nogc {
        return cast(bool) addr;
    }

    bool empty() @safe nothrow const @nogc {
        return addr is null;
    }

    void opAssign(WeakAddress rhs) @safe nothrow @nogc {
        this.addr = rhs.addr;
    }

    size_t toHash() @safe pure nothrow const @nogc scope {
        return cast(size_t) addr;
    }

    void release() @safe nothrow @nogc {
        addr = null;
    }
}

/** Messages can be sent to a strong address.
 */
struct StrongAddress {
    package Address* addr;

    private this(Address* addr) @safe nothrow @nogc {
        this.addr = addr;
    }

    void release() @safe nothrow @nogc scope {
        addr = null;
    }

    ulong id() @safe pure nothrow const @nogc scope {
        return cast(ulong) addr;
    }

    size_t toHash() @safe pure nothrow const @nogc scope {
        return cast(size_t) addr;
    }

    void opAssign(StrongAddress rhs) @safe nothrow @nogc {
        this.addr = rhs.addr;
    }

    T opCast(T : bool)() @safe nothrow const @nogc {
        return cast(bool) addr;
    }

    bool empty() @safe pure nothrow const @nogc scope {
        return addr is null;
    }

    WeakAddress weakRef() @safe nothrow return scope {
        return WeakAddress(addr);
    }

    package Address* get() return scope @safe pure nothrow @nogc {
        return addr;
    }
}

/// An address that carries the actor's type: the result of `spawn!T`.
/// Holding it lets `Channel!I` verify at compile time that the actor class
/// implements `I`; erase explicitly (`.weakRef`) when the type must travel
/// untyped (message payloads, dynamic sends).
struct TypedAddress(T) {
    private StrongAddress addr_;

    /// Wrap an address of a known actor type (normally done by `spawn!T`).
    this(StrongAddress addr) @safe nothrow @nogc {
        this.addr_ = addr;
    }

    /// Strong form of the address.
    @property StrongAddress addr() @safe nothrow @nogc {
        return addr_;
    }

    /// Weak form — use it when the address travels, or for dynamic sends.
    @property WeakAddress weakRef() @safe nothrow {
        return addr_.weakRef;
    }

    /// True when the address is unset.
    @property bool empty() @safe pure nothrow const @nogc scope {
        return addr_.empty;
    }

    bool opCast(B : bool)() @safe nothrow const @nogc {
        return cast(bool) addr_;
    }
}

/// `true` when `T` is a `TypedAddress!U`.
template isTypedAddress(T) {
    enum isTypedAddress = is(T : TypedAddress!U, U);
}

StrongAddress makeAddress() @safe {
    return StrongAddress(new Address(new Mutex));
}
