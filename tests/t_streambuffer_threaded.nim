## Multi-threaded integration tests for Zero-Copy Lock-Free Streaming I/O Ring Buffer.

import unittest2
import lockfree/streambuffer
import lockfree/atomics
import lockfree/atomics/backoff

suite "StreamRing Multi-Threaded Concurrency":
  test "Threaded SPSC blocking transfer":
    const TotalBytes = 5_000
    type ThreadContext = object
      ring: ptr StreamRing
      success: bool

    var ring = initStreamRing(capacity = 512)
    var ctx = ThreadContext(ring: addr ring, success: false)

    var consumerThread: Thread[ptr ThreadContext]

    proc consumerWorker(p: ptr ThreadContext) {.thread.} =
      var receivedCount = 0
      var nextExpected: byte = 0
      var buf: array[64, byte]
      while receivedCount < TotalBytes:
        let n = p.ring[].readBlocking(buf, timeoutNs = 50_000_000)
        if n > 0:
          for i in 0 ..< n:
            if buf[i] != nextExpected:
              p.success = false
              return
            nextExpected = byte((int(nextExpected) + 1) and 255)
          receivedCount += n
      p.success = (receivedCount == TotalBytes)

    createThread(consumerThread, consumerWorker, addr ctx)

    # Producer thread
    var sentCount = 0
    var nextValue: byte = 0
    var chunk: array[64, byte]
    while sentCount < TotalBytes:
      let toSend = min(chunk.len, TotalBytes - sentCount)
      for i in 0 ..< toSend:
        chunk[i] = nextValue
        nextValue = byte((int(nextValue) + 1) and 255)
      let n = ring.writeBlocking(chunk[0 ..< toSend], timeoutNs = 50_000_000)
      sentCount += n

    joinThread(consumerThread)
    check ctx.success == true
    check ring.isEmpty == true

  test "Threaded SPSC Unbounded Blocking Dekker Barrier Integrity (timeoutNs = -1)":
    const TotalBytes = 5_000
    type ThreadContext = object
      ring: ptr StreamRing
      success: bool
      receivedCount: int

    var ring = initStreamRing(capacity = 64)
    var ctx = ThreadContext(ring: addr ring, success: false, receivedCount: 0)

    var consumerThread: Thread[ptr ThreadContext]

    proc consumerWorker(p: ptr ThreadContext) {.thread.} =
      var nextExpected: byte = 0
      var buf: array[17, byte]
      while p.receivedCount < TotalBytes:
        let toRead = min(buf.len, TotalBytes - p.receivedCount)
        let n = p.ring[].readBlocking(toOpenArray(buf, 0, toRead - 1), timeoutNs = -1)
        if n > 0:
          for i in 0 ..< n:
            if buf[i] != nextExpected:
              p.success = false
              return
            nextExpected = byte((int(nextExpected) + 1) and 255)
          p.receivedCount += n
      p.success = (p.receivedCount == TotalBytes)

    createThread(consumerThread, consumerWorker, addr ctx)

    # Producer thread with prime chunk size (13 bytes)
    var sentCount = 0
    var nextValue: byte = 0
    var chunk: array[13, byte]
    while sentCount < TotalBytes:
      let toSend = min(chunk.len, TotalBytes - sentCount)
      for i in 0 ..< toSend:
        chunk[i] = nextValue
        nextValue = byte((int(nextValue) + 1) and 255)
      let n = ring.writeBlocking(toOpenArray(chunk, 0, toSend - 1), timeoutNs = -1)
      sentCount += n

    joinThread(consumerThread)
    check ctx.success == true
    check ctx.receivedCount == TotalBytes
    check ring.isEmpty == true

  test "MPMCStreamRing concurrent multi-threaded stress (4P/4C)":
    const
      NumProducers = 4
      NumConsumers = 4
      ItemsPerProducer = 1_000
      TotalItems = NumProducers * ItemsPerProducer # 4,000

    type
      MPMCContext = object
        ring: ptr MPMCStreamRing
        totalConsumed: Atomic[int]
        producerSuccess: array[NumProducers, bool]
        consumerSuccess: array[NumConsumers, bool]

    var ring = initMPMCStreamRing(capacity = 64)
    var ctx: MPMCContext
    ctx.ring = addr ring
    ctx.totalConsumed.store(0, moRelaxed)

    type WorkerArg = object
      ctx: ptr MPMCContext
      id: int

    proc producerWorker(arg: WorkerArg) {.thread.} =
      var val: byte = byte(arg.id and 0xFF)
      var produced = 0
      while produced < ItemsPerProducer:
        var buf: array[1, byte] = [val]
        let n = arg.ctx.ring[].tryWrite(buf)
        if n > 0:
          inc produced
        else:
          cpuPause()
      arg.ctx.producerSuccess[arg.id] = true

    proc consumerWorker(arg: WorkerArg) {.thread.} =
      var localBuf: array[16, byte]
      while arg.ctx.totalConsumed.load(moAcquire) < TotalItems:
        let n = arg.ctx.ring[].tryRead(localBuf)
        if n > 0:
          discard arg.ctx.totalConsumed.fetchAdd(n, moRelease)
        else:
          cpuPause()
      arg.ctx.consumerSuccess[arg.id] = true

    var prodThreads: array[NumProducers, Thread[WorkerArg]]
    var consThreads: array[NumConsumers, Thread[WorkerArg]]

    var prodArgs: array[NumProducers, WorkerArg]
    var consArgs: array[NumConsumers, WorkerArg]

    for i in 0 ..< NumConsumers:
      consArgs[i] = WorkerArg(ctx: addr ctx, id: i)
      createThread(consThreads[i], consumerWorker, consArgs[i])

    for i in 0 ..< NumProducers:
      prodArgs[i] = WorkerArg(ctx: addr ctx, id: i)
      createThread(prodThreads[i], producerWorker, prodArgs[i])

    for i in 0 ..< NumProducers:
      joinThread(prodThreads[i])
      check ctx.producerSuccess[i] == true

    for i in 0 ..< NumConsumers:
      joinThread(consThreads[i])
      check ctx.consumerSuccess[i] == true

    check ctx.totalConsumed.load(moAcquire) == TotalItems
    check ring.availableRead() == 0
