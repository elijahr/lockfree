## Dual-API: withBoundEndpoint RAII template + Queueable[T] concept.
##
## Per design §5.5. Both surfaces
## must work uniformly across the full Path-C-encoded payload set
## (ref / string / seq / POD) per operator directive 2026-06-06.

import std/atomics
import std/bitops
import options
import unittest2

import lockfree
import lockfree/bqueue
import lockfree/queue
import lockfree/endpoint
import lockfree/strategy
import lockfree/typestates/with_bound

from lockfree/smr/nebr import DebraManager
import ./debra_cc_helpers

type Foo = object
  v: int

# ---------------------------------------------------------------------------
# withBoundEndpoint RAII template — covers cardinalities that require bind.
# ---------------------------------------------------------------------------

suite "withBoundProducer / withBoundConsumer RAII":
  test "BQueue MPSC — POD push via withBoundProducer":
    var q = newBQueue[int, ccMulti, ccSingle, 16, 4, 0]()
    withBoundProducer(q, p):
      check p.push(42)
      check p.push(43)
    check q.pop() == some(42)
    check q.pop() == some(43)
    check q.pop().isNone

  test "BQueue SPMC — POD pop via withBoundConsumer":
    var q = newBQueue[int, ccSingle, ccMulti, 16, 0, 4]()
    check q.push(7)
    check q.push(8)
    withBoundConsumer(q, c):
      check c.pop() == some(7)
      check c.pop() == some(8)
      check c.pop().isNone

  test "BQueue MPMC — RAII round-trip":
    var q = newBQueue[int, ccMulti, ccMulti, 16, 4, 4]()
    withBoundProducer(q, p):
      check p.push(11)
    withBoundConsumer(q, c):
      check c.pop() == some(11)
      check c.pop().isNone

  test "Path-C ref T — BQueue MPSC via RAII":
    var q = newBQueue[ref Foo, ccMulti, ccSingle, 16, 4, 0]()
    let f: ref Foo = new(Foo)
    f.v = 9
    withBoundProducer(q, p):
      check p.push(f)
    let popped = q.pop()
    check popped.isSome
    check popped.get.v == 9

  test "Path-C string — BQueue MPSC via RAII":
    var q = newBQueue[string, ccMulti, ccSingle, 16, 4, 0]()
    withBoundProducer(q, p):
      check p.push("hello")
    let popped = q.pop()
    check popped == some("hello")

  test "Path-C seq[U] — BQueue MPSC via RAII":
    var q = newBQueue[seq[int], ccMulti, ccSingle, 16, 4, 0]()
    withBoundProducer(q, p):
      check p.push(@[1, 2, 3])
    let popped = q.pop()
    check popped == some(@[1, 2, 3])

  test "Path-C ref T — BQueue MPMC RAII round-trip":
    var q = newBQueue[ref Foo, ccMulti, ccMulti, 16, 4, 4]()
    let f: ref Foo = new(Foo)
    f.v = 17
    withBoundProducer(q, p):
      check p.push(f)
    withBoundConsumer(q, c):
      let popped = c.pop()
      check popped.isSome
      check popped.get.v == 17

  # -------------------------------------------------------------------------
  # RAII re-bind contract.
  #
  # The earlier tests above all push inside `withBound...` then read OUTSIDE
  # the block via bare `q.pop()` / `q.push()`. They never re-bind through a
  # second `withBound...` call after the first scope exits.
  #
  # These tests use a single-slot pool (P=1 / C=1) and re-bind a second time
  # after the first scope exits, pinning the contract that the RAII surface
  # admits sequential re-bind from the same thread.
  #
  # NOTE on the mutation check: removing `defer: close()`
  # from the BQueue overloads in `src/lockfree/typestates/with_bound.nim`
  # leaves these tests GREEN. That is not a mirage in these tests — it is an
  # architectural property of BQueue:
  #   * `endpoint.close()` for BQueue is a typestate-only no-op (see the
  #     `proc close*` docstring in `src/lockfree/endpoint.nim`).
  #   * `getProducer` / `getConsumer` are keyed by `getThreadId()`, so the
  #     same thread re-acquires the same slot on re-bind regardless of
  #     whether the prior endpoint was closed.
  # The Queue (unbounded) overload of `close()` DOES do real work (debra
  # `unregisterThread`); that release contract is pinned directly and
  # deterministically by the "withBound RAII release contract (unbounded
  # Queue, T2-005)" suite below, which reads the manager's
  # `activeThreadMask` before/after each scope and asserts the bit is
  # cleared on exit (mutation-twin verified: dropping `defer: close()`
  # from the Queue overloads makes that suite FAIL).
  # -------------------------------------------------------------------------

  test "withBoundProducer re-bind contract: sequential bind succeeds":
    var q = newBQueue[int, ccMulti, ccSingle, 16, 1, 0]()  # P=1 producer slot
    withBoundProducer(q, p1):
      check p1.push(1)
    # If p1's defer didn't fire, the producer slot pool is exhausted; the
    # re-bind below would fail to acquire a fresh slot.
    withBoundProducer(q, p2):
      check p2.push(2)
    check q.pop() == some(1)
    check q.pop() == some(2)
    check q.pop().isNone

  test "withBoundConsumer re-bind contract: sequential bind succeeds":
    var q = newBQueue[int, ccSingle, ccMulti, 16, 0, 1]()  # C=1 consumer slot
    check q.push(42)
    check q.push(99)
    var first, second: int
    withBoundConsumer(q, c1):
      first = c1.pop().get
    # Same re-bind verification on the consumer side.
    withBoundConsumer(q, c2):
      second = c2.pop().get
    check first == 42
    check second == 99

