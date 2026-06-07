# nebr — Neutralizable Epoch-Based Reclamation

`nebr` is `lockfree`'s safe memory reclamation strategy: an
epoch-based reclaimer with signal-driven thread neutralization. It
backs the unbounded multi-consumer queues and is also exposed as a
standalone reclaimer for users building their own lock-free data
structures.

## Attribution

`nebr` (Neutralizable EBR) is **inspired by Brown 2015 DEBRA+**, with
documented deviations from the original paper. See the
[provenance discussion](https://github.com/elijahr/lockfree/blob/devel/docs/internal/debra-plus-provenance.md)
for the full diff. The implementation is functionally adjacent to the
Brown 2015 paper's neutralization model with simplifications around
hazard pointers and `sigsetjmp` recovery; the name slot
`debra_plus.nim` is **reserved for a future faithful Brown 2015 port**.

> **Not to be confused with Brown 2017 NBR.** Brown 2017
> "Neutralization-Based Reclamation" is a distinct algorithm with
> related goals but different safety arguments. Earlier prose in the
> upstream `nim-debra` README cited Brown 2017; that citation has been
> corrected here per Q-FAITHFUL.

## When you reach for `nebr`

You **do not** need `nebr` if you are only using the queues. The
unbounded multi-consumer queues each manage their own private
`Manager` and registration is handled by the endpoint binding API.

You **do** need `nebr` if you are building your own lock-free data
structure that frees interior nodes — a stack, a hash table, a
skiplist, or anything else where a reader can hold a pointer to a
node that a writer concurrently unlinks. The page on
[SMR fundamentals](../concepts/smr.md) explains the problem this
solves and where it sits in the family of solutions.

## Manager lifecycle

A `nebr.Manager` has three operational states: created, active, and
closed. The state machine is enforced by the typestate FSM in
[`lockfree/typestates`](../typestates.md).

### Create

```nim
import lockfree/smr/nebr

var manager = newManager(maxThreads = 4)
```

`maxThreads` is the **lifetime** distinct-thread count, not the
concurrent count. There is no per-thread unregister; each
`register()` consumes a slot for the lifetime of the manager.

### Register a thread (once per operating thread)

Every thread that will pin / unpin / retire MUST call `register()`
before its first such operation. This is thread-affine: call it from
the operating thread, not the parent.

```nim
proc workerProc() {.thread.} =
  manager.register()
  # … pin, unpin, retire from this thread …
```

If `maxThreads` is exhausted at `register()` time, the call raises
`DebraRegistrationError`. (The name predates the rename to nebr; the
exception type retains its historical name for backward compatibility.)

### Pin / unpin around critical sections

The critical section pattern:

```nim
manager.pin()
let snapshot = atomicLoad(myAtomic)
# … walk pointers reachable from snapshot …
manager.unpin()
```

Between `pin` and `unpin`, no thread can reclaim the epoch in which
the pin happened. Keep critical sections short — long pins delay
reclamation for every other thread.

For RAII-style scoping, use the `withPin` template (sketch):

```nim
manager.withPin:
  let snapshot = atomicLoad(myAtomic)
  # … walk snapshot …
# unpin is automatic at scope exit, including raised exceptions
```

### Retire a node

When you unlink a node from your data structure and want it
eventually freed:

```nim
manager.retire(node)
```

`retire` puts the node into the manager's per-thread limbo bag,
stamped with the current epoch. The node is not freed yet — it cannot
be, because other threads may still hold pointers to it.

### Reclaim

Reclamation is the manager's bookkeeping pass:

```nim
manager.reclaim()
```

`reclaim` advances the epoch, scans every registered thread's
announced epoch, and frees every retired node whose stamp is safely
older than every pinned epoch.

The cadence is policy-dependent. For interactive workloads, calling
`reclaim` once per operation is fine. For high-throughput workloads,
call it every N operations or behind a periodic timer.

### Neutralize a stalled thread

If a registered thread stalls inside a critical section, every other
thread's reclamation will block on its pinned epoch. The
neutralization API allows the operator to evict a stalled thread from
the safety pool:

```nim
manager.neutralizeStalled(epochsBeforeNeutralize = 4)
```

The implementation sends `SIGUSR1` to the stalled thread; the thread's
signal handler force-unpins. **The neutralized thread must
acknowledge** by returning out of its critical section: in-operation
recovery (per Brown 2015 `sigsetjmp` / `siglongjmp`) is not
implemented; the v0.1.0 contract is "neutralized thread must not
continue its critical section." See the
[deviation table](#deviations-from-brown-2015-debra) row D3.

### Shutdown

The manager's destructor runs `disposeSlotEncoded` over every retired
node before freeing the manager itself. The destructor is invoked
automatically by Nim's MM when the `Manager` value goes out of scope
or its containing `Queue` is destroyed.

## Typestate enforcement

`nebr` uses [typestates](../typestates.md) to enforce that:

- `pin` and `unpin` may only be called after `register`.
- `retire` may only be called after `register`.
- `reclaim` may be called by any registered thread.
- `register` may not be called twice on the same thread.

Violations are compile-time errors. The typestate FSM is the same
machinery that powers the queue endpoint lifecycle.

## Reclamation cadence policy

The user controls reclamation cadence. `nebr` does not pre-commit to
a frequency. The library exposes:

- `reclaim()` — synchronous; advance epoch and free what is safe.
- `reclaimEvery(n)` — invoked every `n` `retire` calls; configurable.
- `reclaimOnDestroy()` — invoked once on manager destruction.

For latency-sensitive code, prefer explicit `reclaim()` calls at known
safe points. For throughput-sensitive code, use `reclaimEvery(n)` with
a tuned cadence.

## Deviations from Brown 2015 DEBRA+

The full deviation analysis lives in
[`internal/debra-plus-provenance.md`](https://github.com/elijahr/lockfree/blob/devel/docs/internal/debra-plus-provenance.md).
The summary table (D1–D9):

| # | Deviation | Severity | What changes |
|---|-----------|----------|--------------|
| D1 | Paper: 3 fixed limbo bags indexed by `epoch mod 3`. nebr: unbounded FIFO linked list of bags stamped with retire-time epoch. | Semantic (structural) | Memory bound changes (paper: O(mn²); nebr: bounded by retire rate × time-to-advance). |
| D2 | Paper advances epoch with a precondition CAS gate; nebr advances unconditionally via `fetchAdd(1)`. | Semantic (precondition) | Safety recovered via bag-epoch stamp + min-pinned-epoch check at reclaim. |
| D3 | Paper's `sigsetjmp` / `siglongjmp` in-operation recovery is **absent** from nebr. | Semantic (omitted) | A neutralized thread must not continue its critical section; the queues' callers handle this via the `Closed` typestate. |
| D4 | Paper auto-neutralizes from `leaveQstate` when own bag exceeds threshold; nebr requires explicit `neutralizeStalled(manager, epochsBeforeNeutralize)`. | Semantic (policy) | Fault tolerance is opt-in. |
| D5 | Paper epoch-advance CAS (idempotent retry); nebr uses `fetchAdd(1)`. | Engineering | Multiple concurrent advancers each bump; same monotonicity, different cadence. |
| D6 | Paper uses object pools / blockbags / shared-bag handoff; nebr uses `c_calloc` / `c_free` per 64-object limbo bag. | Engineering | Constant-factor; not a contract change. |
| D7 | No hazard-pointer integration. (In DEBRA+ HPs exist to protect descriptors during `sigsetjmp` recovery, which nebr omits — see D3.) | Semantic (omitted) | Tied to D3. |
| D8 | Quiescent-bit-in-LSB packing absent; nebr uses a separate `pinned: Atomic[bool]` per slot. | Engineering | Two atomics per pin/unpin; SC RMW restores ordering. |
| D9 | Paper's incremental per-thread `checkNext` cross-thread announcement scan absent; nebr's reclaim does a full `MaxThreads`-wide scan each time. | Engineering | Reclaim-side cost; not pin-side. |

Severity reading: **D1, D2, D3, D4, D7** are *semantic* (the paper
describes them as core features). **D5, D6, D8, D9** are *engineering*
(same algorithm, different code).

Bottom line: nebr is best described as an **EBR variant inspired by
DEBRA+** that retains the distinguishing signal-neutralization
mechanism but replaces the fixed-3-bag + CAS-gated advance +
quiescent-bit + sigsetjmp-recovery + HP machinery with a
linked-list-of-stamped-bags + unconditional-advance + separate-flags +
operator-driven-neutralize design. The "+" (fault tolerance) is
**partially** preserved.

A faithful Brown 2015 port — `debra_plus.nim` — is held as future
work. The name slot is reserved.

## Safety argument

nebr's safety contract is the EBR safety contract:

> A retired node is freed only after every thread that could have been
> reading it has either advanced its epoch past the retire epoch or
> been neutralized.

This contract is upheld by:

1. Each `pin()` writes the current epoch to the thread's announce slot
   with SC ordering, before the critical-section read.
2. `retire()` stamps the node with the current epoch.
3. `reclaim()` reads the min-pinned-epoch across all threads with SC
   ordering; only retired nodes stamped strictly older than the
   min-pinned-epoch (with the appropriate underflow guard at epoch 0)
   are freed.
4. `neutralizeStalled()` evicts a stalled thread from the
   min-pinned-epoch computation; the evicted thread's critical
   section must not continue.

For the formal safety argument, see
[`internal/safety-argument.md`](https://github.com/elijahr/lockfree/blob/devel/docs/internal/safety-argument.md).

## Limitations

- **Bounded threads.** `maxThreads` is fixed at manager creation;
  there is no per-thread unregister. Size accordingly.
- **No in-operation recovery.** A neutralized thread must not
  continue its critical section. There is no `sigsetjmp` rollback.
- **`sigsetjmp`-free critical sections.** Per D3, critical sections
  must be `sigsetjmp`-free; the queues meet this.
- **Memory bound is policy-dependent.** The unbounded-bag design
  (D1) means the limbo grows until reclaim runs. Set the reclamation
  cadence appropriately.
- **Single signal channel.** Neutralization uses `SIGUSR1`. If your
  application uses `SIGUSR1` for other purposes, the signal handlers
  may conflict.

## Further reading

- [SMR fundamentals](../concepts/smr.md) — the problem nebr solves.
- [Internal: provenance](https://github.com/elijahr/lockfree/blob/devel/docs/internal/debra-plus-provenance.md) — full deviation analysis.
- [Internal: safety argument](https://github.com/elijahr/lockfree/blob/devel/docs/internal/safety-argument.md) — formal correctness sketch.
- Trevor Brown, ["Reclaiming Memory for Lock-Free Data Structures: There has to be a Better Way"](https://www.cs.utoronto.ca/~tabrown/debra/) (PODC 2015).
