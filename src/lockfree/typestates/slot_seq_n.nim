## Per-slot sequence counters (Vyukov bounded MPMC).
##
## Each slot carries an Atomic[uint64] seq, initialised to its index. Producers
## and consumers compare a globally-monotonic claim cursor against this counter
## to decide whether the slot is owned by the current generation (claimable),
## the previous generation's pending consumer (full from the producer's POV), or
## a future generation (empty from the consumer's POV).
##
## Memory ordering is supplied by the caller at every load/store; the module
## itself is order-agnostic so call sites can document intent inline. The order
## parameter is `static MemoryOrder` because `debra/atomics` requires
## compile-time validation of the load/store ordering domain.
##
## Indexing uses PhysicalSlotN[N] for type-safe slot access (carried over from
## the old CommittedFlagsN module) — an arbitrary `int` cannot be passed in,
## eliminating a class of off-by-one indexing bugs.

import typestates
import lockfree/atomics
import ./virtual_values_n

type SlotSeqN*[N: static int] = object
  ## Array of per-slot sequence counters. Used by bounded MPMC/SPMC/MPSC queues
  ## that adopt the Vyukov per-slot generation protocol.
  ##
  ## NOTE (v0.1.0): no PRODUCTION consumer — the bounded Vyukov path uses the
  ## co-located MPMCCellPayload.seq in mpmc_cell.nim for cache-locality.
  ## SlotSeqN is retained as a tested building block (exercised by
  ## tests/t_typestates_import.nim) and a placeholder for a future
  ## standalone-seq-array phase; do not adopt it in production without
  ## revisiting the false-sharing tradeoff.
  seqs*: array[N, Atomic[uint64]]

proc init*[N: static int](s: var SlotSeqN[N]) =
  ## Initialize seq[i] = i. CRITICAL: NOT zeros (zero-init violates the
  ## algorithm; the first producer at pos=0 expects seq[0]=0, seq[1]=1, ...).
  for i in 0 ..< N:
    s.seqs[i].store(uint64(i), moRelaxed)

proc load*[N: static int](
    s: var SlotSeqN[N], idx: PhysicalSlotN[N], order: static MemoryOrder
): uint64 {.inline, notATransition.} =
  s.seqs[idx.slotValue].load(order)

proc store*[N: static int](
    s: var SlotSeqN[N], idx: PhysicalSlotN[N], val: uint64, order: static MemoryOrder
) {.inline, notATransition.} =
  s.seqs[idx.slotValue].store(val, order)
