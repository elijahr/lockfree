## T-VERIFY-POP-CLEARS.unbounded-mpmc — Regression test locking in the
## destructive-read behavior of the unbounded-MPMC pop path.
##
## Locks in the 2026-06-06 Phase 3.4 finding (and OQ4.9 cross-reference):
## the unbounded-MPMC pop site DOES NOT use a `move(seg.data[mySlot])`
## read — that mechanism is the pre-strict-LCRQ code path, replaced
## during the Phase B migration by the DWCAS-based `tryClaim`
## extractor (`queue.nim` line 204 / §5.2.1 / §5.3).
##
## **IMPL PLAN ANCHOR CORRECTION**
## ------------------------------
## The impl plan `T-VERIFY-POP-CLEARS.unbounded-mpmc` task cites
## `queue.nim:1475` (`some(move(seg.data[mySlot]))`) as the MPMC pop
## anchor. That citation is incorrect: line 1476 is actually inside the
## **SPMC** second-variant pop (`Bound[..., Queue[T, ccSingle, ccMulti,
## ...]]`), and the legacy `move(seg.data[mySlot])` line referenced
## around line 1623 is an INFORMATIONAL comment describing the
## pre-strict-LCRQ MPMC pop — superseded by `tryClaim` since
## Phase B. The strict-LCRQ MPMC consumer never reads `seg.data[...]`
## (the field does not exist on MPMC segments; see `Segment[T,
## ccMulti, ccMulti, S]` which has `cells: array[S, LCRQCell[T]]`
## instead).
##
## The legitimate slot-clearing mechanism for MPMC is the
## CAS-then-default-store inside `tryClaim`:
##
## ```
## let desired = Pair[uint, T](first: observed.first, second: default(T))
## ...
## if compareExchangeStrong(cell, prev, desired, moAcquireRelease, moRelaxed):
##   return some(observed.second)
## ```
##
## i.e. the popped value is returned from `observed.second` while the
## cell payload is atomically replaced by `default(T)`. This regression
## test anchors on that mechanism instead, and verifies post-pop the
## cell's `.second` field reads back as `default(T)` (== 0 for int).
##
## REVERT CHECK
## ------------
## If the `desired = Pair[uint, T](first: observed.first, second:
## default(T))` line inside `tryClaim` (proc at line ~204) were reverted
## to a non-clearing form (e.g. `desired = observed` to leave the
## payload in place, or `desired = Pair(first: observed.first, second:
## observed.second)` for the same effect), two assertions in this test
## would fail:
##
## 1. The `staticRead`-based grep-assert: the source no longer contains
##    the `desired = Pair[uint, T](first: observed.first, second:
##    default(T))` substring, so the `static doAssert` fires at compile
##    time.
## 2. The runtime cell-inspection assertion: after pop returns, the
##    cell `.second` would still hold the original payload (42)
##    instead of `default(T)` (0).
##
## EXCLUDED ARMS
## -------------
## `mm:none` is intentionally excluded — that arm has a separate
## bit-transport contract per design §2.8 (no =copy/=destroy hooks fire,
## but for `int` T that is irrelevant since `int` is a pure value type).
## The mm:none exclusion is preserved for consistency with the other
## seven `T-VERIFY-POP-CLEARS` tests, which use a ref-counted
## instrumented type that genuinely depends on the ARC family.
##
## NOTE: this test uses `int` T (not the ref-counted `RefCounter` used
## by the other seven tests) because the MPMC unbounded path requires
## `supportsCopyMem(T)` (DWCAS pair-half constraint; see queue.nim
## §1166-1176 static-asserts). A ref-typed payload is structurally
## infeasible for MPMC unbounded regardless of `mm:arc` availability.

import std/options
import std/strutils
import unittest2

import lockfree/atomics
import lockfree/atomics/dsl
import lockfree/queue
import lockfree/strategy
import lockfree/reclamation
import lockfree/internal/pinscope_stub
import lockfree/endpoint
import lockfree/role_tags

import lockfree/smr/nebr as debra_mod
from lockfree/smr/nebr import initDebraManager

const queue_nim_source = staticRead("../../src/lockfree/queue.nim")
static:
  doAssert queue_nim_source.contains(
      "let desired = Pair[uint, T](first: observed.first, second: default(T))"
    ),
    "DESTRUCTIVE-READ revert detected in src/lockfree/queue.nim: " &
    "expected substring `let desired = Pair[uint, T](first: " &
    "observed.first, second: default(T))` (the MPMC unbounded " &
    "tryClaim slot-clearing mechanism) not found. If you intentionally " &
    "changed the MPMC pop mechanism, update " &
    "tests/internal/t_unbounded_mpmc_pop_clears_payload.nim to match."

const SENTINEL = 42

suite "T-VERIFY-POP-CLEARS.unbounded-mpmc — unbounded MPMC pop is destructive":
  test "pop clears cell payload (single push/pop)":
    var manager = initDebraManager[4, debra_mod.ccMulti]()
    var q = newUnboundedMpmcQueue[int, stEager, 16, 4](addr manager)

    var producer = q.getProducerHere()
    producer.push(SENTINEL)
    check q.len == 1

    var consumer = q.getConsumerHere()
    let popped = consumer.pop()
    check popped.isSome
    check popped.get == SENTINEL

    # The cell at the just-popped slot must now hold `default(T)` in its
    # `.second` field. The MPMC consumer claims slot index 0 of the head
    # segment first (prevConsumerIdx starts at -1, mySlot = 0). After
    # `tryClaim` succeeds, the cell DWCAS has written
    # `Pair(first: observed.first, second: default(T))`, so a load of
    # the cell payload must return `0` for `int` T.
    # `q` is a `var` queue, but `headSegment` field is reached via a
    # path that goes through the queue object — re-acquire via `addr`
    # for the atomic load. The post-pop state must hold cell.second ==
    # default(T) == 0.
    var headSegAtomic = addr q.headSegment
    let headSeg = headSegAtomic[].load(moAcquire)
    check headSeg != nil
    # Re-acquire-load the cell that the consumer just claimed.
    let cell = load(headSeg.cells[0], moAcquire)
    # If the slot was not cleared, this would still hold SENTINEL (42).
    check cell.second == 0
