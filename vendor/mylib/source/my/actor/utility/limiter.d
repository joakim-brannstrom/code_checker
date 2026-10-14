/**
Copyright: Copyright (c) Joakim Brännström. All rights reserved.
License: $(LINK2 http://www.boost.org/LICENSE_1_0.txt, Boost Software License 1.0)
Author: Joakim Brännström (joakim.brannstrom@gmx.com)

An actor that can limit the flow of messages between consumer/producer.

The limiter is initialized with a number of tokens.

Producers try and take a token from the limiter. Either one is free and they
get it right away or a promise is returned. The promise is delivered whenever
a token is returned by the consumer. The waiting producers are triggered in
LIFO (just because that is a more efficient data structure).

A consumer receives a message from a producer containing the token and data.
When the consumer has finished processing the message it returns the token to
the limiter.
*/
module my.actor.utility.limiter;

import std.container : Array;
import std.datetime : dur;

import my.actor.actor : makePromise, Promise, RequestResult;
import my.actor.behavior : ActorRef;
import my.actor.channel : Channel, dynDelayedSend, dynSend;
import my.actor.common : ExitReason;
import my.actor.mailbox : TypedAddress, WeakAddress;
import my.actor.msg : Capture, capture, delay, sendExit;
import my.gc.refc;

/// A token of work.
struct Token {
}

interface IFlowControl {
    /// Take a token if there are any free.
    RequestResult!Token takeToken();

    /// Return a token.
    void returnToken();

    /// Deliver free tokens to waiting producers.
    void refresh();

    /// Refresh periodically; extra caution in case something is missed.
    void tickRefresh();
}

class FlowControl : IFlowControl {
    ActorRef self_;
    uint tokens_;
    Array!(Promise!Token) takeReq_; // pending takeToken requests, delivered LIFO

    this(const uint tokens) {
        tokens_ = tokens;
    }

    void onSpawn(ActorRef self) @safe {
        self_ = self;
        // kick the periodic refresh so that no returned token is missed.
        dynSend(self_.address, "tickRefresh");
    }

    override RequestResult!Token takeToken() {
        typeof(return) rval;

        if (tokens_ > 0) {
            tokens_--;
            rval = typeof(return)(Token.init);
        } else {
            auto p = makePromise!Token;
            takeReq_.insertBack(p);
            rval = typeof(return)(p);
        }
        return rval;
    }

    override void returnToken() {
        tokens_++;
        dynSend(self_.address, "refresh");
    }

    override void refresh() {
        while (tokens_ > 0 && !takeReq_.empty) {
            tokens_--;
            takeReq_.back.deliver(Token.init);
            takeReq_.back.clear;
            takeReq_.removeBack;
        }
    }

    override void tickRefresh() {
        // extra caution to refresh in case something is missed.
        dynDelayedSend(self_.address, delay(200.dur!"msecs"), "tickRefresh");
        dynSend(self_.address, "refresh");
    }
}

version (unittest) {
    private final class Sender {
        WeakAddress limiter_;
        WeakAddress recv_;
        ActorRef self_;

        this(WeakAddress limiter) @safe {
            limiter_ = limiter;
        }

        void onSpawn(ActorRef self) @safe {
            self_ = self;
        }

        void setRecv(WeakAddress recv) {
            recv_ = recv;
            dynSend(self_.address, "tick");
        }

        void tick() {
            Channel!IFlowControl(limiter_, self_).takeToken()
                .capture(Capture!(Sender, "self")(this)).then(&onToken);
        }

        static void onToken(ref Capture!(Sender, "self") ctx, Token t) {
            auto self = ctx.self;
            dynSend(self.self_.address, "tick");
            dynSend(self.recv_, "take", t, 42);
        }
    }

    private final class Consumer {
        WeakAddress limiter_;
        RefCounted!int count_;
        ActorRef self_;

        this(WeakAddress limiter, RefCounted!int count) {
            limiter_ = limiter;
            count_ = count;
        }

        void onSpawn(ActorRef self) @safe {
            self_ = self;
        }

        void tick() {
            if (count_.get == 100)
                sendExit(self_.address, ExitReason.userShutdown);
            else
                dynDelayedSend(self_.address, delay(100.dur!"msecs"), "tick");
        }

        void take(Token t, int _) {
            dynDelayedSend(limiter_, delay(100.dur!"msecs"), "returnToken");
            count_.get++;
            dynSend(self_.address, "tick");
        }
    }
}

@("shall limit the message rate of senders by using a limiter to control the flow")
unittest {
    import core.thread : Thread;
    import std.datetime.stopwatch : AutoStart, StopWatch;
    import my.actor.system;

    auto sys = makeSystem;

    auto limiter = sys.spawn!FlowControl(40);

    TypedAddress!Sender[] senders;
    foreach (_; 0 .. 100)
        senders ~= sys.spawn!Sender(limiter.weakRef);

    auto counter = refCounted(0);
    auto consumer = sys.spawn!Consumer(limiter.weakRef, counter);

    foreach (s; senders)
        s.linkTo(consumer);
    limiter.linkTo(consumer);

    auto sw = StopWatch(AutoStart.yes);
    foreach (s; senders)
        dynSend(s.weakRef, "setRecv", consumer.weakRef);

    while (counter.get < 100 && sw.peek < 4.dur!"seconds") {
        Thread.sleep(1.dur!"msecs");
    }

    assert(counter.get >= 100);
    // 40 tokens mean that it will trigger at least two "slowdown" which is at least 200 ms.
    assert(sw.peek > 200.dur!"msecs");
    sys.shutdown;
}
