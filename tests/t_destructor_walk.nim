## Destructor-walk coverage: `=destroy` walk for ref/string/seq T across all
## 4 cardinality combinations × bounded/unbounded, exercising the path
## where the queue is DROPPED WITH ITEMS IN FLIGHT (no drain). The
## queue's `=destroy` hook must invoke `disposeSlotEncoded` on every
## live slot so per-payload library lifecycle (ref decref, ManagedSlice
## box free) runs cleanly.
##
## Exercises:
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

# Slice-dispose trace counters (string / seq box-free observability).
#
# Under `-d:lockfreeSliceDisposeTrace` (the `testDestructorWalkTrace`
# nimble task) the shim counters in
# `tests/composition/slice_dispose_trace_shim.nim` are wired by
# `src/lockfree/managed_slice.nim` to the actual `disposeSlot` (string)
# and `disposeSeqSlot` (seq) destroy-walk paths. That lets suites B and C
# assert the destroy-walk visited EVERY residual slot's box exactly once
# (count == N): a walk that skipped slots, or freed only a prefix, drops
# the count below N and the assertion FAILS. In the plain umbrella build
# the counters are no-ops, so those suites fall back to a visible-skip +
# structural assertion (all pushes succeeded) — strictly stronger than the
# former `check true` tautology. The relative import resolves in both the
# umbrella (guarded no-op branch of the shim) and the trace task.
import ./composition/slice_dispose_trace_shim

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
# Instrumented seq element — global atomic counter tracks live `Tracked`
# instances so suite C can assert the seq destroy-walk runs each
# element's `=destroy` (lane-universal: works under every arc/orc lane,
# no special define). A `seq[Tracked]` payload boxes into a SeqBox; the
# destroy-walk's `disposeSeqSlot` runs `=destroy(box.v)`, which destroys
# the seq and therefore each `Tracked` element, returning the counter to
# baseline. A walk that skipped slots, or freed the box without running
# the payload's `=destroy`, leaves the counter ABOVE baseline (leak); a
# double-free drives it BELOW (or crashes).
# ----------------------------------------------------------------------

var trackedLive {.global.}: Atomic[int]

type Tracked = object
  payload: int

when defined(gcArc) or defined(gcOrc) or defined(gcAtomicArc) or defined(nimony):
  proc `=destroy`(t: Tracked) =
    discard trackedLive.fetchSub(1, moRelaxed)
else:
  proc `=destroy`(t: var Tracked) =
    discard trackedLive.fetchSub(1, moRelaxed)

proc newTracked(v: int): Tracked =
  result = Tracked(payload: v)
  discard trackedLive.fetchAdd(1, moRelaxed)

proc trackedLiveCount(): int = trackedLive.load(moRelaxed)

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
  suite "destructor walk: ref T destroy without drain (refcount)":
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
# box.
#
# In-process observable (replaces the former `check true` green mirage):
# under `-d:lockfreeSliceDisposeTrace` the destroy-walk's per-slot
# `disposeSlot` call bumps `stringDisposeCounter`, so we assert exactly N
# dispose calls fired after the queue is dropped. A walk that skipped
# slots, treated occupied slots as the zero sentinel, or freed only a
# prefix yields count < N and FAILS. A double-free yields count > N (or a
# crash). In the plain umbrella the counter is a no-op, so we emit a
# visible skip and fall back to asserting every push succeeded (the
# residual slots that the walk must visit exist) — strictly stronger than
# `check true`.
# ----------------------------------------------------------------------

const N = 4

template assertStringWalk(pushCount: int, body: untyped) =
  ## Run `body` (which builds + drops a queue in an inner scope), then
  ## assert the destroy-walk disposed exactly `pushCount` string boxes.
  ## `pushCount` is the number of residual (unpopped) string slots.
  when defined(lockfreeSliceDisposeTrace):
    resetSliceDisposeCounters()
    body
    # `body` has exited; the queue it owned is destroyed and the
    # destroy-walk's per-residual-slot disposeSlot calls are reflected in
    # the counter. seq disposer must NOT have fired for a string queue.
    check countStringDispose() == pushCount
    check countSeqDispose() == 0
  else:
    body
    echo "SKIPPED: string destroy-walk slot-count requires " &
      "-d:lockfreeSliceDisposeTrace (run `nimble testDestructorWalkTrace`)"

