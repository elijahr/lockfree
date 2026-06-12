## Cache-line padding audit for unbounded queue Segments.
##
## Verifies two conditions per design doc §4.2:
## 1. Per-Segment cache-line-padded fields have field offsets that are
##    multiples of ``CacheLineBytes``.
## 2. ``cast[uint](segPtr) mod CacheLineBytes == 0`` for a freshly-allocated
##    Segment via the queue's allocator (base alignment).
##
## GREEN state (Tasks 3.2–3.3): both conditions hold for all four
## unbounded variants. ``posix_memalign`` is used to lift the segment base
## onto a 64-byte boundary, and ``{.align: CacheLineBytes.}`` is added to
## each Segment field that participates in producer/consumer coordination.
##
## v5.0.0 migration note:  the standalone
## `UnboundedSpsc[S, T]` was absorbed into
## `Queue[T, ccSingle, ccSingle, stEager, S, MaxThreads]`. The spsc
## padding checks now go through the unified Queue + Segment helpers
## like the other three variants.

import lockfree/atomics
import lockfree/atomics/dsl

import lockfree/queue as q_mod
import lockfree/strategy
import lockfree/reclamation
import lockfree/internal/pinscope_stub
import lockfree/endpoint
import lockfree/role_tags

# nebr surface for the unbounded smart-constructor manager. Selective
# `from ... import` matches the queue.nim convention and keeps
# `nebr.ccSingle` / `nebr.ccMulti` qualified-only, avoiding the
# unqualified `PinScopeCardinality` collision with the stub.
from lockfree/smr/nebr import DebraManager, initDebraManager, registerThread

import unittest2

# CacheLineBytes is provided by debra/atomics.

const Cl = CacheLineBytes

suite "Unbounded queue Segment cache-line padding":
  test "Segment field offsets are CacheLineBytes-aligned (spsc)":
    # Queue[T, ccSingle, ccSingle, _, 64, 4] — spsc-absorbed Segment
    # carries `tail` (Atomic) and `head` (non-atomic int) as cache-line-
    # padded fields. `committed` and `prevConsumerIdx` are not present.
    type Seg = q_mod.Segment[uint64, ccSingle, ccSingle, 64]
    check segmentTailOffsetForTest(Seg) mod Cl == 0
    check segmentHeadOffsetForTest(Seg) mod Cl == 0

  test "Segment field offsets are CacheLineBytes-aligned (spmc)":
    # Queue[T, ccSingle, ccMulti, _, 64, 4] — Segment for
    # the spmc-equiv shape carries `tail` and `prevConsumerIdx` as
    # cache-line-padded fields. `head` and `committed` are not present
    # on this shape (their helpers would compile-fail here).
    type Seg = q_mod.Segment[uint64, ccSingle, ccMulti, 64]
    check segmentTailOffsetForTest(Seg) mod Cl == 0
    check segmentPrevConsumerIdxOffsetForTest(Seg) mod Cl == 0

  test "Segment field offsets are CacheLineBytes-aligned (mpsc)":
    # Queue[T, ccMulti, ccSingle, _, rkEbr, ...] — Segment for the
    # mpsc-equiv shape carries `tail`, `head`, and `committed` as
    # cache-line-padded fields. `prevConsumerIdx` is not present.
    type Seg = q_mod.Segment[uint64, ccMulti, ccSingle, 64]
    check segmentTailOffsetForTest(Seg) mod Cl == 0
    check segmentHeadOffsetForTest(Seg) mod Cl == 0
    check segmentCommittedOffsetForTest(Seg) mod Cl == 0

  test "Segment field offsets are CacheLineBytes-aligned (mpmc)":
    # Queue[T, ccMulti, ccMulti, _, rkEbr, ...] — Segment for the
    # mpmc-equiv strict-LCRQ shape carries `tail`,
    # `prevConsumerIdx`, and `cells` as cache-line-padded fields.
    # `head` is not present on the ccProd==ccMulti × ccCons==ccMulti
    # shape (only on ccProd==ccMulti × ccCons==ccSingle). The strict-LCRQ
    # shape carries no `committed` field; the per-cell seq counter lives
    # inside each `Atomic[Pair[uint64, T]]` entry of `cells`.
    type Seg = q_mod.Segment[uint64, ccMulti, ccMulti, 64]
    check segmentTailOffsetForTest(Seg) mod Cl == 0
    check segmentPrevConsumerIdxOffsetForTest(Seg) mod Cl == 0
    check segmentCellsOffsetForTest(Seg) mod Cl == 0

  test "freshly-allocated Segment base is CacheLineBytes-aligned (spsc)":
    var q = newUnboundedSpscQueue[uint64, stEager, 64, 4]()
    let segPtr = headSegmentForTest(q)
    check segPtr != nil
    check (cast[uint](segPtr) mod Cl.uint) == 0

  test "freshly-allocated Segment base is CacheLineBytes-aligned (spmc)":
    var manager = initDebraManager[4, nebr.ccMulti]()
    var q = newUnboundedSpmcQueue[uint64, stEager, 64, 4](addr manager)
    let segPtr = headSegmentForTest(q)
    check segPtr != nil
    check (cast[uint](segPtr) mod Cl.uint) == 0

  test "freshly-allocated Segment base is CacheLineBytes-aligned (mpsc)":
    var manager = initDebraManager[4]()
    var q = newUnboundedMpscQueue[uint64, stEager, 64, 4](addr manager)
    let segPtr = headSegmentForTest(q)
    check segPtr != nil
    check (cast[uint](segPtr) mod Cl.uint) == 0

  test "freshly-allocated Segment base is CacheLineBytes-aligned (mpmc)":
    var manager = initDebraManager[4, nebr.ccMulti]()
    var q = newUnboundedMpmcQueue[uint64, stEager, 64, 4](addr manager)
    let segPtr = headSegmentForTest(q)
    check segPtr != nil
    check (cast[uint](segPtr) mod Cl.uint) == 0
