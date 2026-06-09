## T-DESTRUCTOR-WALK — `=destroy` walk for ref/string/seq T across all
## 4 cardinality combinations × bounded/unbounded, exercising the path
## where the queue is DROPPED WITH ITEMS IN FLIGHT (no drain). The
## queue's `=destroy` hook must invoke `disposeSlotEncoded` on every
## live slot so per-payload library lifecycle (ref decref, ManagedSlice
## box free) runs cleanly.
##
## Wave C (PG-6) wired:
## * `src/lockfree/internal/path_c_wrap.nim:disposeSlotEncoded` — the
##   per-slot dispose primitive (POD no-op; ref → `=destroy`-via-toRef;
##   string/seq → ManagedSlice box free).
## * `src/lockfree/queue.nim` segment destructor + `=destroy` walks.
## * `src/lockfree/bqueue.nim` `=destroy` walks all N cells.
##
## This file does NOT modify those walks — it tests them.
##
## ----------------------------------------------------------------------
## RESOLVED — lifecycle model (locked 2026-06-06):
##
## * Push does an explicit `incRefSlot` inside `wrapOrIdentity[ref X]`
##   (path_c_wrap.nim). The queue claims +1 of the cell's refcount
##   lifetime for the slot.
## * Push's `sink`-consumed local fires `=destroy` at scope end (-1);
##   net within push = +1 transferred to the slot.
## * Pop is a destructive read via `move()`; no library inc/dec at pop.
##   The slot's +1 share is inherited by the caller's binding.
## * Destroy-walk (this file's subject) walks UNPOPPED slots and calls
##   `disposeSlotEncoded` which runs `decRefSlot` for ref T, releasing
##   the slot's +1. If the slot held the last share, `=destroy` on the
##   payload fires.
##
## Refcount instrumentation IS observable under this model: a fresh
## `newRefCounter(...)` pushed and never popped should see its
## `=destroy` fire (and the global counter decrement) when the queue
## leaves scope. The ref-T tests in suite A below assert this.
## ----------------------------------------------------------------------
##
## Test pattern notes:
## * ref-T multi-push inside a unittest2 test-body closure under
##   `--mm:arc` can hold cursor borrows that interact poorly with
##   sink consumption (opportunity-queue.md entry). For multi-push
##   ref-T tests we hoist the push loop into a helper proc OUTSIDE
##   the test-body closure (single-action-per-test discipline).
## * String / seq tests use multi-push inline (works cleanly because
##   Nim's value-types arc handling differs from ref).

import std/atomics
import options
import unittest2

import lockfree/bqueue
import lockfree/queue
import lockfree/endpoint
import lockfree/role_tags
import lockfree/strategy

# ----------------------------------------------------------------------
# Instrumented ref type — global atomic counter tracks live RefCounter
# instances. Used to assert the structural "queue scope-exit completes
# without crashing for ref T payloads" across all MMs. Per the contract
# finding above, the counter cannot validate per-slot decref — its job
# here is the broken-implementation check (a destroy walk that
# double-frees would crash; a walk that no-ops on ref T is the current
# observable behavior).
# ----------------------------------------------------------------------

var refLive {.global.}: Atomic[int]

type
  RefCounterObj = object
    payload: int
  RefCounter = ref RefCounterObj

when defined(gcArc) or defined(gcOrc) or defined(gcAtomicArc) or defined(nimony):
  # Nim 2.x arc/orc/atomicArc: =destroy takes T (value).
  proc `=destroy`(r: RefCounterObj) =
    discard refLive.fetchSub(1, moRelaxed)
else:
  # refc / mm:none: =destroy must take `var T`.
  proc `=destroy`(r: var RefCounterObj) =
    discard refLive.fetchSub(1, moRelaxed)

proc newRefCounter(v: int): RefCounter =
  result = RefCounter(payload: v)
  discard refLive.fetchAdd(1, moRelaxed)

proc liveCount(): int = refLive.load(moRelaxed)

