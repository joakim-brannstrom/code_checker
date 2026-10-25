/**
Copyright: Copyright (c) Joakim Brännström. All rights reserved.
License: $(LINK2 http://www.boost.org/LICENSE_1_0.txt, Boost Software License 1.0)
Author: Joakim Brännström (joakim.brannstrom@gmx.com)
*/
module my.actor.behavior;

import std.datetime : Duration;
import std.meta : staticMap;
import std.traits : Unqual;

import my.actor.actor : ActorShell;
import my.actor.common : methodSignature;
import my.actor.mailbox : WeakAddress, makePayload;

/// Hook names: optional class methods the shell calls when present.
/// They are never message methods — nothing can be sent to them.
template isHookName(string name) {
    enum isHookName = name == "onSpawn" || name == "onException" || name == "onError"
        || name == "onExit" || name == "onDownMessage" || name == "onUnhandledMessage";
}

/** The actor's self-handle, passed to `onSpawn`. It is the only path to the
 * actor's own powers: `address()` — save it and pass it on so others can
 * send messages back. `scheduleRepeating` / `cancelTick` — a repeating
 * self-tick on the actor's own thread. Shutdown is deliberately NOT here:
 * that is the system shutdown message (`sendExit` / SystemExitMsg). */
struct ActorRef {
    import my.actor.system : System;

    private ActorShell* kernel_;

    this(ActorShell* kernel) @safe nothrow {
        kernel_ = kernel;
    }

    /// The system this actor belongs to (null for ActorRef.init)
    System* homeSystem() @safe nothrow {
        return kernel_ !is null ? &kernel.homeSystem() : null;
    }

    /// Weak address of this actor.
    WeakAddress address() @safe {
        return kernel_ !is null ? kernel_.address : WeakAddress.init;
    }

    /** Arm a repeating self-tick: `method(args...)` is invoked on this
     * actor's thread every `interval`. At most one pending tick at a time
     * (it re-arms itself on fire). The first fire is at +`interval`, never
     * immediately. A throwing tick handler stops the repeat and fires the
     * `onException` hook. See `ActorShell.scheduleRepeating`. */
    void scheduleRepeating(Args...)(Duration interval, string method, Args args) @trusted {
        alias UArgs = staticMap!(Unqual, Args);
        if (kernel_ !is null)
            kernel_.scheduleRepeating(interval, methodSignature!UArgs(method), makePayload(args));
    }

    /** Cancel a pending repeating tick (safe from inside the tick handler;
     * a no-op if none is pending). Cancelled entries are dropped without
     * dispatch when they come due. See `ActorShell.cancelTick`. */
    void cancelTick() {
        if (kernel_ !is null)
            kernel_.cancelTick;
    }

    /// Package-internal: the shell this handle points at (registration/channel).
    package ActorShell* kernel() @safe nothrow {
        return kernel_;
    }
}

unittest {
    static assert(isHookName!"onSpawn");
    static assert(isHookName!"onException");
    static assert(isHookName!"onError");
    static assert(isHookName!"onExit");
    static assert(isHookName!"onDownMessage");
    static assert(isHookName!"onUnhandledMessage");
    static assert(!isHookName!"ding");
    static assert(!isHookName!"onSpawn2");

    ActorRef selfRef = ActorRef(null);
    assert(selfRef.kernel is null);
    assert(selfRef.address.lock.get is null);
}
