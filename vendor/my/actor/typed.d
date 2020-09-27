/**
Copyright: Copyright (c) 2020, Joakim Brännström. All rights reserved.
License: $(LINK2 http://www.boost.org/LICENSE_1_0.txt, Boost Software License 1.0)
Author: Joakim Brännström (joakim.brannstrom@gmx.com)
*/
module my.actor.typed;

import core.time : Duration, dur;
import logger = std.experimental.logger;
import std.datetime : Clock;
import std.meta : AliasSeq;
import std.stdio : writefln;
import std.traits : Parameters;

public import std.typecons : Tuple;

import my.actor : Aid;
import my.actor.mbox : Message;
import my.gc.refc;

@("shall construct a typed actor and process two messages")
unittest {
    alias MyActor = TypedActor!(Tuple!(int), Tuple!(int, double));

    static void msg0(int x, double y) @safe {
        writefln!"%s:%s yeey %s %s"(__FUNCTION__, __LINE__, x, y);
    }

    static void msg1(int x) @safe {
        writefln!"%s:%s yeey %s"(__FUNCTION__, __LINE__, x);
    }

    auto aid = Aid(42);
    auto actor = makeTypedActor!(MyActor, msg0, msg1)(aid);
    actor.actorId.normalMbox.put(Message(42, 84.0));
    actor.actorId.normalMbox.put(Message(42));

    actor.act(1.dur!"seconds");
    actor.act(1.dur!"seconds");
}

@("shall construct a stateful typed actor and process two messages")
unittest {
    alias MyActor = TypedActor!(Tuple!(int), Tuple!(int, double));

    struct State {
        int cnt;
    }

    static void msg0(ref State st, int x, double y) @safe {
        st.cnt += 1;
        writefln!"%s:%s yeey %s %s"(__FUNCTION__, __LINE__, x, y);
    }

    static void msg1(ref State st, int x) @safe {
        st.cnt += 2;
        writefln!"%s:%s yeey %s"(__FUNCTION__, __LINE__, x);
    }

    auto aid = Aid(42);
    auto actor = makeStatefulTypedActor!(MyActor, State, msg0, msg1)(aid, State.init);
    actor.actorId.normalMbox.put(Message(42, 84.0));
    actor.actorId.normalMbox.put(Message(42));

    actor.act(1.dur!"seconds");
    actor.act(1.dur!"seconds");

    assert(actor.state.cnt == 3);
}

struct TypedActor(AllowedMsg...) {
    alias AllowedMessages = AliasSeq!AllowedMsg;
}

enum isTypedActor(T) = is(T : TypedActor!U, U);

auto extend(TActor, AllowedMsg...)() if (isTypedActor!TActor) {
    return TypedActor!(U, AllowedMsg);
}

/// Interface that all actors that execute in an ActorSystem must implement.
interface ActorRuntime {
    /** Act on one message in the mailbox.
     *
     * Params:
     *  timeout = max time to wait for a message to arrive and execute the
     *            behavior for it.
     */
    void act(Duration timeout);

    /// The actor ID of the runtime.
    ref Aid actorId();

    /// Release any held resources.
    void release();
}

class TypedActorRuntime : ActorRuntime {
    alias Behavior = bool function(ref Message msg);

    /// The behavior of the actor for messages.
    Behavior behavior;
    Aid aid;

    this(Behavior bh, Aid aid) {
        this.behavior = bh;
        this.aid = aid;
    }

    override void release() {
        aid.release;
    }

    override ref Aid actorId() {
        return aid;
    }

    /// Act on one message in the mailbox.
    override void act(Duration timeout) {
        Message m;
        do {
            if (aid.systemMbox.get(Duration.zero, m))
                break;
            if (aid.priorityMbox.get(Duration.zero, m))
                break;
            if (aid.delayedMbox.get(Duration.zero, Clock.currTime, m))
                break;
            if (!aid.normalMbox.get(timeout, m))
                return;
        }
        while (false);

        if (!behavior(m)) {
            logger.tracef("%s:%s no behavior for '%s'", __FUNCTION__, __LINE__, m);
        }
    }
}

