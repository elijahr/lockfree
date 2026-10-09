## Unit and multi-threaded stress tests for Ctrie, Table, ConcurrentTable, and Debra SMR integration.

import std/[options, os, hashes]
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

type
  CollidingKey = object
    id: int

proc hash(k: CollidingKey): Hash {.inline.} =
  # All keys force identical hash to test LNode chains and deep collisions
  hash(42)

proc `==`(a, b: CollidingKey): bool {.inline.} =
  a.id == b.id

suite "Ctrie Remediations: CRIT-01, MED-01 & LNode Collisions":
  test "LNode collision chain inserts, updates, and contraction":
    var map = newCtrie[CollidingKey, string]()
    # Insert 10 keys that share identical hash
    for i in 1 .. 10:
      let k = CollidingKey(id: i)
      check map.put(k, "val_" & $i).isNone

    check map.len == 10
    for i in 1 .. 10:
      check map.get(CollidingKey(id: i)) == some("val_" & $i)

    # Overwrite half of them to test VBox refcounting on LNode (CRIT-01)
    for i in 1 .. 5:
      let k = CollidingKey(id: i)
      let prev = map.put(k, "UPDATED_" & $i)
      check prev == some("val_" & $i)

    check map.len == 10
    for i in 1 .. 5:
      check map.get(CollidingKey(id: i)) == some("UPDATED_" & $i)
    for i in 6 .. 10:
      check map.get(CollidingKey(id: i)) == some("val_" & $i)

    # Delete down to 1 element to trigger contraction from LNode to SNode
    for i in 1 .. 9:
      let k = CollidingKey(id: i)
      let deleted = map.delete(k)
      check deleted.isSome

    check map.len == 1
    # 10 is the surviving key
    check map.get(CollidingKey(id: 10)) == some("val_10")
    check map.contains(CollidingKey(id: 10))

    # Delete the final key
    check map.delete(CollidingKey(id: 10)) == some("val_10")
    check map.len == 0
    check map.isEmpty

suite "Ctrie Remediations: HIGH-02 putIfAbsent & computeIfAbsent Concurrency":
  test "putIfAbsent unit semantics":
    var map = newCtrie[string, string]()
    check map.putIfAbsent("k1", "v1").isNone
    check map.len == 1
    check map.get("k1") == some("v1")

    # Second putIfAbsent must return existing and not overwrite
    check map.putIfAbsent("k1", "v2") == some("v1")
    check map.len == 1
    check map.get("k1") == some("v1")

  type
    ComputeContext = object
      map: ptr Ctrie[string, int, 64]
      results: ptr array[8, int]
      threadId: int

  proc computeWorker(ctx: ptr ComputeContext) {.thread.} =
    let res = ctx.map[].computeIfAbsent("shared_counter", proc(k: string): int =
      # Thread-specific compute attempt
      (ctx.threadId + 1) * 100
    )
    ctx.results[ctx.threadId] = res

  test "8 threads concurrent computeIfAbsent on single key":
    var map = newCtrie[string, int, 64]()
    const NumThreads = 8
    var threads: array[NumThreads, Thread[ptr ComputeContext]]
    var ctxs: array[NumThreads, ComputeContext]
    var results: array[NumThreads, int]

    for i in 0 ..< NumThreads:
      ctxs[i] = ComputeContext(
        map: addr map,
        results: addr results,
        threadId: i
      )
      createThread(threads[i], computeWorker, addr ctxs[i])

    for i in 0 ..< NumThreads:
      joinThread(threads[i])

    check map.len == 1
    let winner = map.get("shared_counter")
    check winner.isSome
    # Every thread must observe the exact same value without lost updates
    for i in 0 ..< NumThreads:
      check results[i] == winner.get

suite "Ctrie Remediations: CRIT-02 Snapshot SMR Pinning & Concurrent Mutation":
  type
    MutatorContext = object
      map: ptr Ctrie[int, string, 64]
      stopFlag: ptr Atomic[bool]

    ReaderContext = object
      snap: Snapshot[int, string, 64]
      stopFlag: ptr Atomic[bool]
      readCount: int

  proc mutatorThread(ctx: ptr MutatorContext) {.thread.} =
    var iter = 0
    while not ctx.stopFlag[].load(moAcquire):
      inc iter
      # Overwrite existing keys to retire nodes
      for k in 1 .. 50:
        ctx.map[].put(k, "mutated_" & $iter & "_" & $k)
      # Delete and reinsert
      for k in 26 .. 50:
        discard ctx.map[].delete(k)
      for k in 26 .. 50:
        ctx.map[].put(k, "reinserted_" & $iter & "_" & $k)

  proc readerThread(ctx: ptr ReaderContext) {.thread.} =
    while not ctx.stopFlag[].load(moAcquire):
      for k, v in ctx.snap.pairs:
        inc ctx.readCount
        if k in 1 .. 50:
          # In the snapshot, all keys 1..50 must have their original snapshot values!
          assert v == "snap_init_" & $k
      let v1 = ctx.snap.get(1)
      assert v1 == some("snap_init_1")

  test "concurrent mutator and snapshot reader under SMR epoch transitions":
    var map = newCtrie[int, string, 64]()
    for i in 1 .. 50:
      map[i] = "snap_init_" & $i

    let snap = map.snapshot()
    var stopFlag: Atomic[bool]
    stopFlag.store(false, moRelaxed)

    var mutCtx = MutatorContext(map: addr map, stopFlag: addr stopFlag)
    var readCtx = ReaderContext(snap: snap, stopFlag: addr stopFlag, readCount: 0)

    var tMut: Thread[ptr MutatorContext]
    var tRead: Thread[ptr ReaderContext]

    createThread(tMut, mutatorThread, addr mutCtx)
    createThread(tRead, readerThread, addr readCtx)

    # Let threads run concurrently for 200ms
    sleep(200)
    stopFlag.store(true, moRelease)

    joinThread(tMut)
    joinThread(tRead)

    check readCtx.readCount > 0
    # Final check: snapshot must still be 100% intact
    check snap.len == 50
    for i in 1 .. 50:
      check snap.get(i) == some("snap_init_" & $i)

