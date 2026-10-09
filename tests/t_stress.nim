## High-volume stress tests for all bounded queue types.
## Tests 100k+ messages to catch ring buffer collision bugs.

when not compileOption("threads"):
  {.error: "t_stress requires --threads:on option.".}

import std/[options, os, algorithm]
import unittest2
import lockfree
import lockfree/endpoint
import lockfree/role_tags
import lockfree/atomics
import lockfree/atomics/dsl
import lockfree/atomics/backoff
import lockfree/stack
import lockfree/deque
import lockfree/skiplist
import lockfree/set

const
  SmallBuffer = 16
  StandardBuffer = 1024
  LargeBuffer = 4096

  Count10k = 10_000
  Count20k = 20_000
  Count40k = 40_000
  Count100k = 100_000

type TestObject = object
  id: int
  payload: string
  checksum: uint32

# The object-payload stress arm transports `ref TestObject`, not a bare
# `TestObject`. A value object containing a `string` field is rejected by
# Path-C admission (`src/lockfree/internal/path_c_admit.nim` value-type-
# with-managed-fields arm); the canonical fix the reject message itself
# prescribes is to wrap in a `ref`, which the queue admits via its
# ManagedRef refcount path. This preserves the object-payload + checksum
# coverage (a wide POD object would lose the managed-field exercise).
type TestObjectRef = ref TestObject

proc computeChecksum(id: int, payload: string): uint32 =
  result = uint32(id)
  for c in payload:
    result = result xor uint32(ord(c))

# =============================================================================
# Spsc (SPSC) Stress Tests
# =============================================================================

suite "Stress - Spsc (SPSC)":
  test "Spsc 100k int":
    var queue = newSpscQueue[int, StandardBuffer]()

    # Interleave push with drain-on-full so every item is accounted for.
    # `pushed` counts items that entered the queue (either directly or
    # after popping to make room); `popped` counts items drained during
    # the fill phase plus the final drain below. A ring-buffer collision
    # that silently dropped items would break the exact pushed == popped
    # equality (the former `popped > 0` passed even with 99,999 losses).
    var pushed = 0
    var popped = 0
    for i in 0 ..< Count100k:
      while not queue.push(i):
        # Pop to make room, accounting for the drained item.
        if queue.pop().isSome:
          inc popped
      inc pushed

    # Drain remaining items.
    while true:
      let item = queue.pop()
      if item.isNone:
        break
      inc popped

    check pushed == Count100k
    check pushed == popped

  test "Spsc 100k with buffer=16 (frequent wrapping)":
    var queue = newSpscQueue[int, SmallBuffer]()
    var pushed = 0
    var popped = 0

    # Interleaved push/pop to stress wraparound
    for i in 0 ..< Count100k:
      if queue.push(i):
        inc pushed
      let item = queue.pop()
      if item.isSome:
        inc popped

    # Drain remaining
    while true:
      let item = queue.pop()
      if item.isNone:
        break
      inc popped

    check pushed == popped

  test "Spsc 100k string":
    var queue = newSpscQueue[string, StandardBuffer]()
    var pushed = 0
    var popped = 0

    for i in 0 ..< Count100k:
      if queue.push("message_" & $i):
        inc pushed
      let item = queue.pop()
      if item.isSome:
        inc popped

    # Drain
    while true:
      let item = queue.pop()
      if item.isNone:
        break
      inc popped

    check pushed == popped

  test "Spsc 100k TestObject with checksum verification":
    var queue = newSpscQueue[TestObjectRef, StandardBuffer]()
    var pushed = 0
    var verified = 0

    for i in 0 ..< Count100k:
      let payload = "payload_" & $i
      let obj = TestObjectRef(
        id: i, payload: payload, checksum: computeChecksum(i, payload)
      )
      if queue.push(obj):
        inc pushed

      let item = queue.pop()
      if item.isSome:
        let got = item.get
        check got.checksum == computeChecksum(got.id, got.payload)
        inc verified

    # Drain and verify remaining
    while true:
      let item = queue.pop()
      if item.isNone:
        break
      let got = item.get
      check got.checksum == computeChecksum(got.id, got.payload)
      inc verified

    check pushed == verified

# =============================================================================
# Mpmc (MPMC) Stress Tests
# =============================================================================

type
  MpmcPCtx[N, P, C: static int, T] = object
    queue: ptr BQueue[T, ccMulti, ccMulti, N, P, C]
    count: int
    producerIdx: int
    sent: ptr Atomic[int]

  MpmcCCtx[N, P, C: static int, T] = object
    queue: ptr BQueue[T, ccMulti, ccMulti, N, P, C]
    count: int
    consumerIdx: int
    received: ptr Atomic[int]

proc mpmcProducer[N, P, C: static int](ctx: ptr MpmcPCtx[N, P, C, int]) {.thread.} =
  # `getProducerHere(idx)` reserves the pinned slot AND binds the endpoint
  # to this thread in one step. The bare `getProducer(idx)` returns an
  # Unbound endpoint, on which `push` is a compile error (the Bound/Unbound
  # typestate guard requires bindToThread() before any push).
  var p = ctx.queue[].getProducerHere(idx = ctx.producerIdx)
  for i in 0 ..< ctx.count:
    while not p.push(i):
      discard
    discard ctx.sent[].fetchAdd(1, moRelaxed)

proc mpmcConsumer[N, P, C: static int](ctx: ptr MpmcCCtx[N, P, C, int]) {.thread.} =
  var c = ctx.queue[].getConsumerHere(idx = ctx.consumerIdx)
  var localReceived = 0
  while localReceived < ctx.count:
    let item = c.pop()
    if item.isSome:
      inc localReceived
      discard ctx.received[].fetchAdd(1, moRelaxed)