# ----------------------------------------------------------------------
# A. ref T destroy without drain — refcount-asserting coverage.
#
# Under the locked lifecycle model (push does library +1; destroy-walk
# does library -1), an unpopped ref T whose only remaining share is the
# queue's slot share MUST have its `=destroy` fire when the queue leaves
# scope. We assert `liveCount()` returns to its baseline.
#
# Multi-push variants hoist the push loop into a helper proc OUTSIDE the
# test-body closure (single-action-per-test pattern; opportunity-queue.md
# closure-capture note for ref-T under --mm:arc). Single-push tests
# stay inline.
#
# ESCAPE: A push wrapper that omits incRefSlot would leak (or crash with
# the destroy-walk dec) — observable via final != baseline or SIGSEGV.
# A destroy-walk that double-frees would crash. A walk that no-ops on
# ref T would leak the slot's share — observable as final > baseline.
#
# NOTE: this suite is gated to arc/orc/atomicArc. Refc uses Nim's
# traditional tracing GC for ref types; it does NOT invoke the
# user-defined `=destroy(var RefCounterObj)` hook when a `ref
# RefCounterObj` drops — reclamation goes through refc's own
# refcount path. Under refc the `liveCount` counter never decrements,
# so these tests cannot pass there by design. The contract being
# verified (queue's destroy-walk fires user `=destroy` per slot
# share) is an ARC/ORC contract. Refc reclamation of `ref T` in
# queue slots is covered by Path-C transit suites (rows 1/14/25 of
# tests/composition/t_path_c_matrix.nim) and by valgrind cell 8
# under arc — both of which exercise drop semantics without
# depending on user-hook timing.
# ----------------------------------------------------------------------

# Multi-push helpers (hoisted outside test-body closures per arc cursor
# discipline; opportunity-queue.md). Each accepts a queue/endpoint and
# pushes N fresh ref counters.

proc pushBqSpsc(q: var BQueue[RefCounter, ccSingle, ccSingle, 16, 0, 0]) =
  discard q.push(newRefCounter(101))
  discard q.push(newRefCounter(102))

proc pushBqMpmc(q: var BQueue[RefCounter, ccMulti, ccMulti, 16, 4, 4]) =
  var p = q.getProducerHere(0)
  discard p.push(newRefCounter(201))
  discard p.push(newRefCounter(202))

when defined(gcArc) or defined(gcOrc) or defined(gcAtomicArc) or defined(nimony):
  suite "T-DESTRUCTOR-WALK — ref T destroy without drain (refcount)":
    test "BQueue SPSC bounded — single ref T pushed, queue dropped":
      let baseline = liveCount()
      block:
        var q = newBQueue[RefCounter, ccSingle, ccSingle, 16, 0, 0]()
        var r = newRefCounter(1)
        check q.push(r)
      check liveCount() == baseline

    test "BQueue MPSC bounded — single ref T pushed, queue dropped":
      let baseline = liveCount()
      block:
        var q = newBQueue[RefCounter, ccMulti, ccSingle, 16, 4, 0]()
        var p = q.getProducerHere(0)
        var r = newRefCounter(2)
        check p.push(r)
      check liveCount() == baseline

    test "BQueue SPMC bounded — single ref T pushed, queue dropped":
      let baseline = liveCount()
      block:
        var q = newBQueue[RefCounter, ccSingle, ccMulti, 16, 0, 4]()
        var r = newRefCounter(3)
        check q.push(r)
      check liveCount() == baseline

    test "BQueue MPMC bounded — single ref T pushed, queue dropped":
      let baseline = liveCount()
      block:
        var q = newBQueue[RefCounter, ccMulti, ccMulti, 16, 4, 4]()
        var p = q.getProducerHere(0)
        var r = newRefCounter(4)
        check p.push(r)
      check liveCount() == baseline

    test "Queue SPSC unbounded — single ref T pushed, queue dropped":
      let baseline = liveCount()
      block:
        var q = newUnboundedSpscQueue[RefCounter, stEager, 16, 4]()
        var p = q.getProducerHere()
        var r = newRefCounter(5)
        p.push(r)
      check liveCount() == baseline

    test "Queue MPSC unbounded — single ref T pushed, queue dropped":
      let baseline = liveCount()
      block:
        var q = newUnboundedMpscQueue[RefCounter, stEager, 16, 4]()
        var p = q.getProducerHere()
        var r = newRefCounter(6)
        p.push(r)
      check liveCount() == baseline

    test "Queue SPMC unbounded — single ref T pushed, queue dropped":
      let baseline = liveCount()
      block:
        var q = newUnboundedSpmcQueue[RefCounter, stEager, 16, 4]()
        var p = q.getProducerHere()
        var r = newRefCounter(7)
        p.push(r)
      check liveCount() == baseline

    test "Queue MPMC unbounded — single ref T pushed, queue dropped":
      let baseline = liveCount()
      block:
        var q = newUnboundedMpmcQueue[RefCounter, stEager, 16, 4]()
        var p = q.getProducerHere()
        var r = newRefCounter(8)
        p.push(r)
      check liveCount() == baseline

    test "BQueue SPSC bounded — two ref T pushed via helper, queue dropped":
      let baseline = liveCount()
      block:
        var q = newBQueue[RefCounter, ccSingle, ccSingle, 16, 0, 0]()
        pushBqSpsc(q)
      check liveCount() == baseline

    test "BQueue MPMC bounded — two ref T pushed via helper, queue dropped":
      let baseline = liveCount()
      block:
        var q = newBQueue[RefCounter, ccMulti, ccMulti, 16, 4, 4]()
        pushBqMpmc(q)
      check liveCount() == baseline

