## Slot-state predicates for v0.1.0 lockfree umbrella.
##
## Two predicate families plus an MPSC committed-segment predicate in sibling
## `segment_state.nim`.
##
## Module-layout choice: shared `slot_state.nim` for Families A and B. Family-A
## symbols use the `B` suffix (`seqIsClosedB`, etc.); Family-B uses no suffix
## (`seqIsClosed`, etc.) because LCRQ-integration is the live consumer in v0.1.0
## (4 call sites in `queue.nim`). The two families intentionally do NOT share a
## `seqIsClosed` symbol so that a silent `uint64` ↔ `uint` width punning
## across the substrates cannot occur (orthogonality rationale).
##
## Three substrates → two slot-state predicate families plus one segment-state
## predicate (the MPSC `committed[i]` predicate lives in the sibling
## `segment_state.nim` module):
##
##   Family A — Bounded-Vyukov: Substrate: `MPMCCell[T]` with `payload.seq:
##   Atomic[uint64]`. Close sentinel: `ClosedBitB = high(uint64) shr 1` (64-bit
##   wide). Current call sites: NONE (placeholder for future bounded
##   close-on-empty; consumed by later phases).
##
##   Family B — LCRQ-integration: Substrate: `LCRQCell[T] = Atomic[Pair[uint,
##   T]]`. Close sentinel: `CLOSED_BIT`, platform-uint wide. Live consumer in
##   `queue.nim`.
##
## Import-cycle note: this module is a *substrate* for queue.nim (queue.nim
## imports it), so it MUST NOT import queue.nim. For Family B that means
## `seqIsClosed(s: uint)` takes a plain `uint` and uses a locally-defined
## `LCRQClosedBit` constant whose value is computed by the same formula as
## queue.nim's `CLOSED_BIT* = 1'u shl (sizeof(uint) * 8 - 1)`.
##
## Drift guard (honest scope): the import cycle (queue.nim imports THIS module)
## makes it impossible to `import` `CLOSED_BIT` here, so a true cross-module pin
## (`static: doAssert LCRQClosedBit == CLOSED_BIT`) CANNOT exist. Instead the
## two constants are kept equal by using the IDENTICAL formula, and a LOCAL
## static-assert at the bottom of this file pins this module's `LCRQClosedBit`
## to that canonical formula (`1'u shl (sizeof(uint) * 8 - 1)`). That tripwire
## fires if someone edits THIS module's constant away from the canonical
## formula. RESIDUAL RISK (explicit, not guarded): if someone edits queue.nim's
## `CLOSED_BIT` formula, the divergence is NOT caught here — the local assert
## only pins this module's side. Keeping both on the same literal formula is the
## only mitigation available without breaking the cycle.

import lockfree/atomics

# Family-A substrate import.
import ./mpmc_cell

# ----------------------------------------------------------------------
# Family A — Bounded-Vyukov (placeholder; zero call sites in v0.1.0).
# ----------------------------------------------------------------------

const ClosedBitB* = high(uint64) shr 1
  ## Family-A close sentinel. 64-bit wide because the Vyukov substrate is
  ## `Atomic[uint64]`. Distinct from Family-B's platform-uint `CLOSED_BIT` so
  ## the two substrates remain lexically separable (orthogonality rationale).

proc seqIsEmptyB*(s: uint64; pos: uint64): bool {.inline.} =
  ## Family A. Vyukov empty: `seq == pos`.
  s == pos

proc seqIsFilledB*(s: uint64; pos: uint64): bool {.inline.} =
  ## Family A. Vyukov filled: `seq == pos + 1`.
  s == pos + 1'u64

proc seqIsClosedB*(s: uint64): bool {.inline.} =
  ## Family A. Placeholder for future bounded close-on-empty; zero call sites in
  ## v0.1.0.
  (s and ClosedBitB) != 0'u64

proc seqIsClaimedB*(s: uint64; pos: uint64): bool {.inline.} =
  ## Family A. Bounded destructor walk: a slot is "claimed" when its seq has
  ## advanced past the filled epoch but has not been closed.
  s > pos + 1'u64 and not seqIsClosedB(s)

proc seqIsLiveB*[T](slot: var MPMCCell[T]; pos: uint64): bool {.inline.} =
  ## Family A. Loads `payload.seq` with `moRelaxed` and reports whether the slot
  ## is filled at epoch `pos` and not closed.
  let s = slot.payload.seq.load(moRelaxed)
  seqIsFilledB(s, pos) and not seqIsClosedB(s)

# ----------------------------------------------------------------------
# Family B — LCRQ-integration (live in v0.1.0).
# ----------------------------------------------------------------------

const LCRQClosedBit: uint = 1'u shl (sizeof(uint) * 8 - 1)
  ## Local mirror of queue.nim's `CLOSED_BIT`. Computed by the SAME canonical
  ## formula. We mirror rather than import because queue.nim imports this module
  ## (substrate inversion would create a cycle), so a cross-module pin to
  ## queue.nim's `CLOSED_BIT` is impossible. The LOCAL static-assert at the
  ## bottom of this file pins this constant to the canonical formula; see the
  ## module-level "Drift guard" note for the residual risk (an edit to
  ## queue.nim's formula is NOT caught here).

proc seqIsClosed*(s: uint): bool {.inline.} =
  ## Family B. LCRQ-integration close test. Replaces the inline `(<seq> and
  ## CLOSED_BIT) != 0'u` literals in queue.nim.
  (s and LCRQClosedBit) != 0'u

# ----------------------------------------------------------------------
# Local drift guard for `LCRQClosedBit`.
#
# A true cross-module pin (`doAssert LCRQClosedBit == CLOSED_BIT`) is
# impossible: queue.nim imports this module, so importing CLOSED_BIT back here
# would close a dependency cycle. This local assert pins THIS module's constant
# to the canonical formula (the same literal queue.nim uses for `CLOSED_BIT`),
# catching an accidental edit to `LCRQClosedBit` away from that formula. It does
# NOT catch an edit to queue.nim's formula — see the module-level "Drift
# guard" note for that residual risk.
# ----------------------------------------------------------------------
static:
  doAssert LCRQClosedBit == (1'u shl (sizeof(uint) * 8 - 1)),
    "LCRQClosedBit must equal the canonical CLOSED_BIT formula " &
    "(1'u shl (sizeof(uint) * 8 - 1)); a cross-module pin to queue.nim's " &
    "CLOSED_BIT is impossible due to the import cycle"
