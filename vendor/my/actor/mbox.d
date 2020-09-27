/**
Copyright: Copyright (c) 2020, Joakim Brännström. All rights reserved.
License: $(LINK2 http://www.boost.org/LICENSE_1_0.txt, Boost Software License 1.0)
Author: Joakim Brännström (joakim.brannstrom@gmx.com)
*/
module my.actor.mbox;

import core.atomic : cas, atomicStore, MemoryOrder;
import core.sync.condition : Condition;
import core.sync.mutex : Mutex;
import core.thread : Thread;
import core.time : Duration, dur;
import logger = std.experimental.logger;
import std.array : appender, empty;
import std.datetime : SysTime, Clock;
import std.format : formattedWrite;
import std.range : isOutputRange;
import std.traits;
import std.typecons : Tuple;
import std.variant : Variant;

import my.actor : Aid;

@("shall retrieve the message from the mailbox")
unittest {
    auto mbox = new MessageBox;
    mbox.put(Message(42));
    Message m;
    assert(mbox.get(10.dur!"msecs", m));
    assert(m != Message.init);
}

@("shall retrieve the message from the mailbox that has trigged because of the clock")
unittest {
    const clock = Clock.currTime;
    auto mbox = new DelayedMessageBox;
    mbox.put(DelayedMessage(clock + 20.dur!"seconds", Message(42)));
    mbox.put(DelayedMessage(clock + 5.dur!"seconds", Message(52)));
    mbox.put(DelayedMessage(clock + 10.dur!"seconds", Message(62)));
    Message m;
    assert(mbox.get(10.dur!"msecs", clock + 6.dur!"seconds", m));
    assert(m != Message.init);
    auto v = m.data.get!int;
    assert(v == 52);
}

/** A MessageBox is a message queue for one actor.
 *
 * Other actors may send messages to this owner by calling put(), and the owner
 * receives them by calling get().  The put() call is therefore effectively
 * shared and the get() call is effectively local. `setMaxMsgs` may be used by
 * any actor to limit the size of the message queue.
 */
class MessageBox {
    /* TODO: make @safe after relevant druntime PR gets merged */
    this() @trusted nothrow {
        m_lock = new Mutex;
        m_closed = false;

        m_putMsg = new Condition(m_lock);
        m_notFull = new Condition(m_lock);
    }

    ///
    final @property bool isClosed() @safe @nogc pure {
        synchronized (m_lock) {
            return m_closed;
        }
    }

    /*
     * Sets a limit on the maximum number of user messages allowed in the
     * mailbox.  If this limit is reached, the caller attempting to add a
     * new message will execute `call`.  If num is zero, there is no limit
     * on the message queue.
     *
     * Params:
     *  num  = The maximum size of the queue or zero if the queue is
     *         unbounded.
     *  call = The routine to call when the queue is full.
     */
    final void setMaxMsgs(size_t num) @safe @nogc pure {
        synchronized (m_lock) {
            m_maxMsgs = num;
        }
    }

    /*
     * If maxMsgs is not set, the message is added to the queue and the
     * owner is notified.  If the queue is full, the message will still be
     * accepted if it is a control message, otherwise onCrowdingDoThis is
     * called.  If the routine returns true, this call will block until
     * the owner has made space available in the queue.  If it returns
     * false, this call will abort.
     *
     * Params:
     *  fromActor = the actor that is sending the message
     *  msg = The message to put in the queue.
     *
     *  Returns: true if the message where successfully added to the mailbox.
     *
     * Throws:
     *  An exception if the queue is full and onCrowdingDoThis throws.
     */
    final bool put(ref Message msg) {
        synchronized (m_lock) {
            if (m_closed) {
                // TODO: Generate an error here if m_closed is true, or maybe
                //       put a message in the caller's queue?
                return false;
            }

            // try only a limited number of times then give up.
            for (int i = 0; i < 3; ++i) {
                if (mboxFull) {
                    m_putQueue++;
                    m_notFull.wait();
                    m_putQueue--;
                } else {
                    m_sharedBox.put(msg);
                    m_putMsg.notify();
                    return true;
                }
            }

            return false;
        }
    }

    /// ditto
    final void put(Message msg) {
        this.put(msg);
    }

