## items / pairs iterators for Queue/BQueue (T-ITERATORS, design §5.3).
##
## `items` is the Nim-convention alias for `drain`: drain-to-empty
## destructive iteration (§5.3.2, OQ5.10 disposition: ship `items` as
## alias, document destructive semantics).
##
## `pairs` (BQueue only per §5.3.1) yields `(localOrdinal, item)` where
## localOrdinal is the drain ordinal observed by THIS iterator instance
## (OQ5.2 disposition — no global ordering for multi-consumer drains).
##
## Per AGENTS.md §3.5 slim-verification, this test file is single-MM
## (--mm:arc) and exercises bounded SPSC + MPSC + Bound SPMC/MPMC plus
## unbounded SPSC + Bound MPSC/SPMC/MPMC. Ref-T cases use single-action-
## per-test (one ref payload per test body) per the unittest2/arc
## closure-capture note in t_drain.nim.

import options
import unittest2

import lockfree/bqueue
import lockfree/queue
import lockfree/endpoint
import lockfree/role_tags
import lockfree/strategy

suite "items iterator — bounded":
  test "spsc bounded — items yields drained POD ints in FIFO order":
    var q = newBQueue[int, ccSingle, ccSingle, 16, 0, 0]()
    check q.push(1)
    check q.push(2)
    check q.push(3)
    var collected: seq[int] = @[]
    for x in items(q):
      collected.add(x)
    check collected == @[1, 2, 3]
    check q.pop().isNone

  test "spsc bounded — for-loop sugar (implicit items)":
    var q = newBQueue[int, ccSingle, ccSingle, 16, 0, 0]()
    check q.push(10)
    check q.push(20)
    var collected: seq[int] = @[]
    for x in q:
      collected.add(x)
    check collected == @[10, 20]

  test "spsc bounded — items on empty queue yields nothing":
    var q = newBQueue[int, ccSingle, ccSingle, 16, 0, 0]()
    var collected: seq[int] = @[]
    for x in items(q):
      collected.add(x)
    check collected == newSeq[int]()

  test "spsc bounded — items with string payload (Path-C)":
    var q = newBQueue[string, ccSingle, ccSingle, 16, 0, 0]()
    check q.push("alpha")
    check q.push("beta")
    var collected: seq[string] = @[]
    for s in items(q):
      collected.add(s)
    check collected == @["alpha", "beta"]

  test "spsc bounded — items with seq[int] payload":
    var q = newBQueue[seq[int], ccSingle, ccSingle, 16, 0, 0]()
    check q.push(@[1, 2])
    check q.push(@[3, 4, 5])
    var collected: seq[seq[int]] = @[]
    for s in items(q):
      collected.add(s)
    check collected == @[@[1, 2], @[3, 4, 5]]

  test "mpsc bounded — items yields FIFO":
    var q = newBQueue[int, ccMulti, ccSingle, 16, 4, 0]()
    var p = q.getProducerHere(0)
    check p.push(100)
    check p.push(200)
    var collected: seq[int] = @[]
    for x in items(q):
      collected.add(x)
    check collected == @[100, 200]

  test "spmc bounded — items via Bound consumer endpoint":
    var q = newBQueue[string, ccSingle, ccMulti, 16, 0, 4]()
    check q.push("p")
    check q.push("q")
    var c = q.getConsumerHere(0)
    var collected: seq[string] = @[]
    for s in items(c):
      collected.add(s)
    check collected == @["p", "q"]

  test "mpmc bounded — items via Bound consumer endpoint":
    var q = newBQueue[string, ccMulti, ccMulti, 16, 4, 4]()
    var p = q.getProducerHere(0)
    check p.push("x")
    check p.push("y")
    var c = q.getConsumerHere(0)
    var collected: seq[string] = @[]
    for s in items(c):
      collected.add(s)
    check collected == @["x", "y"]