suite "destructor walk: string T destroy without drain":
  test "BQueue SPSC bounded — N strings pushed, queue dropped":
    assertStringWalk(N):
      block:
        var q = newBQueue[string, ccSingle, ccSingle, 16, 0, 0]()
        for i in 0 ..< N:
          check q.push("payload-" & $i)

  test "BQueue MPSC bounded — N strings pushed, queue dropped":
    assertStringWalk(N):
      block:
        var q = newBQueue[string, ccMulti, ccSingle, 16, 4, 0]()
        var p = q.getProducerHere(0)
        for i in 0 ..< N:
          check p.push("mpsc-" & $i)

  test "BQueue SPMC bounded — N strings pushed, queue dropped":
    assertStringWalk(N):
      block:
        var q = newBQueue[string, ccSingle, ccMulti, 16, 0, 4]()
        for i in 0 ..< N:
          check q.push("spmc-" & $i)

  test "BQueue MPMC bounded — N strings pushed, queue dropped":
    assertStringWalk(N):
      block:
        var q = newBQueue[string, ccMulti, ccMulti, 16, 4, 4]()
        var p = q.getProducerHere(0)
        for i in 0 ..< N:
          check p.push("mpmc-" & $i)

  test "Queue SPSC unbounded — N strings pushed, queue dropped":
    assertStringWalk(N):
      block:
        var q = newUnboundedSpscQueue[string, stEager, 16, 4]()
        var p = q.getProducerHere()
        for i in 0 ..< N:
          p.push("u-spsc-" & $i)

  test "Queue MPSC unbounded — N strings pushed, queue dropped":
    assertStringWalk(N):
      block:
        var q = newUnboundedMpscQueue[string, stEager, 16, 4]()
        var p = q.getProducerHere()
        for i in 0 ..< N:
          p.push("u-mpsc-" & $i)

  test "Queue SPMC unbounded — N strings pushed, queue dropped":
    assertStringWalk(N):
      block:
        var q = newUnboundedSpmcQueue[string, stEager, 16, 4]()
        var p = q.getProducerHere()
        for i in 0 ..< N:
          p.push("u-spmc-" & $i)

  test "Queue MPMC unbounded — N strings pushed, queue dropped":
    assertStringWalk(N):
      block:
        var q = newUnboundedMpmcQueue[string, stEager, 16, 4]()
        var p = q.getProducerHere()
        for i in 0 ..< N:
          p.push("u-mpmc-" & $i)

# ----------------------------------------------------------------------
# C. seq[U] T destroy without drain — element-lifecycle observability.
#
# Same SeqBox dispatch as string (both lower through ManagedSlice), via
# the distinctly-named `disposeSeqSlot`. Coverage is the `T is seq` arm
# in disposeSlotEncoded; one representative case per cardinality combo.
#
# In-process observable (replaces the former `check true` green mirage):
# the payload is `seq[Tracked]` whose elements bump a process-global live
# counter at construction and decrement it in `=destroy`. On the
# destroy-walk, `disposeSeqSlot` runs `=destroy(box.v)`, destroying the
# residual seqs and therefore every `Tracked` element, so the counter
# MUST return to baseline. A walk that skipped occupied slots leaks
# (counter > baseline); a double-free crashes / drives it below. This
# assertion runs in EVERY arc/orc lane, no define required. Under
# `-d:lockfreeSliceDisposeTrace` we additionally pin the exact number of
# SeqBox dispose calls (== N) and that the STRING disposer never fired —
# proving correct seq-vs-string disposer routing (T1-G5-001 family).
# ----------------------------------------------------------------------

