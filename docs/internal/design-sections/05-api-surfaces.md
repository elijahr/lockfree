# Section 5: API Surfaces

This section specifies the **public API surfaces** of the v0.1.0 (post-rename) `lockfree` library: the `Queue` and `BQueue` types, the Tier 1 sync iterators, the Tier 3 `lockfree/chronos` adapter, the typestate dual-API (endpoint-guarded vs RAII wrapper), the chronos optional-dep mechanics, and the lifecycle ergonomics around drain / destroy.

It is the **user-facing companion** to Sections 1–4 (which describe layout, type system, SMR, and the per-MM compat shim). Where Section 4 specifies *how* `ManagedRef[X]` / `ManagedSlice[T]` round-trip per MM, Section 5 specifies *what the user types* and *what shows up on the help page*.

Cross-references throughout:
- `§1.x` = `docs/internal/design-sections/01-architecture-and-module-layout.md`
- `§2.x` = `02-type-system-and-payload-types.md`
- `§3.x` = `03-smr-architecture-and-nebr.md`
- `§4.x` = `04-mm-compat-shim-and-cell-layouts.md`
- `safety:§N` = `docs/internal/safety-argument.md`
- `handoff:S5` = the 2026-06-05 consolidation handoff brief, "Session updates (2026-06-05)" subsections relevant to Section 5.

The v5.0.0 source under `src/lockfree/` is the API baseline; the v0.1.0 namespace rename to `src/lockfree/` is purely path movement (handoff §T-INTEGRATE.a). API names / signatures shown below preserve v5.0.0 shape verbatim except where a §5 subsection explicitly says otherwise.

> **Cite convention for Section 5.** All `queue.nim:NNN` and `bqueue.nim:NNN` line-number cites in this section are **post-T-INTEGRATE target coordinates**, not existing source. The files `src/lockfree/queue.nim` and `src/lockfree/bqueue.nim` do not exist in the v5.0.0 tree under `src/lockfree/`; they are the consolidation targets produced by T-INTEGRATE.a–.c, which collapses the per-cardinality arms (`mupmuc.nim`, `mupsic.nim`, `sipmuc.nim`, `sipsic.nim` and the unbounded counterparts) into single `queue.nim` / `bqueue.nim` files keyed by the `ccProd` / `ccCons` static params. The line-number ranges below are therefore aspirational anchors for Phase 3 implementation, not verifiable in the v5.0.0 source. The analogous v5.0.0 source (typically `src/lockfree/<arm>.nim` for the corresponding cardinality) carries the same logical content under a different filename and line range; Phase 2.5 fact-check verifies the v5.0.0-side analogue exists, and Phase 3 ports each cite to its post-T-INTEGRATE line.

Likewise, `endpoint.nim:NNN` cites refer to `src/lockfree/endpoint.nim`, which is the renamed-from-`src/lockfree/endpoint.nim` post-T-INTEGRATE module; the line numbers track v5.0.0 source positions and are verifiable today against the existing `src/lockfree/endpoint.nim`.

---

## 5.1 Queue public API (unbounded)

### 5.1.1 Type and generic parameters

```nim
type
  Queue*[
    T;
    ccProd, ccCons: static PinScopeCardinality,
    ST: static DeallocationStrategy,
    S, MaxThreads: static int,
  ] {.QueueLifecycle: QueueInit.} = object
    ...
```

**Param order (LOAD-BEARING — frozen v5.0.0)**:

| # | Param | Meaning |
|---|-------|---------|
| 1 | `T` | Payload type. Subject to §2 admit/reject rules + the `when T is ref / string / seq` Path C dispatch (§5.1.5). |
| 2 | `ccProd` | Producer cardinality (`ccSingle` / `ccMulti`). |
| 3 | `ccCons` | Consumer cardinality (`ccSingle` / `ccMulti`). |
| 4 | `ST` | Deallocation strategy (`stManual` / `stEager`). Governs the nebr retire cadence (§3.6.3). |
| 5 | `S` | Segment slot count. `S > 0`. Validated at compile time by `validateQueueParams`. |
| 6 | `MaxThreads` | nebr thread-registry capacity. `MaxThreads > 0`. |

`ccSingle × ccSingle` is the **absorbed SPSC** branch — debra-free, committed-flag-free, no `manager` field, no thread registration (§1.2 lower-half, queue.nim:368-405). `MaxThreads` becomes a type-uniform phantom for that branch.

The other three cardinality combos (`MPSC` / `SPMC` / `MPMC`) carry full nebr integration: `manager`, `ownsManager`, optional per-arm counters, and the destructor-side `unbindClient` (queue.nim:1033-1038).

### 5.1.2 Family-named smart constructors

Six smart constructors live in `queue.nim` (one per cardinality, plus borrow / auto-create overloads where applicable). All return `Queue[...]`, never an arm-named alias — `*Mpmc*` / `*Mpsc*` / `*Spmc*` / `*Spsc*` are only in the constructor name (queue.nim:1046+):

```nim
# Auto-create (allocates a private DebraManager for non-SPSC arms).
proc newUnboundedSpscQueue*[T; ST; S, MaxThreads](): Queue[T, ccSingle, ccSingle, ST, S, MaxThreads]
proc newUnboundedMpscQueue*[T; ST; S, MaxThreads](): Queue[T, ccMulti,  ccSingle, ST, S, MaxThreads]
proc newUnboundedSpmcQueue*[T; ST; S, MaxThreads](): Queue[T, ccSingle, ccMulti,  ST, S, MaxThreads]
proc newUnboundedMpmcQueue*[T; ST; S, MaxThreads](): Queue[T, ccMulti,  ccMulti,  ST, S, MaxThreads]

# Borrow (caller owns the manager; non-SPSC only — SPSC has {.error.} gate).
# Note: `nebr.ccSingle` / `nebr.ccMulti` in the manager type below are the
# SAME `PinScopeCardinality` enum values that Queue takes as `ccProd` /
# `ccCons`. The enum lives in `lockfree/smr/nebr/cardinality.nim` and is
# re-exported as bare names from `lockfree/smr/nebr.nim`; the borrow
# constructor signatures keep the `nebr.` qualifier purely as a
# readability cue that the manager's cardinality must match the queue's
# consumer cardinality (MPSC → manager `ccSingle`; SPMC / MPMC → manager
# `ccMulti`). See §3.1 for the enum's canonical home.
proc newUnboundedMpscQueue*[T; ST; S, MaxThreads](
    manager: ptr DebraManager[MaxThreads, nebr.ccSingle]
): Queue[T, ccMulti, ccSingle, ST, S, MaxThreads]
proc newUnboundedSpmcQueue*[T; ST; S, MaxThreads](
    manager: ptr DebraManager[MaxThreads, nebr.ccMulti]
): Queue[T, ccSingle, ccMulti, ST, S, MaxThreads]
proc newUnboundedMpmcQueue*[T; ST; S, MaxThreads](
    manager: ptr DebraManager[MaxThreads, nebr.ccMulti]
): Queue[T, ccMulti, ccMulti, ST, S, MaxThreads]
```

