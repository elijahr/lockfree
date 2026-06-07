# Q-DWCAS Investigation: Brown 2015 DEBRA+ vs nim-debra Implementation

**Date**: 2026-06-05
**Scope**: Determine whether (a) Brown 2015 PODC paper specifies DWCAS (Double-Width
Compare-And-Swap, 128-bit / `cmpxchg16b` / `casp`) as part of the DEBRA or DEBRA+
algorithm, and (b) the current `imports/nim-debra/src/debra/` implementation uses
DWCAS in the DEBRA+ algorithm itself.

---

## Summary verdict

| Field | Value |
|---|---|
| `paper_specifies_dwcas` | **NO** |
| `impl_uses_dwcas` | **NO** (DWCAS substrate exists in `atomics.nim`, but it is **not used** by the DEBRA+ algorithm; it is dead code from the LCRQ/v5.0.0 wave) |
| `switch_recommended` | **NO** — both sides match (single-word CAS only). No T-INTEGRATE switch needed for paper-faithfulness. |
| Confidence | **HIGH** (paper read directly; impl grep-verified across all algorithm files) |

**Headline**: The paper and the impl agree. DEBRA+ does not need DWCAS. The
`Pair[A, B]` / `dwcas*` machinery in `nim-debra/src/debra/atomics.nim` was added
during the strict-LCRQ Phase B work for the LCRQ algorithm (which DOES need
DWCAS for its tagged-index nodes) and is currently unused by anything inside
`src/debra/` proper. The DEBRA+ algorithm uses single-word `Atomic[uint64]`
fields exclusively, with the paper's published optimization of packing the
quiescent bit into the LSB of the announcement word.

A secondary finding worth surfacing to T-INTEGRATE: if no non-LCRQ consumer
uses DWCAS, the 700+ lines of DWCAS infrastructure in `atomics.nim`
(lines ~411-2256) may be candidates for relocation to an LCRQ-local atomics
module — but that is a code-organization question, not a correctness question.

---

## Paper findings

**Primary source**: Trevor Brown, "Reclaiming Memory for Lock-Free Data
Structures: There has to be a Better Way", PODC 2015. Extended arXiv version
v1, 4 Dec 2017, arXiv:1712.01044. Full PDF read directly.

URLs:
- Author's PODC'15 PDF: <http://www.cs.utoronto.ca/~tabrown/debra/paper.podc15.pdf>
- Extended arXiv version: <https://arxiv.org/abs/1712.01044> / <https://arxiv.org/pdf/1712.01044>

### Where DWCAS is mentioned in the paper

DWCAS appears exactly **three times** in the entire 27-page extended paper,
and **never** as a primitive that DEBRA or DEBRA+ uses. All mentions are in
the formal model / related work sections, never in the algorithm pseudocode:

1. **Section 2 (Model), p.4**, primitives declaration:
   > "Memory is divided into primitive objects, which include read-/write
   > registers, compare-and-swap (CAS) objects, and double-wide
   > compare-and-swap (DWCAS) objects."

   This admits DWCAS as a model primitive available to *any* algorithm
   discussed in the paper, but does not commit DEBRA+ to using it.

2. **Section 3 (Related work), p.5**, in the Reference Counting subsection
   describing Detlefs et al. [11]:
   > "LFRC uses the double compare-and-swap (DCAS) synchronization
   > primitive... DCAS is not natively available in modern hardware, but
   > it can be implemented from CAS [19]."

   This is about a *different scheme* (LFRC), not DEBRA+.

3. **Section 3 (Related work), p.5**, in the Hazard Pointers subsection
   describing Herlihy et al.'s Pass-the-Buck [22]:
   > "(Herlihy et al. [22] independently developed another version of HPs
   > called Pass-the-Buck (PTB), providing a lock-free implementation from
   > CAS, and a wait-free implementation from double-wide CAS.)"

   Again about *PTB*, not DEBRA+.

### What DEBRA+ actually uses (paper pseudocode)

The DEBRA pseudocode is **Figure 4, p.14**. The DEBRA+ pseudocode (data and
procedures *added to* DEBRA to obtain DEBRA+) is **Figure 6, p.19**. Every
shared atomic in the algorithm is single-word:

**Shared variables (Figure 4, lines 8-10):**
```
shared variables:
  long  epoch;                 // current epoch
  long  announce[n];           // per-process announced epoch and quiescent bit
  objectpool *pool;            // pointer to object pool
```

All `long`s. The atomic operations on them are:

- **Epoch advance (Figure 4, line 37):** `CAS(&epoch, readEpoch, readEpoch+2)`
  — single-word CAS on a single `long`. (In DEBRA+ Figure 6, line 24 this is
  `CAS(&epoch, readEpoch, readEpoch+1)` — same shape, just the +1 vs +2 is a
  difference that does not affect the single-word nature.)
