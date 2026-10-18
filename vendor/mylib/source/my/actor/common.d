/**
Copyright: Copyright (c) Joakim Brännström. All rights reserved.
License: $(LINK2 http://www.boost.org/LICENSE_1_0.txt, Boost Software License 1.0)
Author: Joakim Brännström (joakim.brannstrom@gmx.com)
*/
module my.actor.common;

import logger = std.logger;

import core.sync.condition : Condition;
import core.sync.mutex : Mutex;

/** Multiple producer, "single" consumer thread safe queue.
 *
 * The value may be `T.init` if multiple consumers try to pop a value at the same time.
 */
struct Queue(RawT) {
    import std.container.dlist : DList;

    static if (is(RawT == U*, U)) {
        alias T = U;
        enum AsPointer = true;
    } else {
        alias T = RawT;
        enum AsPointer = false;
    }

    static struct Item(TT) {
        private TT ptr;

        ~this() @trusted {
            if (ptr !is null) {
                *ptr = T.init;
                ptr = null;
            }
        }

        ref T get() {
            return *ptr;
        }

        // Move the value. It is now up to the user to ensure it is destructed.
        TT unsafeMove() {
            auto tmp = ptr;
            ptr = null;
            return tmp;
        }
    }

    private {
        Mutex mtx;
        DList!(T*) data;
        bool open;
        size_t length_;
    }

    invariant {
        assert(mtx !is null);
    }

    @disable this(this);

    this(Mutex mtx)
    in (mtx !is null) {
        this.mtx = mtx;
        this.open = true;
    }

    static if (AsPointer) {
        bool put(T* a) @trusted {
            synchronized (mtx) {
                if (open) {
                    data.insertBack(a);
                    length_++;
                }
                return open;
            }
        }
    } else {
        bool put(T a) @trusted {
            synchronized (mtx) {
                if (open) {
                    auto obj = new T;
                    *obj = a;
                    data.insertBack(obj);
                    length_++;
                }
                return open;
            }
        }
    }

    alias PopReturnType = Item!(T*);

    Item!(T*) pop() @trusted scope {
        synchronized (mtx) {
            if (!empty) {
                auto tmp = data.front;
                data.removeFront;
                length_--;
                return typeof(return)(tmp);
            }
        }

        return typeof(return).init;
    }

    /** Pop a message and, if one was removed, wake `cond` while still
     * holding the queue lock.
     *
     * Needed by the bounded incoming mailbox: the pop is the moment a slot
     * frees, and non-actor senders waiting on the bound must be woken in
     * the same critical section that frees it or the wakeup is lost.
     * `cond` must be bound to this queue's lock. `null` behaves like `pop`.
     *
     * The Item is returned directly from the critical section: if it were
     * bound to a local first and then returned, the local's destructor
     * (`*ptr = T.init`) would null the popped slot before the caller's
     * copy could read it.
     */
    Item!(T*) popNotifying(Condition cond) @trusted scope {
        synchronized (mtx) {
            if (!empty) {
                auto tmp = data.front;
                data.removeFront;
                length_--;
                if (cond !is null) {
                    // Insurance: a condition bound to a different lock would
                    // wake the wrong waiters.
                    assert(cond.mutex_nothrow is this.mtx,
                            "popNotifying: condition detached from queue lock");
                    cond.notifyAll;
                }
                return typeof(return)(tmp);
            }
        }

        return typeof(return).init;
    }

    bool empty() @trusted pure const @nogc {
        synchronized (mtx) {
            return data.empty;
        }
    }

    size_t length() @trusted pure const @nogc {
        synchronized (mtx) {
            return length_;
        }
    }

    /// clear the queue and permanently shut it down by rejecting put messages.
    void teardown(void delegate(ref T) deinit) @trusted {
        synchronized (mtx) {
            foreach (ref a; cast() data)
                deinit(*a);
            open = false;
            data.clear;
            length_ = 0;
        }
    }
}

/** Errors that occur in the actor system.
 *
 * Attribution: C++ Actor Framework.
 * The framework is well developed and has gathered a lot of experience
 * throughout the years. The error enum is one of many indications of this
 * fact.  The enum `Error` here is a copy of those suitable for a local actor
 * system.
 */
enum SystemError : ubyte {
    // no error
    none,
    /// Indicates that an actor dropped an unexpected message.
    unexpectedMessage,
    /// Indicates that a response message did not match the provided handler.
    unexpectedResponse,
    /// Indicates that the receiver of a request is no longer alive.
    requestReceiverDown,
    /// Indicates that a request message timed out.
    requestTimeout,
    /// An exception was thrown during message handling.
    runtimeError,
}

/** Exit reasons of actors, a special kind of error code. These are usually
 * fail states set by the actor system itself. The two exceptions are
 * `userShutdown` and `kill`: the former signals orderly, user-requested
 * shutdown and can be used by programmers the same way; the latter terminates
 * an actor unconditionally when used in `sendExit`, even for actors that
 * override the default exit handling.
 */

/// This error category represents fail conditions for actors.
enum ExitReason : ubyte {
    /// Indicates that an actor finished execution without error.
    normal,
    /// Indicates that an actor died because of an unhandled exception.
    unhandledException,
    /// Indicates that the exit reason for this actor is unknown, i.e.,
    /// the actor has been terminated and no longer exists.
    unknown,
    /// Indicates that an actor was forced to shutdown by a user-generated event.
    userShutdown,
    /// Indicates that an actor was killed unconditionally.
    kill,
}

/// Message identity: method name + parameter types (Unqual), FNV-1a mixed.
/// Registration and sending sides compute it from the same pair, so zero-arg
/// methods and methods sharing parameter lists stay distinct.
ulong methodSignature(T...)(string name) @trusted {
    import std.traits : Unqual;

    ulong h = 0xcbf29ce484222325UL; // FNV-1a offset basis
    foreach (c; name)
        h = (h ^ cast(ulong) cast(ubyte) c) * 0x100000001b3UL;
    static foreach (T100; T)
        h = (h ^ typeid(Unqual!T100).toHash) * 0x100000001b3UL;
    return h;
}

unittest {
    alias CInt = const(int);
    alias IOInt = inout(int);

    // Zero-arg and arg-taking methods stay distinct.
    assert(methodSignature("total") != methodSignature!int("add"));

    // Same parameters, different names.
    assert(methodSignature!int("ding") != methodSignature!int("dong"));

    // Parameter order is significant.
    assert(methodSignature!(int, string)("mix") != methodSignature!(string, int)("mix"));

    // Unqual: qualifiers on parameter types do not change the identity.
    assert(methodSignature!int("add") == methodSignature!CInt("add"));
    assert(methodSignature!int("add") == methodSignature!IOInt("add"));
}
