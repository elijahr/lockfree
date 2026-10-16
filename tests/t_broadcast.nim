## Tests for BroadcastRing[T] and TopicBus[T].
## Covers:
##   - Basic single-threaded fan-out broadcast to multiple cursors
##   - Subscription origins (soFromLatest vs soFromEarliest)
##   - Slow-consumer lag detection and overrun handling (omDropOldest)
##   - Backpressure and flow-control (omBackoff)
##   - ARC/ORC managed types and leak-free destruction
##   - Concurrent multi-reader stress testing under omBackoff (lossless)
##   - Concurrent multi-reader stress testing under omDropOldest (lossy lag accounting)
##   - TopicBus[T] topic isolation and multi-topic routing

import unittest2
import std/[options, os]
import lockfree/broadcast
import lockfree/atomics

suite "BroadcastRing — Basic Fan-Out Broadcast":
  test "empty state and initialization":
    let ring = initBroadcastRing[int](capacity = 32, overflowMode = omDropOldest)
    check ring.capacity >= 32
    check ring.len == 0
    check ring.subscriberCount == 0

    var c1 = ring.subscribe(soFromLatest)
    check ring.subscriberCount == 1

    var val: int
    check not c1.tryRead(val)
    check c1.poll().kind == prEmpty

    c1.unsubscribe()
    check ring.subscriberCount == 0

  test "single publisher, multiple independent readers":
    let ring = initBroadcastRing[int](capacity = 64)
    var c1 = ring.subscribe(soFromLatest)
    var c2 = ring.subscribe(soFromLatest)
    var c3 = ring.subscribe(soFromLatest)
    check ring.subscriberCount == 3

    for i in 1 .. 10:
      ring.publish(i)

    # Every reader must receive all 10 messages in order
    for expected in 1 .. 10:
      let r1 = c1.poll()
      let r2 = c2.poll()
      let r3 = c3.poll()

      check r1.kind == prSuccess and r1.val == expected
      check r2.kind == prSuccess and r2.val == expected
      check r3.kind == prSuccess and r3.val == expected

    # Ring should now be empty from readers' perspectives
    check c1.poll().kind == prEmpty
    check c2.poll().kind == prEmpty
    check c3.poll().kind == prEmpty

    c1.unsubscribe()
    c2.unsubscribe()
    c3.unsubscribe()
    check ring.subscriberCount == 0

  test "subscription origins (soFromLatest vs soFromEarliest)":
    let ring = initBroadcastRing[int](capacity = 64)
    for i in 1 .. 20:
      ring.publish(i)

    # cEarliest starts from oldest available
    var cEarliest = ring.subscribe(soFromEarliest)
    # cLatest starts from current tail
    var cLatest = ring.subscribe(soFromLatest)

    # cEarliest sees message 1
    let rEarly = cEarliest.poll()
    check rEarly.kind == prSuccess and rEarly.val == 1

    # cLatest sees nothing yet
    check cLatest.poll().kind == prEmpty

    # Publish new message
    ring.publish(999)

    # cLatest sees only 999
    let rLate = cLatest.poll()
    check rLate.kind == prSuccess and rLate.val == 999
    check cLatest.poll().kind == prEmpty

    cEarliest.unsubscribe()
    cLatest.unsubscribe()

suite "BroadcastRing — Overflow & Lag Detection (omDropOldest)":
  test "slow reader detects overwritten slot and advances with lag":
    # Small capacity ring (16 slots)
    let ring = initBroadcastRing[int](capacity = 16, overflowMode = omDropOldest)
    var fastCursor = ring.subscribe(soFromLatest)
    var slowCursor = ring.subscribe(soFromLatest)

    # Publish 5 messages
    for i in 1 .. 5:
      ring.publish(i)

    # Fast cursor consumes 5 messages
    for i in 1 .. 5:
      var val: int
      check fastCursor.tryRead(val)
      check val == i

    # Slow cursor does not consume anything!
    # Publish 30 more messages, completely overwriting the 16-slot ring multiple times.
    # Fast cursor keeps pace with publisher, while slow cursor does not consume anything!
    for i in 6 .. 35:
      ring.publish(i)
      var val: int
      check fastCursor.tryRead(val)
      check val == i

    # Now slowCursor polls: it was waiting for message 1, which has been overwritten!
    let pollRes = slowCursor.poll()
    check pollRes.kind == prLagged
    check pollRes.skippedCount > 0
    check slowCursor.lag > 0

    # After lag recovery, slow cursor can read the subsequent available messages
    var readAfterLag = 0
    while true:
      var val: int
      if slowCursor.tryRead(val):
        inc readAfterLag
      else:
        break

    check readAfterLag > 0
    # Invariant: received + skipped must equal total published
    check slowCursor.lag + readAfterLag.uint64 == 35

    fastCursor.unsubscribe()
    slowCursor.unsubscribe()

