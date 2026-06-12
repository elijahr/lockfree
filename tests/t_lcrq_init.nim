## Unit test: MPMC newSegment cell-init contract.
##
## With the `result.cells[i] = (seq=0, default(T))` store loop wired
## into the MPMC arm of `newSegment`, every slot of a freshly-allocated
## MPMC segment MUST observe the design §2.5.1 empty-cell state:
##   - `seq == 0` (low 63 bits of the epoch counter == 0)
##   - `payload == default(T)`
##
## Why this test passes against allocAligned zero-init even without the
## explicit store loop: `allocAligned[Segment[T, ccMulti, ccMulti, S]]`
## already zeros the page, and `(seq=0, default(int)=0)` IS the all-zero
## bit pattern. An empty `discard` body and the explicit-store loop are
## observationally indistinguishable on T=int with this allocator.
## The test still earns its keep as a regression guard: if a future
## change swaps `allocAligned` for `alloc` (no zero-init), drops the
## init loop, or introduces a non-zero empty sentinel without
## reseeding cells, this test fails. The teeth of the test bite under a
## non-zero store such as `Pair(first: 7'u64, second: 99)`, which fails
## assertion 1; the zero store passes.
##
## Design references:
##   §2.5.1 — state machine (empty cell = (seq=0, default(T)))
##   §4     — init path / progress argument

import std/unittest

import lockfree/queue
import lockfree/strategy
import lockfree/internal/pinscope_stub
import lockfree/smr/nebr as debra_mod
from lockfree/smr/nebr import DebraManager, initDebraManager
from lockfree/atomics import load, moRelaxed, Pair

suite "MPMC newSegment cell-init contract (design §2.5.1)":
  test "every cell of a fresh MPMC segment is (seq=0, default(T)=0) for T=int":
    var manager = initDebraManager[4, debra_mod.ccMulti]()
    var queue = newUnboundedMpmcQueue[int, stEager, 16, 4](addr manager)
    let segPtr = cast[ptr Segment[int, pinscope_stub.ccMulti, pinscope_stub.ccMulti, 16]](queue.headSegmentForTest())
    check segPtr != nil
    for i in 0 ..< 16:
      let observed = load(segPtr.cells[i], moRelaxed)
      check observed.first == 0'u
      check observed.second == 0

  test "every cell of a fresh MPMC segment is (seq=0, default(T)=nil) for T=ptr int":
    var manager = initDebraManager[4, debra_mod.ccMulti]()
    var queue = newUnboundedMpmcQueue[ptr int, stEager, 16, 4](addr manager)
    let segPtr = cast[ptr Segment[
      ptr int, pinscope_stub.ccMulti, pinscope_stub.ccMulti, 16
    ]](queue.headSegmentForTest())
    check segPtr != nil
    let nilPtr: ptr int = nil
    for i in 0 ..< 16:
      let observed = load(segPtr.cells[i], moRelaxed)
      check observed.first == 0'u
      check observed.second == nilPtr