# ----------------------------------------------------------------------
# B. string T destroy without drain — box-free lifecycle.
#
# For string T, push goes through `wrap(s: sink string)` →
# ManagedSlice[char]; the queue stores a box pointer. On destroy walk,
# `disposeSlot(ms)` runs the box's =destroy and `deallocShared`s the
# box. PG-10 valgrind detects leaks if any slot is missed.
#
# ESCAPE: a walk that iterates only [0..N/2) slots would leave half the
# boxes leaked (caught by valgrind in PG-10, not by this in-process
# check). A walk that double-frees boxes would crash here. A walk that
# skips occupied slots (treating them as zero sentinel) would leak
# silently here but be caught by valgrind.
# ----------------------------------------------------------------------

const N = 4

suite "T-DESTRUCTOR-WALK — string T destroy without drain":
  test "BQueue SPSC bounded — N strings pushed, queue dropped":
    block:
      var q = newBQueue[string, ccSingle, ccSingle, 16, 0, 0]()
      for i in 0 ..< N:
        check q.push("payload-" & $i)
    check true

  test "BQueue MPSC bounded — N strings pushed, queue dropped":
    block:
      var q = newBQueue[string, ccMulti, ccSingle, 16, 4, 0]()
      var p = q.getProducerHere(0)
      for i in 0 ..< N:
        check p.push("mpsc-" & $i)
    check true

  test "BQueue SPMC bounded — N strings pushed, queue dropped":
    block:
      var q = newBQueue[string, ccSingle, ccMulti, 16, 0, 4]()
      for i in 0 ..< N:
        check q.push("spmc-" & $i)
    check true

  test "BQueue MPMC bounded — N strings pushed, queue dropped":
    block:
      var q = newBQueue[string, ccMulti, ccMulti, 16, 4, 4]()
      var p = q.getProducerHere(0)
      for i in 0 ..< N:
        check p.push("mpmc-" & $i)
    check true

  test "Queue SPSC unbounded — N strings pushed, queue dropped":
    block:
      var q = newUnboundedSpscQueue[string, stEager, 16, 4]()
      var p = q.getProducerHere()
      for i in 0 ..< N:
        p.push("u-spsc-" & $i)
    check true

  test "Queue MPSC unbounded — N strings pushed, queue dropped":
    block:
      var q = newUnboundedMpscQueue[string, stEager, 16, 4]()
      var p = q.getProducerHere()
      for i in 0 ..< N:
        p.push("u-mpsc-" & $i)
    check true

  test "Queue SPMC unbounded — N strings pushed, queue dropped":
    block:
      var q = newUnboundedSpmcQueue[string, stEager, 16, 4]()
      var p = q.getProducerHere()
      for i in 0 ..< N:
        p.push("u-spmc-" & $i)
    check true

  test "Queue MPMC unbounded — N strings pushed, queue dropped":
    block:
      var q = newUnboundedMpmcQueue[string, stEager, 16, 4]()
      var p = q.getProducerHere()
      for i in 0 ..< N:
        p.push("u-mpmc-" & $i)
    check true

