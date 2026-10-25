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

  test "concurrent multi-producer multi-consumer tryPush and peek stress":
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

    proc tryPushProducerWorker(arg: WorkerArg) {.thread, nimcall.} =
      let startVal = arg.idx * ItemsPerThread
      for i in 0 ..< ItemsPerThread:
        var val = startVal + i
        var spins = InitialSpin
        while not arg.stack[].tryPush(val):
          backoffOnRetry(spins)

    proc peekAndPopConsumerWorker(arg: WorkerArg) {.thread, nimcall.} =
      var count = 0
      var val: int
      while true:
        let peekOpt = arg.stack[].peek() # Optimistic read concurrent with pop
        if peekOpt.isSome:
          doAssert peekOpt.get() >= 0 and peekOpt.get() < NumThreads * ItemsPerThread
        if arg.stack[].tryPop(val):
          inc count
        else:
          if doneProducers.load(moAcquire) == NumThreads and arg.stack[].isEmpty:
            while arg.stack[].tryPop(val):
              inc count
            break
          cpuPause()
      poppedCounts[arg.idx] = count

    var prodThreads: array[NumThreads, Thread[WorkerArg]]
    var consThreads: array[NumThreads, Thread[WorkerArg]]

    for i in 0 ..< NumThreads:
      createThread(consThreads[i], peekAndPopConsumerWorker, WorkerArg(idx: i, stack: sPtr))

    for i in 0 ..< NumThreads:
      createThread(prodThreads[i], tryPushProducerWorker, WorkerArg(idx: i, stack: sPtr))

    for i in 0 ..< NumThreads:
      joinThread(prodThreads[i])
    doneProducers.store(NumThreads, moRelease)

    for i in 0 ..< NumThreads:
      joinThread(consThreads[i])

    var totalPopped = 0
    for i in 0 ..< NumThreads:
      totalPopped += poppedCounts[i]

    let remaining = s.drain()
    totalPopped += remaining.len

    check totalPopped == NumThreads * ItemsPerThread
    check s.isEmpty == true
    check s.len == 0

