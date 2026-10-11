## Multi-threaded integration tests for BroadcastRing[T] and TopicBus[T].

import unittest2
import std/[options, os]
import lockfree/broadcast
import lockfree/atomics

suite "BroadcastRing — Concurrent Stress Tests":
  type
    StressContext = object
      ring: BroadcastRing[int]
      totalItems: int
      receivedCount: ptr array[4, Atomic[int]]
      readerIndex: int

  proc losslessReaderThread(ctx: ptr StressContext) {.thread, gcsafe.} =
    {.cast(gcsafe).}:
      var cursor = ctx.ring.subscribe(soFromLatest)
      let idx = ctx.readerIndex
      var nextExpected = 0

      while nextExpected < ctx.totalItems:
        var val: int
        if cursor.tryRead(val):
          if val == nextExpected:
            discard ctx.receivedCount[idx].fetchAdd(1, moRelaxed)
            inc nextExpected
        else:
          sleep(0)

      cursor.unsubscribe()

  test "1 Publisher pushing 1,000 items to 4 concurrent readers under omBackoff":
    const Total = 1000
    var received: array[4, Atomic[int]]
    for i in 0 ..< 4:
      received[i].store(0, moRelaxed)

    let ring = initBroadcastRing[int](capacity = 128, overflowMode = omBackoff)
    var contexts: array[4, StressContext]
    var threads: array[4, Thread[ptr StressContext]]

    for i in 0 ..< 4:
      contexts[i] = StressContext(
        ring: ring,
        totalItems: Total,
        receivedCount: addr received,
        readerIndex: i
      )
      createThread(threads[i], losslessReaderThread, addr contexts[i])

    # Allow reader threads to subscribe
    sleep(10)

    # Publisher publishes Total items
    for i in 0 ..< Total:
      ring.publish(i)

    for i in 0 ..< 4:
      joinThread(threads[i])

    # Invariant: Every single reader received exactly Total items in order
    for i in 0 ..< 4:
      check received[i].load(moRelaxed) == Total

  proc lossyReaderThread(ctx: ptr StressContext) {.thread, gcsafe.} =
    var cursor = ctx.ring.subscribe(soFromLatest)
    let idx = ctx.readerIndex
    var count = 0

    while true:
      let res = cursor.poll()
      case res.kind
      of prSuccess:
        inc count
        discard ctx.receivedCount[idx].fetchAdd(1, moRelaxed)
      of prLagged:
        count += int(res.skippedCount)
      of prEmpty:
        if ctx.ring.core != nil and ctx.ring.core.publishedHead.load(moAcquire) >= uint64(ctx.totalItems):
          break
        sleep(0)

    cursor.unsubscribe()

  test "1 Publisher pushing 2,000 items to 4 concurrent readers under omDropOldest":
    const Total = 2000
    var received: array[4, Atomic[int]]
    for i in 0 ..< 4:
      received[i].store(0, moRelaxed)

    let ring = initBroadcastRing[int](capacity = 64, overflowMode = omDropOldest)
    var contexts: array[4, StressContext]
    var threads: array[4, Thread[ptr StressContext]]

    for i in 0 ..< 4:
      contexts[i] = StressContext(
        ring: ring,
        totalItems: Total,
        receivedCount: addr received,
        readerIndex: i
      )
      createThread(threads[i], lossyReaderThread, addr contexts[i])

    sleep(10)

    for i in 0 ..< Total:
      ring.publish(i)

    for i in 0 ..< 4:
      joinThread(threads[i])

    # Readers processed messages without hanging or crashing
    for i in 0 ..< 4:
      check received[i].load(moRelaxed) > 0

suite "TopicBus — Concurrent Subscribe Race":
  test "Concurrent getOrCreateRing no split-brain (HIGH-01)":
    let bus = initTopicBus[string]()
    const NumThreads = 8
    const TopicName = "concurrent.topic.race"

    type RaceContext = object
      bus: TopicBus[string]
      cursor: BroadcastCursor[string]
      subscribed: Atomic[bool]

    var contexts: array[NumThreads, RaceContext]
    var threads: array[NumThreads, Thread[ptr RaceContext]]

    proc raceWorker(ctx: ptr RaceContext) {.thread.} =
      # Concurrently subscribe to the exact same new topic
      ctx.cursor = ctx.bus.subscribe(TopicName, soFromLatest)
      ctx.subscribed.store(true, moRelease)

    for i in 0 ..< NumThreads:
      contexts[i].bus = bus
      contexts[i].subscribed.store(false, moRelaxed)
      createThread(threads[i], raceWorker, addr contexts[i])

    for i in 0 ..< NumThreads:
      joinThread(threads[i])

    check bus.topicCount == 1 # Exactly ONE ring created for the topic!

    # Publish a message and ensure ALL subscribers receive it (no split-brain partition)
    bus.publish(TopicName, "unified-broadcast-payload")

    for i in 0 ..< NumThreads:
      var msg: string
      check contexts[i].cursor.tryRead(msg) and msg == "unified-broadcast-payload"
      contexts[i].cursor.unsubscribe()

suite "BroadcastRing — Adversarial CRITICAL-01 Quarantine UAF Verification":
  test "Fast publisher wrap-around with preempted readers under omDropOldest (CRITICAL-01)":
    let ring = initBroadcastRing[string](capacity = 16, overflowMode = omDropOldest)
    const NumReaders = 4
    const Messages = 1000

    type UafContext = object
      ring: BroadcastRing[string]
      cursor: BroadcastCursor[string]
      received: Atomic[int]
      lagged: Atomic[int]
      stop: Atomic[bool]

    var contexts: array[NumReaders, UafContext]
    var threads: array[NumReaders, Thread[ptr UafContext]]

    proc slowReaderWorker(ctx: ptr UafContext) {.thread.} =
      while not ctx.stop.load(moAcquire):
        let res = ctx.cursor.poll()
        case res.kind
        of prSuccess:
          discard ctx.received.fetchAdd(1, moRelaxed)
          # Simulate slow reader / preemption
          if (ctx.received.load(moRelaxed) mod 17) == 0:
            sleep(1)
        of prLagged:
          discard ctx.lagged.fetchAdd(1, moRelaxed)
        of prEmpty:
          cpuRelax()

    for i in 0 ..< NumReaders:
      contexts[i].ring = ring
      contexts[i].cursor = ring.subscribe(soFromLatest)
      contexts[i].stop.store(false, moRelaxed)
      createThread(threads[i], slowReaderWorker, addr contexts[i])

    # Fast publisher rapid wrap-around with heap strings
    for i in 0 ..< Messages:
      ring.publish("payload_message_number_" & $i)

    # Let readers drain/settle
    sleep(50)
    for i in 0 ..< NumReaders:
      contexts[i].stop.store(true, moRelease)
      joinThread(threads[i])
      contexts[i].cursor.unsubscribe()

    for i in 0 ..< NumReaders:
      check contexts[i].received.load(moRelaxed) + contexts[i].lagged.load(moRelaxed) > 0
