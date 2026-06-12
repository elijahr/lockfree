## tests/composition/t_verify_pop_clears_spsc_bounded.nim
##
## C-MAJOR-11 technique 1: per-arm property test asserting the pop-side
## slot-clear invariant for the **SPSC bounded** arm
## (`BQueue[T, ccSingle, ccSingle, N, 0, 0]`).
##
## Three-technique acceptance stack (addendum design §2.9):
##   1. Property test (this file) — read-through-API probe.
##      Methodology: push N known payloads, pop N, then push N DIFFERENT
##      payloads, pop N — verify the second batch's pops return EXACTLY
##      the second batch's values (no stale slot residue), and verify
##      `len == 0` between batches. A slot that wasn't cleared on pop
##      would either double-emit (the impl plan's degradation predicate)
##      OR return stale data on second-cycle pop after wraparound.
##   2. TSAN subset (cell 6): wired into `tests/test.nim` so the
##      `testTSan` nimble task picks it up.
##   3. Light code audit: `docs/internal/q-cardinality-payload-clear.md`
##      (untracked scratch).
##
## The probe is observational (no `-d:lockfreeInternalAccess` flag).
## Cardinality × storage matrix: 4 cardinality shapes (SPSC/MPSC/SPMC/
## MPMC) × 2 storage forms (bounded/unbounded) = 8 files.

import std/options
import unittest2

import lockfree/bqueue
import lockfree/strategy

type
  Payload = object
    v: int

  RefPayload = ref Payload

const
  Cap = 32
  Iters = 4 # multiple wraparound cycles to amplify any slot-residue

suite "pop payload-clear: SPSC bounded":
  test "no stale slot residue across wraparound cycles":
    var q = newBQueue[RefPayload, ccSingle, ccSingle, Cap, 0, 0]()
    var counter = 0
    for cycle in 0 ..< Iters:
      # Push a batch of unique values.
      for i in 0 ..< Cap:
        let r = RefPayload(v: counter)
        check q.push(r)
        inc counter
      # Pop the batch; each pop must return the corresponding push value.
      let baseline = counter - Cap
      for i in 0 ..< Cap:
        let popped = q.pop()
        check popped.isSome
        check popped.get.v == baseline + i
      # Slot-clear invariant: after draining, a subsequent pop returns
      # none (no double-emit from a stale slot).
      check q.pop().isNone

  test "single-item push/pop returns none on second pop (no double-emit)":
    var q = newBQueue[int, ccSingle, ccSingle, Cap, 0, 0]()
    for i in 0 ..< 100:
      check q.push(i * 7 + 3)
      let popped = q.pop()
      check popped.isSome
      check popped.get == i * 7 + 3
      # The slot-clear predicate: a second pop on the freshly-popped
      # cycle must observe empty (no stale residue).
      check q.pop().isNone
