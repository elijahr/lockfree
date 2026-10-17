## Tier 1: Unit test suite for TreiberStack with Elimination-Backoff Array.
## Validates API surface, LIFO ordering, bulk operations, and managed types (ARC/ORC/refc).

import std/options
import unittest2

import lockfree/stack
import lockfree/atomics

type
  PayloadRef = ref object
    id: int
    data: string

suite "TreiberStack - Basic API & Semantics":
  test "empty stack invariants":
    var s = initTreiberStack[int]()
    check s.len == 0
    check s.isEmpty
    check s.peek().isNone
    check s.pop().isNone
    check s.drain() == newSeq[int]()

  test "LIFO ordering single-threaded":
    var s = initTreiberStack[int]()
    s.push(1)
    s.push(2)
    s.push(3)
    check s.len == 3
    check not s.isEmpty

    let p1 = s.pop()
    check p1.isSome and p1.get == 3
    let p2 = s.pop()
    check p2.isSome and p2.get == 2
    let p3 = s.pop()
    check p3.isSome and p3.get == 1
    check s.pop().isNone
    check s.len == 0
    check s.isEmpty

  test "peek does not consume item":
    var s = newTreiberStack[string]()
    s.push("first")
    s.push("second")
    check s.peek() == some("second")
    check s.peek() == some("second")
    check s.len == 2
    check s.pop() == some("second")
    check s.peek() == some("first")
    check s.pop() == some("first")
    check s.peek().isNone

  test "peek and len on immutable binding":
    var s = initStack[int]()
    s.push(42)
    s.push(99)
    let ro = s # shallow alias via let
    check ro.len == 2
    check not ro.isEmpty
    check ro.peek() == some(99)

  test "bulk push openArray":
    var s = initStack[int]()
    s.push([10, 20, 30])
    check s.len == 3
    check s.pop() == some(30)
    check s.pop() == some(20)
    check s.pop() == some(10)
    check s.pop().isNone

  test "interleaved push and pop":
    var s = initStack[int]()
    s.push(1)
    s.push(2)
    check s.pop() == some(2)
    s.push(3)
    check s.pop() == some(3)
    s.push(4)
    check s.pop() == some(4)
    check s.pop() == some(1)
    check s.pop().isNone
    check s.isEmpty

  test "drain empty and populated":
    var s = initStack[int]()
    check s.drain() == newSeq[int]()

    s.push([1, 2, 3, 4, 5])
    let drained = s.drain()
    check drained == @[5, 4, 3, 2, 1]
    check s.isEmpty
    check s.len == 0
    check s.pop().isNone

  test "drainInto appends in LIFO order":
    var s = initStack[int]()
    var outSeq = @[100, 200]
    s.drainInto(outSeq)
    check outSeq == @[100, 200]

    s.push([10, 20, 30])
    s.drainInto(outSeq)
    check outSeq == @[100, 200, 30, 20, 10]
    check s.isEmpty
    check s.len == 0

  test "constructors and aliases":
    var s1 = initTreiberStack[int]()
    var s2 = newTreiberStack[int]()
    var s3 = initStack[int]()
    var s4 = newStack[int]()
    var s5: ref ConcurrentStack[int] = newConcurrentStack[int]()

    s1.push(1)
    s2.push(2)
    s3.push(3)
    s4.push(4)
    s5[].push(5)

    check s1.pop() == some(1)
    check s2.pop() == some(2)
    check s3.pop() == some(3)
    check s4.pop() == some(4)
    check s5[].pop() == some(5)

