## tests/composition/t_seq_char_dispose.nim
##
## TDD regression for the disposeSlot/unwrap overload collision
## (finding T1-G5-001): `ManagedSlice[char]` is the slot encoding for
## BOTH `string` (T = char) and `seq[char]` (U = char). They collapse to
## the same instantiation, so before the fix Nim overload resolution
## picked the NON-generic `disposeSlot(ManagedSlice[char])` (StringBox
## path) for a `seq[char]` slot, running the StringBox destructor over a
## SeqBox. The fix gives the seq path a distinctly-named disposer
## (`disposeSeqSlot`) / unwrap (`unwrapSeq`) so the seq[char] arm is
## never shadowed.
##
## The assertion is REAL only under `-d:lockfreeSliceDisposeTrace`, where
## the shim counters in `slice_dispose_trace_shim.nim` are wired to the
## dispose paths in `src/lockfree/managed_slice.nim`. We push N
## `seq[char]` payloads into a queue and DROP the queue WITHOUT popping,
## so the destructor walk (`disposeSlotEncoded` →
## `managed_slice.disposeSeqSlot`) runs once per residual slot. The
## correct routing increments `seqDisposeCounter` exactly N times and
## leaves `stringDisposeCounter` at 0. Before the fix the residual
## seq[char] slots route to the STRING disposer, so the assertion
## inverts (seqDispose == 0, stringDispose == N) and the test FAILS.
##
## In the plain umbrella build the counters are no-ops, so instead of a
## silent tautology we emit a VISIBLE skip notice. The real gate runs via
## the `testSliceDispose` nimble task.

import std/options
import unittest2

import lockfree/bqueue
import lockfree/queue
import lockfree/endpoint
import lockfree/role_tags
import lockfree/strategy

import ./slice_dispose_trace_shim

const
  N = 4 # residual seq[char] payloads pushed, never popped
  Cap = 32 # bounded capacity (must hold N)
  Seg = 16 # unbounded segment size
  MaxThreads = 4

proc seqCharPayload(i: int): seq[char] =
  ## Build a distinct `seq[char]` payload (NOT a string) for slot `i`.
  result = @[]
  for c in ("payload-" & $i):
    result.add(c)

proc seqBytePayload(i: int): seq[byte] =
  ## Build a distinct `seq[byte]` payload for slot `i`.
  result = @[]
  for c in ("payload-" & $i):
    result.add(byte(ord(c)))

template assertSeqRouted(body: untyped) =
  ## Run `body` (which owns a queue in an inner scope that closes before
  ## the counters are read), then assert the residual seq slots routed to
  ## the SEQ disposer, not the STRING disposer.
  when defined(lockfreeSliceDisposeTrace):
    resetSliceDisposeCounters()
    body
    # `body` has exited; the queue it owned has been destroyed and the
    # destroy-walk's per-residual-slot disposer calls are now reflected
    # in the counters. Read AFTER the queue scope closes.
    check countSeqDispose() == N
    check countStringDispose() == 0
  else:
    body
    echo "SKIPPED: seq[char] dispose routing requires " &
      "-d:lockfreeSliceDisposeTrace (run `nimble testSliceDispose` for " &
      "the real assertion)"
    # Compile / crash-free coverage arm only; the REAL assertion is the
    # trace arm above.
    check true

suite "seq[char] dispose routing (overload-collision regression)":
  test "BQueue SPSC: residual seq[char] slots use the seq disposer":
    assertSeqRouted:
      block:
        var q = newSpscQueue[seq[char], Cap]()
        for i in 0 ..< N:
          let s = seqCharPayload(i)
          check q.push(s)

  test "BQueue MPMC: residual seq[char] slots use the seq disposer":
    assertSeqRouted:
      block:
        var q = newMpmcQueue[seq[char], Cap, 4, 4]()
        var producer = q.getProducerHere(0)
        for i in 0 ..< N:
          let s = seqCharPayload(i)
          check producer.push(s)

  test "Queue SPSC unbounded: residual seq[char] slots use the seq disposer":
    assertSeqRouted:
      block:
        var q = newUnboundedSpscQueue[seq[char], stEager, Seg, MaxThreads]()
        var producer = q.getProducerHere()
        for i in 0 ..< N:
          let s = seqCharPayload(i)
          producer.push(s)

  test "Queue MPMC unbounded: residual seq[char] slots use the seq disposer":
    assertSeqRouted:
      block:
        var q = newUnboundedMpmcQueue[seq[char], stEager, Seg, MaxThreads]()
        var producer = q.getProducerHere()
        for i in 0 ..< N:
          let s = seqCharPayload(i)
          producer.push(s)

  test "BQueue SPSC: residual seq[byte] slots use the seq disposer":
    assertSeqRouted:
      block:
        var q = newSpscQueue[seq[byte], Cap]()
        for i in 0 ..< N:
          let s = seqBytePayload(i)
          check q.push(s)