# ----------------------------------------------------------------------
# C. seq[int] T destroy without drain.
#
# Same dispatch as string (both lower through ManagedSlice). Coverage
# is the `T is seq` arm in disposeSlotEncoded; one representative case
# per cardinality combo.
# ----------------------------------------------------------------------

suite "T-DESTRUCTOR-WALK — seq[int] T destroy without drain":
  test "BQueue SPSC bounded — N seq[int] pushed, queue dropped":
    block:
      var q = newBQueue[seq[int], ccSingle, ccSingle, 16, 0, 0]()
      for i in 0 ..< N:
        check q.push(@[i, i + 1, i + 2])
    check true

  test "BQueue MPSC bounded — N seq[int] pushed, queue dropped":
    block:
      var q = newBQueue[seq[int], ccMulti, ccSingle, 16, 4, 0]()
      var p = q.getProducerHere(0)
      for i in 0 ..< N:
        check p.push(@[i])
    check true

  test "BQueue SPMC bounded — N seq[int] pushed, queue dropped":
    block:
      var q = newBQueue[seq[int], ccSingle, ccMulti, 16, 0, 4]()
      for i in 0 ..< N:
        check q.push(@[i, i])
    check true

  test "BQueue MPMC bounded — N seq[int] pushed, queue dropped":
    block:
      var q = newBQueue[seq[int], ccMulti, ccMulti, 16, 4, 4]()
      var p = q.getProducerHere(0)
      for i in 0 ..< N:
        check p.push(@[i, i + 1])
    check true

  test "Queue SPSC unbounded — N seq[int] pushed, queue dropped":
    block:
      var q = newUnboundedSpscQueue[seq[int], stEager, 16, 4]()
      var p = q.getProducerHere()
      for i in 0 ..< N:
        p.push(@[i, i * 2])
    check true

  test "Queue MPSC unbounded — N seq[int] pushed, queue dropped":
    block:
      var q = newUnboundedMpscQueue[seq[int], stEager, 16, 4]()
      var p = q.getProducerHere()
      for i in 0 ..< N:
        p.push(@[i])
    check true

  test "Queue SPMC unbounded — N seq[int] pushed, queue dropped":
    block:
      var q = newUnboundedSpmcQueue[seq[int], stEager, 16, 4]()
      var p = q.getProducerHere()
      for i in 0 ..< N:
        p.push(@[i, i + 1])
    check true

  test "Queue MPMC unbounded — N seq[int] pushed, queue dropped":
    block:
      var q = newUnboundedMpmcQueue[seq[int], stEager, 16, 4]()
      var p = q.getProducerHere()
      for i in 0 ..< N:
        p.push(@[i, i * 3])
    check true

# ----------------------------------------------------------------------
# D. POD T destroy without drain — no-op walk.
#
# POD T routes to the `discard` arm in disposeSlotEncoded. The walk
# must complete cleanly without touching slot bits. Asserting
# completion is sufficient.
# ----------------------------------------------------------------------

suite "T-DESTRUCTOR-WALK — POD T destroy without drain":
  test "BQueue SPSC bounded — N ints pushed, queue dropped":
    block:
      var q = newBQueue[int, ccSingle, ccSingle, 16, 0, 0]()
      for i in 0 ..< N:
        check q.push(i * 100)
    check true

  test "BQueue MPSC bounded — N ints pushed, queue dropped":
    block:
      var q = newBQueue[int, ccMulti, ccSingle, 16, 4, 0]()
      var p = q.getProducerHere(0)
      for i in 0 ..< N:
        check p.push(i * 100)
    check true

  test "BQueue SPMC bounded — N ints pushed, queue dropped":
    block:
      var q = newBQueue[int, ccSingle, ccMulti, 16, 0, 4]()
      for i in 0 ..< N:
        check q.push(i * 100)
    check true

  test "BQueue MPMC bounded — N ints pushed, queue dropped":
    block:
      var q = newBQueue[int, ccMulti, ccMulti, 16, 4, 4]()
      var p = q.getProducerHere(0)
      for i in 0 ..< N:
        check p.push(i * 100)
    check true

  test "Queue SPSC unbounded — N ints pushed, queue dropped":
    block:
      var q = newUnboundedSpscQueue[int, stEager, 16, 4]()
      var p = q.getProducerHere()
      for i in 0 ..< N:
        p.push(i * 100)
    check true

  test "Queue MPSC unbounded — N ints pushed, queue dropped":
    block:
      var q = newUnboundedMpscQueue[int, stEager, 16, 4]()
      var p = q.getProducerHere()
      for i in 0 ..< N:
        p.push(i * 100)
    check true

  test "Queue SPMC unbounded — N ints pushed, queue dropped":
    block:
      var q = newUnboundedSpmcQueue[int, stEager, 16, 4]()
      var p = q.getProducerHere()
      for i in 0 ..< N:
        p.push(i * 100)
    check true

  test "Queue MPMC unbounded — N ints pushed, queue dropped":
    block:
      var q = newUnboundedMpmcQueue[int, stEager, 16, 4]()
      var p = q.getProducerHere()
      for i in 0 ..< N:
        p.push(i * 100)
    check true

