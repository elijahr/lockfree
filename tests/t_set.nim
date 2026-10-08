## Comprehensive test suite for SkipListSet with Debra SMR and concurrent set algebra.
## Validates API surface, sorted order, set algebra (intersect, union, difference, isSubsetOf),
## managed types (ARC/ORC/refc), and multi-threaded stress concurrency.

when not compileOption("threads"):
  {.error: "tests/t_set requires --threads:on".}

import unittest2

import lockfree/set
import lockfree/atomics
import lockfree/smr/nebr

type
  NamedRef = ref object
    id: int
    name: string

proc cmp(a, b: NamedRef): int =
  if a.id < b.id: -1
  elif b.id < a.id: 1
  else: 0

suite "SkipListSet - Basic API & Membership":
  test "empty set invariants":
    var s = initSkipListSet[int]()
    check s.len == 0
    check s.isEmpty
    check not s.contains(42)
    check s.toSeq == newSeq[int]()
    var count = 0
    for x in s:
      inc count
    check count == 0

  test "insert new and duplicate elements":
    var s = newSkipListSet[int]()
    check s.insert(10)
    check s.len == 1
    check not s.isEmpty
    check s.contains(10)

    # Duplicate insertion returns false and does not increment count
    check not s.insert(10)
    check s.len == 1

    check s.insert(20)
    check s.insert(5)
    check s.len == 3
    check s.contains(5)
    check s.contains(10)
    check s.contains(20)
    check not s.contains(99)

  test "remove existing and missing elements":
    var s = newSkipListSet[int]()
    s.incl(1)
    s.incl(2)
    s.incl(3)
    check s.len == 3

    check s.remove(2)
    check s.len == 2
    check not s.contains(2)
    check s.contains(1)
    check s.contains(3)

    # Removing already removed or absent element returns false
    check not s.remove(2)
    check not s.remove(999)
    check s.len == 2

    s.excl(1)
    s.excl(3)
    check s.len == 0
    check s.isEmpty
    check not s.contains(1)
    check not s.contains(3)

  test "strictly ascending sorted traversal":
    var s = newSkipListSet[int]()
    let inputs = [42, 17, 88, 3, 55, 99, 1, 24]
    for x in inputs:
      discard s.insert(x)

    check s.len == inputs.len
    let sortedSeq = s.toSeq
    check sortedSeq == @[1, 3, 17, 24, 42, 55, 88, 99]

  test "toSkipListSet from openArray":
    let s = toSkipListSet([5, 3, 8, 1, 3, 5, 8])
    check s.len == 4
    check s.toSeq == @[1, 3, 5, 8]

suite "SkipListSet - Constructors & Aliases":
  test "all constructor aliases":
    var s1: SkipListSet[int] = initSkipListSet[int]()
    var s2: SkipListSet[int] = newSkipListSet[int]()
    var s3: Set[int] = initSet[int]()
    var s4: Set[int] = newSet[int]()
    var s5: ConcurrentSet[int] = initConcurrentSet[int]()
    var s6: ConcurrentSet[int] = newConcurrentSet[int]()
    var s7: OrderedSet[int] = initOrderedSet[int]()
    var s8: OrderedSet[int] = newOrderedSet[int]()

    s1.incl(1)
    s2.incl(2)
    s3.incl(3)
    s4.incl(4)
    s5.incl(5)
    s6.incl(6)
    s7.incl(7)
    s8.incl(8)

    check s1.contains(1)
    check s2.contains(2)
    check s3.contains(3)
    check s4.contains(4)
    check s5.contains(5)
    check s6.contains(6)
    check s7.contains(7)
    check s8.contains(8)

  test "external DebraManager sharing":
    var mgr = initDebraManager[16, ccMulti]()
    var s = newSkipListSet[int, 16, 16](addr mgr)
    s.incl(100)
    s.incl(200)
    check s.len == 2
    check s.contains(100)
    check s.contains(200)

suite "SkipListSet - Managed Types (ARC/ORC/Refc)":
  test "string elements":
    var s = newSet[string]()
    s.incl("banana")
    s.incl("apple")
    s.incl("cherry")
    check s.len == 3
    check s.contains("apple")
    check s.contains("banana")
    check s.contains("cherry")
    check not s.contains("date")
    check s.toSeq == @["apple", "banana", "cherry"]

    check s.remove("banana")
    check s.toSeq == @["apple", "cherry"]

  test "ref object elements":
    var s = newSet[NamedRef]()
    let r1 = NamedRef(id: 1, name: "one")
    let r2 = NamedRef(id: 2, name: "two")
    let r3 = NamedRef(id: 3, name: "three")

    s.incl(r2)
    s.incl(r1)
    s.incl(r3)
    check s.len == 3

    let query1 = NamedRef(id: 1, name: "different_name")
    check s.contains(query1)

    check s.remove(query1)
    check s.len == 2
    check not s.contains(r1)

