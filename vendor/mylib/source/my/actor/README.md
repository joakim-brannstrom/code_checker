# my.actor

In-process actor library for mylib (D). An actor is a **plain class** — there is
no framework base class. Its public instance methods are its messages; optional
D interfaces make sends compile-time checked; the only self-abilities come from
the `ActorRef` handle passed to `onSpawn`; and shutdown is only the system
message `sendExit`.

## Quick start

```d
import my.actor;

interface ICounter
{
    void add(int v); // one-shot message
    int total(); // request/reply
}

class Counter : ICounter
{
    private ActorRef self_;
    private int total_;

    this() {} // runs on the spawning thread, before the actor is bound

    void onSpawn(ActorRef self) // optional; first execution on the actor's context
    {
        self_ = self; // keep the handle: address(), nothing else
    }

    override void add(int v)
    {
        total_ += v;
    }

    override int total()
    {
        return total_;
    }
}

void main()
{
    auto sys = makeSystem;
    auto counter = sys.spawn!Counter(); // TypedAddress!Counter — the actor handle
    // From another actor: Channel!ICounter(counter, self_).add(1);
    sys.shutdown;
}
```

Spawn order: constructor on the calling thread (arguments are forwarded to it)
→ wiring → `onSpawn` as the actor's first execution on its own context. Do
asynchronous initialization and self-sends in `onSpawn`
(`dynSend(self_.address, "method", args...)`); the constructor cannot send
anything — the actor has no address yet.

## Messages

- A message method is any **public, non-static instance method**, except the
  reserved hook names and `Object` members (`toString`, `opEquals`, ...).
- A message is identified by **method name + parameter types** (exact `Unqual`
  types, no implicit conversions). `ding(int)` and `dong(int)` are different
  messages; zero-argument methods work.
- Private, protected and static members are never message methods.

## Sending messages

`spawn!T` returns a `TypedAddress!T` handle. Keep it, and pass
`handle.weakRef` (or `self_.address`) on when the address has to travel, e.g.
as a message payload.

**Compile-time checked path** — `Channel!I` (from inside an actor, where `self_`
is the `ActorRef` saved in `onSpawn`):

```d
auto chan = Channel!ICounter(counter, self_); // handle + requesting actor
chan.add(1); // one-shot
chan.total().then((int sum) { ... }); // request
```

Building a channel from a typed address requires the actor class to implement
`I` (`is(C : I)`); every call site is then checked against `I`. A channel can
also be built from a raw address — `Channel!ICounter(someWeakAddress, self_)` —
which still checks the call sites against `I`, but trusts you that the target
really is an `ICounter`.

**Unchecked path** — method names as strings:

```d
dynSend(counter, "add", 1);
dynRequest(self_, counter, timeout(1.dur!"seconds"), "total").then((int sum) { ... });
dynDelayedSend(counter, delay(100.dur!"msecs"), "add", 1);
```

A wrong name or parameter list produces a different signature: the message is
silently dropped (observable via `onUnhandledMessage`). The `dyn*` overloads
accept a typed handle as well — the type is erased to the weak form before
sending, so the call stays unchecked.

What is checked where:

| Send path | Compile-time check |
| --- | --- |
| `Channel!I` from `TypedAddress!C` | `C` must implement `I`; call sites checked against `I` |
| `Channel!I` from a raw address | call sites checked against `I`; you vouch for the target's type |
| `dynSend` / `dynRequest` / `dynDelayedSend` | none |
| `sendExit`, `linkTo`, `monitor`, ... | address validity only (fixed system messages) |

## Repeating self-tick

An actor can have one repeating self-tick: at every interval the shell
dispatches a message to the actor itself. Arm it from the actor (via the
`ActorRef`), not from outside:

```d
void onSpawn(ActorRef self_) {
    self_.scheduleRepeating(100.dur!"msecs", "tick", 1); // fire tick(1) every 100 ms
}

void tick(int n) { ... }
```