    /** Try to pop a message from the mailbox.
     *
     * Params:
     *  timeout = max time to wait for a message to arrive.
     *  msg = the retrieved message is written here.
     *
     * Returns:
     *  true if a message was retrieved and false if not (such as if a
     *  timeout occurred).
     */
    bool get(Duration timeout, ref Message msg) {
        import core.time : MonoTime;

        const limit = () {
            if (timeout <= Duration.zero)
                return MonoTime.currTime;
            return MonoTime.currTime + timeout;
        }();

        static bool tryMsg(ref ListT list, ref Message msg) {
            if (list.empty)
                return false;
            auto range = list[];
            msg = range.front;
            list.removeAt(range);
            return true;
        }

        while (true) {
            if (tryMsg(m_localBox, msg)) {
                return true;
            }

            ListT arrived;

            synchronized (m_lock) {
                updateMsgCount();
                while (m_sharedBox.empty) {
                    // NOTE: We're notifying all waiters here instead of just
                    //       a few because the onCrowding behavior may have
                    //       changed and we don't want to block sender threads
                    //       unnecessarily if the new behavior is not to block.
                    //       This will admittedly result in spurious wakeups
                    //       in other situations, but what can you do?
                    if (m_putQueue && !mboxFull()) {
                        m_notFull.notifyAll();
                    }
                    if (timeout <= Duration.zero || !m_putMsg.wait(timeout)) {
                        return false;
                    }
                }
                arrived.put(m_sharedBox);
            }

            scope (exit)
                m_localBox.put(arrived);
            if (tryMsg(arrived, msg)) {
                return true;
            } else {
                timeout = limit - MonoTime.currTime;
            }
        }
    }

    /*
     * Called on thread termination.  This routine processes any remaining
     * control messages, clears out message queues, and sets a flag to
     * reject any future messages.
     */
    final void close() {
        synchronized (m_lock) {
            m_sharedBox.clear;
            m_closed = true;
        }
        m_localBox.clear();
    }

private:
    // Routines involving local data only, no lock needed.

    bool mboxFull() @safe @nogc pure nothrow {
        return m_maxMsgs && m_maxMsgs <= m_localMsgs + m_sharedBox.length;
    }

    void updateMsgCount() @safe @nogc pure nothrow {
        m_localMsgs = m_localBox.length;
    }

    alias ListT = List!(Message);

    ListT m_localBox;

    Mutex m_lock;
    Condition m_putMsg;
    Condition m_notFull;
    size_t m_putQueue;
    ListT m_sharedBox;
    size_t m_localMsgs;
    size_t m_maxMsgs;
    bool m_closed;
}

/** A MessageBox that keep messages sorted by the time they should be processed.
 *
 * Other actors may send messages to this owner by calling put(), and the owner
 * receives them by calling get().  The put() call is therefore effectively
 * shared and the get() call is effectively local. `setMaxMsgs` may be used by
 * any actor to limit the size of the message queue.
 */
class DelayedMessageBox {
    /* TODO: make @safe after relevant druntime PR gets merged */
    this() @trusted nothrow {
        m_lock = new Mutex;
        m_closed = false;

        m_putMsg = new Condition(m_lock);
        m_notFull = new Condition(m_lock);
    }

    ///
    final @property bool isClosed() @safe @nogc pure {
        synchronized (m_lock) {
            return m_closed;
        }
    }

    /*
     * Sets a limit on the maximum number of user messages allowed in the
     * mailbox.  If this limit is reached, the caller attempting to add a
     * new message will execute `call`.  If num is zero, there is no limit
     * on the message queue.
     *
     * Params:
     *  num  = The maximum size of the queue or zero if the queue is
     *         unbounded.
     *  call = The routine to call when the queue is full.
     */
    final void setMaxMsgs(size_t num) @safe @nogc pure {
        synchronized (m_lock) {
            m_maxMsgs = num;
        }
    }

    /** Add a message that will trigger in the future.
     *
     * If maxMsgs is not set, the message is added to the queue and the
     * owner is notified.  If the queue is full, the message will still be
     * accepted if it is a control message, otherwise onCrowdingDoThis is
     * called.  If the routine returns true, this call will block until
     * the owner has made space available in the queue.  If it returns
     * false, this call will abort.
     *
     * Params:
     *  fromActor = the actor that is sending the message
     *  msg = The message to put in the queue.
     *
     *  Returns: true if the message where successfully added to the mailbox.
     *
     * Throws:
     *  An exception if the queue is full and onCrowdingDoThis throws.
     */
    final bool put(ref DelayedMessage msg) {
        synchronized (m_lock) {
            if (m_closed) {
                // TODO: Generate an error here if m_closed is true, or maybe
                //       put a message in the caller's queue?
                return false;
            }

            // try only a limited number of times then give up.
            for (int i = 0; i < 3; ++i) {
                if (mboxFull) {
                    m_putQueue++;
                    m_notFull.wait();
                    m_putQueue--;
                } else {
                    m_sharedBox.put(msg);
                    m_putMsg.notify();
                    return true;
                }
            }

            return false;
        }
    }

