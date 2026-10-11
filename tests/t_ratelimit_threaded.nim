## Multi-threaded integration tests for Hardware 128-Bit DWCAS Rate Limiters.

import unittest2
import lockfree/ratelimit
import lockfree/atomics

suite "Wave 4A Rate Limiters — Multithreaded Contention":
  test "TokenBucket multithreaded contention stress":
    const NumThreads = 8
    const OpsPerThread = 1000
    const TotalTokens = 4000'u64

    var tb = initTokenBucket(capacityTokens = TotalTokens, refillRatePerSec = 0, initialTokens = TotalTokens)

    type WorkerArg = object
      tb: ptr TokenBucket
      acquired: ptr Atomic[int]

    proc worker(arg: WorkerArg) {.thread.} =
      var localAcquired = 0
      for _ in 1 .. OpsPerThread:
        if arg.tb[].tryAcquire(1):
          inc localAcquired
      discard arg.acquired[].fetchAdd(localAcquired)

    var totalAcquired: Atomic[int]
    totalAcquired.store(0)

    var threads: array[NumThreads, Thread[WorkerArg]]
    for i in 0 ..< NumThreads:
      createThread(threads[i], worker, WorkerArg(tb: addr tb, acquired: addr totalAcquired))

    for i in 0 ..< NumThreads:
      joinThread(threads[i])

    # Exactly TotalTokens should have been acquired, none lost, none duplicated
    check totalAcquired.load() == int(TotalTokens)
    check tb.available == 0
