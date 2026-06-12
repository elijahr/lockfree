## tests/composition/t_verify_pop_clears_spmc_bounded.nim
##
## C-MAJOR-11 technique 1: per-arm property test asserting the pop-side
## slot-clear invariant for the **SPMC bounded** arm
## (`BQueue[T, ccSingle, ccMulti, N, 0, C]`).
##
## Three-technique acceptance stack (addendum design §2.9):
##   1. Property test (this file) — read-through-API probe. Push N via
##      direct `BQueue.push`, pop N via `getConsumerHere(0).pop`, verify
##      values across wraparound cycles; post-drain pop must return none.
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

suite "pop payload-clear: SPMC bounded":
  test "no stale slot residue across wraparound cycles (ref Payload)":
    var q = newSpmcQueue[RefPayload, Cap, 4]()
    var consumer = q.getConsumerHere(0)
    var counter = 0
    for cycle in 0 ..< Iters:
      for i in 0 ..< Cap:
        let r = RefPayload(v: counter)
        check q.push(r)
        inc counter
      let baseline = counter - Cap
      for i in 0 ..< Cap:
        let popped = consumer.pop()
        check popped.isSome
        check popped.get.v == baseline + i
      check consumer.pop().isNone

  test "single-item cycle: no double-emit on second pop":
    var q = newSpmcQueue[int, Cap, 4]()
    var consumer = q.getConsumerHere(0)
    for i in 0 ..< 100:
      check q.push(i * 7 + 3)
      let popped = consumer.pop()
      check popped.isSome
      check popped.get == i * 7 + 3
      check consumer.pop().isNone
