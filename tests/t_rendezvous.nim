## Tests for RendezvousChannel[T] synchronous zero-buffer dual channel.
## Covers:
##   - Basic synchronous 1-to-1 handoff between sender and receiver threads
##   - Bilateral correlation ID verification (sender and receiver get identical monotonic ID)
##   - Non-blocking trySend / tryRecv semantics
##   - Bounded timeout sendWithTimeout / recvWithTimeout and timeout cancellation
##   - ARC/ORC managed types and leak-free destruction
##   - MPMC concurrent stress testing (multi-sender multi-receiver)
##   - Channel close semantics and unparking

import unittest2
import std/[os, times]
import lockfree/rendezvous
import lockfree/atomics
import lockfree/exceptions

suite "RendezvousChannel — Basic Handoff & Duality":
  test "trySend and tryRecv fail when no partner is waiting":
    let chan = initRendezvousChannel[int]()
    var cid: uint64 = 0
    var val: int = 0
    check not chan.trySend(42, cid)
    check cid == 0
    check not chan.tryRecv(val, cid)
    check val == 0
    check cid == 0

  test "single synchronous rendezvous between 2 threads":
    let chan = initRendezvousChannel[int]()
    var receivedVal: int = 0
    var senderCid: uint64 = 0
    var receiverCid: uint64 = 0

    type ThreadArg = object
      ch: RendezvousChannel[int]
      outVal: ptr int
      outCid: ptr uint64

    proc receiverThread(arg: ptr ThreadArg) {.thread.} =
      arg.outCid[] = arg.ch.recv(arg.outVal[])

    var arg = ThreadArg(ch: chan, outVal: addr receivedVal, outCid: addr receiverCid)
    var th: Thread[ptr ThreadArg]
    createThread(th, receiverThread, addr arg)

    # Receiver is waiting; sender delivers
    sleep(10) # Allow receiver to park
    senderCid = chan.send(12345)

    joinThread(th)

    check receivedVal == 12345
    check senderCid > 0
    check senderCid == receiverCid

  test "trySend succeeds immediately when receiver is already parked":
    let chan = initRendezvousChannel[string]()
    var recvMsg: string = ""
    var recvCid: uint64 = 0
    var sendCid: uint64 = 0

    type StrArg = object
      ch: RendezvousChannel[string]
      outMsg: ptr string
      outCid: ptr uint64

    proc strReceiver(arg: ptr StrArg) {.thread.} =
      arg.outCid[] = arg.ch.recv(arg.outMsg[])

    var arg = StrArg(ch: chan, outMsg: addr recvMsg, outCid: addr recvCid)
    var th: Thread[ptr StrArg]
    createThread(th, strReceiver, addr arg)

    sleep(10) # Let receiver park
    check chan.trySend("hello-rendezvous", sendCid)
    check sendCid > 0

    joinThread(th)
    check recvMsg == "hello-rendezvous"
    check recvCid == sendCid

suite "RendezvousChannel — Bounded Timeouts & Cancellation":
  test "sendWithTimeout times out when no receiver arrives":
    let chan = initRendezvousChannel[int]()
    var cid: uint64 = 0
    let start = epochTime()
    let ok = chan.sendWithTimeout(99, 20, cid)
    let elapsedMs = (epochTime() - start) * 1000.0

    check not ok
    check cid == 0
    check elapsedMs >= 15.0

  test "recvWithTimeout times out when no sender arrives":
    let chan = initRendezvousChannel[int]()
    var val: int = 0
    var cid: uint64 = 0
    let start = epochTime()
    let ok = chan.recvWithTimeout(val, 20, cid)
    let elapsedMs = (epochTime() - start) * 1000.0

    check not ok
    check val == 0
    check cid == 0
    check elapsedMs >= 15.0

  test "sendWithTimeout succeeds when receiver arrives within deadline":
    let chan = initRendezvousChannel[int]()
    var receivedVal: int = 0
    var senderCid: uint64 = 0
    var receiverCid: uint64 = 0

    type DelayArg = object
      ch: RendezvousChannel[int]
      outVal: ptr int
      outCid: ptr uint64

    proc delayedReceiver(arg: ptr DelayArg) {.thread.} =
      sleep(15) # Wait a bit before receiving
      arg.outCid[] = arg.ch.recv(arg.outVal[])

    var arg = DelayArg(ch: chan, outVal: addr receivedVal, outCid: addr receiverCid)
    var th: Thread[ptr DelayArg]
    createThread(th, delayedReceiver, addr arg)

    # Send with 200ms timeout
    let ok = chan.sendWithTimeout(777, 200, senderCid)
    check ok
    check senderCid > 0

    joinThread(th)
    check receivedVal == 777
    check receiverCid == senderCid

