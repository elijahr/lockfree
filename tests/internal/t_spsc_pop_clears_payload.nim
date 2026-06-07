## T-VERIFY-POP-CLEARS.spsc — Regression test locking in the
## destructive-read behavior of the bounded-SPSC pop path.
##
## Locks in the 2026-06-06 Phase 3.4 finding: the bounded-SPSC pop
## reads the slot via `move(queue.storage[op.slot])`, which is
## observationally equivalent to `.reset()` for slot-clearing under
## all relevant `T` (per design §4.5.3 family (1)). This regression
## test guards against a future refactor silently reverting the
## destructive read to a plain (copying) assignment.
##
## REVERT CHECK
## ------------
## If the `move(queue.storage[op.slot])` at
## `src/lockfree/typestates/spsc_pop.nim:72` were reverted to a
## plain `queue.storage[op.slot]` read, two assertions in this test
## would fail:
##
## 1. The `staticRead`-based grep-assert: the source no longer contains
##    the `move(queue.storage[op.slot])` substring, so the doAssert at
##    compile time fires.
## 2. The runtime liveRefs assertion: after pop returns and the popped
##    local is reset to `nil`, the slot would still hold a copy of the
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

# ---------------------------------------------------------------------------
# CODE-anchor: grep-assert that the cited source still performs a destructive
# read via `move(...)`. Without this, a future refactor could silently swap
# the pop mechanism for a plain copying read, and the runtime test below
# might still pass (since ref destructors fire when the slot is overwritten
# on the next push), masking the regression.
# ---------------------------------------------------------------------------
const spsc_pop_source = staticRead("../../src/lockfree/typestates/spsc_pop.nim")
static:
  doAssert spsc_pop_source.contains("move(queue.storage[op.slot])"),
    "DESTRUCTIVE-READ revert detected at " &
    "src/lockfree/typestates/spsc_pop.nim: expected substring " &
    "`move(queue.storage[op.slot])` not found. If you intentionally " &
    "changed the SPSC pop mechanism (e.g. to `.reset()`), update " &
    "tests/internal/t_spsc_pop_clears_payload.nim to match."

# ---------------------------------------------------------------------------
# Instrumented ref type: a global atomic counter tracks every live instance
# (incremented on construction, decremented on destruction). After a pop the
# popped local is reset to nil; if the slot also no longer holds the ref,
# liveRefs must drop to 0.
# ---------------------------------------------------------------------------
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

suite "T-VERIFY-POP-CLEARS.spsc — bounded SPSC pop is destructive":
  test "pop clears slot (single push/pop)":
    liveRefs.store(0, moRelaxed)

    block lifecycle:
      var q = q_mod.newBQueue[RefCounter, ccSingle, ccSingle, 8, 0, 0]()
      block pushpop:
        let r = newRefCounter(42)
        check liveRefs.load(moRelaxed) == 1
        check q.push(r) == true
      # `r` is out of scope; only the slot holds a reference now.
      when defined(gcArc) or defined(gcOrc) or defined(gcAtomicArc):
        check liveRefs.load(moRelaxed) == 1

      block pop_and_drop:
        let popped = q.pop()
        check popped.isSome
        check popped.get.payload == 42

      # `popped` is out of scope. Under the ARC family (arc/orc/
      # atomicArc) destructors run deterministically on scope exit, so
      # liveRefs falls to 0 immediately if `move()` cleared the slot,
      # or stays at 1 if a plain copying read left the slot holding
      # the ref. Under refc this distinction is not observable (tracing
      # GC sweeps both paths identically once the queue is destroyed),
      # so this assertion is gated to the ARC family.
      when defined(gcArc) or defined(gcOrc) or defined(gcAtomicArc):
        check liveRefs.load(moRelaxed) == 0
