import std/[options, sequtils, algorithm]
import unittest2
import ../src/lockfree/[bstack, bpriority_queue, btable]
when compileOption("threads"):
  import ../src/lockfree
import ../src/lockfree/atomics
import ../src/lockfree/atomics/backoff

type
  TrackedPayload = object
    id: int

var
  gTrackedLiveCount: Atomic[int]
  gTrackedDestroyCount: Atomic[int]

proc `=destroy`(x: TrackedPayload) =
  if x.id != 0:
    discard gTrackedLiveCount.fetchSub(1, moAcquireRelease)
    discard gTrackedDestroyCount.fetchAdd(1, moAcquireRelease)

proc `=copy`(dest: var TrackedPayload, src: TrackedPayload) =
  if dest.id == src.id:
    return
  if dest.id != 0:
    discard gTrackedLiveCount.fetchSub(1, moAcquireRelease)
    discard gTrackedDestroyCount.fetchAdd(1, moAcquireRelease)
  dest.id = src.id
  if dest.id != 0:
    discard gTrackedLiveCount.fetchAdd(1, moAcquireRelease)

proc `=sink`(dest: var TrackedPayload, src: TrackedPayload) =
  if dest.id != 0 and dest.id != src.id:
    discard gTrackedLiveCount.fetchSub(1, moAcquireRelease)
    discard gTrackedDestroyCount.fetchAdd(1, moAcquireRelease)
  dest.id = src.id

proc makeTracked(id: int): TrackedPayload =
  doAssert id != 0
  discard gTrackedLiveCount.fetchAdd(1, moAcquireRelease)
  TrackedPayload(id: id)

proc `<`(a, b: TrackedPayload): bool {.inline.} =
  a.id < b.id

proc `==`(a, b: TrackedPayload): bool {.inline.} =
  a.id == b.id

