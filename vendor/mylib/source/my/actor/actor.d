/**
Copyright: Copyright (c) Joakim Brännström. All rights reserved.
License: $(LINK2 http://www.boost.org/LICENSE_1_0.txt, Boost Software License 1.0)
Author: Joakim Brännström (joakim.brannstrom@gmx.com)
*/
module my.actor.actor;

import std.stdio : writeln, writefln;

import core.sync.mutex : Mutex;
import core.thread : Thread;
import logger = std.logger;
import std.algorithm : schwartzSort, max, min, among;
import std.array : empty;
import std.datetime : SysTime, Clock, dur;
import std.exception : collectException;
import std.functional : toDelegate;
import std.meta : staticMap;
import std.sumtype;
import std.traits : Parameters, Unqual;
import std.typecons : Tuple, tuple;
import std.variant : Variant;

import my.actor.common : ExitReason, SystemError, methodSignature;
import my.actor.mailbox;
import my.actor.msg;
import my.actor.system : System;
import my.actor.behavior : ActorRef;
import my.actor.registration : implActor;
import my.gc.refc;

public import my.actor.system_msg;

private struct PromiseData {
    WeakAddress replyTo;
    ulong replyId;

    /// Copy constructor
    this(ref return scope typeof(this) rhs) @safe nothrow @nogc {
        replyTo = rhs.replyTo;
        replyId = rhs.replyId;
    }

    @disable this(this);
}

struct Promise(T) {
    private RefCounted!PromiseData data;

    private this(PromiseData data) {
        this.data = refCounted(data);
    }

    private this(RefCounted!PromiseData data) {
        this.data = data;
    }

    package void set(WeakAddress replyTo, ulong replyId)
    in (!data.empty, "promise must be initialized") {
        data.borrow!((ref a) { a.replyTo = replyTo; a.replyId = replyId; });
    }

    package WeakAddress replyTo() @safe
    in (!data.empty, "promise must be initialized") {
        return data.replyTo;
    }

    package ulong replyId() @safe
    in (!data.empty, "promise must be initialized") {
        return data.replyId;
    }

    void deliver(T reply) {
        auto tmp = reply;
        deliver(reply);
    }

    /** Deliver the message `reply`.
     *
     * A promise can only be delivered once.
     */
    void deliver(ref T reply) @trusted
    in (!data.empty, "promise must be initialized") {
        if (data.empty)
            return;
        scope (exit)
            data.release;

        // TODO: should probably call delivering actor with an ErrorMsg if replyTo is closed.
        if (auto replyTo = data.replyTo.lock.get) {
            enum wrapInTuple = !is(T : Tuple!U, U);
            static if (wrapInTuple)
                replyTo.put(Reply(data.replyId, Variant(tuple(reply))));
            else
                replyTo.put(Reply(data.replyId, Variant(reply)));
        }
    }

    void opAssign(Promise!T rhs) {
        data = rhs.data;
    }

    /// True if the promise is not initialized and thus unusable.
    bool empty() {
        version (mylib_actor_trace) {
            logger.infof("Promise!(%s)(empty or replyId: %s)", T.stringof,
                    data.empty ? -1 : data.replyId);
        }
        return data.empty || data.replyId == 0;
    }

    /// Clear the promise.
    void clear() {
        data.release;
    }
}

auto makePromise(T)() {
    return Promise!T(PromiseData.init);
}

struct RequestResult(T) {
    this(T v) {
        value = typeof(value)(v);
    }

    this(ErrorMsg v) {
        value = typeof(value)(v);
    }

    this(Promise!T v) {
        value = typeof(value)(v);
    }

    SumType!(T, ErrorMsg, Promise!T) value;
}

package alias MsgHandler = void delegate(void* ctx, ref Variant msg) @safe;
package alias RequestHandler = void delegate(void* ctx, ref Variant msg,
        ulong replyId, WeakAddress replyTo) @safe;
package alias ReplyHandler = void delegate(void* ctx, ref Variant msg) @safe;

alias DefaultHandler = void delegate(scope ref ActorShell self, ref Variant msg) @safe nothrow;

/** Actors send error messages to others by returning an error
 * from a message handler. Similar to exit messages, error messages usually
 * cause the receiving actor to terminate, unless a custom handler was
 * installed. The default handler is used as fallback if request is used
 * without error handler.
 */
alias ErrorHandler = void delegate(scope ref ActorShell self, scope ErrorMsg) @safe nothrow;

/** Bidirectional monitoring with a strong lifetime coupling is established by
 * calling a `LinkRequest` to an address. This will cause the runtime to send
 * an `ExitMsg` if either this or other dies. Per default, actors terminate
 * after receiving an `ExitMsg` unless the exit reason is `ExitReason.normal`.
 * This mechanism propagates failure states in an actor system. Linked actors
 * form a sub system in which an error causes all actors to fail collectively.
 */
alias ExitHandler = void delegate(scope ref ActorShell self, scope ExitMsg msg) @safe nothrow;

/// An exception has been thrown while processing a message.
alias ExceptionHandler = void delegate(scope ref ActorShell self, scope Exception e) @safe nothrow;

/** Actors can monitor the lifetime of other actors by sending a `MonitorRequest`
 * to an address. This will cause the runtime system to send a `DownMsg` for
 * other if it dies.
 *
 * Actors drop down messages unless they provide a custom handler.
 */
alias DownHandler = void delegate(scope ref ActorShell self, scope DownMsg msg) @safe nothrow;

void defaultHandler(scope ref ActorShell self, ref Variant msg) @safe nothrow {
}

/// Write the name of the actor and the message type to the console.
void logAndDropHandler(scope ref ActorShell self, ref Variant msg) @trusted nothrow {
    import std.stdio : writeln;

    try {
        writeln("UNKNOWN message sent to actor ", self.name);
        writeln(msg.toString);
    } catch (Exception e) {
    }
}

void defaultErrorHandler(scope ref ActorShell self, scope ErrorMsg msg) @safe nothrow {
    version (mylib_actor_trace) {
        try {
            logger.tracef("%X [%s] source %s shutdown: error: %s (source %s)",
                    self.id, self.name, msg.source.toHash, msg.reason);
        } catch (Exception e) {
        }
    }
    self.errorReason = msg.reason;
    self.shutdown;
}

void defaultExitHandler(scope ref ActorShell self, scope ExitMsg msg) @safe nothrow {
    version (mylib_actor_trace) {
        try {
            logger.tracef("%X [%s] source %s shutdown: exit: %s", self.id,
                    self.name, msg.source.toHash, msg.reason);
        } catch (Exception e) {
        }
    }
    self.errorReason = msg.reason;
    self.forceShutdown;
}

void defaultExceptionHandler(scope ref ActorShell self, scope Exception e) @safe nothrow {
    version (mylib_actor_trace) {
        try {
            logger.tracef("%X [%s] shutdown: exception: %s", self.id, self.name, e.msg);
        } catch (Exception e) {
        }
    }
    self.errorReason = SystemError.runtimeError;
    self.forceShutdown;
}

// Log the name of the actor and the exception.
void logExceptionHandler(scope ref ActorShell self, scope Exception e) @safe nothrow {
    self.errorReason = SystemError.runtimeError;
    try {
        logger.infof("[%s] shutdown: exception: %s: ", self.name, e.msg);
    } catch (Exception e) {
    }
    self.forceShutdown;
}

/// Timeout for an outstanding request.
struct ReplyHandlerTimeout {
    ulong id;
    SysTime timeout;
}

package enum ActorState {
    /// waiting to be started.
    waiting,
    /// active and processing messages.
    active,
    /// wait for all awaited responses to finish
    shutdown,
    /// discard also the awaited responses, just shutdown fast
    forceShutdown,
    /// in process of shutting down
    finishShutdown,
    /// stopped.
    stopped,
}

private struct AwaitReponse {
    Closure!(ReplyHandler, void*) behavior;
    ErrorHandler onError;
    string name;

    string toString() @safe pure nothrow const @nogc {
        return name;
    }
}

private struct Behavior2(HandlerT) {
    Closure2!HandlerT behavior;
    string name;

    string toString() @safe pure nothrow const @nogc {
        return name;
    }
}

struct ActorShell {
    import std.container.rbtree : RedBlackTree, redBlackTree;

    package StrongAddress addr;
    // visible in the package for logging purpose.
    package ActorState state_ = ActorState.stopped;

    private {
        Mutex mtx;

        ActorState lastState_ = ActorState.stopped;

        // TODO: rename to behavior.
        Behavior2!(MsgHandler)[ulong] incoming2;
        Behavior2!(RequestHandler)[ulong] reqBehavior2;

        // callbacks for awaited responses keyed on their id.
        AwaitReponse[ulong] awaitedResponses;
        ReplyHandlerTimeout[] replyTimeouts;

        // important that it start at 1 because then zero is known to not be initialized.
        ulong nextReplyId_ = 1;

        /// Delayed messages ordered by their trigger time.
        RedBlackTree!(DelayedMsg*, "a.triggerAt < b.triggerAt", true) delayed;

        /// Used during shutdown to signal monitors and links why this actor is terminating.
        SystemError lastError_;

        /// monitoring the actor lifetime.
        WeakAddress[size_t] monitors;

        /// strong, bidirectional link of the actors lifetime.
        WeakAddress[size_t] links;

        // Number of messages that has been processed.
        ulong messages_;

        /// System the actor belongs to.
        System* homeSystem_;

        /// Name of the actor
        string name_;

        /// Context used by behaviors.
        void* context_;
        void function(void* ctx) cleanupContext_;

        ErrorHandler errorHandler_;

        /// callback when a link goes down.
        DownHandler downHandler_;

        ExitHandler exitHandler_;

        ExceptionHandler exceptionHandler_;

        DefaultHandler defaultHandler_;

        /// One-shot launch hook (see `launchHandler`). Null if not set.
        void delegate() @safe launch_;

        /// Repeating self-tick (see `scheduleRepeating`): a valid pending
        /// entry (in the delayed mailbox queue or `delayed`) exists while
        /// `tickPending_` and its `seq` equals `tickSeq_`. At most one such
        /// entry exists at any time.
        bool tickPending_;
        ulong tickSeq_;
        Duration tickInterval_;
    }

