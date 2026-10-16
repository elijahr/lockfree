## Unit, ARC/ORC lifecycle, C ABI, and multi-threaded MPMC stress tests for
## Lindén-Jonsson `SkipListPriorityQueue[T]`.

import std/[options, algorithm, strutils]
import unittest2
import lockfree
import lockfree/priority_queue
import lockfree/cabi

# ---------------------------------------------------------------------------
# ARC/ORC Destructor Lifecycle Tracking
# ---------------------------------------------------------------------------

var gLiveTrackedCount: Atomic[int]

type
  TrackedPayload = object
    id: int
    label: string
    active: bool

proc `=destroy`(x: var TrackedPayload) =
  if x.active:
    discard gLiveTrackedCount.fetchSub(1, moAcquireRelease)
    x.active = false
  `=destroy`(x.label)

proc `=copy`(dst: var TrackedPayload, src: TrackedPayload) =
  if dst.active and not src.active:
    discard gLiveTrackedCount.fetchSub(1, moAcquireRelease)
  elif not dst.active and src.active:
    discard gLiveTrackedCount.fetchAdd(1, moAcquireRelease)
  dst.id = src.id
  dst.label = src.label
  dst.active = src.active

proc `=sink`(dst: var TrackedPayload, src: TrackedPayload) =
  if dst.active:
    discard gLiveTrackedCount.fetchSub(1, moAcquireRelease)
  dst.id = src.id
  dst.label = src.label
  dst.active = src.active

proc makeTracked(id: int, s: string): TrackedPayload =
  discard gLiveTrackedCount.fetchAdd(1, moAcquireRelease)
  TrackedPayload(id: id, label: s, active: true)

type
  PayloadRef = ref object
    id: int
    name: string

# ---------------------------------------------------------------------------
# Single-Threaded Unit Tests
# ---------------------------------------------------------------------------

