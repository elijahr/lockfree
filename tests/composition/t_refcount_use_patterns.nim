## Refcount-balance matrix: 5 use-pattern arms.
##
## Each arm verifies that ref-T increment/decrement balance after a
## push/pop round-trip in a single-threaded fixed-iteration loop.
##
## Source: addendum design §2.6 / understanding §3.C MAJOR-6 / impl
## plan task C-MAJOR-6.
##
## Queue payload type is `ref Payload` (USER-facing per design §2.2);
## the queue internally encodes as `ManagedRef[Payload]` but that is
## NEVER user-facing and not referenced here.
##
## The 5 arms cover:
##   a) `let x = q.pop().get` — let-binding pop
##   b) `var x: ref Payload; x = q.pop().get` — var-binding pop
##   c) `while r =? q.pop(): consume(r)` — loop-pop with Option
##   d) closure capture of popped ref
##   e) generic instantiation through a forwarding proc
##
## Use the SPSC-absorbed `(ccSingle, ccSingle)` shape: it is the
## simplest typedesc-only `newQueue` call site (debra-free, no manager
## ceremony). The matrix is single-threaded per addendum §2.6, so the
## cardinality choice does not affect coverage.

import std/[options, unittest]

import lockfree/queue
import lockfree/strategy
import lockfree/endpoint
import lockfree/reclamation
import lockfree/role_tags

import ./refcount_trace_shim

const N = 10_000

type
  Payload = object
    v: int

  RefPayload = ref Payload

  QSpsc = Queue[RefPayload, ccSingle, ccSingle, stEager, 64, 1]

template refcountStable(body: untyped) =
  ## Run body; assert nimIncRef and nimDecRef are balanced afterwards.
  ##
  ## Under `-d:lockfreeRefcountTrace` the shim populates real counters;
  ## otherwise both sides are zero and the assertion is trivially true
  ## (matrix runs are gated on the trace build per the impl plan).
  let incBefore = countInc()
  let decBefore = countDec()
  body
  let incAfter = countInc()
  let decAfter = countDec()
  check (incAfter - incBefore) == (decAfter - decBefore)

suite "refcount-balance matrix (ref Payload, SPSC-absorbed shape)":
  test "arm a: let x = q.pop().get":
    var q = newQueue(QSpsc)
    var p = q.getProducerHere()
    refcountStable:
      for i in 0 ..< N:
        let r = RefPayload(v: i)
        p.push(r)
        let x = q.pop().get
        discard x # sink semantics handle the release at scope end

  test "arm b: var x = q.pop().get":
    var q = newQueue(QSpsc)
    var p = q.getProducerHere()
    refcountStable:
      for i in 0 ..< N:
        var x: RefPayload
        let r = RefPayload(v: i)
        p.push(r)
        x = q.pop().get
        discard x

  test "arm c: while loop pop with Option":
    var q = newQueue(QSpsc)
    var p = q.getProducerHere()
    refcountStable:
      for i in 0 ..< N:
        let r = RefPayload(v: i)
        p.push(r)
      var popped = 0
      while true:
        let opt = q.pop()
        if opt.isNone:
          break
        let r = opt.get
        inc popped
        discard r
      check popped == N

  test "arm d: closure capture of popped ref":
    var q = newQueue(QSpsc)
    var p = q.getProducerHere()
    refcountStable:
      var sinkRef: RefPayload
      let cap = proc(r: RefPayload) =
        sinkRef = r

      for i in 0 ..< N:
        let r = RefPayload(v: i)
        p.push(r)
        cap(q.pop().get)
        sinkRef = nil # release the captured ref before next iteration

  test "arm e: generic instantiation":
    proc roundTrip[T](
        q: var Queue[T, ccSingle, ccSingle, stEager, 64, 1], v: sink T
    ): T =
      var p = q.getProducerHere()
      p.push(v)
      q.pop().get

    var q = newQueue(QSpsc)
    refcountStable:
      for i in 0 ..< N:
        let r = RefPayload(v: i)
        let popped = roundTrip(q, r)
        discard popped
