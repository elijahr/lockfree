# Safe memory reclamation

A lock-free data structure that ever frees an interior node has to
solve a problem that locks make trivial: **how do you free memory that
another thread might still be reading?** The answer is *safe memory
reclamation* (SMR), and it is the part of the library most likely to
trip up someone coming from mutex-based code.

This page explains the problem, the family of solutions, and how
`lockfree` chooses among them. For the implementation specifics of the
strategy `lockfree` actually ships, see [nebr](../smr/nebr.md).

## The use-after-free problem

Consider a lock-free linked-list pop:

```text
Thread A                          Thread B
loadHead() → node                 loadHead() → node
                                  CAS head: node → node.next  (succeeds)
                                  free(node)
node.value  ← USE-AFTER-FREE
```

Thread A read the head, was preempted, and by the time it dereferences
`node`, thread B has unlinked and freed it. The CAS does not protect
A's load: from A's perspective, `node` is a dangling pointer.

You cannot solve this with more CASes. You need a *protocol* that
keeps `node` alive until every thread that could be reading it has
moved on.

## The four standard solutions

| Family | How it works | Cost |
|--------|--------------|------|
| **EBR** (Epoch-Based Reclamation) | Threads announce an *epoch* before each critical section. Memory retired in epoch `e` is freed after every thread has been observed past epoch `e`. | Cheap per-pin (`fetchAdd` + announce write). Reclamation amortised. Stalled threads block reclamation. |
| **HP** (Hazard Pointers) | Threads publish per-pointer protection slots before dereferencing. Reclaimer scans all slots before freeing. | Expensive per-dereference (publication + fence). Robust to stalled threads. |
| **IBR** (Interval-Based Reclamation) | Generalization of EBR with per-pointer epoch ranges. Reduces the "stalled thread blocks everyone" weakness. | Mid-cost; more bookkeeping than EBR, less per-deref than HP. |
| **NBR** (Neutralization-Based Reclamation, Brown 2017) | A different algorithm from DEBRA+; uses signal-driven neutralization but with a distinct safety argument. | Active research. Not what `lockfree` ships — see the [nebr deviation table](../smr/nebr.md#deviations-from-brown-2015-debra). |

`lockfree` ships **EBR with signal-driven neutralization** under the
name `nebr` (Neutralizable EBR). The signal-driven neutralization
mechanism is inspired by Brown 2015 DEBRA+. See
[nebr](../smr/nebr.md) for the full algorithm description and the
deviation table from the original paper.

## Reader-writer asymmetry

A subtlety that EBR makes explicit: **readers and writers have
asymmetric costs**.

- A reader pins the epoch, dereferences, and unpins. Two atomic writes
  per critical section.
- A writer (the thread that calls `retire`) records the node and the
  epoch. The reclaimer scans every reader's announced epoch to decide
  when retired nodes are safe to free.

This asymmetry is why EBR is the cheapest SMR for read-heavy
workloads: readers pay the bare minimum, and the writer / reclaimer
pays the bookkeeping cost. Hazard pointers invert the asymmetry —
readers pay more, writers pay less.

For `lockfree`'s queues, the multi-consumer arms are the place SMR
matters. The producer pushes onto a segment that the consumer is
walking; when the consumer claims a slot, the segment may become
eligible for reclamation. The consumer's pop is the read; the
segment-retirement is the write. EBR is the right fit.

## When SMR is needed inside `lockfree`

| Variant | SMR? |
|---------|------|
| `BQueue` (bounded, any cardinality) | No. Slots live in the queue's inline array; nothing is reclaimed. |
| `Queue[T, ccSingle, ccSingle, …]` (unbounded SPSC) | No. The consumer is the only freer; producer never sees a retired segment. |
| `Queue[T, ccSingle, ccMulti, …]` (unbounded SPMC) | Yes. Multiple consumers can race on segment advance. |
| `Queue[T, ccMulti, ccSingle, …]` (unbounded MPSC) | Yes. Single consumer, but producer-side segment allocation interacts. |
| `Queue[T, ccMulti, ccMulti, …]` (unbounded MPMC) | Yes. Strict-LCRQ + nebr. |

When SMR is needed, the queue manages its own private `nebr.Manager`
unless you supply one explicitly. See
[managed-ref.md](../managed-ref.md#cleanup-and-reclamation) for how
payload cleanup interacts with segment reclamation.

## When to reach for `nebr` directly

If you are building your own lock-free data structure — a stack, a
hash table, a skiplist — you can use `nebr` as a standalone reclaimer
without any of the queue machinery. The standalone surface is the
[manager lifecycle](../smr/nebr.md#manager-lifecycle): create a
manager, register each operating thread once, then bracket your
critical sections with `pin` / `unpin` and call `retire` for retired
nodes. The reclaimer runs on a cadence you control.

## Further reading

- Trevor Brown, ["Reclaiming Memory for Lock-Free Data Structures:
  There has to be a Better Way"](https://www.cs.utoronto.ca/~tabrown/debra/)
  (PODC 2015). The DEBRA+ paper. `nebr` is inspired by this work; the
  precise deviations are catalogued in
  [`internal/debra-plus-provenance.md`](https://github.com/elijahr/lockfree/blob/devel/docs/internal/debra-plus-provenance.md).
- Maged M. Michael, "Hazard Pointers: Safe Memory Reclamation for
  Lock-Free Objects" (TPDS 2004). The standard HP reference.
- Haosen Wen et al., "Interval-Based Memory Reclamation" (PPoPP 2018).
  The IBR reference.
