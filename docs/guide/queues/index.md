# Queues

`lockfree` ships two queue families: bounded (`BQueue`) and unbounded
(`Queue`). Each covers all four producer/consumer cardinalities:

|  | Single producer | Multi producer |
|--|--|--|
| **Single consumer** | SPSC | MPSC |
| **Multi consumer** | SPMC | MPMC |

That is eight cells total: four bounded + four unbounded.

## Bounded vs unbounded

| | Bounded `BQueue` | Unbounded `Queue` |
|--|--|--|
| Backing storage | Inline `array[N, T]` ring buffer | Linked segments allocated on demand |
| Capacity | Compile-time `N` | Grows as needed |
| Memory | Predictable, fixed | Grows with backlog |
| Reclamation | None needed | SPSC: inline. SPMC/MPSC/MPMC: nebr |
| `--mm:none` | Yes (strict bit transport) | Yes for SPSC; multi-cardinality requires nebr |
| Algorithm (MPMC arm) | Vyukov per-slot seq counter | Strict-LCRQ (Morrison & Afek 2013) |

**Reach for `BQueue` when** the worst-case backlog fits a known number
of items, when memory must be predictable, or when you are running
under `--mm:none` for real-time work.

**Reach for `Queue` when** burst sizes are unpredictable and paying
for heap-allocated segments + epoch-based reclamation is acceptable.

## Cardinality chooser

| You have | Choose |
|---|---|
| 1 producer, 1 consumer, fits in a fixed buffer | `newSpscQueue[T, N]()` |
| 1 producer, 1 consumer, may burst beyond any buffer | `newUnboundedSpscQueue[T, stEager, S, P]()` |
| 1 producer, N consumers, fits in a fixed buffer | `newSpmcQueue[T, N, C]()` |
| 1 producer, N consumers, may burst | `newUnboundedSpmcQueue[T, stEager, S, MaxThreads]()` |
| N producers, 1 consumer, fits in a fixed buffer | `newMpscQueue[T, N, P]()` |
| N producers, 1 consumer, may burst | `newUnboundedMpscQueue[T, stEager, S, MaxThreads]()` |
| N producers, N consumers, fits in a fixed buffer | `newMpmcQueue[T, N, P, C]()` |
| N producers, N consumers, may burst | `newUnboundedMpmcQueue[T, stEager, S, MaxThreads]()` |

Where:

- `T` is the payload type (any value type, `ref T`, `string`, or `seq[T]`; see [ManagedRef](../managed-ref.md) and [ManagedSlice](../managed-slice.md)).
- `N` is the bounded capacity.
- `P` / `C` are the per-side view counts (bounded multi-cardinality arms).
- `S` is the unbounded segment size.
- `MaxThreads` is the lifetime distinct-thread count for the nebr manager.
- `stEager` is the unbounded segment-allocation strategy.

## Pages

- [Bounded — Vyukov](bounded-vyukov.md) — the Vyukov per-slot
  sequence-counter substrate underlying every bounded arm.
- [Unbounded MPMC — strict-LCRQ](strict-lcrq-mpmc.md) — the
  double-word CAS algorithm underlying the unbounded MPMC arm.
- [Legacy cardinalities](legacy.md) — unbounded SPSC, SPMC, and MPSC
  via the committed-flag segment chain.

## Choosing between bounded and unbounded with the same cardinality

The decision is not always obvious for `XPSC` / `XPMC` workloads where
both bounded and unbounded technically work. Three rules of thumb:

- **If you can predict the worst-case backlog and pay for a fixed
  allocation, bounded is faster.** No per-segment allocation, no
  reclamation. The bounded Vyukov arm is the most extensively
  benchmark-tuned code in the library.
- **If your workload is read-heavy with long-lived consumers,
  unbounded is more flexible.** Consumers can fall behind without
  back-pressure on the producer; the queue grows segments.
- **If you are under `--mm:none`, bounded is the obvious choice.**
  The unbounded multi-cardinality arms require nebr, which requires
  heap allocation.

For the implementation-level rationale, see the design doc's
[Architecture](https://github.com/elijahr/lockfree/blob/devel/docs/internal/design-sections/01-architecture-and-module-layout.md).
