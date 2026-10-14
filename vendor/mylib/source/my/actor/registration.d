/**
Copyright: Copyright (c) Joakim Brännström. All rights reserved.
License: $(LINK2 http://www.boost.org/LICENSE_1_0.txt, Boost Software License 1.0)
Author: Joakim Brännström (joakim.brannstrom@gmx.com)
*/
module my.actor.registration;

import std.datetime : Clock;
import std.meta : staticMap;
import std.sumtype : match;
import std.traits : Parameters, ReturnType, Unqual;
import std.typecons : Tuple, tuple;
import std.variant : Variant;

import my.actor.actor : ActorShell, Closure2, MsgHandler, RequestHandler,
    defaultErrorHandler, defaultExitHandler, defaultExceptionHandler, Promise, RequestResult;
import my.actor.behavior : ActorRef, isHookName;
import my.actor.common : ExitReason, methodSignature;
import my.actor.mailbox : Msg, MsgOneShot, MsgRequest, MsgType, Reply, WeakAddress, makeAddress;
import my.actor.msg : sendExit, sendSystemMsg;
import my.actor.system_msg : DownMsg, ErrorMsg, ExitMsg;

/// Members declared by Object must never become message methods.
private template isFrameworkMember(alias m) {
    enum isFrameworkMember = __traits(isSame, __traits(parent, m), Object);
}

/// A message method: public, non-static instance method.
template isMessageMethod(alias m) {
    enum isMessageMethod = !isFrameworkMember!m && !__traits(isStaticFunction,
                m) && __traits(getProtection, m) == "public";
}

private template isObjMemberName(string name) {
    enum isObjMemberName = name == "toString" || name == "toHash" || name == "opCmp"
        || name == "opEquals" || name == "Monitor" || name == "factory"
        || name == "this" || name == "~this";
}

/// Framework-reserved names: never message methods.
private template isReservedName(string name) {
    enum isReservedName = isObjMemberName!name || isHookName!name;
}

/// Count message methods named `methodName` with parameter types `UArgs`.
int countMethods(T, string methodName, UArgs...)() {
    int n;
    static foreach (name; __traits(allMembers, T)) {
        static if (name == methodName && !isReservedName!name) {
            static foreach (m; __traits(getOverloads, T, name)) {
                {
                    static if (isMessageMethod!m) {
                        static if (is(staticMap!(Unqual, Parameters!m) == UArgs))
                            n++;
                    }
                }
            }
        }
    }
    return n;
}

/// Count message methods of `T` named `methodName` whose Unqual parameter
/// types match those of `refM` (implActor's overload-collision guard:
/// const- and ref-differing overloads share a name+params message identity,
/// so one of them would be silently dead in register()).
int countSameIdentity(T, string methodName, alias refM)() {
    int n;
    static foreach (name; __traits(allMembers, T)) {
        static if (name == methodName && !isReservedName!name) {
            static foreach (m; __traits(getOverloads, T, name)) {
                static if (isMessageMethod!m) {
                    static if (is(staticMap!(Unqual,
                            Parameters!m) == staticMap!(Unqual, Parameters!refM)))
                        n++;
                }
            }
        }
    }
    return n;
}

/// The message method named `methodName` with parameter types `UArgs`.
template messageMethod(T, string methodName, UArgs...) {
    static foreach (name; __traits(allMembers, T)) {
        static if (name == methodName && !isReservedName!name) {
            static foreach (m; __traits(getOverloads, T, name)) {
                static if (isMessageMethod!m && is(staticMap!(Unqual, Parameters!m) == UArgs))
                    alias messageMethod = m;
            }
        }
    }
}

unittest {
    class C {
        private int state_;

        void onSpawn() {
        }

        private void secret(int x) {
            state_ = x;
        }

        static void helper(int x) {
        }

        void add(int a, int b) {
            state_ = a + b;
        }

        void add(int a) {
            state_ = a;
        }

        int total() {
            return state_;
        }
    }

    // Hook, private and static members are never message methods.
    assert(countMethods!(C, "onSpawn")() == 0);
    assert(countMethods!(C, "secret")() == 0);
    assert(countMethods!(C, "helper")() == 0);

    // Real message methods count, disambiguated by parameter types.
    assert(countMethods!(C, "add", int, int)() == 1);
    assert(countMethods!(C, "add", int)() == 1);
    assert(countMethods!(C, "add", int, string)() == 0);
    assert(countMethods!(C, "total")() == 1);
    assert(countMethods!(C, "noSuchMethod")() == 0);

    alias M = messageMethod!(C, "add", int, int);
    static assert(Parameters!M.length == 2);
    static assert(isMessageMethod!M);

    alias M1 = messageMethod!(C, "add", int);
    static assert(Parameters!M1.length == 1);

    alias M0 = messageMethod!(C, "total");
    static assert(Parameters!M0.length == 0);
}