suite "TreiberStack - Managed Types (ARC/ORC/Refc)":
  test "string payloads and free-list recycling":
    var s = initStack[string]()
    for round in 0 ..< 10:
      for i in 0 ..< 50:
        s.push("item_" & $i)
      check s.len == 50
      for i in countdown(49, 0):
        check s.pop() == some("item_" & $i)
      check s.isEmpty

  test "seq[int] payloads":
    var s = initStack[seq[int]]()
    s.push(@[1, 2, 3])
    s.push(@[4, 5])
    s.push(@[6])
    check s.pop() == some(@[6])
    check s.pop() == some(@[4, 5])
    check s.pop() == some(@[1, 2, 3])
    check s.isEmpty

  test "ref object payloads":
    var s = initStack[PayloadRef]()
    s.push(PayloadRef(id: 1, data: "alpha"))
    s.push(PayloadRef(id: 2, data: "beta"))
    let b = s.pop()
    check b.isSome and b.get.id == 2 and b.get.data == "beta"
    let a = s.pop()
    check a.isSome and a.get.id == 1 and a.get.data == "alpha"
    check s.isEmpty

  test "managed string drain and drainInto":
    var s = initStack[string]()
    for i in 0 ..< 64:
      s.push("payload_segment_" & $i & "_with_heap_allocation")
    let drained = s.drain()
    check drained.len == 64
    check drained[0] == "payload_segment_63_with_heap_allocation"
    check drained[63] == "payload_segment_0_with_heap_allocation"
    check s.isEmpty

    var intoSeq: seq[string] = @["prefix"]
    for i in 0 ..< 32:
      s.push("into_" & $i)
    s.drainInto(intoSeq)
    check intoSeq.len == 33
    check intoSeq[0] == "prefix"
    check intoSeq[1] == "into_31"
    check intoSeq[32] == "into_0"
    check s.isEmpty

when compileOption("threads") and (defined(gcArc) or defined(gcOrc) or defined(gcAtomicArc)):
  import lockfree/backoff

  type
    PreemptStressCtx = object
      stack: ptr TreiberStack[string]
      pushedCount: ptr Atomic[int]
      poppedCount: ptr Atomic[int]
      corruptedFound: ptr Atomic[bool]
      threadIdx: int

  proc preemptStressWorker(ctx: ptr PreemptStressCtx) {.thread.} =
    {.cast(gcsafe).}:
      ctx.stack[].registerThread()
      defer:
        ctx.stack[].unregisterThread()
      for i in 0 ..< 400:
        let msg = "thread_" & $ctx.threadIdx & "_item_" & $i & "_heap_string_payload"
        ctx.stack[].push(msg)
        discard ctx.pushedCount[].fetchAdd(1, moRelaxed)
        if (i and 3) == 0:
          schedYield()
        let peeked = ctx.stack[].peek()
        if peeked.isSome:
          let pVal = peeked.get
          if pVal.len < 14 or pVal[0 .. 6] != "thread_":
            ctx.corruptedFound[].store(true, moRelaxed)
        if (i and 1) == 0:
          schedYield()
        let popped = ctx.stack[].pop()
        if popped.isSome:
          let val = popped.get
          if val.len < 14 or val[0 .. 6] != "thread_":
            ctx.corruptedFound[].store(true, moRelaxed)
          discard ctx.poppedCount[].fetchAdd(1, moRelaxed)

  suite "TreiberStack - Preemptive SMR & Managed Payload Soundness":
    test "concurrent preemptive push/peek/pop with managed strings":
      var s = initTreiberStack[string]()
      var pushedCount: Atomic[int]
      var poppedCount: Atomic[int]
      var corruptedFound: Atomic[bool]
      pushedCount.store(0, moRelaxed)
      poppedCount.store(0, moRelaxed)
      corruptedFound.store(false, moRelaxed)

      const NumThreads = 6
      var ctxs: array[NumThreads, PreemptStressCtx]
      var threads: array[NumThreads, Thread[ptr PreemptStressCtx]]

      for i in 0 ..< NumThreads:
        ctxs[i] = PreemptStressCtx(
          stack: addr s,
          pushedCount: addr pushedCount,
          poppedCount: addr poppedCount,
          corruptedFound: addr corruptedFound,
          threadIdx: i
        )
        createThread(threads[i], preemptStressWorker, addr ctxs[i])

      for i in 0 ..< NumThreads:
        joinThread(threads[i])

      let remaining = s.drain()
      for item in remaining:
        check item.len >= 14
        check item[0 .. 6] == "thread_"

      check not corruptedFound.load(moRelaxed)
      check pushedCount.load(moRelaxed) == poppedCount.load(moRelaxed) + remaining.len
      check s.isEmpty

