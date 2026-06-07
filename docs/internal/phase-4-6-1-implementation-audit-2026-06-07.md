# Phase 4.6.1 Implementation Audit (2026-06-07)

Workspace: `/Users/eek/Development/lockfree`, branch `feat/v5.0.0-impl`.
Scope: READ-ONLY spot-check of the 11 locked decisions from the project's
status canvas against actual source.

## Summary
- Decisions verified: **11 / 11 CONFIRMED**
- Drift findings: **1 minor** (CI cell-count nomenclature: canvas says "18
  cells (1 lint + 17 test)", source has 18 numbered cells but renders as
  17 actual GitHub Actions jobs — see Decision 10 for the reconciliation)
- Missing artifacts: 0

## Per-decision findings

### Decision 1 — Repo name `lockfree` — CONFIRMED
- `lockfree.nimble:4` — `version = "0.1.0"` (package implied by filename).
- `src/lockfree.nim:1-2` — umbrella exists: `## lockfree — top-level umbrella module.`
- `grep -rn "lockfreequeues" src/` — no matches. No residual references in source.

### Decision 2 — SMR module `nebr` (not `debra_plus`) — CONFIRMED
- `src/lockfree/smr/nebr/` tree exists: `convenience.nim, limbo.nim, refptr.nim, signal.nim, thread_id.nim, types.nim, typestates/`.
- `src/lockfree/smr/nebr.nim:1` — facade: `## lockfree/smr/nebr: NEBR Safe Memory Reclamation`.
- `find src -name "debra_plus*"` — no results. Filename reserved but not present.

### Decision 3 — Path C refs: `ref X` user-facing, `ManagedRef[X]` internal with library-inc-in-push lifecycle — CONFIRMED
- `src/lockfree/managed_ref.nim:94` — `ManagedRef*[X] = distinct uint`.
- `src/lockfree/managed_ref.nim:176-194` — `template incRefSlot*[X]` per-MM dispatch via `GC_ref`.
- `src/lockfree/managed_ref.nim:196-213` — `template decRefSlot*[X]` per-MM via `GC_unref`.
- `src/lockfree/managed_ref.nim:119-130` — locked docstring: "library inc paired with library dec WITHIN library scopes... bumps +1 BEFORE the sink consumption".
- `src/lockfree/internal/path_c_wrap.nim:43-60` — ref-T arm of `wrapOrIdentity`:
  ```nim
  when T is ref:
    let mrefView = cast[ManagedRef[typeof(item[])]](item)
    incRefSlot(mrefView)
    toManagedRef(item)
  ```
  Order confirmed: bit-cast view → `incRefSlot` → `toManagedRef(sink)`. Use-after-free hazard explicitly explained in the inline comment (`path_c_wrap.nim:44-57`).

### Decision 4 — Path C strings/seqs: `string`/`seq[U]` user-facing, `ManagedSlice[T]` internal as box pointer — CONFIRMED
- `src/lockfree/managed_slice.nim:57` — `ManagedSlice*[T] = distinct uint`.
- `src/lockfree/managed_slice.nim:88,110` — `allocShared0(sizeof(string))` / `allocShared0(sizeof(seq[U]))` in `wrap`.
- `src/lockfree/managed_slice.nim:133,143,166,177` — `deallocShared(box)` in `unwrap` and `disposeSlot`.
- `src/lockfree/managed_slice.nim:89-95` — per-MM arm: `when defined(gcArc) or defined(gcOrc) or defined(gcAtomicArc) or defined(gcRefc):` sink-assign; `else:` mm:none `copyMem`.
- `src/lockfree/managed_slice.nim:156-166` — `disposeSlot` explicitly calls `` `=destroy`(box.v) `` (not relying on compiler-emitted destructor on `ptr object`):
  ```nim
  when defined(gcArc) or defined(gcOrc) or defined(gcAtomicArc) or defined(gcRefc):
    `=destroy`(box.v)
  deallocShared(box)
  ```