suite "Stress - Mpmc (MPMC)":
  test "Mpmc 1P/1C 10k int":
    var queue = newMpmcQueue[int, StandardBuffer, 1, 1]()
    var sent, received: Atomic[int]
    sent.store(0, moRelaxed)
    received.store(0, moRelaxed)

    var pctx = MpmcPCtx[StandardBuffer, 1, 1, int](
      queue: addr queue, count: Count10k, producerIdx: 0, sent: addr sent
    )
    var cctx = MpmcCCtx[StandardBuffer, 1, 1, int](
      queue: addr queue, count: Count10k, consumerIdx: 0, received: addr received
    )

    var pThread: Thread[ptr MpmcPCtx[StandardBuffer, 1, 1, int]]
    var cThread: Thread[ptr MpmcCCtx[StandardBuffer, 1, 1, int]]

    createThread(pThread, mpmcProducer[StandardBuffer, 1, 1], addr pctx)
    createThread(cThread, mpmcConsumer[StandardBuffer, 1, 1], addr cctx)

    joinThread(pThread)
    joinThread(cThread)

    check sent.load(moRelaxed) == Count10k
    check received.load(moRelaxed) == Count10k

  test "Mpmc 2P/2C 10k int":
    var queue = newMpmcQueue[int, StandardBuffer, 2, 2]()
    var sent, received: Atomic[int]
    sent.store(0, moRelaxed)
    received.store(0, moRelaxed)

    const PerThread = Count10k div 2

    var pctx0 = MpmcPCtx[StandardBuffer, 2, 2, int](
      queue: addr queue, count: PerThread, producerIdx: 0, sent: addr sent
    )
    var pctx1 = MpmcPCtx[StandardBuffer, 2, 2, int](
      queue: addr queue, count: PerThread, producerIdx: 1, sent: addr sent
    )
    var cctx0 = MpmcCCtx[StandardBuffer, 2, 2, int](
      queue: addr queue, count: PerThread, consumerIdx: 0, received: addr received
    )
    var cctx1 = MpmcCCtx[StandardBuffer, 2, 2, int](
      queue: addr queue, count: PerThread, consumerIdx: 1, received: addr received
    )

    var pThreads: array[2, Thread[ptr MpmcPCtx[StandardBuffer, 2, 2, int]]]
    var cThreads: array[2, Thread[ptr MpmcCCtx[StandardBuffer, 2, 2, int]]]

    createThread(pThreads[0], mpmcProducer[StandardBuffer, 2, 2], addr pctx0)
    createThread(pThreads[1], mpmcProducer[StandardBuffer, 2, 2], addr pctx1)
    createThread(cThreads[0], mpmcConsumer[StandardBuffer, 2, 2], addr cctx0)
    createThread(cThreads[1], mpmcConsumer[StandardBuffer, 2, 2], addr cctx1)

    joinThread(pThreads[0])
    joinThread(pThreads[1])
    joinThread(cThreads[0])
    joinThread(cThreads[1])

    check sent.load(moRelaxed) == Count10k
    check received.load(moRelaxed) == Count10k

  test "Mpmc 2P/2C 10k with buffer=16 (stress wraparound)":
    var queue = newMpmcQueue[int, SmallBuffer, 2, 2]()
    var sent, received: Atomic[int]
    sent.store(0, moRelaxed)
    received.store(0, moRelaxed)

    const PerThread = Count10k div 2

    var pctx0 = MpmcPCtx[SmallBuffer, 2, 2, int](
      queue: addr queue, count: PerThread, producerIdx: 0, sent: addr sent
    )
    var pctx1 = MpmcPCtx[SmallBuffer, 2, 2, int](
      queue: addr queue, count: PerThread, producerIdx: 1, sent: addr sent
    )
    var cctx0 = MpmcCCtx[SmallBuffer, 2, 2, int](
      queue: addr queue, count: PerThread, consumerIdx: 0, received: addr received
    )
    var cctx1 = MpmcCCtx[SmallBuffer, 2, 2, int](
      queue: addr queue, count: PerThread, consumerIdx: 1, received: addr received
    )

    var pThreads: array[2, Thread[ptr MpmcPCtx[SmallBuffer, 2, 2, int]]]
    var cThreads: array[2, Thread[ptr MpmcCCtx[SmallBuffer, 2, 2, int]]]

    createThread(pThreads[0], mpmcProducer[SmallBuffer, 2, 2], addr pctx0)
    createThread(pThreads[1], mpmcProducer[SmallBuffer, 2, 2], addr pctx1)
    createThread(cThreads[0], mpmcConsumer[SmallBuffer, 2, 2], addr cctx0)
    createThread(cThreads[1], mpmcConsumer[SmallBuffer, 2, 2], addr cctx1)

    joinThread(pThreads[0])
    joinThread(pThreads[1])
    joinThread(cThreads[0])
    joinThread(cThreads[1])

    check sent.load(moRelaxed) == Count10k
    check received.load(moRelaxed) == Count10k

  test "Mpmc 1P/1C 100k int":
    var queue = newMpmcQueue[int, StandardBuffer, 1, 1]()
    var sent, received: Atomic[int]
    sent.store(0, moRelaxed)
    received.store(0, moRelaxed)

    var pctx = MpmcPCtx[StandardBuffer, 1, 1, int](
      queue: addr queue, count: Count100k, producerIdx: 0, sent: addr sent
    )
    var cctx = MpmcCCtx[StandardBuffer, 1, 1, int](
      queue: addr queue, count: Count100k, consumerIdx: 0, received: addr received
    )

    var pThread: Thread[ptr MpmcPCtx[StandardBuffer, 1, 1, int]]
    var cThread: Thread[ptr MpmcCCtx[StandardBuffer, 1, 1, int]]

    createThread(pThread, mpmcProducer[StandardBuffer, 1, 1], addr pctx)
    createThread(cThread, mpmcConsumer[StandardBuffer, 1, 1], addr cctx)

    joinThread(pThread)
    joinThread(cThread)

    check sent.load(moRelaxed) == Count100k
    check received.load(moRelaxed) == Count100k

type
  MpmcStressPCtx[N: static int] = object
    queue: ptr BQueue[int, ccMulti, ccMulti, N, 4, 4]
    count: int
    producerIdx: int
    sent: ptr Atomic[int]
    producersDone: ptr Atomic[int]

  MpmcStressCCtx[N: static int] = object
    queue: ptr BQueue[int, ccMulti, ccMulti, N, 4, 4]
    consumerIdx: int
    totalExpected: int
    totalProducers: int
    received: ptr Atomic[int]
    totalConsumed: ptr Atomic[int]
    producersDone: ptr Atomic[int]

proc mpmcStressProducer[N: static int](ctx: ptr MpmcStressPCtx[N]) {.thread.} =
  var p = ctx.queue[].getProducerHere(idx = ctx.producerIdx)
  for i in 0 ..< ctx.count:
    while not p.push(i):
      cpuPause()
    discard ctx.sent[].fetchAdd(1, moRelaxed)
  discard ctx.producersDone[].fetchAdd(1, moRelease)

proc mpmcStressConsumer[N: static int](ctx: ptr MpmcStressCCtx[N]) {.thread.} =
  var c = ctx.queue[].getConsumerHere(idx = ctx.consumerIdx)
  while true:
    let item = c.pop()
    if item.isSome:
      discard ctx.received[].fetchAdd(1, moRelaxed)
      if ctx.totalConsumed[].fetchAdd(1, moRelaxed) + 1 >= ctx.totalExpected:
        break
    elif ctx.producersDone[].load(moAcquire) >= ctx.totalProducers:
      if ctx.totalConsumed[].load(moRelaxed) >= ctx.totalExpected:
        break
      cpuPause()
    else:
      cpuPause()

suite "Stress - Mpmc (MPMC) - 4P:4C High Contention":
  test "Mpmc 4P/4C 100k int (StandardBuffer=1024)":
    var queue = newMpmcQueue[int, StandardBuffer, 4, 4]()
    var sent, received, totalConsumed, producersDone: Atomic[int]
    sent.store(0, moRelaxed)
    received.store(0, moRelaxed)
    totalConsumed.store(0, moRelaxed)
    producersDone.store(0, moRelaxed)

    const PerProducer = Count100k div 4

    var pctxs: array[4, MpmcStressPCtx[StandardBuffer]]
    var cctxs: array[4, MpmcStressCCtx[StandardBuffer]]
    var pThreads: array[4, Thread[ptr MpmcStressPCtx[StandardBuffer]]]
    var cThreads: array[4, Thread[ptr MpmcStressCCtx[StandardBuffer]]]

    for i in 0 ..< 4:
      pctxs[i] = MpmcStressPCtx[StandardBuffer](
        queue: addr queue, count: PerProducer, producerIdx: i,
        sent: addr sent, producersDone: addr producersDone
      )
      cctxs[i] = MpmcStressCCtx[StandardBuffer](
        queue: addr queue, consumerIdx: i, totalExpected: Count100k, totalProducers: 4,
        received: addr received, totalConsumed: addr totalConsumed, producersDone: addr producersDone
      )

    for i in 0 ..< 4:
      createThread(pThreads[i], mpmcStressProducer[StandardBuffer], addr pctxs[i])
      createThread(cThreads[i], mpmcStressConsumer[StandardBuffer], addr cctxs[i])

    for i in 0 ..< 4:
      joinThread(pThreads[i])
      joinThread(cThreads[i])

    check sent.load(moRelaxed) == Count100k
    check received.load(moRelaxed) == Count100k

  test "Mpmc 4P/4C 100k int (SmallBuffer=16 wraparound)":
    var queue = newMpmcQueue[int, SmallBuffer, 4, 4]()
    var sent, received, totalConsumed, producersDone: Atomic[int]
    sent.store(0, moRelaxed)
    received.store(0, moRelaxed)
    totalConsumed.store(0, moRelaxed)
    producersDone.store(0, moRelaxed)

    const PerProducer = Count100k div 4

    var pctxs: array[4, MpmcStressPCtx[SmallBuffer]]
    var cctxs: array[4, MpmcStressCCtx[SmallBuffer]]
    var pThreads: array[4, Thread[ptr MpmcStressPCtx[SmallBuffer]]]
    var cThreads: array[4, Thread[ptr MpmcStressCCtx[SmallBuffer]]]

    for i in 0 ..< 4:
      pctxs[i] = MpmcStressPCtx[SmallBuffer](
        queue: addr queue, count: PerProducer, producerIdx: i,
        sent: addr sent, producersDone: addr producersDone
      )
      cctxs[i] = MpmcStressCCtx[SmallBuffer](
        queue: addr queue, consumerIdx: i, totalExpected: Count100k, totalProducers: 4,
        received: addr received, totalConsumed: addr totalConsumed, producersDone: addr producersDone
      )

    for i in 0 ..< 4:
      createThread(pThreads[i], mpmcStressProducer[SmallBuffer], addr pctxs[i])
      createThread(cThreads[i], mpmcStressConsumer[SmallBuffer], addr cctxs[i])

    for i in 0 ..< 4:
      joinThread(pThreads[i])
      joinThread(cThreads[i])

    check sent.load(moRelaxed) == Count100k
    check received.load(moRelaxed) == Count100k