suite "SkipListSet - Concurrent Set Algebra":
  test "intersect / *":
    let a = toSkipListSet([1, 2, 3, 4, 5])
    let b = toSkipListSet([3, 4, 5, 6, 7])
    let ab = a.intersect(b)
    check ab.toSeq == @[3, 4, 5]
    check ab.len == 3

    let star = a * b
    check star.toSeq == @[3, 4, 5]

    let disjoint = toSkipListSet([10, 20])
    check (a * disjoint).isEmpty

  test "union / +":
    let a = toSkipListSet([1, 2, 3])
    let b = toSkipListSet([3, 4, 5])
    let u = a.union(b)
    check u.toSeq == @[1, 2, 3, 4, 5]
    check u.len == 5

    let plus = a + b
    check plus.toSeq == @[1, 2, 3, 4, 5]

  test "difference / -":
    let a = toSkipListSet([1, 2, 3, 4])
    let b = toSkipListSet([2, 4, 6])
    let diff = a.difference(b)
    check diff.toSeq == @[1, 3]

    let minus = a - b
    check minus.toSeq == @[1, 3]

  test "isSubsetOf / <= / < / ==":
    let s1 = toSkipListSet([1, 2])
    let s2 = toSkipListSet([1, 2, 3])
    let s3 = toSkipListSet([2, 1])
    let s4 = toSkipListSet([1, 4])

    check s1.isSubsetOf(s2)
    check s1 <= s2
    check s1 < s2
    check not (s2 <= s1)

    check s1 <= s3
    check s3 <= s1
    check not (s1 < s3)
    check s1 == s3

    check not (s4 <= s2)
    check not (s4 == s2)

suite "SkipListSet - Multithreaded Concurrency":
  const
    ItemCount = 10000
    ThreadCount = 4
    ItemsPerThread = ItemCount div ThreadCount

  type
    DisjointWorkerCtx = object
      set: ptr Set[int]
      threadIdx: int

    OverlappingWorkerCtx = object
      set: ptr Set[int]
      threadIdx: int

    MixedWorkerCtx = object
      set: ptr Set[int]
      threadIdx: int
      insertDone: ptr Atomic[bool]

  proc disjointInsertWorker(ctx: ptr DisjointWorkerCtx) {.thread.} =
    {.cast(gcsafe).}:
      let base = ctx.threadIdx * ItemsPerThread
      for i in 0 ..< ItemsPerThread:
        discard ctx.set[].insert(base + i)

  proc overlappingInsertWorker(ctx: ptr OverlappingWorkerCtx) {.thread.} =
    {.cast(gcsafe).}:
      # Each thread attempts to insert the same 0 ..< 2500 range
      for i in 0 ..< 2500:
        discard ctx.set[].insert(i)

  proc mixedWorker(ctx: ptr MixedWorkerCtx) {.thread.} =
    {.cast(gcsafe).}:
      let base = ctx.threadIdx * 1000
      for i in 0 ..< 1000:
        discard ctx.set[].insert(base + i)
      # Now remove half of them
      for i in 0 ..< 500:
        discard ctx.set[].remove(base + i)

  test "Concurrent Disjoint Insertions (10,000 items)":
    var s = newSet[int]()
    var ctxs: array[ThreadCount, DisjointWorkerCtx]
    var threads: array[ThreadCount, Thread[ptr DisjointWorkerCtx]]

    for i in 0 ..< ThreadCount:
      ctxs[i] = DisjointWorkerCtx(set: addr s, threadIdx: i)
      createThread(threads[i], disjointInsertWorker, addr ctxs[i])

    for i in 0 ..< ThreadCount:
      joinThread(threads[i])

    check s.len == ItemCount
    for i in 0 ..< ItemCount:
      check s.contains(i)

    # Verify order is strictly sorted
    var prev = -1
    var count = 0
    for x in s:
      check x > prev
      prev = x
      inc count
    check count == ItemCount

  test "Concurrent Overlapping Insertions & Deduplication":
    var s = newSet[int]()
    var ctxs: array[ThreadCount, OverlappingWorkerCtx]
    var threads: array[ThreadCount, Thread[ptr OverlappingWorkerCtx]]

    for i in 0 ..< ThreadCount:
      ctxs[i] = OverlappingWorkerCtx(set: addr s, threadIdx: i)
      createThread(threads[i], overlappingInsertWorker, addr ctxs[i])

    for i in 0 ..< ThreadCount:
      joinThread(threads[i])

    check s.len == 2500
    for i in 0 ..< 2500:
      check s.contains(i)

  test "Concurrent Interleaved Insert & Remove Stress":
    var s = newSet[int]()
    var ctxs: array[ThreadCount, MixedWorkerCtx]
    var threads: array[ThreadCount, Thread[ptr MixedWorkerCtx]]
    var flag: Atomic[bool]
    flag.store(false, moRelaxed)

    for i in 0 ..< ThreadCount:
      ctxs[i] = MixedWorkerCtx(set: addr s, threadIdx: i, insertDone: addr flag)
      createThread(threads[i], mixedWorker, addr ctxs[i])

    for i in 0 ..< ThreadCount:
      joinThread(threads[i])

    # 4 threads inserted 1000 each (4000 total), then each removed 500 (2000 remaining)
    check s.len == 2000
    for t in 0 ..< ThreadCount:
      let base = t * 1000
      for i in 0 ..< 500:
        check not s.contains(base + i)
      for i in 500 ..< 1000:
        check s.contains(base + i)