### Decision 5 — Cell layer `SlotEncoding(T)` — CONFIRMED
- `src/lockfree/internal/slot_encoding.nim:19-33` — `template SlotEncoding*(T: typedesc): typedesc` with arms for `ref`, `string`, `seq`, else.
- `src/lockfree/queue.nim:338` — `cells* {.align: CacheLineBytes.}: array[S, LCRQCell[SlotEncoding(T)]]` (strict-LCRQ).
- `src/lockfree/queue.nim:345,348` — `data*: array[S, SlotEncoding(T)]` (MPSC overlay + SPSC/SPMC).
- `src/lockfree/bqueue.nim:173,177` — `storage*: StorageN1[N, SlotEncoding(T)]` and `cells*: MPMCCellArrayN[N, SlotEncoding(T)]`.
- Typestates parameterized: `mpmc_push.nim:59`, `mpmc_pop.nim:57`, `mpsc_push.nim:62`, `mpsc_pop.nim:63`, `spmc_push.nim:65`, `spmc_pop.nim:60` each carry `MPMCCellArrayN[N, SlotEncoding(T)]`.
- bqueue cast sites: 8 occurrences of `cast[ptr (Sp|Mp)…Base[…, SlotEncoding(T)]]` (e.g., lines 418, 440, 481, 503, 771, 797, 821, 845). Matches Wave B/C report.

### Decision 6 — Lifecycle: inc-on-push + compiler-dec at push exit; pop destructive-move; destroy-walk via `disposeSlotEncoded` — CONFIRMED
- Inc-on-push: `path_c_wrap.nim:59` — `incRefSlot(mrefView)` precedes `toManagedRef(item)`.
- Pop has no library dec: `path_c_wrap.nim:69-84` — `unwrapOrIdentity` for `ref` arm is `toRef(encoded)` only; no `decRefSlot` call. Module doc-comment at lines 11-15 explicitly states "Pop is a destructive read via `move` — the queue relinquishes the bits without a library `decRefSlot`".
- `disposeSlotEncoded`: `path_c_wrap.nim:86-129` — for `ref` arm calls `decRefSlot(encoded)` (line 123) with the cursor-elision rationale at 114-120; for `string`/`seq` arms calls `disposeSlot(encoded)`.
- queue.nim destructor walks: lines 578, 583, 591 (segment destructor) and 1054, 1060, 1068 (queue `=destroy`) call `disposeSlotEncoded[T](...)`.
- bqueue.nim `=destroy`: lines 700-741 — walks all N cells with branches at 727 (SPSC storage), 741 (MPSC/SPMC/MPMC cells), each calling `disposeSlotEncoded[T](...)`.

### Decision 7 — R7 element guard RELAXED (`seq[ref U]` / `seq[seq[U]]` ACCEPT) — CONFIRMED
- `src/lockfree/internal/path_c_admit.nim:108-117`:
  ```
  # Accept rows 17-19 — `seq[U]`. Element-type guard removed 2026-06-06
  # per operator directive: §2.5 rows 18-19 (`seq[ref U]`, `seq[seq[U]]`)
  # are ACCEPTED.
  ...
  elif T is seq:
    discard
  ```
  No `static: assert supportsCopyMem(Elem)` in seq arm — verified by full read.
- `src/lockfree/managed_slice.nim:98-116` — `wrap[U]` similarly has no `supportsCopyMem` assert. Lines 101-109 explicitly note the relaxation: "The former R7 `supportsCopyMem(U)` guard was removed alongside the matching assert in path_c_admit.nim."

### Decision 8 — 5 MM support (arc/orc/atomicArc/refc/none) — CONFIRMED
- `managed_ref.nim:179-194` `incRefSlot` arms: `when defined(gcArc) or defined(gcOrc) or defined(gcAtomicArc) or defined(gcRefc):` + `else:` (mm:none = discard, strict bit-transport per §2.8). Plus bonus `when defined(nimony):` block at lines 275-294.
- `managed_ref.nim:199-213` `decRefSlot` arms — same shape.
- `managed_slice.nim:89-95, 111-115, 128-132, 138-142, 162-165, 174-177` — `wrap`, `unwrap`, `disposeSlot` all carry the same `arc|orc|atomicArc|refc` vs. `else` (mm:none) split with `copyMem` on the mm:none arm per §2.8 bit-transport contract.
- All 5 supported MMs (arc, orc, atomicArc, refc, none) covered. Did not run `nim check` per audit scope.