    invariant () {
        if (addr && !state_.among(ActorState.waiting, ActorState.shutdown)) {
            assert(errorHandler_);
            assert(exitHandler_);
            assert(exceptionHandler_);
            assert(defaultHandler_);
        }
    }

    this(StrongAddress a) @trusted
    in (!a.empty, "address is empty") {
        mtx = new Mutex();
        state_ = ActorState.waiting;

        addr = a;
        addr.get.setOpen;
        delayed = new typeof(delayed);

        errorHandler_ = toDelegate(&defaultErrorHandler);
        downHandler_ = null;
        exitHandler_ = toDelegate(&defaultExitHandler);
        exceptionHandler_ = toDelegate(&defaultExceptionHandler);
        defaultHandler_ = toDelegate(&.defaultHandler);
    }

    WeakAddress address() @safe {
        return addr.weakRef;
    }

    package ref StrongAddress addressRef() return @safe pure nothrow @nogc {
        return addr;
    }

    ref System homeSystem() @safe pure nothrow @nogc {
        return *homeSystem_;
    }

    /** Clean shutdown of the actor
     *
     * Stopping incoming messages from triggering new behavior and finish all
     * awaited responses.
     */
    void shutdown() @safe nothrow scope {
        if (state_.among(ActorState.waiting, ActorState.active))
            state_ = ActorState.shutdown;
    }

    /** Force an immediate shutdown.
     *
     * Stopping incoming messages from triggering new behavior and discard all
     * awaited responses.
     */
    void forceShutdown() @safe nothrow scope {
        if (state_.among(ActorState.waiting, ActorState.active, ActorState.shutdown))
            state_ = ActorState.forceShutdown;
    }

    ulong id() @safe pure nothrow const @nogc scope {
        return addr.id;
    }

    /// Returns: the name of the actor.
    string name() @safe pure nothrow const return scope {
        return name_;
    }

    // dfmt off

    /// Set the name of the actor.
    void name(string n) @safe pure nothrow @nogc scope {
        this.name_ = n;
    }

    void errorHandler(ErrorHandler v) @safe pure nothrow @nogc scope {
        errorHandler_ = v;
    }

    void downHandler(DownHandler v) @safe pure nothrow @nogc scope {
        downHandler_ = v;
    }

    void exitHandler(ExitHandler v) @safe pure nothrow @nogc scope {
        exitHandler_ = v;
    }

    void exceptionHandler(ExceptionHandler v) @safe pure nothrow @nogc scope {
        exceptionHandler_ = v;
    }

    void defaultHandler(DefaultHandler v) @safe pure nothrow @nogc scope {
        defaultHandler_ = v;
    }

    /// Set the one-shot launch hook: runs on the actor's own context, before
    /// the first message is processed; a throwing call follows the normal
    /// actor error path (exceptionHandler_). The delegate and any state it
    /// captures must stay valid until the first tick. If the actor is
    /// force-shutdown before its first tick the hook is not invoked.
    package void launchHandler(void delegate() @safe d) @safe pure nothrow @nogc
    {
        launch_ = d;
    }

    /// Error reason to signal to monitors and links why the actor is terminated when forceShutdown is called.
    void errorReason(SystemError e) @safe pure nothrow @nogc scope {
        lastError_ = e;
    }

    // dfmt on

package:
    bool hasMessage() @safe pure nothrow @nogc {
        try {
            synchronized (mtx) {
                return (cast() addr) && addr.get.hasMessage;
            }
        } catch (Exception e) {
        }
        return false;
    }

    /// How long until a delayed message or a timeout fires.
    Duration nextTimeout(const SysTime now, const Duration default_) @safe {
        return min(delayed.empty ? default_ : (delayed.front.triggerAt - now),
                replyTimeouts.empty ? default_ : (replyTimeouts[0].timeout - now));
    }

    /** Arm a repeating self-tick: a one-shot message to this actor's own
     * `method` is staged in the delayed mailbox queue to fire at
     * +`interval`; on fire the shell dispatches it directly and re-arms the
     * entry at +`interval` (at most one pending entry at any time). The
     * first fire is at +`interval`, never immediately. A re-schedule
     * replaces the pending entry; see `cancelTick`. No-op if the actor is
     * no longer accepting messages. */
    package void scheduleRepeating(Duration interval, ulong signature, Variant data) @trusted {
        if (!isAccepting)
            return;
        cancelTick;
        tickSeq_++;
        auto d = DelayedMsg(Msg(signature, MsgType(MsgOneShot(data))), Clock.currTime + interval);
        d.repeating = true;
        d.seq = tickSeq_;
        tickPending_ = true;
        tickInterval_ = interval;
        addr.get.put(d);
    }

    /** Cancel a pending repeating tick (no-op if none). The entry is not
     * removed eagerly; it is dropped without dispatch when it comes due
     * (its `seq` no longer matches `tickSeq_`). Safe from inside the tick
     * handler — the in-flight entry simply does not re-arm. */
    package void cancelTick() @trusted {
        tickPending_ = false;
        tickSeq_++;
    }

    bool waitingForReply() @safe pure nothrow const @nogc {
        return !awaitedResponses.empty;
    }

    /// Number of messages that has been processed.
    ulong messages() @safe pure nothrow const @nogc {
        return messages_;
    }

    void setHomeSystem(System* sys) @safe pure nothrow @nogc {
        homeSystem_ = sys;
    }

    void setContext(void* context, void function(void*) cleanup = null) @trusted {
        this.context_ = context;
        this.cleanupContext_ = cleanup;
    }

    void cleanupContext() @trusted nothrow scope {
        if (context_) {
            try {
                if (cleanupContext_)
                    cleanupContext_(context_);
            } catch (Exception e) {
            }
            context_ = null;
            cleanupContext_ = null;
        }
    }

    void cleanupBehavior() @trusted nothrow scope {
        incoming2 = null;
        reqBehavior2 = null;
    }

    void cleanupAwait() @trusted nothrow scope {
        foreach (ref a; awaitedResponses.byValue) {
            try {
                a.behavior.free;
            } catch (Exception e) {
            }
        }
        awaitedResponses = null;
    }

    void cleanupDelayed() @trusted nothrow scope {
        tickPending_ = false;
        tickSeq_++;
        foreach (const _; 0 .. delayed.length) {
            try {
                delayed.front.msg = Msg.init;
                delayed.removeFront;
            } catch (Exception e) {
            }
        }
        .destroy(delayed);
    }

    bool isAlive() @safe pure nothrow const @nogc scope {
        final switch (state_) {
        case ActorState.waiting:
            goto case;
        case ActorState.active:
            goto case;
        case ActorState.shutdown:
            goto case;
        case ActorState.forceShutdown:
            goto case;
        case ActorState.finishShutdown:
            return true;
        case ActorState.stopped:
            return false;
        }
    }

    /// Accepting messages.
    bool isAccepting() @safe pure nothrow const @nogc scope {
        final switch (state_) {
        case ActorState.waiting:
            goto case;
        case ActorState.active:
            goto case;
        case ActorState.shutdown:
            return true;
        case ActorState.forceShutdown:
            goto case;
        case ActorState.finishShutdown:
            goto case;
        case ActorState.stopped:
            return false;
        }
    }

    ulong nextReplyId() @safe {
        return nextReplyId_++;
    }

