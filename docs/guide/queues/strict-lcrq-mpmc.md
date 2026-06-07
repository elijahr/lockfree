# Unbounded MPMC (strict-LCRQ)

The unbounded `Queue[T, ccMulti, ccMulti, ST, S, MaxThreads]` arm
uses the **strict-LCRQ** algorithm (Morrison & Afek, "Fast Concurrent
Queues for x86 Processors", PPoPP 2013). Strict-LCRQ is the
double-word-CAS form: each segment cell is an
`Atomic[Pair[uint, T]]`, and progress is guaranteed by the
close-CAS-on-empty rule.

This page documents the user-facing surface; the implementation
lives in `src/lockfree/queue.nim` and is shared with the legacy
unbounded SPSC / SPMC / MPSC arms (the bulk of the segment-chain
machinery is common).

## When to reach for this arm

- You have multiple producers AND multiple consumers.
- You cannot bound the worst-case backlog.
- You can pay for heap-allocated segments + epoch-based reclamation.

If your worst-case backlog fits a fixed buffer, prefer
[bounded MPMC](bounded-vyukov.md): it is faster and needs no
reclaimer.

If you have only one producer or only one consumer, prefer the
[legacy unbounded arms](legacy.md), which use the (simpler)
committed-flag protocol.

## Construction

```nim
import options
import lockfree
import lockfree/endpoint

# Segment size 64, registry for 4 lifetime threads.
var q = newUnboundedMpmcQueue[int, stEager, 64, 4]()
```

Parameters:

- `T` — the payload type. Per the strict-LCRQ encoding, the cell is
  `Atomic[Pair[uint, T]]`; for non-`uint8`-sized `T` the library
  routes through the [Path C](../concepts/memory-management.md)
  encoding so `ref T` / `string` / `seq[T]` payloads work
  transparently.
- `stEager` — the segment-allocation strategy. Eager preallocates the
  first segment at construction; `stLazy` (when available) defers
  until the first push.
- `64` — the segment size. Each segment holds 64 slots before the
  producer allocates a successor segment.
- `4` — `MaxThreads`, the lifetime distinct-thread count for the
  internal nebr manager.

## Push / pop

Push and pop go through endpoints. Each operating thread binds an
endpoint once over its lifetime:

```nim
import lockfree
import lockfree/endpoint
import lockfree/role_tags

var q = newUnboundedMpmcQueue[int, stEager, 64, 4]()

# On the producer thread:
var producer = q.getProducerHere()  # registers with nebr on this thread
producer.push(42)

# On the consumer thread:
var consumer = q.getConsumerHere()
let v = consumer.pop()  # Option[int]: some(42)
```

`*Here` is sugar for `getProducer()` + `bindToThread()` when caller =
operating thread. For the parent-obtains-then-hands-off-to-worker
pattern, use the explicit pair so registration lands on the worker:

```nim
proc workerProc(p: ptr SomeProducerType) {.thread.} =
  p[].bindToThread()  # registers with nebr from THIS thread
  p[].push(42)
```

See [Typestates](../typestates.md) for the lifecycle details.

## The strict-LCRQ protocol

The algorithm uses two coordinated CASes per slot:

1. **Producer claims slot `i`** via `tryClaim` (single-word CAS on the
   slot's sequence tag). On success, the producer is the sole writer
   of slot `i`.
2. **Producer publishes** via `tryPublish` (DWCAS on `(seq, payload)`).
   The atomic publish writes the payload and advances the sequence in
   one instruction.
3. **Consumer claims slot `i`** via a parallel `tryClaim` on the
   consumer-side sequence tag.
4. **Consumer reads** the payload via an SC load on the published
   `(seq, payload)` cell.

The progress rule is **close-CAS-on-empty**: when a producer would
publish into a slot that a consumer has already given up on, the slot
is closed via a sentinel bit (`CLOSED_BIT`, the high bit of the
sequence word). The producer then walks to the next segment. This is
what makes strict-LCRQ *strict*: there is no in-place fix-up loop;
closed slots are skipped.

## Memory layout

A `Queue` value owns a head segment pointer, a tail segment pointer,
and (for multi-cardinality arms) a private `nebr.Manager`. Segments
are heap-allocated and freed by nebr's reclaimer.

This means:

- A `Queue` is **move-only** (non-copyable). Copying would alias the
  owned `ptr Segment` chain and the owned `ptr nebr.Manager`,
  double-freeing on destroy. The compiler enforces this via
  `=copy` rejection.
- Pass by `var` or `ptr` to share across threads.

## Reclamation cadence

The MPMC arm's private `nebr.Manager` runs reclaim on a default
cadence inherited from the `nebr` defaults. For latency-sensitive
code, you can supply an explicit `Manager` and control the cadence;
for typical workloads, the defaults are appropriate. See
[nebr — Reclamation cadence policy](../smr/nebr.md#reclamation-cadence-policy).

## Payload type constraints

`Queue[ref Foo, ccMulti, ccMulti, …]`, `Queue[string, …]`, and
`Queue[seq[T], …]` all work via Path C — the queue stores an 8-byte
slot token and heap-allocates a *box* for the payload. See
[ManagedRef](../managed-ref.md) and [ManagedSlice](../managed-slice.md)
for the user-facing API and the per-MM cleanup story.

Under `--mm:none`, the MPMC arm requires explicit user-managed
reclamation because nebr requires heap allocation. Most `--mm:none`
deployments prefer the bounded MPMC arm for this reason.

## Difference from earlier `lockfreequeues` versions

Prior to v0.1.0, the unbounded MPMC arm shipped a **committed-flag**
protocol: each slot carried a separate `Atomic[bool]` "committed" bit,
and the publish was two atomic stores rather than one DWCAS. The
strict-LCRQ form is faster on contended workloads and is the default
in v0.1.0.

The committed-flag form is preserved for the unbounded SPSC, SPMC, and
MPSC arms because the strict-LCRQ progress rule is unnecessary when
one side has a single endpoint. See [Legacy cardinalities](legacy.md).

## Further reading

- Adam Morrison and Yehuda Afek, "Fast Concurrent Queues for x86
  Processors" (PPoPP 2013). The LCRQ paper.
- [`api/queue`](../../api/queue.md) — auto-generated symbol reference.
- [SMR / nebr](../smr/nebr.md) — the reclaimer the MPMC arm depends on.