Semantics:

- The first fire is `interval` after arming; each fire re-arms from the fire
  time, so the period is drift-free with respect to work done in the handler.
  At most one entry is ever pending.
- The signature is resolved when arming (same as `dynSend`): a wrong name or
  parameter list resolves to a message that is dropped on each fire (the
  unhandled-message path) while the repeat continues. The tick method must be
  a void message method; arming a request (non-void) method makes every fire
  a no-op drop.
- `self_.cancelTick()` stops the tick: the pending entry (if any) is dropped
  without dispatch when it comes due, and an entry already firing will not
  re-arm. A new `scheduleRepeating` call replaces any previous tick.
- A handler that throws stops the repeat; the exception is delivered to
  `onException` as for any other handler. Re-arm with `scheduleRepeating` if
  the tick should continue.
- No re-arm happens while the actor is shutting down: a pending entry is
  dropped without re-arming, and in a graceful shutdown a due entry may fire
  once during the final drain (the kill path clears it without firing).

This is the preferred replacement for the pattern of re-arming a
`dynDelayedSend(self_, ..., "tick")` at the end of the tick handler.

## Requests and replies

`chan.method(args)` on a non-void message returns a request chain:

```d
import std.typecons : Tuple;

int sum = -1;
chan.total().capture(&sum).then((ref Tuple!(int*) ctx, int v) { *ctx[0] = v; });
```

`capture` avoids the closure; without it, `.then((int v) { ... })` may capture.
The handler runs later, on the requesting actor's context. Requests have a
timeout — the channel's default is `SysTime.max` (`infTimeout()`); pass
`timeout(...)` to bound it. A timeout is reported through the error path
(`onError` with `SystemError.requestTimeout`).

A handler may defer its reply: returning `RequestResult!(T)` that holds a
`Promise!T` answers the requester when the promise is delivered — see the
flow-control actor in `utility/limiter.d`.

## Hooks

Optional class methods, called by the shell — they are never message targets.

| Hook | Called when | Default if absent |
| --- | --- | --- |
| `void onSpawn(ActorRef self)` | once, before the first message | nothing |
| `void onException(Exception e)` | a message method threw | force shutdown |
| `void onError(ErrorMsg msg)` | an `ErrorMsg` arrives | shutdown |
| `void onExit(ExitMsg msg)` | `sendExit` / a linked actor died | force shutdown |
| `void onDownMessage(DownMsg msg)` | a monitored actor died | dropped |
| `void onUnhandledMessage(ref Variant msg)` | no handler for the message | dropped |

## Lifecycle

- Shutdown is only the system message:
  `sendExit(target, ExitReason.userShutdown)` (`ExitReason.kill` is
  unconditional). There is no `shutdown()` on a handle.
- `linkTo(a, b)` couples two actors' lifetimes; `monitor(observer, target)`
  reports the target's death via `DownMsg`; both accept typed addresses or
  `WeakAddress`.
- An actor with at least one message method stays alive until it is shut down;
  it can shut itself down with `sendExit(self_.address, ...)`.
- An actor with no message methods self-terminates after `onSpawn`
  (empty behavior) — a one-shot task actor.

## Bounded mailbox

By default an actor's incoming queue is unbounded — sends never block and
never drop. `spawnBounded` opts in to a bound:

```d
auto ui = sys.spawnBounded!TuiActor(100); // at most 100 queued messages
```

The bound is installed before the actor is scheduled, so no message can
outrun it. When a bounded incoming queue is full:

- a send **from an actor worker** (a thread executing `process`) is
  **dropped**, never blocked — blocking a pool worker is the deadlock the
  bound exists to prevent: the worker holds a pool slot, and the only
  threads that could free a mailbox slot may themselves be workers, so a
  blocked worker can exhaust the pool and nothing ever drains the queue.
  The drop is counted — see `Address.dropped` — so loss beyond the
  declared policy is observable.