# =============================================================================
# Spmc (SPMC) Stress Tests
# =============================================================================

type SpmcCCtx[N, C: static int, T] = object
  queue: ptr BQueue[T, ccSingle, ccMulti, N, 0, C]
  count: int
  consumerIdx: int
  received: ptr Atomic[int]

proc spmcConsumer[N, C: static int](ctx: ptr SpmcCCtx[N, C, int]) {.thread.} =
  var c = ctx.queue[].getConsumerHere(idx = ctx.consumerIdx)
  var localReceived = 0
  while localReceived < ctx.count:
    let item = c.pop()
    if item.isSome:
      inc localReceived
      discard ctx.received[].fetchAdd(1, moRelaxed)

type
  SpmcStressCCtx[N: static int] = object
    queue: ptr BQueue[int, ccSingle, ccMulti, N, 0, 4]
    consumerIdx: int
    totalExpected: int
    received: ptr Atomic[int]
    totalConsumed: ptr Atomic[int]
    producerDone: ptr Atomic[bool]

proc spmcStressConsumer[N: static int](ctx: ptr SpmcStressCCtx[N]) {.thread.} =
  var c = ctx.queue[].getConsumerHere(idx = ctx.consumerIdx)
  while true:
    let item = c.pop()
    if item.isSome:
      discard ctx.received[].fetchAdd(1, moRelaxed)
      if ctx.totalConsumed[].fetchAdd(1, moRelaxed) + 1 >= ctx.totalExpected:
        break
    elif ctx.producerDone[].load(moAcquire):
      if ctx.totalConsumed[].load(moRelaxed) >= ctx.totalExpected:
        break
      cpuPause()
    else:
      cpuPause()

suite "Stress - Spmc (SPMC)":
  test "Spmc 1P/2C 10k int":
    var queue = newSpmcQueue[int, StandardBuffer, 2]()
    var received: Atomic[int]
    received.store(0, moRelaxed)

    const PerConsumer = Count10k div 2

    var cctx0 = SpmcCCtx[StandardBuffer, 2, int](
      queue: addr queue, count: PerConsumer, consumerIdx: 0, received: addr received
    )
    var cctx1 = SpmcCCtx[StandardBuffer, 2, int](
      queue: addr queue, count: PerConsumer, consumerIdx: 1, received: addr received
    )

    var cThreads: array[2, Thread[ptr SpmcCCtx[StandardBuffer, 2, int]]]

    createThread(cThreads[0], spmcConsumer[StandardBuffer, 2], addr cctx0)
    createThread(cThreads[1], spmcConsumer[StandardBuffer, 2], addr cctx1)

    # Producer runs in main thread
    for i in 0 ..< Count10k:
      while not queue.push(i):
        cpuPause()

    joinThread(cThreads[0])
    joinThread(cThreads[1])

    check received.load(moRelaxed) == Count10k

  test "Spmc 1P/4C 100k int (StandardBuffer=1024)":
    var queue = newSpmcQueue[int, StandardBuffer, 4]()
    var received, totalConsumed: Atomic[int]
    var producerDone: Atomic[bool]
    received.store(0, moRelaxed)
    totalConsumed.store(0, moRelaxed)
    producerDone.store(false, moRelaxed)

    var cctxs: array[4, SpmcStressCCtx[StandardBuffer]]
    var cThreads: array[4, Thread[ptr SpmcStressCCtx[StandardBuffer]]]

    for i in 0 ..< 4:
      cctxs[i] = SpmcStressCCtx[StandardBuffer](
        queue: addr queue, consumerIdx: i, totalExpected: Count100k,
        received: addr received, totalConsumed: addr totalConsumed,
        producerDone: addr producerDone
      )
      createThread(cThreads[i], spmcStressConsumer[StandardBuffer], addr cctxs[i])

    # Producer runs in main thread
    for i in 0 ..< Count100k:
      while not queue.push(i):
        cpuPause()
    producerDone.store(true, moRelease)

    for i in 0 ..< 4:
      joinThread(cThreads[i])

    check received.load(moRelaxed) == Count100k

  test "Spmc 1P/4C 100k int (SmallBuffer=16 wraparound)":
    var queue = newSpmcQueue[int, SmallBuffer, 4]()
    var received, totalConsumed: Atomic[int]
    var producerDone: Atomic[bool]
    received.store(0, moRelaxed)
    totalConsumed.store(0, moRelaxed)
    producerDone.store(false, moRelaxed)

    var cctxs: array[4, SpmcStressCCtx[SmallBuffer]]
    var cThreads: array[4, Thread[ptr SpmcStressCCtx[SmallBuffer]]]

    for i in 0 ..< 4:
      cctxs[i] = SpmcStressCCtx[SmallBuffer](
        queue: addr queue, consumerIdx: i, totalExpected: Count100k,
        received: addr received, totalConsumed: addr totalConsumed,
        producerDone: addr producerDone
      )
      createThread(cThreads[i], spmcStressConsumer[SmallBuffer], addr cctxs[i])

    # Producer runs in main thread
    for i in 0 ..< Count100k:
      while not queue.push(i):
        cpuPause()
    producerDone.store(true, moRelease)

    for i in 0 ..< 4:
      joinThread(cThreads[i])

    check received.load(moRelaxed) == Count100k

# =============================================================================
# Mpsc (MPSC) Stress Tests
# =============================================================================

type MpscPCtx[N, P: static int, T] = object
  queue: ptr BQueue[T, ccMulti, ccSingle, N, P, 0]
  count: int
  producerIdx: int
  sent: ptr Atomic[int]

proc mpscProducer[N, P: static int](ctx: ptr MpscPCtx[N, P, int]) {.thread.} =
  var p = ctx.queue[].getProducerHere(idx = ctx.producerIdx)
  for i in 0 ..< ctx.count:
    while not p.push(i):
      discard
    discard ctx.sent[].fetchAdd(1, moRelaxed)

type
  MpscStressPCtx[N: static int] = object
    queue: ptr BQueue[int, ccMulti, ccSingle, N, 4, 0]
    count: int
    producerIdx: int
    sent: ptr Atomic[int]

proc mpscStressProducer[N: static int](ctx: ptr MpscStressPCtx[N]) {.thread.} =
  var p = ctx.queue[].getProducerHere(idx = ctx.producerIdx)
  for i in 0 ..< ctx.count:
    while not p.push(i):
      cpuPause()
    discard ctx.sent[].fetchAdd(1, moRelaxed)

