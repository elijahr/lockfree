## mm:none pure-bit-transport contract per §2.8 + §4.2.1.
##
## Under --mm:none, the queue transports raw bit patterns: ref T is just
## a raw pointer, incRefSlot/decRefSlot expand to discard, and the queue
## does NOT manage payload lifecycle for ref/string/seq T (caller manages).
## For POD T, behavior is identical to other MMs.
##
## §6 O7 acknowledges mm:none test framework limitations: the full
## unittest2 suite likely fails because the framework allocates. This
## file uses `doAssert` + `echo` to stay compatible with mm:none.
##
## Tests exercise the BQueue SPSC arm with several POD-ish shapes plus
## raw pointer transport — the contractually-supported mm:none cases.

import std/options

import lockfree/bqueue

# ---- 1. POD int — identical to other MMs --------------------------------
block pod_int:
  var q = newBQueue[int, ccSingle, ccSingle, 16, 0, 0]()
  doAssert q.push(42)
  doAssert q.push(-7)
  doAssert q.push(0)
  doAssert q.pop().get == 42
  doAssert q.pop().get == -7
  doAssert q.pop().get == 0
  doAssert q.pop().isNone

# ---- 2. Raw pointer transport — bit-pattern fidelity --------------------
block ptr_int:
  var a = 7
  var b = 11
  var c = 13
  var q = newBQueue[ptr int, ccSingle, ccSingle, 16, 0, 0]()
  doAssert q.push(addr a)
  doAssert q.push(addr b)
  doAssert q.push(addr c)
  let pa = q.pop().get
  let pb = q.pop().get
  let pc = q.pop().get
  # Pointer bits round-trip exactly: dereference yields original values
  # AND the pointer identity is preserved (same address back out).
  doAssert pa == addr a
  doAssert pb == addr b
  doAssert pc == addr c
  doAssert pa[] == 7
  doAssert pb[] == 11
  doAssert pc[] == 13
  doAssert q.pop().isNone

# ---- 3. Tuple of PODs — multi-field bit transport -----------------------
block pod_tuple:
  type Pair = tuple[x: int, y: int]
  var q = newBQueue[Pair, ccSingle, ccSingle, 16, 0, 0]()
  doAssert q.push((x: 1, y: 2))
  doAssert q.push((x: -3, y: 4))
  let p1 = q.pop().get
  let p2 = q.pop().get
  doAssert p1 == (x: 1, y: 2)
  doAssert p2 == (x: -3, y: 4)
  doAssert q.pop().isNone

# ---- 4. POD object — every field round-trips ----------------------------
block pod_object:
  type Rec = object
    a: int32
    b: int32
    c: uint64
  var q = newBQueue[Rec, ccSingle, ccSingle, 16, 0, 0]()
  let r1 = Rec(a: 100'i32, b: -200'i32, c: 0xDEADBEEF'u64)
  let r2 = Rec(a: 0'i32, b: 0'i32, c: 0'u64)
  doAssert q.push(r1)
  doAssert q.push(r2)
  let g1 = q.pop().get
  let g2 = q.pop().get
  doAssert g1 == r1
  doAssert g2 == r2
  doAssert q.pop().isNone

# ---- 5. FIFO order preserved across capacity-edge fills ----------------
block fifo_order_full:
  var q = newBQueue[int, ccSingle, ccSingle, 16, 0, 0]()
  # Fill to capacity (N=16). All 16 pushes must succeed.
  for i in 0 ..< 16:
    doAssert q.push(i * 3)
  # 17th push must fail (full).
  doAssert not q.push(999)
  # Pop must return exactly the FIFO sequence we pushed.
  for i in 0 ..< 16:
    doAssert q.pop().get == i * 3
  doAssert q.pop().isNone

echo "mm:none pure-bit-transport OK"
