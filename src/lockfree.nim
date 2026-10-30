## lockfree — top-level umbrella module.
##
## The umbrella module exposes `LockfreeVersion` so the bench
## harness's `getAdapterVersions` can stamp the in-tree package version
## into the bench JSON `meta.adapters.lockfree.version` field
## without re-parsing `lockfree.nimble` at run time.
## Source-of-truth remains `lockfree.nimble`; this constant MUST
## be bumped in lockstep on every release.

const LockfreeVersion* {.strdefine.} = "0.6.6"
  ## In-tree package version. Mirrors the `version = "0.5.0"` line in
  ## `lockfree.nimble`. `{.strdefine.}` lets downstream builds
  ## override via `-d:LockfreeVersion=<x.y.z>` for fork builds; the
  ## bench JSON captures whatever value was compiled in.

## Module surface & Concurrency Topologies:
##   - **Bounded Surface** (`lockfree/bqueue`):
##     - Core type: `BQueue[T, ccProd, ccCons, N, P, C]`
##     - Ergonomic aliases: `BoundedQueue`, `MpmcBoundedQueue`, `SpscBoundedQueue`,
##       `MpscBoundedQueue`, `SpmcBoundedQueue`
##     - Implementation: Dmitry Vyukov bounded MPMC queue with per-slot sequence counters
##       and wait-free SPSC circular ring buffer.
##   - **Unbounded Surface** (`lockfree/queue`):
##     - Core type: `Queue[T, ccProd, ccCons, ST, S, MaxThreads]`
##     - Ergonomic aliases: `UnboundedQueue`, `MpmcQueue`, `SpscQueue`,
##       `MpscQueue`, `SpmcQueue`
##     - Implementation: Linked-segment LCRQ with DEBRA/NEBR epoch-based memory reclamation.
##   - **Concurrent Map Surface** (`lockfree/skiplist`):
##     - Core type: `SkipListMap[K, V, MaxThreads, MaxLevel]`
##     - Ergonomic aliases: `SortedTable`, `OrderedTable`, `ConcurrentSortedTable`
##     - Implementation: Fraser / Herlihy MPMC Lock-Free SkipList with Debra SMR and atomic associative operations (computeIfAbsent, atomicUpdate, upsert, snapshotPairs).
##   - **Concurrent Hash Trie Surface** (`lockfree/ctrie`):
##     - Core type: `Ctrie[K, V, MaxThreads]`
##     - Ergonomic aliases: `Table`, `ConcurrentTable`, `ConcurrentMap`, `ConcurrentTrie`
##     - Implementation: Aleksandar Prokopec MPMC Lock-Free Concurrent Hash Array Mapped Trie with O(1) Wait-Free Snapshots, Debra SMR, and atomic associative operations (computeIfAbsent, atomicUpdate, upsert, snapshotPairs).
##   - **Channel Facade** (`lockfree/channel`):
##     - `Channel[T]`, `Sender[T]`, `Receiver[T]` with automatic thread-local registration.
##   - **Rate Limiting Surface** (`lockfree/ratelimit`):
##     - `TokenBucket` / `TokenBucket128`: Hardware 128-bit DWCAS burst-tolerant rate limiter with zero-drift nano-tokens.
##     - `LeakyBucket` / `LeakyBucket128`: Hardware 128-bit DWCAS GCRA virtual scheduling traffic smoother.
##     - `TokenBucket64` / `LeakyBucket64`: Universal 64-bit single-word packed atomic rate limiters for minimal cacheline overhead and non-DWCAS targets.
##   - **Hardware 128-Bit DWCAS Surface** (`lockfree/bqueue128`, `lockfree/stack128`):
##     - `BQueue128`: Preallocated bounded MPMC queue with 128-bit atomic slot state (64-bit turn + 64-bit payload).
##     - `TaggedStack` / `Stack128`: MPMC LIFO stack with 128-bit atomic top (64-bit pointer + 64-bit ABA tag) and zero-SMR pooled freelist recycling.
##   - **Bounded Zero-SMR Surface** (`lockfree/bqueue`, `lockfree/bstack`, `lockfree/bpriority_queue`, `lockfree/btable`, `lockfree/disjoint_set`):
##     - `BQueue` / `BoundedQueue`: Preallocated bounded SPSC/MPSC/SPMC/MPMC FIFO queue.
##     - `BStack` / `BoundedStack`: Preallocated bounded SPSC/MPSC/SPMC/MPMC LIFO stack with elimination backoff.
##     - `BPriorityQueue` / `BoundedPriorityQueue`: Preallocated bounded SPSC/MPSC/SPMC/MPMC binary min-heap priority queue with strict FIFO tie-breaking.
##     - `BTable` / `BoundedTable`: Preallocated bounded SPSC/MPSC/SPMC/MPMC open-addressing concurrent hash table.
##     - `DisjointSet` / `UnionFind`: Preallocated zero-SMR concurrent Disjoint-Set (Union-Find / DSU) with wait-free CAS path splitting and rank-based union.
##   - Strategy / reclamation / pinscope-stub enums re-exported for
##     consumer code that references `stEager`, `stManual`, `ccSingle`,
##     `ccMulti` (and the legacy `rkNone`/`rkEbr` symbols) directly.

when compileOption("threads"):
  import lockfree/atomics
  import lockfree/atomics/dsl
  import ./lockfree/[atomic_arc, bpriority_queue, bqueue, broadcast, bstack, btable, cardinality, channel, ctrie, deque, disjoint_set, endpoint, exceptions, flat_combiner, priority_queue, queue, ratelimit, reclamation, rendezvous, set, skiplist, stack, strategy, streambuffer, taskpool, typestate_constructs]
  import ./lockfree/internal/pinscope_stub
  import ./lockfree/typestates/with_bound
  import ./lockfree/typestates/constructs

  export atomics, dsl
  export atomic_arc, bpriority_queue, bqueue, broadcast, bstack, btable, cardinality, channel, ctrie, deque, disjoint_set, endpoint, exceptions, flat_combiner, priority_queue, queue, ratelimit, reclamation, rendezvous, set, skiplist, stack, strategy, streambuffer, taskpool, typestate_constructs
  export pinscope_stub
  export with_bound, constructs

  when supportsDwcas:
    import ./lockfree/[bqueue128, stack128]
    export bqueue128, stack128

  when defined(lockfreeChronos) or defined(lockfreeAsyncdispatch):
    import ./lockfree/async_bridge
    export async_bridge
else:
  # threading off, only provide the unified Queue + bounded zero-SMR primitives
  # + supporting enums.
  import lockfree/atomics
  import lockfree/atomics/dsl
  import ./lockfree/[bpriority_queue, bqueue, bstack, btable, cardinality, channel, disjoint_set, endpoint, queue, reclamation, stack, strategy]
  import ./lockfree/internal/pinscope_stub
  import ./lockfree/typestates/with_bound
  import ./lockfree/typestates/constructs

  export atomics, dsl
  export bpriority_queue, bqueue, bstack, btable, cardinality, channel, disjoint_set, endpoint, queue, reclamation, stack, strategy
  export pinscope_stub
  export with_bound, constructs

  when supportsDwcas:
    import ./lockfree/[bqueue128, stack128]
    export bqueue128, stack128