suite "Stress - Mpsc (MPSC)":
  test "Mpsc 2P/1C 10k int":
    var queue = newMpscQueue[int, StandardBuffer, 2]()
    var sent: Atomic[int]
    sent.store(0, moRelaxed)

    const PerProducer = Count10k div 2

    var pctx0 = MpscPCtx[StandardBuffer, 2, int](
      queue: addr queue, count: PerProducer, producerIdx: 0, sent: addr sent
    )
    var pctx1 = MpscPCtx[StandardBuffer, 2, int](
      queue: addr queue, count: PerProducer, producerIdx: 1, sent: addr sent
    )

    var pThreads: array[2, Thread[ptr MpscPCtx[StandardBuffer, 2, int]]]

    createThread(pThreads[0], mpscProducer[StandardBuffer, 2], addr pctx0)
    createThread(pThreads[1], mpscProducer[StandardBuffer, 2], addr pctx1)

    # Consumer runs in main thread
    var received = 0
    while received < Count10k:
      let item = queue.pop()
      if item.isSome:
        inc received
      else:
        cpuPause()

    joinThread(pThreads[0])
    joinThread(pThreads[1])

    check sent.load(moRelaxed) == Count10k
    check received == Count10k

  test "Mpsc 2P/1C 10k with buffer=16 (stress wraparound)":
    var queue = newMpscQueue[int, SmallBuffer, 2]()
    var sent: Atomic[int]
    sent.store(0, moRelaxed)

    const PerProducer = Count10k div 2

    var pctx0 = MpscPCtx[SmallBuffer, 2, int](
      queue: addr queue, count: PerProducer, producerIdx: 0, sent: addr sent
    )
    var pctx1 = MpscPCtx[SmallBuffer, 2, int](
      queue: addr queue, count: PerProducer, producerIdx: 1, sent: addr sent
    )

    var pThreads: array[2, Thread[ptr MpscPCtx[SmallBuffer, 2, int]]]

    createThread(pThreads[0], mpscProducer[SmallBuffer, 2], addr pctx0)
    createThread(pThreads[1], mpscProducer[SmallBuffer, 2], addr pctx1)

    # Consumer runs in main thread
    var received = 0
    while received < Count10k:
      let item = queue.pop()
      if item.isSome:
        inc received
      else:
        cpuPause()

    joinThread(pThreads[0])
    joinThread(pThreads[1])

    check sent.load(moRelaxed) == Count10k
    check received == Count10k

  test "Mpsc 4P/1C 100k int (StandardBuffer=1024)":
    var queue = newMpscQueue[int, StandardBuffer, 4]()
    var sent: Atomic[int]
    sent.store(0, moRelaxed)

    const PerProducer = Count100k div 4

    var pctxs: array[4, MpscStressPCtx[StandardBuffer]]
    var pThreads: array[4, Thread[ptr MpscStressPCtx[StandardBuffer]]]

    for i in 0 ..< 4:
      pctxs[i] = MpscStressPCtx[StandardBuffer](
        queue: addr queue, count: PerProducer, producerIdx: i, sent: addr sent
      )
      createThread(pThreads[i], mpscStressProducer[StandardBuffer], addr pctxs[i])

    # Consumer runs in main thread
    var received = 0
    while received < Count100k:
      let item = queue.pop()
      if item.isSome:
        inc received
      else:
        cpuPause()

    for i in 0 ..< 4:
      joinThread(pThreads[i])

    check sent.load(moRelaxed) == Count100k
    check received == Count100k

  test "Mpsc 4P/1C 100k int (SmallBuffer=16 wraparound)":
    var queue = newMpscQueue[int, SmallBuffer, 4]()
    var sent: Atomic[int]
    sent.store(0, moRelaxed)

    const PerProducer = Count100k div 4

    var pctxs: array[4, MpscStressPCtx[SmallBuffer]]
    var pThreads: array[4, Thread[ptr MpscStressPCtx[SmallBuffer]]]

    for i in 0 ..< 4:
      pctxs[i] = MpscStressPCtx[SmallBuffer](
        queue: addr queue, count: PerProducer, producerIdx: i, sent: addr sent
      )
      createThread(pThreads[i], mpscStressProducer[SmallBuffer], addr pctxs[i])

    # Consumer runs in main thread
    var received = 0
    while received < Count100k:
      let item = queue.pop()
      if item.isSome:
        inc received
      else:
        cpuPause()

    for i in 0 ..< 4:
      joinThread(pThreads[i])

    check sent.load(moRelaxed) == Count100k
    check received == Count100k

# =============================================================================
# Unbounded Queue (Strict-LCRQ & NEBR Epoch Reclamation) Stress Tests
# =============================================================================

type
  UnbSpscStressCtx = object
    queue: ptr Queue[int, ccSingle, ccSingle, stEager, 64, 4]
    count: int
    sent: ptr Atomic[int]

proc unbSpscProducerThread(ctx: ptr UnbSpscStressCtx) {.thread.} =
  {.cast(gcsafe).}:
    var p = ctx.queue[].getProducerHere()
    for i in 0 ..< ctx.count:
      p.push(i)
      discard ctx.sent[].fetchAdd(1, moRelaxed)

type
  UnbMpscStressPCtx = object
    queue: ptr Queue[int, ccMulti, ccSingle, stEager, 64, 8]
    count: int
    sent: ptr Atomic[int]

proc unbMpscProducerThread(ctx: ptr UnbMpscStressPCtx) {.thread.} =
  {.cast(gcsafe).}:
    var p = ctx.queue[].getProducerHere()
    for i in 0 ..< ctx.count:
      p.push(i)
      discard ctx.sent[].fetchAdd(1, moRelaxed)

type
  UnbSpmcStressCCtx = object
    queue: ptr Queue[int, ccSingle, ccMulti, stEager, 64, 8]
    totalExpected: int
    received: ptr Atomic[int]
    totalConsumed: ptr Atomic[int]
    producerDone: ptr Atomic[bool]

proc unbSpmcConsumerThread(ctx: ptr UnbSpmcStressCCtx) {.thread.} =
  {.cast(gcsafe).}:
    var c = ctx.queue[].getConsumerHere()
    while true:
      let item = c.pop()
      if item.isSome:
        discard ctx.received[].fetchAdd(1, moRelaxed)
        if ctx.totalConsumed[].fetchAdd(1, moRelaxed) + 1 >= ctx.totalExpected:
          break
      elif ctx.producerDone[].load(moAcquire):
        if ctx.totalConsumed[].load(moRelaxed) >= ctx.totalExpected:
          break
      else:
        cpuPause()

type
  UnbMpmcStressPCtx = object
    queue: ptr Queue[int, ccMulti, ccMulti, stEager, 64, 16]
    count: int
    sent: ptr Atomic[int]
    producersDone: ptr Atomic[int]

  UnbMpmcStressCCtx = object
    queue: ptr Queue[int, ccMulti, ccMulti, stEager, 64, 16]
    totalExpected: int
    totalProducers: int
    received: ptr Atomic[int]
    totalConsumed: ptr Atomic[int]
    producersDone: ptr Atomic[int]

proc unbMpmcProducerThread(ctx: ptr UnbMpmcStressPCtx) {.thread.} =
  {.cast(gcsafe).}:
    var p = ctx.queue[].getProducerHere()
    for i in 0 ..< ctx.count:
      p.push(i)
      discard ctx.sent[].fetchAdd(1, moRelaxed)
    discard ctx.producersDone[].fetchAdd(1, moRelease)

proc unbMpmcConsumerThread(ctx: ptr UnbMpmcStressCCtx) {.thread.} =
  {.cast(gcsafe).}:
    var c = ctx.queue[].getConsumerHere()
    while true:
      let item = c.pop()
      if item.isSome:
        discard ctx.received[].fetchAdd(1, moRelaxed)
        if ctx.totalConsumed[].fetchAdd(1, moRelaxed) + 1 >= ctx.totalExpected:
          break
      elif ctx.producersDone[].load(moAcquire) >= ctx.totalProducers:
        if ctx.totalConsumed[].load(moRelaxed) >= ctx.totalExpected:
          break
      else:
        cpuPause()

