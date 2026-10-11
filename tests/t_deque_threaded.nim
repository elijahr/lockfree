## Tier 2: Multithreaded concurrency test suite for ChaseLevDeque.
## Validates multi-thief work stealing, batch stealing under contention, and last-element CAS race.

when not compileOption("threads"):
  {.error: "t_deque_threaded requires --threads:on".}

import std/[options, os]
import unittest2

import lockfree/deque
import lockfree/atomics
import lockfree/atomics/backoff

suite "ChaseLevDeque — Concurrent Multi-Thief Stress Tests":
  const Total = 2000

  type
    StressContext = object
      deque: ChaseLevDeque[int]
      totalItems: int
      poppedOrStolen: ptr array[Total, Atomic[int]]
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

  test "1 Worker pushing 2,000 items with 4 concurrent thieves":
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

    const Iterations = 1000
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
    check ctx.thiefWins.load(moRelaxed) >= 0