    /// ditto
    final void put(DelayedMessage msg) {
        this.put(msg);
    }

    /** Try to pop a message from the mailbox.
     *
     * The messages aren
     *
     * Params:
     *  timeout = max time to wait for a message to arrive.
     *  clock = retrieve the first message that are delayed until this clock
     *  msg = the retrieved message is written here.
     *
     * Returns:
     *  true if a message was retrieved and false if not (such as if a
     *  timeout occurred).
     */
    bool get(Duration timeout, const SysTime clock, ref Message msg) {
        import core.time : MonoTime;

        // Move the front message if it has longer until it triggers than the
        // message after it. This is so messages "far" in the future are at the
        // end of the list "eventually".
        static void shiftOldToBack(ref ListT list, const SysTime clock) {
            if (list.length < 3)
                return;
            auto r0 = list[];
            // the next message will trigger a timeout thus do nothing.
            if (r0.front.delayUntil < clock)
                return;

            auto r1 = r0;
            r1.popFront;
            if (r0.front.delayUntil - clock < r1.front.delayUntil - clock)
                return;

            auto msg = r0.front;
            list.removeAt(r0);
            list.put(msg);
        }

        static bool tryScanForMsg(SysTime clock, ref ListT list, ref Message msg) {
            for (auto range = list[]; !range.empty;) {
                if (range.front.delayUntil < clock) {
                    msg = range.front.value;
                    list.removeAt(range);
                    return true;
                }
                range.popFront();
            }
            return false;
        }

        // max time to wait for a message.
        const limit = () {
            if (timeout <= Duration.zero)
                return MonoTime.currTime;
            return MonoTime.currTime + timeout;
        }();

        while (true) {
            if (tryScanForMsg(clock, m_localBox, msg)) {
                return true;
            }

            ListT arrived;

            synchronized (m_lock) {
                updateMsgCount();
                while (m_sharedBox.empty) {
                    // NOTE: We're notifying all waiters here instead of just
                    //       a few because the onCrowding behavior may have
                    //       changed and we don't want to block sender threads
                    //       unnecessarily if the new behavior is not to block.
                    //       This will admittedly result in spurious wakeups
                    //       in other situations, but what can you do?
                    if (m_putQueue && !mboxFull()) {
                        m_notFull.notifyAll();
                    }
                    if (timeout <= Duration.zero || !m_putMsg.wait(timeout)) {
                        return false;
                    }
                }
                arrived.put(m_sharedBox);
            }

            scope (exit)
                m_localBox.put(arrived);
            if (tryScanForMsg(clock, arrived, msg)) {
                return true;
            } else {
                timeout = limit - MonoTime.currTime;
                shiftOldToBack(m_localBox, clock);
            }
        }
    }

    /*
     * Called on thread termination.  This routine processes any remaining
     * control messages, clears out message queues, and sets a flag to
     * reject any future messages.
     */
    final void close() {
        synchronized (m_lock) {
            m_sharedBox.clear;
            m_closed = true;
        }
        m_localBox.clear();
    }

private:
    // Routines involving local data only, no lock needed.

    bool mboxFull() @safe @nogc pure nothrow {
        return m_maxMsgs && m_maxMsgs <= m_localMsgs + m_sharedBox.length;
    }

    void updateMsgCount() @safe @nogc pure nothrow {
        m_localMsgs = m_localBox.length;
    }

    alias ListT = List!(DelayedMessage);

    ListT m_localBox;

    Mutex m_lock;
    Condition m_putMsg;
    Condition m_notFull;
    size_t m_putQueue;
    ListT m_sharedBox;
    size_t m_localMsgs;
    size_t m_maxMsgs;
    bool m_closed;
}

enum MsgType {
    normal,
    priority,
    delayed,
    system,
}

struct Message {
    Variant data;

    this(T...)(T vals) if (T.length > 0 && !is(T[0] == MsgType)) {
        static if (T.length == 1) {
            data = vals[0];
        } else {
            data = Tuple!(T)(vals);
        }
    }

    string toString() @safe const {
        auto buf = appender!string;
        toString(buf);
        return buf.data;
    }

    void toString(Writer)(ref Writer w) const if (isOutputRange!(Writer, char)) {
        formattedWrite(w, "Message(%s)", data.type);
    }