suite "Stress - Unbounded Queue (Strict-LCRQ & NEBR)":
  test "Unbounded Spsc 1P/1C 100k int":
    var queue = newUnboundedSpscQueue[int, stEager, 64, 4]()
    var sent: Atomic[int]
    sent.store(0, moRelaxed)

    var ctx = UnbSpscStressCtx(
      queue: addr queue, count: Count100k, sent: addr sent
    )
    var pThread: Thread[ptr UnbSpscStressCtx]
    createThread(pThread, unbSpscProducerThread, addr ctx)

    var c = queue.getConsumerHere()
    var received = 0
    while received < Count100k:
      let item = c.pop()
      if item.isSome:
        inc received
      else:
        cpuPause()

    joinThread(pThread)
    check sent.load(moRelaxed) == Count100k
    check received == Count100k

  test "Unbounded Mpsc 4P/1C 100k int":
    var queue = newUnboundedMpscQueue[int, stEager, 64, 8]()
    var sent: Atomic[int]
    sent.store(0, moRelaxed)

    const PerProducer = Count100k div 4
    var pctxs: array[4, UnbMpscStressPCtx]
    var pThreads: array[4, Thread[ptr UnbMpscStressPCtx]]

    for i in 0 ..< 4:
      pctxs[i] = UnbMpscStressPCtx(
        queue: addr queue, count: PerProducer, sent: addr sent
      )
      createThread(pThreads[i], unbMpscProducerThread, addr pctxs[i])

    var c = queue.bindConsumer()
    var received = 0
    while received < Count100k:
      let item = c.pop()
      if item.isSome:
        inc received
      else:
        cpuPause()

    for i in 0 ..< 4:
      joinThread(pThreads[i])

    check sent.load(moRelaxed) == Count100k
    check received == Count100k

  test "Unbounded Spmc 1P/4C 100k int":
    var queue = newUnboundedSpmcQueue[int, stEager, 64, 8]()
    var received, totalConsumed: Atomic[int]
    var producerDone: Atomic[bool]
    received.store(0, moRelaxed)
    totalConsumed.store(0, moRelaxed)
    producerDone.store(false, moRelaxed)

    var cctx = UnbSpmcStressCCtx(
      queue: addr queue, totalExpected: Count100k,
      received: addr received, totalConsumed: addr totalConsumed,
      producerDone: addr producerDone
    )
    var cThreads: array[4, Thread[ptr UnbSpmcStressCCtx]]

    for i in 0 ..< 4:
      createThread(cThreads[i], unbSpmcConsumerThread, addr cctx)

    var p = queue.getProducerHere()
    for i in 0 ..< Count100k:
      p.push(i)
    producerDone.store(true, moRelease)

    for i in 0 ..< 4:
      joinThread(cThreads[i])

    check received.load(moRelaxed) == Count100k

  test "Unbounded Mpmc 4P/4C 100k int (Strict-LCRQ & NEBR epoch reclamation)":
    var queue = newUnboundedMpmcQueue[int, stEager, 64, 16]()
    var sent, received, totalConsumed, producersDone: Atomic[int]
    sent.store(0, moRelaxed)
    received.store(0, moRelaxed)
    totalConsumed.store(0, moRelaxed)
    producersDone.store(0, moRelaxed)

    const PerProducer = Count100k div 4
    var pctxs: array[4, UnbMpmcStressPCtx]
    var cctxs: array[4, UnbMpmcStressCCtx]
    var pThreads: array[4, Thread[ptr UnbMpmcStressPCtx]]
    var cThreads: array[4, Thread[ptr UnbMpmcStressCCtx]]

    for i in 0 ..< 4:
      pctxs[i] = UnbMpmcStressPCtx(
        queue: addr queue, count: PerProducer,
        sent: addr sent, producersDone: addr producersDone
      )
      cctxs[i] = UnbMpmcStressCCtx(
        queue: addr queue, totalExpected: Count100k, totalProducers: 4,
        received: addr received, totalConsumed: addr totalConsumed,
        producersDone: addr producersDone
      )

    for i in 0 ..< 4:
      createThread(pThreads[i], unbMpmcProducerThread, addr pctxs[i])
      createThread(cThreads[i], unbMpmcConsumerThread, addr cctxs[i])

    for i in 0 ..< 4:
      joinThread(pThreads[i])
      joinThread(cThreads[i])

    check sent.load(moRelaxed) == Count100k
    check received.load(moRelaxed) == Count100k

# =============================================================================
# TreiberStack Stress Tests (Elimination-Backoff Array)
# =============================================================================

type
  StackStressProdCtx = object
    stack: ptr TreiberStack[int]
    threadIdx: int
    itemsPerThread: int
    producersDone: ptr Atomic[int]

  StackStressConsCtx = object
    stack: ptr TreiberStack[int]
    received: ptr UncheckedArray[Atomic[bool]]
    duplicateFound: ptr Atomic[bool]
    totalConsumed: ptr Atomic[int]
    totalExpected: int
    producersDone: ptr Atomic[int]
    totalProducers: int

  StackStressManagedProdCtx = object
    stack: ptr TreiberStack[TestObjectRef]
    threadIdx: int
    itemsPerThread: int
    producersDone: ptr Atomic[int]

  StackStressManagedConsCtx = object
    stack: ptr TreiberStack[TestObjectRef]
    totalConsumed: ptr Atomic[int]
    totalExpected: int
    checksumErrors: ptr Atomic[int]
    producersDone: ptr Atomic[int]
    totalProducers: int

proc stackStressProdWorker(ctx: ptr StackStressProdCtx) {.thread.} =
  {.cast(gcsafe).}:
    let base = ctx.threadIdx * ctx.itemsPerThread
    for i in 0 ..< ctx.itemsPerThread:
      ctx.stack[].push(base + i)
    if ctx.producersDone != nil:
      discard ctx.producersDone[].fetchAdd(1, moRelease)

proc stackStressConsWorker(ctx: ptr StackStressConsCtx) {.thread.} =
  {.cast(gcsafe).}:
    while true:
      let item = ctx.stack[].pop()
      if item.isSome:
        let val = item.get
        if val >= 0 and val < ctx.totalExpected:
          if ctx.received[val].exchange(true, moRelaxed):
            ctx.duplicateFound[].store(true, moRelaxed)
        if ctx.totalConsumed[].fetchAdd(1, moRelaxed) + 1 >= ctx.totalExpected:
          break
      elif ctx.producersDone[].load(moAcquire) >= ctx.totalProducers:
        if ctx.totalConsumed[].load(moRelaxed) >= ctx.totalExpected:
          break
        cpuPause()
      else:
        cpuPause()

proc stackStressManagedProdWorker(ctx: ptr StackStressManagedProdCtx) {.thread.} =
  {.cast(gcsafe).}:
    let base = ctx.threadIdx * ctx.itemsPerThread
    for i in 0 ..< ctx.itemsPerThread:
      let id = base + i
      let payload = "stack_payload_" & $id
      let obj = TestObjectRef(id: id, payload: payload, checksum: computeChecksum(id, payload))
      ctx.stack[].push(obj)
    if ctx.producersDone != nil:
      discard ctx.producersDone[].fetchAdd(1, moRelease)

proc stackStressManagedConsWorker(ctx: ptr StackStressManagedConsCtx) {.thread.} =
  {.cast(gcsafe).}:
    while true:
      let item = ctx.stack[].pop()
      if item.isSome:
        let obj = item.get
        if obj.checksum != computeChecksum(obj.id, obj.payload):
          discard ctx.checksumErrors[].fetchAdd(1, moRelaxed)
        if ctx.totalConsumed[].fetchAdd(1, moRelaxed) + 1 >= ctx.totalExpected:
          break
      elif ctx.producersDone[].load(moAcquire) >= ctx.totalProducers:
        if ctx.totalConsumed[].load(moRelaxed) >= ctx.totalExpected:
          break
        cpuPause()
      else:
        cpuPause()