# ---------------------------------------------------------------------------
# withBound RAII RELEASE contract (unbounded Queue) — T2-005.
#
# The re-bind tests above cannot detect a withBound that fails to release,
# because BQueue's close() is a typestate-only no-op and getProducer is
# keyed by getThreadId() (same thread re-acquires the same slot). For a
# REAL release assertion we use the unbounded Queue path, whose close()
# does actual work: it calls `unregisterThread`, clearing the calling
# thread's bit in the debra manager's `activeThreadMask`.
#
# We construct an unbounded MPMC Queue with a BORROWED manager so the test
# can read `manager.activeThreadMask` directly. The RAII template
# `withBoundProducer` / `withBoundConsumer` registers the thread on
# bindToThread (sets a mask bit) and MUST clear it on scope exit via
# `defer: close()`. We assert the set-bit population returns to its
# baseline after each scope — a release that did not fire leaves the bit
# set and the post-scope popcount stays elevated.
#
# MUTATION TWIN (verified manually, reverted): removing `defer: close()`
# from the Queue overloads of `withBoundProducer`/`withBoundConsumer` in
# `src/lockfree/typestates/with_bound.nim` leaves the bit set after scope
# exit, so `activeBits() == baseline` FAILS. This is the cross-thread
# release contract the BQueue re-bind tests structurally cannot pin.
# ---------------------------------------------------------------------------

proc activeBits(mgr: var DebraManager): int =
  ## Population count of the manager's active-thread mask: the number of
  ## currently-registered threads. Returns to baseline once every bound
  ## endpoint has released (unregistered) on scope exit.
  countSetBits(mgr.activeThreadMask.load())

suite "withBound RAII release contract (unbounded Queue, T2-005)":
  test "withBoundProducer releases the debra slot on scope exit":
    const MaxThreads = 16
    var manager = initMultiConsumerManager[MaxThreads]()
    var q = newUnboundedMpmcQueue[int, stEager, 16, MaxThreads](addr manager)

    let baseline = activeBits(manager)
    withBoundProducer(q, p):
      p.push(1)
      p.push(2)
      # Inside the scope the producer thread is registered: the mask must
      # carry at least one more set bit than the baseline.
      check activeBits(manager) > baseline
    # After scope exit the deferred close() must have unregistered the
    # thread, returning the active-bit population to baseline.
    check activeBits(manager) == baseline

  test "withBoundConsumer releases the debra slot on scope exit":
    const MaxThreads = 16
    var manager = initMultiConsumerManager[MaxThreads]()
    var q = newUnboundedMpmcQueue[int, stEager, 16, MaxThreads](addr manager)

    # Seed two items via a producer scope that itself releases.
    block:
      withBoundProducer(q, p):
        p.push(10)
        p.push(20)

    let baseline = activeBits(manager)
    withBoundConsumer(q, c):
      check activeBits(manager) > baseline
      check c.pop().isSome
    check activeBits(manager) == baseline

  test "sequential producer + consumer scopes each return mask to baseline":
    const MaxThreads = 16
    var manager = initMultiConsumerManager[MaxThreads]()
    var q = newUnboundedMpmcQueue[int, stEager, 16, MaxThreads](addr manager)

    let baseline = activeBits(manager)
    withBoundProducer(q, p):
      p.push(7)
    check activeBits(manager) == baseline
    withBoundConsumer(q, c):
      check c.pop() == some(7)
    check activeBits(manager) == baseline

# ---------------------------------------------------------------------------
# Queueable[T] concept — non-typestate-aware ergonomic surface.
# ---------------------------------------------------------------------------