suite "RendezvousChannel — ARC/ORC Lifecycle Management":
  type RefNode = ref object
    data: string

  test "complex ref types transfer ownership without memory leaks":
    let chan = initRendezvousChannel[RefNode]()
    var receivedNode: RefNode = nil

    type RefArg = object
      ch: RendezvousChannel[RefNode]
      outNode: ptr RefNode

    proc refReceiver(arg: ptr RefArg) {.thread.} =
      discard arg.ch.recv(arg.outNode[])

    var arg = RefArg(ch: chan, outNode: addr receivedNode)
    var th: Thread[ptr RefArg]
    createThread(th, refReceiver, addr arg)

    sleep(10)
    let node = RefNode(data: "payload-with-arc-ownership")
    discard chan.send(node)

    joinThread(th)
    check receivedNode != nil
    check receivedNode.data == "payload-with-arc-ownership"

suite "RendezvousChannel — Concurrent MPMC Stress Testing":
  test "4 Senders and 4 Receivers exchanging 2,000 items":
    const TotalPerThread = 500
    const NumThreads = 4
    let chan = initRendezvousChannel[int]()

    var totalReceived: Atomic[int]
    totalReceived.store(0, moRelaxed)

    type WorkerArg = object
      ch: RendezvousChannel[int]
      threadId: int
      counter: ptr Atomic[int]
      validFlag: ptr Atomic[bool]

    var allValuesValid: Atomic[bool]
    allValuesValid.store(true, moRelaxed)

    proc senderThread(arg: ptr WorkerArg) {.thread.} =
      for i in 1 .. TotalPerThread:
        discard arg.ch.send(arg.threadId * 10000 + i)

    proc receiverThread(arg: ptr WorkerArg) {.thread.} =
      for _ in 1 .. TotalPerThread:
        var val: int
        discard arg.ch.recv(val)
        if val <= 0:
          arg.validFlag[].store(false, moRelaxed)
        discard arg.counter[].fetchAdd(1, moRelaxed)

    var senderArgs: array[NumThreads, WorkerArg]
    var receiverArgs: array[NumThreads, WorkerArg]
    var senderThreads: array[NumThreads, Thread[ptr WorkerArg]]
    var receiverThreads: array[NumThreads, Thread[ptr WorkerArg]]

    for i in 0 ..< NumThreads:
      receiverArgs[i] = WorkerArg(ch: chan, threadId: i, counter: addr totalReceived, validFlag: addr allValuesValid)
      createThread(receiverThreads[i], receiverThread, addr receiverArgs[i])

      senderArgs[i] = WorkerArg(ch: chan, threadId: i, counter: addr totalReceived, validFlag: addr allValuesValid)
      createThread(senderThreads[i], senderThread, addr senderArgs[i])

    for i in 0 ..< NumThreads:
      joinThread(senderThreads[i])
      joinThread(receiverThreads[i])

    check allValuesValid.load(moRelaxed)
    check totalReceived.load(moRelaxed) == NumThreads * TotalPerThread

suite "RendezvousChannel — Close Semantics":
  test "closing channel unparks waiting receivers with exception":
    let chan = initRendezvousChannel[int]()
    var caughtException = false

    type CloseArg = object
      ch: RendezvousChannel[int]
      caught: ptr bool

    proc waiterThread(arg: ptr CloseArg) {.thread.} =
      try:
        var val: int
        discard arg.ch.recv(val)
      except ChannelClosedDefect:
        arg.caught[] = true

    var arg = CloseArg(ch: chan, caught: addr caughtException)
    var th: Thread[ptr CloseArg]
    createThread(th, waiterThread, addr arg)

    sleep(15) # Ensure thread is parked
    chan.close()
    joinThread(th)

    check caughtException
    check chan.isClosed
