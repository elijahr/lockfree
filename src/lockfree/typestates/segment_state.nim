## Segment-state predicate for the unbounded MPSC arm.
##
## Design cite: §4.6 (refactored 2026-06-06 — two slot-state predicate
## families in `slot_state.nim` plus this MPSC committed-segment predicate)
## and §4.7 (linked-segment destructor walk).
##
## Substrate: `Segment[T, ccMulti, ccSingle, S].committed: array[S, Atomic[bool]]`
## — the committed-flag overlay on the MPSC arm (declared in `queue.nim` on
## the `(ccMulti × ccSingle)` shape; `Segment` definition at queue.nim:300,
## committed field at queue.nim:343).
##
## Current call sites: NONE in v0.1.0. The first consumer is
## T-DESTRUCTOR-WALK in PG-7 (segment destructor walks `committed[i]` to
## drop any values committed by the producer but not yet read by the
## consumer when the segment is reclaimed). See impl-plan
## `docs/internal/2026-06-06-umbrella-v0.1.0-impl-plan.md`.
##
## Why a sibling module rather than a section in `slot_state.nim`?
## §4.6.2 orthogonality rationale: three substrates → three predicate
## families. The MPSC `committed[i]` is a segment-overlay flag with
## different lifetime semantics from the per-slot seq counters used by
## Families A and B. Keeping it lexically distinct makes accidental
## cross-substrate reuse impossible.
##
## Import note: this module imports `queue.nim` (and is itself NOT imported
## by `queue.nim` in v0.1.0), so there is no cycle. The first downstream
## importer is T-DESTRUCTOR-WALK in PG-7.

import lockfree/atomics
import ../queue

proc slotIsCommittedAndUnread*[T; S: static int](
    seg: var Segment[T, ccMulti, ccSingle, S];
    slot: int;
    prevConsumerIdx: int
): bool {.inline.} =
  ## §4.6 / §4.7. Returns true when `slot` is at or past the consumer's
  ## last-read index AND the producer has flipped its `committed[slot]`
  ## flag to true. The relaxed load suffices because the destructor walk
  ## runs only when the segment is being reclaimed — all producers and
  ## the consumer have already quiesced by EBR/manual reclamation
  ## guarantees, so no in-flight publish can race the walk.
  slot >= prevConsumerIdx and seg.committed[slot].load(moRelaxed)