suite "Queueable[T] concept":
  test "BQueue SPSC[int] satisfies Queueable":
    var q = newBQueue[int, ccSingle, ccSingle, 16, 0, 0]()
    proc roundTrip[Q](qref: var Q): int =
      discard qref.push(99)
      qref.pop().get
    check roundTrip(q) == 99
    # Static concept check at the call site.
    static:
      doAssert (BQueue[int, ccSingle, ccSingle, 16, 0, 0]) is Queueable[int]

  test "BQueue SPSC[string] (Path-C string) satisfies Queueable":
    var q = newBQueue[string, ccSingle, ccSingle, 16, 0, 0]()
    proc roundTrip[Q](qref: var Q): string =
      discard qref.push("hi")
      qref.pop().get
    check roundTrip(q) == "hi"
    static:
      doAssert (BQueue[string, ccSingle, ccSingle, 16, 0, 0]) is Queueable[string]

  test "BQueue SPSC[seq[int]] (Path-C seq) satisfies Queueable":
    var q = newBQueue[seq[int], ccSingle, ccSingle, 16, 0, 0]()
    proc roundTrip[Q](qref: var Q): seq[int] =
      discard qref.push(@[4, 5])
      qref.pop().get
    check roundTrip(q) == @[4, 5]
    static:
      doAssert (BQueue[seq[int], ccSingle, ccSingle, 16, 0, 0]) is Queueable[seq[int]]

  test "BQueue SPSC[ref Foo] (Path-C ref) satisfies Queueable":
    var q = newBQueue[ref Foo, ccSingle, ccSingle, 16, 0, 0]()
    proc roundTrip[Q](qref: var Q): int =
      let f: ref Foo = new(Foo)
      f.v = 33
      discard qref.push(f)
      qref.pop().get.v
    check roundTrip(q) == 33
    static:
      doAssert (BQueue[ref Foo, ccSingle, ccSingle, 16, 0, 0]) is Queueable[ref Foo]

  test "Queue unbounded SPSC — does NOT satisfy Queueable (no direct push)":
    static:
      doAssert not ((Queue[int, ccSingle, ccSingle, stEager, 16, 4]) is Queueable[int])

# ---------------------------------------------------------------------------
# Universal Typestate & RAII Coverage: TreiberStack, BStack, ChaseLevDeque, BTable
# ---------------------------------------------------------------------------

type
  OrderObj = object of RootObj
    orderId: int
    symbol: string
    fills: seq[int]

  OrderRecord = ref OrderObj

  OrderDraft = distinct OrderRecord
  OrderValidated = distinct OrderRecord
  OrderSettled = distinct OrderRecord

proc newOrderRecord(orderId: int, symbol: string, fills: seq[int]): OrderRecord =
  OrderRecord(orderId: orderId, symbol: symbol, fills: fills)

proc `==`(a, b: OrderRecord): bool =
  if a.isNil and b.isNil:
    return true
  if a.isNil or b.isNil:
    return false
  a.orderId == b.orderId and a.symbol == b.symbol and a.fills == b.fills

typestate OrderDomainMachine:
  consumeOnTransition = false
  strictTransitions = true
  inheritsFromRootObj = true
  states:
    OrderDraft
    OrderValidated
    OrderSettled
  initial:
    OrderDraft
  terminal:
    OrderSettled
  transitions:
    OrderDraft -> OrderValidated
    OrderValidated -> OrderSettled

proc validateOrder(d: sink OrderDraft): OrderValidated {.transition, gcsafe.} =
  OrderRecord(d).fills.add(100)
  result = OrderValidated(OrderRecord(move(d)))

proc settleOrder(v: sink OrderValidated): OrderSettled {.transition, gcsafe.} =
  OrderRecord(v).fills.add(200)
  result = OrderSettled(OrderRecord(move(v)))