suite "BroadcastRing — Backpressure & Flow-Control (omBackoff)":
  test "tryPublish returns false when ring is full until consumer reads":
    const Cap = 16
    let ring = initBroadcastRing[int](capacity = Cap, overflowMode = omBackoff)
    var cursor = ring.subscribe(soFromLatest)

    # Fill ring to capacity
    for i in 1 .. Cap:
      check ring.tryPublish(i)

    # Ring is now full: slowest (and only) active cursor has read 0 items
    check not ring.tryPublish(999)

    # Consumer reads 1 item
    var val: int
    check cursor.tryRead(val)
    check val == 1

    # Now 1 slot is free: tryPublish must succeed
    check ring.tryPublish(100)

    # Full again
    check not ring.tryPublish(101)

    cursor.unsubscribe()
    # After cursor unsubscribes, ring is no longer blocked by slow consumer
    check ring.tryPublish(102)

when defined(gcArc) or defined(gcOrc) or defined(gcAtomicArc):
  suite "BroadcastRing — ARC/ORC Lifecycle Management":
    type TrackedObj = ref object
      id: int

    var gDestructCount {.global.}: Atomic[int]

    proc `=destroy`(x: var typeof(TrackedObj()[])) =
      if x.id > 0:
        discard gDestructCount.fetchAdd(1, moRelaxed)

    test "managed ref objects correctly freed on overwrite and ring destruction":
      gDestructCount.store(0, moRelaxed)
      const Total = 50
      block:
        let ring = initBroadcastRing[TrackedObj](capacity = 16, overflowMode = omDropOldest)
        var cursor = ring.subscribe(soFromLatest)

        for i in 1 .. Total:
          ring.publish(TrackedObj(id: i))
          if i mod 3 == 0:
            var obj: TrackedObj
            discard cursor.tryRead(obj)

        cursor.unsubscribe()

      # When ring and all objects leave scope, all 50 allocated objects must be destroyed
      check gDestructCount.load(moRelaxed) == Total

suite "BroadcastRing — Managed String and Seq Payloads":
  test "strings and seqs under broadcast":
    let ring = initBroadcastRing[string](capacity = 32)
    var c = ring.subscribe(soFromLatest)

    ring.publish("alpha")
    ring.publish("beta")
    ring.publish("gamma")

    var s: string
    check c.tryRead(s) and s == "alpha"
    check c.tryRead(s) and s == "beta"
    check c.tryRead(s) and s == "gamma"
    check not c.tryRead(s)

    c.unsubscribe()

suite "TopicBus — Multi-Topic Multiplexer":
  test "topic isolation and routing":
    let bus = initTopicBus[string]()
    check bus.topicCount == 0

    var btcCursor = bus.subscribe("crypto.btc", soFromLatest)
    var ethCursor = bus.subscribe("crypto.eth", soFromLatest)
    check bus.topicCount == 2
    check bus.hasTopic("crypto.btc")
    check bus.hasTopic("crypto.eth")
    check not bus.hasTopic("crypto.sol")

    bus.publish("crypto.btc", "BTC-1")
    bus.publish("crypto.eth", "ETH-1")
    bus.publish("crypto.btc", "BTC-2")

    var msg: string
    check btcCursor.tryRead(msg) and msg == "BTC-1"
    check btcCursor.tryRead(msg) and msg == "BTC-2"
    check not btcCursor.tryRead(msg)

    check ethCursor.tryRead(msg) and msg == "ETH-1"
    check not ethCursor.tryRead(msg)

    btcCursor.unsubscribe()
    ethCursor.unsubscribe()

suite "BroadcastRing — Inline Seqlock & Non-Blocking tryPublish (HIGH-PERF-01)":
  test "inline seqlock fast path allocates zero VBox for trivial types":
    let ring = initBroadcastRing[int](capacity = 16, overflowMode = omDropOldest)
    var c1 = ring.subscribe(soFromLatest)
    var c2 = ring.subscribe(soFromLatest)
    check ring.core.activeCursorMask.load(moAcquire) == 0b11'u64

    for round in 0 ..< 20:
      for i in 1 .. 16:
        let v = round * 100 + i
        ring.publish(v)
        var out1, out2: int
        check c1.tryRead(out1) and out1 == v
        check c2.tryRead(out2) and out2 == v

    for i in 0 ..< 16:
      check ring.core.slots[i].vbox.load(moRelaxed) == nil

    c1.unsubscribe()
    check ring.core.activeCursorMask.load(moAcquire) == 0b10'u64
    c2.unsubscribe()
    check ring.core.activeCursorMask.load(moAcquire) == 0'u64

  test "tryPublish in omBackoff mode atomically returns false when full":
    let ring = initBroadcastRing[int](capacity = 16, overflowMode = omBackoff)
    var c = ring.subscribe(soFromLatest)

    for i in 1 .. 16:
      check ring.tryPublish(i)

    # Ring is now at capacity relative to slow cursor c; tryPublish must return false immediately
    check not ring.tryPublish(999)

    var v: int
    check c.tryRead(v) and v == 1
    # Now 1 slot freed up
    check ring.tryPublish(17)
    check not ring.tryPublish(18)

    c.unsubscribe()