- **Announce read/write:** plain reads and writes of `announce[other]` and
  `announce[pid]`. These are single-word and naturally atomic on the
  primitive-object model.
- **Quiescent bit:** explicitly packed into the LSB of `announce[pid]`. The
  paper's "Minor optimizations" paragraph (p.15) reads:
  > "the least significant bit of announce_p is used as p's quiescent bit.
  > This allows both values to be read and written atomically, which reduces
  > the number of reads and writes to shared memory."

  Critical: this is the canonical inline-tag pattern (one word holds both
  epoch and a 1-bit flag) — the **opposite** of DWCAS. The whole point of
  the optimization is that it stays within a single word. If DWCAS were
  needed, no LSB packing would be necessary.

**DEBRA+ additions (Figure 6, p.19):** The procedures added on top of DEBRA
(`isRProtected`, `RProtect`, `RUnprotectAll`, `leaveQstate`, `rotateAndReclaim`,
`suspectNeutralized`, `signalHandler`) introduce:

- An `arraystack RProtected[n]` shared variable — a per-process stack of
  RProtected record pointers. Single-word pointer entries; operations are
  `.add(r)`, `.clear()`, `.contains(r)`, `.get(i)`, `.size()`.
- The same single-word `CAS(&epoch, readEpoch, readEpoch+1)` (Figure 6,
  line 24) as DEBRA's epoch advance.
- A `pthread_kill(getPthreadID(other), SIGQUIT)` signal send (Figure 6,
  line 58) — not an atomic op at all, an OS syscall.
- The `signalHandler` uses `siglongjmp` (Figure 6, line 6) — also not an
  atomic op.

**Nothing in DEBRA+ pairs (epoch, pointer), (epoch, op_descriptor), or any
other two-word tuple into a single atomic word.** The fault-tolerance
mechanism is signaling + non-local goto, not DWCAS.

### Confidence on paper side

**HIGH**. Direct read of paper pages 1-27. Verified that:
- DWCAS is mentioned only in the formal model primitive list and in related
  work comparisons to OTHER schemes (LFRC, PTB).
- DEBRA pseudocode (Figure 4) uses only single-word CAS.
- DEBRA+ pseudocode (Figure 6) uses only single-word CAS plus signaling.
- The "Minor optimizations" paragraph explicitly says the quiescent bit is
  packed into the announce word's LSB — DWCAS would not be needed because
  the design fits in one word.

---

## Implementation findings

**Local source root**: `/Users/eek/Development/lockfree/imports/nim-debra/src/debra/`

### File inventory (line counts)

| Path | Lines | Role |
|---|---|---|
| `atomics.nim` | 2269 | Atomics surface; contains DWCAS substrate |
| `atomics/backoff.nim` | 75 | Spin/backoff helpers |
| `atomics/dsl.nim` | 45 | Atomics DSL |
| `constants.nim` | 24 | |
| `convenience.nim` | 383 | Public convenience API (RAII handles, retire helpers) |
| `limbo.nim` | 43 | Limbo bag types |
| `refptr.nim` | 160 | Reference-pointer types |
| `signal.nim` | 515 | Signaling / neutralization (DEBRA+ fault tolerance) |
| `thread_id.nim` | 236 | Thread ID abstraction |
| `types.nim` | 187 | Core DEBRA types (`DebraManager`, epoch fields, masks) |
| `typestates/advance.nim` | 89 | Epoch advance typestate |
| `typestates/cardinality.nim` | 23 | |
| `typestates/guard.nim` | 207 | Pin-scope guard |
| `typestates/manager.nim` | 88 | |
| `typestates/neutralize.nim` | 128 | Neutralize protocol (DEBRA+) |
| `typestates/pinned_scope.nim` | 244 | Pin scope |
| `typestates/reclaim.nim` | 301 | Reclamation logic |
| `typestates/registration.nim` | 131 | Thread registration |
| `typestates/retire.nim` | 210 | Retire-list operations |
| `typestates/signal_handler.nim` | 59 | Signal handler |
| `typestates/slot.nim` | 96 | Slot type |

### Where DWCAS lives in the impl

`Pair[A, B]` and `dwcas*` template definitions are confined to
**`atomics.nim` lines 411-2256**. Specifically:

