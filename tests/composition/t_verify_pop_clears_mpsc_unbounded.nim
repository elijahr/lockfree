## tests/composition/t_verify_pop_clears_mpsc_unbounded.nim
##
## C-MAJOR-11 technique 1: per-arm property test asserting the pop-side
## slot-clear invariant for the **MPSC unbounded** arm
## (`Queue[T, ccMulti, ccSingle, ST, S, MaxThreads]`).
##
## Three-technique acceptance stack (addendum design §2.9):
##   1. Property test (this file) — read-through-API probe. Push via
##      producer endpoint, pop via the bound single-consumer endpoint
##      across segment boundaries; post-drain pop must return none.
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

suite "pop payload-clear: MPSC unbounded":
  test "no stale slot residue across segment boundaries (ref Payload)":
    var q = newUnboundedMpscQueue[RefPayload, stEager, Seg, MaxThreads]()
    var consumer = q.bindConsumer()
    var producer = q.getProducerHere()
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
    var q = newUnboundedMpscQueue[int, stEager, Seg, MaxThreads]()
    var consumer = q.bindConsumer()
    var producer = q.getProducerHere()
    for i in 0 ..< 200:
      producer.push(i * 7 + 3)
      let popped = consumer.pop()
      check popped.isSome
      check popped.get == i * 7 + 3
      check consumer.pop().isNone
