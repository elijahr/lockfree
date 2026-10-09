## ==============================================================================
## Tests for TaskPool (Work-Stealing Task Scheduler)
## ==============================================================================

import unittest2
import std/options
import std/os
import lockfree/atomics
import lockfree/taskpool

suite "TaskPool - Basic Lifecycle & Ergonomics":
  test "Initialization, numWorkers, and properties":
    var pool = initTaskPool(4)
    check not pool.isNil
    check pool.numWorkers == 4
    check pool.len == 0
    pool.shutdown(wait = true)

  test "Default thread count fallback":
    var pool = initTaskPool(0)
    check not pool.isNil
    check pool.numWorkers >= 1
    pool.shutdown(wait = true)

  test "Ergonomic aliases":
    var pool1: ThreadPool = initThreadPool(2)
    check pool1.numWorkers == 2
    pool1.shutdown(wait = true)

    var pool2: ConcurrentTaskPool = initConcurrentTaskPool(2)
    check pool2.numWorkers == 2
    pool2.shutdown(wait = true)

suite "TaskPool - Task Spawning":
  test "Closure tasks with atomic counter":
    var pool = initTaskPool(4)
    var counter: Atomic[int64]
    counter.store(0, moRelaxed)

    const TotalTasks = 1000
    for i in 0 ..< TotalTasks:
      pool.spawn(proc() =
        discard counter.fetchAdd(1'i64, moRelaxed)
      )

    pool.sync()
    check counter.load(moAcquire) == TotalTasks
    pool.shutdown(wait = true)

  test "Nimcall function pointer tasks":
    var pool = initTaskPool(4)
    var counter: Atomic[int64]
    counter.store(0, moRelaxed)

    proc incNimcall(arg: pointer) {.nimcall, gcsafe.} =
      let p = cast[ptr Atomic[int64]](arg)
      discard p[].fetchAdd(10'i64, moRelaxed)

    const TotalTasks = 100
    for i in 0 ..< TotalTasks:
      pool.spawn(incNimcall, cast[pointer](addr counter))

    pool.sync()
    check counter.load(moAcquire) == TotalTasks * 10
    pool.shutdown(wait = true)

  test "C-ABI cdecl function pointer tasks":
    var pool = initTaskPool(4)
    var counter: Atomic[int64]
    counter.store(0, moRelaxed)

    proc incCdecl(arg: pointer) {.cdecl, gcsafe.} =
      let p = cast[ptr Atomic[int64]](arg)
      discard p[].fetchAdd(5'i64, moRelaxed)

    const TotalTasks = 100
    for i in 0 ..< TotalTasks:
      pool.spawn(incCdecl, cast[pointer](addr counter))

    pool.sync()
    check counter.load(moAcquire) == TotalTasks * 5
    pool.shutdown(wait = true)

suite "TaskPool - forkJoin":
  test "Two-way forkJoin":
    var pool = initTaskPool(4)
    var leftDone: Atomic[bool]
    var rightDone: Atomic[bool]
    leftDone.store(false, moRelaxed)
    rightDone.store(false, moRelaxed)

    pool.forkJoin(
      proc() =
        sleep(10)
        leftDone.store(true, moRelease),
      proc() =
        sleep(10)
        rightDone.store(true, moRelease)
    )

    check leftDone.load(moAcquire) == true
    check rightDone.load(moAcquire) == true
    pool.shutdown(wait = true)

  test "Multi-way forkJoin":
    var pool = initTaskPool(4)
    var counter: Atomic[int]
    counter.store(0, moRelaxed)

    var tasks: seq[proc() {.closure, gcsafe.}] = @[]
    for i in 0 ..< 8:
      tasks.add(proc() =
        discard counter.fetchAdd(1, moRelaxed)
      )

    pool.forkJoin(tasks)
    check counter.load(moAcquire) == 8
    pool.shutdown(wait = true)

  test "Recursive divide-and-conquer parallel sum":
    var pool = initTaskPool(4)
    const N = 1024
    var data = newSeq[int](N)
    for i in 0 ..< N:
      data[i] = i + 1

    proc parallelSum(p: TaskPool, d: ptr UncheckedArray[int], low, high: int): int {.gcsafe.} =
      if high - low <= 64:
        var s = 0
        for i in low .. high:
          s += d[i]
        return s
      let mid = low + (high - low) div 2
      var leftSum = 0
      var rightSum = 0
      p.forkJoin(
        proc() {.closure, gcsafe.} =
          leftSum = parallelSum(p, d, low, mid),
        proc() {.closure, gcsafe.} =
          rightSum = parallelSum(p, d, mid + 1, high)
      )
      return leftSum + rightSum

    let arrPtr = cast[ptr UncheckedArray[int]](addr data[0])
    let total = parallelSum(pool, arrPtr, 0, N - 1)
    let expected = (N * (N + 1)) div 2
    check total == expected
    pool.shutdown(wait = true)

suite "TaskPool - parallelFor":
  test "Closure parallelFor with inclusive range":
    var pool = initTaskPool(4)
    const N = 5000
    var results = newSeq[int](N)
    let resPtr = cast[ptr UncheckedArray[int]](addr results[0])

    pool.parallelFor(0, N - 1, proc(i: int) =
      resPtr[i] = (i + 1) * 2
    )

    for i in 0 ..< N:
      check results[i] == (i + 1) * 2
    pool.shutdown(wait = true)

  test "Closure parallelFor with slice and custom chunk size":
    var pool = initTaskPool(4)
    const N = 2000
    var results = newSeq[int](N)
    let resPtr = cast[ptr UncheckedArray[int]](addr results[0])

    pool.parallelFor(0 .. (N - 1), proc(i: int) =
      resPtr[i] = i * i
    , chunkSize = 16)

    for i in 0 ..< N:
      check results[i] == i * i
    pool.shutdown(wait = true)

  test "C-ABI parallelFor with pointer arg":
    var pool = initTaskPool(4)
    const N = 1000
    var results = newSeq[int](N)

    type Context = object
      arr: ptr UncheckedArray[int]

    var ctx = Context(arr: cast[ptr UncheckedArray[int]](addr results[0]))

    proc cdeclLoop(idx: int, arg: pointer) {.cdecl, gcsafe.} =
      let c = cast[ptr Context](arg)
      c.arr[idx] = idx + 100

    pool.parallelFor(0, N - 1, cdeclLoop, cast[pointer](addr ctx))

    for i in 0 ..< N:
      check results[i] == i + 100
    pool.shutdown(wait = true)

suite "TaskPool - Concurrency & Graceful Teardown":
  test "Concurrent producers submitting tasks simultaneously":
    var pool = initTaskPool(4)
    var totalExecuted: Atomic[int64]
    totalExecuted.store(0, moRelaxed)

    const NumThreads = 4
    const TasksPerThread = 500

    type ProducerArg = object
      p: TaskPool
      outCount: ptr Atomic[int64]

    var threads: array[NumThreads, Thread[ProducerArg]]

    proc producerThread(arg: ProducerArg) {.thread.} =
      for i in 0 ..< TasksPerThread:
        arg.p.spawn(proc() =
          discard arg.outCount[].fetchAdd(1'i64, moRelaxed)
        )

    for i in 0 ..< NumThreads:
      createThread(threads[i], producerThread, ProducerArg(p: pool, outCount: addr totalExecuted))

    for i in 0 ..< NumThreads:
      joinThread(threads[i])

    pool.sync()
    check totalExecuted.load(moAcquire) == int64(NumThreads * TasksPerThread)
    pool.shutdown(wait = true)

  test "Graceful shutdown with pending tasks in queue":
    var pool = initTaskPool(4)
    var counter: Atomic[int]
    counter.store(0, moRelaxed)

    for i in 0 ..< 100:
      pool.spawn(proc() =
        sleep(1)
        discard counter.fetchAdd(1, moRelaxed)
      )

    # Calling shutdown(wait = true) should drain all tasks before exit
    pool.shutdown(wait = true)
    check counter.load(moAcquire) == 100

suite "TaskPool - Adversarial HIGH-02 Closure Lifetime":
  test "Synchronized closure tasks with captured heap objects":
    var pool = initTaskPool(4)
    var sum: Atomic[int64]
    sum.store(0, moRelaxed)

    proc spawnSynchronized(p: TaskPool, outVal: ptr Atomic[int64], id: int) =
      let capturedPayload = "payload_" & $id & "_extra_string_data_to_force_heap_allocation"
      let capturedData = (id: id, extra: "extra_" & $id)
      p.spawn(proc() =
        let val = capturedPayload.len.int64 + capturedData.extra.len.int64
        discard outVal[].fetchAdd(val, moRelaxed)
      )
      p.sync()

    const Total = 100
    for i in 0 ..< Total:
      spawnSynchronized(pool, addr sum, i)

    check sum.load(moAcquire) > 0
    pool.shutdown(wait = true)

  test "Detached task execution with shared memory via TaskProc":
    var pool = initTaskPool(4)
    var sum: Atomic[int64]
    sum.store(0, moRelaxed)

    type TaskPayload = object
      outVal: ptr Atomic[int64]
      len1: int64
      len2: int64

    proc payloadWorker(arg: pointer) {.nimcall, gcsafe.} =
      let p = cast[ptr TaskPayload](arg)
      discard p.outVal[].fetchAdd(p.len1 + p.len2, moRelaxed)
      deallocShared(p)

    const Total = 100
    for i in 0 ..< Total:
      let p = cast[ptr TaskPayload](allocShared0(sizeof(TaskPayload)))
      p.outVal = addr sum
      p.len1 = int64(10 + i)
      p.len2 = int64(20 + i)
      pool.spawn(payloadWorker, cast[pointer](p))

    pool.sync()
    check sum.load(moAcquire) > 0
    pool.shutdown(wait = true)
