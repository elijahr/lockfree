## ==============================================================================
## Tests for Constructor Standardization, Copy-Safety, and Operator Parity
## ==============================================================================

import unittest2
import std/options

# Import top-level umbrella module to verify name collisions and export resolution
import lockfree

suite "Idiomatic Constructor Standardization & Operator Parity":

  test "Unbounded Queue constructors with default parameters":
    var q = initQueue[int, ccSingle, ccSingle]()
    var p = q.getProducerHere()
    p.push(10)
    p.push(20)
    check q.pop().get == 10
    check q.pop().get == 20

    var uq = initUnboundedQueue[int, ccSingle, ccSingle]()
    var up = uq.getProducerHere()
    up.push(99)
    check uq.pop().get == 99

    var sq = initSpscQueue[int]()
    var sp = sq.getProducerHere()
    sp.push(123)
    check sq.pop().get == 123

    var mq = initMpscQueue[int]()
    var mp = mq.getProducerHere()
    mp.push(456)
    var mc = mq.bindConsumer()
    check mc.pop().get == 456

    var spmc = initSpmcQueue[int]()
    var spmcp = spmc.getProducerHere()
    spmcp.push(789)
    var spmcc = spmc.getConsumerHere()
    check spmcc.pop().get == 789

    var mpmc = initMpmcQueue[int]()
    var mpmcp = mpmc.getProducerHere()
    mpmcp.push(111)
    var mpmcc = mpmc.getConsumerHere()
    check mpmcc.pop().get == 111

  test "Unbounded Queue new* legacy aliases with default parameters":
    var sq = newSpscQueue[int]()
    var sp = sq.getProducerHere()
    sp.push(10)
    check sq.pop().get == 10

    var mq = newMpscQueue[int]()
    var mp = mq.getProducerHere()
    mp.push(20)
    var mc = mq.bindConsumer()
    check mc.pop().get == 20

    var spmc = newSpmcQueue[int]()
    var spmcp = spmc.getProducerHere()
    spmcp.push(30)
    var spmcc = spmc.getConsumerHere()
    check spmcc.pop().get == 30

    var mpmc = newMpmcQueue[int]()
    var mpmcp = mpmc.getProducerHere()
    mpmcp.push(40)
    var mpmcc = mpmc.getConsumerHere()
    check mpmcc.pop().get == 40

  test "Bounded vs Unbounded newMpmcQueue disambiguation under umbrella import":
    # 0 static int args: matches unbounded Queue[int] with default S=64, MaxThreads=128
    var uQ = newMpmcQueue[int]()
    var uP = uQ.getProducerHere()
    uP.push(777)
    var uC = uQ.getConsumerHere()
    check uC.pop().get == 777

    # 3 static int args: matches bounded BQueue[int, ccMulti, ccMulti, 16, 4, 4]
    var bQ = newMpmcQueue[int, 16, 4, 4]()
    var bP = bQ.getProducerHere(0)
    check bP.push(888)
    var bC = bQ.getConsumerHere(0)
    check bC.pop().get == 888

  test "Bounded Queue standardized constructors":
    var bq = initBQueue[int, ccSingle, ccSingle, 16, 0, 0]()
    check bq.push(1)
    check bq.pop().get == 1

    var bndq = initBoundedQueue[int, ccSingle, ccSingle, 16, 0, 0]()
    check bndq.push(2)
    check bndq.pop().get == 2

    var spsc = initBoundedSpscQueue[int, 16]()
    check spsc.push(3)
    check spsc.pop().get == 3

    var spscNew = newBoundedSpscQueue[int, 16]()
    check spscNew.push(4)
    check spscNew.pop().get == 4

    var mpsc = initBoundedMpscQueue[int, 16, 4]()
    var mpscP = mpsc.getProducerHere(0)
    check mpscP.push(5)
    check mpsc.pop().get == 5

    var mpscNew = newBoundedMpscQueue[int, 16, 4]()
    var mpscNewP = mpscNew.getProducerHere(0)
    check mpscNewP.push(6)
    check mpscNew.pop().get == 6

    var spmc = initBoundedSpmcQueue[int, 16, 4]()
    check spmc.push(7)
    var spmcC = spmc.getConsumerHere(0)
    check spmcC.pop().get == 7

    var spmcNew = newBoundedSpmcQueue[int, 16, 4]()
    check spmcNew.push(8)
    var spmcNewC = spmcNew.getConsumerHere(0)
    check spmcNewC.pop().get == 8

    var mpmc = initBoundedMpmcQueue[int, 16, 4, 4]()
    var mpmcP = mpmc.getProducerHere(0)
    check mpmcP.push(9)
    var mpmcC = mpmc.getConsumerHere(0)
    check mpmcC.pop().get == 9

    var mpmcNew = newBoundedMpmcQueue[int, 16, 4, 4]()
    var mpmcNewP = mpmcNew.getProducerHere(0)
    check mpmcNewP.push(10)
    var mpmcNewC = mpmcNew.getConsumerHere(0)
    check mpmcNewC.pop().get == 10

  test "Queue items and pairs destructive drain iterators":
    var bq = initBoundedSpscQueue[int, 16]()
    check bq.push(100)
    check bq.push(200)
    var collectedItems: seq[int] = @[]
    for item in bq:
      collectedItems.add(item)
    check collectedItems == @[100, 200]
    check bq.pop().isNone

    check bq.push(300)
    check bq.push(400)
    var collectedPairs: seq[(int, int)] = @[]
    for idx, item in bq.pairs:
      collectedPairs.add((idx, item))
    check collectedPairs == @[(0, 300), (1, 400)]
    check bq.pop().isNone

    var uq = initSpscQueue[int]()
    var up = uq.getProducerHere()
    up.push(500)
    up.push(600)
    var uCollectedItems: seq[int] = @[]
    for item in uq:
      uCollectedItems.add(item)
    check uCollectedItems == @[500, 600]
    check uq.len == 0

    up.push(700)
    up.push(800)
    var uCollectedPairs: seq[(int, int)] = @[]
    for idx, item in uq.pairs:
      uCollectedPairs.add((idx, item))
    check uCollectedPairs == @[(0, 700), (1, 800)]
    check uq.len == 0

  test "BTable operator parity: [] and hasKey":
    var tbl = initBTable[string, int, 16]()
    tbl["alpha"] = 10
    tbl["beta"] = 20

    check tbl.hasKey("alpha") == true
    check tbl.hasKey("beta") == true
    check tbl.hasKey("gamma") == false

    check tbl["alpha"] == 10
    check tbl["beta"] == 20

    var caught = false
    try:
      discard tbl["nonexistent"]
    except KeyError:
      caught = true
    check caught == true

  test "SkipListMap operator parity: hasKey":
    var sm = initSkipListMap[string, int]()
    check sm.put("x", 1)
    check sm.put("y", 2)

    check sm.hasKey("x") == true
    check sm.hasKey("y") == true
    check sm.hasKey("z") == false

  test "PriorityQueue & BPriorityQueue template parity: pop and peek":
    var pq = initPriorityQueue[int]()
    pq.push(50)
    pq.push(10)
    pq.push(30)

    check pq.peek().get == 10
    check pq.pop().get == 10
    check pq.peek().get == 30
    check pq.pop().get == 30
    check pq.pop().get == 50
    check pq.pop().isNone

    var bpq = initBPriorityQueue[int, 16]()
    bpq.push(100)
    bpq.push(20)
    bpq.push(40)

    check bpq.peek().get == 20
    check bpq.pop().get == 20
    check bpq.peek().get == 40
    check bpq.pop().get == 40
    check bpq.pop().get == 100
    check bpq.pop().isNone

  test "All other value object constructors exist and instantiate":
    var s = initTreiberStack[int]()
    s.push(1)
    check s.pop().get == 1

    var bs = initBStack[int, 16, ccSingle, ccSingle]()
    check bs.push(2)
    check bs.pop().get == 2

    var dq = initChaseLevDeque[int]()
    dq.pushBottom(3)
    check dq.popBottom().get == 3

    var dqn = newChaseLevDeque[int]()
    dqn.pushBottom(4)
    check dqn.popBottom().get == 4

    var slSet = initSkipListSet[int]()
    slSet.incl(5)
    check slSet.contains(5) == true