    /// Public function to enable unittesting
    public void process(const SysTime now) @safe nothrow scope {
        import core.memory : GC;

        assert(!GC.inFinalizer);

        messages_ = 0;

        // Bounded mailbox support (see README, "Bounded mailbox"): mark this
        // thread as an actor worker for the duration of the message loop so
        // a full bounded mailbox drops our sends instead of blocking us —
        // blocking a pool worker is the deadlock the bound exists to
        // prevent. Unconditional (not gated on bounded mailboxes existing):
        // a dispatch that started before the process's first spawnBounded
        // must still count as a worker once that mailbox appears
        // mid-dispatch, or its sends would take the blocking non-actor
        // path. process() is re-entrant on one thread (the scoped actor
        // request loop), so the mark is reference counted. The flag is a
        // plain thread-local variable in mailbox.d, so the cost is an
        // integer bump per dispatch, not per message.
        setActorWorker(true);
        scope (exit)
            setActorWorker(false);

        void tick() @safe scope {
            // Timeouts are checked before processing a reply: a reply that
            // has already timed out is too old to be useful, so failing is
            // better than delivering it.
            try {
                if (launch_ !is null) {
                    auto launch = launch_;
                    launch_ = null; // once: clear before the call
                    launch();
                }
                processSystemMsg();
                checkReplyTimeout(now);
                processDelayed(now);
                processIncoming();
                processReply();
            } catch (Exception e) {
                exceptionHandler_(this, e);
            }
        }

        assert(state_ == ActorState.stopped || addr, "no address");

        version (mylib_actor_trace) {
            if (state_ != lastState_) {
                try {
                    logger.tracef("actor:%X [%s] state: %s -> %s", id, name, lastState_, state_);
                } catch (Exception e) {
                }
                lastState_ = state_;
            }

            if (state_ != ActorState.stopped && addr.get.hasMessage) {
                try {
                    logger.tracef("actor:%X [%s] mailbox:%s", id, name, addr.get.length);
                } catch (Exception e) {
                }
            }
        }

        final switch (state_) {
        case ActorState.waiting:
            state_ = ActorState.active;
            tick;
            // the state can be changed before the actor has executed.
            break;
        case ActorState.active:
            tick;
            // self terminate if the actor has no behavior.
            if (incoming2.empty && awaitedResponses.empty && reqBehavior2.empty)
                state_ = ActorState.forceShutdown;
            break;
        case ActorState.shutdown:
            tick;
            if (awaitedResponses.empty)
                state_ = ActorState.finishShutdown;
            cleanupBehavior;
            break;
        case ActorState.forceShutdown:
            state_ = ActorState.finishShutdown;
            cleanupBehavior;
            addr.get.setClosed;
            break;
        case ActorState.finishShutdown:
            state_ = ActorState.stopped;

            sendToMonitors(DownMsg(addr.weakRef, lastError_));
            sendToLinks(ExitMsg(addr.weakRef, lastError_));

            replyTimeouts = null;
            cleanupDelayed;
            cleanupAwait;
            cleanupContext;

            // must be last because sendToLinks and sendToMonitors uses addr.
            addr.get.shutdown();
            addr.release;
            break;
        case ActorState.stopped:
            break;
        }
    }

    void sendToMonitors(scope DownMsg msg) @safe nothrow scope {
        try {
            foreach (ref a; monitors) {
                try {
                    auto tmp = a.lock;
                    auto rc = tmp.get;
                    if (rc)
                        rc.put(SystemMsg(msg));
                    a.release;
                } catch (Exception e) {
                }
            }
        } catch (Exception e) {
        }

        monitors = null;
    }

    void sendToLinks(scope ExitMsg msg) @safe nothrow scope {
        try {
            foreach (ref a; links) {
                try {
                    auto tmp = a.lock;
                    auto rc = tmp.get;
                    if (rc)
                        rc.put(SystemMsg(msg));
                    a.release;
                } catch (Exception e) {
                }
            }
        } catch (Exception e) {
        }

        links = null;
    }

    void checkReplyTimeout(const SysTime now) @safe scope {
        if (replyTimeouts.empty)
            return;

        size_t removeTo;
        foreach (const i; 0 .. replyTimeouts.length) {
            if (now > replyTimeouts[i].timeout) {
                auto id = replyTimeouts[i].id;
                if (auto v = id in awaitedResponses) {
                    messages_++;
                    v.onError(this, ErrorMsg(addr.weakRef, SystemError.requestTimeout));
                    try {
                        () @trusted { v.behavior.free; }();
                    } catch (Exception e) {
                    }
                    awaitedResponses.remove(id);
                }
                removeTo = i + 1;
            } else {
                break;
            }
        }

        if (removeTo >= replyTimeouts.length) {
            replyTimeouts = null;
        } else if (removeTo != 0) {
            replyTimeouts = replyTimeouts[removeTo .. $];
        }
    }

    void processIncoming() @safe scope {
        if (addr.get.empty!Msg)
            return;
        messages_++;

        auto front = addr.get.pop!Msg;
        scope (exit)
            .destroy(front);

        void doSend(ref MsgOneShot msg) @trusted {
            if (auto v = front.get.signature in incoming2) {
                version (mylib_actor_trace) {
                    logger.tracef("actor:%X [%s] process send: %s (%X)", id,
                            name, v.name, front.get.signature).collectException;
                }
                v.behavior(context_, msg.data);
            } else {
                version (mylib_actor_trace) {
                    logger.tracef("actor:%X [%s] process send: no message handler with signature: %s",
                            id, name, front.get.signature).collectException;
                }
                defaultHandler_(this, msg.data);
            }
        }

        void doRequest(ref MsgRequest msg) @trusted {
            if (auto v = front.get.signature in reqBehavior2) {
                version (mylib_actor_trace) {
                    logger.tracef("actor:%X [%s] process request from %X: %s (%X)", id, name,
                            msg.replyTo.toHash, v.name, front.get.signature).collectException;
                }
                v.behavior(context_, msg.data, msg.replyId, msg.replyTo);
            } else {
                version (mylib_actor_trace) {
                    logger.tracef("actor:%X [%s] process request from %X: no message handler with signature: %s", id,
                            name, msg.replyTo.toHash, front.get.signature).collectException;
                }
                defaultHandler_(this, msg.data);
            }
        }

        front.get.type.match!((ref MsgOneShot a) { doSend(a); }, (ref MsgRequest a) {
            doRequest(a);
        });
    }

    /** All system messages are handled.
     *
     * Assuming:
     *  * they are not heavy to process
     *  * if there are any they should be handled as soon as possible
     *  * the volume of system messages is bounded (a "storm" of system messages
     *    is out of scope; external inputs that could trigger such a volume
     *    should be controlled and limited)
     */
    void processSystemMsg() @safe scope {
        while (!addr.get.empty!SystemMsg) {
            messages_++;
            auto front = addr.get.pop!SystemMsg;
            scope (exit)
                .destroy(front);

            version (mylib_actor_trace) {
                () @trusted {
                    logger.tracef("actor:%X [%s] system message: %s", id, name,
                            front.get).collectException;
                }();
            }

            front.get.match!((ref DownMsg a) {
                if (downHandler_)
                    downHandler_(this, a);
            }, (ref MonitorRequest a) { monitors[a.addr.toHash] = a.addr; }, (ref DemonitorRequest a) {
                if (auto v = a.addr.toHash in monitors)
                    v.release;
                monitors.remove(a.addr.toHash);
            }, (ref LinkRequest a) { links[a.addr.toHash] = a.addr; }, (ref UnlinkRequest a) {
                if (auto v = a.addr.toHash in links)
                    v.release;
                links.remove(a.addr.toHash);
            }, (ref ErrorMsg a) { errorHandler_(this, a); }, (ref ExitMsg a) {
                exitHandler_(this, a);
            }, (ref SystemExitMsg a) {
                final switch (a.reason) {
                case ExitReason.normal:
                    break;
                case ExitReason.unhandledException:
                    exitHandler_(this, ExitMsg.init);
                    break;
                case ExitReason.unknown:
                    exitHandler_(this, ExitMsg.init);
                    break;
                case ExitReason.userShutdown:
                    exitHandler_(this, ExitMsg.init);
                    break;
                case ExitReason.kill:
                    exitHandler_(this, ExitMsg.init);
                    // the user has NO option here
                    forceShutdown;
                    break;
                }
            });
        }
    }

    void processReply() @safe scope {
        if (addr.get.empty!Reply)
            return;
        messages_++;

        auto front = addr.get.pop!Reply;
        auto msgId = front.get.id;
        scope (exit)
            .destroy(front);

        if (auto v = msgId in awaitedResponses) {
            version (mylib_actor_trace) {
                () @trusted {
                    logger.tracef("actor:%X [%s] reply_id:%s - %s", id, name,
                            msgId, v.name).collectException;
                }();
            }

            scope (exit)
                () {
                awaitedResponses.remove(msgId);
                removeReplyTimeout(msgId);
                try {
                    () @trusted { v.behavior.free; }();
                } catch (Exception e) {
                }
            }();
            v.behavior(front.get.data);
        } else {
            version (mylib_actor_trace) {
                () @trusted {
                    logger.tracef("actor:%X [%s] reply_id:%s - no handler", id,
                            name, msgId).collectException;
                }();
            }
            // TODO: should probably be SystemError.unexpectedResponse?
            defaultHandler_(this, front.get.data);
        }
    }

    void processDelayed(const SysTime now) @trusted scope {
        if (!addr.get.empty!DelayedMsg) {
            // count as a message because handling them is "expensive". A message
            // moved to the incoming queue in the same tick is counted again
            // (double accounting, accepted).
            // Prefer plain sends; use delayed sends only when the delay is needed.
            messages_++;
            delayed.insert(addr.get.pop!DelayedMsg.unsafeMove);
        } else if (delayed.empty) {
            return;
        }

        foreach (const i; 0 .. delayed.length) {
            if (now > delayed.front.triggerAt) {
                auto d = delayed.front;
                delayed.removeFront;
                if (d.repeating)
                    fireRepeatingTick(d, now);
                else
                    addr.get.put(d.msg);
            } else {
                break;
            }
        }
    }

