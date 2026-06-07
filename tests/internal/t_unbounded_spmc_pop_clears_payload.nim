## T-VERIFY-POP-CLEARS.unbounded-spmc — Regression test locking in the
## destructive-read behavior of the unbounded-SPMC pop path.
##
## Locks in the 2026-06-06 Phase 3.4 finding: the unbounded-SPMC pop
## site inlined in `queue.nim` reads the segment slot via
## `some(move(seg.data[seg.head]))`, which is observationally equivalent
## to `.reset()` for slot-clearing under all relevant `T` (per design
## §4.5.3 family (1)). This regression test guards against a future
## refactor silently reverting the destructive read to a plain (copying)
## assignment.
##
## REVERT CHECK
## ------------
## If the `some(move(seg.data[seg.head]))` at the inlined unbounded-SPMC
## pop site in `src/lockfree/queue.nim` (line ~1381) were reverted
## to a plain `some(seg.data[seg.head])` read, two assertions in this
## test would fail:
##
## 1. The `staticRead`-based grep-assert: the source no longer contains
##    the `some(move(seg.data[seg.head]))` substring (the SPMC-specific
##    anchor; the MPMC site uses `seg.data[mySlot]` instead, so the
##    anchor disambiguates the two `some(move(seg.data...))` sites in
##    `queue.nim`), so the `static doAssert` fires at compile time.
## 2. The runtime liveRefs assertion: after pop returns and the popped
##    local is reset to `nil`, the segment slot would still hold a copy
##    of the ref, keeping `liveRefs` at 1 instead of dropping it to 0.
##
## EXCLUDED ARMS
## -------------
## `mm:none` is intentionally excluded — that arm has a separate
## bit-transport contract per design §2.8 (no =copy/=destroy hooks fire,
## so the liveRefs accounting does not apply).
##
## On `mm:refc`, the tracing GC sweeps unreferenced refs on cycle
## regardless of whether `move()` ran in pop, so the liveRefs
## observation cannot distinguish a destructive read from a copying
## read — both code paths converge once the queue is destroyed and
## `GC_fullCollect` runs. The runtime liveRefs assertion is therefore
## gated to the ARC family (arc/orc/atomicArc), which have deterministic
## destructor semantics. The `staticRead` grep-assert is the universal
## CODE anchor and fires regardless of MM (it runs at compile time).

import std/atomics as std_atomics
import std/options
import std/strutils
import unittest2

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
  doAssert queue_nim_source.contains("some(move(seg.data[seg.head]))"),
    "DESTRUCTIVE-READ revert detected in src/lockfree/queue.nim: " &
    "expected substring `some(move(seg.data[seg.head]))` (the SPMC " &
    "unbounded pop site) not found. If you intentionally changed the " &
    "unbounded-SPMC pop mechanism, update " &
    "tests/internal/t_unbounded_spmc_pop_clears_payload.nim to match."

type
  RefCounterObj = object
    payload: int
  RefCounter = ref RefCounterObj

var liveRefs: std_atomics.Atomic[int]

proc `=destroy`(x: var RefCounterObj) =
  discard std_atomics.fetchSub(liveRefs, 1, std_atomics.moRelaxed)

proc newRefCounter(payload: int): RefCounter =
  result = RefCounter(payload: payload)
  discard std_atomics.fetchAdd(liveRefs, 1, std_atomics.moRelaxed)

suite "T-VERIFY-POP-CLEARS.unbounded-spmc — unbounded SPMC pop is destructive":
  test "pop clears segment slot (single push/pop)":
    liveRefs.store(0, std_atomics.moRelaxed)

    block lifecycle:
      var manager = initDebraManager[4, debra_mod.ccMulti]()
      var q = newUnboundedSpmcQueue[RefCounter, stEager, 16, 4](addr manager)

      block pushpop:
        let r = newRefCounter(42)
        check liveRefs.load(std_atomics.moRelaxed) == 1
        var producer = q.getProducerHere()
        producer.push(r)
      when defined(gcArc) or defined(gcOrc) or defined(gcAtomicArc):
        check liveRefs.load(std_atomics.moRelaxed) == 1

      block pop_and_drop:
        var consumer = q.getConsumerHere()
        let popped = consumer.pop()
        check popped.isSome
        check popped.get.payload == 42
      # If `move()` fired, the segment slot no longer holds the ref and
      # liveRefs drops to 0 once `popped` exits. If a plain copying read
      # were used, the segment slot would retain the ref and liveRefs
      # would still be 1. Gated to ARC-family per file header.
      when defined(gcArc) or defined(gcOrc) or defined(gcAtomicArc):
        check liveRefs.load(std_atomics.moRelaxed) == 0

    when defined(gcArc) or defined(gcOrc) or defined(gcAtomicArc):
      check liveRefs.load(std_atomics.moRelaxed) == 0
