/**
Copyright: Copyright (c) 2020, Joakim Brännström. All rights reserved.
License: $(LINK2 http://www.boost.org/LICENSE_1_0.txt, Boost Software License 1.0)
Author: Joakim Brännström (joakim.brannstrom@gmx.com)

The design is derived from C++ Actor Framework (CAF).

Actors are always allocated with a control block that stores its identity

When allocating a new actor, CAF will always embed the user-defined actor in an
`actor_storage` with the control block prefixing the actual actor type, as
shown below.

    +----------------------------------------+
    |                  storage!T             |
    +----------------------------------------+
    | +-----------------+------------------+ |
    | |  control block  |        data!T    | |
    | +-----------------+------------------+ |
    | | actor ID        | mailbox          | |
    | | node ID         | .                | |
    | +-----------------+------------------+ |
    +----------------------------------------+
*/
module my.actor.actor;

import core.atomic : atomicOp, atomicLoad, atomicStore, cas;
import core.memory : GC;
import std.algorithm : move, swap;

import my.actor : ActorSystem;

/// Unique identifier for an actor.
struct ActorId {
    ulong value;
}

struct NodeId {
    ulong value;
}

class ControlBlock {
    private {
        ActorId aid_;
        NodeId nid_;
        ActorSystem* homeSystem_;
        AbstractActor instance_;
    }

    this(ActorId aid, NodeId nid, ActorSystem* sys) {
        this.aid_ = aid;
        this.nid_ = nid;
        this.homeSystem_ = sys;
    }

    ActorId aid() @safe pure nothrow const @nogc {
        return aid_;
    }

    NodeId nid() @safe pure nothrow const @nogc {
        return nid_;
    }

    ref ActorSystem homeSystem() @safe pure nothrow @nogc {
        return *homeSystem_;
    }

    /// Returns: the actual actor instance.
    AbstractActor get() {
        return instance_;
    }
}

/**
The design is derived from C++ Actor Framework (CAF).

Actors are always allocated with a control block that stores its identity

When allocating a new actor, CAF will always embed the user-defined actor in an
`actor_storage` with the control block prefixing the actual actor type, as
shown below.

    +----------------------------------------+
    |                  storage!T             |
    +----------------------------------------+
    | +-----------------+------------------+ |
    | |  control block  |        data!T    | |
    | +-----------------+------------------+ |
    | | actor ID        | mailbox          | |
    | | node ID         | .                | |
    | +-----------------+------------------+ |
    +----------------------------------------+
*/
struct Storage(T) {
    ControlBlock ctrl;
    T item;

    this(ActorId aid, NodeId nid, ActorSystem* sys, ref T item_) {
        ctrl = new ctrl(aid, nid, sys);
        item = move(item_);
    }

    this(Args...)(ActorId aid, NodeId nid, ActorSystem* sys, auto ref Args args) {
        ctrl = new ctrl(aid, nid, sys);
        item = T(args);
    }
}
