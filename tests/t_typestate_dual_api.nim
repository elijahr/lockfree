## Dual-API: withBoundEndpoint RAII template + Queueable[T] concept.
##
## Per T-TYPESTATE-DUAL-API (design §5.5, impl plan PG-7). Both surfaces
## must work uniformly across the full Path-C-encoded payload set
## (ref / string / seq / POD) per operator directive 2026-06-06.

import options
import unittest2

import lockfree
import lockfree/bqueue
import lockfree/queue
import lockfree/endpoint
import lockfree/role_tags
import lockfree/strategy
import lockfree/typestates/with_bound

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
  # RAII re-bind contract (Phase 4.6.3 green-mirage finding #5).
  #
  # The earlier tests above all push inside `withBound...` then read OUTSIDE
  # the block via bare `q.pop()` / `q.push()`. They never re-bind through a
  # second `withBound...` call after the first scope exits.
  #
  # These tests use a single-slot pool (P=1 / C=1) and re-bind a second time
  # after the first scope exits, pinning the contract that the RAII surface
  # admits sequential re-bind from the same thread.
  #
  # NOTE on the mutation check (Phase 4.6 fix-pass): removing `defer: close()`
  # from the BQueue overloads in `src/lockfree/typestates/with_bound.nim`
  # leaves these tests GREEN. That is not a mirage in these tests — it is an
  # architectural property of BQueue:
  #   * `endpoint.close()` for BQueue is a typestate-only no-op (see the
  #     `proc close*` docstring in `src/lockfree/endpoint.nim`).
  #   * `getProducer` / `getConsumer` are keyed by `getThreadId()`, so the
  #     same thread re-acquires the same slot on re-bind regardless of
  #     whether the prior endpoint was closed.
  # The Queue (unbounded) overload of `close()` DOES do real work (debra
  # `unregisterThread`); the cross-thread RAII contract is exercised
  # implicitly by `tests/t_unbounded_mpmc_threaded.nim` and the chronos
  # suite, which run long enough to expose debra-guard leaks.
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
    # Unbounded Queue routes ALL push/pop through Bound endpoints (no
    # direct push on bare Queue, even for SPSC). Per §5.5.5, Queueable
    # matches bare types that have direct push/pop — that's bare BQueue
    # SPSC only. For unbounded queues, the typestate-guarded API
    # (getProducer + bindToThread) or the RAII surface is required.
    # This test pins the contract: the bare Queue type does NOT match.
    static:
      doAssert not ((Queue[int, ccSingle, ccSingle, stEager, 16, 4]) is Queueable[int])
