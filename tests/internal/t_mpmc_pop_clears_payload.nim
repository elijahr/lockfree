## T-VERIFY-POP-CLEARS.mpmc — Regression test locking in the
## destructive-read behavior of the bounded-MPMC pop path.
##
## Locks in the 2026-06-06 Phase 3.4 finding: the bounded-MPMC pop
## reads the cell via `move(queue.cells.dataPtr(op.slot)[])`, which is
## observationally equivalent to `.reset()` for slot-clearing under
## all relevant `T` (per design §4.5.3 family (1)). This regression
## test guards against a future refactor silently reverting the
## destructive read to a plain (copying) cell access.
##
## REVERT CHECK
## ------------
## If the `move(queue.cells.dataPtr(op.slot)[])` at
## `src/lockfree/typestates/mpmc_pop.nim:99` were reverted to a
## plain `queue.cells.dataPtr(op.slot)[]` read, two assertions in this
## test would fail:
##
## 1. The `staticRead`-based grep-assert: the source no longer contains
##    the `move(queue.cells.dataPtr(op.slot)[])` substring, so the
##    `static doAssert` fires at compile time.
## 2. The runtime liveRefs assertion: after pop returns and the popped
##    local is reset to `nil`, the cell would still hold a copy of the
##    ref, keeping `liveRefs` at 1 instead of dropping it to 0.
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

import lockfree
import lockfree/bqueue as q_mod
import lockfree/strategy
import lockfree/reclamation
import lockfree/internal/pinscope_stub
import lockfree/endpoint
import lockfree/role_tags

const mpmc_pop_source = staticRead("../../src/lockfree/typestates/mpmc_pop.nim")
static:
  doAssert mpmc_pop_source.contains("move(queue.cells.dataPtr(op.slot)[])"),
    "DESTRUCTIVE-READ revert detected at " &
    "src/lockfree/typestates/mpmc_pop.nim: expected substring " &
    "`move(queue.cells.dataPtr(op.slot)[])` not found. If you " &
    "intentionally changed the MPMC pop mechanism (e.g. to `.reset()`), " &
    "update tests/internal/t_mpmc_pop_clears_payload.nim to match."

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

suite "T-VERIFY-POP-CLEARS.mpmc — bounded MPMC pop is destructive":
  test "pop clears cell (single push/pop)":
    liveRefs.store(0, std_atomics.moRelaxed)

    block lifecycle:
      var q = q_mod.newBQueue[RefCounter, ccMulti, ccMulti, 8, 4, 4]()
      block pushpop:
        let r = newRefCounter(42)
        check liveRefs.load(std_atomics.moRelaxed) == 1
        var producer = q.getProducerHere(0)
        check producer.push(r) == true
      # `r` is out of scope; only the cell holds a reference now.
      when defined(gcArc) or defined(gcOrc) or defined(gcAtomicArc):
        check liveRefs.load(std_atomics.moRelaxed) == 1

      block pop_and_drop:
        var consumer = q.getConsumerHere(0)
        let popped = consumer.pop()
        check popped.isSome
        check popped.get.payload == 42
      # `popped` and `consumer` are out of scope. If the cell was cleared
      # by `move()`, no references remain and the object's `=destroy` ran,
      # dropping liveRefs to 0. If a plain copying read were used instead,
      # the cell would still hold the ref, keeping liveRefs at 1.
      when defined(gcArc) or defined(gcOrc) or defined(gcAtomicArc):
        check liveRefs.load(std_atomics.moRelaxed) == 0

    when defined(gcArc) or defined(gcOrc) or defined(gcAtomicArc):
      check liveRefs.load(std_atomics.moRelaxed) == 0
