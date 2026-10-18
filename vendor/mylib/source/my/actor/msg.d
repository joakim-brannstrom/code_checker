/**
Copyright: Copyright (c) Joakim Brännström. All rights reserved.
License: $(LINK2 http://www.boost.org/LICENSE_1_0.txt, Boost Software License 1.0)
Author: Joakim Brännström (joakim.brannstrom@gmx.com)
*/
module my.actor.msg;

import logger = std.logger;
import std.traits : isFunction, isFunctionPointer;
import std.typecons : Tuple, tuple;

public import std.datetime : SysTime, Duration, dur;

import my.actor.mailbox;
import my.actor.common : ExitReason, SystemError;
import my.actor.actor : ActorShell, makeReply2, ErrorHandler;
import my.actor.system_msg;

SysTime infTimeout() @safe pure nothrow {
    return SysTime.max;
}

SysTime timeout(Duration d) @safe nothrow {
    import std.datetime : Clock;

    return Clock.currTime + d;
}

/// Alias of `timeout` so delayed-send call sites read as `delay(...)`.
alias delay = timeout;

enum isActor(T) = is(T == ActorShell*);
enum isAddress(T) = is(T == WeakAddress) || is(T == StrongAddress) || isTypedAddress!T;

/// Convert any supported address form to a `StrongAddress`.
package StrongAddress underlyingAddress(T)(scope T address) @safe
        if (is(T == ActorShell*) || is(T == StrongAddress)
            || is(T == WeakAddress) || isTypedAddress!T) {
    static StrongAddress toStrong(scope WeakAddress wa) @safe {
        if (auto a = wa.lock)
            return a;
        return StrongAddress.init;
    }

    static if (is(T == ActorShell*))
        return address.addressRef;
    else static if (is(T == WeakAddress))
        return toStrong(address);
    else static if (isTypedAddress!T)
        return address.addr;
    else
        return address;
}

package WeakAddress underlyingWeakAddress(T)(scope T x) @safe
        if (is(T == ActorShell*) || is(T == StrongAddress)
            || is(T == WeakAddress) || isTypedAddress!T) {
    static if (is(T == ActorShell*))
        return x.address;
    else static if (is(T == StrongAddress))
        return x.weakRef;
    else static if (isTypedAddress!T)
        return x.weakRef;
    else
        return x;
}

/** Link the lifetime of `self` to the actor using `sendTo`.
 *
 * An `ExitMsg` is sent to `self` if `sendTo` is terminated and vice versa.
 *
 * `ExitMsg` triggers `exitHandler`.
 */
void linkTo(AddressT0, AddressT1)(AddressT0 self, AddressT1 sendTo) @safe
        if ((isActor!AddressT0 || isAddress!AddressT0) && (isActor!AddressT1
            || isAddress!AddressT1)) {
    import my.actor.mailbox : LinkRequest;

    auto self_ = underlyingAddress(self);
    auto addr = underlyingAddress(sendTo);

    if (self_.empty || addr.empty)
        return;

    sendSystemMsg(self_, LinkRequest(addr.weakRef));
    sendSystemMsg(addr, LinkRequest(self_.weakRef));
}

/// Remove the link between `self` and the actor using `sendTo`.
void unlinkTo(AddressT0, AddressT1)(AddressT0 self, AddressT1 sendTo) @safe
        if ((isActor!AddressT0 || isAddress!AddressT0) && (isActor!AddressT1
            || isAddress!AddressT1)) {
    import my.actor.mailbox : UnlinkRequest;

    auto self_ = underlyingAddress(self);
    auto addr = underlyingAddress(sendTo);

    // do NOT check if the addresses exist because it doesn't matter. Just
    // remove the link.

    sendSystemMsg(self_, UnlinkRequest(addr.weakRef));
    sendSystemMsg(addr, UnlinkRequest(self_.weakRef));
}

/** ActorShell `self` will receive a `DownMsg` when `sendTo` shutdown.
 *
 * `DownMsg` triggers `downHandler`.
 */
void monitor(AddressT0, AddressT1)(AddressT0 self, AddressT1 sendTo) @safe
        if ((isActor!AddressT0 || isAddress!AddressT0) && (isActor!AddressT1
            || isAddress!AddressT1)) {
    import my.actor.system_msg : MonitorRequest;

    if (auto self_ = underlyingAddress(self))
        sendSystemMsg(sendTo, MonitorRequest(self_.weakRef));
}

/// Remove `self` as a monitor of the actor using `sendTo`.
void demonitor(AddressT0, AddressT1)(scope AddressT0 self, scope AddressT1 sendTo) @safe
        if ((isActor!AddressT0 || isAddress!AddressT0) && (isActor!AddressT1
            || isAddress!AddressT1)) {
    import my.actor.system_msg : MonitorRequest;

    if (auto self_ = underlyingAddress(self))
        sendSystemMsg(sendTo, DemonitorRequest(self_.weakRef));
}

// Only send the message if the system message queue is empty.
package void sendSystemMsgIfEmpty(AddressT, T)(AddressT sendTo, T msg) @safe
        if (isAddress!AddressT)
in (!sendTo.empty, "cannot send to an empty address") {
    auto tmp = underlyingAddress(sendTo);
    auto addr = tmp.get;
    if (addr && addr.empty!SystemMsg)
        addr.put(SystemMsg(msg));
}

