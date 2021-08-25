/**
Copyright: Copyright (c) 2021, Joakim Brännström. All rights reserved.
License: $(LINK2 http://www.boost.org/LICENSE_1_0.txt, Boost Software License 1.0)
Author: Joakim Brännström (joakim.brannstrom@gmx.com)
*/
module app;

import core.memory : GC;
import core.thread : Thread;
import core.time : dur;
import logger = std.experimental.logger;
import std.algorithm : sort;
import std.array : array, appender, empty;
import std.datetime : Clock, Duration, dur, SysTime;
import std.datetime.stopwatch : StopWatch, AutoStart;
import std.exception : collectException;
import std.functional : toDelegate;
import std.stdio : writeln, writefln;
import std.typecons : tuple, Tuple;

import my.actor;
import my.stat;
import my.gc.refc;

immutable MByte = 1024.0 * 1024.0;

void main(string[] args) {
    import std.file : thisExePath;
    import std.format : format;
    import std.path : baseName;
    import std.traits;
    static import std.getopt;

    TestFn[string] metrics;
    metrics["create"] = toDelegate(&testActorCreate);
    metrics["send_msg"] = toDelegate(&testActorMsg);
    metrics["delayed_msg1"] = () => testActorDelayedMsg(1.dur!"msecs", 5.dur!"msecs", 1000);
    metrics["delayed_msg10"] = () => testActorDelayedMsg(12.dur!"msecs", 10.dur!"msecs", 100);
    metrics["delayed_msg100"] = () => testActorDelayedMsg(100.dur!"msecs", 100.dur!"msecs", 10);
    metrics["delayed_msg1000"] = () => testActorDelayedMsg(1000.dur!"msecs", 1000.dur!"msecs", 5);

    string[] metricName;
    uint repeatTimes = 1;
    auto helpInfo = std.getopt.getopt(args, "m|metric", format("metric to run %s",
            metrics.byKey), &metricName, "r|repeat", "repeat the metric test", &repeatTimes);

    if (helpInfo.helpWanted) {
        std.getopt.defaultGetoptPrinter(format!"usage: %s <options>\n"(thisExePath.baseName),
                helpInfo.options);
        return;
    }

    metricName = metricName.empty ? metrics.byKey.array.sort.array : metricName;

    foreach (const iter; 0 .. repeatTimes) {
        writeln("# Iteration ", iter);
        foreach (m; metricName) {
            writeln("##############");
            run(metrics[m]);
            writeln;
        }
    }
}

alias TestFn = Metric delegate();

void run(TestFn t) {
    auto m = t();
    writeln("data points ", m.values.length);
    auto data = m.values.makeData;
    auto bstat = basicStat(data);
    writeln(bstat);
    writeln("95% is < ", (bstat.mean.value + bstat.sd.value * 2.0) / 1000000.0, " ms");
    writeln("bytes per actor ", m.mem);
}

struct Metric {
    double[] values;
    double mem;
}

struct Mem {
    ulong start;
    double peek() {
        const used = GC.stats.usedSize;
        if (used < start)
            return start - used;
        return used - start;
    }
}

Mem mem() {
    return Mem(GC.stats.usedSize);
}

Metric testActorCreate() {
    writeln("# Test time to create an actor");
    writeln("unit: nanoseconds");

    Metric rval;

    auto sys = makeSystem;
    auto m = mem;
    auto perf() {
        auto sw = StopWatch(AutoStart.yes);
        foreach (_; 0 .. 1000)
            sys.spawn((Actor* a) => impl(a, (int a) {}));
        rval.values ~= sw.peek.total!"nsecs" / 1000.0;
    }

    foreach (_; 0 .. 1000)
        perf;

    rval.mem = m.peek / 1000000.0;

    return rval;
}

