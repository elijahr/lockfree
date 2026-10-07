## Move-analyzer and non-copyable payload verification test suite.
##
## Verifies that:
## 1. Unbounded MPMC (strict-LCRQ substrate with 128-bit DWCAS) accepts
##    and properly moves non-copyable 8-byte POD types whose `=copy` is disabled
##    with `{.error.}` without invoking copies or triggering move-analyzer defects.
## 2. Unbounded MPMC accepts managed ref payloads (`ref object`) routed via
##    Path C admission and ManagedRef slot encoding under strict-LCRQ.
## 3. Bounded MPMC (`BQueue`) continues to accept wide (> 8 bytes) non-copyable
##    payloads under the Vyukov per-slot sequence protocol.

import options
import unittest2

import lockfree/queue
import lockfree/bqueue
import lockfree/strategy
import lockfree/endpoint
import lockfree/smr/nebr as debra_mod
from lockfree/smr/nebr import DebraManager, initDebraManager

type
  MovePayload = object
    id: int

  RefPayload = ref object
    tag: int
    payload: seq[int]

  WidePayload = object
    a, b, c: int

proc `=copy`(dest: var MovePayload, src: MovePayload) {.error.}
proc `=copy`(dest: var WidePayload, src: WidePayload) {.error.}

suite "Move-Analyzer & Non-Copyable Payloads":

  test "Unbounded MPMC round-trips 8-byte move-only MovePayload":
    static:
      doAssert sizeof(MovePayload) == 8

    var manager = initDebraManager[4, debra_mod.ccMulti]()
    var q = newUnboundedMpmcQueue[MovePayload, stEager, 16, 4](addr manager)
    var producer = q.getProducerHere()
    var consumer = q.getConsumerHere()

    for i in 1 .. 8:
      var item = MovePayload(id: i * 10)
      producer.push(move(item))

    check q.len == 8

    for i in 1 .. 8:
      var popped = consumer.pop()
      check popped.isSome
      let val = move(popped.get())
      check val.id == i * 10

    check q.len == 0
    check consumer.pop().isNone

  test "Unbounded MPMC preserves FIFO ordering across segment boundary with MovePayload":
    var manager = initDebraManager[4, debra_mod.ccMulti]()
    # Small segment size (4) to force segment allocation and crossing.
    var q = newUnboundedMpmcQueue[MovePayload, stEager, 4, 4](addr manager)
    var producer = q.getProducerHere()
    var consumer = q.getConsumerHere()

    for i in 1 .. 12:
      var item = MovePayload(id: i)
      producer.push(move(item))

    check q.len == 12

    for i in 1 .. 12:
      var popped = consumer.pop()
      check popped.isSome
      let val = move(popped.get())
      check val.id == i

    check q.len == 0
    check consumer.pop().isNone

  test "Unbounded MPMC accepts managed RefPayload via Path C":
    var manager = initDebraManager[4, debra_mod.ccMulti]()
    var q = newUnboundedMpmcQueue[RefPayload, stEager, 16, 4](addr manager)
    var producer = q.getProducerHere()
    var consumer = q.getConsumerHere()

    for i in 1 .. 5:
      var item = RefPayload(tag: i, payload: @[i * 1, i * 2, i * 3])
      producer.push(move(item))

    check q.len == 5

    for i in 1 .. 5:
      var popped = consumer.pop()
      check popped.isSome
      let item = popped.get()
      check item.tag == i
      check item.payload == @[i * 1, i * 2, i * 3]

    check q.len == 0
    check consumer.pop().isNone

  test "BQueue MPMC accepts wide non-copyable WidePayload":
    static:
      doAssert sizeof(WidePayload) == 24

    var q = initBQueue[WidePayload, ccMulti, ccMulti, 16, 4, 4]()
    var producer = q.getProducerHere(0)
    var consumer = q.getConsumerHere(0)

    for i in 1 .. 6:
      var item = WidePayload(a: i, b: i * 10, c: i * 100)
      check producer.push(move(item))

    for i in 1 .. 6:
      var popped = consumer.pop()
      check popped.isSome
      let item = move(popped.get())
      check item.a == i
      check item.b == i * 10
      check item.c == i * 100

    check consumer.pop().isNone