suite "BStack (Bounded Zero-SMR Lock-Free Stack)":
  test "SPSC, MPSC, SPMC, MPMC LIFO order and strict capacity enforcement":
    var spsc = initSpscBStack[int, 8]()
    check spsc.capacity == 8
    check spsc.len == 0
    check spsc.isEmpty
    check not spsc.isFull
    check spsc.peek().isNone
    check spsc.pop().isNone

    for i in 1 .. 8:
      check spsc.tryPush(i * 10)
      check spsc.len == i
    check spsc.isFull
    check not spsc.isEmpty
    # Negative control: pushing past Cap returns false
    check not spsc.tryPush(999)
    check spsc.len == 8
    check spsc.peek() == some(80)

    for i in countdown(8, 1):
      check spsc.peek() == some(i * 10)
      check spsc.pop() == some(i * 10)
      check spsc.len == i - 1

    check spsc.isEmpty
    check spsc.pop().isNone

    # Verify MPSC, SPMC, MPMC aliases and slot recycling after full drain
    var mpsc = initMpscBStack[int, 4]()
    var spmc = initSpmcBStack[int, 4]()
    var mpmc = initMpmcBStack[int, 4]()
    for i in 0 ..< 4:
      check mpsc.push(i + 1)
      check spmc.push(i + 10)
      check mpmc.push(i + 100)
    check not mpsc.push(99)
    check not spmc.push(99)
    check not mpmc.push(99)
    check mpsc.drain() == @[4, 3, 2, 1]
    check spmc.drain() == @[13, 12, 11, 10]
    check mpmc.drain() == @[103, 102, 101, 100]
    check mpsc.isEmpty
    check spmc.isEmpty
    check mpmc.isEmpty

  test "BStack ARC/ORC string payload lifecycle, drain, and clear reuse":
    var st = initBStack[string, 16]()
    for round in 0 ..< 10:
      for i in 0 ..< 16:
        check st.tryPush("payload-" & $round & "-" & $i)
      check st.isFull
      check not st.tryPush("overflow")
      if round mod 2 == 0:
        let items = st.drain()
        check items.len == 16
        check items[0] == "payload-" & $round & "-15"
        check items[15] == "payload-" & $round & "-0"
      else:
        st.clear()
      check st.isEmpty
      check st.len == 0

  when compileOption("threads"):
    test "BStack 8-thread MPMC push/pop/peek contention conservation":
      const
        NumProducers = 4
        NumConsumers = 4
        ItemsPerProducer = 2_000
        TotalItems = NumProducers * ItemsPerProducer

      type
        StackWorkerCtx = object
          stack: ptr MpmcBStack[int, 128]
          tid: int
          pushedSum: ptr Atomic[int64]
          poppedSum: ptr Atomic[int64]
          poppedCount: ptr Atomic[int]
          peekValidCount: ptr Atomic[int]

      var st = initMpmcBStack[int, 128]()
      var pushedSum: Atomic[int64]
      var poppedSum: Atomic[int64]
      var poppedCount: Atomic[int]
      var peekValidCount: Atomic[int]
      pushedSum.store(0, moRelaxed)
      poppedSum.store(0, moRelaxed)
      poppedCount.store(0, moRelaxed)
      peekValidCount.store(0, moRelaxed)

      proc producerProc(ctx: StackWorkerCtx) {.thread.} =
        let base = ctx.tid * ItemsPerProducer
        var localSum = 0'i64
        for i in 1 .. ItemsPerProducer:
          let v = base + i
          while not ctx.stack[].tryPush(v):
            cpuPause()
          localSum += int64(v)
        discard ctx.pushedSum[].fetchAdd(localSum, moAcquireRelease)

      proc consumerProc(ctx: StackWorkerCtx) {.thread.} =
        var localSum = 0'i64
        var iter = 0
        while ctx.poppedCount[].load(moAcquire) < TotalItems:
          if (iter and 7) == 0:
            let pk = ctx.stack[].peek()
            if pk.isSome:
              doAssert pk.get() >= 1 and pk.get() <= TotalItems
              discard ctx.peekValidCount[].fetchAdd(1, moRelaxed)
          var v = 0
          if ctx.stack[].tryPop(v):
            doAssert v >= 1 and v <= TotalItems
            localSum += int64(v)
            discard ctx.poppedCount[].fetchAdd(1, moAcquireRelease)
          else:
            cpuPause()
          inc iter
        discard ctx.poppedSum[].fetchAdd(localSum, moAcquireRelease)

      var prodThreads: array[NumProducers, Thread[StackWorkerCtx]]
      var consThreads: array[NumConsumers, Thread[StackWorkerCtx]]
      for i in 0 ..< NumProducers:
        createThread(
          prodThreads[i],
          producerProc,
          StackWorkerCtx(
            stack: addr st,
            tid: i,
            pushedSum: addr pushedSum,
            poppedSum: addr poppedSum,
            poppedCount: addr poppedCount,
            peekValidCount: addr peekValidCount
          )
        )
      for i in 0 ..< NumConsumers:
        createThread(
          consThreads[i],
          consumerProc,
          StackWorkerCtx(
            stack: addr st,
            tid: i,
            pushedSum: addr pushedSum,
            poppedSum: addr poppedSum,
            poppedCount: addr poppedCount,
            peekValidCount: addr peekValidCount
          )
        )
      for i in 0 ..< NumProducers:
        joinThread(prodThreads[i])
      for i in 0 ..< NumConsumers:
        joinThread(consThreads[i])

      let expectedSum = (int64(TotalItems) * int64(TotalItems + 1)) div 2
      check poppedCount.load(moAcquire) == TotalItems
      check pushedSum.load(moAcquire) == expectedSum
      check poppedSum.load(moAcquire) == expectedSum
      check st.isEmpty