- a send **from a non-actor thread** (your `main`, a supervisor, a test)
  **blocks** until a slot frees or the target shuts down (the send then
  returns `false`). Such a sender holds no worker, so blocking it cannot
  exhaust the pool.

Only one-shot `Msg`s (`send`, `dynSend`, `Channel` sends) are bounded.
System messages (`sendExit`, monitor/link traffic), delayed messages and
replies are never bounded, so a busy actor is always reachable for
shutdown, and a bounded actor is guaranteed to drain — which in turn
guarantees that a blocked non-actor sender always resolves (delivered, or
`false` if the target shuts down).

**Pool-size policy (a convention, not enforced by the library):** keep at least
**actor count + 1** threads available — one worker per concurrently busy
actor, plus one **non-pool thread** (e.g. the `main` supervisor) that may
perform blocking sends. A pool worker must never be the thread that
blocks on a full bounded mailbox. `Config.detached` actors run on their own
dedicated threads and do not consume pool workers; the convention above
applies to the pooled set only.

The semantics and the 2-worker deadlock scenario are covered by the
unittests in `bounded_mailbox.d`.

The blocking path relies on `core.sync.Mutex` being reentrant and on
`Condition` waiting on the same lock — verified with ldc2 (1.42); this
tree builds LDC-only.

A class without an interface is still an actor (all its public methods are
messages), but sends should use the dynamic path — unless the class type is in
scope, in which case `Channel!Class` works as well.

## Detached actors

Placement is chosen per spawn call with the `Config` parameter (first
template argument of `spawn` / `spawnBounded`):

```d
sys.spawn!T(args);                                  // Config.pool (default)
sys.spawn!(Config.detached, T)(args);               // dedicated thread
sys.spawnBounded!T(1000, args);                     // pool, bounded
sys.spawnBounded!(Config.detached, T)(1000, args);  // dedicated thread, bounded
```

A `Config.detached` actor runs on its own System-owned thread: created at
spawn, never daemon, and joined at `shutdown`. It is never queued on the
shared worker pool, so a fully busy pool cannot starve it; per-actor
serialization is unchanged (one `process` pass at a time, on that thread).
Idle executors wake at most every 10 ms, and `scheduleRepeating` / delayed
sends fire on the executor within one poll after they come due.

**One-shot task actors.** An actor with no message methods self-terminates
as soon as its first execution finishes — `onSpawn` is the whole task. The
explicit variant keeps a message method but sends
`sendExit(self_.address, ExitReason.userShutdown)` from `onSpawn` with no
`onExit` hook; the default exit handler force-shuts, which is a real death
a `monitor` sees via `DownMsg`. A throwing ctor propagates out of `spawn`
and leaves no executor behind.

## Known limits

- `ActorRef` exposes only `address()`; spawning children from inside an actor
  needs the `System*` handed in at construction.
- Exact parameter matching: a `byte` argument does not match an `int` parameter
  (compile error on the checked path, dropped message on the dynamic path).
- Unhandled messages are dropped by default; use `onUnhandledMessage` to
  observe them.
- Addresses are process-local; there is no distribution.

## Executable examples

The unittests are the reference implementation of this document:

- `channel.d` — complete driver: typed actor with two interfaces, zero-arg and
  same-parameter methods, request/reply, dynamic sends, lifecycle ordering
  (ctor → onSpawn → messages), address passing, shutdown, `onException`.
- `registration.d` — message-method rules and hook wiring (launch/`onSpawn`,
  `onException`, `onUnhandledMessage`, `onExit`).
- `system.d` — spawning through the `System`, constructor semantics, self-send
  in `onSpawn`, requests from a manually driven actor, exit hooks.
- `actor.d` — `linkTo`/`monitor`, request chains, promise replies, address
  passing.
- `utility/limiter.d` — a real flow-control actor with its load test.

Run them with `dub test` in the mylib package root.