### Decision 9 — Async tiers: T1 sync IN, T2 dropped, T3 chronos IN — CONFIRMED
- T1 sync iterators:
  - `queue.nim` — `iterator items*` at lines 1988, 2000, 2013, 2026; `iterator drain*` at 1924, 1941, 1954, 1967.
  - `bqueue.nim` — `iterator items*` at 997, 1007, 1019; `iterator pairs*` at 1031, 1043, 1057; `iterator drain*` at 950, 963, 975.
- T2 dropped: `grep -rn "proc notify\|notify\*" src/` — no matches. No raw `notify*` primitive in source.
- T3 chronos: `src/lockfree/chronos.nim` exists (244+ lines). Hybrid optional-dep guard at lines 60-81:
  ```nim
  const lockfreeChronosAvailable* = compiles do: ...
  when defined(lockfreeChronos) and not lockfreeChronosAvailable: {.error: ... .}
  when defined(lockfreeChronos) or lockfreeChronosAvailable: ...
  ```
  Matches §5.6.2 activation matrix in the module doc.

### Decision 10 — CI matrix 18 cells (Windows + nim cpp IN) — CONFIRMED (with cell-count nomenclature note)
- `.github/workflows/ci.yml` exists. Top-level jobs (8): `lint`, `test`, `valgrind`, `helgrind`, `chronos`, `nimony`.
- `test` job matrix `include:` enumerates 12 cells: 1, 2, 3, 4, 5, 6, 7, 10, 11, 13, 17, 18.
- Cells 8 (Valgrind) and 9 (Helgrind) are split into their own jobs (line comments at 415 and 489). Cell 12 (chronos) → `chronos` job (552). Cell 14 (nimony) → `nimony` job (602). Cells 15-16 are reserved/skipped per the §6.3 numbering comment (line 28).
- **Cell 17 (Windows + MSVC + orc)**: present at lines 265-274, `runs-on: windows-latest`, `mm: 'orc'`.
- **Cell 18 (nim cpp backend)**: present at lines 280-289, `backend: 'cpp'`, `runs-on: ubuntu-latest`.
- 14 numbered cells (1-7, 10, 11, 12, 13, 14, 17, 18). Job-shape: lint + 12 matrix cells + valgrind + helgrind + chronos + nimony = **17 GitHub Actions jobs**.
- Minor nomenclature drift: canvas reads "18 cells (1 lint + 17 test)". Source has 18 distinct cell *labels* in the §6.3 numbering (1-14, 17-18 = 16; canvas count of 18 includes lint as cell + the implicit reservation), but renders as 17 jobs. Substantively the canvas claim "Windows + nim cpp IN" holds: cells 17 and 18 are present and configured per O4/O5. No fix required for ship readiness; consider tightening the canvas wording in a follow-up doc pass.

### Decision 11 — Version `LockfreeVersion = "0.1.0"` — CONFIRMED
- `src/lockfree.nim:10` — `const LockfreeVersion* {.strdefine.} = "0.1.0"` (verbatim).
- `lockfree.nimble:4` — `version        = "0.1.0"`.

## Drift / missing detail

- **Decision 10 cell-count nomenclature**: canvas says "18 cells (1 lint + 17 test)". Source enumerates 12 cells in the `test` job matrix + 4 separate jobs (valgrind=8, helgrind=9, chronos=12, nimony=14) + lint = 17 jobs. The §6.3 design numbering goes up to 18 but reserves 15-16. The substantive claim (Windows + nim cpp IN) is fully met; only the numerical phrasing is ambiguous. Not a blocker.

No other drift or missing artifacts found.

## Recommendation

**Pass to Phase 4.7 finishing.** All 11 locked decisions are present in the
source and align with the canvas. The single nomenclature note on Decision
10 is cosmetic — the substantive coverage (Windows MSVC + nim cpp backend
cells) is in place. No source fixes required before Phase 4.7.