suite "BPriorityQueue (Bounded Zero-SMR Binary Min-Heap Priority Queue)":
  test "Min-heap ordering, strict FIFO seqId tie-breaking, and capacity enforcement":
    var pq = initBPriorityQueue[Prioritized[int, string], 8]()
    check pq.capacity == 8
    check pq.len == 0
    check pq.isEmpty
    check not pq.isFull
    check pq.peekMin().isNone
    check pq.popMin().isNone

    check pq.tryPush(Prioritized[int, string](priority: 30, value: "thirty-A"))
    check pq.tryPush(Prioritized[int, string](priority: 10, value: "ten-A"))
    check pq.tryPush(Prioritized[int, string](priority: 20, value: "twenty-A"))
    check pq.tryPush(Prioritized[int, string](priority: 10, value: "ten-B"))
    check pq.tryPush(Prioritized[int, string](priority: 10, value: "ten-C"))
    check pq.tryPush(Prioritized[int, string](priority: 5, value: "five"))
    check pq.tryPush(Prioritized[int, string](priority: 20, value: "twenty-B"))
    check pq.tryPush(Prioritized[int, string](priority: 30, value: "thirty-B"))
    check pq.isFull
    check pq.len == 8
    # Negative control: capacity exceeded
    check not pq.tryPush(Prioritized[int, string](priority: 1, value: "overflow"))

    check pq.peekMin() == some(Prioritized[int, string](priority: 5, value: "five"))

    var poppedValues: seq[string] = @[]
    var item: Prioritized[int, string]
    while pq.tryPopMin(item):
      poppedValues.add(item.value)

    check poppedValues == @[
      "five",
      "ten-A",
      "ten-B",
      "ten-C",
      "twenty-A",
      "twenty-B",
      "thirty-A",
      "thirty-B"
    ]
    check pq.isEmpty
    check pq.len == 0

  test "SPSC, MPSC, SPMC, MPMC BPriorityQueue topology aliases and clear":
    var spsc = initSpscBPriorityQueue[int, 4]()
    var mpsc = initMpscBPriorityQueue[int, 4]()
    var spmc = initSpmcBPriorityQueue[int, 4]()
    var mpmc = initMpmcBPriorityQueue[int, 4]()
    for v in [40, 10, 30, 20]:
      check spsc.push(v)
      check mpsc.push(v)
      check spmc.push(v)
      check mpmc.push(v)
    check not spsc.push(5)
    check spsc.popMin() == some(10)
    check spsc.popMin() == some(20)
    spsc.clear()
    mpsc.clear()
    spmc.clear()
    mpmc.clear()
    check spsc.isEmpty
    check mpsc.isEmpty
    check spmc.isEmpty
    check mpmc.isEmpty

  when compileOption("threads"):
    test "BPriorityQueue 8-thread MPMC producer/consumer contention":
      const
        NumProducers = 4
        NumConsumers = 4
        ItemsPerProducer = 1_500
        TotalItems = NumProducers * ItemsPerProducer

      type
        PQWorkerCtx = object
          pq: ptr MpmcBPriorityQueue[int, 256]
          tid: int
          pushedSum: ptr Atomic[int64]
          poppedSum: ptr Atomic[int64]
          poppedCount: ptr Atomic[int]

      var pq = initMpmcBPriorityQueue[int, 256]()
      var pushedSum: Atomic[int64]
      var poppedSum: Atomic[int64]
      var poppedCount: Atomic[int]
      pushedSum.store(0, moRelaxed)
      poppedSum.store(0, moRelaxed)
      poppedCount.store(0, moRelaxed)

      proc pqProducer(ctx: PQWorkerCtx) {.thread.} =
        let base = ctx.tid * ItemsPerProducer
        var localSum = 0'i64
        for i in 1 .. ItemsPerProducer:
          let v = base + i
          while not ctx.pq[].tryPush(v):
            cpuPause()
          localSum += int64(v)
        discard ctx.pushedSum[].fetchAdd(localSum, moAcquireRelease)

      proc pqConsumer(ctx: PQWorkerCtx) {.thread.} =
        var localSum = 0'i64
        while ctx.poppedCount[].load(moAcquire) < TotalItems:
          var v = 0
          if ctx.pq[].tryPopMin(v):
            doAssert v >= 1 and v <= TotalItems
            localSum += int64(v)
            discard ctx.poppedCount[].fetchAdd(1, moAcquireRelease)
          else:
            cpuPause()
        discard ctx.poppedSum[].fetchAdd(localSum, moAcquireRelease)

      var prodThreads: array[NumProducers, Thread[PQWorkerCtx]]
      var consThreads: array[NumConsumers, Thread[PQWorkerCtx]]
      for i in 0 ..< NumProducers:
        createThread(
          prodThreads[i],
          pqProducer,
          PQWorkerCtx(
            pq: addr pq,
            tid: i,
            pushedSum: addr pushedSum,
            poppedSum: addr poppedSum,
            poppedCount: addr poppedCount
          )
        )
      for i in 0 ..< NumConsumers:
        createThread(
          consThreads[i],
          pqConsumer,
          PQWorkerCtx(
            pq: addr pq,
            tid: i,
            pushedSum: addr pushedSum,
            poppedSum: addr poppedSum,
            poppedCount: addr poppedCount
          )
        )
      for i in 0 ..< NumProducers:
        joinThread(prodThreads[i])
      for i in 0 ..< NumConsumers:
        joinThread(consThreads[i])

      let expectedSum = (int64(TotalItems) * int64(TotalItems + 1)) div 2
      check poppedCount.load(moAcquire) == TotalItems
      check pushedSum.load(moAcquire) == expectedSum
      check poppedSum.load(moAcquire) == expectedSum
      check pq.isEmpty

