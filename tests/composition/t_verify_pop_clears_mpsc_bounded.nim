## tests/composition/t_verify_pop_clears_mpsc_bounded.nim
##
## C-MAJOR-11 technique 1: per-arm property test asserting the pop-side
## slot-clear invariant for the **MPSC bounded** arm
## (`BQueue[T, ccMulti, ccSingle, N, P, 0]`).
##
## Three-technique acceptance stack (addendum design §2.9):
##   1. Property test (this file) — read-through-API probe (no internal
##      accessor flag). Push N values, pop N, verify each pop returns
##      the matching push value across wraparound cycles; a stale slot
##      would double-emit on the post-drain pop or leak across cycles.
##   2. TSAN subset (cell 6): wired into `tests/test.nim`.
##   3. Light code audit: `docs/internal/q-cardinality-payload-clear.md`
##      (untracked scratch).

import std/options
import unittest2

import lockfree/bqueue
import lockfree/endpoint
import lockfree/role_tags
import lockfree/strategy

type
  Payload = object
    v: int

  RefPayload = ref Payload

const
  Cap = 32
  Iters = 4

suite "pop payload-clear: MPSC bounded":
  test "no stale slot residue across wraparound cycles (ref Payload)":
    var q = newMpscQueue[RefPayload, Cap, 4]()
    var producer = q.getProducerHere(0)
    var counter = 0
    for cycle in 0 ..< Iters:
      for i in 0 ..< Cap:
        let r = RefPayload(v: counter)
        check producer.push(r)
        inc counter
      let baseline = counter - Cap
      for i in 0 ..< Cap:
        let popped = q.pop()
        check popped.isSome
        check popped.get.v == baseline + i
      # Slot-clear predicate: post-drain pop returns none (no
      # double-emit from a slot that retained popped bits).
      check q.pop().isNone

  test "single-item cycle: no double-emit on second pop":
    var q = newMpscQueue[int, Cap, 4]()
    var producer = q.getProducerHere(0)
    for i in 0 ..< 100:
      check producer.push(i * 7 + 3)
      let popped = q.pop()
      check popped.isSome
      check popped.get == i * 7 + 3
      check q.pop().isNone