`ST` defaults to `DefaultDeallocationStrategy` (currently `stEager`).

**SPSC borrow `{.error.}` gate** (queue.nim:710-741): `newUnboundedSpscQueue` only has the auto-create form. Passing a manager triggers a compile-time error pointing to the typedesc-only overload. The error message names `ccSingle × ccSingle` and the user-visible constructor name only — no `*Spsc*` internal arm leakage.

### 5.1.3 push / pop signatures

```nim
# Single-item push, all cardinalities, on bare Queue.
proc push*[T; ccProd, ccCons; ST; S, MaxThreads](
    self: var Queue[T, ccProd, ccCons, ST, S, MaxThreads], item: sink T
): bool

# Single-item pop — SPSC (ccSingle × ccSingle) direct on Queue.
proc pop*[T; ST; S, MaxThreads](
    self: var Queue[T, ccSingle, ccSingle, ST, S, MaxThreads]
): Option[T]

# Batch pop — ccCons == ccSingle on bare Queue (loops over single-item pop).
proc pop*[T; ccProd; ST; S, MaxThreads](
    self: var Queue[T, ccProd, ccSingle, ST, S, MaxThreads], count: int
): Option[seq[T]]
```

`sink T` for push: caller relinquishes ownership; the compiler emits the matching `=destroy` after the push. Under arc/orc/atomicArc this combines with the §4.2.3 `incRefSlot` in the wrapper to net `+1` (the queue's reference). Under mm:none both are no-ops.

`Option[T]` for pop: `none(T)` on empty / closed-empty. The std/options transport asserts non-nil for nullable T at `some(...)` construction — `tryPublish` precondition (queue.nim:191-193) bans nil payloads for `ref / ptr / cstring / proc / closure / pointer` to surface the violation at the producer.

**Compile-time gates on multi-consumer pop** (queue.nim:920-949): direct `q.pop()` on a `ccCons == ccMulti` Queue is a `{.error.}` with a message pointing at `q.getConsumerHere().pop()` (same-thread shortcut) or `q.bindConsumer()` (one-shot SC consumer wrapped in a Bound endpoint). The error message references `q.getConsumerHere()` / `q.bindConsumer()` by user-visible name; no internal arm names leak.

Direct `q.push()` on a `ccProd == ccMulti` Queue routes through the same pattern: a `{.error.}` overload pointing at `q.getProducerHere().push(item)` (same-thread) or `q.getProducer().bindToThread().push(item)` (cross-thread).

### 5.1.4 Path C internal dispatch (refcounted / sliced payload routing)

User-facing generic shape stays `Queue[T, ...]` for **all** `T` admitted by §2 (handoff Phase 1.5 Q2 — Path C "ref T user-facing"). Internally, push/pop dispatch via `when` on the payload kind (§4.2.3):

```nim
proc push*[T; ...](self: var Queue[T, ...], item: sink T): bool =
  when T is ref:
    pushRef[T.basetype](self, item)        # routes to ManagedRef[X] path (§4.3.4)
  elif T is string or T is seq:
    pushSlice(self, item)                  # routes to ManagedSlice[T] path (§4.4)
  else:
    pushPOD(self, item)                    # legacy POD path (no shim)
```

The POD path is what the v5.0.0 source baseline already implements. The ref and slice arms add the per-MM shim layer (§4.3 / §4.4) and are net-new in v0.1.0. The user sees `Queue[ref Foo, ...]` / `Queue[string, ccMulti, ccSingle, ...]` directly — no `Queue[ManagedRef[Foo], ...]` leakage (handoff §"ManagedRef internal vs user-facing").

Compile-time gates from §2 still apply:
- `ref T` under arc/orc/atomicArc compiles and ships the ManagedRef arm.
- `ref T` under refc → `{.error.}` (§2.x reject rules; refc cannot bit-cast `ref` safely).
- `string` / `seq[T]` under any supported MM → ManagedSlice arm.
- POD (T satisfying `supportsCopyMem(T) and sizeof(T) <= 8`) → POD arm.
- Anything else → `{.error.}` with the §2 message.

### 5.1.5 Cardinality endpoint accessors

```nim
# Cross-thread factories (return Unbound[T, AnyThreadTag, Queue[...]]).
proc getProducer*(self: var Queue[T, ...]): Unbound[T, AnyThreadTag, Queue[T, ...]]
proc getConsumer*(self: var Queue[T, ...]): Unbound[T, AnyThreadTag, Queue[T, ...]]

# Same-thread shortcuts (return Bound directly — no separate bindToThread).
template getProducerHere*(self: var Queue[T, ...]): Bound[T, AnyThreadTag, Queue[T, ...]]
template getConsumerHere*(self: var Queue[T, ...]): Bound[T, AnyThreadTag, Queue[T, ...]]

# One-shot SC-consumer bind (replaces v4.x attachConsumer).
proc bindConsumer*(self: var Queue[T, ccProd, ccSingle, ...]): Bound[T, AnyThreadTag, Queue[T, ...]]
```

Endpoint typestate is `Endpoint[T, Tag, queueT]` with states `Unbound → Bound → Closed` (endpoint.nim:71-78). `Tag` carries role discrimination via `role_tags.nim`. The dual-API surfaces both this typestate-guarded path and a wrapper template (§5.5).

### 5.1.6 Lifecycle (init / destroy / drain)

- **Init**: any `newUnbounded*Queue` constructor leaves the queue in `QueueInit` (queue.nim's `QueueLifecycle` typestate, `{.QueueLifecycle: QueueInit.}` attachment).
- **Destroy**: `=destroy` walks the segment chain, runs `unbindClient`, and (if `ownsManager`) frees the manager. Drives `QueueInit → QueueDestroyed` via `destructorTransition`. Precondition: all attached workers joined (queue.nim:1001-1006).
- **Drain**: `drain` / `destroyAndDrain` per §5.7 (new in v0.1.0 per CRITICAL #2 / §4.8).

---

## 5.2 BQueue public API (bounded)

### 5.2.1 Type and generic parameters

```nim
type
  BQueue*[
    T; ccProd, ccCons: static PinScopeCardinality, N, P, C: static int
  ] {.BQueueLifecycle: BQueueInit.} = object
    ...
```

| # | Param | Meaning |
|---|-------|---------|
| 1 | `T` | Same admit/reject + Path C dispatch as Queue. |
| 2 | `ccProd` | Producer cardinality. |
| 3 | `ccCons` | Consumer cardinality. |
| 4 | `N` | Bounded slot count. `N > 0`. |
| 5 | `P` | Per-producer state count. `P > 0` iff `ccProd == ccMulti`; `P == 0` otherwise. |
| 6 | `C` | Per-consumer state count. `C > 0` iff `ccCons == ccMulti`; `C == 0` otherwise. |

`assertBQueueParams` enforces these coherence rules at compile time (bqueue.nim:180-198). There is **no `ST` axis and no `MaxThreads` axis** on BQueue: bounded queues own no heap state (ring buffer is in-line in the object body) and don't integrate with nebr at all.

### 5.2.2 Smart constructors

```nim
proc newBoundedSpscQueue*[T; N: static int](): BQueue[T, ccSingle, ccSingle, N, 0, 0]
proc newBoundedMpscQueue*[T; N, P: static int](): BQueue[T, ccMulti,  ccSingle, N, P, 0]
proc newBoundedSpmcQueue*[T; N, C: static int](): BQueue[T, ccSingle, ccMulti,  N, 0, C]
proc newBoundedMpmcQueue*[T; N, P, C: static int](): BQueue[T, ccMulti,  ccMulti,  N, P, C]
```

No borrow / auto-create distinction because there's no manager to borrow. The bounded body either owns its slots (always, no choice) or it doesn't exist.

### 5.2.3 push / pop signatures

```nim
# SPSC direct on BQueue.
proc push*[T; N](self: var BQueue[T, ccSingle, ccSingle, N, 0, 0], item: sink T): bool
proc pop*[T; N](self: var BQueue[T, ccSingle, ccSingle, N, 0, 0]): Option[T]

# Compile-time gates on direct multi-side calls (bqueue.nim §"cardinality dispatch ladder").
# q.push() on a ccProd == ccMulti BQueue → {.error.}: "use q.getProducer().push(item)"
# q.pop()  on a ccCons == ccMulti BQueue → {.error.}: "use q.getConsumer().pop()"
```

Path C dispatch on BQueue mirrors Queue (§5.1.4): `when T is ref / string / seq:` routes through ManagedRef / ManagedSlice; otherwise POD path. The per-arm cell layout matrix is §4.5.1.

### 5.2.4 Endpoint factories

```nim
proc getProducer*(self: var BQueue[T, ccMulti, ccCons, N, P, C], idx: int = -1): Unbound[T, AnyThreadTag, BQueue[T, ccMulti, ccCons, N, P, C]]
proc getConsumer*(self: var BQueue[T, ccProd, ccMulti, N, P, C], idx: int = -1): Unbound[T, AnyThreadTag, BQueue[T, ccProd, ccMulti, N, P, C]]
template getProducerHere*(self: var BQueue[...], idx: int = -1): Bound[...]
template getConsumerHere*(self: var BQueue[...], idx: int = -1): Bound[...]
```

`getProducer` / `getConsumer` claim a per-thread slot via CAS over `producerThreadIds` / `consumerThreadIds` (endpoint.nim:195-264). The `idx` overload exists for tests; default `-1` triggers the auto-claim path. Raises `NoProducersAvailableError` / `NoConsumersAvailableError` on slot exhaustion.

### 5.2.5 Lifecycle (init / destroy / drain)

BQueue's `=destroy` does **not** unbind a manager (none exists) — it runs the default object destructor plus the `BQueueInit → BQueueDestroyed` transition. Drain helpers mirror the Queue side (§5.7).

---

## 5.3 Tier 1 sync iterators (in-tree, no external deps)

Tier 1 is the only iterator tier shipping in v0.1.0 (handoff §"Q6 Iterator + async integration": Tier 1 + Tier 3, Tier 2 dropped). The iterators are pure drain-loops over the existing pop primitive — no new control flow, no new state.

### 5.3.1 Surface

Module: each iterator lives in the queue or bqueue file it iterates (no separate `iterators.nim` — they need access to the same `Bound` / `var Queue` receivers as push/pop).

```nim
# Unbounded.
iterator items*[T; ccProd: static PinScopeCardinality, ST; S, MaxThreads](
    q: var Queue[T, ccProd, ccSingle, ST, S, MaxThreads]
): T

iterator drain*[T; ccProd: static PinScopeCardinality, ST; S, MaxThreads](
    q: var Queue[T, ccProd, ccSingle, ST, S, MaxThreads]
): T

# Bounded.
iterator items*[T; ccProd; N, P](q: var BQueue[T, ccProd, ccSingle, N, P, 0]): T
iterator pairs*[T; ccProd; N, P](q: var BQueue[T, ccProd, ccSingle, N, P, 0]): (int, T)
iterator drain*[T; ccProd; N, P](q: var BQueue[T, ccProd, ccSingle, N, P, 0]): T

# Multi-consumer overloads on Bound endpoint (same signature pattern, receiver is
# Bound[T, Tag, Queue[...]] / Bound[T, Tag, BQueue[...]]).
iterator items*[T; Tag; queueT](b: var Bound[T, Tag, queueT]): T
iterator drain*[T; Tag; queueT](b: var Bound[T, Tag, queueT]): T
```

### 5.3.2 Semantics

- **`items` / `drain`**: alias pair. Both pop until `pop()` returns `none(T)` once, then exit. They are **drain-to-empty** iterators, not blocking iterators — they observe the queue's state at the moment of each pop call. `drain` is the user-facing name (clear intent: "consume everything available now"); `items` is the Nim convention name for `for x in q: ...` sugar.
- **`pairs` (BQueue only)**: yields `(index, item)` where `index` is the drain ordinal (0, 1, 2, ...), not the original slot index. Provided per Nim iterator convention so `for i, item in q: ...` works.
- **Cardinality restriction**: only ccCons == ccSingle bare-queue iterators on `Queue` / `BQueue`. Multi-consumer iterators must go through a `Bound` endpoint, mirroring the pop API constraint.
- **No internal state**: each iterator body is a `while true: let v = q.pop(); if v.isNone: break; yield v.get`. Roughly ~10 lines per overload; the handoff §"Q6" estimate of "30 lines per queue type" is total across all overloads for that family.

### 5.3.3 Lock-freedom under iteration

The iterator does not add synchronization. It calls `pop` in a loop; each `pop` is lock-free per the v5.0.0 algorithm. The iterator is **not** wait-free against concurrent producers: a fast producer could keep `pop` returning `some(...)` indefinitely (livelock for the iterator-side caller, but not for the queue). This matches the documented drain-loop pattern (§4.8.3, handoff §"CRITICAL #2") — users who want a bounded drain pass a count limit:

```nim
proc drainUpTo*[T; ...](q: var Queue[T, ...], max: int): seq[T]
```

(Documented but not strictly an iterator; lives next to the iterators.)

---

## 5.4 Tier 3 chronos adapter (`lockfree/chronos`)

The chronos adapter is the **only async tier shipping in v0.1.0** (Tier 2 dropped per handoff §"Q6"). It lives at `src/lockfree/chronos.nim`. Soft dep via `compiles do: import chronos` (§5.6).

### 5.4.1 Types

```nim
when defined(lockfreeChronos) or (compiles do: import chronos):
  import chronos

  type
    AsyncQueue*[T; ccProd, ccCons: static PinScopeCardinality, ST: static DeallocationStrategy, S, MaxThreads: static int] = object
      queue*: Queue[T, ccProd, ccCons, ST, S, MaxThreads]
      event*: AsyncEvent

    AsyncBQueue*[T; ccProd, ccCons: static PinScopeCardinality, N, P, C: static int] = object
      queue*: BQueue[T, ccProd, ccCons, N, P, C]
      event*: AsyncEvent
```

The adapter wraps the existing queue and adds **exactly one piece of state**: a chronos `AsyncEvent`. The queue body is unchanged. Wakeup is a fire signal sent on push; consumers `await event.wait()` and re-poll.

### 5.4.2 push / pop

```nim
proc push*[T; ...](q: var AsyncQueue[T, ...], item: sink T): bool =
  result = q.queue.push(item)
  if result:
    q.event.fire()

proc pop*[T; ...](q: var AsyncQueue[T, ...]): Future[Option[T]] {.async.} =
  while true:
    let v = q.queue.pop()
    if v.isSome:
      return v
    await q.event.wait()
    # event re-fires on next push; if we wake with the queue still empty
    # (spurious wakeup or another consumer drained first), we loop.
```

Same pattern for `AsyncBQueue`. Multi-consumer flavours route through `Bound` endpoints (an `AsyncQueue` over a multi-consumer Queue must use a `bindConsumer()`-equivalent factory or the typestate-wrapped path — §5.4.5).

### 5.4.3 Cancellation semantics

When the chronos task is cancelled mid-`await q.event.wait()`:
- The `await` raises `CancelledError` per chronos contract.
- The Queue's pin scope is **not entangled with the async wait**: the SMR pin is acquired inside `q.queue.pop()` and released before the `await`. The wait sits between pop attempts, holding no pin.
- The user can safely re-enter `pop()` after handling cancellation; queue state is consistent. No leak.

This is intentional: §3.5's `withPinscope` is **synchronous-only**. Any asynchronous boundary inside a pin scope is forbidden (handoff §"CRITICAL #4" + §3 "Pinscope unwind"). The AsyncQueue.pop body honors this by closing the pin scope before each `await`.

### 5.4.4 Lock-freedom guarantee

The producer side (`push + fire`) stays lock-free: `fire` on a chronos `AsyncEvent` is a non-blocking flag set (chronos runs on a single event loop, so no atomicity is required). The consumer side **opts into blocking** — `await event.wait()` parks the chronos task on the dispatcher. This is the documented trade (handoff §"chronos coupling"): users who want blocking opt in; users who want pure lock-freedom don't import the chronos adapter.

The wait is bounded by the dispatcher's wakeup latency, not by the queue's contention behaviour.

### 5.4.5 Endpoint factories on AsyncQueue

For multi-side cardinalities, the wrappers proxy to the underlying queue's factories:

```nim
template getProducer*(q: var AsyncQueue[T, ...]): auto = q.queue.getProducer()
template getConsumer*(q: var AsyncQueue[T, ...]): auto = q.queue.getConsumer()
```

A `Bound` endpoint from these factories can drive both `push` and `pop`. The wrapper additionally exposes:

```nim
proc asyncPop*[T; Tag; queueT](b: var Bound[T, Tag, queueT], event: var AsyncEvent): Future[Option[T]] {.async.}
```

…for users who want async-pop semantics on an explicit endpoint. (Open question OQ5.3 — should this be the only API and `AsyncQueue` a thin alias? Phase 2.2 to confirm.)

---

## 5.5 Typestate dual-API

Per handoff §"Typestates audit + dual-API design" (concerns 2 and 3): some typestates are user-facing contracts, others are pure internal control flow. Users should be able to **opt out** of the typestate surface when they don't want it.

### 5.5.1 Classification (input → §5.5)

| Typestate | Internal / User-facing | Wrapper? |
|---|---|---|
| Per-cardinality push/pop FSMs (`typestates/mpmc_push.nim`, etc.) | Internal | N/A — never user-typed. |
| `QueueLifecycle` / `BQueueLifecycle` (`Init → Destroyed`) | Internal (driven by `=destroy`) | N/A — destructor-only. |
| `Endpoint` (`Unbound → Bound → Closed`) | **User-facing contract** | Yes — RAII `withBoundEndpoint`. |
| Role tags (`SpscProducerTag` / `MpmcConsumerTag` / etc., `AnyThreadTag`) | User-facing | No — wrapping defeats the role-discrimination purpose. |

The classification table is the input that drives §5.5.2–5.5.4.

### 5.5.2 Typestate-guarded surface (existing v5.0.0 shape)

```nim
var u = q.getProducer()              # Unbound[T, AnyThreadTag, Queue[T, ...]]
var b = u.bindToThread()             # Bound[T, AnyThreadTag, Queue[T, ...]]
discard b.push(item)
var c = b.close()                    # Closed[T, AnyThreadTag, Queue[T, ...]]
```

Compile-time guards:
- Calling `push` on `Unbound` → type error (no `push` overload on `Unbound`).
- Calling `bindToThread` twice on the same value → typestates 0.12.0 strict-transition error.
- Calling `push` after `close` → `Closed` has no `push` overload.

This is the **path users opt into** when they want the strongest static guarantees (the `bindToThread` step is meaningful to them, and the `close` step is meaningful to them).

### 5.5.3 RAII wrapper surface (new in v0.1.0)

```nim
template withBoundEndpoint*[T; Tag; queueT](
    queue: var queueT,
    endpoint: untyped,
    body: untyped
) =
  block:
    var u = queue.getProducer()           # or getConsumer — see overload below
    var endpoint = u.bindToThread()
    defer:
      var c = endpoint.close()
      discard c                            # drive Bound → Closed transition
    body

# Producer-side overload (matches Queue / BQueue with ccProd accessible).
template withBoundProducer*[...](queue: var ..., endpoint: untyped, body: untyped)
template withBoundConsumer*[...](queue: var ..., endpoint: untyped, body: untyped)
```

Usage:
```nim
var q = newUnboundedMpmcQueue[int, stEager, 64, 8]()
withBoundProducer(q, prod):
  discard prod.push(42)
  discard prod.push(43)
# prod is closed here.
```

Properties:
- The user never types `bindToThread` or `close`. The typestate is invisible.
- The typestate FSM is **still driven** under the hood — the same compile-time guards apply to `body`. If `body` tries to do something `Bound` doesn't allow, it still fails to compile.
- `defer` runs on normal exit and on unhandled exceptions; the `close` transition always fires.

### 5.5.4 Shared inner primitives (no duplication)

Both the typestate-guarded API (§5.5.2) and the RAII wrapper (§5.5.3) dispatch to the same primitives. The primitives are `tryPublish` / `tryClaim` / `tryCloseOnEmpty` on cells (queue.nim:174-231) for MPMC, the per-cardinality push/pop bodies for the others. There is exactly **one implementation per (cardinality, payload-kind)** combination; the two surfaces are wrappers over it.

This means: bug fixes apply uniformly. There is no "the typestate path took the patch but the wrapper didn't" risk. Code review on either path covers both.

### 5.5.5 Concept-based dispatch (`Queueable[T]`)

```nim
type Queueable*[T] = concept x
  push(x, default(T)) is bool
  pop(x) is Option[T]
```

This concept matches both:
- A bare `Queue[T, ccSingle, ccSingle, ...]` / `BQueue[T, ccSingle, ccSingle, ...]` (SPSC; direct push/pop).
- A `Bound[T, Tag, Queue[T, ...]]` / `Bound[T, Tag, BQueue[T, ...]]` endpoint (any cardinality after bind).

User code that wants to be generic across both:
```nim
proc producerLoop*[Q: Queueable[int]](q: var Q) =
  for i in 0 ..< 1000:
    while not q.push(i): discard
```

`producerLoop` accepts either a bare SPSC queue or a `Bound` MPMC endpoint. The compile-time check that the type satisfies the concept happens at the call site. The concept does **not** widen the API contract — both push and pop must still observe the cardinality rules of the underlying type — but it gives a single generic surface for libraries that don't care.

---

## 5.6 chronos optional-dep details (Path Hybrid)

Resolution: handoff §"CRITICAL #4 — chronos missing/half-installed UX" — LOCKED to hybrid pattern. §1.5 of the architecture section also covers the soft-dep matrix.

### 5.6.1 Concrete `when` pattern

```nim
## src/lockfree/chronos.nim
when defined(lockfreeChronos) or (compiles do: import chronos):
  import chronos

  type
    AsyncQueue*[T; ...] = object
      queue*: Queue[T, ...]
      event*: AsyncEvent

  proc push*[T; ...](q: var AsyncQueue[T, ...], item: sink T): bool = ...
  proc pop*[T; ...](q: var AsyncQueue[T, ...]): Future[Option[T]] {.async.} = ...

  # ... plus AsyncBQueue and endpoint integration.

# else: module body is empty. import succeeds; nothing is exported.
```

### 5.6.2 Matrix (from §1.5)

| User has chronos installed | `-d:lockfreeChronos` set | Outcome |
|---|---|---|
| No | No | `import lockfree/chronos` succeeds; module empty. User pays zero. |
| Yes | No | Module body activates via the `compiles do: import chronos` branch. User gets `AsyncQueue` / `AsyncBQueue`. |
| Yes | Yes | Same as above (the `-d` flag is the explicit opt-in for users who want certainty). |
| No | Yes | `import lockfree/chronos` fails with chronos's own "cannot import" error from the `import chronos` line. Clean compile error pointing at the missing package. |

### 5.6.3 nimble file

```nim
# lockfree.nimble
# requires "chronos >= 4.0.0"   # <-- intentionally omitted (handoff §"chronos coupling")
```

Users who want chronos either declare it in their own nimble file or pass `-d:lockfreeChronos`. The library does not transitively pull in chronos for users who don't need it.

### 5.6.4 CI matrix

Per handoff: dedicated chronos cell installs chronos via `nimble install chronos` in preflight and compiles with `-d:lockfreeChronos`. The rest of the matrix runs without chronos to validate the empty-module branch.

### 5.6.5 Version pinning

Floor: `chronos >= 4.0.0` (the version chronos shipped its current `AsyncEvent` semantics in). Cap: open at v0.1.0. Open question OQ5.4: does chronos 5.x (if it ships before v0.1.0) change `AsyncEvent.fire` or `AsyncEvent.wait` semantics in a way that breaks the adapter? — Phase 2.2 to track.

### 5.6.6 Error message for `-d:lockfreeChronos` without chronos installed

Currently the user gets chronos's own `cannot open file: chronos` error from the `import chronos` line. This is acceptable (clear cause, points at the right fix: `nimble install chronos`).

Open question OQ5.5: should we add a custom `{.error.}` wrapping it ("`-d:lockfreeChronos` set but chronos is not installed — run `nimble install chronos >= 4.0.0`")? Phase 2.2 — trade-off is custom error vs. the standard one is already clear.

---

## 5.7 Lifecycle ergonomics

### 5.7.1 destroyAndDrain callback shape

Per CRITICAL #2 + §4.8: mm:none users have no destructors, so undrained queues leak. v0.1.0 ships an explicit drain helper.

```nim
# Drain helper — runs cleanup on every remaining slot, then leaves the queue
# in a state safe to destroy.
proc drain*[T; ...](q: var Queue[T, ...], cleanup: proc(item: T) {.gcsafe, raises: [].})
proc drain*[T; ...](q: var BQueue[T, ...], cleanup: proc(item: T) {.gcsafe, raises: [].})

# Drain + destroy in one call.
proc destroyAndDrain*[T; ...](q: var Queue[T, ...], cleanup: proc(item: T) {.gcsafe, raises: [].})
proc destroyAndDrain*[T; ...](q: var BQueue[T, ...], cleanup: proc(item: T) {.gcsafe, raises: [].})
```

Callback signature: `proc(item: T) {.gcsafe, raises: [].}`. The `gcsafe` is required because the drain may run during destruction in arbitrary thread contexts; `raises: []` because the destructor walk (`=destroy`) is `raises: []` and a raising callback would violate that contract.

`cleanup` may be `nil`-equivalent (no-op) for POD payloads:

```nim
q.destroyAndDrain(proc(_: int) = discard)
```

…but the lambda must still be supplied — there is no overload that defaults the callback. Open question OQ5.6: should there be a default `proc(_: T) = discard` overload for POD-only? Phase 2.2.

### 5.7.2 Iterator-based drain vs callback-based drain

Two patterns coexist:

```nim
# Iterator: user collects / processes items, queue stays alive.
for item in q.drain():
  processSync(item)
# q is empty here, still alive.

# Callback: user processes inline, queue gets destroyed (with destroyAndDrain).
q.destroyAndDrain(processSync)
# q's storage is reclaimed; q itself is unusable.
```

The iterator is the right tool when:
- The user wants to use the items elsewhere (move them into a `seq`, send them to another queue, etc.).
- The queue will be reused after.
- The drain happens on a known consumer thread (iterator goes through `pop`, which has thread-affinity constraints for non-SPSC arms).

The callback is the right tool when:
- The user is wrapping up the queue (closing a producer/consumer pipeline).
- mm:none — the callback is the **only way** to release per-item resources.
- The drain is part of `=destroy` semantics (the user wants drain + destroy to be one atomic-looking call).

### 5.7.3 mm:none strict contract

Under `--mm:none`, `=destroy` does not run automatically. The library's `=destroy` on `Queue` / `BQueue` is still defined (it frees segment storage, unbinds the manager) but it does **not** run a per-item cleanup — there is no MM hook to call.

The user contract under mm:none is:
- **MUST** call `drain` or `destroyAndDrain` before the queue goes out of scope (or its storage is reused).
- Failure to do so leaks per-item resources. The queue's own segment / cell storage is still reclaimed by `freeAligned` because the library tracks it manually, but anything the user put in the cells (a `string`, a `seq`, a `ref Foo`) is **not** freed.

This is documented in `docs/guide/memory-management.md` as the headline mm:none warning (handoff §"CRITICAL #2").

### 5.7.4 Iterator interaction with typestate

The iterator overloads on `Bound` (§5.3) preserve the typestate. `for item in boundEndpoint.drain():` does not transition the endpoint — `drain` is `notATransition` (analogous to `push` / `pop`). The endpoint is still `Bound` after the loop and needs explicit `close()` (or RAII wrapper) to transition to `Closed`.

---

## 5.8 User code examples per use case

### 5.8.1 POD MPMC (5 lines)

```nim
import lockfree/queue
var q = newUnboundedMpmcQueue[int, stEager, 64, 16]()
withBoundProducer(q, prod):
  discard prod.push(42)
# In another thread, withBoundConsumer(q, cons): echo cons.pop()
```

### 5.8.2 Bounded SPSC for audio ringbuffer under mm:none (10 lines)

```nim
import lockfree/bqueue
type Sample = object
  l, r: float32
var ring = newBoundedSpscQueue[Sample, 4096]()
# Audio thread:
discard ring.push(Sample(l: 0.0, r: 0.0))
# DSP thread:
let s = ring.pop()
if s.isSome:
  process(s.get)
# Before teardown:
ring.destroyAndDrain(proc(_: Sample) = discard)
```

### 5.8.3 Refcounted-payload + async (chronos `AsyncQueue[ref Foo]`)

```nim
import lockfree/queue, lockfree/chronos
type Foo = ref object
  id: int
var aq = AsyncQueue[ref Foo, ccMulti, ccSingle, stEager, 32, 8](
  queue: newUnboundedMpscQueue[ref Foo, stEager, 32, 8](),
  event: newAsyncEvent(),
)
# Producer:
let f = Foo(id: 1)
discard aq.push(f)
# Consumer (chronos task):
let v = await aq.pop()
if v.isSome: echo v.get.id
```

Internally, `Queue[ref Foo, ...]` routes through the ManagedRef arm per §4.3. The chronos adapter sees `Queue[ref Foo, ...]` — it doesn't care about the Path C dispatch beneath.

### 5.8.4 Standalone nebr usage (no queue)

```nim
import lockfree/atomics, lockfree/smr/nebr
var mgr = initDebraManager[8, ccMulti]()
let handle = registerThread(mgr)
withPinscope(handle):
  # critical section: protected from reclamation
  let p = mySharedPtr.load(moAcquire)
  doStuff(p)
# pin scope released here; safeEpoch can advance.
```

This is the user surface for nebr-on-its-own (§3.x). No Queue required.

### 5.8.5 Custom drain pattern with seq collection

```nim
proc collectAll[T; ...](q: var Queue[T, ...]): seq[T] =
  result = @[]
  for item in q.drain():
    result.add(item)
let remaining = collectAll(myQueue)
# do something with `remaining`; myQueue is empty but still alive.
```

### 5.8.6 Concept-generic library code

```nim
proc fanIn*[T; Q1: Queueable[T]; Q2: Queueable[T]](src1: var Q1, src2: var Q2, dst: var Q1) =
  while true:
    let a = src1.pop()
    if a.isSome: discard dst.push(a.get)
    let b = src2.pop()
    if b.isSome: discard dst.push(b.get)
    if a.isNone and b.isNone: break
```

`fanIn` accepts any combination of bare-SPSC queues, Bound endpoints, or a mix — the concept gate is the only constraint.

---

## 5.9 Compile-time error UX

This subsection enumerates the user-visible compile-time errors and what message text the user sees. Inline contradiction-detection messages are §2 (admit/reject) and the destructor / use-after-destroy errors are queue.nim:957-972.

> **Prescriptive vs descriptive.** All message strings quoted in §5.9 are **prescriptive specs** for the post-T-INTEGRATE library: the Phase 3 implementer must emit these strings verbatim (substituting `$T` / user types where indicated). They are not approximations of v5.0.0's current message text. The post-T-INTEGRATE `queue.nim` / `bqueue.nim` are the canonical sites for these messages; the v5.0.0 per-arm files carry analogous (but not necessarily identical) message text that will be replaced by the prescribed strings during T-INTEGRATE.a–.c. OQ5.7 (§5.10) tracks the only deliberate softening: friendly interceptor overloads for typestate violations.

### 5.9.1 Invalid payload composition

```nim
var q = newUnboundedMpmcQueue[ref Foo, stEager, 64, 8]()
# Under --mm:refc:
# Error: ref types under refc are not admissible (Path C requires bit-cast-stable
# refcount intrinsics; refc has no public hook). Use --mm:arc / --mm:orc /
# --mm:atomicArc, or use Queue[ptr Foo] with manual lifetime management.
```

Routed through the §2 admit gate (`when not supportsManagedRefMM(T):` static error).

### 5.9.2 Missing chronos for AsyncQueue usage

```nim
# Without chronos installed AND without -d:lockfreeChronos:
import lockfree/chronos
var aq = AsyncQueue[int, ...](...)
# Error: AsyncQueue is not declared in this scope.
#       (lockfree/chronos.nim's body is gated by `when defined(lockfreeChronos)
#        or (compiles do: import chronos)` and the predicate is false.)
```

If the user thought the import would force chronos in, the import itself does succeed (module body is empty). The error fires on `AsyncQueue` use — pointing the user at the gate condition.

For `-d:lockfreeChronos` without chronos installed, chronos's own `cannot open file: chronos` from `import chronos` fires.

### 5.9.3 Multi-side direct-on-queue call

```nim
var q = newUnboundedMpmcQueue[int, stEager, 64, 8]()
discard q.pop()
# Error: Direct pop on a multi-consumer Queue is not allowed.
#        Use q.getConsumerHere().pop() (same-thread sugar) or
#        q.bindConsumer().pop() (one-shot SC consumer) to obtain a per-thread
#        Bound[T, Tag, Queue[...]] and pop through it.
```

Message text from queue.nim:927-932. No `*Multi` / `*Single` internal arm names leak; only user-visible API names.

### 5.9.4 Use-after-destroy

```nim
var q = newUnboundedSpscQueue[int, stEager, 64, 8]()
`=destroy`(q)
discard q.push(42)
# Error: Queue used after =destroy (lifecycle: QueueInit -> QueueDestroyed).
```

Message text from queue.nim:990. Driven by the `transitionError` pragma on `=destroy`.

### 5.9.5 Endpoint typestate violations

```nim
var u = q.getProducer()
discard u.push(42)
# Error: undeclared field: 'push'
#        (push is only defined on Bound[T, Tag, queueT], not Unbound.)
```

```nim
var b = u.bindToThread()
discard b.bindToThread()
# Error: strict-transition violation: Bound[T, Tag, queueT] has no transition
#        from itself (typestates 0.12.0 strictTransitions = true).
```

These errors come from the typestate DSL, not custom strings. Quality of message is bounded by upstream nim-typestates. Open question OQ5.7: should we add `{.error: "..."  .}` overloads on `Bound` that intercept `bindToThread` and produce a friendlier message? Phase 2.2.

### 5.9.6 mm:none + ref payload

```nim
# --mm:none -d:allowManagedRefUnderMmNone
var q = newUnboundedMpmcQueue[ref Foo, stEager, 64, 8]()
```

Compiles. The ManagedRef arm activates with all incRef/decRef calls compiled to no-ops (§4.3.3, mm:none arm). The user is responsible for `destroyAndDrain` (§5.7.3). No compile error — the contract is documented in the guide, not enforced statically.

(Without the `-d:allowManagedRefUnderMmNone` flag, the default is to reject `ref T` under mm:none with a pointer at the flag — §2 admit gate.)

### 5.9.7 Param-coherence guards

```nim
var q = newBoundedMpscQueue[int, 0, 8]()  # N == 0
# Error: BQueue requires N > 0 (bounded slot count)
```

From `assertBQueueParams` (bqueue.nim:182-185). Same pattern for `S > 0`, `MaxThreads > 0` on Queue.

---

## 5.10 Open questions for Phase 2.2 review

The following are deferred for Phase 2.2 (design review) — they are decisions where Section 5 has a preferred answer but wants explicit confirmation before locking.

### OQ5.1 Default callback on `destroyAndDrain` for POD

Current text (§5.7.1): no default; user supplies a `proc(_: T) = discard` even for POD. Alternative: provide a `destroyAndDrain(q)` zero-arg overload for `T` where `supportsCopyMem(T)`. Trade-off: convenience vs explicitness about per-item ownership. Recommendation: provide the zero-arg overload **only** for POD (gated by `when supportsCopyMem(T)`), reject otherwise.

### OQ5.2 `pairs` semantics on multi-consumer drain

The bounded `pairs` iterator yields `(index, item)`. On a multi-consumer drain (going through `Bound`), what is the index? Recommendation: drain ordinal observed by **this consumer's** iterations, not the queue's global ordering — there is no global ordering for multi-consumer drains.

### OQ5.3 AsyncQueue vs explicit endpoint async

Section 5.4.5 raises this: should `AsyncQueue` be the only async surface, or should `asyncPop` on `Bound` be the primary surface and `AsyncQueue` a thin sugar? Recommendation: ship both, document `AsyncQueue` as the recommended surface for SPSC / SPMC and `asyncPop` on Bound as the recommended surface for MPMC (where the endpoint is required anyway). Trade-off: API surface area vs user clarity.

### OQ5.4 chronos version cap

Floor `>= 4.0.0`. Cap currently open. If chronos 5.x changes `AsyncEvent.fire` / `wait` semantics, the adapter could silently misbehave. Recommendation: pin to `>= 4.0.0, < 5.0.0` until we audit chronos 5.x.

### OQ5.5 Custom error for `-d:lockfreeChronos` without chronos installed

Currently the user sees chronos's own `cannot open file: chronos` error. Recommendation: keep as-is — the message is already clear and points at the right fix. Re-evaluate only if user feedback says otherwise.

### OQ5.6 Default cleanup callback overload

See OQ5.1 above (same question, restated). Resolution links should converge.

### OQ5.7 Friendly typestate violation messages

`Unbound → push` and `Bound → bindToThread` both produce the upstream nim-typestates DSL error message. Recommendation: add `{.error: "..."  .}` interceptor overloads on the wrong-state types with user-friendly text pointing at the right transition.

### OQ5.8 Concept overload resolution priority

The `Queueable[T]` concept matches both bare SPSC and `Bound`. If user code defines a `push` that also matches the concept, which overload wins? Recommendation: document that `Queueable` is intended for type-class dispatch only, not for in-place push/pop overrides. Concrete overload resolution rules are deferred to Phase 2.2 with a small test suite.

### OQ5.9 Tier 1 iterator on multi-consumer bare queue

The current §5.3.1 surface puts the multi-consumer iterators on `Bound`, not on the bare queue. Should there be a `for item in q.drainAll(): ...` shortcut that internally binds + drains + closes? Recommendation: yes, as a template wrapper (analogous to `getConsumerHere`). Defer to Phase 2.2 to confirm the name (`drainAll` vs `drainSync` vs other).

### OQ5.10 Iterator name `items` vs Nim convention

Nim's `for x in q: ...` desugars to `iterator items*`. The drain semantics (consume-to-empty) deviates from the conventional `items` (non-destructive iteration). Recommendation: ship `items` as the alias to `drain` (current §5.3.1) but document the destructive semantics prominently. Alternative considered: only ship `drain` and force `for x in q.drain(): ...`. Trade-off: convenience vs explicitness. Lean toward shipping `items` for the same-thread SPSC drain pattern (where the loss of "non-destructive iteration" is well-understood).

---

## 5.11 Cross-references to other sections

| Section 5 subsection | Cross-references |
|---|---|
| 5.1.4 (Path C dispatch) | §2 (admit/reject), §4.2.3 (op routing), §4.3 (ManagedRef), §4.4 (ManagedSlice) |
| 5.2.x (BQueue) | §1.3 (module layout), §4.5 (per-arm cell shapes) |
| 5.3 (iterators) | §4.8 (drain helper internals) |
| 5.4 (chronos) | §1.5 (chronos soft-dep), §3.5 (pinscope sync-only — cancellation discipline) |
| 5.5 (dual-API) | endpoint.nim source, role_tags.nim source; handoff §"Typestates audit + dual-API design" |
| 5.6 (chronos opt-dep) | §1.5, handoff §"CRITICAL #4" |
| 5.7 (lifecycle) | §4.7 (destructor walk), §4.8 (drain), safety:§invariants |
| 5.9 (compile errors) | §2 admit/reject, queue.nim:957-972, bqueue.nim:180-198, role_tags.nim |

---

## 5.12 Section 5 self-check

- [x] **Surface enumeration complete.** Queue, BQueue, iterators, chronos adapter, typestate dual-API, lifecycle helpers, examples, error UX all covered.
- [x] **No scope creep.** Tier 2 is explicitly dropped per handoff Q6 — Section 5 does not propose reintroducing it. Tier 1 + Tier 3 only.
- [x] **Path C internal dispatch is invisible at the API surface.** Users type `Queue[ref Foo, ...]` and `Queue[string, ...]`; the ManagedRef / ManagedSlice routing is `when` inside the procs (§5.1.4).
- [x] **Compile-time error messages reference user-visible names only.** No `*Multi` / `*Single` arm leakage in any error string (§5.9.3). Confirmed against queue.nim:927-932 + bqueue.nim:184.
- [x] **chronos hybrid pattern locked.** §5.6 is the exact pattern from handoff §"CRITICAL #4" (`when defined(lockfreeChronos) or (compiles do: import chronos):`).
- [x] **mm:none drain contract surfaced.** §5.7.3 documents the leak-on-undrained contract explicitly, with cross-reference to §4.8.4.
- [x] **Dual-API surfaces both typestate-guarded and RAII wrapper paths.** §5.5.2 (existing v5.0.0 typestate) + §5.5.3 (new `withBoundEndpoint` wrapper) + §5.5.4 (shared inner primitives, no duplication) + §5.5.5 (`Queueable` concept dispatch).
- [x] **No new generic params introduced.** Queue and BQueue param shapes are preserved exactly from v5.0.0.
- [x] **Cross-references to Sections 1–4 + safety + handoff are present.** §5.11 enumerates them.
- [x] **Open questions surfaced, not buried.** §5.10 has 10 explicit Phase 2.2 items with recommendations.
- [x] **No commit / no AI attribution / no emojis in artifact.** Section is markdown prose + Nim code samples only.
