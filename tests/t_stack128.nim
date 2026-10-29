## Tests for 128-Bit Hardware DWCAS Lock-Free TaggedStack (Stack128)

import unittest2
import std/options
import lockfree/atomics
import lockfree/backoff
import lockfree/stack128

suite "TaggedStack / Stack128 (128-Bit DWCAS)":

  test "basic push, peek, pop, isEmpty, len":
    var s = initTaggedStack[int]()
    check s.isEmpty == true
    check s.len == 0
    check s.pop().isNone
    check s.peek().isNone

    s.push(10)
    check s.isEmpty == false
    check s.len == 1
    check s.peek() == some(10)

    s.push(20)
    s.push(30)
    check s.len == 3
    check s.peek() == some(30)

    check s.pop() == some(30)
    check s.pop() == some(20)
    check s.len == 1
    check s.pop() == some(10)
    check s.isEmpty == true
    check s.len == 0
    check s.pop().isNone

  test "node recycling and freelist reuse":
    var s = initTaggedStack[int]()
    # Push and pop many times to trigger freelist allocation and reuse
    for cycle in 0 ..< 1000:
      s.push(cycle)
      let val = s.pop()
      check val == some(cycle)
    check s.isEmpty == true
    check s.len == 0

  test "batch push, drain, and clear":
    var s = initTaggedStack[string]()
    s.push(["alpha", "beta", "gamma"])
    check s.len == 3
    check s.peek() == some("gamma")

    let drained = s.drain()
    check drained == @["gamma", "beta", "alpha"]
    check s.isEmpty == true
    check s.len == 0

    s.push(["x", "y", "z"])
    check s.len == 3
    s.clear()
    check s.isEmpty == true
    check s.len == 0

  test "heap allocated newTaggedStack and freeTaggedStack":
    let s = newTaggedStack[int]()
    s[].push(42)
    s[].push(84)
    check s[].len == 2
    check s[].pop() == some(84)
    check s[].pop() == some(42)
    freeTaggedStack(s)

  test "alias Stack128 parity":
    var s = initStack128[int]()
    s.push(999)
    check s.len == 1
    check s.pop() == some(999)

  test "concurrent multi-producer multi-consumer stress":
    var s = initTaggedStack[int]()
    let sPtr = addr s
    const NumThreads = 4
    const ItemsPerThread = 5000

    type
      WorkerArg = object
        idx: int
        stack: ptr TaggedStack[int]

    var poppedCounts {.global.}: array[NumThreads, int]
    var doneProducers {.global.}: Atomic[int]
    doneProducers.store(0, moRelaxed)

    proc producerWorker(arg: WorkerArg) {.thread, nimcall.} =
      let startVal = arg.idx * ItemsPerThread
      for i in 0 ..< ItemsPerThread:
        arg.stack[].push(startVal + i)

    proc consumerWorker(arg: WorkerArg) {.thread, nimcall.} =
      var count = 0
      var val: int
      while true:
        if arg.stack[].tryPop(val):
          inc count
        else:
          if doneProducers.load(moAcquire) == NumThreads and arg.stack[].isEmpty:
            # Drain any remaining elements that arrived right before termination
            while arg.stack[].tryPop(val):
              inc count
            break
          cpuPause()
      poppedCounts[arg.idx] = count

    var prodThreads: array[NumThreads, Thread[WorkerArg]]
    var consThreads: array[NumThreads, Thread[WorkerArg]]

    for i in 0 ..< NumThreads:
      createThread(consThreads[i], consumerWorker, WorkerArg(idx: i, stack: sPtr))

    for i in 0 ..< NumThreads:
      createThread(prodThreads[i], producerWorker, WorkerArg(idx: i, stack: sPtr))

    for i in 0 ..< NumThreads:
      joinThread(prodThreads[i])
    doneProducers.store(NumThreads, moRelease)

    for i in 0 ..< NumThreads:
      joinThread(consThreads[i])

    var totalPopped = 0
    for i in 0 ..< NumThreads:
      totalPopped += poppedCounts[i]

    # Drain any remaining if any
    let remaining = s.drain()
    totalPopped += remaining.len

    check totalPopped == NumThreads * ItemsPerThread
    check s.isEmpty == true
    check s.len == 0

  test "concurrent tryPush and pop never observe uninitialized payload":
    var s = initTaggedStack[int]()
    let sPtr = addr s
    const NumThreads = 4
    const ItemsPerThread = 2500

    type
      TryPushWorkerArg = object
        idx: int
        stack: ptr TaggedStack[int]

    var poppedCounts {.global.}: array[NumThreads, int]
    var zeroPayloadObserved {.global.}: Atomic[int]
    var doneProducers {.global.}: Atomic[int]
    zeroPayloadObserved.store(0, moRelaxed)
    doneProducers.store(0, moRelaxed)

    proc tryPushProducer(arg: TryPushWorkerArg) {.thread, nimcall.} =
      let baseVal = arg.idx * ItemsPerThread + 1
      for i in 0 ..< ItemsPerThread:
        let v = baseVal + i
        while not arg.stack[].tryPush(v):
          cpuPause()

    proc tryPushConsumer(arg: TryPushWorkerArg) {.thread, nimcall.} =
      var count = 0
      while true:
        let opt = arg.stack[].pop()
        if opt.isSome:
          if opt.get <= 0:
            discard zeroPayloadObserved.fetchAdd(1, moRelaxed)
          inc count
        else:
          if doneProducers.load(moAcquire) == NumThreads and arg.stack[].isEmpty:
            while true:
              let tailOpt = arg.stack[].pop()
              if tailOpt.isSome:
                if tailOpt.get <= 0:
                  discard zeroPayloadObserved.fetchAdd(1, moRelaxed)
                inc count
              else:
                break
            break
          cpuPause()
      poppedCounts[arg.idx] = count

    var prodThreads: array[NumThreads, Thread[TryPushWorkerArg]]
    var consThreads: array[NumThreads, Thread[TryPushWorkerArg]]

    for i in 0 ..< NumThreads:
      createThread(consThreads[i], tryPushConsumer, TryPushWorkerArg(idx: i, stack: sPtr))
    for i in 0 ..< NumThreads:
      createThread(prodThreads[i], tryPushProducer, TryPushWorkerArg(idx: i, stack: sPtr))

    for i in 0 ..< NumThreads:
      joinThread(prodThreads[i])
    doneProducers.store(NumThreads, moRelease)
    for i in 0 ..< NumThreads:
      joinThread(consThreads[i])

    var totalPopped = 0
    for i in 0 ..< NumThreads:
      totalPopped += poppedCounts[i]
    let remaining = s.drain()
    for v in remaining:
      check v > 0
    totalPopped += remaining.len

    check zeroPayloadObserved.load(moAcquire) == 0
    check totalPopped == NumThreads * ItemsPerThread
    check s.isEmpty == true
    check s.len == 0