suite "Stress - TreiberStack (Elimination-Backoff Array)":
  test "TreiberStack 4P/1C High Volume (40k int)":
    var s = initTreiberStack[int]()
    let received = cast[ptr UncheckedArray[Atomic[bool]]](allocShared0(sizeof(Atomic[bool]) * Count40k))
    var duplicateFound: Atomic[bool]
    var producersDone, totalItemsConsumed: Atomic[int]
    duplicateFound.store(false, moRelaxed)
    producersDone.store(0, moRelaxed)
    totalItemsConsumed.store(0, moRelaxed)

    const PerProducer = Count40k div 4
    var pctxs: array[4, StackStressProdCtx]
    var pThreads: array[4, Thread[ptr StackStressProdCtx]]

    for i in 0 ..< 4:
      pctxs[i] = StackStressProdCtx(
        stack: addr s, threadIdx: i, itemsPerThread: PerProducer,
        producersDone: addr producersDone
      )
      createThread(pThreads[i], stackStressProdWorker, addr pctxs[i])

    var cctx = StackStressConsCtx(
      stack: addr s, received: received, duplicateFound: addr duplicateFound,
      totalConsumed: addr totalItemsConsumed, totalExpected: Count40k,
      producersDone: addr producersDone, totalProducers: 4
    )
    var cThread: Thread[ptr StackStressConsCtx]
    createThread(cThread, stackStressConsWorker, addr cctx)

    for i in 0 ..< 4:
      joinThread(pThreads[i])
    joinThread(cThread)

    check not duplicateFound.load(moRelaxed)
    check totalItemsConsumed.load(moRelaxed) == Count40k
    check s.isEmpty
    deallocShared(received)

  test "TreiberStack 1P/4C High Volume (40k int)":
    var s = initTreiberStack[int]()
    let received = cast[ptr UncheckedArray[Atomic[bool]]](allocShared0(sizeof(Atomic[bool]) * Count40k))
    var duplicateFound: Atomic[bool]
    var producerDone: Atomic[int]
    var totalItemsConsumed: Atomic[int]
    duplicateFound.store(false, moRelaxed)
    producerDone.store(0, moRelaxed)
    totalItemsConsumed.store(0, moRelaxed)

    var cctxs: array[4, StackStressConsCtx]
    var cThreads: array[4, Thread[ptr StackStressConsCtx]]

    for i in 0 ..< 4:
      cctxs[i] = StackStressConsCtx(
        stack: addr s, received: received, duplicateFound: addr duplicateFound,
        totalConsumed: addr totalItemsConsumed, totalExpected: Count40k,
        producersDone: addr producerDone, totalProducers: 1
      )
      createThread(cThreads[i], stackStressConsWorker, addr cctxs[i])

    for i in 0 ..< Count40k:
      s.push(i)
    discard producerDone.fetchAdd(1, moRelease)

    for i in 0 ..< 4:
      joinThread(cThreads[i])

    check not duplicateFound.load(moRelaxed)
    check totalItemsConsumed.load(moRelaxed) == Count40k
    check s.isEmpty
    deallocShared(received)

  test "TreiberStack 4P/4C Extreme MPMC Contention (40k int)":
    var s = initTreiberStack[int]()
    let received = cast[ptr UncheckedArray[Atomic[bool]]](allocShared0(sizeof(Atomic[bool]) * Count40k))
    var duplicateFound: Atomic[bool]
    var producersDone: Atomic[int]
    var totalItemsConsumed: Atomic[int]
    duplicateFound.store(false, moRelaxed)
    producersDone.store(0, moRelaxed)
    totalItemsConsumed.store(0, moRelaxed)

    const PerProducer = Count40k div 4
    var pctxs: array[4, StackStressProdCtx]
    var cctxs: array[4, StackStressConsCtx]
    var pThreads: array[4, Thread[ptr StackStressProdCtx]]
    var cThreads: array[4, Thread[ptr StackStressConsCtx]]

    for i in 0 ..< 4:
      pctxs[i] = StackStressProdCtx(
        stack: addr s, threadIdx: i, itemsPerThread: PerProducer,
        producersDone: addr producersDone
      )
      cctxs[i] = StackStressConsCtx(
        stack: addr s, received: received, duplicateFound: addr duplicateFound,
        totalConsumed: addr totalItemsConsumed, totalExpected: Count40k,
        producersDone: addr producersDone, totalProducers: 4
      )
      createThread(cThreads[i], stackStressConsWorker, addr cctxs[i])
      createThread(pThreads[i], stackStressProdWorker, addr pctxs[i])

    for i in 0 ..< 4:
      joinThread(pThreads[i])
      joinThread(cThreads[i])

    check not duplicateFound.load(moRelaxed)
    check totalItemsConsumed.load(moRelaxed) == Count40k
    check s.isEmpty
    deallocShared(received)

  test "TreiberStack 4P/4C Managed Ref Objects (10k ref TestObject)":
    var s = initTreiberStack[TestObjectRef]()
    var producersDone: Atomic[int]
    var totalItemsConsumed: Atomic[int]
    var checksumErrors: Atomic[int]
    producersDone.store(0, moRelaxed)
    totalItemsConsumed.store(0, moRelaxed)
    checksumErrors.store(0, moRelaxed)

    const PerProducer = Count10k div 4
    var pctxs: array[4, StackStressManagedProdCtx]
    var cctxs: array[4, StackStressManagedConsCtx]
    var pThreads: array[4, Thread[ptr StackStressManagedProdCtx]]
    var cThreads: array[4, Thread[ptr StackStressManagedConsCtx]]

    for i in 0 ..< 4:
      pctxs[i] = StackStressManagedProdCtx(
        stack: addr s, threadIdx: i, itemsPerThread: PerProducer,
        producersDone: addr producersDone
      )
      cctxs[i] = StackStressManagedConsCtx(
        stack: addr s, totalConsumed: addr totalItemsConsumed,
        totalExpected: Count10k, checksumErrors: addr checksumErrors,
        producersDone: addr producersDone, totalProducers: 4
      )
      createThread(cThreads[i], stackStressManagedConsWorker, addr cctxs[i])
      createThread(pThreads[i], stackStressManagedProdWorker, addr pctxs[i])

    for i in 0 ..< 4:
      joinThread(pThreads[i])
      joinThread(cThreads[i])

    check checksumErrors.load(moRelaxed) == 0
    check totalItemsConsumed.load(moRelaxed) == Count10k
    check s.isEmpty

# =============================================================================
# ChaseLevDeque Stress Tests (Single-Worker / Multi-Thief Work Stealing)
# =============================================================================

type
  DequeStressCtx = object
    deque: ChaseLevDeque[int]
    totalItems: int
    poppedOrStolen: ptr UncheckedArray[Atomic[int]]
    workerDone: ptr Atomic[bool]
    totalProcessed: ptr Atomic[int]

  DequeBatchStressCtx = object
    deque: ChaseLevDeque[int]
    totalItems: int
    poppedOrStolen: ptr UncheckedArray[Atomic[int]]
    workerDone: ptr Atomic[bool]
    totalProcessed: ptr Atomic[int]

  DequeManagedStressCtx = object
    deque: ChaseLevDeque[TestObjectRef]
    totalItems: int
    workerDone: ptr Atomic[bool]
    totalProcessed: ptr Atomic[int]
    checksumErrors: ptr Atomic[int]

proc dequeThiefWorker(ctx: ptr DequeStressCtx) {.thread.} =
  {.cast(gcsafe).}:
    while true:
      let item = ctx.deque.steal()
      if item.isSome:
        let val = item.get
        if val >= 0 and val < ctx.totalItems:
          discard ctx.poppedOrStolen[val].fetchAdd(1, moRelaxed)
        discard ctx.totalProcessed[].fetchAdd(1, moRelaxed)
      elif ctx.workerDone[].load(moAcquire):
        if ctx.deque.isEmpty or ctx.totalProcessed[].load(moRelaxed) >= ctx.totalItems:
          break
        cpuPause()
      else:
        cpuPause()

proc dequeBatchThiefWorker(ctx: ptr DequeBatchStressCtx) {.thread.} =
  {.cast(gcsafe).}:
    var buf: array[16, int]
    while true:
      let count = ctx.deque.stealBatch(buf, maxItems = 8)
      if count > 0:
        for i in 0 ..< count:
          let val = buf[i]
          if val >= 0 and val < ctx.totalItems:
            discard ctx.poppedOrStolen[val].fetchAdd(1, moRelaxed)
        discard ctx.totalProcessed[].fetchAdd(count, moRelaxed)
      elif ctx.workerDone[].load(moAcquire):
        if ctx.deque.isEmpty or ctx.totalProcessed[].load(moRelaxed) >= ctx.totalItems:
          break
        cpuPause()
      else:
        cpuPause()

proc dequeManagedThiefWorker(ctx: ptr DequeManagedStressCtx) {.thread.} =
  {.cast(gcsafe).}:
    while true:
      let item = ctx.deque.steal()
      if item.isSome:
        let obj = item.get
        if obj.checksum != computeChecksum(obj.id, obj.payload):
          discard ctx.checksumErrors[].fetchAdd(1, moRelaxed)
        discard ctx.totalProcessed[].fetchAdd(1, moRelaxed)
      elif ctx.workerDone[].load(moAcquire):
        if ctx.deque.isEmpty or ctx.totalProcessed[].load(moRelaxed) >= ctx.totalItems:
          break
        cpuPause()
      else:
        cpuPause()