class StatefulActorRuntime(StateT) : ActorRuntime {
    alias Behavior = bool function(ref StateT state, ref Message msg);

    /// The behavior of the actor for messages.
    Behavior behavior;
    Aid aid;
    StateT state;

    this(Behavior bh, Aid aid, StateT state) {
        this.behavior = bh;
        this.aid = aid;
        this.state = state;
    }

    override void release() {
        aid.release;
    }

    override ref Aid actorId() {
        return aid;
    }

    /// Act on one message in the mailbox.
    override void act(Duration timeout) {
        Message m;
        do {
            if (aid.systemMbox.get(Duration.zero, m))
                break;
            if (aid.priorityMbox.get(Duration.zero, m))
                break;
            if (aid.delayedMbox.get(Duration.zero, Clock.currTime, m))
                break;
            if (!aid.normalMbox.get(timeout, m))
                return;
        }
        while (false);

        if (!behavior(state, m)) {
            logger.tracef("%s:%s no behavior for '%s'", __FUNCTION__, __LINE__, m);
        }
    }
}

/// Check that `Behavior` implement the actor interface `TActor`.
auto makeTypedActor(TActor, Behavior...)(Aid aid)
        if (isTypedActor!TActor && typeCheck!(0, TActor, Behavior)) {
    return new TypedActorRuntime(&actorBehaviorImpl!Behavior, aid);
}

/// Check that `Behavior` implement the actor interface `TActor`.
auto makeStatefulTypedActor(TActor, StateT, Behavior...)(Aid aid, StateT state)
        if (isTypedActor!TActor && typeCheck!(1, TActor, Behavior)) {
    return new StatefulActorRuntime!StateT(&statefulActorBehaviorImpl!(StateT,
            Behavior), aid, state);
}

package(my.actor) bool typeCheck(size_t paramFromIndex, TActor, Behavior...)()
        if (isTypedActor!TActor) {
    alias AllowedTypes = TActor.AllowedMessages;

    foreach (T; AllowedTypes) {
        bool added = false;
        foreach (bh; Behavior) {
            alias Args = Parameters!bh[paramFromIndex .. $];
            alias BehaviorTuple = Tuple!Args;

            static if (is(BehaviorTuple == T)) {
                if (added) {
                    assert(false, "duplicate overload specified for type '" ~ T.stringof ~ "'");
                }
                added = true;
            }
        }

        if (!added) {
            assert(false, "unhandled message type '" ~ T.stringof ~ "'");
        }
    }
    return true;
}

/* Apply the first behavior `T` that matches the message.
 *
 * Matches ops against each message in turn until a match is found.
 *
 * Params:
 *  Behaviors = the behaviors (functions) to match the message against.
 *  ops = The operations to match.
 *
 * Returns:
 *  true if a message was retrieved and false if not.
 */
bool actorBehaviorImpl(Behaviors...)(ref Message msg) {
    import std.meta : AliasSeq;

    static assert(Behaviors.length, "Behaviors must not be empty");

    alias Ops = AliasSeq!(Behaviors);

    foreach (i, t; Ops) {
        alias Args = Parameters!(t);

        if (msg.convertsTo!(Args)) {
            msg.map!(Ops[i]);
            return true;
        }
    }
    return false;
}

bool statefulActorBehaviorImpl(StateT, Behaviors...)(ref StateT state, ref Message msg) {
    import std.meta : AliasSeq;

    static assert(Behaviors.length, "Behaviors must not be empty");

    alias Ops = AliasSeq!(Behaviors);

    foreach (i, t; Ops) {
        /// dropping the first parameter because it is the state.
        alias Args = Parameters!(t)[1 .. $];

        if (msg.convertsTo!(Args)) {
            msg.map!(Ops[i])(state);
            return true;
        }
    }
    return false;
}
