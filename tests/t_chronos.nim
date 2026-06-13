## tests/t_chronos.nim
##
## Tier 3 chronos async adapter tests for `src/lockfree/chronos.nim`.
##
## Verifies acceptance cells (a) + (b) for the chronos adapter
## (design §5.4 + §5.6):
##
##   (a) chronos installed, no `-d:lockfreeChronos`: auto-detect via
##       `compiles do: import chronos`; AsyncQueue/AsyncBQueue exported.
##   (b) chronos installed, `-d:lockfreeChronos` set: opt-in path; same
##       exports.
##
## Cells (c) + (d) are verified by inspection (cell c: the `{.error.}`
## block guarding `-d:lockfreeChronos` without chronos installed; cell d:
## the `when` gate around the module body that makes AsyncQueue/AsyncBQueue
## invisible without chronos + flag) and by the chronos / no-chronos CI
## cells.
##
## When chronos is NOT available locally, the whole test body is gated
## off; this file becomes a no-op so non-chronos builds still compile.
## A loud echo below makes the skip observable in local dev runs
## (silent skip on missing optional dep). In CI the chronos cell
## installs chronos so the gate opens.

when not (compiles do:
  import chronos
):
  # LOUD skip marker: chronos is NOT in lockfree.nimble requires, so the
  # default build env has no chronos and this entire adapter suite
  # compiles to a no-op with ZERO assertions. A green umbrella run does
  # NOT imply the chronos adapter was tested. The banner below makes that
  # explicit so the absence of coverage is never mistaken for passing
  # coverage. CI must install chronos in a dedicated lane to exercise the
  # real assertions in the `when (compiles ...)` branch below.
  echo "================================================================"
  echo "SKIPPED [t_chronos]: chronos adapter NOT TESTED (chronos not on " &
    "the Nim path in this build env). 0 assertions ran. Install chronos " &
    "and re-run to exercise lockfree/chronos. This is a SKIP, not a PASS."
  echo "================================================================"

when (compiles do:
  import chronos
):
  # chronos own `AsyncQueue[T]` collides at unqualified scope with the
  # `AsyncQueue[T; ccProd, ccCons, ST, S, MaxThreads]` exported by
  # `lockfree/chronos`. Use `from chronos import nil`-style qualified
  # access for the bits we need from chronos directly (Future, waitFor,
  # CancelledError) so the lockfree adapter's `AsyncQueue` /
  # `AsyncBQueue` names dominate in the test body. Real-world callers
  # typically only need one of the two `AsyncQueue` types in any given
  # scope; pick the right `import` accordingly.
  import std/options
  import unittest2
  import lockfree/bqueue  # PinScopeCardinality (ccSingle / ccMulti)
  import lockfree/queue
  import lockfree/strategy
  import lockfree/endpoint   # getProducerHere for unbounded SPSC manual push
  import lockfree/role_tags
  import lockfree/chronos
  # Pull chronos's Future / waitFor / CancelledError / cancelSoon /
  # finished from the asyncsync submodule (which re-exports asyncloop ->
  # asyncfutures + errors). This sidesteps chronos's own top-level
  # `AsyncQueue[T]` re-export, which would shadow our parameterized
  # `lockfree/chronos.AsyncQueue` at unqualified scope.
  import chronos/[asyncsync]

  suite "lockfree/chronos — AsyncBQueue SPSC":
    test "push + pop roundtrip (POD int)":
      var q = newAsyncBQueue[int, ccSingle, ccSingle, 16, 0, 0]()
      check q.push(42) == true
      let popped = waitFor(q.pop())
      check popped == some(42)

    test "pop awaits event when empty, fires on push":
      var q = newAsyncBQueue[int, ccSingle, ccSingle, 16, 0, 0]()
      # Kick off pop while queue is empty; future must not be finished yet.
      let popFut = q.pop()
      check popFut.finished == false
      # Push fires the AsyncEvent; pop completes after one dispatcher pass.
      check q.push(7) == true
      let got = waitFor(popFut)
      check got == some(7)

    test "FIFO order preserved across multiple roundtrips":
      var q = newAsyncBQueue[int, ccSingle, ccSingle, 16, 0, 0]()
      check q.push(1) == true
      check q.push(2) == true
      check q.push(3) == true
      check waitFor(q.pop()) == some(1)
      check waitFor(q.pop()) == some(2)
      check waitFor(q.pop()) == some(3)

    test "Path-C string transparency (sink T encoded via SlotEncoding)":
      var q = newAsyncBQueue[string, ccSingle, ccSingle, 16, 0, 0]()
      check q.push("hello") == true
      check q.push("world") == true
      check waitFor(q.pop()) == some("hello")
      check waitFor(q.pop()) == some("world")

    test "pop future cancellation raises CancelledError; queue remains usable":
      var q = newAsyncBQueue[int, ccSingle, ccSingle, 16, 0, 0]()
      let popFut = q.pop()
      check popFut.finished == false
      popFut.cancelSoon()
      # Drain the dispatcher so the cancellation callback fires.
      var raised = false
      try:
        discard waitFor(popFut)
      except CancelledError:
        raised = true
      check raised == true
      # Queue is still consistent — a fresh push/pop pair succeeds.
      check q.push(99) == true
      check waitFor(q.pop()) == some(99)

  suite "lockfree/chronos — AsyncQueue (unbounded SPSC, manual producer)":
    # The unbounded async-adapter currently exposes pop on the wrapper
    # but routes push through the inner queue's Bound endpoint (design
    # §5.4.5 — endpoint-side async push is still open). The
    # canonical pattern documented in `src/lockfree/chronos.nim` is to
    # acquire a same-thread producer via `q.queue.getProducerHere()`,
    # push through it, and then fire `q.event` to wake any awaiting
    # consumers. These tests pin that contract.
    test "manual-producer push + async pop roundtrip (POD int)":
      var q = newAsyncQueue(AsyncQueueSpsc[int, 64, 1])
      var prod = q.queue.getProducerHere()
      prod.push(123)
      q.event.fire()
      check waitFor(q.pop()) == some(123)

    test "pop awaits event when empty, fires on push":
      var q = newAsyncQueue(AsyncQueueSpsc[int, 64, 1])
      var prod = q.queue.getProducerHere()
      let popFut = q.pop()
      check popFut.finished == false
      prod.push(11)
      q.event.fire()
      check waitFor(popFut) == some(11)