    @property auto convertsTo(T...)() {
        static if (T.length == 1) {
            return is(T[0] == Variant) || data.convertsTo!(T);
        } else {
            import std.typecons : Tuple;

            return data.convertsTo!(Tuple!(T));
        }
    }

    @property auto get(T...)() {
        static if (T.length == 1) {
            static if (is(T[0] == Variant))
                return data;
            else
                return data.get!(T);
        } else {
            import std.typecons : Tuple;

            return data.get!(Tuple!(T));
        }
    }

    auto map(alias Op)() {
        alias OpArgs = Parameters!Op;

        static if (OpArgs.length == 1) {
            static if (is(OpArgs[0] == Variant)) {
                return Op(data);
            } else {
                return Op(data.get!(OpArgs));
            }
        } else {
            import std.typecons : Tuple;

            return Op(data.get!(Tuple!(OpArgs)).expand);
        }
    }

    auto map(alias Op, StateT)(ref StateT state) {
        alias OpArgs = Parameters!Op[1 .. $];

        static if (OpArgs.length == 1) {
            static if (is(OpArgs[0] == Variant)) {
                return Op(state, data);
            } else {
                return Op(state, data.get!(OpArgs));
            }
        } else {
            import std.typecons : Tuple;

            return Op(state, data.get!(Tuple!(OpArgs)).expand);
        }
    }
}

struct List(T) {
    struct Range {
        import std.exception : enforce;

        @property bool empty() const {
            return !m_prev.next;
        }

        @property ref T front() {
            enforce(m_prev.next, "invalid list node");
            return m_prev.next.val;
        }

        @property void front(T val) {
            enforce(m_prev.next, "invalid list node");
            m_prev.next.val = val;
        }

        void popFront() {
            enforce(m_prev.next, "invalid list node");
            m_prev = m_prev.next;
        }

        private this(Node* p) {
            m_prev = p;
        }

        private Node* m_prev;
    }

    void put(T val) {
        put(newNode(val));
    }

    void put(ref List!(T) rhs) {
        if (!rhs.empty) {
            put(rhs.m_first);
            while (m_last.next !is null) {
                m_last = m_last.next;
                m_count++;
            }
            rhs.m_first = null;
            rhs.m_last = null;
            rhs.m_count = 0;
        }
    }

    Range opSlice() {
        return Range(cast(Node*)&m_first);
    }

    void removeAt(Range r) {
        import std.exception : enforce;

        assert(m_count, "Can not remove from empty Range");
        Node* n = r.m_prev;
        enforce(n && n.next, "attempting to remove invalid list node");

        if (m_last is m_first)
            m_last = null;
        else if (m_last is n.next)
            m_last = n; // nocoverage
        Node* to_free = n.next;
        n.next = n.next.next;
        freeNode(to_free);
        m_count--;
    }

    @property size_t length() {
        return m_count;
    }

    void clear() {
        m_first = m_last = null;
        m_count = 0;
    }

    @property bool empty() {
        return m_first is null;
    }

private:
    struct Node {
        Node* next;
        T val;

        this(T v) {
            val = v;
        }
    }

    static shared struct SpinLock {
        void lock() {
            while (!cas(&locked, false, true)) {
                Thread.yield();
            }
        }

        void unlock() {
            atomicStore!(MemoryOrder.rel)(locked, false);
        }

        bool locked;
    }

    static shared SpinLock sm_lock;
    static shared Node* sm_head;

    Node* newNode(T v) {
        Node* n;
        {
            sm_lock.lock();
            scope (exit)
                sm_lock.unlock();

            if (sm_head) {
                n = cast(Node*) sm_head;
                sm_head = sm_head.next;
            }
        }
        if (n) {
            import std.conv : emplace;

            emplace!Node(n, v);
        } else {
            n = new Node(v);
        }
        return n;
    }

    void freeNode(Node* n) {
        // destroy val to free any owned GC memory
        destroy(n.val);

        sm_lock.lock();
        scope (exit)
            sm_lock.unlock();

        auto sn = cast(shared(Node)*) n;
        sn.next = sm_head;
        sm_head = sn;
    }

    void put(Node* n) {
        m_count++;
        if (!empty) {
            m_last.next = n;
            m_last = n;
            return;
        }
        m_first = n;
        m_last = n;
    }

    Node* m_first;
    Node* m_last;
    size_t m_count;
}

struct DelayedMessage {
    SysTime delayUntil;
    Message value;
}