suite "pairs iterator — bounded":
  test "spsc bounded — pairs yields (localOrdinal, item) tuples":
    var q = newBQueue[int, ccSingle, ccSingle, 16, 0, 0]()
    check q.push(10)
    check q.push(11)
    check q.push(12)
    var collected: seq[(int, int)] = @[]
    for idx, val in pairs(q):
      collected.add((idx, val))
    check collected == @[(0, 10), (1, 11), (2, 12)]

  test "spsc bounded — for i, x in q sugar (implicit pairs)":
    var q = newBQueue[string, ccSingle, ccSingle, 16, 0, 0]()
    check q.push("a")
    check q.push("b")
    var collected: seq[(int, string)] = @[]
    for i, s in q:
      collected.add((i, s))
    check collected == @[(0, "a"), (1, "b")]

  test "spsc bounded — pairs on empty queue yields nothing":
    var q = newBQueue[int, ccSingle, ccSingle, 16, 0, 0]()
    var collected: seq[(int, int)] = @[]
    for idx, val in pairs(q):
      collected.add((idx, val))
    check collected == newSeq[(int, int)]()

  test "mpsc bounded — pairs local-ordinal semantics":
    var q = newBQueue[int, ccMulti, ccSingle, 16, 4, 0]()
    var p = q.getProducerHere(0)
    check p.push(77)
    check p.push(88)
    var collected: seq[(int, int)] = @[]
    for idx, val in pairs(q):
      collected.add((idx, val))
    check collected == @[(0, 77), (1, 88)]

  test "spmc bounded — pairs via Bound consumer endpoint":
    var q = newBQueue[string, ccSingle, ccMulti, 16, 0, 4]()
    check q.push("first")
    check q.push("second")
    var c = q.getConsumerHere(0)
    var collected: seq[(int, string)] = @[]
    for idx, val in pairs(c):
      collected.add((idx, val))
    check collected == @[(0, "first"), (1, "second")]

  test "mpmc bounded — pairs via Bound consumer endpoint":
    var q = newBQueue[string, ccMulti, ccMulti, 16, 4, 4]()
    var p = q.getProducerHere(0)
    check p.push("u")
    check p.push("v")
    var c = q.getConsumerHere(0)
    var collected: seq[(int, string)] = @[]
    for idx, val in pairs(c):
      collected.add((idx, val))
    check collected == @[(0, "u"), (1, "v")]

suite "items iterator — unbounded":
  test "spsc unbounded — items yields FIFO":
    var q = newUnboundedSpscQueue[string, stEager, 16, 4]()
    var p = q.getProducerHere()
    p.push("alpha")
    p.push("beta")
    var collected: seq[string] = @[]
    for s in items(q):
      collected.add(s)
    check collected == @["alpha", "beta"]
    check q.pop().isNone

  test "spsc unbounded — items on empty yields nothing":
    var q = newUnboundedSpscQueue[int, stEager, 16, 4]()
    var collected: seq[int] = @[]
    for x in items(q):
      collected.add(x)
    check collected == newSeq[int]()

  test "mpsc unbounded — items via Bound consumer":
    var q = newUnboundedMpscQueue[int, stEager, 16, 4]()
    var c = q.bindConsumer()
    var p = q.getProducerHere()
    p.push(1)
    p.push(2)
    p.push(3)
    var collected: seq[int] = @[]
    for x in items(c):
      collected.add(x)
    check collected == @[1, 2, 3]

  test "spmc unbounded — items via Bound consumer":
    var q = newUnboundedSpmcQueue[string, stEager, 16, 4]()
    var p = q.getProducerHere()
    p.push("hello")
    p.push("world")
    var c = q.getConsumerHere()
    var collected: seq[string] = @[]
    for s in items(c):
      collected.add(s)
    check collected == @["hello", "world"]

  test "mpmc unbounded — items via Bound consumer":
    var q = newUnboundedMpmcQueue[string, stEager, 16, 4]()
    var p = q.getProducerHere()
    p.push("alpha")
    p.push("beta")
    var c = q.getConsumerHere()
    var collected: seq[string] = @[]
    for s in items(c):
      collected.add(s)
    check collected == @["alpha", "beta"]
