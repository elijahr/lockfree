## Unit and multi-threaded stress tests for SkipListMap, SortedTable, and Debra SMR integration.

import std/[options, algorithm]
import unittest2
import lockfree
import lockfree/skiplist

type
  PayloadRef = ref object
    id: int
    name: string

suite "SkipListMap Basic Operations":
  test "empty map invariants":
    var map = newSkipListMap[int, string]()
    check map.len == 0
    check not map.contains(42)
    check map.get(42).isNone
    check map.getOrDefault(42, "default") == "default"

  test "put, get, and len":
    var map = newSkipListMap[int, string]()
    check map.put(10, "ten") == true
    check map.put(20, "twenty") == true
    check map.put(5, "five") == true
    check map.len == 3

    check map.contains(10)
    check map.contains(20)
    check map.contains(5)
    check not map.contains(15)

    check map.get(10) == some("ten")
    check map.get(20) == some("twenty")
    check map.get(5) == some("five")
    check map.get(15).isNone

  test "put overwrite / update":
    var map = newSkipListMap[int, string]()
    check map.put(10, "ten") == true
    check map.len == 1
    # Overwrite
    check map.put(10, "TEN_UPDATED") == false
    check map.len == 1
    check map.get(10) == some("TEN_UPDATED")

  test "table indexing syntax [] and []=":
    var map = newSkipListMap[int, int]()
    map[100] = 1000
    map[200] = 2000
    check map[100] == 1000
    check map[200] == 2000
    check map.len == 2
    expect(KeyError):
      discard map[999]

  test "delete and del":
    var map = newSkipListMap[int, string]()
    map[1] = "one"
    map[2] = "two"
    map[3] = "three"
    check map.len == 3

    check map.delete(2) == true
    check map.len == 2
    check not map.contains(2)
    check map.get(2).isNone

    # Deleting absent key
    check map.delete(2) == false
    check map.len == 2

    # del operator
    del(map, 1)
    check map.len == 1
    check not map.contains(1)

    del(map, 3)
    check map.len == 0
    check not map.contains(3)

  test "computeIfAbsent":
    var map = newSkipListMap[string, int]()
    var callCount = 0
    let v1 = map.computeIfAbsent("key1", proc(k: string): int =
      callCount.inc()
      42
    )
    check v1 == 42
    check callCount == 1
    check map["key1"] == 42
    check map.len == 1

    # Second call should not invoke closure
    let v2 = map.computeIfAbsent("key1", proc(k: string): int =
      callCount.inc()
      999
    )
    check v2 == 42
    check callCount == 1
    check map["key1"] == 42

suite "SkipListMap Ordered Iteration":
  test "strictly ascending order across scrambled insertions":
    var map = newSkipListMap[int, int]()
    let inputs = @[50, 10, 90, 30, 70, 20, 80, 40, 60, 100, 5, 95]
    for x in inputs:
      map[x] = x * 10

    var sortedKeys: seq[int]
    for k in map.keys():
      sortedKeys.add(k)

    var expected = inputs
    expected.sort()
    check sortedKeys == expected

    var pairsKeys: seq[int]
    var pairsVals: seq[int]
    for (k, v) in map.pairs():
      pairsKeys.add(k)
      pairsVals.add(v)

    check pairsKeys == expected
    for i in 0 ..< pairsKeys.len:
      check pairsVals[i] == pairsKeys[i] * 10

suite "Ergonomic Aliases & Umbrella Export":
  test "SortedTable instantiation":
    var tbl: SortedTable[string, int] = newSortedTable[string, int]()
    tbl["alpha"] = 1
    tbl["beta"] = 2
    check tbl.len == 2
    check tbl["alpha"] == 1
    check "beta" in tbl

  test "OrderedTable instantiation":
    var tbl: OrderedTable[int, string] = newOrderedTable[int, string]()
    tbl[1] = "first"
    check tbl[1] == "first"
    check tbl.len == 1

  test "ConcurrentSortedTable instantiation":
    var tbl: ConcurrentSortedTable[int, int] = newConcurrentSortedTable[int, int]()
    tbl[7] = 77
    check tbl[7] == 77
    check tbl.len == 1

suite "ARC/ORC Managed Types Lifetime":
  test "string keys and string values":
    var map = newSkipListMap[string, string]()
    for i in 0 ..< 50:
      map["k" & $i] = "v" & $i
    check map.len == 50
    for i in 0 ..< 50:
      check map["k" & $i] == "v" & $i
    for i in 0 ..< 25:
      check map.delete("k" & $i) == true
    check map.len == 25

  test "ref object values":
    var map = newSkipListMap[int, PayloadRef]()
    for i in 1 .. 20:
      map[i] = PayloadRef(id: i, name: "item_" & $i)
    check map.len == 20
    for i in 1 .. 20:
      let item = map[i]
      check item.id == i
      check item.name == "item_" & $i

    # Update ref
    map[5] = PayloadRef(id: 500, name: "updated_5")
    check map[5].id == 500
    check map[5].name == "updated_5"

    # Delete ref
    check map.delete(5) == true
    check not map.contains(5)
    check map.len == 19

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
