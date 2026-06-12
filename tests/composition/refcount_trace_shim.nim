## tests/composition/refcount_trace_shim.nim
##
## Phase A scaffold for C-MAJOR-6: per-thread nimIncRef / nimDecRef
## counters used to assert refcount balance across the 5 use-pattern
## arms in `t_refcount_use_patterns.nim`.
##
## Gated on `-d:lockfreeRefcountTrace`. In the non-trace build the
## counters are zeroed and the assertions become trivially true, so
## the test file still compiles in normal CI. The actual matrix gate
## runs under `-d:lockfreeRefcountTrace`.
##
## The shim wraps the counters in `Atomic[int]`. The matrix tests
## themselves are single-threaded per addendum design §2.6, but the
## atomic form keeps the shim cheap to extend to multi-threaded smoke
## later.
##
## Design references
## -----------------
## * Addendum design §2.6 — refcount-balance matrix scope (5 arms).
## * Impl plan task C-MAJOR-6, Phase A — shim scaffold.

import std/atomics

when defined(lockfreeRefcountTrace):
  var
    incCounter*: Atomic[int]
    decCounter*: Atomic[int]

  proc countInc*(): int =
    incCounter.load(moRelaxed)

  proc countDec*(): int =
    decCounter.load(moRelaxed)

  proc bumpInc*() =
    discard incCounter.fetchAdd(1, moRelaxed)

  proc bumpDec*() =
    discard decCounter.fetchAdd(1, moRelaxed)

  proc resetCounters*() =
    incCounter.store(0, moRelaxed)
    decCounter.store(0, moRelaxed)

else:
  proc countInc*(): int =
    0

  proc countDec*(): int =
    0

  proc bumpInc*() =
    discard

  proc bumpDec*() =
    discard

  proc resetCounters*() =
    discard