package void sendSystemMsg(AddressT, T)(scope AddressT sendTo, scope T msg) @safe
        if (isAddress!AddressT) {
    auto tmp = underlyingAddress(sendTo);
    auto addr = tmp.get;
    if (addr)
        addr.put(SystemMsg(msg));
}

void sendExit(AddressT)(AddressT sendTo, const ExitReason reason) @safe
        if (isAddress!AddressT) {
    import my.actor.system_msg : SystemExitMsg;

    sendSystemMsg(sendTo, SystemExitMsg(reason));
}

package struct RequestSend {
    ActorShell* self;
    WeakAddress requestTo;
    SysTime timeout;
    ulong replyId;

    /// Copy constructor
    this(ref return scope typeof(this) rhs) @safe pure nothrow @nogc {
        self = rhs.self;
        requestTo = rhs.requestTo;
        timeout = rhs.timeout;
        replyId = rhs.replyId;
    }
}

package struct RequestSendThen {
    RequestSend rs;
    Msg msg;

    /// Copy constructor
    this(ref return typeof(this) rhs) {
        rs = rhs.rs;
        msg = rhs.msg;
    }

    ~this() scope {
    }
}

RequestSend request(ActorT)(ActorT self, WeakAddress requestTo, SysTime timeout)
        if (is(ActorT == ActorShell*)) {
    return RequestSend(self, requestTo, timeout, self.nextReplyId);
}

private struct ThenContext(CtxT, Captures...) {
    RequestSendThen r;
    CtxT* ctx;

    void then(T)(T handler, ErrorHandler onError = null)
            if (isFunction!T || isFunctionPointer!T) {
        thenUnsafe!(T, CtxT)(r, handler, cast(void*) ctx, onError);
        ctx = null;
    }
}

// allows delegates but the context for them may be corrupted by the GC if they
// are used in another thread thus use of `thenUnsafe` must ensure it is not
// escaped.
package void thenUnsafe(T, CtxT = void)(scope RequestSendThen r, T handler,
        void* ctx, ErrorHandler onError = null) @trusted {
    auto requestTo = r.rs.requestTo.lock.get;
    if (!requestTo) {
        if (onError)
            onError(*r.rs.self, ErrorMsg(r.rs.requestTo, SystemError.requestReceiverDown));
        return;
    }

    // TODO: compiler bug? how can SysTime be inferred as scoped?
    SysTime timeout = () @trusted { return r.rs.timeout; }();

    // first register a handler for the message.
    // this order ensures that there is always a handler that can receive the message.

    () @safe {
        auto reply = makeReply2!(T, CtxT)(handler);
        reply.ctx = ctx;
        string desc;
        debug desc = T.stringof;
        r.rs.self.register(desc, r.rs.replyId, timeout, reply, onError);
    }();

    requestTo.put(r.msg);
}

void then(T, CtxT = void)(scope RequestSendThen r, T handler, ErrorHandler onError = null) @trusted
        if (isFunction!T || isFunctionPointer!T) {
    thenUnsafe!(T, CtxT)(r, handler, null, onError);
}

alias Capture(T...) = Tuple!T;
enum isCapture(T) = is(T == Tuple!U, U);

auto capture(T...)(auto ref T args) if (!is(T[0] == RequestSendThen)) {
    static if (T.length == 1 && isCapture!(T[0])) {
        return args[0];
    } else {
        return Tuple!T(args);
    }
}

auto capture(Captures...)(RequestSendThen r, auto ref Captures captures) {
    static if (Captures.length == 1 && isCapture!(Captures[0])) {
        alias CtxT = Captures[0];
        auto ctx = new CtxT;
        *ctx = captures;
        return ThenContext!(CtxT, Captures)(r, ctx);
    } else {
        auto ctx = new Tuple!Captures(captures);
        return ThenContext!(Tuple!Captures, Captures)(r, ctx);
    }
}

@("a new context should copy the provided values")
unittest {
    class AClass {
        int v;
        this(int v) {
            this.v = v;
        }
    }

    class AClassWithInnerPtr {
        int* v;
        this(int v) {
            this.v = new int;
            *this.v = v;
        }
    }

    struct AStruct {
        int v;
    }

    { // common user pattern when there is uncertainty of what "capture()" does
        auto userValues = tuple!("aint", "aclass", "astruct", "ainner")(42,
                new AClass(42), AStruct(42), new AClassWithInnerPtr(42));
        auto userCtx = capture(userValues);

        assert(userCtx.aint == 42);
        assert(userCtx.aclass !is null);
        assert(userCtx.aclass.v == 42);
        assert(userCtx.astruct.v == 42);
        assert(userCtx.ainner !is null);
        assert(userCtx.ainner.v !is null);
        assert(*userCtx.ainner.v == 42);
    }
    { // how capture can be used
        auto userCtx = capture(42, new AClass(42), AStruct(42), new AClassWithInnerPtr(42));

        assert(userCtx[0] == 42);
        assert(userCtx[1].v == 42);
        assert(userCtx[2].v == 42);
        assert(userCtx[3]!is null);
        assert(userCtx[3].v !is null);
        assert(*userCtx[3].v == 42);
    }
}
