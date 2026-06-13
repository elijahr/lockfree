## tests/composition/slice_dispose_trace_shim.nim
##
## String-vs-seq slice-dispose counters, gated by
## `-d:lockfreeSliceDisposeTrace`, used to assert that a `seq[char]`
## slot is routed to the SEQ disposer (`disposeSeqSlot`) and NOT the
## non-generic string disposer (`disposeSlot(ManagedSlice[char])`) in
## `t_seq_char_dispose.nim`. The bug being guarded is the overload
## collision where `ManagedSlice[char]` is the slot encoding for BOTH
## `string` and `seq[char]`.
##
## Gated on `-d:lockfreeSliceDisposeTrace`. In the non-trace build the
## counters are zeroed and the assertions become trivially true, so the
## test file still compiles in normal CI. The actual gate runs under
## `-d:lockfreeSliceDisposeTrace`.
##
## The shim wraps the counters in `Atomic[int]`. The tests themselves
## are single-threaded, but the atomic form keeps the shim cheap to
## extend to multi-threaded smoke later.
##
## Mirrors the structure of `refcount_trace_shim.nim` exactly.

import std/atomics

when defined(lockfreeSliceDisposeTrace):
  var
    stringDisposeCounter*: Atomic[int]
    seqDisposeCounter*: Atomic[int]

  proc countStringDispose*(): int =
    stringDisposeCounter.load(moRelaxed)

  proc countSeqDispose*(): int =
    seqDisposeCounter.load(moRelaxed)

  proc bumpStringDispose*() =
    discard stringDisposeCounter.fetchAdd(1, moRelaxed)

  proc bumpSeqDispose*() =
    discard seqDisposeCounter.fetchAdd(1, moRelaxed)

  proc resetSliceDisposeCounters*() =
    stringDisposeCounter.store(0, moRelaxed)
    seqDisposeCounter.store(0, moRelaxed)

else:
  proc countStringDispose*(): int =
    0

  proc countSeqDispose*(): int =
    0

  proc bumpStringDispose*() =
    discard

  proc bumpSeqDispose*() =
    discard

  proc resetSliceDisposeCounters*() =
    discard