suite "BTable (Bounded Zero-SMR Concurrent Open-Addressing Hash Table)":
  test "CRUD operations, strict capacity enforcement, and associative modifiers":
    var tbl = initBTable[string, int, 8]()
    check tbl.capacity == 8
    check tbl.probeCapacity == 16
    check tbl.len == 0
    check tbl.isEmpty
    check not tbl.isFull

    for i in 1 .. 8:
      check tbl.tryInsert("k" & $i, i * 10)
    check tbl.len == 8
    check tbl.isFull
    # Duplicate insert returns false without overwriting
    check not tbl.tryInsert("k1", 999)
    check tbl.get("k1") == some(10)
    # New key beyond Cap returns false
    check not tbl.tryPut("k9", 90)
    check not tbl.tryInsert("k9", 90)
    # Updating an existing key when full succeeds!
    check tbl.tryPut("k1", 111)
    check tbl.get("k1") == some(111)
    check tbl.len == 8

    # computeIfAbsent, atomicUpdate, upsert, take, remove
    check tbl.computeIfAbsent("k2", proc(): int {.gcsafe.} = 777) == 20
    check tbl.atomicUpdate("k2", proc(v: int): int {.gcsafe.} = v + 5) == some(25)
    check tbl.atomicUpdate("missing", proc(v: int): int {.gcsafe.} = v + 5) == none(int)
    check tbl.take("k2") == some(25)
    check not tbl.contains("k2")
    check tbl.len == 7
    check tbl.upsert("k2", 200, proc(v: int): int {.gcsafe.} = v + 1) == 200
    check tbl.upsert("k2", 200, proc(v: int): int {.gcsafe.} = v + 1) == 201
    check tbl.remove("k2")
    check not tbl.remove("k2")
    check tbl.len == 7

    let snap = tbl.snapshotPairs()
    check snap.len == 7
    tbl.clear()
    check tbl.isEmpty
    check tbl.len == 0

  test "Tombstone-reuse probe invariant without duplicate keys across 20 full churn cycles":
    var tbl = initBTable[int, string, 8]()
    # Churn 20 full cycles of 8 keys (160 distinct insertions into 16 probe slots)
    for cycle in 0 ..< 20:
      let base = cycle * 100
      for i in 0 ..< 8:
        check tbl.tryPut(base + i, "val-" & $cycle & "-" & $i)
      check tbl.len == 8
      check tbl.isFull
      for i in 0 ..< 8:
        check tbl.get(base + i) == some("val-" & $cycle & "-" & $i)
      for i in 0 ..< 8:
        check tbl.remove(base + i)
      check tbl.isEmpty
      check tbl.len == 0

    # Verify in-place update behind an earlier tombstone (no duplicate keys!)
    for i in 1 .. 8:
      check tbl.tryPut(i, "init-" & $i)
    for i in 1 .. 7:
      check tbl.remove(i)
    check tbl.len == 1
    check tbl.tryPut(8, "updated-8")
    check tbl.len == 1
    check tbl.get(8) == some("updated-8")
    check tbl.snapshotPairs() == @[(8, "updated-8")]

  when compileOption("threads"):
    test "BTable 8-thread MPMC concurrent put/get/remove/atomicUpdate contention":
      const
        NumThreads = 8
        OpsPerThread = 1_000

      type
        TableWorkerCtx = object
          tbl: ptr MpmcBTable[int, int, 64]
          tid: int

      var tbl = initMpmcBTable[int, int, 64]()
      for k in 0 ..< 32:
        check tbl.tryPut(k, 0)

      proc tableWorker(ctx: TableWorkerCtx) {.thread.} =
        for step in 0 ..< OpsPerThread:
          let steadyKey = (ctx.tid * 4) + (step and 3)
          discard ctx.tbl[].atomicUpdate(
            steadyKey,
            proc(v: int): int {.gcsafe.} = v + 1
          )
          var outVal = 0
          doAssert ctx.tbl[].tryGet(steadyKey, outVal)
          doAssert outVal >= 1

          # Churn dynamic keys in 100 ..< 132
          let churnKey = 100 + ctx.tid * 4 + (step and 3)
          discard ctx.tbl[].tryPut(churnKey, step)
          discard ctx.tbl[].get(churnKey)
          if (step and 1) == 1:
            discard ctx.tbl[].remove(churnKey)

      var threads: array[NumThreads, Thread[TableWorkerCtx]]
      for i in 0 ..< NumThreads:
        createThread(threads[i], tableWorker, TableWorkerCtx(tbl: addr tbl, tid: i))
      for i in 0 ..< NumThreads:
        joinThread(threads[i])

      # Every steadyKey in 0 ..< 32 was incremented exactly OpsPerThread div 4 = 250 times
      for k in 0 ..< 32:
        check tbl.get(k) == some(OpsPerThread div 4)

