## Multi-threaded integration tests for SkipListMap.

import std/[options, algorithm]
import unittest2
import lockfree
import lockfree/skiplist

suite "SkipListMap Multi-threaded Stress":
  type
    ThreadCtx = object
      map: ptr SkipListMap[int, int]
      threadId: int
      itemsPerThread: int

  proc insertWorker(ctx: ptr ThreadCtx) {.thread.} =
    {.cast(gcsafe).}:
      let base = ctx.threadId * ctx.itemsPerThread
      for i in 0 ..< ctx.itemsPerThread:
        let k = base + i
        discard ctx.map[].put(k, k * 2)

  test "concurrent multi-threaded disjunct insertions":
    const NumThreads = 4
    const ItemsPerThread = 500
    const TotalItems = NumThreads * ItemsPerThread

    var map = newSkipListMap[int, int]()
    var contexts: array[NumThreads, ThreadCtx]
    var threads: array[NumThreads, Thread[ptr ThreadCtx]]

    for i in 0 ..< NumThreads:
      contexts[i] = ThreadCtx(
        map: addr map,
        threadId: i,
        itemsPerThread: ItemsPerThread
      )
      createThread(threads[i], insertWorker, addr contexts[i])

    for i in 0 ..< NumThreads:
      joinThread(threads[i])

    check map.len == TotalItems

    for i in 0 ..< TotalItems:
      let opt = map.get(i)
      check opt.isSome
      if opt.isSome:
        check opt.get == i * 2

    # Verify iteration produces all sorted keys
    var count = 0
    var prev = -1
    for k in map.keys():
      check k > prev
      prev = k
      count.inc()
    check count == TotalItems

  proc mixedWorker(ctx: ptr ThreadCtx) {.thread.} =
    {.cast(gcsafe).}:
      let base = ctx.threadId * ctx.itemsPerThread
      # Insert
      for i in 0 ..< ctx.itemsPerThread:
        let k = base + i
        discard ctx.map[].put(k, k * 3)
      # Read
      for i in 0 ..< ctx.itemsPerThread:
        let k = base + i
        discard ctx.map[].get(k)
      # Delete half
      for i in 0 ..< ctx.itemsPerThread div 2:
        let k = base + i
        discard ctx.map[].delete(k)

  test "concurrent mixed put/get/delete workers":
    const NumThreads = 4
    const ItemsPerThread = 300

    var map = newSkipListMap[int, int]()
    var contexts: array[NumThreads, ThreadCtx]
    var threads: array[NumThreads, Thread[ptr ThreadCtx]]

    for i in 0 ..< NumThreads:
      contexts[i] = ThreadCtx(
        map: addr map,
        threadId: i,
        itemsPerThread: ItemsPerThread
      )
      createThread(threads[i], mixedWorker, addr contexts[i])

    for i in 0 ..< NumThreads:
      joinThread(threads[i])

    let expectedRemaining = NumThreads * (ItemsPerThread - ItemsPerThread div 2)
    check map.len == expectedRemaining

    for t in 0 ..< NumThreads:
      let base = t * ItemsPerThread
      for i in 0 ..< ItemsPerThread div 2:
        check not map.contains(base + i)
      for i in (ItemsPerThread div 2) ..< ItemsPerThread:
        check map.contains(base + i)
        check map[base + i] == (base + i) * 3
