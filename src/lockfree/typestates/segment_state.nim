## Segment-state predicate for the unbounded MPSC arm.
##
## Companion to the two slot-state predicate families in `slot_state.nim`,
## covering the MPSC committed-segment predicate (the linked-segment destructor
## walk).
##
## Substrate: `Segment[T, ccMulti, ccSingle, S].committed: array[S,
## Atomic[bool]]` — the committed-flag overlay on the MPSC arm (declared in
## `queue.nim` on the `(ccMulti × ccSingle)` shape).
##
## Current call sites: NONE in v0.1.0. The first consumer is the segment
## destructor walk, which walks `committed[i]` to drop any values committed by
## the producer but not yet read by the consumer when the segment is reclaimed.
##
## Why a sibling module rather than a section in `slot_state.nim`? Orthogonality
## rationale: three substrates → three predicate families. The MPSC
## `committed[i]` is a segment-overlay flag with different lifetime semantics
## from the per-slot seq counters used by Families A and B. Keeping it lexically
## distinct makes accidental cross-substrate reuse impossible.
##
## Import note: this module imports `queue.nim` (and is itself NOT imported by
## `queue.nim` in v0.1.0), so there is no cycle.

import lockfree/atomics
import ../queue

proc slotIsCommittedAndUnread*[T; S: static int](
    seg: var Segment[T, ccMulti, ccSingle, S];
    slot: int;
    prevConsumerIdx: int
): bool {.inline.} =
  ## Returns true when `slot` is at or past the consumer's last-read index AND
  ## the producer has flipped its `committed[slot]` flag to true. The relaxed
  ## load suffices because the destructor walk runs only when the segment is
  ## being reclaimed — all producers and the consumer have already quiesced by
  ## EBR/manual reclamation guarantees, so no in-flight publish can race the
  ## walk.
  slot >= prevConsumerIdx and seg.committed[slot].load(moRelaxed)