Metric testActorMsg() {
    writeln("# How long does it take to send an actor message from actor a->b");
    writeln("unit: nanoseconds");

    Metric rval;

    auto sys = makeSystem;
    auto m = mem;
    ulong nrActors;
    auto perf() {
        int count;
        auto a1 = sys.spawn((Actor* a) => impl(a, (ref Capture!(int*, "count") c, int x) {
                (*c.count)++;
            }, capture(&count)));
        nrActors++;

        Actor* spawnA2(Actor* self) {
            static void fn(ref Capture!(Actor*, "self", WeakAddress, "a1") c, int x) {
                send(c.a1, x);
                send(c.self.address, x + 1);
                if (x > 100)
                    c.self.shutdown;
            }

            return impl(self, &fn, capture(self, a1));
        }

        auto actors = appender!(WeakAddress[])();
        actors.put(a1);
        foreach (_; 0 .. 100) {
            actors.put(sys.spawn(&spawnA2));
            nrActors++;
        }

        auto sw = StopWatch(AutoStart.yes);
        foreach (a; actors.data)
            send(a, 1);

        int reqs;
        while (count < 10000) {
            Thread.sleep(1.dur!"msecs");
        }
        rval.values ~= sw.peek.total!"nsecs" / cast(double) count;

        foreach (a; actors.data)
            sendExit(a, ExitReason.userShutdown);
    }

    foreach (_; 0 .. 100)
        perf;

    rval.mem = m.peek / cast(double) nrActors;

    return rval;
}

Metric testActorDelayedMsg(Duration delayFor, Duration rate, const ulong dataPoints) {
    writeln("# Test delayed message trigger jitter");
    writefln("delay: %s rate: %s", delayFor, rate);
    writeln("What is the jitter of a delayed message compared to the expected arrival time");
    writeln("unit: nanoseconds");

    Metric rval;

    import std.parallelism;

    auto sys = System(new TaskPool(4), true);
    auto m = mem;

    auto perf() {
        static struct Get {
        }

        static struct Msg {
            SysTime expectedArrival;
        }

        static struct StartMsg {
        }

        auto sender = sys.spawn((Actor* self) {
            self.name = "sender";
            //self.exitHandler((ref Actor self, ExitMsg m) nothrow{
            //    logger.info("sender exit").collectException;
            //    self.shutdown;
            //});

            return impl(self, (ref Capture!(Actor*, "self", Duration, "delay",
                Duration, "rate") ctx, WeakAddress recv) {
                delayedSend(recv, delay(ctx.delay), Msg(Clock.currTime + ctx.delay));
                delayedSend(ctx.self, delay(ctx.rate), recv);
            }, capture(self, delayFor, rate));
        });

        auto collector = sys.spawn((Actor* self) {
            self.name = "collector";
            self.exitHandler((ref Actor self, ExitMsg m) nothrow{
                logger.info("collector exit").collectException;
                self.shutdown;
            });

            auto st = tuple!("diffs")(refCounted((double[]).init));
            alias CT = typeof(st);
            return impl(self, (ref CT ctx, Duration d) {
                ctx.diffs.get ~= cast(double) d.total!"nsecs";
            }, capture(st), (ref CT ctx, Get _) {
                auto tmp = ctx.diffs.get.dup;
                ctx.diffs.get = null;
                return tmp;
            }, capture(st));
        });

        auto recv = sys.spawn((Actor* self, WeakAddress collector) {
            self.name = "recv";
            //self.exitHandler((ref Actor self, ExitMsg m) nothrow{
            //    logger.info("recv exit").collectException;
            //    self.shutdown;
            //});

            return impl(self, (ref Capture!(WeakAddress, "collector") ctx, Msg m) {
                send(ctx.collector, Clock.currTime - m.expectedArrival);
            }, capture(collector));
        }, collector);

        // one dies, both goes down.
        collector.linkTo(sender);
        collector.linkTo(recv);
        send(sender, recv);

        auto self = scopedActor;
        double[] values;
        while (values.length < dataPoints) {
            self.request(collector, infTimeout).send(Get.init).then((double[] d) {
                values ~= d;
            });
            Thread.sleep(50.dur!"msecs");
        }
        rval.values ~= values;
        sendExit(collector, ExitReason.userShutdown);
    }

    foreach (_; 0 .. 10)
        perf;

    return rval;
}
