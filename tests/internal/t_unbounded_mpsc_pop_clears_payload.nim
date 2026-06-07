## T-VERIFY-POP-CLEARS.unbounded-mpsc — Regression test locking in the
## destructive-read behavior of the unbounded-MPSC pop path.
##
## Locks in the 2026-06-06 Phase 3.4 finding: the unbounded-MPSC pop
## site inlined in `queue.nim` reads the segment slot via
## `move(seg.data[head])`, which is observationally equivalent to
## `.reset()` for slot-clearing under all relevant `T` (per design
## §4.5.3 family (1)). This regression test guards against a future
## refactor silently reverting the destructive read to a plain (copying)
## assignment.
##
## REVERT CHECK
## ------------
## If the `let value = move(seg.data[head])` at the inlined
## unbounded-MPSC pop site in `src/lockfree/queue.nim` (line
## ~875) were reverted to a plain `let value = seg.data[head]` read,
## two assertions in this test would fail:
##
## 1. The `staticRead`-based grep-assert: the source no longer contains
##    the `let value = move(seg.data[head])` substring (the MPSC-
##    specific anchor; the SPSC site uses `let v = ...` instead, so the
##    anchor disambiguates the two `move(seg.data[head])` sites in
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

import lockfree/smr/nebr
import lockfree
import lockfree/endpoint
import lockfree/role_tags

const queue_nim_source = staticRead("../../src/lockfree/queue.nim")
static:
  doAssert queue_nim_source.contains("let value = move(seg.data[head])"),
    "DESTRUCTIVE-READ revert detected in src/lockfree/queue.nim: " &
    "expected substring `let value = move(seg.data[head])` (the MPSC " &
    "unbounded pop site) not found. If you intentionally changed the " &
    "unbounded-MPSC pop mechanism, update " &
    "tests/internal/t_unbounded_mpsc_pop_clears_payload.nim to match."

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

suite "T-VERIFY-POP-CLEARS.unbounded-mpsc — unbounded MPSC pop is destructive":
  test "pop clears segment slot (single push/pop)":
    liveRefs.store(0, std_atomics.moRelaxed)

    block lifecycle:
      var manager = initDebraManager[4]()
      var q = newUnboundedMpscQueue[RefCounter, stEager, 16, 4](addr manager)
      var lfqConsumer = q.bindConsumer()

      block pushpop:
        let r = newRefCounter(42)
        check liveRefs.load(std_atomics.moRelaxed) == 1
        var producer = q.getProducerHere()
        producer.push(r)
      when defined(gcArc) or defined(gcOrc) or defined(gcAtomicArc):
        check liveRefs.load(std_atomics.moRelaxed) == 1

      block pop_and_drop:
        let popped = lfqConsumer.pop()
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
