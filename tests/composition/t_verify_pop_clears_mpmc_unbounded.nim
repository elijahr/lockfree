## tests/composition/t_verify_pop_clears_mpmc_unbounded.nim
##
## C-MAJOR-11 technique 1: per-arm property test asserting the pop-side
## slot-clear invariant for the **MPMC unbounded** arm
## (`Queue[T, ccMulti, ccMulti, ST, S, MaxThreads]`).
##
## Three-technique acceptance stack (addendum design §2.9):
##   1. Property test (this file) — read-through-API probe. Push via
##      producer endpoint, pop via consumer endpoint across segment
##      boundaries; post-drain pop must return none. This is the LCRQ
##      cell-state arm — the DWCAS-based slot claim subsumes the
##      explicit `move()` clear used in the other three pop paths, and
##      this test exercises that path through several segment retires.
##   2. TSAN subset (cell 6): wired into `tests/test.nim`.
##   3. Light code audit: `docs/internal/q-cardinality-payload-clear.md`
##      (untracked scratch).

import std/options
import unittest2

import lockfree/queue
import lockfree/endpoint
import lockfree/role_tags
import lockfree/strategy

type
  Payload = object
    v: int

  RefPayload = ref Payload

const
  Seg = 16
  MaxThreads = 4
  Iters = 4
  PerCycle = Seg * 2

suite "pop payload-clear: MPMC unbounded":
  test "no stale slot residue across segment boundaries (ref Payload)":
    var q = newUnboundedMpmcQueue[RefPayload, stEager, Seg, MaxThreads]()
    var producer = q.getProducerHere()
    var consumer = q.getConsumerHere()
    var counter = 0
    for cycle in 0 ..< Iters:
      for i in 0 ..< PerCycle:
        let r = RefPayload(v: counter)
        producer.push(r)
        inc counter
      let baseline = counter - PerCycle
      for i in 0 ..< PerCycle:
        let popped = consumer.pop()
        check popped.isSome
        check popped.get.v == baseline + i
      check consumer.pop().isNone

  test "single-item cycle: no double-emit on second pop":
    var q = newUnboundedMpmcQueue[int, stEager, Seg, MaxThreads]()
    var producer = q.getProducerHere()
    var consumer = q.getConsumerHere()
    for i in 0 ..< 200:
      producer.push(i * 7 + 3)
      let popped = consumer.pop()
      check popped.isSome
      check popped.get == i * 7 + 3
      check consumer.pop().isNone
