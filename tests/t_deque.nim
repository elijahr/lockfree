## Tests for ChaseLevDeque[T] (Single-Worker / Multi-Thief work-stealing deque).
## Covers:
##   - Single-threaded worker LIFO operations (pushBottom / popBottom)
##   - Single-threaded thief FIFO operations (steal / stealBatch)
##   - Dynamic buffer growth and retired-buffer safety
##   - Bulk stealBatch (in-place array and allocated seq)
##   - Managed types under ARC/ORC (ref types with destructor tracking, string, seq)
##   - Concurrent multi-thief stress testing
##   - Concurrent multi-thief bulk stealBatch stress testing
##   - Contention race on last element (CAS arbitration)
##   - Ergonomic aliases (Deque[T], ConcurrentDeque[T], initDeque, initConcurrentDeque)

import unittest2
import std/[options, os]
import lockfree/deque
import lockfree/atomics
import lockfree/atomics/backoff

suite "ChaseLevDeque — Worker LIFO Lifecycle":
  test "empty state and basic push/pop":
    let d = initChaseLevDeque[int](16)
    check d.isEmpty
    check d.len == 0
    check d.capacity >= 16

    var dummy: int
    check not d.tryPopBottom(dummy)
    check d.popBottom().isNone
    check d.steal().isNone
    check d.stealBatch(2).len == 0

    d.pushBottom(42)
    check not d.isEmpty
    check d.len == 1

    let popped = d.popBottom()
    check popped.isSome
    check popped.get() == 42
    check d.isEmpty
    check d.len == 0

  test "LIFO ordering on multiple pushes":
    let d = initChaseLevDeque[int](16)
    for i in 1 .. 10:
      d.pushBottom(i)
    check d.len == 10

    # Pop should return 10 down to 1 (LIFO / stack order)
    for expected in countdown(10, 1):
      let val = d.popBottom()
      check val.isSome
      check val.get() == expected

    check d.isEmpty

  test "interleaved worker push and pop":
    let d = initChaseLevDeque[int](16)
    d.pushBottom(10)
    d.pushBottom(20)
    check d.popBottom().get() == 20
    d.pushBottom(30)
    check d.popBottom().get() == 30
    check d.popBottom().get() == 10
    check d.isEmpty

suite "ChaseLevDeque — Thief FIFO Lifecycle":
  test "FIFO ordering on single steals":
    let d = initChaseLevDeque[int](16)
    for i in 1 .. 5:
      d.pushBottom(i)

    # Thieves steal from top (FIFO / queue order: 1, 2, 3, 4, 5)
    for expected in 1 .. 5:
      let val = d.steal()
      check val.isSome
      check val.get() == expected

    check d.isEmpty
    check d.steal().isNone

  test "interleaved worker popBottom and thief steal":
    let d = initChaseLevDeque[int](16)
    d.pushBottom(1)
    d.pushBottom(2)
    d.pushBottom(3)
    d.pushBottom(4)

    # Thief steals oldest from top (1)
    check d.steal().get() == 1
    # Worker pops newest from bottom (4)
    check d.popBottom().get() == 4
    # Thief steals next oldest (2)
    check d.steal().get() == 2
    # Worker pops remaining (3)
    check d.popBottom().get() == 3

    check d.isEmpty
    check d.popBottom().isNone
    check d.steal().isNone

suite "ChaseLevDeque — Dynamic Buffer Resizing":
  test "automatic buffer expansion under heavy push":
    let d = initChaseLevDeque[int](16)
    check d.capacity == 16

    # Push 500 items, forcing multiple doublings: 16 -> 32 -> 64 -> 128 -> 256 -> 512
    for i in 1 .. 500:
      d.pushBottom(i)

    check d.capacity >= 512
    check d.len == 500

    # Steal first 250 items (FIFO: 1 .. 250)
    for expected in 1 .. 250:
      let s = d.steal()
      check s.isSome
      check s.get() == expected

    # Pop remaining 250 items (LIFO: 500 down to 251)
    for expected in countdown(500, 251):
      let p = d.popBottom()
      check p.isSome
      check p.get() == expected

    check d.isEmpty

