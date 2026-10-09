## ==============================================================================
## Tests for Zero-Copy Lock-Free Streaming I/O Ring Buffer (Wave 4B)
## ==============================================================================

import unittest2
import lockfree/streambuffer

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