suite "SkipListPriorityQueue Basic Operations":
  test "empty priority queue invariants":
    var pq = newSkipListPriorityQueue[int]()
    check pq.len == 0
    check pq.isEmpty
    check pq.peekMin().isNone
    check pq.popMin().isNone
    var outVal = -1
    check not pq.tryPopMin(outVal)
    check $pq == "SkipListPriorityQueue([])"

  test "ascending priority extraction across scrambled insertions":
    var pq = newSkipListPriorityQueue[int]()
    let inputs = @[50, 10, 90, 30, 70, 20, 80, 40, 60, 100, 5, 95, 1, 65, 15]
    for x in inputs:
      pq.push(x)

    check pq.len == inputs.len
    check not pq.isEmpty
    check pq.peekMin() == some(1)
    check pq.len == inputs.len

    var popped: seq[int]
    while not pq.isEmpty:
      let opt = pq.popMin()
      check opt.isSome
      popped.add(opt.get())

    var expected = inputs
    expected.sort()
    check popped == expected
    check pq.len == 0
    check pq.isEmpty
    check pq.popMin().isNone

  test "duplicate priorities preserve all elements in strict FIFO order":
    var pq = newSkipListPriorityQueue[Prioritized[int, int]]()
    # Push 40 items with priority 10, interleaved with priority 5 and priority 20
    for seqNum in 1 .. 40:
      pq.push(10, seqNum)
      if seqNum mod 2 == 0:
        pq.push(5, 1000 + seqNum)
      else:
        pq.push(20, 2000 + seqNum)

    check pq.len == 80

    # First 20 popped items must be priority 5 in exact FIFO order (1002, 1004, ..., 1040)
    for idx in 1 .. 20:
      let item = pq.popMin().get()
      check item.priority == 5
      check item.value == 1000 + idx * 2

    # Next 40 popped items must be priority 10 in exact FIFO order (1 .. 40)
    for seqNum in 1 .. 40:
      let item = pq.popMin().get()
      check item.priority == 10
      check item.value == seqNum

    # Final 20 popped items must be priority 20 in exact FIFO order (2001, 2003, ..., 2039)
    for idx in 0 ..< 20:
      let item = pq.popMin().get()
      check item.priority == 20
      check item.value == 2000 + (idx * 2 + 1)

    check pq.isEmpty
    check pq.len == 0

  test "batch physical restructuring across >200 pops and re-insertions":
    var pq = newSkipListPriorityQueue[int]()
    # Exceed DefaultRestructureThreshold (32) many times over
    for round in 0 ..< 5:
      for i in countdown(100, 1):
        pq.push(i + round * 1000)
      check pq.len == 100
      for i in 1 .. 100:
        var v = 0
        check pq.tryPopMin(v)
        check v == i + round * 1000
      check pq.len == 0
      check pq.isEmpty

  test "clear operation empties queue and allows reuse":
    var pq = newSkipListPriorityQueue[string]()
    pq.push("delta")
    pq.push("alpha")
    pq.push("charlie")
    pq.push("bravo")
    check pq.len == 4
    check pq.peekMin() == some("alpha")

    pq.clear()
    check pq.len == 0
    check pq.isEmpty
    check pq.peekMin().isNone
    check pq.popMin().isNone

    pq.push("echo")
    pq.push("Beta")
    check pq.len == 2
    check pq.popMin() == some("Beta")
    check pq.popMin() == some("echo")
    check pq.isEmpty

  test "ergonomic aliases and constructors":
    var pq1: PriorityQueue[int] = newPriorityQueue[int]()
    var pq2: PriorityQueue[int] = initPriorityQueue[int]()
    var pq3: ConcurrentPriorityQueue[int] = newConcurrentPriorityQueue[int]()
    var pq4: LockFreePriorityQueue[int] = newLockFreePriorityQueue[int]()
    var pq5 = initSkipListPriorityQueue[int]()

    pq1.push(3)
    pq1.push(1)
    pq2.push(2)
    pq3.push(5)
    pq4.push(4)
    pq5.push(0)

    check pq1.popMin() == some(1)
    check pq1.popMin() == some(3)
    check pq2.popMin() == some(2)
    check pq3.popMin() == some(5)
    check pq4.popMin() == some(4)
    check pq5.popMin() == some(0)

# ---------------------------------------------------------------------------
# ARC/ORC Managed Types & Destructor Verification
# ---------------------------------------------------------------------------

suite "SkipListPriorityQueue ARC/ORC Managed Types & Destructor Lifecycle":
  test "custom =destroy payload has zero leaks after popMin and queue destruction":
    gLiveTrackedCount.store(0, moRelease)
    block:
      var pq = newSkipListPriorityQueue[Prioritized[int, TrackedPayload]]()
      for i in 1 .. 160:
        pq.push(161 - i, makeTracked(i, "payload_" & $i))
      check pq.len == 160
      check gLiveTrackedCount.load(moAcquire) == 160

      for expectedPrio in 1 .. 160:
        let item = pq.popMin()
        check item.isSome
        check item.get().priority == expectedPrio
        check item.get().value.id == 161 - expectedPrio
      check pq.isEmpty

    # After pq goes out of scope, all retired and remaining nodes must be destroyed
    check gLiveTrackedCount.load(moAcquire) == 0

  test "destroying non-empty queue reclaims all unpopped managed payloads":
    gLiveTrackedCount.store(0, moRelease)
    block:
      var pq = newSkipListPriorityQueue[Prioritized[int, TrackedPayload]]()
      for i in 1 .. 96:
        pq.push(i, makeTracked(i, "unpopped_" & $i))
      check pq.len == 96
      # Pop only 40 items (leaving 56 items in the queue + deleted prefix)
      for i in 1 .. 40:
        discard pq.popMin()
      check pq.len == 56

    check gLiveTrackedCount.load(moAcquire) == 0

  test "ref object payloads with Prioritized wrapper":
    var pq = newSkipListPriorityQueue[Prioritized[int, PayloadRef]]()
    for i in countdown(30, 1):
      pq.push(i, PayloadRef(id: i, name: "node_" & $i))
    check pq.len == 30
    for i in 1 .. 30:
      let entry = pq.popMin().get()
      check entry.priority == i
      check entry.value.id == i
      check entry.value.name == "node_" & $i
    check pq.isEmpty

  test "accessing >32 SkipListPriorityQueue instances on one thread recovers DEBRA handle":
    const NumQueues = 48
    var queues = newSeq[SkipListPriorityQueue[int]](NumQueues)
    for q in 0 ..< NumQueues:
      queues[q] = newSkipListPriorityQueue[int]()

    for round in 0 ..< 80:
      for q in 0 ..< NumQueues:
        queues[q].push(100 - round)
        check queues[q].peekMin() == some(100 - round)

    for q in 0 ..< NumQueues:
      check queues[q].len == 80
      for round in countdown(79, 0):
        check queues[q].popMin() == some(100 - round)
      check queues[q].isEmpty

