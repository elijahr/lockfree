## lockfree — top-level umbrella module.
##
## The umbrella module exposes `LockfreeVersion` so the bench
## harness's `getAdapterVersions` can stamp the in-tree package version
## into the bench JSON `meta.adapters.lockfree.version` field
## without re-parsing `lockfree.nimble` at run time.
## Source-of-truth remains `lockfree.nimble`; this constant MUST
## be bumped in lockstep on every release.

const LockfreeVersion* {.strdefine.} = "0.1.0"
  ## In-tree package version. Mirrors the `version = "0.1.0"` line in
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
##     - `TokenBucket`: Hardware 128-bit DWCAS burst-tolerant rate limiter with zero-drift nano-tokens.
##     - `LeakyBucket`: Hardware 128-bit DWCAS GCRA virtual scheduling traffic smoother.
##   - Strategy / reclamation / pinscope-stub enums re-exported for
##     consumer code that references `stEager`, `stManual`, `ccSingle`,
##     `ccMulti` (and the legacy `rkNone`/`rkEbr` symbols) directly.

when compileOption("threads"):
  import lockfree/atomics
  import lockfree/atomics/dsl
  import ./lockfree/[bqueue, broadcast, cardinality, channel, ctrie, deque, endpoint, exceptions, queue, ratelimit, reclamation, rendezvous, set, skiplist, stack, strategy, streambuffer, taskpool]
  import ./lockfree/internal/pinscope_stub
  import ./lockfree/typestates/with_bound

  export atomics, dsl
  export bqueue, broadcast, cardinality, channel, ctrie, deque, endpoint, exceptions, queue, ratelimit, reclamation, rendezvous, set, skiplist, stack, strategy, streambuffer, taskpool
  export pinscope_stub
  export with_bound

  when defined(lockfreeAsyncdispatch):
    import ./lockfree/async_bridge
    export async_bridge
else:
  # threading off, only provide the unified Queue + its supporting enums
  # (Queue SPSC works without threads).
  import lockfree/atomics
  import lockfree/atomics/dsl
  import ./lockfree/[bqueue, cardinality, channel, endpoint, queue, reclamation, stack, strategy]
  import ./lockfree/internal/pinscope_stub
  import ./lockfree/typestates/with_bound

  export atomics, dsl
  export bqueue, cardinality, channel, endpoint, queue, reclamation, stack, strategy
  export pinscope_stub
  export with_bound