/// Keeps the actor instance alive while it is bound as the kernel context.
private struct InstanceBox(T) {
    T instance;
    this(T instance) {
        this.instance = instance;
    }
}

/// Context cleanup: unbind the instance when the actor shuts down.
private void cleanupInstance(T)(void* ctx) @trusted nothrow {
    (cast(InstanceBox!T*) ctx).instance = null;
}

/// Binds the optional user hooks of `T` to the kernel handler slots.
///
/// The forwarders are plain methods on a heap object (never closure
/// literals), so the bound delegates are capture-free and the kernel's
/// @nogc slot setters accept them. A hook that throws falls back to the
/// matching default handler, keeping the kernel error path intact.
private final class HookForwarder(T) {
    T instance;
    ActorShell* kernel_;

    this(T instance, ActorShell* kernel) @safe nothrow {
        this.instance = instance;
        this.kernel_ = kernel;
    }

    static if (__traits(hasMember, T, "onSpawn"))
        void forwardLaunch() @trusted {
            instance.onSpawn(ActorRef(kernel_));
        }

    static if (__traits(hasMember, T, "onException"))
        void forwardException(scope ref ActorShell self, scope Exception e) @trusted nothrow {
            try
                instance.onException(e);
            catch (Throwable)
                defaultExceptionHandler(self, e);
        }

    static if (__traits(hasMember, T, "onError"))
        void forwardError(scope ref ActorShell self, scope ErrorMsg msg) @trusted nothrow {
            try
                instance.onError(msg);
            catch (Throwable)
                defaultErrorHandler(self, msg);
        }

    static if (__traits(hasMember, T, "onExit"))
        void forwardExit(scope ref ActorShell self, scope ExitMsg msg) @trusted nothrow {
            try
                instance.onExit(msg);
            catch (Throwable)
                defaultExitHandler(self, msg);
        }

    static if (__traits(hasMember, T, "onDownMessage"))
        void forwardDown(scope ref ActorShell self, scope DownMsg msg) @trusted nothrow {
            try
                instance.onDownMessage(msg);
            catch (Throwable) {
            }
        }

    static if (__traits(hasMember, T, "onUnhandledMessage"))
        void forwardUnhandled(scope ref ActorShell self, ref Variant msg) @trusted nothrow {
            try
                instance.onUnhandledMessage(msg);
            catch (Throwable) {
            }
        }
}

/** Register every message method of `instance` with `kernel` and bind the
 * instance as the kernel context. Works for any plain class — there is no
 * base class to inherit from. Optional hooks (onSpawn, onException, ...)
 * are installed on the kernel handler slots; onSpawn is the one-shot
 * launch hook the kernel runs before the first message, passing the
 * ActorRef that is the only path to self-operations. Handler exceptions
 * propagate to the kernel tick catch and are routed to the onException
 * hook (or the default exception handler when the class has none). */