suite "Stress - ChaseLevDeque (Single-Worker / Multi-Thief Work Stealing)":
  test "ChaseLevDeque 1 Worker, 4 Concurrent Thieves (20k int)":
    let deque = initChaseLevDeque[int](128)
    let poppedOrStolen = cast[ptr UncheckedArray[Atomic[int]]](allocShared0(sizeof(Atomic[int]) * Count20k))
    var workerDone: Atomic[bool]
    var totalProcessed: Atomic[int]
    workerDone.store(false, moRelaxed)
    totalProcessed.store(0, moRelaxed)

    var ctx = DequeStressCtx(
      deque: deque, totalItems: Count20k,
      poppedOrStolen: poppedOrStolen, workerDone: addr workerDone,
      totalProcessed: addr totalProcessed
    )
    var thiefThreads: array[4, Thread[ptr DequeStressCtx]]
    for i in 0 ..< 4:
      createThread(thiefThreads[i], dequeThiefWorker, addr ctx)

    for i in 0 ..< Count20k:
      deque.pushBottom(i)
      if i mod 8 == 0:
        let popped = deque.popBottom()
        if popped.isSome:
          let val = popped.get
          discard poppedOrStolen[val].fetchAdd(1, moRelaxed)
          discard totalProcessed.fetchAdd(1, moRelaxed)

    # Drain remaining items before signaling workerDone
    while true:
      let p = deque.popBottom()
      if p.isSome:
        let val = p.get
        discard poppedOrStolen[val].fetchAdd(1, moRelaxed)
        discard totalProcessed.fetchAdd(1, moRelaxed)
      else:
        break

    workerDone.store(true, moRelease)
    for i in 0 ..< 4:
      joinThread(thiefThreads[i])

    for i in 0 ..< Count20k:
      check poppedOrStolen[i].load(moRelaxed) == 1
    check totalProcessed.load(moRelaxed) == Count20k
    check deque.isEmpty
    deallocShared(poppedOrStolen)

  test "ChaseLevDeque 1 Worker, 4 Concurrent Batch Thieves (20k int)":
    let deque = initChaseLevDeque[int](128)
    let poppedOrStolen = cast[ptr UncheckedArray[Atomic[int]]](allocShared0(sizeof(Atomic[int]) * Count20k))
    var workerDone: Atomic[bool]
    var totalProcessed: Atomic[int]
    workerDone.store(false, moRelaxed)
    totalProcessed.store(0, moRelaxed)

    var ctx = DequeBatchStressCtx(
      deque: deque, totalItems: Count20k,
      poppedOrStolen: poppedOrStolen, workerDone: addr workerDone,
      totalProcessed: addr totalProcessed
    )
    var thiefThreads: array[4, Thread[ptr DequeBatchStressCtx]]
    for i in 0 ..< 4:
      createThread(thiefThreads[i], dequeBatchThiefWorker, addr ctx)

    for i in 0 ..< Count20k:
      deque.pushBottom(i)
      if i mod 10 == 0:
        let popped = deque.popBottom()
        if popped.isSome:
          let val = popped.get
          discard poppedOrStolen[val].fetchAdd(1, moRelaxed)
          discard totalProcessed.fetchAdd(1, moRelaxed)

    # Drain remaining items before signaling workerDone
    while true:
      let p = deque.popBottom()
      if p.isSome:
        let val = p.get
        discard poppedOrStolen[val].fetchAdd(1, moRelaxed)
        discard totalProcessed.fetchAdd(1, moRelaxed)
      else:
        break

    workerDone.store(true, moRelease)
    for i in 0 ..< 4:
      joinThread(thiefThreads[i])

    for i in 0 ..< Count20k:
      check poppedOrStolen[i].load(moRelaxed) == 1
    check totalProcessed.load(moRelaxed) == Count20k
    check deque.isEmpty
    deallocShared(poppedOrStolen)

  test "ChaseLevDeque Dynamic Buffer Growth under Contention (initial cap = 16, 10k int)":
    let deque = initChaseLevDeque[int](16)
    let poppedOrStolen = cast[ptr UncheckedArray[Atomic[int]]](allocShared0(sizeof(Atomic[int]) * Count10k))
    var workerDone: Atomic[bool]
    var totalProcessed: Atomic[int]
    workerDone.store(false, moRelaxed)
    totalProcessed.store(0, moRelaxed)

    var ctx = DequeStressCtx(
      deque: deque, totalItems: Count10k,
      poppedOrStolen: poppedOrStolen, workerDone: addr workerDone,
      totalProcessed: addr totalProcessed
    )
    var thiefThreads: array[4, Thread[ptr DequeStressCtx]]
    for i in 0 ..< 4:
      createThread(thiefThreads[i], dequeThiefWorker, addr ctx)

    for i in 0 ..< Count10k:
      deque.pushBottom(i)

    # Drain remaining items before signaling workerDone
    while true:
      let p = deque.popBottom()
      if p.isSome:
        let val = p.get
        discard poppedOrStolen[val].fetchAdd(1, moRelaxed)
        discard totalProcessed.fetchAdd(1, moRelaxed)
      else:
        break

    workerDone.store(true, moRelease)
    for i in 0 ..< 4:
      joinThread(thiefThreads[i])

    for i in 0 ..< Count10k:
      check poppedOrStolen[i].load(moRelaxed) == 1
    check totalProcessed.load(moRelaxed) == Count10k
    deallocShared(poppedOrStolen)

  test "ChaseLevDeque Managed Types (strings and ref objects) under Contention":
    let deque = initChaseLevDeque[TestObjectRef](32)
    var workerDone: Atomic[bool]
    var totalProcessed: Atomic[int]
    var checksumErrors: Atomic[int]
    workerDone.store(false, moRelaxed)
    totalProcessed.store(0, moRelaxed)
    checksumErrors.store(0, moRelaxed)

    const ManagedCount = 5_000
    var ctx = DequeManagedStressCtx(
      deque: deque, totalItems: ManagedCount,
      workerDone: addr workerDone, totalProcessed: addr totalProcessed,
      checksumErrors: addr checksumErrors
    )
    var thiefThreads: array[4, Thread[ptr DequeManagedStressCtx]]
    for i in 0 ..< 4:
      createThread(thiefThreads[i], dequeManagedThiefWorker, addr ctx)

    for i in 0 ..< ManagedCount:
      let payload = "deque_payload_" & $i
      let obj = TestObjectRef(id: i, payload: payload, checksum: computeChecksum(i, payload))
      deque.pushBottom(obj)

    # Drain remaining items before signaling workerDone
    while true:
      let p = deque.popBottom()
      if p.isSome:
        let obj = p.get
        if obj.checksum != computeChecksum(obj.id, obj.payload):
          discard checksumErrors.fetchAdd(1, moRelaxed)
        discard totalProcessed.fetchAdd(1, moRelaxed)
      else:
        break

    workerDone.store(true, moRelease)
    for i in 0 ..< 4:
      joinThread(thiefThreads[i])

    check checksumErrors.load(moRelaxed) == 0
    check totalProcessed.load(moRelaxed) == ManagedCount
    check deque.isEmpty

# =============================================================================
# SkipListMap Stress Tests (Fraser/Herlihy Debra SMR)
# =============================================================================

type
  SkipListMapStressCtx = object
    map: ptr SkipListMap[int, int]
    threadIdx: int
    itemsPerThread: int

  SkipListMapOverlappingCtx = object
    map: ptr SkipListMap[int, int]
    threadIdx: int
    opsPerThread: int
    keyRange: int

  SkipListMapMixedCtx = object
    map: ptr SkipListMap[int, int]
    threadIdx: int
    itemsPerThread: int

  SkipListMapManagedCtx = object
    map: ptr SkipListMap[int, TestObjectRef]
    threadIdx: int
    itemsPerThread: int
    checksumErrors: ptr Atomic[int]

proc skipListMapDisjointWorker(ctx: ptr SkipListMapStressCtx) {.thread.} =
  {.cast(gcsafe).}:
    let base = ctx.threadIdx * ctx.itemsPerThread
    for i in 0 ..< ctx.itemsPerThread:
      let k = base + i
      discard ctx.map[].put(k, k * 2)

proc skipListMapOverlappingWorker(ctx: ptr SkipListMapOverlappingCtx) {.thread.} =
  {.cast(gcsafe).}:
    for i in 0 ..< ctx.opsPerThread:
      let k = i mod ctx.keyRange
      discard ctx.map[].put(k, k * 10 + ctx.threadIdx)

proc skipListMapMixedWorker(ctx: ptr SkipListMapMixedCtx) {.thread.} =
  {.cast(gcsafe).}:
    let base = ctx.threadIdx * ctx.itemsPerThread
    for i in 0 ..< ctx.itemsPerThread:
      let k = base + i
      discard ctx.map[].put(k, k * 3)
    for i in 0 ..< ctx.itemsPerThread:
      let k = base + i
      discard ctx.map[].get(k)
    for i in 0 ..< ctx.itemsPerThread div 2:
      let k = base + i
      discard ctx.map[].delete(k)

proc skipListMapManagedWorker(ctx: ptr SkipListMapManagedCtx) {.thread.} =
  {.cast(gcsafe).}:
    let base = ctx.threadIdx * ctx.itemsPerThread
    for i in 0 ..< ctx.itemsPerThread:
      let id = base + i
      let payload = "map_payload_" & $id
      let obj = TestObjectRef(id: id, payload: payload, checksum: computeChecksum(id, payload))
      discard ctx.map[].put(id, obj)
    for i in 0 ..< ctx.itemsPerThread:
      let id = base + i
      let opt = ctx.map[].get(id)
      if opt.isSome:
        let obj = opt.get
        if obj.checksum != computeChecksum(obj.id, obj.payload):
          discard ctx.checksumErrors[].fetchAdd(1, moRelaxed)
    for i in 0 ..< ctx.itemsPerThread div 2:
      let id = base + i
      discard ctx.map[].delete(id)