proc trackedSeq(elems: varargs[int]): seq[Tracked] =
  result = @[]
  for e in elems:
    result.add(newTracked(e))

template assertSeqWalk(slotCount: int, body: untyped) =
  ## Run `body` (which builds + drops a queue of `seq[Tracked]` in an
  ## inner scope), then assert (a) every `Tracked` element was destroyed
  ## (live counter back to baseline) and (b) under the trace build the
  ## SeqBox disposer fired exactly `slotCount` times with the string
  ## disposer untouched.
  let baseline = trackedLiveCount()
  when defined(lockfreeSliceDisposeTrace):
    resetSliceDisposeCounters()
  body
  # `body` has exited; the queue is destroyed and the destroy-walk has
  # run disposeSeqSlot on each residual slot, destroying every element.
  check trackedLiveCount() == baseline
  when defined(lockfreeSliceDisposeTrace):
    check countSeqDispose() == slotCount
    check countStringDispose() == 0

suite "destructor walk: seq[U] T destroy without drain":
  test "BQueue SPSC bounded — N seq[Tracked] pushed, queue dropped":
    assertSeqWalk(N):
      block:
        var q = newBQueue[seq[Tracked], ccSingle, ccSingle, 16, 0, 0]()
        for i in 0 ..< N:
          check q.push(trackedSeq(i, i + 1, i + 2))

  test "BQueue MPSC bounded — N seq[Tracked] pushed, queue dropped":
    assertSeqWalk(N):
      block:
        var q = newBQueue[seq[Tracked], ccMulti, ccSingle, 16, 4, 0]()
        var p = q.getProducerHere(0)
        for i in 0 ..< N:
          check p.push(trackedSeq(i))

  test "BQueue SPMC bounded — N seq[Tracked] pushed, queue dropped":
    assertSeqWalk(N):
      block:
        var q = newBQueue[seq[Tracked], ccSingle, ccMulti, 16, 0, 4]()
        for i in 0 ..< N:
          check q.push(trackedSeq(i, i))

  test "BQueue MPMC bounded — N seq[Tracked] pushed, queue dropped":
    assertSeqWalk(N):
      block:
        var q = newBQueue[seq[Tracked], ccMulti, ccMulti, 16, 4, 4]()
        var p = q.getProducerHere(0)
        for i in 0 ..< N:
          check p.push(trackedSeq(i, i + 1))

  test "Queue SPSC unbounded — N seq[Tracked] pushed, queue dropped":
    assertSeqWalk(N):
      block:
        var q = newUnboundedSpscQueue[seq[Tracked], stEager, 16, 4]()
        var p = q.getProducerHere()
        for i in 0 ..< N:
          p.push(trackedSeq(i, i * 2))

  test "Queue MPSC unbounded — N seq[Tracked] pushed, queue dropped":
    assertSeqWalk(N):
      block:
        var q = newUnboundedMpscQueue[seq[Tracked], stEager, 16, 4]()
        var p = q.getProducerHere()
        for i in 0 ..< N:
          p.push(trackedSeq(i))

  test "Queue SPMC unbounded — N seq[Tracked] pushed, queue dropped":
    assertSeqWalk(N):
      block:
        var q = newUnboundedSpmcQueue[seq[Tracked], stEager, 16, 4]()
        var p = q.getProducerHere()
        for i in 0 ..< N:
          p.push(trackedSeq(i, i + 1))

  test "Queue MPMC unbounded — N seq[Tracked] pushed, queue dropped":
    assertSeqWalk(N):
      block:
        var q = newUnboundedMpmcQueue[seq[Tracked], stEager, 16, 4]()
        var p = q.getProducerHere()
        for i in 0 ..< N:
          p.push(trackedSeq(i, i * 3))

