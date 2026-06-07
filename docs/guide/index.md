# The lockfree umbrella

`lockfree` is a single Nim package collecting production-quality lock-free
primitives under one consistent API. v0.1.0 ships four things:

- **Bounded queues** (`BQueue`) — ring buffers with compile-time capacity, the
  Vyukov per-slot sequence-counter protocol covering all four cardinalities
  (SPSC, SPMC, MPSC, MPMC).
- **Unbounded queues** (`Queue`) — linked-segment queues that grow as needed.
  MPMC uses the strict-LCRQ DWCAS form (Morrison & Afek 2013); SPSC, SPMC, and
  MPSC use the committed-flag segment chain.
- **Safe memory reclamation** (`lockfree/smr/nebr`) — epoch-based reclamation
  with signal-driven thread neutralization. Used internally by the
  multi-consumer unbounded queues; also exposed as a standalone reclaimer for
  user data structures.
- **Typestate-checked endpoints** — a `Unbound → Bound → Closed` lifecycle
  that locks in thread-affinity discipline at compile time. The bare API and
  the RAII `withBoundEndpoint` wrapper are both supported; `chronos`
  integration is available behind `-d:lockfreeChronos`.

This is a consolidation. Prior to v0.1.0 these primitives lived in two
separate packages, `lockfreequeues` (queues only) and `nim-debra` (the
DEBRA+-inspired reclaimer). The new umbrella ships them together, with one
consistent type-system story for payloads, one test matrix, and one mkdocs
site. See [Migrations](../migrations/from-lockfreequeues-v5.md) for the
package- and import-path-rename map if you are coming from either of those
packages.

## When to reach for what

If you have one producer and one consumer and a known maximum item count,
start with `newSpscQueue[int, 16]()`. Either bounded or unbounded SPSC is
wait-free and needs no reclaimer.

If you need multiple producers or multiple consumers, the choice between
bounded and unbounded is the next one:

- **Bounded** when memory must be predictable, when you are on
  `--mm:none` for real-time work, or when you can size the buffer to
  fit your worst-case backlog.
- **Unbounded** when bursts are unpredictable and you can pay for
  heap-allocated segments + epoch-based reclamation.

If your payload type is a `ref T`, a `string`, or a `seq[T]`, see
[ManagedRef](managed-ref.md) and [ManagedSlice](managed-slice.md). The
queues store these directly under all five memory managers (`orc`, `arc`,
`atomicArc`, `refc`, and `none`) — no `ptr T` wrappers required.

If you are building your own lock-free data structure and just need the
reclaimer, [nebr](smr/nebr.md) is a standalone reclaimer usable without
the queues.

## What this guide covers

| Section | When to read |
|---------|--------------|
| [Getting started](getting-started.md) | Install, simplest example, when to reach for `nebr`. |
| [Concepts](concepts/lock-freedom.md) | Vocabulary: lock-free vs wait-free vs blocking, what SMR is, how the memory managers interact with queue payloads. |
| [Queues](queues/index.md) | Cardinality chooser, the bounded Vyukov substrate, the strict-LCRQ MPMC, legacy cardinalities. |
| [SMR / nebr](smr/nebr.md) | Manager lifecycle, neutralize protocol, reclamation cadence, the deviation table vs Brown 2015 DEBRA+. |
| [ManagedRef](managed-ref.md) | `ref T` payloads end-to-end, including what the queue does on push/pop/destroy. |
| [ManagedSlice](managed-slice.md) | `string` / `seq[T]` payloads, the box pattern, the (now relaxed) nesting rules. |
| [Typestates](typestates.md) | Bare API, `withBoundEndpoint` RAII wrapper, the `Queueable[T]` concept, and where chronos fits in. |
| [Nimony](nimony.md) | Current nimony portability state, experimental flags, the watch policy. |
| [Migrations](../migrations/from-lockfreequeues-v5.md) | Coming from `lockfreequeues` or `nim-debra` — symbol-by-symbol rename map. |

## What is intentionally out of scope for v0.1.0

The umbrella is queues + SMR; it is not a general-purpose lock-free
container library. Hashes, sets, skiplists, and channels are out of scope.
A faithful Brown 2015 DEBRA+ port (with `sigsetjmp` recovery and hazard
pointers) is reserved as future work — the name `debra_plus.nim` is held
for it; see the [nebr deviation table](smr/nebr.md#deviations-from-brown-2015-debra)
for what is and is not implemented. `std/asyncdispatch` is not adapted;
`chronos` is the only supported async runtime.