suite "Universal Typestates — TreiberStack, BStack, ChaseLevDeque, BTable":
  test "TreiberStack — withBoundProducer / withBoundConsumer & NEBR active thread release":
    var s = initTreiberStack[string]()
    let baseCount = s.activeThreadCount()
    withBoundProducer(s, prod):
      check s.activeThreadCount() == baseCount + 1
      prod.push("alpha")
      prod.push("beta")
      check prod.len == 2
    check s.activeThreadCount() == baseCount

    withBoundConsumer(s, cons):
      check s.activeThreadCount() == baseCount + 1
      check cons.peek() == some("beta")
      check cons.pop() == some("beta")
      check cons.pop() == some("alpha")
      check cons.pop() == none(string)
    check s.activeThreadCount() == baseCount

  test "BStack — withBoundProducer / withBoundConsumer & Stackable[T] concept":
    var bs = initBStack[seq[int], 8]()
    withBoundProducer(bs, prod):
      check prod.tryPush(@[10, 20])
      check prod.push(@[30, 40])
      check prod.len == 2
      check prod.capacity == 8

    withBoundConsumer(bs, cons):
      check cons.peek() == some(@[30, 40])
      var outSeq: seq[int]
      check cons.tryPop(outSeq)
      check outSeq == @[30, 40]
      check cons.pop() == some(@[10, 20])
      check cons.pop() == none(seq[int])

    proc stackRoundTrip[S: Stackable[int]](st: var S, v: int): Option[int] =
      discard st.push(v)
      st.pop()

    var bsInt = initBStack[int, 8]()
    check stackRoundTrip(bsInt, 77) == some(77)

  test "ChaseLevDeque — withBoundOwner / withBoundThief & Stealable[T] concept":
    var d = initChaseLevDeque[string](16)
    withBoundOwner(d, owner):
      owner.pushBottom("task-1")
      owner.pushBottom("task-2")
      owner.pushBottom("task-3")
      check owner.len == 3
      # Owner pops LIFO from bottom:
      check owner.popBottom() == some("task-3")

    withBoundThief(d, thief):
      # Thief steals FIFO from top:
      check thief.steal() == some("task-1")
      var stolen = ""
      check thief.trySteal(stolen)
      check stolen == "task-2"
      check thief.steal() == none(string)

  test "BTable — withBoundWriter / withBoundReader & TableReadable/TableWritable concepts":
    var tbl = initBTable[string, seq[int], 16]()
    withBoundWriter(tbl, writer):
      check writer.put("k1", @[1, 2])
      check writer.tryInsert("k2", @[3, 4])
      check not writer.tryInsert("k1", @[9, 9])
      check writer.len == 2
      check writer.get("k1") == some(@[1, 2])

    withBoundReader(tbl, reader):
      check reader.contains("k1")
      check reader.contains("k2")
      check not reader.contains("k3")
      check reader.get("k2") == some(@[3, 4])
      var v: seq[int]
      check reader.tryGet("k1", v)
      check v == @[1, 2]

    withBoundWriter(tbl, writer):
      check writer.take("k1") == some(@[1, 2])
      check writer.remove("k2")
      check writer.isEmpty

suite "Domain Typestate Constructs — TypestateGate & TypestatePipelineStage":
  test "TypestateGate transitions OrderDraft -> OrderValidated across SPSC BQueue with ARC/ORC payloads":
    var q = newBQueue[OrderRecord, ccSingle, ccSingle, 16, 0, 0]()
    var gate = initTypestateGate[OrderRecord, OrderDraft, OrderValidated, typeof(q)](q)

    var draft = OrderDraft(OrderRecord(orderId: 501, symbol: "NVDA", fills: @[10, 20]))
    check gate.trySendState(move(draft))

    let validatedOpt = gate.recvState()
    check validatedOpt.isSome
    let settled = settleOrder(validatedOpt.get())
    let finalRec = OrderRecord(settled)
    check finalRec == OrderRecord(orderId: 501, symbol: "NVDA", fills: @[10, 20, 200])

  test "TypestateGate works over ChaseLevDeque owner pushBottom and thief stealState":
    var d = initChaseLevDeque[OrderRecord](16)
    var gate = initTypestateGate[OrderRecord, OrderDraft, OrderValidated, typeof(d)](d)

    check gate.sendState(OrderDraft(OrderRecord(orderId: 901, symbol: "AAPL", fills: @[5])))
    let stolenOpt = gate.stealState()
    check stolenOpt.isSome
    let settled = settleOrder(stolenOpt.get())
    check OrderRecord(settled) == OrderRecord(orderId: 901, symbol: "AAPL", fills: @[5, 200])

  test "TypestatePipelineStage chains OrderDraft -> OrderValidated -> OrderSettled across two queues":
    var qIn = newBQueue[OrderRecord, ccSingle, ccSingle, 16, 0, 0]()
    var qOut = newBQueue[OrderRecord, ccSingle, ccSingle, 16, 0, 0]()

    var ingressGate = initTypestateGate[OrderRecord, OrderDraft, OrderDraft, typeof(qIn)](qIn)
    var stage = initTypestatePipelineStage[
      OrderRecord,
      OrderDraft,
      OrderValidated,
      OrderSettled,
      typeof(qIn),
      typeof(qOut)
    ](qIn, qOut)
    var egressGate = initTypestateGate[OrderRecord, OrderSettled, OrderSettled, typeof(qOut)](qOut)

    check ingressGate.trySendState(OrderDraft(OrderRecord(orderId: 777, symbol: "MSFT", fills: @[1])))
    check stage.stepStage(validateOrder)

    let outOpt = egressGate.recvState()
    check outOpt.isSome
    check OrderRecord(outOpt.get()) == OrderRecord(orderId: 777, symbol: "MSFT", fills: @[1, 100])
    # Empty inbound returns false cleanly:
    check not stage.stepStage(validateOrder)

verifyTypestates()

