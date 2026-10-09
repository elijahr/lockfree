## Test verifying that all code snippets presented in docs/guides/user_guide.md compile and run cleanly.

import unittest2
import std/[options, os]
import lockfree

suite "User Guide Code Snippets Verification":

  test "4.1 Concurrent Table":
    var users = newTable[int, string]()
    users[101] = "Alice"
    users[102] = "Bob"
    discard users.put(103, "Charlie")

    check users[101] == "Alice"
    check users.contains(102)
    check users.get(102).get() == "Bob"

    let score = users.computeIfAbsent(104, proc(id: int): string =
      "ComputedUser_" & $id
    )
    check score == "ComputedUser_104"

    let snapshot = users.snapshot()
    users[101] = "Alice Updated"
    users.del(102)

    check snapshot.len == 4
    check snapshot.get(101).get() == "Alice"
    check users[101] == "Alice Updated"

  test "4.2 Concurrent Sorted Table":
    var leaderboard = newSortedTable[int, string]()
    leaderboard[500] = "Player Five"
    leaderboard[100] = "Player One"
    leaderboard[800] = "Player Eight"
    leaderboard[300] = "Player Three"

    check leaderboard.get(800).get() == "Player Eight"

    var sortedScores: seq[int] = @[]
    for (score, _) in leaderboard.pairs():
      sortedScores.add(score)
    check sortedScores == @[100, 300, 500, 800]
    var keysList: seq[int] = @[]
    for k in leaderboard.keys():
      keysList.add(k)
    check keysList == @[100, 300, 500, 800]

  test "4.3 Concurrent Set":
    var setA = newSet[int]()
    var setB = newSet[int]()

    setA.incl(10)
    setA.incl(20)
    setA.incl(30)

    setB.incl(20)
    setB.incl(30)
    setB.incl(40)

    check setA.contains(20)

    let common = setA.intersect(setB)
    check common.toSeq() == @[20, 30]

    let allItems = setA.union(setB)
    check allItems.toSeq() == @[10, 20, 30, 40]

    let diff = setA.difference(setB)
    check diff.toSeq() == @[10]

    check common.isSubsetOf(setA)

  test "4.4 Concurrent Stack":
    var stack = initStack[string]()
    stack.push("Item A")
    stack.push("Item B")
    stack.push("Item C")

    check stack.len == 3
    check stack.peek().get() == "Item C"

    check stack.pop().get() == "Item C"
    check stack.pop().get() == "Item B"
    check stack.pop().get() == "Item A"
    check stack.isEmpty

  test "4.5 Bounded Queue":
    var spsc = newSpscBoundedQueue[int, 16]()
    check spsc.push(100)
    check spsc.push(200)
    check spsc.pop().get() == 100

    var mpmc = newMpmcBoundedQueue[string, 64, 4, 4]()
    var producer = mpmc.getProducer(0).bindToThread()
    var consumer = mpmc.getConsumer(0).bindToThread()

    check producer.push("Message 1")
    check producer.push("Message 2")
    check consumer.pop().get() == "Message 1"

  test "4.6 Channel Facade":
    let (tx, rx) = newChannel[int](capacity = 32)
    check tx.send(100)
    check rx.recv().get() == 100
    tx.close()
    check rx.recv().isNone
    check rx.isClosed

  test "4.7 Synchronous Rendezvous Channel":
    let syncChan = initRendezvousChannel[string]()
    type SyncCtx = object
      ch: RendezvousChannel[string]

    proc waiterThread(ctx: ptr SyncCtx) {.thread.} =
      var msg: string
      let cid = ctx.ch.recv(msg)
      check msg == "Direct handoff payload"
      check cid > 0

    var ctx = SyncCtx(ch: syncChan)
    var th: Thread[ptr SyncCtx]
    createThread(th, waiterThread, addr ctx)
    sleep(10)

    let sendCid = syncChan.send("Direct handoff payload")
    check sendCid > 0
    joinThread(th)

  test "4.8 Work-Stealing TaskPool":
    var pool = initTaskPool(2)
    var ran: Atomic[bool]
    ran.store(false, moRelaxed)
    pool.spawn(proc() =
      ran.store(true, moRelease)
    )

    var numbers = newSeq[int](10)
    let arrPtr = cast[ptr UncheckedArray[int]](addr numbers[0])
    pool.parallelFor(0 .. 9, proc(i: int) =
      arrPtr[i] = (i + 1) * 2
    , chunkSize = 2)

    var leftDone: Atomic[bool]
    var rightDone: Atomic[bool]
    leftDone.store(false, moRelaxed)
    rightDone.store(false, moRelaxed)
    pool.forkJoin(
      proc() = leftDone.store(true, moRelease),
      proc() = rightDone.store(true, moRelease)
    )
    pool.sync()
    check ran.load(moAcquire) == true
    check leftDone.load(moAcquire) == true
    check rightDone.load(moAcquire) == true
    check numbers[0] == 2
    check numbers[9] == 20
    pool.shutdown(wait = true)

  test "4.9 Broadcast Ring":
    let bus = initBroadcastRing[string](capacity = 64, overflowMode = omDropOldest)
    var cursorA = bus.subscribe(soFromLatest)
    var cursorB = bus.subscribe(soFromLatest)

    bus.publish("Event 1: System Boot")
    bus.publish("Event 2: Network Ready")

    var msgA, msgB: string
    check cursorA.tryRead(msgA) and msgA == "Event 1: System Boot"
    check cursorB.tryRead(msgB) and msgB == "Event 1: System Boot"

    cursorA.unsubscribe()
    cursorB.unsubscribe()
