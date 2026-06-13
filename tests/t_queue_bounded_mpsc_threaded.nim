## Migrated from `t_mpsc_threaded.nim` — high-contention concurrent
## test for the unified Queue under MPSC cardinality.
##
## Mechanical conversion from the migration table:
##   ptr Mpsc[N, ProducerCount, int] -> ptr Queue[int, ccMulti, ccSingle,
##                                                    stEager, rkNone, N,
##                                                    ProducerCount, 0, 0, 0]
##   initMpsc[N, ProducerCount, int]() -> initQueue[int, ccMulti, ccSingle,
##                                                     stEager, N,
##                                                     ProducerCount, 0]()
##
## Test count parity: 2 tests (matches t_mpsc_threaded.nim).
## 7, 5, 6.1.

import lockfree/atomics
import lockfree/atomics/dsl
import options
import unittest2

import lockfree
import lockfree/bqueue as q_mod
import lockfree/strategy
import lockfree/reclamation
import lockfree/internal/pinscope_stub
import lockfree/endpoint
import lockfree/role_tags

const
  ItemCount = 10000
  ProducerCount = 4
  ItemsPerProducer = ItemCount div ProducerCount

type TestContext[N: static int] = object
  queue: ptr BQueue[int, ccMulti, ccSingle, N, ProducerCount, 0]
  received: ptr array[ItemCount, Atomic[bool]]
  duplicateFound: ptr Atomic[bool]
  producersDone: ptr Atomic[int]
  fifoViolation: ptr Atomic[bool]
  producerIdx: int

proc producer[N: static int](ctx: ptr TestContext[N]) {.thread.} =
  var p = ctx.queue[].getProducerHere()
  let base = ctx.producerIdx * ItemsPerProducer
  for i in 1 .. ItemsPerProducer:
    while not p.push(base + i):
      discard
  discard ctx.producersDone[].fetchAdd(1, moRelease)

proc consumer[N: static int](ctx: ptr TestContext[N]) {.thread.} =
  var consumed = 0
  # MPSC: a single consumer with multiple producers. Global order is not
  # FIFO across producers, but the contract IS per-producer FIFO: each
  # producer pushes its block `base+1 .. base+ItemsPerProducer` in order,
  # so values originating from the SAME producer must be observed in
  # strictly increasing order by the single consumer. We bucket the
  # last-seen value per producer (derived from the value range) and flag
  # any per-producer regression. This catches a reordering bug that
  # preserved count + uniqueness.
  var lastSeenPerProducer: array[ProducerCount, int]
  for j in 0 ..< ProducerCount:
    lastSeenPerProducer[j] = 0
  while consumed < ItemCount:
    let item = ctx.queue[].pop()
    if item.isSome:
      let raw = item.get # 1-indexed, in [1 .. ItemCount]
      let prod = (raw - 1) div ItemsPerProducer # originating producer
      if raw <= lastSeenPerProducer[prod]:
        ctx.fifoViolation[].store(true, moRelaxed)
      lastSeenPerProducer[prod] = raw
      let val = raw - 1
      if ctx.received[val].exchange(true, moRelaxed):
        ctx.duplicateFound[].store(true, moRelaxed)
      inc consumed
    elif ctx.producersDone[].load(moAcquire) >= ProducerCount:
      discard

suite "Queue MPSC threaded":
  var
    received: array[ItemCount, Atomic[bool]]
    duplicateFound: Atomic[bool]
    producersDone: Atomic[int]
    fifoViolation: Atomic[bool]

  setup:
    for i in 0 ..< ItemCount:
      received[i].store(false, moRelaxed)
    duplicateFound.store(false, moRelaxed)
    producersDone.store(0, moRelaxed)
    fifoViolation.store(false, moRelaxed)

  test "high contention":
    var queue = q_mod.newBQueue[int, ccMulti, ccSingle, 16, ProducerCount, 0]()

    var contexts: array[ProducerCount, TestContext[16]]
    for i in 0 ..< ProducerCount:
      contexts[i] = TestContext[16](
        queue: addr queue,
        received: addr received,
        duplicateFound: addr duplicateFound,
        producersDone: addr producersDone,
        fifoViolation: addr fifoViolation,
        producerIdx: i,
      )

    var consCtx = TestContext[16](
      queue: addr queue,
      received: addr received,
      duplicateFound: addr duplicateFound,
      producersDone: addr producersDone,
      fifoViolation: addr fifoViolation,
      producerIdx: 0,
    )

    var prodThreads: array[ProducerCount, Thread[ptr TestContext[16]]]
    var consThread: Thread[ptr TestContext[16]]

    for i in 0 ..< ProducerCount:
      createThread(prodThreads[i], producer[16], addr contexts[i])
    createThread(consThread, consumer[16], addr consCtx)

    for i in 0 ..< ProducerCount:
      joinThread(prodThreads[i])
    joinThread(consThread)

    check(not duplicateFound.load(moRelaxed))
    check(not fifoViolation.load(moRelaxed)) # per-producer FIFO order
    for i in 0 ..< ItemCount:
      check(received[i].load(moRelaxed))

  test "normal capacity":
    var queue = q_mod.newBQueue[int, ccMulti, ccSingle, 64, ProducerCount, 0]()

    var contexts: array[ProducerCount, TestContext[64]]
    for i in 0 ..< ProducerCount:
      contexts[i] = TestContext[64](
        queue: addr queue,
        received: addr received,
        duplicateFound: addr duplicateFound,
        producersDone: addr producersDone,
        fifoViolation: addr fifoViolation,
        producerIdx: i,
      )

    var consCtx = TestContext[64](
      queue: addr queue,
      received: addr received,
      duplicateFound: addr duplicateFound,
      producersDone: addr producersDone,
      fifoViolation: addr fifoViolation,
      producerIdx: 0,
    )

    var prodThreads: array[ProducerCount, Thread[ptr TestContext[64]]]
    var consThread: Thread[ptr TestContext[64]]

    for i in 0 ..< ProducerCount:
      createThread(prodThreads[i], producer[64], addr contexts[i])
    createThread(consThread, consumer[64], addr consCtx)

    for i in 0 ..< ProducerCount:
      joinThread(prodThreads[i])
    joinThread(consThread)

    check(not duplicateFound.load(moRelaxed))
    check(not fifoViolation.load(moRelaxed)) # per-producer FIFO order
    for i in 0 ..< ItemCount:
      check(received[i].load(moRelaxed))