suite "ChaseLevDeque — Bulk stealBatch":
  test "stealBatch with openArray destination":
    let d = initChaseLevDeque[int](32)
    for i in 0 ..< 10:
      d.pushBottom(i)

    var batch: array[4, int]
    let stolen = d.stealBatch(batch, maxItems = 4)
    check stolen == 4
    check batch[0] == 0
    check batch[1] == 1
    check batch[2] == 2
    check batch[3] == 3
    check d.len == 6

    # Steal half of remaining (default maxItems = -1 => (6+1) div 2 = 3)
    var batch2: array[10, int]
    let stolen2 = d.stealBatch(batch2)
    check stolen2 == 3
    check batch2[0] == 4
    check batch2[1] == 5
    check batch2[2] == 6
    check d.len == 3

    # Worker pops remaining 3 (LIFO: 9, 8, 7)
    check d.popBottom().get() == 9
    check d.popBottom().get() == 8
    check d.popBottom().get() == 7
    check d.isEmpty

  test "stealBatch returning seq[T]":
    let d = initChaseLevDeque[int](32)
    for i in 1 .. 8:
      d.pushBottom(i)

    let stolen = d.stealBatch(maxItems = 3)
    check stolen.len == 3
    check stolen == @[1, 2, 3]

    let stolen2 = d.stealBatch(maxItems = -1) # half of 5 = (5+1) div 2 = 3
    check stolen2.len == 3
    check stolen2 == @[4, 5, 6]

    let stolen3 = d.stealBatch(maxItems = 10) # request 10, only 2 left
    check stolen3.len == 2
    check stolen3 == @[7, 8]

    check d.isEmpty
    check d.stealBatch(5).len == 0

suite "ChaseLevDeque — Ergonomic Aliases":
  test "Deque and ConcurrentDeque aliases":
    var q1: Deque[int] = initDeque[int](16)
    var q2: ConcurrentDeque[string] = initConcurrentDeque[string](16)

    q1.pushBottom(100)
    check q1.popBottom().get() == 100

    q2.pushBottom("chase-lev")
    check q2.steal().get() == "chase-lev"

suite "ChaseLevDeque — ARC/ORC Managed Types":
  type TrackedObj = ref object
    id: int

  var gDestructCount {.global.}: Atomic[int]

  proc `=destroy`(x: var typeof(TrackedObj()[])) =
    if x.id > 0:
      discard gDestructCount.fetchAdd(1, moRelaxed)

  test "ref types correctly retain and balance refcounts":
    gDestructCount.store(0, moRelaxed)
    block:
      let d = initChaseLevDeque[TrackedObj](16)
      for i in 1 .. 50:
        d.pushBottom(TrackedObj(id: i))

      # Pop 20 from bottom
      for _ in 1 .. 20:
        let obj = d.popBottom()
        check obj.isSome
        check obj.get().id > 0

      # Steal 20 from top
      for _ in 1 .. 20:
        let obj = d.steal()
        check obj.isSome
        check obj.get().id > 0

      # 10 remaining in deque when block ends and deque is destroyed
      check d.len == 10

    # Total 50 objects created; when popped/stolen items leave scope and deque is destroyed,
    # all 50 MUST be destroyed without leaks.
    check gDestructCount.load(moRelaxed) == 50

  test "strings and seqs":
    let d = initChaseLevDeque[string](16)
    d.pushBottom("alpha")
    d.pushBottom("beta")
    d.pushBottom("gamma")

    check d.steal().get() == "alpha"
    check d.popBottom().get() == "gamma"
    check d.popBottom().get() == "beta"
    check d.isEmpty