    /** Fire a repeating self-tick entry (see `scheduleRepeating`):
     * dispatch the message directly on this actor (no mailbox round trip —
     * a throwing handler must stop the re-arm) and re-arm at +interval
     * unless cancelled, replaced, or shutting down. An exception escapes to
     * the tick's catch → `onException`; the repeat stops. */
    private void fireRepeatingTick(DelayedMsg* d, const SysTime now) @trusted scope {
        if (!tickPending_ || d.seq != tickSeq_)
            return; // cancelled or replaced: drop without dispatch
        messages_++;

        d.msg.type.match!((ref MsgOneShot a) {
            if (auto v = d.msg.signature in incoming2)
                v.behavior(context_, a.data);
            else
                defaultHandler_(this, a.data);
        }, (ref MsgRequest a) {
            // repeating entries are built as one-shots by scheduleRepeating;
            // a request payload here is malformed — default handling drops it.
            defaultHandler_(this, a.data);
        });

        if (tickPending_ && d.seq == tickSeq_ && state_.among(ActorState.waiting,
                ActorState.active)) {
            d.triggerAt = now + tickInterval_;
            delayed.insert(d);
        }
    }

    private void removeReplyTimeout(ulong id) @trusted nothrow scope {
        import std.algorithm : remove;

        foreach (const i; 0 .. replyTimeouts.length) {
            if (replyTimeouts[i].id == id) {
                remove(replyTimeouts, i);
                break;
            }
        }
    }

    void register(string desc, ulong signature, Closure2!MsgHandler handler) @trusted
    in (!desc.empty) {
        if (!isAccepting)
            return;

        incoming2[signature] = Behavior2!MsgHandler(handler, desc);
        version (mylib_actor_trace) {
            logger.tracef("actor:%X [%s] reply handler (%X): %s", id, name, signature, desc);
        }
    }

    void register(string desc, ulong signature, Closure2!RequestHandler handler) @trusted
    in (!desc.empty) {
        if (!isAccepting)
            return;

        reqBehavior2[signature] = Behavior2!RequestHandler(handler, desc);
        version (mylib_actor_trace) {
            logger.tracef("actor:%X [%s] request handler (%X): %s", id, name, signature, desc);
        }
    }

    void register(string desc, ulong replyId, SysTime timeout,
            Closure!(ReplyHandler, void*) reply, ErrorHandler onError) @safe //in (!name.empty)
            {
        if (!isAccepting)
            return;

        awaitedResponses[replyId] = AwaitReponse(reply, onError is null
                ? errorHandler_ : onError, desc);
        replyTimeouts ~= ReplyHandlerTimeout(replyId, timeout);
        schwartzSort!(a => a.timeout, (a, b) => a < b)(replyTimeouts);
        version (mylib_actor_trace) {
            logger.tracef("actor:%X [%s] awaited reply_id:%s handler: %s ", id,
                    name, replyId, desc);
        }
    }
}

struct Closure(Fn, CtxT) {
    alias FreeFn = void function(CtxT);

    Fn fn;
    CtxT ctx;
    FreeFn cleanup;

    this(Fn fn) {
        this.fn = fn;
    }

    this(Fn fn, CtxT* ctx, FreeFn cleanup) {
        this.fn = fn;
        this.ctx = ctx;
        this.cleanup = cleanup;
    }

    void opCall(Args...)(auto ref Args args) {
        assert(fn !is null);
        fn(ctx, args);
    }

    void free() {
        // will crash on purpose if there is a ctx and no cleanup registered.
        if (ctx)
            cleanup(ctx);
        ctx = CtxT.init;
    }
}

@("shall register a behavior to be called when msg received matching signature")
unittest {
    auto addr = makeAddress;
    auto actor = ActorShell(addr);

    bool processedIncoming;
    void fn(void* ctx, ref Variant msg) @trusted {
        *(cast(bool*) ctx) = true;
    }

    actor.setContext(cast(void*)&processedIncoming, null);
    actor.register("foo", 1, Closure2!MsgHandler(&fn));
    addr.get.put(Msg(1, MsgType(MsgOneShot(Variant(42)))));

    actor.process(Clock.currTime);

    assert(processedIncoming);
}

@("shall register a behavior to be called when msg received matching signature")
unittest {
    auto addr = makeAddress;
    auto actor = ActorShell(addr);

    struct LocalContext {
        bool processedIncoming;
    }

    LocalContext ctx;
    void fn(void* ctx, ref Variant msg) @trusted {
        (cast(LocalContext*) ctx).processedIncoming = true;
    }

    actor.setContext(&ctx);
    actor.register("foo", 1, Closure2!MsgHandler(&fn));
    addr.get.put(Msg(1, MsgType(MsgOneShot(Variant(42)))));

    actor.process(Clock.currTime);

    assert(ctx.processedIncoming);
}

private void cleanupCtx(CtxT)(void* ctx)
        if (is(CtxT == Tuple!T, T) || is(CtxT == void)) {
    import std.traits;
    import core.memory : GC;

    static if (!is(CtxT == void)) {
        // trust that any use of this also pass on the correct context type.
        auto userCtx = () @trusted { return cast(CtxT*) ctx; }();
        // release the context such as if it holds a rc object.
        alias Types = CtxT.Types;

        static foreach (const i; 0 .. CtxT.Types.length) {
            {
                alias T = CtxT.Types[i];
                alias UT = Unqual!T;
                static if (!is(T == UT)) {
                    static assert(!is(UT : WeakAddress),
                            "WeakAddress must NEVER be const or immutable");
                }
                // TODO: add a -version actor_ctx_diagnostic that prints when it is unable to deinit?
            }
        }
        if (!GC.inFinalizer) {
            .destroy(*userCtx);
        }
    }
}

@("shall cleanup all tuples values")
unittest {
    {
        auto x = tuple(cast(const) 42, 43);
        alias T = typeof(x);
        cleanupCtx!T(cast(void*)&x);
        assert(x[0] == 0);
        assert(x[1] == 0);
    }

    {
        import my.path : Path;

        auto x = tuple(Path.init, cast(const) Path("foo"));
        alias T = typeof(x);
        cleanupCtx!T(cast(void*)&x);
        assert(x[0] == Path.init);
        assert(x[1] == Path.init);
    }
}

struct Closure2(Fn) {
    Fn fn;

    this(Fn fn) {
        this.fn = fn;
    }

    void opCall(Args...)(void* ctx, auto ref Args args) {
        assert(fn !is null);
        fn(ctx, args);
    }
}

package Closure!(ReplyHandler, void*) makeReply2(T, CtxT = void)(T handler) @safe {
    static if (is(CtxT == void))
        alias Params = Parameters!T;
    else {
        alias CtxParam = Parameters!T[0];
        alias Params = Parameters!T[1 .. $];
        checkMatchingCtx!(CtxParam, CtxT);
        checkRefForContext!handler;
    }

    alias HArgs = staticMap!(Unqual, Params);

    void fn(void* ctx, ref Variant msg) @trusted {
        static if (is(CtxT == void)) {
            handler(msg.get!(Tuple!HArgs).expand);
        } else {
            auto userCtx = cast(CtxParam*) cast(CtxT*) ctx;
            handler(*userCtx, msg.get!(Tuple!HArgs).expand);
        }
    }

    return typeof(return)(&fn, null, &cleanupCtx!CtxT);
}

/// Check that the context parameter is `ref` otherwise issue a warning.
package void checkRefForContext(alias handler)() {
    import std.traits : ParameterStorageClass, ParameterStorageClassTuple;

    alias CtxParam = ParameterStorageClassTuple!(typeof(handler))[0];

    static if (CtxParam != ParameterStorageClass.ref_) {
        pragma(msg, "INFO: handler type is " ~ typeof(handler).stringof);
        static assert(CtxParam == ParameterStorageClass.ref_,
                "The context must be `ref` to avoid unnecessary copying");
    }
}

package void checkMatchingCtx(CtxParam, CtxT)() {
    import my.actor.msg : isCapture;

    static string errorStr(int i) {
        import std.conv : to;

        if (i == -1)
            return "mismatch between the context type " ~ CtxT.stringof
                ~ " and the first parameter " ~ CtxParam.stringof;
        return "mismatch between the context type " ~ CtxT.stringof
            ~ " and first parameter " ~ CtxParam.stringof ~ " at index " ~ i.to!string;
    }

    static if (isCapture!CtxT && isCapture!CtxParam) {
        static foreach (const i; 0 .. CtxParam.Types.length) {
            static assert(__traits(isSame, CtxParam.Types[i], CtxT.Types[i]), errorStr(i));
        }
    } else static if (!is(CtxT == CtxParam)) {
        static assert(__traits(compiles, { auto x = CtxParam(CtxT.init.expand); }), errorStr(-1));
    }
}

@("shall link two actors lifetime")
unittest {
    class LinkedActor {
        int exited;

        void foo(int x) @safe {
        }

        void onExit(ExitMsg msg) @safe {
            exited++;
        }
    }

    auto aa1 = ActorShell(makeAddress);
    auto a1 = new LinkedActor;
    implActor(a1, &aa1);
    auto aa2 = ActorShell(makeAddress);
    auto a2 = new LinkedActor;
    implActor(a2, &aa2);

    linkTo(aa1.address, aa2.address);
    aa1.process(Clock.currTime);
    aa2.process(Clock.currTime);

    assert(aa1.isAlive());
    assert(aa2.isAlive());

    sendExit(aa1.address, ExitReason.kill);
    foreach (_; 0 .. 5) {
        aa1.process(Clock.currTime);
        aa2.process(Clock.currTime);
    }

    assert(!aa1.isAlive(), "the killed actor terminates");
    assert(aa2.isAlive(), "receiving the exit message does not kill the linked actor");
    assert(a1.exited == 1, "the killed actor ran its onExit hook");
    assert(a2.exited == 1, "kill/exit propagated to the linked actor via onExit");

    sendExit(aa2.address, ExitReason.kill);
    foreach (_; 0 .. 5)
        aa2.process(Clock.currTime);
    assert(!aa2.isAlive(), "the survivor shuts down via the system message");
}

