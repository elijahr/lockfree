# Lock-freedom

`lockfree` is a library of **lock-free** concurrent data structures.
This page defines the progress hierarchy, explains what `{.lockFree.}`
buys you, and clarifies what lock-freedom does and does not guarantee.

## Progress hierarchy

Three terms cover the standard progress guarantees for concurrent
operations:

- **Wait-free**: every thread completes its operation in a bounded
  number of steps, regardless of what other threads do. The strongest
  guarantee; immune to scheduling decisions on other threads.
- **Lock-free**: at least one thread makes progress on every step.
  Individual threads may retry under contention, but the system as a
  whole never stalls.
- **Blocking** (mutex-based): a thread holding a lock blocks any other
  thread that needs the lock. A preempted holder stalls every waiter.

Wait-free is preferable when achievable; lock-free is what contended
CAS loops give you. Both are strictly stronger than blocking, because
neither can deadlock and neither stalls the system on a slow holder.

## What `lockfree` guarantees per arm

| Type | Cardinality | Push | Pop |
|------|-------------|------|-----|
| `BQueue` | SPSC | Wait-free | Wait-free |
| `BQueue` | SPMC | Wait-free | Lock-free |
| `BQueue` | MPSC | Lock-free | Wait-free |
| `BQueue` | MPMC | Lock-free | Lock-free |
| `Queue` | SPSC | Wait-free | Wait-free |
| `Queue` | SPMC | Wait-free | Lock-free |
| `Queue` | MPSC | Lock-free | Wait-free |
| `Queue` | MPMC (strict-LCRQ) | Lock-free | Lock-free |

The single-cardinality side (single producer, single consumer) of each
arm is always wait-free because there is no contention on that side.
The multi-cardinality side uses a CAS loop, which is lock-free but not
wait-free under contention.

## The `{.lockFree.}` pragma

`lockfree` ships a `{.lockFree.}` pragma you can apply to your own
procs. It is a **documentation marker plus a static check** that the
proc body does not call into anything that takes a lock:

- The pragma asserts the proc does not invoke `system/locks` primitives
  (`acquire`, `release`, `withLock`).
- It does not analyse the *transitive* call graph — a proc marked
  `{.lockFree.}` can still call into other procs that lock if you do
  not also mark them.
- The pragma is for human auditing first, compile-time enforcement
  second. It does not measure cache behaviour, contention costs, or
  scheduling fairness.

```nim
import lockfree

proc enqueueOne(q: var BQueue[int, ccSingle, ccSingle, 16, 0, 0],
                v: int) {.lockFree.} =
  while not q.push(v):
    discard  # backoff omitted for clarity
```

If you call `system.acquire` from inside an `{.lockFree.}` proc, you
get a compile-time error. The pragma is opt-in; the queues themselves
are intrinsically lock-free without it.

## What lock-freedom does NOT guarantee

A common confusion: lock-freedom is a *progress* property, not a
*latency* property and not a *correctness* property.

- **It does not bound latency.** A lock-free CAS loop can retry many
  times under contention. If you need bounded latency, you need
  wait-free, not lock-free.
- **It does not prevent priority inversion.** A high-priority thread
  spinning in a CAS loop while a lower-priority thread holds the
  contested cell still wastes CPU.
- **It does not prevent ABA.** ABA is a separate correctness concern
  addressed via tagged pointers, sequence counters, or safe memory
  reclamation. The queues' bounded variants use the Vyukov sequence
  counter; the unbounded MPMC variant uses the DWCAS sequence-tag from
  LCRQ. See [SMR](smr.md).
- **It does not free reclaimed memory safely on its own.** Reclaiming
  memory that another thread is concurrently reading is unsafe unless
  there is an explicit reclamation protocol. The unbounded
  multi-consumer queues use [nebr](../smr/nebr.md) for this.

## Further reading

- Maged M. Michael and Michael L. Scott, "Simple, Fast, and Practical
  Non-Blocking and Blocking Concurrent Queue Algorithms" (PODC 1996) —
  the M&S queue underlying the unbounded segment-chain SPSC / SPMC /
  MPSC arms.
- Adam Morrison and Yehuda Afek, "Fast Concurrent Queues for x86
  Processors" (PPoPP 2013) — the LCRQ algorithm underlying the
  unbounded MPMC arm.
- Dmitry Vyukov's writings on the per-slot sequence counter protocol —
  the bounded multi-cardinality arms.