T implActor(T)(T instance, ActorShell* kernel) @safe {
    kernel.setContext(cast(void*) new InstanceBox!T(instance), &cleanupInstance!T);

    static foreach (name; __traits(allMembers, T)) {
        static if (!isReservedName!name) {
            static foreach (m; __traits(getOverloads, T, name)) {
                { // scope per method
                    static if (isMessageMethod!m) {
                        alias HArgs = staticMap!(Unqual, Parameters!m);
                        alias R = ReturnType!m;

                        // message identity is name + parameter types only —
                        // const-ness and ref-ness are not part of it, so two
                        // overloads with the same identity would collide in
                        // register() (last-write-wins) and silently kill one.
                        // Make that a compile error.
                        static assert(countSameIdentity!(T, name, m)() <= 1,
                                "implActor: overloads of '" ~ name ~ "' have the "
                                ~ "same name + parameter types; message identity "
                                ~ "excludes const-ness and ref-ness, so rename one "
                                ~ "or change its parameter types");

                        static R callImpl(T self, ref Variant msg) @trusted {
                            static if (HArgs.length == 0)
                                return __traits(getMember, self, name)();
                            else
                                return __traits(getMember, self, name)(msg.get!(Tuple!HArgs)
                                        .expand);
                        }

                        static if (is(R == void)) {
                            MsgHandler handler = (void* ctx, ref Variant msg) @trusted {
                                auto self = () @trusted {
                                    return cast(T)(cast(InstanceBox!T*) ctx).instance;
                                }();
                                callImpl(self, msg);
                            };
                            kernel.register(name, methodSignature!HArgs(name),
                                    Closure2!MsgHandler(handler));
                        } else {
                            RequestHandler handler = (void* ctx, ref Variant msg,
                                    ulong replyId, WeakAddress replyTo) @trusted {
                                auto self = () @trusted {
                                    return cast(T)(cast(InstanceBox!T*) ctx).instance;
                                }();
                                R r = callImpl(self, msg);

                                // deliver the result to the requester
                                static if (is(R : RequestResult!ReqT, ReqT)) {
                                    r.value.match!((ErrorMsg a) {
                                        sendSystemMsg(replyTo, a);
                                    }, (Promise!ReqT a) {
                                        a.set(replyTo, replyId);
                                    }, (data) {
                                        enum wrapInTuple = !is(typeof(data) : Tuple!U, U);
                                        if (auto rc = replyTo.lock.get) {
                                            static if (wrapInTuple)
                                                rc.put(Reply(replyId, Variant(tuple(data))));
                                            else
                                                rc.put(Reply(replyId, Variant(data)));
                                        }
                                    });
                                } else static if (is(R : Promise!PromT, PromT)) {
                                    r.set(replyTo, replyId);
                                } else {
                                    enum wrapInTuple = !is(R : Tuple!U, U);
                                    if (auto rc = replyTo.lock.get) {
                                        static if (wrapInTuple)
                                            rc.put(Reply(replyId, Variant(tuple(r))));
                                        else
                                            rc.put(Reply(replyId, Variant(r)));
                                    }
                                }
                            };
                            kernel.register(name, methodSignature!HArgs(name),
                                    Closure2!RequestHandler(handler));
                        }
                    }
                }
            }
        }
    }

    // Optional user hooks -> kernel handler slots (launch runs first, once).
    static if (__traits(hasMember, T, "onSpawn") || __traits(hasMember, T,
            "onException") || __traits(hasMember, T, "onError") || __traits(hasMember, T,
            "onExit") || __traits(hasMember, T, "onDownMessage")
            || __traits(hasMember, T, "onUnhandledMessage")) {
        auto hooks = new HookForwarder!T(instance, kernel);
        static if (__traits(hasMember, T, "onSpawn"))
            kernel.launchHandler(&hooks.forwardLaunch);
        static if (__traits(hasMember, T, "onException"))
            kernel.exceptionHandler(&hooks.forwardException);
        static if (__traits(hasMember, T, "onError"))
            kernel.errorHandler(&hooks.forwardError);
        static if (__traits(hasMember, T, "onExit"))
            kernel.exitHandler(&hooks.forwardExit);
        static if (__traits(hasMember, T, "onDownMessage"))
            kernel.downHandler(&hooks.forwardDown);
        static if (__traits(hasMember, T, "onUnhandledMessage"))
            kernel.defaultHandler(&hooks.forwardUnhandled);
    }

    return instance;
}