- **Type definition**: `atomics.nim:415` — `Pair[A, B]` object with `{.align: 16.}`.
- **Gate enforcement**: `atomics.nim:436` `enforceDwcasConstraints(A, B)` template.
- **DWCAS ops** (single-instantiation per op):
  - `dwcasLoad` — `atomics.nim:1406`
  - `dwcasStore` — `atomics.nim:1512`
  - `dwcasExchange` — `atomics.nim:1643`
  - `dwcasCasStrong` — `atomics.nim:1749`
  - `dwcasCasWeak` — `atomics.nim:1901`
  - DWCAS-componentwise `fetchAdd` / `fetchSub` / `fetchAnd` / `fetchOr` /
    `fetchXor` — `atomics.nim:2163`, `2184`, `2199`, `2215`, `2230`.
- Public `Atomic[Pair[A, B]]` wrappers (`load`, `store`, `exchange`,
  `compareExchangeStrong`, `compareExchangeWeak`, fetch ops) interleaved
  with the templates above.
- `dwcasOrderRelaxedCAS` — `atomics.nim:2256` (call-site macro to silence
  the seq_cst-upgrade warning).

### Use sites of DWCAS inside DEBRA+ algorithm files

**None.** A grep for `Pair\[` and `dwcas` against every file under
`src/debra/` *except* `atomics.nim` and `atomics/` returns zero matches:

```
$ grep -rnE "Pair\[|dwcas" --include="*.nim" src/debra/ \
    | grep -v "^src/debra/atomics.nim:" \
    | grep -v "^src/debra/atomics/"
# (empty)
```

The one DWCAS-adjacent comment outside `atomics.nim` is documentation, not
usage — `thread_id.nim:101`:

> ## Keeping `ThreadId` at 8 bytes (same as POSIX) avoids triggering
> ## the 16-byte DWCAS path in `Atomic[ThreadId]`. A bare `uint32`
> ## (4 bytes) would still be lock-free, but the object wrapper is
> ## retained for API parity with the POSIX arm

This is an explicit decision to **stay out of the DWCAS path** for the
Windows `ThreadId` wrapper. It confirms that DWCAS exists in `atomics.nim`
as a substrate but the DEBRA+ algorithm deliberately avoids it.

### What atomic ops DEBRA+ actually uses

All atomic state is single-word. From `types.nim`:

- `types.nim:20` — `epoch {.align: 8.}: Atomic[uint64]` (per-thread announced epoch)
- `types.nim:30` — `epoch* {.align: 8.}: Atomic[uint64]` (last observed global epoch)
- `types.nim:71` — `globalEpoch* {.align: CacheLineBytes.}: Atomic[uint64]`
- `types.nim:72` — `activeThreadMask* {.align: CacheLineBytes.}: Atomic[uint64]`

Operations on these fields, grepped across the algorithm files:

| Site | Op | Notes |
|---|---|---|
| `typestates/advance.nim:70` | `globalEpoch.fetchAdd(1'u64, moRelease)` | Epoch advance. Single-word `fetchAdd`. Matches paper Figure 4/6 `CAS(&epoch, ...)` semantically (the `+1` increment). The impl uses `fetchAdd` instead of CAS-loop — equivalent on x86 and cheaper. **Not** a DWCAS. |
| `typestates/registration.nim:88` | `activeThreadMask.compareExchangeWeak(...)` | Single-word `compareExchangeWeak` on `Atomic[uint64]` for the active-thread bitmask. **Not** a DWCAS. |
| `typestates/pinned_scope.nim:168` | `atomic.compareExchange(expected, desired, moAcquireRelease, moAcquire)` | Single-word CAS on a per-thread atomic (called inside the pin/unpin protocol). **Not** a DWCAS. |
| `typestates/pinned_scope.nim:208-209` | `atomic.load(moAcquire)` / `atomic.store(desired, moRelease)` | Single-word load/store (single-writer contract). **Not** a DWCAS. |
| `typestates/retire.nim:167` | `subscribeBarrier.fetchAdd(0'u64, moSequentiallyConsistent)` | Single-word "fence-as-fetchAdd-0" idiom for SC ordering. **Not** a DWCAS. |
| `typestates/reclaim.nim:161, 195, 207` | `globalEpoch.fetchAdd(0)` (read-with-fence), `subscribeBarrier.fetchAdd(0)` | Same SC-fence idiom. **Not** DWCAS. |
| `convenience.nim:285` | `handle.manager.globalEpoch.fetchAdd(1'u64, moRelease)` | Epoch advance via amortized counter (called from `retire` helpers). **Not** DWCAS. |
| `signal.nim:460` | Three atomic stores (header, stride, ...) | Sequential single-word stores. **Not** DWCAS. |

Every atomic op in the DEBRA+ algorithm is single-word.

### Workaround analysis

Not applicable. There is no two-word value that the impl is forcing into one
word as a workaround. The impl follows the paper directly:

