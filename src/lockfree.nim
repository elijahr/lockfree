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
##     - Implementation: Fraser / Herlihy MPMC Lock-Free SkipList with Debra SMR.
##   - **Channel Facade** (`lockfree/channel`):
##     - `Channel[T]`, `Sender[T]`, `Receiver[T]` with automatic thread-local registration.
##   - Strategy / reclamation / pinscope-stub enums re-exported for
##     consumer code that references `stEager`, `stManual`, `ccSingle`,
##     `ccMulti` (and the legacy `rkNone`/`rkEbr` symbols) directly.

when compileOption("threads"):
  import lockfree/atomics
  import ./lockfree/[bqueue, cardinality, channel, deque, endpoint, exceptions, queue, reclamation, set, skiplist, stack, strategy]
  import ./lockfree/internal/pinscope_stub
  import ./lockfree/typestates/with_bound

  export atomics, dsl
  export bqueue, cardinality, channel, deque, endpoint, exceptions, queue, reclamation, set, skiplist, stack, strategy
  export pinscope_stub
  export with_bound
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
