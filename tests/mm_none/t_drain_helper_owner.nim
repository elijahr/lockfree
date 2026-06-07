## mm:none drain-contract per §5.7.3.
##
## Under --mm:none, drain MUST be called by the user to extract items;
## the queue's =destroy does NOT free payload bits (per §2.8 contract).
## Users who do not drain leak all unpopped pointers — the queue does
## not touch their bits.
##
## §6 O7 acknowledges mm:none test framework limitations: use doAssert
## + echo rather than unittest2.

import std/options

import lockfree/bqueue

# ---- 1. drain yields every pushed item in FIFO order -------------------
block drain_fifo:
  var q = newBQueue[int, ccSingle, ccSingle, 16, 0, 0]()
  doAssert q.push(1)
  doAssert q.push(2)
  doAssert q.push(3)
  var collected: seq[int] = @[]
  for x in drain(q):
    collected.add(x)
  doAssert collected == @[1, 2, 3]
  # Post-drain emptiness: pop must return none, and a second drain
  # must yield nothing.
  doAssert q.pop().isNone
  var second: seq[int] = @[]
  for x in drain(q):
    second.add(x)
  doAssert second == newSeq[int]()

# ---- 2. drain on already-empty queue yields nothing --------------------
block drain_empty:
  var q = newBQueue[int, ccSingle, ccSingle, 16, 0, 0]()
  var collected: seq[int] = @[]
  for x in drain(q):
    collected.add(x)
  doAssert collected == newSeq[int]()
  doAssert q.pop().isNone

# ---- 3. partial pop + drain — drain only sees unpopped items ----------
block partial_pop_then_drain:
  var q = newBQueue[int, ccSingle, ccSingle, 16, 0, 0]()
  doAssert q.push(10)
  doAssert q.push(20)
  doAssert q.push(30)
  doAssert q.push(40)
  # Pop two items normally.
  doAssert q.pop().get == 10
  doAssert q.pop().get == 20
  # Drain consumes only the remaining two, in FIFO order.
  var collected: seq[int] = @[]
  for x in drain(q):
    collected.add(x)
  doAssert collected == @[30, 40]
  doAssert q.pop().isNone

# ---- 4. items iterator (drain alias) — same contract ------------------
block items_iterator:
  var q = newBQueue[int, ccSingle, ccSingle, 16, 0, 0]()
  doAssert q.push(7)
  doAssert q.push(8)
  doAssert q.push(9)
  var collected: seq[int] = @[]
  for x in q.items:
    collected.add(x)
  doAssert collected == @[7, 8, 9]
  doAssert q.pop().isNone

echo "mm:none drain-contract OK"