unittest {
    class LaunchLog {
        string log;

        void onSpawn(ActorRef self) @safe {
            log ~= "onSpawn;";
        }

        void ping() {
            log ~= "ping;";
        }
    }

    // onSpawn runs exactly once and before the first message is processed.
    {
        auto addr = makeAddress;
        auto kernel = ActorShell(addr);
        auto c = new LaunchLog;
        implActor(c, &kernel);

        kernel.addr.weakRef.lock.get.put(Msg(methodSignature("ping"),
                MsgType(MsgOneShot(Variant(tuple())))));
        kernel.process(Clock.currTime);
        assert(c.log == "onSpawn;ping;", c.log);
        kernel.process(Clock.currTime);
        assert(c.log == "onSpawn;ping;", c.log);

        sendExit(kernel.addr.weakRef, ExitReason.userShutdown);
        int guard;
        while (kernel.isAlive() && guard++ < 100)
            kernel.process(Clock.currTime);
    }

    class BoomCaught {
        int caught;

        void boom() {
            throw new Exception("bang");
        }

        void onException(Exception e) {
            caught++;
        }
    }

    // a throwing handler reaches the onException hook and the actor survives.
    {
        auto addr = makeAddress;
        auto kernel = ActorShell(addr);
        auto c = new BoomCaught;
        implActor(c, &kernel);

        kernel.addr.weakRef.lock.get.put(Msg(methodSignature("boom"),
                MsgType(MsgOneShot(Variant(tuple())))));
        kernel.process(Clock.currTime);
        assert(c.caught == 1);
        assert(kernel.isAlive());

        sendExit(kernel.addr.weakRef, ExitReason.userShutdown);
        int guard;
        while (kernel.isAlive() && guard++ < 100)
            kernel.process(Clock.currTime);
    }

    class BoomHookThrows {
        void boom() {
            throw new Exception("bang");
        }

        void onException(Exception e) {
            throw new Exception("hook failed");
        }
    }

    // a failing onException hook falls back to the default exception handler.
    {
        auto addr = makeAddress;
        auto kernel = ActorShell(addr);
        auto c = new BoomHookThrows;
        implActor(c, &kernel);

        kernel.addr.weakRef.lock.get.put(Msg(methodSignature("boom"),
                MsgType(MsgOneShot(Variant(tuple())))));
        int guard;
        while (kernel.isAlive() && guard++ < 100)
            kernel.process(Clock.currTime);
        assert(!kernel.isAlive());
    }

    class UnhandledLog {
        int unhandled;

        void known() {
        }

        void onUnhandledMessage(ref Variant msg) {
            unhandled++;
        }
    }

    // an unknown signature reaches the onUnhandledMessage hook once.
    {
        auto addr = makeAddress;
        auto kernel = ActorShell(addr);
        auto c = new UnhandledLog;
        implActor(c, &kernel);

        kernel.addr.weakRef.lock.get.put(Msg(0xDEADBEEF, MsgType(MsgOneShot(Variant(tuple())))));
        kernel.process(Clock.currTime);
        assert(c.unhandled == 1);

        sendExit(kernel.addr.weakRef, ExitReason.userShutdown);
        int guard;
        while (kernel.isAlive() && guard++ < 100)
            kernel.process(Clock.currTime);
    }

    class ExitLog {
        int exits;

        void onExit(ExitMsg msg) {
            exits++;
        }
    }

    // a user shutdown message reaches the onExit hook once. The !isAlive
    // below rides the empty-behavior self-termination rule (ExitLog has no
    // message methods), not the exit path — a class WITH message methods
    // survives userShutdown; see TrappedExit right after.
    {
        auto addr = makeAddress;
        auto kernel = ActorShell(addr);
        auto c = new ExitLog;
        implActor(c, &kernel);

        sendExit(kernel.addr.weakRef, ExitReason.userShutdown);
        int guard;
        while (kernel.isAlive() && guard++ < 100)
            kernel.process(Clock.currTime);
        assert(c.exits == 1);
        assert(!kernel.isAlive());
    }

    // trap semantics (by design): with message methods present,
    // userShutdown reaches the onExit hook but does not kill the actor —
    // the hook replaced the default exit handler (whose forceShutdown is
    // the only default death), and the hook has no self handle to request
    // shutdown from. kill remains untrappable.
    class TrappedExit {
        int exits;

        void ping() {
        }

        void onExit(ExitMsg msg) {
            exits++;
        }
    }

    {
        auto addr = makeAddress;
        auto kernel = ActorShell(addr);
        auto c = new TrappedExit;
        implActor(c, &kernel);

        sendExit(kernel.addr.weakRef, ExitReason.userShutdown);
        int guard;
        while (kernel.isAlive() && guard++ < 10)
            kernel.process(Clock.currTime);
        assert(c.exits == 1);
        assert(kernel.isAlive());
    }

    class Counter {
        int sum;

        void add(int v) {
            sum += v;
        }
    }

    // a one-arg payload dispatches through the tuple expand path.
    {
        auto addr = makeAddress;
        auto kernel = ActorShell(addr);
        auto c = new Counter;
        implActor(c, &kernel);

        kernel.addr.weakRef.lock.get.put(Msg(methodSignature!int("add"),
                MsgType(MsgOneShot(Variant(Tuple!(int)(5))))));
        kernel.process(Clock.currTime);
        assert(c.sum == 5);

        sendExit(kernel.addr.weakRef, ExitReason.userShutdown);
        int guard;
        while (kernel.isAlive() && guard++ < 100)
            kernel.process(Clock.currTime);
    }

    class IntEcho {
        int echo(int v) {
            return v;
        }
    }

    // a request message dispatches to the request handler and the value
    // reply is boxed into the caller's mailbox.
    {
        auto addr = makeAddress;
        auto kernel = ActorShell(addr);
        auto c = new IntEcho;
        implActor(c, &kernel);

        // the caller mailbox must be open to receive the reply, like a
        // live actor's mailbox is.
        auto replyAddr = makeAddress;
        replyAddr.get.setOpen;
        ulong replyId = 7;
        kernel.addr.weakRef.lock.get.put(Msg(methodSignature!int("echo"),
                MsgType(MsgRequest(replyAddr.weakRef, replyId, Variant(Tuple!(int)(42))))));
        kernel.process(Clock.currTime);

        assert(!replyAddr.get.empty!Reply);
        auto reply = replyAddr.get.pop!Reply;
        assert(reply.get.id == replyId);
        assert(reply.get.data.get!(Tuple!(int)) == Tuple!(int)(42));

        sendExit(kernel.addr.weakRef, ExitReason.userShutdown);
        int guard;
        while (kernel.isAlive() && guard++ < 100)
            kernel.process(Clock.currTime);
    }
}
