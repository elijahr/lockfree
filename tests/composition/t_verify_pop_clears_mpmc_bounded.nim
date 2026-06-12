## tests/composition/t_verify_pop_clears_mpmc_bounded.nim
##
## C-MAJOR-11 technique 1: per-arm property test asserting the pop-side
## slot-clear invariant for the **MPMC bounded** arm
## (`BQueue[T, ccMulti, ccMulti, N, P, C]`).
##
## Three-technique acceptance stack (addendum design §2.9):
##   1. Property test (this file) — read-through-API probe (no internal
##      accessor flag). Push via producer endpoint, pop via consumer
##      endpoint across wraparound cycles; post-drain pop must return
##      none (no double-emit from stale slot residue).
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

suite "pop payload-clear: MPMC bounded":
  test "no stale slot residue across wraparound cycles (ref Payload)":
    var q = newMpmcQueue[RefPayload, Cap, 4, 4]()
    var producer = q.getProducerHere(0)
    var consumer = q.getConsumerHere(0)
    var counter = 0
    for cycle in 0 ..< Iters:
      for i in 0 ..< Cap:
        let r = RefPayload(v: counter)
        check producer.push(r)
        inc counter
      let baseline = counter - Cap
      for i in 0 ..< Cap:
        let popped = consumer.pop()
        check popped.isSome
        check popped.get.v == baseline + i
      check consumer.pop().isNone

  test "single-item cycle: no double-emit on second pop":
    var q = newMpmcQueue[int, Cap, 4, 4]()
    var producer = q.getProducerHere(0)
    var consumer = q.getConsumerHere(0)
    for i in 0 ..< 100:
      check producer.push(i * 7 + 3)
      let popped = consumer.pop()
      check popped.isSome
      check popped.get == i * 7 + 3
      check consumer.pop().isNone