@("shall let one actor monitor the lifetime of the other one")
unittest {
    class MonitoringActor {
        int downs;

        void a1(int x) @safe {
        }

        void onDownMessage(DownMsg msg) @safe {
            downs++;
        }
    }

    class PlainActor {
        void a2(int x) @safe {
        }
    }

    auto aa1 = ActorShell(makeAddress);
    auto a1 = new MonitoringActor;
    implActor(a1, &aa1);
    auto aa2 = ActorShell(makeAddress);
    auto a2 = new PlainActor;
    implActor(a2, &aa2);

    monitor(aa1.address, aa2.address);
    aa1.process(Clock.currTime);
    aa2.process(Clock.currTime);

    assert(aa1.isAlive());
    assert(aa2.isAlive());

    sendExit(aa2.address, ExitReason.userShutdown);
    foreach (_; 0 .. 5) {
        aa1.process(Clock.currTime);
        aa2.process(Clock.currTime);
    }

    assert(aa1.isAlive());
    assert(!aa2.isAlive());
    assert(a1.downs == 1, "exactly one DownMsg delivered to the monitor");

    sendExit(aa1.address, ExitReason.userShutdown);
    foreach (_; 0 .. 5)
        aa1.process(Clock.currTime);
    assert(!aa1.isAlive());
}

@("shall build a class actor with void, string and tuple returning methods")
unittest {
    import my.actor.channel;

    class Dyn {
        void one(int s) @safe {
        }

        string two(int s) @safe {
            return "foo";
        }

        Tuple!(int, string) three(const string s) @safe {
            return typeof(return)(42, "hej");
        }
    }

    auto aa1 = ActorShell(makeAddress);
    auto a1 = new Dyn;
    implActor(a1, &aa1);

    dynSend(aa1.address, "one", 1);
    foreach (_; 0 .. 4)
        aa1.process(Clock.currTime);
    assert(aa1.addressRef.get.empty!Msg, "the void method ran");

    Tuple!(int, string) r3;
    static void onThree(ref Tuple!(Tuple!(int, string)*) ctx, int i, const string s) {
        *ctx[0] = tuple(i, s);
    }

    dynRequest(&aa1, aa1.address, infTimeout, "three", "x").capture(&r3).then(&onThree);
    foreach (_; 0 .. 4)
        aa1.process(Clock.currTime);
    assert(r3 == tuple(42, "hej"), "the tuple return round-tripped");

    sendExit(aa1.address, ExitReason.userShutdown);
    int guard;
    while (aa1.isAlive() && guard++ < 100)
        aa1.process(Clock.currTime);
    assert(!aa1.isAlive());
}

@("shall copy and use the context in the actor")
unittest {
    import my.actor.channel;

    class AClassWithInnerPtr {
        int* v;
        this(int v) {
            this.v = new int;
            *this.v = v;
        }
    }

    class CtxActor {
        AClassWithInnerPtr inner;
        bool* tickCalled;

        this(AClassWithInnerPtr inner, bool* tickCalled) @safe {
            this.inner = inner;
            this.tickCalled = tickCalled;
        }

        void tick(int s) @safe {
            assert(inner !is null);
            assert(inner.v !is null);
            assert(*inner.v == 42);
            *tickCalled = true;
        }
    }

    bool tickCalled;
    auto base = ActorShell(makeAddress);
    auto actor = new CtxActor(new AClassWithInnerPtr(42), &tickCalled);
    implActor(actor, &base);
    dynSend(base.address, "tick", 42);
    foreach (_; 0 .. 10)
        base.process(Clock.currTime);
    assert(tickCalled);

    sendExit(base.address, ExitReason.userShutdown);
    int guard;
    while (base.isAlive() && guard++ < 100)
        base.process(Clock.currTime);
    assert(!base.isAlive());
}

shared static this() {
    version (unittest) {
        logger.globalLogLevel = logger.LogLevel.all;
        (cast() logger.sharedLog).logLevel = logger.LogLevel.all;
    }
}

@("shall receive the sent message")
unittest {
    import my.actor.channel;

    class RecvActor {
        bool* sendOk;
        bool* shouldNeverHappen;

        this(bool* sendOk, bool* shouldNeverHappen) @safe {
            this.sendOk = sendOk;
            this.shouldNeverHappen = shouldNeverHappen;
        }

        void actor(const string s) @safe {
            *sendOk = true;
        }

        void actor(int s) @safe {
            *shouldNeverHappen = true;
        }
    }

    bool sendOk;
    bool shouldNeverHappen;
    auto aa1 = ActorShell(makeAddress);
    auto actor = new RecvActor(&sendOk, &shouldNeverHappen);
    implActor(actor, &aa1);
    dynSend(aa1.address, "actor", "foo");

    assert(aa1.addressRef.get.empty!DelayedMsg);
    assert(!aa1.addressRef.get.empty!Msg);
    assert(aa1.addressRef.get.empty!Reply);

    foreach (_; 0 .. 10)
        aa1.process(Clock.currTime);

    assert(aa1.addressRef.get.empty!DelayedMsg);
    assert(aa1.addressRef.get.empty!Msg);
    assert(aa1.addressRef.get.empty!Reply);

    aa1.process(Clock.currTime);
    aa1.process(Clock.currTime);

    assert(aa1.addressRef.get.empty!DelayedMsg);
    assert(aa1.addressRef.get.empty!Msg);
    assert(aa1.addressRef.get.empty!Reply);

    assert(sendOk);
    assert(!shouldNeverHappen);

    sendExit(aa1.address, ExitReason.userShutdown);
    int guard;
    while (aa1.isAlive() && guard++ < 100)
        aa1.process(Clock.currTime);
    assert(!aa1.isAlive());
}

unittest {
    import my.actor.channel;

    class DelayActor {
        bool* delayOk;
        bool* delayShouldNeverHappen;

        this(bool* delayOk, bool* delayShouldNeverHappen) @safe {
            this.delayOk = delayOk;
            this.delayShouldNeverHappen = delayShouldNeverHappen;
        }

        void actor(const string s) @safe {
            *delayOk = true;
        }

        void actor(int s) @safe {
            *delayShouldNeverHappen = true;
        }
    }

    bool delayOk;
    bool delayShouldNeverHappen;
    auto aa1 = ActorShell(makeAddress);
    auto actor = new DelayActor(&delayOk, &delayShouldNeverHappen);
    implActor(actor, &aa1);
    dynDelayedSend(aa1.address, Clock.currTime - 1.dur!"seconds", "actor", "foo");
    dynDelayedSend(aa1.address, Clock.currTime + 1.dur!"hours", "actor", 42);

    assert(!aa1.addressRef.get.empty!DelayedMsg);
    assert(aa1.addressRef.get.empty!Msg);
    assert(aa1.addressRef.get.empty!Reply);

    aa1.process(Clock.currTime);

    assert(!aa1.addressRef.get.empty!DelayedMsg);
    assert(aa1.addressRef.get.empty!Msg);
    assert(aa1.addressRef.get.empty!Reply);

    aa1.process(Clock.currTime);
    aa1.process(Clock.currTime);

    assert(aa1.addressRef.get.empty!DelayedMsg);
    assert(aa1.addressRef.get.empty!Msg);
    assert(aa1.addressRef.get.empty!Reply);

    assert(delayOk);
    assert(!delayShouldNeverHappen);

    sendExit(aa1.address, ExitReason.userShutdown);
    int guard;
    while (aa1.isAlive() && guard++ < 100)
        aa1.process(Clock.currTime);
    assert(!aa1.isAlive());
}

@("shall process a request->then chain xyz")
@system unittest {
    import my.actor.channel;

    // checking capture is correctly setup/teardown by using captured rc.
    auto rcReq = refCounted(42);

    class ReqActor {
        bool* calledOk;
        RefCounted!int rc;

        this(bool* calledOk, RefCounted!int rc) @trusted {
            this.calledOk = calledOk;
            this.rc = rc;
        }

        string actor(const string s, const string b) @trusted {
            assert(2 == rc.refCount);
            if (s == "apa")
                *calledOk = true;
            return "foo";
        }
    }

    bool calledOk;
    auto aa1 = ActorShell(makeAddress);
    auto actor = new ReqActor(&calledOk, rcReq);
    implActor(actor, &aa1);

    auto rcReply = refCounted(42);
    bool calledReply;
    static void reply(ref Tuple!(bool*, RefCounted!int) ctx, const string s) {
        *ctx[0] = s == "foo";
        assert(2 == ctx[1].refCount);
    }

    assert(2 == rcReq.refCount);
    assert(1 == rcReply.refCount);

    auto chan = Channel!ReqActor(aa1.address, &aa1, infTimeout);
    chan.actor("apa", "foo").capture(&calledReply, rcReply).then(&reply);
    assert(2 == rcReply.refCount);

    assert(!aa1.addr.get.empty!Msg);
    assert(aa1.addr.get.empty!Reply);

    foreach (_; 0 .. 10)
        aa1.process(Clock.currTime);
    assert(aa1.addr.get.empty!Msg);
    assert(aa1.addr.get.empty!Reply);

    assert(2 == rcReq.refCount);
    assert(1 == rcReply.refCount, "after the message is consumed the refcount should go back");

    assert(calledOk);
    assert(calledReply);

    sendExit(aa1.address, ExitReason.userShutdown);
    int guard;
    while (aa1.isAlive() && guard++ < 100)
        aa1.process(Clock.currTime);
    assert(!aa1.isAlive());
}