# ----------------------------------------------------------------------
# E. Partial-drain then destroy.
#
# Push N items (POD), pop K < N items, drop queue. The walk must
# complete cleanly with N-K live slots.
#
# ESCAPE: a walk that fails to track popped vs live slots could
# double-free or skip slots. POD case is structural (no observable
# state); the same dispatch path runs for string/seq variants and
# would surface as valgrind diagnostics.
# ----------------------------------------------------------------------

suite "T-DESTRUCTOR-WALK — partial drain then destroy":
  test "BQueue SPSC POD — K of N popped, queue dropped":
    const K = 2
    block:
      var q = newBQueue[int, ccSingle, ccSingle, 16, 0, 0]()
      for i in 0 ..< N:
        check q.push(i * 10)
      for _ in 0 ..< K:
        let r = q.pop()
        check r.isSome
      # N-K = 2 live slots remain; queue drops below.
    check true

  test "BQueue SPSC string — K of N popped, queue dropped":
    const K = 2
    var seen: seq[string] = @[]
    block:
      var q = newBQueue[string, ccSingle, ccSingle, 16, 0, 0]()
      for i in 0 ..< N:
        check q.push("part-" & $i)
      for _ in 0 ..< K:
        let r = q.pop()
        check r.isSome
        seen.add(r.get)
    check seen == @["part-0", "part-1"]

  test "Queue SPSC unbounded string — K of N popped, queue dropped":
    const K = 2
    var seen: seq[string] = @[]
    block:
      var q = newUnboundedSpscQueue[string, stEager, 16, 4]()
      var p = q.getProducerHere()
      for i in 0 ..< N:
        p.push("u-part-" & $i)
      for _ in 0 ..< K:
        let r = q.pop()
        check r.isSome
        seen.add(r.get)
    check seen == @["u-part-0", "u-part-1"]

# ----------------------------------------------------------------------
# F. mm:none semantics — drain consumes all items; destroy after drain
# is safe.
#
# Per §5.7.3, under --mm:none + non-POD T the queue's =destroy does NOT
# auto-free payload bits — drain is the user contract. We assert the
# drain extracts every pushed item exactly once. The post-drain queue's
# scope-exit =destroy must complete without crashing.
#
# This test is meaningful under all MMs: drain is the universal
# extraction path. Under mm:none users rely on it exclusively.
# ----------------------------------------------------------------------

suite "T-DESTRUCTOR-WALK — mm:none drain-then-destroy contract":
  test "string T: drain extracts all then scope-exit destroy is safe":
    var drained: seq[string] = @[]
    block:
      var q = newBQueue[string, ccSingle, ccSingle, 16, 0, 0]()
      check q.push("alpha")
      check q.push("beta")
      check q.push("gamma")
      for s in drain(q):
        drained.add(s)
      # Post-drain queue is empty; scope-exit =destroy walks zero
      # live slots. Under mm:none this is the documented safe path.
    check drained == @["alpha", "beta", "gamma"]

  test "POD T: drain extracts all then scope-exit destroy is safe":
    var drained: seq[int] = @[]
    block:
      var q = newBQueue[int, ccSingle, ccSingle, 16, 0, 0]()
      check q.push(11)
      check q.push(22)
      check q.push(33)
      for x in drain(q):
        drained.add(x)
    check drained == @[11, 22, 33]
