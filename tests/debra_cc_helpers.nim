## Test helpers for v5.0.0 unbounded spmc/mpmc tests.
##
## The unbounded spmc/mpmc target imports `lockfree/queue` + nebr,
## both of which export a `PinScopeCardinality` enum with `ccSingle` /
## `ccMulti` members. v5.0.0 keeps the lockfree stub in place until
## the canonical enum is re-homed into nebr and the stub
## (`internal/pinscope_stub.nim`) is deleted. Until then,
## test files that need a ccMulti-typed `DebraManager` (spmc-equiv,
## mpmc-equiv) cannot import both `debra` and `lockfree/queue`
## unqualified without colliding on `ccMulti`.
##
## This helper module imports `debra` in isolation and exposes a single
## constructor that returns a ccMulti `DebraManager`. Callers can then
## `import lockfree` + use `Queue[..., ccMulti, ...]` types
## referring to the pinscope_stub members without ambiguity.

import lockfree/smr/nebr

proc initMultiConsumerManager*[MaxThreads: static int](): DebraManager[
    MaxThreads, ccMulti
] =
  ## Returns a fresh `DebraManager[MaxThreads, ccMulti]` for tests of
  ## `ccCons == ccMulti` queues (spmc-equiv, mpmc-equiv).
  initDebraManager[MaxThreads, ccMulti]()