suite "Stress - SkipListMap (Fraser/Herlihy Debra SMR)":
  test "SkipListMap Concurrent Disjoint Insertions (10k items across 4 threads)":
    var map = newSkipListMap[int, int]()
    const Threads = 4
    const PerThread = Count10k div Threads
    var ctxs: array[Threads, SkipListMapStressCtx]
    var threads: array[Threads, Thread[ptr SkipListMapStressCtx]]

    for i in 0 ..< Threads:
      ctxs[i] = SkipListMapStressCtx(map: addr map, threadIdx: i, itemsPerThread: PerThread)
      createThread(threads[i], skipListMapDisjointWorker, addr ctxs[i])

    for i in 0 ..< Threads:
      joinThread(threads[i])

    check map.len == Count10k
    for i in 0 ..< Count10k:
      let opt = map.get(i)
      check opt.isSome
      if opt.isSome:
        check opt.get == i * 2

    var count = 0
    var prev = -1
    for k in map.keys():
      check k > prev
      prev = k
      inc count
    check count == Count10k

  test "SkipListMap High-Contention Overlapping Put (10k operations across 4 threads)":
    var map = newSkipListMap[int, int]()
    const Threads = 4
    const OpsPerThread = 2500
    const KeyRange = 500
    var ctxs: array[Threads, SkipListMapOverlappingCtx]
    var threads: array[Threads, Thread[ptr SkipListMapOverlappingCtx]]

    for i in 0 ..< Threads:
      ctxs[i] = SkipListMapOverlappingCtx(map: addr map, threadIdx: i, opsPerThread: OpsPerThread, keyRange: KeyRange)
      createThread(threads[i], skipListMapOverlappingWorker, addr ctxs[i])

    for i in 0 ..< Threads:
      joinThread(threads[i])

    check map.len == KeyRange
    for k in 0 ..< KeyRange:
      check map.contains(k)

  test "SkipListMap Concurrent Mixed Workers (Put / Get / Delete under Debra SMR)":
    var map = newSkipListMap[int, int]()
    const Threads = 4
    const PerThread = 1500
    var ctxs: array[Threads, SkipListMapMixedCtx]
    var threads: array[Threads, Thread[ptr SkipListMapMixedCtx]]

    for i in 0 ..< Threads:
      ctxs[i] = SkipListMapMixedCtx(map: addr map, threadIdx: i, itemsPerThread: PerThread)
      createThread(threads[i], skipListMapMixedWorker, addr ctxs[i])

    for i in 0 ..< Threads:
      joinThread(threads[i])

    let expectedRemaining = Threads * (PerThread - PerThread div 2)
    check map.len == expectedRemaining

    for t in 0 ..< Threads:
      let base = t * PerThread
      for i in 0 ..< PerThread div 2:
        check not map.contains(base + i)
      for i in (PerThread div 2) ..< PerThread:
        check map.contains(base + i)

  test "SkipListMap Managed Types (strings and ref objects)":
    var map = newSkipListMap[int, TestObjectRef]()
    var checksumErrors: Atomic[int]
    checksumErrors.store(0, moRelaxed)

    const Threads = 4
    const PerThread = 1000
    var ctxs: array[Threads, SkipListMapManagedCtx]
    var threads: array[Threads, Thread[ptr SkipListMapManagedCtx]]

    for i in 0 ..< Threads:
      ctxs[i] = SkipListMapManagedCtx(
        map: addr map, threadIdx: i, itemsPerThread: PerThread,
        checksumErrors: addr checksumErrors
      )
      createThread(threads[i], skipListMapManagedWorker, addr ctxs[i])

    for i in 0 ..< Threads:
      joinThread(threads[i])

    check checksumErrors.load(moRelaxed) == 0
    let expectedRemaining = Threads * (PerThread - PerThread div 2)
    check map.len == expectedRemaining

# =============================================================================
# SkipListSet Stress Tests (Fraser/Herlihy Debra SMR)
# =============================================================================

type
  SkipListSetStressCtx = object
    set: ptr SkipListSet[int]
    threadIdx: int
    itemsPerThread: int

  SkipListSetOverlappingCtx = object
    set: ptr SkipListSet[int]
    threadIdx: int
    itemsPerThread: int
    keyRange: int

  SkipListSetMixedCtx = object
    set: ptr SkipListSet[int]
    threadIdx: int
    itemsPerThread: int

proc skipListSetDisjointWorker(ctx: ptr SkipListSetStressCtx) {.thread.} =
  {.cast(gcsafe).}:
    let base = ctx.threadIdx * ctx.itemsPerThread
    for i in 0 ..< ctx.itemsPerThread:
      discard ctx.set[].insert(base + i)

proc skipListSetOverlappingWorker(ctx: ptr SkipListSetOverlappingCtx) {.thread.} =
  {.cast(gcsafe).}:
    for i in 0 ..< ctx.itemsPerThread:
      let val = i mod ctx.keyRange
      discard ctx.set[].insert(val)

proc skipListSetMixedWorker(ctx: ptr SkipListSetMixedCtx) {.thread.} =
  {.cast(gcsafe).}:
    let base = ctx.threadIdx * ctx.itemsPerThread
    for i in 0 ..< ctx.itemsPerThread:
      discard ctx.set[].insert(base + i)
    for i in 0 ..< ctx.itemsPerThread:
      discard ctx.set[].contains(base + i)
    for i in 0 ..< ctx.itemsPerThread div 2:
      discard ctx.set[].remove(base + i)

suite "Stress - SkipListSet (Fraser/Herlihy Debra SMR)":
  test "SkipListSet Concurrent Disjoint Insertions (10k items across 4 threads)":
    var s = newSkipListSet[int]()
    const Threads = 4
    const PerThread = Count10k div Threads
    var ctxs: array[Threads, SkipListSetStressCtx]
    var threads: array[Threads, Thread[ptr SkipListSetStressCtx]]

    for i in 0 ..< Threads:
      ctxs[i] = SkipListSetStressCtx(set: addr s, threadIdx: i, itemsPerThread: PerThread)
      createThread(threads[i], skipListSetDisjointWorker, addr ctxs[i])

    for i in 0 ..< Threads:
      joinThread(threads[i])

    check s.len == Count10k
    for i in 0 ..< Count10k:
      check s.contains(i)

    var count = 0
    var prev = -1
    for x in s:
      check x > prev
      prev = x
      inc count
    check count == Count10k

  test "SkipListSet Concurrent Overlapping Insertions (Duplicate Rejection)":
    var s = newSkipListSet[int]()
    const Threads = 4
    const OpsPerThread = 2500
    const KeyRange = 500
    var ctxs: array[Threads, SkipListSetOverlappingCtx]
    var threads: array[Threads, Thread[ptr SkipListSetOverlappingCtx]]

    for i in 0 ..< Threads:
      ctxs[i] = SkipListSetOverlappingCtx(set: addr s, threadIdx: i, itemsPerThread: OpsPerThread, keyRange: KeyRange)
      createThread(threads[i], skipListSetOverlappingWorker, addr ctxs[i])

    for i in 0 ..< Threads:
      joinThread(threads[i])

    check s.len == KeyRange
    for i in 0 ..< KeyRange:
      check s.contains(i)

  test "SkipListSet Concurrent Mixed Insert / Remove / Contains":
    var s = newSkipListSet[int]()
    const Threads = 4
    const PerThread = 1500
    var ctxs: array[Threads, SkipListSetMixedCtx]
    var threads: array[Threads, Thread[ptr SkipListSetMixedCtx]]

    for i in 0 ..< Threads:
      ctxs[i] = SkipListSetMixedCtx(set: addr s, threadIdx: i, itemsPerThread: PerThread)
      createThread(threads[i], skipListSetMixedWorker, addr ctxs[i])

    for i in 0 ..< Threads:
      joinThread(threads[i])

    let expectedRemaining = Threads * (PerThread - PerThread div 2)
    check s.len == expectedRemaining

    for t in 0 ..< Threads:
      let base = t * PerThread
      for i in 0 ..< PerThread div 2:
        check not s.contains(base + i)
      for i in (PerThread div 2) ..< PerThread:
        check s.contains(base + i)

