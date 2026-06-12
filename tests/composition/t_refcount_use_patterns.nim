## Refcount-balance matrix: 5 drained use-pattern arms + 1 residual arm.
##
## §2.6 Amendment (2026-06-12): the original `incRefSlot == decRefSlot`
## per-popped-item invariant is unmeasurable by the trace shim (popped
## items are released by the COMPILER-emitted `=destroy` on the caller
## binding, invisible to the shim; library `decRefSlot` fires only on
## the destroy-walk for residual slots). Reframed to the CONSERVATION
## law `incRefSlot == poppedCount + decRefSlot`, with the residual arm
## additionally asserting `decRefSlot == residual`. See
## `refcountConservation` below.
##
## Source: addendum design §2.6 (+ 2026-06-12 amendment) / understanding
## §3.C MAJOR-6 / impl plan task C-MAJOR-6.
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

template refcountConservation(
    pushed, popped, residual: int, body: untyped
) =
  ## Run `body` (which owns a queue in an inner scope that closes before
  ## this template reads the counters), then assert the library-refcount
  ## CONSERVATION law the trace shim can observe.
  ##
  ## Fix 2 / §2.6 Amendment (2026-06-12): the original §2.6 invariant
  ## `incRefSlot == decRefSlot` per popped item is UNMEASURABLE by the
  ## shim. Push runs exactly one library `incRefSlot` (GC_ref). Pop is a
  ## pure destructive bit-cast — it runs NO library `decRefSlot`; the
  ## +1 it hands to the caller binding is released later by the
  ## COMPILER-emitted `=destroy` on that binding, which the shim cannot
  ## see. Library `decRefSlot` fires ONLY on the destroy-walk
  ## (`disposeSlotEncoded`, `internal/path_c_wrap.nim`) for slots still
  ## resident when the queue is destroyed. So for a fully-drained queue
  ## library `dec` is always 0.
  ##
  ## The reframed invariant is the CONSERVATION law the shim CAN observe
  ## and that proves the same no-leak / no-double-free property:
  ##
  ##   incRefSlot == poppedCount + decRefSlot
  ##
  ## i.e. every push is accounted for — released either by the caller on
  ## pop (`poppedCount`) or by the destroy-walk for residual slots
  ## (`decRefSlot`). Additionally `decRefSlot == residual`: the
  ## destroy-walk releases every un-popped pin exactly once.
  ##
  ## The assertion is REAL only under `-d:lockfreeRefcountTrace`, where
  ## the shim counters are wired to the `incRefSlot` / `decRefSlot`
  ## shims in `src/lockfree/managed_ref.nim`. In the plain umbrella
  ## build the counters are no-ops, so instead of silently passing a
  ## 0==0 tautology we emit a VISIBLE skip notice. The real gate runs
  ## via the `testRefcountTrace` nimble task.
  when defined(lockfreeRefcountTrace):
    # Counters are cumulative across arms in one process; reset to a
    # clean snapshot so each arm reads its own deltas as absolutes.
    resetCounters()
    body
    # `body` has exited, so the queue it owned has been destroyed and
    # the destroy-walk's `decRefSlot` calls (one per residual slot) are
    # now reflected in the counters. Read AFTER the queue scope closes.
    let incCount = countInc()
    let decCount = countDec()
    # Conservation: every push is released exactly once, by the caller
    # on pop or by the destroy-walk for residual slots.
    check incCount == popped + decCount
    # Every push ran exactly one library inc.
    check incCount == pushed
    # The destroy-walk released every un-popped pin exactly once.
    check decCount == residual
  else:
    body
    # Visible, unconditional notice (echo prints regardless of pass/skip
    # status, unlike `checkpoint` which only surfaces on failure) so the
    # plain umbrella run cannot masquerade as a passing real assertion.
    echo "SKIPPED: refcount balance requires -d:lockfreeRefcountTrace " &
      "(run `nimble testRefcountTrace` for the real assertion)"
    skip()

suite "refcount-balance matrix (ref Payload, SPSC-absorbed shape)":
  # Drained arms (a-e): push N, pop N, queue empty at destroy. Conservation
  # holds as `inc == popped + 0` (residual == 0, so dec == 0) — proving
  # popped items cause NO spurious library dec (= no double-free).
  test "arm a: let x = q.pop().get":
    # `pushed = N`, `popped = N`, `residual = 0` (fully drained).
    refcountConservation(N, N, 0):
      block:
        var q = newQueue(QSpsc)
        var p = q.getProducerHere()
        for i in 0 ..< N:
          let r = RefPayload(v: i)
          p.push(r)
          let x = q.pop().get
          discard x # sink semantics handle the release at scope end

  test "arm b: var x = q.pop().get":
    refcountConservation(N, N, 0):
      block:
        var q = newQueue(QSpsc)
        var p = q.getProducerHere()
        for i in 0 ..< N:
          var x: RefPayload
          let r = RefPayload(v: i)
          p.push(r)
          x = q.pop().get
          discard x

  test "arm c: while loop pop with Option":
    var popped = 0
    refcountConservation(N, N, 0):
      block:
        var q = newQueue(QSpsc)
        var p = q.getProducerHere()
        for i in 0 ..< N:
          let r = RefPayload(v: i)
          p.push(r)
        while true:
          let opt = q.pop()
          if opt.isNone:
            break
          let r = opt.get
          inc popped
          discard r
    check popped == N

  test "arm d: closure capture of popped ref":
    refcountConservation(N, N, 0):
      block:
        var q = newQueue(QSpsc)
        var p = q.getProducerHere()
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

    refcountConservation(N, N, 0):
      block:
        var q = newQueue(QSpsc)
        for i in 0 ..< N:
          let r = RefPayload(v: i)
          let popped = roundTrip(q, r)
          discard popped

  # Residual arm (REQUIRED): push K, pop P < K, leave residual = K - P
  # items in the queue. The queue destroys at the inner-block exit; the
  # destroy-walk runs `decRefSlot` once per residual slot. Asserts BOTH
  # `inc == popped + dec` (conservation) AND `dec == residual` — proving
  # the destroy-walk releases every un-popped pin exactly once (no leak).
  test "arm f: residual slots released by destroy-walk":
    const
      K = 40 # pushed (fits the 64-slot SPSC bound)
      P = 15 # popped
      R = K - P # residual left resident at queue destroy
    var popped = 0
    refcountConservation(K, P, R):
      block:
        var q = newQueue(QSpsc)
        var p = q.getProducerHere()
        for i in 0 ..< K:
          let r = RefPayload(v: i)
          p.push(r)
        for _ in 0 ..< P:
          let r = q.pop().get
          inc popped
          discard r
    check popped == P