@("shall process a request->then chain using promises")
unittest {
    import my.actor.channel;

    static struct A {
        string v;
    }

    static struct B {
        string v;
    }

    class PromiseActor {
        int* calledOk;
        Promise!string fn1p;
        Promise!string fn2p;

        this(int* calledOk, Promise!string fn1p, Promise!string fn2p) @safe {
            this.calledOk = calledOk;
            this.fn1p = fn1p;
            this.fn2p = fn2p;
        }

        RequestResult!string actor(A a) @trusted {
            if (a.v == "apa")
                (*calledOk)++;
            return typeof(return)(fn1p);
        }

        Promise!string actor(B a) {
            (*calledOk)++;
            return fn2p;
        }
    }

    int calledOk;
    auto fn1p = makePromise!string;
    auto fn2p = makePromise!string;

    int calledReply;
    static void reply(ref Tuple!(int*) ctx, const string s) {
        if (s == "foo")
            *ctx[0] += 1;
    }

    auto aa1 = ActorShell(makeAddress);
    auto actor = new PromiseActor(&calledOk, fn1p, fn2p);
    implActor(actor, &aa1);

    auto chan = Channel!PromiseActor(aa1.address, &aa1, infTimeout);
    chan.actor(A("apa")).capture(&calledReply).then(&reply);
    chan.actor(B("apa")).capture(&calledReply).then(&reply);

    // process first request, which return a promise so calledReply should not be called
    aa1.process(Clock.currTime);
    assert(calledOk == 1);
    assert(calledReply == 0);

    // by delivering an answer it is added to the actors mailbox
    fn1p.deliver("foo");

    // but it shouldn't trigger until the actor processes
    assert(calledReply == 0);

    // read the reply delivered by the promise fn1p
    aa1.process(Clock.currTime);
    assert(calledOk == 2);
    assert(calledReply == 1);

    // by delivering the second answer to the actor the reply handler should again be called
    fn2p.deliver("foo");

    foreach (_; 0 .. 3)
        aa1.process(Clock.currTime);
    assert(calledReply == 2);

    sendExit(aa1.address, ExitReason.userShutdown);
    int guard;
    while (aa1.isAlive() && guard++ < 100)
        aa1.process(Clock.currTime);
    assert(!aa1.isAlive());
}

/// The timeout triggered.
class ScopedActorException : Exception {
    this(ScopedActorError err, string file = __FILE__, int line = __LINE__) @safe pure nothrow {
        super(null, file, line);
        error = err;
    }

    ScopedActorError error;
}

enum ScopedActorError : ubyte {
    none,
    // actor address is down
    down,
    // request timeout
    timeout,
    // the address where unable to process the received message
    unknownMsg,
    // some type of fatal error occurred.
    fatal,
}

/** Intended to be used in a local scope by a user.
 *
 * `ScopedActor` is not thread safe.
 */
struct ScopedActor {
    private {
        ActorShell actor;
        ScopedActorError errSt;

        /// Non-matching payloads retained for later receive calls (design
        /// §3.B); survives across calls, entries cleared when dispatched.
        Variant[] stash;
    }

    this(StrongAddress addr, string name) @safe {
        actor = ActorShell(addr);
        actor.name = name;
    }

    ~this() @safe {
        if (actor.addr.empty)
            return;

        () @trusted {
            actor.downHandler = null;
            actor.defaultHandler = toDelegate(&.defaultHandler);
            actor.errorHandler = toDelegate(&defaultErrorHandler);
        }();

        actor.shutdown;
        while (actor.isAlive) {
            actor.process(Clock.currTime);
        }
    }

    @disable this(this);

    private void reset() @safe {
        errSt = ScopedActorError.none;
    }

    auto dynRequest(TAddress, Args...)(scope TAddress requestTo, SysTime timeout,
            string method, auto ref Args args) @safe if (isAddress!TAddress) {
        reset;
        alias UArgs = staticMap!(Unqual, Args);
        auto rs = .request(() @trusted { return &actor; }(),
                underlyingWeakAddress(requestTo), timeout);
        auto msg = () @trusted {
            return Msg(methodSignature!UArgs(method),
                    MsgType(MsgRequest(rs.self.addr.weakRef, rs.replyId,
                        Variant(Tuple!UArgs(args)))));
        }();
        return SRequestSendThen(RequestSendThen(rs, msg), &this);
    }

    /// The address senders can target (design §3.B).
    WeakAddress address() @safe nothrow scope {
        return actor.addr.weakRef;
    }

    /** Block until a message matching one of `handlers` arrives (design
     * §3.B). A handler is a function or delegate `void f(P v)`; the first
     * handler whose parameter type matches the message payload (mylib's
     * exact `Unqual` rule, including the `makePayload` tuple box) is
     * invoked.
     *
     * Non-matching messages are retained in the actor's stash and
     * reconsidered, oldest first, by later receive calls. Only one thread
     * may wait on an actor at a time — a receive inside another wait's
     * handler is not supported. If the matching handler throws, its
     * exception is rethrown at this wait point. */
    void receive(Handlers...)(Handlers handlers) @safe {
        () @trusted { receiveLoop(Duration.max, handlers); }();
    }

    /** Like `receive`, but returns `false` when `timeout` expires without
     * a match (std-parity). */
    bool receiveTimeout(Handlers...)(Duration timeout, Handlers handlers) @safe {
        return () @trusted { return receiveLoop(timeout, handlers); }();
    }

    /// The wait loop shared by `receive` and `receiveTimeout` (design §3.B):
    /// installs the dispatcher as the actor's default handler (restored on
    /// exit), then scans the stash and pumps the mailbox until a handler
    /// matches or the deadline expires. A throwing handler aborts the wait
    /// and its exception is rethrown here.
    private bool receiveLoop(Handlers...)(Duration timeout, Handlers handlers) @trusted {
        auto hs = tuple(handlers);
        auto ctx = new ReceiveDispatcher!(Handlers)(&this, &hs);
        auto prev = actor.defaultHandler_;
        actor.defaultHandler_ = &ctx.dispatch;
        scope (exit)
            actor.defaultHandler_ = prev;

        Duration remaining = timeout;
        SysTime prevTime = Clock.currTime;
        uint backoff = 0;
        while (true) {
            // retained messages first (stale first)
            if (ctx.scanStash) {
                if (ctx.handlerError !is null)
                    throw ctx.handlerError;
                return true;
            }

            // pump the mailbox; the keep-alive mirrors SRequestSendThen.then
            actor.process(Clock.currTime);
            actor.state_ = ActorState.waiting;

            if (ctx.matched) {
                if (ctx.handlerError !is null)
                    throw ctx.handlerError;
                return true;
            }

            // Duration.max never expires: the subtraction stays positive.
            remaining -= (Clock.currTime - prevTime);
            prevTime = Clock.currTime;
            if (remaining <= Duration.zero)
                return false;

            Thread.sleep(backoff.dur!"usecs");
            backoff = min(backoff + 100, 20000);
        }
    }

    /// Context for one blocking receive call (design §3.B): holds the
    /// handlers tuple and per-call state, and manipulates the actor's
    /// persistent `stash` so retained messages survive across calls.
    private static class ReceiveDispatcher(Hs...) {
        ScopedActor* self_;
        Tuple!Hs* handlers;
        bool matched;
        Exception handlerError;

        this(ScopedActor* self, Tuple!Hs* handlers) @safe nothrow @nogc {
            this.self_ = self;
            this.handlers = handlers;
        }

        /// Match `handler` against `msg`: parameter `P` accepts a payload
        /// stored as `Unqual!P`, or (when `P` is not itself a tuple) the
        /// `makePayload` box `Tuple!(Unqual!P)`. A throwing handler stores
        /// its exception in `handlerError` instead of propagating it.
        private static bool tryHandler(H)(H handler, ref Variant msg, ref Exception handlerError) @trusted nothrow {
            alias P = Parameters!H[0];
            P v;
            bool found;
            try {
                if (auto p = msg.peek!(Unqual!P)) {
                    v = cast(P)*p;
                    found = true;
                } else {
                    static if (!is(Unqual!P : Tuple!U, U)) {
                        if (auto t = msg.peek!(Tuple!(Unqual!P))) {
                            v = cast(P)(*t).tupleof[0];
                            found = true;
                        }
                    }
                }
            } catch (Exception e) {
                return false;
            }
            if (!found)
                return false;
            try {
                handler(v);
            } catch (Exception e) {
                handlerError = e;
            }
            return true;
        }

        void dispatch(scope ref ActorShell self, ref Variant msg) @safe nothrow {
            if (!matched) {
                static foreach (i, H; Hs) {
                    if (!matched && tryHandler!H((*handlers)[i], msg, handlerError))
                        matched = true;
                }
            }
            if (!matched) {
                try {
                    () @trusted { self_.stash ~= Variant(msg); }();
                } catch (Exception e) {
                }
            }
        }

