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

##
## Original module contract:
##   - Bounded surface: `BQueue[T, ccProd, ccCons, N, P, C]` in
##     `lockfree/bqueue`.
##   - Unbounded surface: `Queue[T, ccProd, ccCons, ST, S, MaxThreads]`
##     in `lockfree/queue`. The `(ccSingle, ccSingle)` branch
##     absorbs what was the standalone `UnboundedSpsc[S, T]` type
##     (debra-free, committed-flag-free linked-segment protocol).
##   - Strategy / reclamation / pinscope-stub enums re-exported for
##     consumer code that references `stEager`, `stManual`, `ccSingle`,
##     `ccMulti` (and the legacy `rkNone`/`rkEbr` symbols) directly.

when compileOption("threads"):
  import lockfree/atomics
  import lockfree/atomics/dsl
  import ./lockfree/[bqueue, exceptions, queue, reclamation, strategy]
  import ./lockfree/internal/pinscope_stub
  import ./lockfree/typestates/with_bound

  export atomics, dsl
  export bqueue, exceptions, queue, reclamation, strategy
  export pinscope_stub
  export with_bound
else:
  # threading off, only provide the unified Queue + its supporting enums
  # (Queue SPSC works without threads).
  import lockfree/atomics
  import lockfree/atomics/dsl
  import ./lockfree/[bqueue, queue, reclamation, strategy]
  import ./lockfree/internal/pinscope_stub
  import ./lockfree/typestates/with_bound

  export atomics, dsl
  export bqueue, queue, reclamation, strategy
  export pinscope_stub
  export with_bound
