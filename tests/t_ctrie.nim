## Unit and multi-threaded stress tests for Ctrie, Table, ConcurrentTable, and Debra SMR integration.

import std/[options, os]
import unittest2
import lockfree
import lockfree/ctrie

type
  PayloadRef = ref object
    id: int
    name: string

suite "Ctrie Basic Operations":
  test "empty map invariants":
    var map = newCtrie[int, string]()
    check map.len == 0
    check map.isEmpty
    check not map.contains(42)
    check map.get(42).isNone
    check map.getOrDefault(42, "default") == "default"

  test "put, get, and len":
    var map = newCtrie[int, string]()
    check map.put(10, "ten").isNone
    check map.put(20, "twenty").isNone
    check map.put(5, "five").isNone
    check map.len == 3
    check not map.isEmpty

    check map.contains(10)
    check map.contains(20)
    check map.contains(5)
    check not map.contains(15)

    check map.get(10) == some("ten")
    check map.get(20) == some("twenty")
    check map.get(5) == some("five")
    check map.get(15).isNone

  test "put overwrite / update":
    var map = newCtrie[int, string]()
    check map.put(10, "ten").isNone
    check map.len == 1
    # Overwrite
    let prev = map.put(10, "TEN_UPDATED")
    check prev == some("ten")
    check map.len == 1
    check map.get(10) == some("TEN_UPDATED")

  test "table indexing syntax [] and []=":
    var map = newTable[int, int]()
    map[100] = 1000
    map[200] = 2000
    check map[100] == 1000
    check map[200] == 2000
    check map.len == 2
    expect(KeyError):
      discard map[999]

  test "delete and del":
    var map = newCtrie[int, string]()
    map[1] = "one"
    map[2] = "two"
    map[3] = "three"
    check map.len == 3

    check map.delete(2) == some("two")
    check map.len == 2
    check not map.contains(2)
    check map.get(2).isNone

    # Deleting non-existent key
    check map.delete(99).isNone
    check map.len == 2

    map.del(1)
    check map.len == 1
    check not map.contains(1)

    map.del(3)
    check map.len == 0
    check map.isEmpty

  test "computeIfAbsent":
    var map = newCtrie[string, int]()
    var callCount = 0
    let computeA = proc(k: string): int =
      inc callCount
      k.len * 10

    let val1 = map.computeIfAbsent("hello", computeA)
    check val1 == 50
    check callCount == 1
    check map["hello"] == 50

    # Second call should return existing value without calling computeFn
    let val2 = map.computeIfAbsent("hello", computeA)
    check val2 == 50
    check callCount == 1

suite "Ctrie Collisions & HAMT Multi-Branching":
  test "insertion of 1000 sequential elements across 32-way HAMT levels":
    var map = newCtrie[int, int]()
    for i in 1 .. 1000:
      map[i] = i * 10

    check map.len == 1000
    for i in 1 .. 1000:
      check map.get(i) == some(i * 10)

    # Delete odd numbers
    for i in countup(1, 1000, 2):
      check map.delete(i) == some(i * 10)

    check map.len == 500
    for i in 1 .. 1000:
      if i mod 2 == 0:
        check map.get(i) == some(i * 10)
      else:
        check map.get(i).isNone