        /// Scan the stash oldest first; dispatch the first handler match
        /// and clear its entry.
        bool scanStash() @safe nothrow {
            for (size_t i = 0; i < self_.stash.length; ++i) {
                bool hit;
                static foreach (j, H; Hs) {
                    if (!hit && tryHandler!H((*handlers)[j], self_.stash[i], handlerError)) {
                        try {
                            () @trusted {
                                self_.stash = self_.stash[0 .. i] ~ self_.stash[i + 1 .. $];
                            }();
                        } catch (Exception e) {
                        }
                        hit = true;
                    }
                }
                if (hit) {
                    matched = true;
                    return true;
                }
            }
            return false;
        }
    }

    private static struct SRequestSendThen {
        RequestSendThen rs;
        ScopedActor* self;
        uint backoff;

        /// Copy constructor
        this(ref return typeof(this) rhs) {
            rs = rhs.rs;
            self = rhs.self;
            backoff = rhs.backoff;
        }

        ~this() scope {
        }

        @disable this(this);

        void dynIntervalSleep() scope @trusted {
            // +100 usecs is a magic number that "feels good": current OS and
            // message-passing implementation aren't much faster than 100us,
            // and a bit slow behavior is OK for a scoped actor (not expected
            // in time-critical sections).
            Thread.sleep(backoff.dur!"usecs");
            backoff = min(backoff + 100, 20000);
        }

        private static struct ValueCapture {
            ScopedActor* self;

            void downHandler(scope ref ActorShell, scope DownMsg) @safe nothrow {
                try {
                    self.errSt = ScopedActorError.down;
                } catch (Exception e) {
                }
            }

            void errorHandler(scope ref ActorShell, scope ErrorMsg msg) @safe nothrow {
                try {
                    if (msg.reason == SystemError.requestTimeout)
                        self.errSt = ScopedActorError.timeout;
                    else
                        self.errSt = ScopedActorError.fatal;
                } catch (Exception e) {
                }
            }

            void unknownMsgHandler(scope ref ActorShell a, ref Variant msg) @safe nothrow {
                logAndDropHandler(a, msg);
                try {
                    self.errSt = ScopedActorError.unknownMsg;
                } catch (Exception e) {
                }
            }
        }

        void then(T)(T handler, ErrorHandler onError = null) scope @safe {
            scope (exit)
                demonitor(rs.rs.self, rs.rs.requestTo);
            monitor(rs.rs.self, rs.rs.requestTo);

            auto callback = new ValueCapture(() @trusted { return self; }());
            self.actor.downHandler = &callback.downHandler;
            self.actor.defaultHandler = &callback.unknownMsgHandler;
            self.actor.errorHandler = &callback.errorHandler;

            () @trusted { .thenUnsafe!(T, void)(rs, handler, null, onError); }();

            scope (exit)
                () @trusted {
                self.actor.downHandler = null;
                self.actor.defaultHandler = toDelegate(&.defaultHandler);
                self.actor.errorHandler = toDelegate(&defaultErrorHandler);
            }();

            auto requestTo = rs.rs.requestTo.lock;
            if (!requestTo)
                throw new ScopedActorException(ScopedActorError.down);

            // TODO: this loop is stupid... should use a conditional variable
            // instead but that requires changing the mailbox. later
            do {
                rs.rs.self.process(Clock.currTime);
                // force the actor to be alive even though there are no behaviors.
                rs.rs.self.state_ = ActorState.waiting;

                if (self.errSt == ScopedActorError.none) {
                    dynIntervalSleep;
                } else {
                    throw new ScopedActorException(self.errSt);
                }

            }
            while (self.actor.waitingForReply);
        }
    }
}

ScopedActor scopedActor(string file = __FILE__, uint line = __LINE__)() @safe {
    import std.format : format;

    return ScopedActor(makeAddress, format!"ScopedActor.%s:%s"(file, line));
}

@(
        "scoped actor shall throw an exception if the actor that is sent a request terminates or is closed")
unittest {
    import my.actor.system;

    static class ScopedTarget {
        ActorRef self_;

        void onSpawn(ActorRef self) @safe {
            self_ = self;
        }

        int slow(int x) @safe {
            Thread.sleep(50.dur!"msecs");
            return 42;
        }

        int bye(string x) @safe {
            sendExit(self_.address, ExitReason.kill);
            return 42;
        }
    }

    auto sys = makeSystem;

    auto a0 = sys.spawn!ScopedTarget;

    {
        auto self = scopedActor;
        bool excThrown;
        auto stopAt = Clock.currTime + 3.dur!"seconds";
        while (!excThrown && Clock.currTime < stopAt) {
            try {
                self.dynRequest(a0, delay(1.dur!"nsecs"), "slow", 42).then((int x) {
                });
            } catch (ScopedActorException e) {
                excThrown = e.error == ScopedActorError.timeout;
            } catch (Exception e) {
                logger.info(e.msg);
            }
        }
        assert(excThrown, "timeout did not trigger as expected");
    }

    {
        auto self = scopedActor;
        bool excThrown;
        auto stopAt = Clock.currTime + 3.dur!"seconds";
        while (!excThrown && Clock.currTime < stopAt) {
            try {
                self.dynRequest(a0, delay(1.dur!"seconds"), "bye", "hello").then((int x) {
                });
            } catch (ScopedActorException e) {
                excThrown = e.error == ScopedActorError.down;
            } catch (Exception e) {
                logger.info(e.msg);
            }
        }
        assert(excThrown, "detecting terminated actor did not trigger as expected");
    }
}

@("class actors can pass actor addresses as message arguments")
unittest {
    import my.actor.channel;

    class Pinger {
        ActorRef self_;
        int helloBacks;

        void onSpawn(ActorRef self) @safe {
            self_ = self;
        }

        void introduce(WeakAddress other) @safe {
            dynSend(other, "remember", self_.address);
        }

        void helloBack() @safe {
            helloBacks++;
        }
    }

    class Echoer {
        void remember(WeakAddress back) @safe {
            dynSend(back, "helloBack");
        }
    }

    auto aa1 = ActorShell(makeAddress);
    auto pinger = new Pinger;
    implActor(pinger, &aa1);
    auto aa2 = ActorShell(makeAddress);
    auto echoer = new Echoer;
    implActor(echoer, &aa2);

    // the first process runs onSpawn and stores the self handle.
    aa1.process(Clock.currTime);
    aa2.process(Clock.currTime);

    dynSend(aa1.address, "introduce", aa2.address);
    foreach (_; 0 .. 8) {
        aa1.process(Clock.currTime);
        aa2.process(Clock.currTime);
    }

    assert(pinger.helloBacks == 1, "the reply hop via the passed address landed");

    sendExit(aa1.address, ExitReason.userShutdown);
    sendExit(aa2.address, ExitReason.userShutdown);
    int guard;
    while ((aa1.isAlive() || aa2.isAlive()) && guard++ < 100) {
        aa1.process(Clock.currTime);
        aa2.process(Clock.currTime);
    }
    assert(!aa1.isAlive());
    assert(!aa2.isAlive());
}

@("plain-class actors are shut down via sendExit, not handles")
unittest {
    static assert(!__traits(hasMember, ActorRef, "shutdown"),
            "ActorRef has no shutdown member; use sendExit");

    class Ping {
        void ping() @safe {
        }
    }

    auto kernel = ActorShell(makeAddress);
    auto instance = new Ping;
    implActor(instance, &kernel);
    kernel.process(Clock.currTime);
    assert(kernel.isAlive());

    sendExit(kernel.address, ExitReason.userShutdown);
    int guard;
    while (kernel.isAlive() && guard++ < 100)
        kernel.process(Clock.currTime);
    assert(!kernel.isAlive(), "the system exit message shuts the actor down");
}

@("launch hook runs once before the first message")
unittest {
    auto kernel = ActorShell(makeAddress);
    string log;
    kernel.launchHandler(() @safe { log ~= "launch;"; });
    kernel.process(Clock.currTime);
    kernel.process(Clock.currTime);
    assert(log == "launch;", "launch runs exactly once, on the first process");
}

@("launch hook failures follow the normal actor error path")
unittest {
    auto kernel = ActorShell(makeAddress);
    int handled;
    kernel.exceptionHandler((scope ref ActorShell, scope Exception e) @safe nothrow{
        handled++;
    });
    kernel.launchHandler(() @safe { throw new Exception("boom"); });
    kernel.process(Clock.currTime);
    assert(handled == 1, "the exception routed through exceptionHandler_");
    kernel.process(Clock.currTime);
    assert(handled == 1, "launch is not retried");
}