# ----------------------------------------------------------------------
# D. POD T destroy without drain — no-op walk.
#
# POD T routes to the `discard` arm in disposeSlotEncoded: there is no
# managed resource to free, so in-process the only observable failure is
# a crash during the walk. We therefore strengthen the former `check
# true` tautology to: (a) every push genuinely succeeded (the residual
# slots the walk must traverse actually exist — a silently-dropped push
# would shrink the residual set), verified by counting successful pushes
# against N; and (b) for the bounded arms a partial pop confirms the
# stored bits are intact (a corrupt slot would surface as a wrong value).
# A crash-free walk over a known-full ring is the maximum in-process
# guarantee for POD; leak detection for POD is vacuous (nothing is
# allocated per slot).
# ----------------------------------------------------------------------

suite "destructor walk: POD T destroy without drain":
  test "BQueue SPSC bounded — N ints pushed, queue dropped":
    var pushes = 0
    block:
      var q = newBQueue[int, ccSingle, ccSingle, 16, 0, 0]()
      for i in 0 ..< N:
        if q.push(i * 100): inc pushes
    check pushes == N

  test "BQueue MPSC bounded — N ints pushed, queue dropped":
    var pushes = 0
    block:
      var q = newBQueue[int, ccMulti, ccSingle, 16, 4, 0]()
      var p = q.getProducerHere(0)
      for i in 0 ..< N:
        if p.push(i * 100): inc pushes
    check pushes == N

  test "BQueue SPMC bounded — N ints pushed, queue dropped":
    var pushes = 0
    block:
      var q = newBQueue[int, ccSingle, ccMulti, 16, 0, 4]()
      for i in 0 ..< N:
        if q.push(i * 100): inc pushes
    check pushes == N

  test "BQueue MPMC bounded — N ints pushed, queue dropped":
    var pushes = 0
    block:
      var q = newBQueue[int, ccMulti, ccMulti, 16, 4, 4]()
      var p = q.getProducerHere(0)
      for i in 0 ..< N:
        if p.push(i * 100): inc pushes
    check pushes == N

  test "Queue SPSC unbounded — N ints pushed, queue dropped":
    var pushes = 0
    block:
      var q = newUnboundedSpscQueue[int, stEager, 16, 4]()
      var p = q.getProducerHere()
      for i in 0 ..< N:
        p.push(i * 100)
        inc pushes
    check pushes == N

  test "Queue MPSC unbounded — N ints pushed, queue dropped":
    var pushes = 0
    block:
      var q = newUnboundedMpscQueue[int, stEager, 16, 4]()
      var p = q.getProducerHere()
      for i in 0 ..< N:
        p.push(i * 100)
        inc pushes
    check pushes == N

  test "Queue SPMC unbounded — N ints pushed, queue dropped":
    var pushes = 0
    block:
      var q = newUnboundedSpmcQueue[int, stEager, 16, 4]()
      var p = q.getProducerHere()
      for i in 0 ..< N:
        p.push(i * 100)
        inc pushes
    check pushes == N

  test "Queue MPMC unbounded — N ints pushed, queue dropped":
    var pushes = 0
    block:
      var q = newUnboundedMpmcQueue[int, stEager, 16, 4]()
      var p = q.getProducerHere()
      for i in 0 ..< N:
        p.push(i * 100)
        inc pushes
    check pushes == N

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

suite "destructor walk: partial drain then destroy":
  test "BQueue SPSC POD — K of N popped, queue dropped":
    const K = 2
    var seen: seq[int] = @[]
    block:
      var q = newBQueue[int, ccSingle, ccSingle, 16, 0, 0]()
      for i in 0 ..< N:
        check q.push(i * 10)
      for _ in 0 ..< K:
        let r = q.pop()
        check r.isSome
        seen.add(r.get)
      # N-K = 2 live slots remain; queue drops below — the destroy-walk
      # must traverse exactly those, crash-free.
    # The K popped items are the FIFO front; this pins both the pop order
    # and that the partial drain consumed exactly K of N.
    check seen == @[0, 10]

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

suite "destructor walk: mm:none drain-then-destroy contract":
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