# ---------------------------------------------------------------------------
# C ABI Tests (lfq_pqueue_*)
# ---------------------------------------------------------------------------

var gCabiDestroyedCount: Atomic[int]

proc testPqueueDestructor(item: pointer, userData: pointer) {.cdecl, gcsafe.} =
  discard gCabiDestroyedCount.fetchAdd(1, moAcquireRelease)
  if userData != nil:
    let tagPtr = cast[ptr int](userData)
    tagPtr[] = tagPtr[] + cast[int](item)

suite "SkipListPriorityQueue C ABI (lfq_pqueue_*)":
  test "lfq_pqueue lifecycle, push, peek_min, pop_min, and FIFO tie-breaking":
    var pq: ptr lfq_pqueue_t = nil
    check lfq_pqueue_create(nil, nil, addr pq) == LFQ_OK
    check pq != nil
    check lfq_pqueue_len(pq) == 0
    check lfq_pqueue_is_empty(pq) == true

    check lfq_pqueue_push(pq, 30'i64, cast[pointer](300)) == LFQ_OK
    check lfq_pqueue_push(pq, 10'i64, cast[pointer](101)) == LFQ_OK
    check lfq_pqueue_push(pq, 10'i64, cast[pointer](102)) == LFQ_OK
    check lfq_pqueue_push(pq, 20'i64, cast[pointer](200)) == LFQ_OK

    check lfq_pqueue_len(pq) == 4
    check lfq_pqueue_is_empty(pq) == false

    var prio: int64 = 0
    var item: pointer = nil
    check lfq_pqueue_peek_min(pq, addr prio, addr item) == LFQ_OK
    check prio == 10'i64
    check cast[int](item) == 101
    check lfq_pqueue_len(pq) == 4

    check lfq_pqueue_pop_min(pq, addr prio, addr item) == LFQ_OK
    check prio == 10'i64
    check cast[int](item) == 101

    check lfq_pqueue_pop_min(pq, addr prio, addr item) == LFQ_OK
    check prio == 10'i64
    check cast[int](item) == 102

    check lfq_pqueue_pop_min(pq, addr prio, addr item) == LFQ_OK
    check prio == 20'i64
    check cast[int](item) == 200

    check lfq_pqueue_pop_min(pq, nil, addr item) == LFQ_OK
    check cast[int](item) == 300

    check lfq_pqueue_pop_min(pq, addr prio, addr item) == LFQ_ERR_EMPTY
    check lfq_pqueue_peek_min(pq, addr prio, addr item) == LFQ_ERR_EMPTY
    check lfq_pqueue_len(pq) == 0
    check lfq_pqueue_is_empty(pq) == true

    check lfq_pqueue_destroy(pq) == LFQ_OK

  test "lfq_pqueue_clear and lfq_pqueue_destroy invoke destructor callback":
    gCabiDestroyedCount.store(0, moRelease)
    var sumTag: int = 0
    var pq: ptr lfq_pqueue_t = nil
    check lfq_pqueue_create(testPqueueDestructor, addr sumTag, addr pq) == LFQ_OK

    check lfq_pqueue_push(pq, 5'i64, cast[pointer](10)) == LFQ_OK
    check lfq_pqueue_push(pq, 15'i64, cast[pointer](20)) == LFQ_OK
    check lfq_pqueue_clear(pq) == LFQ_OK
    check gCabiDestroyedCount.load(moAcquire) == 2
    check sumTag == 30
    check lfq_pqueue_is_empty(pq) == true

    check lfq_pqueue_push(pq, 1'i64, cast[pointer](40)) == LFQ_OK
    check lfq_pqueue_push(pq, 2'i64, cast[pointer](60)) == LFQ_OK
    check lfq_pqueue_destroy(pq) == LFQ_OK
    check gCabiDestroyedCount.load(moAcquire) == 4
    check sumTag == 130

  test "lfq_pqueue invalid argument handling":
    var pq: ptr lfq_pqueue_t = nil
    var item: pointer = nil
    check lfq_pqueue_create(nil, nil, nil) == LFQ_ERR_INVALID_ARG
    check lfq_pqueue_destroy(nil) == LFQ_ERR_INVALID_ARG
    check lfq_pqueue_clear(nil) == LFQ_ERR_INVALID_ARG
    check lfq_pqueue_push(nil, 1'i64, nil) == LFQ_ERR_INVALID_ARG
    check lfq_pqueue_pop_min(nil, nil, addr item) == LFQ_ERR_INVALID_ARG
    check lfq_pqueue_peek_min(nil, nil, addr item) == LFQ_ERR_INVALID_ARG
    check lfq_pqueue_len(nil) == 0
    check lfq_pqueue_is_empty(nil) == true
    discard pq

# ---------------------------------------------------------------------------
# Multi-Threaded Concurrency & Stress Tests
# ---------------------------------------------------------------------------

const
  NumProducers = 4
  NumConsumers = 4
  ItemsPerProducer = 2_000
  TotalItems = NumProducers * ItemsPerProducer

type
  ProducerArg = object
    pq: SkipListPriorityQueue[int]
    threadId: int
    pushedSum: ptr Atomic[int64]
    producersDone: ptr Atomic[int]

  ConsumerArg = object
    pq: SkipListPriorityQueue[int]
    poppedCount: ptr Atomic[int]
    poppedSum: ptr Atomic[int64]
    producersDone: ptr Atomic[int]

proc producerWorker(arg: ProducerArg) {.thread.} =
  {.cast(gcsafe).}:
    arg.pq.registerThread()
    defer:
      arg.pq.unregisterThread()
    var localSum: int64 = 0
    for i in 0 ..< ItemsPerProducer:
      # Scramble priorities deterministically across producers
      let val = ((i * 73 + arg.threadId * 19) mod 500) + 1
      arg.pq.push(val)
      localSum += int64(val)
    discard arg.pushedSum[].fetchAdd(localSum, moAcquireRelease)
    discard arg.producersDone[].fetchAdd(1, moRelease)

proc consumerWorker(arg: ConsumerArg) {.thread.} =
  {.cast(gcsafe).}:
    arg.pq.registerThread()
    defer:
      arg.pq.unregisterThread()
    var localSum: int64 = 0
    var localCount = 0
    var val = 0
    while true:
      if arg.pq.tryPopMin(val):
        localSum += int64(val)
        inc localCount
      else:
        if arg.producersDone[].load(moAcquire) == NumProducers and arg.pq.isEmpty:
          if not arg.pq.tryPopMin(val):
            break
          else:
            localSum += int64(val)
            inc localCount
    discard arg.poppedSum[].fetchAdd(localSum, moAcquireRelease)
    discard arg.poppedCount[].fetchAdd(localCount, moAcquireRelease)

type
  MonotonicConsumerArg = object
    pq: SkipListPriorityQueue[int]
    poppedCount: ptr Atomic[int]
    orderViolations: ptr Atomic[int]

proc monotonicConsumerWorker(arg: MonotonicConsumerArg) {.thread.} =
  {.cast(gcsafe).}:
    arg.pq.registerThread()
    defer:
      arg.pq.unregisterThread()
    var prev = low(int)
    var val = 0
    var localCount = 0
    while arg.pq.tryPopMin(val):
      if val < prev:
        discard arg.orderViolations[].fetchAdd(1, moRelaxed)
      prev = val
      inc localCount
    discard arg.poppedCount[].fetchAdd(localCount, moAcquireRelease)

suite "SkipListPriorityQueue Multi-Threaded MPMC Stress":
  test "concurrent 4P x 4C MPMC exact item and sum conservation":
    var pq = newSkipListPriorityQueue[int]()
    var pushedSum: Atomic[int64]
    var poppedSum: Atomic[int64]
    var poppedCount: Atomic[int]
    var producersDone: Atomic[int]

    pushedSum.store(0, moRelaxed)
    poppedSum.store(0, moRelaxed)
    poppedCount.store(0, moRelaxed)
    producersDone.store(0, moRelaxed)

    var prodThreads: array[NumProducers, Thread[ProducerArg]]
    var consThreads: array[NumConsumers, Thread[ConsumerArg]]

    for i in 0 ..< NumProducers:
      createThread(
        prodThreads[i],
        producerWorker,
        ProducerArg(
          pq: pq,
          threadId: i,
          pushedSum: addr pushedSum,
          producersDone: addr producersDone,
        ),
      )

    for i in 0 ..< NumConsumers:
      createThread(
        consThreads[i],
        consumerWorker,
        ConsumerArg(
          pq: pq,
          poppedCount: addr poppedCount,
          poppedSum: addr poppedSum,
          producersDone: addr producersDone,
        ),
      )

    joinThreads(prodThreads)
    joinThreads(consThreads)

    # Drain any final straggler if consumers exited concurrently
    var rem = 0
    while pq.tryPopMin(rem):
      discard poppedSum.fetchAdd(int64(rem), moAcquireRelease)
      discard poppedCount.fetchAdd(1, moAcquireRelease)

    check poppedCount.load(moAcquire) == TotalItems
    check poppedSum.load(moAcquire) == pushedSum.load(moAcquire)
    check pq.len == 0
    check pq.isEmpty

  test "concurrent multi-producer fill followed by parallel consumer drain maintains per-thread monotonic order":
    var pq = newSkipListPriorityQueue[int]()
    var pushedSum: Atomic[int64]
    var producersDone: Atomic[int]
    pushedSum.store(0, moRelaxed)
    producersDone.store(0, moRelaxed)

    var prodThreads: array[NumProducers, Thread[ProducerArg]]
    for i in 0 ..< NumProducers:
      createThread(
        prodThreads[i],
        producerWorker,
        ProducerArg(
          pq: pq,
          threadId: i,
          pushedSum: addr pushedSum,
          producersDone: addr producersDone,
        ),
      )
    joinThreads(prodThreads)
    check pq.len == TotalItems

    var poppedCount: Atomic[int]
    var orderViolations: Atomic[int]
    poppedCount.store(0, moRelaxed)
    orderViolations.store(0, moRelaxed)

    var consThreads: array[NumConsumers, Thread[MonotonicConsumerArg]]
    for i in 0 ..< NumConsumers:
      createThread(
        consThreads[i],
        monotonicConsumerWorker,
        MonotonicConsumerArg(
          pq: pq,
          poppedCount: addr poppedCount,
          orderViolations: addr orderViolations,
        ),
      )
    joinThreads(consThreads)

    check orderViolations.load(moAcquire) == 0
    check poppedCount.load(moAcquire) == TotalItems
    check pq.isEmpty