suite "ChaseLevDeque — Concurrent Multi-Thief Stress Tests":
  type
    StressContext = object
      deque: ChaseLevDeque[int]
      totalItems: int
      poppedOrStolen: ptr array[10000, Atomic[int]]
      workerCount: int
      thiefCount: int
      stopFlag: Atomic[bool]

  proc thiefWorker(ctx: ptr StressContext) {.thread.} =
    var stolen = 0
    while true:
      let res = ctx.deque.steal()
      if res.isSome:
        let val = res.get()
        if val >= 0 and val < ctx.totalItems:
          discard ctx.poppedOrStolen[val].fetchAdd(1, moRelaxed)
          inc stolen
      else:
        if ctx.stopFlag.load(moAcquire):
          while true:
            let leftover = ctx.deque.steal()
            if leftover.isSome:
              let val = leftover.get()
              if val >= 0 and val < ctx.totalItems:
                discard ctx.poppedOrStolen[val].fetchAdd(1, moRelaxed)
                inc stolen
            else:
              break
          break
        sleep(0)

  test "1 Worker pushing 10,000 items with 4 concurrent thieves":
    const Total = 10000
    var poppedOrStolen: array[Total, Atomic[int]]
    for i in 0 ..< Total:
      poppedOrStolen[i].store(0, moRelaxed)

    let deque = initChaseLevDeque[int](64)
    var ctx = StressContext(
      deque: deque,
      totalItems: Total,
      poppedOrStolen: addr poppedOrStolen,
      workerCount: 1,
      thiefCount: 4
    )
    ctx.stopFlag.store(false, moRelaxed)

    var thiefThreads: array[4, Thread[ptr StressContext]]
    for i in 0 ..< 4:
      createThread(thiefThreads[i], thiefWorker, addr ctx)

    # Worker thread pushes and occasionally pops
    for i in 0 ..< Total:
      deque.pushBottom(i)
      if i mod 7 == 0:
        let popped = deque.popBottom()
        if popped.isSome:
          let val = popped.get()
          discard poppedOrStolen[val].fetchAdd(1, moRelaxed)

    # Drain any leftovers from worker side
    while true:
      let p = deque.popBottom()
      if p.isSome:
        discard poppedOrStolen[p.get()].fetchAdd(1, moRelaxed)
      else:
        break

    # Signal thieves to stop
    ctx.stopFlag.store(true, moRelease)

    # Join thieves
    for i in 0 ..< 4:
      joinThread(thiefThreads[i])

    # Verification: every single item was processed EXACTLY once
    for i in 0 ..< Total:
      check poppedOrStolen[i].load(moRelaxed) == 1

  proc batchThiefWorker(ctx: ptr StressContext) {.thread.} =
    var buf: array[16, int]
    while true:
      let count = ctx.deque.stealBatch(buf, maxItems = 8)
      if count > 0:
        for i in 0 ..< count:
          let val = buf[i]
          if val >= 0 and val < ctx.totalItems:
            discard ctx.poppedOrStolen[val].fetchAdd(1, moRelaxed)
      else:
        if ctx.stopFlag.load(moAcquire):
          while true:
            let rem = ctx.deque.stealBatch(buf, maxItems = 8)
            if rem > 0:
              for i in 0 ..< rem:
                let val = buf[i]
                if val >= 0 and val < ctx.totalItems:
                  discard ctx.poppedOrStolen[val].fetchAdd(1, moRelaxed)
            else:
              break
          break
        sleep(0)

  test "1 Worker with 4 concurrent batch thieves":
    const Total = 10000
    var poppedOrStolen: array[Total, Atomic[int]]
    for i in 0 ..< Total:
      poppedOrStolen[i].store(0, moRelaxed)

    let deque = initChaseLevDeque[int](64)
    var ctx = StressContext(
      deque: deque,
      totalItems: Total,
      poppedOrStolen: addr poppedOrStolen,
      workerCount: 1,
      thiefCount: 4
    )
    ctx.stopFlag.store(false, moRelaxed)

    var thiefThreads: array[4, Thread[ptr StressContext]]
    for i in 0 ..< 4:
      createThread(thiefThreads[i], batchThiefWorker, addr ctx)

    for i in 0 ..< Total:
      deque.pushBottom(i)
      if i mod 5 == 0:
        let p = deque.popBottom()
        if p.isSome:
          discard poppedOrStolen[p.get()].fetchAdd(1, moRelaxed)

    # Signal thieves to stop
    ctx.stopFlag.store(true, moRelease)

    for i in 0 ..< 4:
      joinThread(thiefThreads[i])

    # Drain leftovers from worker side after thieves have completed
    while true:
      let p = deque.popBottom()
      if p.isSome:
        discard poppedOrStolen[p.get()].fetchAdd(1, moRelaxed)
      else:
        break

    for i in 0 ..< Total:
      check poppedOrStolen[i].load(moRelaxed) == 1

suite "ChaseLevDeque — Last Element CAS Contention Race":
  type RaceContext = object
    deque: ChaseLevDeque[int]
    stop: Atomic[bool]
    thiefWins: Atomic[int]
    workerWins: Atomic[int]

  proc raceThief(ctx: ptr RaceContext) {.thread.} =
    var emptyCount = 0
    while not ctx.stop.load(moRelaxed):
      let s = ctx.deque.steal()
      if s.isSome:
        discard ctx.thiefWins.fetchAdd(1, moRelaxed)
        emptyCount = 0
      else:
        inc emptyCount
        if emptyCount > 128:
          sleep(0)
          emptyCount = 0
        else:
          cpuPause()

  test "continuous race for single remaining element (t == b)":
    let deque = initChaseLevDeque[int](16)
    var ctx = RaceContext(deque: deque)
    ctx.stop.store(false, moRelaxed)
    ctx.thiefWins.store(0, moRelaxed)
    ctx.workerWins.store(0, moRelaxed)

    var thief: Thread[ptr RaceContext]
    createThread(thief, raceThief, addr ctx)

    const Iterations = 2000
    for i in 1 .. Iterations:
      deque.pushBottom(i)
      cpuPause()
      let p = deque.popBottom()
      if p.isSome:
        discard ctx.workerWins.fetchAdd(1, moRelaxed)

    ctx.stop.store(true, moRelaxed)
    joinThread(thief)

    # Worker wins + thief wins must equal exactly Iterations
    let totalWins = ctx.workerWins.load(moRelaxed) + ctx.thiefWins.load(moRelaxed)
    check totalWins == Iterations
    check ctx.workerWins.load(moRelaxed) > 0
    check ctx.thiefWins.load(moRelaxed) > 0