suite "Zero-Allocation & ARC/ORC Destructor Tracking (BStack, BPriorityQueue, BTable)":
  test "Steady-state hot-path operations allocate zero heap memory":
    var st = initBStack[int, 64]()
    var pq = initBPriorityQueue[int, 64]()
    var tbl = initBTable[int, int, 64]()

    # Warmup pass
    for i in 0 ..< 64:
      check st.tryPush(i)
      check pq.tryPush(i)
      check tbl.tryPut(i, i * 2)
    var outInt = 0
    for i in 0 ..< 64:
      check st.tryPop(outInt)
      check pq.tryPopMin(outInt)
      check tbl.remove(i)

    when declared(getOccupiedMem):
      let occupiedBefore = getOccupiedMem()
    for iter in 0 ..< 5_000:
      let k = iter and 63
      check st.tryPush(iter)
      check st.tryPop(outInt)
      check outInt == iter

      check pq.tryPush(iter)
      check pq.tryPopMin(outInt)
      check outInt == iter

      check tbl.tryPut(k, iter)
      check tbl.tryGet(k, outInt)
      check outInt == iter
      check tbl.remove(k)
    when declared(getOccupiedMem):
      let occupiedAfter = getOccupiedMem()
      check occupiedAfter <= occupiedBefore

  test "Deterministic ARC/ORC =destroy invocation across push/pop/remove/clear":
    gTrackedLiveCount.store(0, moRelaxed)
    gTrackedDestroyCount.store(0, moRelaxed)

    block:
      var st = initBStack[TrackedPayload, 8]()
      for i in 1 .. 8:
        check st.tryPush(makeTracked(i))
      check gTrackedLiveCount.load(moAcquire) == 8
      for i in 1 .. 4:
        var popped: TrackedPayload
        check st.tryPop(popped)
      check gTrackedLiveCount.load(moAcquire) == 4
      st.clear()
      check gTrackedLiveCount.load(moAcquire) == 0

      var pq = initBPriorityQueue[TrackedPayload, 8]()
      for i in 1 .. 8:
        check pq.tryPush(makeTracked(100 + i))
      check gTrackedLiveCount.load(moAcquire) == 8
      for i in 1 .. 4:
        var popped: TrackedPayload
        check pq.tryPopMin(popped)
      check gTrackedLiveCount.load(moAcquire) == 4
      pq.clear()
      check gTrackedLiveCount.load(moAcquire) == 0

      var tbl = initBTable[int, TrackedPayload, 8]()
      for i in 1 .. 8:
        check tbl.tryPut(i, makeTracked(200 + i))
      check gTrackedLiveCount.load(moAcquire) == 8
      # Overwrite existing entries: old TrackedPayload values must be destroyed
      for i in 1 .. 4:
        check tbl.tryPut(i, makeTracked(300 + i))
      check gTrackedLiveCount.load(moAcquire) == 8
      for i in 1 .. 4:
        check tbl.remove(i)
      check gTrackedLiveCount.load(moAcquire) == 4
      tbl.clear()
      check gTrackedLiveCount.load(moAcquire) == 0

    check gTrackedLiveCount.load(moAcquire) == 0
    check gTrackedDestroyCount.load(moAcquire) >= 28