suite "Ctrie Wait-Free O(1) Snapshots":
  test "empty snapshot":
    var map = newCtrie[int, string]()
    let snap = map.snapshot()
    check snap.len == 0
    check snap.isEmpty
    check not snap.contains(1)

  test "point-in-time snapshot isolation under continuous writes":
    var map = newCtrie[int, string]()
    for i in 1 .. 50:
      map[i] = "val_" & $i

    check map.len == 50

    # Take Snapshot S1
    let snap1 = map.snapshot()
    check snap1.len == 50

    # Mutate map after snapshot: add 51..100, delete 1..25
    for i in 51 .. 100:
      map[i] = "val_" & $i
    for i in 1 .. 25:
      map.del(i)

    check map.len == 75

    # Verify Snapshot S1 remains completely frozen and untouched
    check snap1.len == 50
    for i in 1 .. 25:
      check snap1.contains(i)
      check snap1.get(i) == some("val_" & $i)
      check not map.contains(i)

    for i in 51 .. 100:
      check not snap1.contains(i)
      check snap1.get(i).isNone
      check map.contains(i)

  test "snapshot iterators (pairs, keys, values)":
    var map = newCtrie[string, int]()
    map["alpha"] = 1
    map["beta"] = 2
    map["gamma"] = 3

    let snap = map.snapshot()
    var pairsList: seq[(string, int)] = @[]
    for k, v in snap.pairs:
      pairsList.add((k, v))
    check pairsList.len == 3

    var keysList: seq[string] = @[]
    for k in snap.keys:
      keysList.add(k)
    check keysList.len == 3
    check "alpha" in keysList
    check "beta" in keysList
    check "gamma" in keysList

    var valsList: seq[int] = @[]
    for v in snap.values:
      valsList.add(v)
    check valsList.len == 3
    check 1 in valsList
    check 2 in valsList
    check 3 in valsList

suite "Ctrie Ergonomic Aliases & Constructors":
  test "ConcurrentTable, ConcurrentMap, and ConcurrentTrie aliases":
    var tbl = newConcurrentTable[string, int]()
    tbl["key1"] = 100
    check tbl["key1"] == 100

    var cmap = newConcurrentMap[int, string]()
    cmap[42] = "answer"
    check cmap[42] == "answer"

    var ctrie = newConcurrentTrie[int, int]()
    ctrie[1] = 2
    check ctrie[1] == 2

suite "Ctrie ARC/ORC Managed Types Lifetime":
  test "string keys and string values":
    var map = newCtrie[string, string]()
    for i in 1 .. 100:
      let k = "key_" & $i & "_extended_padding_for_heap_allocation"
      let v = "val_" & $i & "_extended_padding_for_heap_allocation"
      map[k] = v

    check map.len == 100
    for i in 1 .. 100:
      let k = "key_" & $i & "_extended_padding_for_heap_allocation"
      let expected = "val_" & $i & "_extended_padding_for_heap_allocation"
      check map[k] == expected

  test "ref object keys and values":
    var map = newCtrie[int, PayloadRef]()
    for i in 1 .. 50:
      map[i] = PayloadRef(id: i, name: "item_" & $i)

    check map.len == 50
    for i in 1 .. 50:
      let item = map[i]
      check item.id == i
      check item.name == "item_" & $i

    # Delete half
    for i in 1 .. 25:
      map.del(i)
    check map.len == 25

suite "Ctrie Multi-Threaded Concurrency":
  type
    StressContext = object
      map: ptr Ctrie[int, int, 64]
      numItemsPerThread: int
      threadId: int

  proc workerThread(ctx: ptr StressContext) {.thread.} =
    let startIdx = ctx.threadId * ctx.numItemsPerThread
    let endIdx = startIdx + ctx.numItemsPerThread
    for i in startIdx ..< endIdx:
      ctx.map[].put(i, i * 2)

  test "4 threads concurrent insertions":
    var map = newCtrie[int, int, 64]()
    const NumThreads = 4
    const ItemsPerThread = 250
    var threads: array[NumThreads, Thread[ptr StressContext]]
    var ctxs: array[NumThreads, StressContext]

    for i in 0 ..< NumThreads:
      ctxs[i] = StressContext(
        map: addr map,
        numItemsPerThread: ItemsPerThread,
        threadId: i
      )
      createThread(threads[i], workerThread, addr ctxs[i])

    for i in 0 ..< NumThreads:
      joinThread(threads[i])

    check map.len == NumThreads * ItemsPerThread
    for i in 0 ..< NumThreads * ItemsPerThread:
      check map.get(i) == some(i * 2)
