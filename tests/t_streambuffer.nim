## ==============================================================================
## Tests for Zero-Copy Lock-Free Streaming I/O Ring Buffer (Wave 4B)
## ==============================================================================

import unittest2
import lockfree/streambuffer
import lockfree/atomics
import lockfree/atomics/backoff

suite "Wave 4B StreamRing Zero-Copy I/O Buffer":

  test "Basic SPSC capacity, empty/full, and simple write/read":
    var ring = initStreamRing(capacity = 64)
    check ring.capacity == 64
    check ring.isEmpty == true
    check ring.isFull == false
    check ring.availableRead == 0
    check ring.availableWrite == 64

    # Write 10 bytes
    let payload = [1'u8, 2, 3, 4, 5, 6, 7, 8, 9, 10]
    check ring.tryWrite(payload) == 10
    check ring.isEmpty == false
    check ring.availableRead == 10
    check ring.availableWrite == 54

    # Read 5 bytes
    var buf: array[5, byte]
    check ring.tryRead(buf) == 5
    check buf == [1'u8, 2, 3, 4, 5]
    check ring.availableRead == 5
    check ring.availableWrite == 59

    # Read remaining 5 bytes
    check ring.tryRead(buf) == 5
    check buf == [6'u8, 7, 8, 9, 10]
    check ring.availableRead == 0
    check ring.isEmpty == true

  test "Zero-copy IOVecPair wrap-around boundary mechanics":
    # 32-byte capacity ring
    var ring = initStreamRing(capacity = 32)
    
    # Fill 24 bytes, then read 24 bytes, advancing tail & head to 24
    var filler: array[24, byte]
    check ring.tryWrite(filler) == 24
    check ring.tryRead(filler) == 24
    check ring.availableRead == 0
    check ring.availableWrite == 32

    # Now tailIndex = 24.
    # If we request to write 16 bytes:
    # Slice 1: index 24..31 (len = 8)
    # Slice 2: index 0..7 (len = 8)
    var writeIov = ring.acquireWriteIov(16)
    check writeIov.totalLen == 16
    check writeIov.first.len == 8
    check writeIov.second.len == 8

    # Populate writeIov with test sequence: 100 .. 115
    for i in 0 ..< 8:
      cast[ptr UncheckedArray[byte]](writeIov.first.data)[i] = byte(100 + i)
      cast[ptr UncheckedArray[byte]](writeIov.second.data)[i] = byte(108 + i)
    ring.commitWrite(16)

    check ring.availableRead == 16

    # Now read back via acquireReadIov:
    # headIndex = 24.
    # Slice 1: index 24..31 (len = 8)
    # Slice 2: index 0..7 (len = 8)
    let readIov = ring.acquireReadIov(16)
    check readIov.totalLen == 16
    check readIov.first.len == 8
    check readIov.second.len == 8

    var received: array[16, byte]
    check readIov.copyTo(received) == 16
    ring.commitRead(16)

    for i in 0 ..< 16:
      check received[i] == byte(100 + i)
    check ring.isEmpty == true

  test "String read/write helpers":
    var ring = initStreamRing(capacity = 128)
    let msg = "Hello, Lock-Free Streaming I/O!"
    check ring.tryWriteString(msg) == msg.len
    check ring.availableRead == msg.len

    let readBack = ring.readString(msg.len)
    check readBack == msg
    check ring.isEmpty == true

  test "Blocking backpressure and timeout semantics":
    var ring = initStreamRing(capacity = 32)
    # Filling the buffer
    var fullData: array[32, byte]
    for i in 0 ..< 32: fullData[i] = byte(i)
    check ring.tryWrite(fullData) == 32
    check ring.isFull == true

    # Non-blocking write fails
    var extra: array[4, byte] = [1'u8, 2, 3, 4]
    check ring.tryWrite(extra) == 0

    # Write with immediate timeout 0 returns 0
    check ring.writeBlocking(extra, timeoutNs = 0) == 0

    # Write with short timeout (e.g. 5ms = 5_000_000 ns) expires and returns 0
    check ring.writeBlocking(extra, timeoutNs = 5_000_000) == 0

    # Read with short timeout on empty ring
    var emptyRing = initStreamRing(capacity = 32)
    var recvBuf: array[4, byte]
    check emptyRing.readBlocking(recvBuf, timeoutNs = 5_000_000) == 0

  test "Threaded SPSC Streaming Integrity (Producer-Consumer)":
    # Transfer 100,000 bytes across threads through a 1024-byte ring buffer
    const TotalBytes = 100_000
    type ThreadContext = object
      ring: ptr StreamRing
      success: bool

    var ring = initStreamRing(capacity = 1024)
    var ctx = ThreadContext(ring: addr ring, success: false)

    var consumerThread: Thread[ptr ThreadContext]

    proc consumerWorker(p: ptr ThreadContext) {.thread.} =
      var receivedCount = 0
      var nextExpected: byte = 0
      var buf: array[256, byte]
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
    var chunk: array[128, byte]
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

  test "MPMCStreamRing multi-producer multi-consumer basic transfer":
    var mpmc = initMPMCStreamRing(capacity = 64)
    check mpmc.capacity == 64
    check mpmc.availableRead == 0
    check mpmc.availableWrite == 64

    let data1 = [10'u8, 20, 30, 40]
    let data2 = [50'u8, 60, 70, 80]
    check mpmc.tryWrite(data1) == 4
    check mpmc.tryWrite(data2) == 4
    check mpmc.availableRead == 8

    var outBuf: array[8, byte]
    check mpmc.tryRead(outBuf) == 8
    check outBuf == [10'u8, 20, 30, 40, 50, 60, 70, 80]
    check mpmc.availableRead == 0

  test "Virtual Memory Mirroring rejection (HIGH-01)":
    expect ValueError:
      discard initStreamRing(capacity = 64, useVirtualMirror = true)

  test "Threaded SPSC Unbounded Blocking Dekker Barrier Integrity (timeoutNs = -1)":
    # Transfer 100,000 bytes across threads through a tiny 64-byte ring buffer
    # with timeoutNs = -1 (unbounded blocking). Any lost-wakeup will deadlock immediately.
    const TotalBytes = 100_000
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

  test "MPMCStreamRing concurrent multi-threaded stress (4P/4C, 100k items)":
    const
      NumProducers = 4
      NumConsumers = 4
      ItemsPerProducer = 25_000
      TotalItems = NumProducers * ItemsPerProducer # 100,000

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