@("repeating tick: first fire at +interval, then re-arms on the fire time")
unittest {
    static class TickCounter {
        int ticks;

        void tick() @safe {
            ticks++;
        }
    }

    auto kernel = ActorShell(makeAddress);
    auto a = new TickCounter;
    implActor(a, &kernel);
    auto selfRef = ActorRef(&kernel);

    const I = 10.dur!"msecs";
    auto t0 = Clock.currTime;
    selfRef.scheduleRepeating(I, "tick");

    kernel.process(t0);
    kernel.process(t0 + I / 2);
    kernel.process(t0 + I - 1.dur!"msecs");
    assert(a.ticks == 0, "no fire before +interval (first fire is never immediate)");

    kernel.process(t0 + I + 1.dur!"msecs");
    assert(a.ticks == 1, "exactly one fire once +interval has passed");

    // the re-arm is anchored on the fire time, not the schedule time.
    kernel.process(t0 + 2 * I);
    assert(a.ticks == 1, "no second fire before fire-time + interval");
    kernel.process(t0 + 2 * I + 2.dur!"msecs");
    assert(a.ticks == 2, "second fire at fire-time + interval");

    sendExit(kernel.address, ExitReason.kill);
    int guard;
    while (kernel.isAlive() && guard++ < 100)
        kernel.process(Clock.currTime);
    assert(!kernel.isAlive());
}

@("repeating tick: a throwing handler stops the repeat and fires onException")
unittest {
    static class ThrowingTick {
        int fires;
        int exceptions;

        void tick() {
            if (fires++ == 0)
                throw new Exception("boom");
        }

        void onException(Exception e) @safe {
            exceptions++;
        }
    }

    auto kernel = ActorShell(makeAddress);
    auto a = new ThrowingTick;
    implActor(a, &kernel);
    auto selfRef = ActorRef(&kernel);

    const I = 10.dur!"msecs";
    auto t0 = Clock.currTime;
    selfRef.scheduleRepeating(I, "tick");

    kernel.process(t0);
    kernel.process(t0 + I + 1.dur!"msecs");
    assert(a.fires == 1, "the first tick ran and threw");
    assert(a.exceptions == 1, "the throw fired the onException hook");
    assert(kernel.isAlive(), "a log-only onException does not shut the actor down");

    // the repeat is stopped: no re-arm after a throwing handler.
    foreach (const k; 1 .. 5) {
        kernel.process(t0 + (k + 1) * I + 1.dur!"msecs");
    }
    assert(a.fires == 1, "no further tick fires after the throw");
    assert(a.exceptions == 1, "no further onException");

    sendExit(kernel.address, ExitReason.kill);
    int guard;
    while (kernel.isAlive() && guard++ < 100)
        kernel.process(Clock.currTime);
    assert(!kernel.isAlive());
}

@("repeating tick: cancelTick from inside the handler stops the repeat")
unittest {
    static class SelfCancel {
        int fires;
        private ActorRef self_;

        void onSpawn(ActorRef self) @safe {
            self_ = self;
        }

        void tick() {
            fires++;
            self_.cancelTick();
        }
    }

    auto kernel = ActorShell(makeAddress);
    auto a = new SelfCancel;
    implActor(a, &kernel);
    auto selfRef = ActorRef(&kernel);

    const I = 10.dur!"msecs";
    auto t0 = Clock.currTime;
    selfRef.scheduleRepeating(I, "tick");

    kernel.process(t0); // runs onSpawn, stages the entry
    assert(a.fires == 0);

    kernel.process(t0 + I + 1.dur!"msecs");
    assert(a.fires == 1, "the first tick ran and cancelled the repeat");

    foreach (const k; 2 .. 5) {
        kernel.process(t0 + k * I + 1.dur!"msecs");
    }
    assert(a.fires == 1, "no fire after the in-handler cancelTick");

    sendExit(kernel.address, ExitReason.kill);
    int guard;
    while (kernel.isAlive() && guard++ < 100)
        kernel.process(Clock.currTime);
    assert(!kernel.isAlive());
}

@("repeating tick: a pending entry is dropped at shutdown, never firing")
unittest {
    static class TickCounter {
        int ticks;

        void tick() @safe {
            ticks++;
        }
    }

    auto kernel = ActorShell(makeAddress);
    auto a = new TickCounter;
    implActor(a, &kernel);
    auto selfRef = ActorRef(&kernel);

    const I = 10.dur!"msecs";
    auto t0 = Clock.currTime;
    selfRef.scheduleRepeating(I, "tick");

    kernel.process(t0);
    kernel.process(t0 + I + 1.dur!"msecs");
    assert(a.ticks == 1, "one fire before the exit");

    sendExit(kernel.address, ExitReason.kill);
    int guard;
    while (kernel.isAlive() && guard++ < 100)
        kernel.process(Clock.currTime);
    assert(!kernel.isAlive());
    // The shell's delayed tree is destroyed in cleanupDelayed and is not
    // safe to inspect after shutdown; the observable pin is the fire count.
    assert(a.ticks == 1, "no tick fire after the exit message");

    // a later tick at a much later time cannot resurrect the entry.
    kernel.process(Clock.currTime + 100.dur!"msecs");
    assert(a.ticks == 1);
}

@system @("repeating tick: fires independently of mailbox activity (maxThroughput=1)")
unittest {
    import std.conv : to;
    import std.parallelism : TaskPool;
    import my.actor.system : SystemConfig;
    import my.optional : some;

    static class TickingActor {
        private RefCounted!int ticks;
        private ActorRef self_;

        this(RefCounted!int counter) {
            ticks = counter;
        }

        void onSpawn(ActorRef self) @safe {
            self_ = self;
            self_.scheduleRepeating(20.dur!"msecs", "tick");
        }

        void tick() {
            ticks.get++;
        }
    }

    // maxThroughput=1: a scheduled run consumes at most one message, so a
    // tick that had to wait behind the mailbox for its own delivery would
    // starve here. Direct dispatch must keep the cadence.
    auto conf = SystemConfig.init;
    conf.scheduler.maxThroughput = some(1uL);
    auto sys = System(conf, new TaskPool(1), true);

    auto counter = refCounted(0);
    auto addr = sys.spawn!TickingActor(counter);

    // ~25 ticks in 500msecs at 20msecs; allow a wide margin for scheduling
    // jitter — the point is that the tick runs AT ALL under throughput=1.
    const failAfter = Clock.currTime + 3.dur!"seconds";
    while (counter.get < 3 && Clock.currTime < failAfter) {
        Thread.sleep(10.dur!"msecs");
    }
    assert(counter.get >= 3,
            "repeating tick should fire under maxThroughput=1 but got " ~ to!string(counter.get));
    sys.shutdown;
}

@("ScopedActor.receive: handler dispatch + address-targeted send") unittest {
    import my.actor.system;
    import my.actor.channel;

    static class Sender {
        void go(WeakAddress to) {
            dynSend(to, "hello", "world");
        }
    }

    auto sup = scopedActor;
    auto sys = makeSystem;
    auto s = sys.spawn!Sender();
    dynSend(s, "go", sup.address());
    string got;
    assert(sup.receiveTimeout(5.dur!"seconds", (string v) { got = v; }));
    assert(got == "world");
    sys.shutdown();
}

@("ScopedActor.receiveTimeout: false on deadline") unittest {
    auto sup = scopedActor;
    assert(!sup.receiveTimeout(50.dur!"msecs", (string s) { assert(false); }));
}

@("ScopedActor.receive: stash retains non-matching messages for later calls") unittest {
    import my.actor.channel;

    auto sup = scopedActor;
    dynSend(sup.address(), "a", 42); // int payload — no handler in call 1
    dynSend(sup.address(), "b", "text"); // string payload
    string s1;
    assert(sup.receiveTimeout(5.dur!"seconds", (string s) { s1 = s; }));
    assert(s1 == "text");
    int i1 = -1;
    assert(sup.receiveTimeout(5.dur!"seconds", (int i) { i1 = i; }));
    assert(i1 == 42);
}

@("ScopedActor.receive: sequential reuse with dynRequest") unittest {
    import my.actor.system;

    static class Target {
        int sum(int a, int b) {
            return a + b;
        }
    }

    auto sup = scopedActor;
    auto sys = makeSystem;
    auto t = sys.spawn!Target();
    assert(!sup.receiveTimeout(50.dur!"msecs", (string s) { assert(false); })); // wait times out
    int got = -1;
    sup.dynRequest(t, Clock.currTime + 5.dur!"seconds", "sum", 2, 3).then((int v) {
        got = v;
    });
    assert(got == 5, "dynRequest must still work after receive calls");
    sys.shutdown();
}

@("ScopedActor.receive: handler exceptions rethrow at the wait point") unittest {
    import my.actor.channel;

    auto sup = scopedActor;
    dynSend(sup.address(), "x", "boom");
    bool threw;
    try {
        sup.receiveTimeout(5.dur!"seconds", (string s) {
            throw new Exception("handler boom");
        });
    } catch (Exception e) {
        threw = e.msg == "handler boom";
    }
    assert(threw);
}

@("ScopedActor.receive: infinite wait (no timeout) returns on match") unittest {
    import my.actor.channel;

    auto sup = scopedActor;
    dynSend(sup.address(), "m", "now");
    string got;
    sup.receive((string s) { got = s; });
    assert(got == "now");
}

@("ScopedActor.receive: first matching handler wins across multiple handlers") unittest {
    import my.actor.channel;

    auto sup = scopedActor;
    // dynSend boxes the payload as Variant(Tuple!(string)): the (string)
    // handler matches via the box-unwrap path, the (Tuple!(string)) handler
    // matches directly — the first one in the list must win.
    dynSend(sup.address(), "m", "x");
    string first;
    bool secondHit;
    sup.receiveTimeout(5.dur!"seconds", (string s) { first = s; }, (Tuple!(string) t) {
        secondHit = true;
    });
    assert(first == "x");
    assert(!secondHit, "the first matching handler must win");
}