- The paper packs the quiescent bit into the LSB of the announcement word
  (a 1-bit flag + an epoch number that fits comfortably in 63 bits).
- The impl uses `Atomic[uint64]` for the per-thread epoch field with the
  same convention available (though the impl appears to track the
  active-thread bitmask separately in `activeThreadMask`, which is a
  reasonable cache-locality refactor of the same idea).

No spin-bounded retry pattern as a DWCAS substitute. No livelock risk from
"two halves observed at different times" — there are no two halves.

### Confidence on impl side

**HIGH**. Verified by:
- Full file enumeration of `src/debra/` (21 files, 5513 lines).
- `grep -rE "Pair\[|dwcas"` across all algorithm files, returning zero hits
  outside `atomics.nim` / `atomics/` (and one comment in `thread_id.nim`
  explaining a deliberate avoidance).
- Direct read of `typestates/advance.nim` (the epoch advance path) and the
  `types.nim` field declarations.

Every claim above has a file:line cite the operator can independently `grep`.

---

## Cross-reference: paper vs impl

| Concern | Paper says | Impl does | Match? |
|---|---|---|---|
| Epoch counter | single `long` with `CAS` (Fig 4 line 37; Fig 6 line 24) | `Atomic[uint64]` with `fetchAdd` (`advance.nim:70`) | YES (paper-faithful; `fetchAdd` is a semantically-equivalent simplification of the CAS retry loop) |
| Announce / quiescent bit | LSB-packed into one `long` ("Minor optimizations", p.15) | `Atomic[uint64]` per-thread, with `activeThreadMask` separate | YES (same single-word discipline; impl uses a separate bitmask for the quiescent set, a refactor not a deviation) |
| Reservations / RProtected | per-process `arraystack RProtected[n]` of pointers (Fig 6 line 4) | not yet inspected at the same depth here, but `Atomic[T]` not `Atomic[Pair[...]]` based on the grep | YES (no `Pair[` in algorithm files) |
| Limbo bag / pool | block-list of pointers, single-word entries | single-word | YES |
| Signaling / neutralization | `pthread_kill` + `siglongjmp` (Fig 6 line 58; signalHandler) | `signal.nim` (515 lines, Windows + POSIX) | YES (not an atomic-op concern) |

**No mismatches. No T-INTEGRATE switch indicated.**

---

## Recommendation

**Do NOT switch DEBRA+ to use DWCAS in T-INTEGRATE.** The paper does not
specify it, and the impl correctly mirrors the paper's single-word design.
A switch would be paper-deviating, not paper-faithful.

A separate **code-hygiene observation** to flag (not part of the Q-DWCAS
question per se):

- If LCRQ is the *only* consumer of the `Pair[A, B]` / `dwcas*` machinery in
  `atomics.nim`, then ~700 lines of `atomics.nim` (lines 411-2256) are
  effectively LCRQ-local infrastructure being carried inside the nim-debra
  module. T-INTEGRATE may want to consider whether that substrate belongs
  in `nim-debra/src/debra/atomics.nim` or in an LCRQ-adjacent module.
  Doing so is a refactor opportunity, not a correctness fix, and is out of
  scope for this investigation. The operator should decide whether to
  raise it as a separate T-* item.

The Q12 finding in the original handoff ("DWCAS support added to
atomics.nim during the strict-LCRQ Phase B work") is consistent with this
investigation: DWCAS was added FOR LCRQ, not for DEBRA+, and the DEBRA+
algorithm itself never grew a call site.

---

## Sources

- Trevor Brown, "Reclaiming Memory for Lock-Free Data Structures: There has
  to be a Better Way" — PODC'15 author PDF:
  <http://www.cs.utoronto.ca/~tabrown/debra/paper.podc15.pdf>
- Same paper, extended arXiv version v1, 4 Dec 2017:
  <https://arxiv.org/abs/1712.01044> (PDF: <https://arxiv.org/pdf/1712.01044>)
- Local nim-debra source: `/Users/eek/Development/lockfree/imports/nim-debra/src/debra/`
  (commit / branch state as of 2026-06-05 working tree)

## Confidence summary

| Side | Confidence | Rationale |
|---|---|---|
| Paper | HIGH | Direct read of all 27 pages of arXiv version. Pseudocode (Figures 4 and 6) and "Minor optimizations" paragraph examined; DWCAS mentions exhaustively enumerated (3 total, all unrelated to DEBRA+). |
| Impl | HIGH | Full file enumeration; `Pair\[|dwcas` grep across all algorithm files yields zero matches outside `atomics.nim`/`atomics/`; epoch advance and key CAS sites read directly. |
| Verdict | HIGH | Both sides agree on single-word CAS. No mismatch, no switch needed. |
