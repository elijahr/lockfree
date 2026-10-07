## High-volume stress tests for all bounded queue types.
## Tests 100k+ messages to catch ring buffer collision bugs.

when not compileOption("threads"):
  {.error: "t_stress requires --threads:on option.".}

import std/options
import unittest2
import lockfree
import lockfree/endpoint
import lockfree/role_tags
import lockfree/atomics
import lockfree/atomics/dsl
import lockfree/atomics/backoff

const
  SmallBuffer = 16
  StandardBuffer = 1024
  LargeBuffer = 4096

  Count10k = 10_000
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

