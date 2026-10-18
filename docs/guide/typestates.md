# Typestates — endpoint lifecycle

`lockfree`'s multi-cardinality queues hand out *endpoints*. An
endpoint is a per-thread view that lets you push (producer) or pop
(consumer) safely. The endpoint lifecycle is enforced at compile time
by typestates: `Unbound → Bound → Closed`.

This page covers three things:

1. **The bare API** — `getProducer`, `bindToThread`, `close`. The
   building-block surface.
2. **The RAII wrapper** — `withBoundEndpoint`. Same API, scope-bound.
3. **The `Queueable[T]` concept** — for generic code that operates on
   any queue endpoint.

And a teaser for [chronos integration](#chronos-integration) at the end.

## Why typestates

A bound endpoint is *thread-affine*: the thread that called
`bindToThread()` is the only thread that can `push` / `pop` through
it. Violating thread-affinity is a use-after-something error class
(use-after-unregister, use-by-wrong-thread, double-bind, etc.).

The typestate machinery makes those errors compile-time:

- `push` and `pop` are defined ONLY on `Bound[…]`.
- `bindToThread` is defined ONLY on `Unbound[…]`.
- `close` is defined ONLY on `Bound[…]`.

You cannot push through an `Unbound` (no `bind`), and you cannot push
through a `Closed` (already released). The compiler refuses.

## The bare API

```nim
import lockfree
import lockfree/endpoint
import lockfree/role_tags

var q = newMpmcQueue[int, 16, 4, 4]()

# 1. Get an Unbound endpoint (on any thread).
var producer: Unbound[int, ProducerTag, …] = q.getProducer()

# 2. Hand off to the operating thread.
proc workerProc(p: ptr Unbound[…]) {.thread.} =
  var bound = p[].bindToThread()  # Unbound → Bound; registers with nebr
  bound.push(42)
  bound.close()                   # Bound → Closed; unregisters
```

The `Unbound → Bound` transition is the registration point. For the
unbounded multi-consumer arms, this is where the endpoint registers
with the internal nebr manager.

The `Bound → Closed` transition is the unregistration point. After
`close()`, the endpoint is consumed (its state is `Closed`); calling
any operation on it is a compile-time error.

## Sugar: `*Here` for same-thread bind

When the caller is also the operating thread, the explicit
`getProducer` + `bindToThread` is needlessly verbose. Use
`*Here`:

```nim
var producer = q.getProducerHere()  # Unbound + bindToThread in one
producer.push(42)
producer.close()
```

`getProducerHere()` and `getConsumerHere()` are sugar for the
same-thread shortcut.

## RAII wrapper: `withBoundEndpoint`

For scope-bound usage where the endpoint should always close at scope
exit (including on raised exceptions), use `withBoundEndpoint`:

```nim
import lockfree/typestates/with_bound

proc workerProc(q: ptr Queue[int, …]) {.thread.} =
  q[].withBoundEndpoint(producer):
    producer.push(42)
    # close() invoked automatically at scope exit, even on raised exceptions
```

The block introduces `producer` as a `Bound[…]` endpoint, bound to
the current thread, and ensures `close()` runs at scope exit. This is
the recommended pattern for new code unless you have a specific need
for the bare API (e.g. lifetime spanning multiple procs).

## The `Queueable[T]` concept

For generic code that operates on any bound endpoint (regardless of
queue type or cardinality), use the `Queueable[T]` concept:

```nim
proc pumpFrom[Q: Queueable[int]](source: var Q) =
  while true:
    let v = source.pop()
    if v.isNone: break
    process(v.get)
```

`Queueable[T]` matches any `Bound[T, _, _]` endpoint regardless of
cardinality, queue type (`BQueue` vs `Queue`), or backing storage.
This is the concept to write against when the cardinality is a
parameter of your code rather than a fixed design choice.

## Choosing among the three styles

| Style | Use when |
|---|---|
| Bare API | Endpoint lifetime spans multiple procs; you need explicit control of bind / close timing. |
| `withBoundEndpoint` | Endpoint lifetime fits a single block; you want exception-safe close. |
| `Queueable[T]` | Code is generic over queue type or cardinality. |

For most new code, prefer `withBoundEndpoint` for endpoint
construction and `Queueable[T]` for generic consumers.

## chronos integration

When compiled with `-d:lockfreeChronos` (or with `chronos` available
and auto-detected), `lockfree` exposes async-aware endpoint variants
under `lockfree/chronos`:

```nim
# With -d:lockfreeChronos
import lockfree
import lockfree/chronos

proc asyncWorker(q: AsyncQueue[int]) {.async.} =
  let v = await q.pop()
  await process(v)
```

The chronos adapter integrates the endpoint typestate with chronos's
`Future[T]` lifecycle: `await q.pop()` suspends until an item arrives,
and a cancelled future correctly closes the bound endpoint without
leaking a nebr registration. See [the chronos example](https://github.com/elijahr/lockfree/blob/devel/examples/06_chronos_async.nim)
for the full pattern.

The chronos dependency is **soft** — it is not in `lockfree.nimble`'s
`requires`. The adapter is enabled automatically if `chronos` is
present in the resolved import path, or explicitly via
`-d:lockfreeChronos`. Code that does not need async pays nothing.

## Universal Typestate Coverage & Domain Extension Constructs (v0.5.0+)

Starting in `v0.5.0`, `lockfree` generalizes the formal `Unbound → Bound → Closed` typestate model across **all** major concurrent collections and introduces first-class typestate domain extension constructs:

### 1. Universal Endpoint Lifecycle & Role Tags

The endpoint typestate (`Unbound[T, Tag, QueueT] → Bound[T, Tag, QueueT] → EndpointClosed[T, Tag, QueueT]`) is extended beyond basic queues to stacks, work-stealing deques, and concurrent hash tables using dedicated role tags:

| Primitive | Supported Role Tags | Acquisition Sugar | RAII Scope Template | Generic Concept |
| :--- | :--- | :--- | :--- | :--- |
| `BQueue` / `Queue` | `ProducerTag`, `ConsumerTag` | `getProducer`, `getConsumer` | `withBoundProducer`, `withBoundConsumer` | `Queueable[T]` |
| `BStack` / `TreiberStack` | `ProducerTag`, `ConsumerTag` | `getProducer`, `getConsumer` | `withBoundProducer`, `withBoundConsumer` | `Stackable[T]` |
| `ChaseLevDeque` | `DequeOwnerTag`, `DequeThiefTag` | `acquireOwner`, `acquireThief` | `withBoundOwner`, `withBoundThief` | `Stealable[T]` |
| `BTable` | `TableWriterTag`, `TableReaderTag` | `acquireWriter`, `acquireReader` | `withBoundWriter`, `withBoundReader` | `TableWritable`, `TableReadable` |

#### Compile-Time Role Safety

Role tags prevent invalid operations at compile time:
- A thief holding `Bound[T, DequeThiefTag, ...]` cannot call `pushBottom` or `popBottom`.
- A reader holding `Bound[K, TableReaderTag, ...]` cannot call `put` or `del`.
- Any attempt to invoke operations on un-bound or closed endpoints is rejected by 22 compile-time `{.error: ..., notATransition.}` guards in `src/lockfree/endpoint.nim`.
- Safety is validated by 24 negative compile-fail test cases in `tests/should_fail/runner.nim`.

### 2. First-Class Domain Typestate Constructs (`typestate_constructs.nim`)

`lockfree` exports high-level constructs for coordinating stateful workflows across concurrent channels:

- **`TypestateGate[Base, InState, OutState, Transport]`**: Enforces that values entering a channel or stack undergo a compile-time state transition when transferred across threads (`sendState`, `trySendState`, `recvState`, `tryRecvState`, `stealState`).
- **`TypestatePipelineStage[Base, InState, MidState, OutState, InTransport, OutTransport]`**: Chains multi-stage actor and pipelined transformations where state transitions are guaranteed by the type system (`stepStage`).

### 3. SMR NEBR Domain Typestate State Machines

The safe memory reclamation engine (`lockfree/smr/nebr`) uses 9 specialized compile-time typestates to verify critical concurrency protocols:

- **`RegistrationContext`**: Governs thread registration lifecycle (`Unpinned → Pinned`).
- **`EpochGuardContext`**: Enforces balanced epoch pinning (`Unpinned ↔ Pinned`).
- **`RetireContext`**: Tracks retired memory blocks (`Pinned → RetireReady → BagFull → Flushed`).
- **`ReclaimContext`**: Verifies epoch advancement before freeing blocks (`ReclaimIdle → EpochChecked → BagScanned → ReclaimComplete`).
- **`NeutralizeContext`**: Tracks OS thread preemption recovery (`Running → Neutralized → Recovered`).
- **`AdvanceContext`**: Enforces global epoch progression (`CanAdvance → Advanced | Blocked`).
- **`ManagerContext`**: SMR manager lifecycle (`ManagerUninitialized → ManagerActive → ManagerShutdown`).
- **`SignalHandlerContext`**: Signal registration (`HandlerUninstalled → HandlerInstalled → HandlerRemoved`).
- **`SlotContext`**: Thread slot pool states (`SlotFree → SlotReserved → SlotActive → SlotDraining → SlotFree`).

### 4. CI Typestate Verification

All 86 source files and 208 state transitions are continuously checked in CI:
```bash
typestates verify -W --format=github src/
```

## Further reading

- [`api/typestates`](../api/typestates.md) — endpoint claim state (`Unbound → Bound → Closed`) and the `with_bound` scope macro reference.
- [nebr](smr/nebr.md) — what the `Unbound → Bound` transition registers with.

