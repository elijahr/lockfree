# Section 4: MM Compat Shim & Cell Layouts

> Status: v0.1.0 design — Section 4 of 7. Locked decisions per handoff
> Session updates (2026-06-05), the operator dispositions on Phase 1.6
> devil's-advocate findings (CRITICAL #2: mm:none strict contract +
> drain/destroyAndDrain helpers REQUIRED in v0.1.0; implementation
> gotcha: pop MUST clear payload bits across ALL cardinality arms),
> and the Phase 1.5 Batch 1 captured answers (mm:none REQUIRED;
> ManagedSlice IN scope). Sibling sections: architecture (1), types
> & payloads (2), SMR architecture & nebr (3), public APIs (5), CI +
> nimony (6), docs IA + risks (7).
>
> Scope: per-MM refcount-op matrix (the full enumeration that Section
> 2's "Per-MM compat shim arms" sketch references as "finalised in
> §4"), per-arm × per-payload cell shape matrix (the full enumeration
> that Section 2 references as "the queue's slot type"), slot-state
> predicates factored out of the v5.0.0 inline literals, the
> destructor walk that calls `decRefSlot` on live slots at teardown,
> the drain/destroyAndDrain helpers required by the mm:none strict
> contract, and the ABI guarantees that make `--mm:X` orthogonal to
> queue layout.
>
> Out of scope: module layout (§1); T constraint catalog and Path C
> design rationale (§2); nebr safety argument and segment retire path
> (§3); public push/pop/iterator signatures, batched operations, and
> result types (§5); CI matrix and nimony partial-port decision (§6);
> docs IA and migration narrative (§7).

## 4.1 What the shim is

The MM compat shim is a thin abstraction layer between the queue
implementation and the C-RTL refcount symbols emitted by the Nim
compiler under `--mm:arc`, `--mm:orc`, `--mm:atomicArc`, `--mm:refc`,
`--mm:none`, and (target) the nimony aufbruch backend. It exists for
exactly two reasons:

1. **Centralisation.** A future Nim release that renames
   `nimDecRefIsLast` to `nimDecRefIsLastNew` (or splits the symbol
   into two variants per RFC, as happened with the addition of
   `nimDecRefIsLastDyn`/`nimDecRefIsLastCyclicDyn` in orc.nim:517,529)
   requires editing exactly one file in lockfree — the shim. Without
   the shim, every push/pop/destroy wrapper in `Queue[ref X, ...]` and
   `Queue[string, ...]` (and the bounded equivalents) would need to
   carry a `when defined(arc):` arm. That blast radius is
   unacceptable on a library that explicitly tracks five MMs and a
   sixth backend candidate.
2. **Single point of audit.** The lifecycle correctness argument
   (Section 2.4 — Path C refcount accounting) must hold for every MM
   the library supports. Concentrating the per-MM behaviour in one
   table-shaped module makes that argument checkable by reading one
   file. A reviewer who knows the abstract trace (push: inc; pop:
   dec; destroy: dec all live) can verify each MM arm against the
   trace independently without re-reading queue.nim.

### Shape

The shim lives in two files:

```
lockfree/managed_ref.nim    # ManagedRef[X] + per-MM ref-shim arms
lockfree/managed_slice.nim  # ManagedSlice[T] + per-MM slice-shim arms
```

Both files share an identical `when defined(MM): … else: …` skeleton
and re-export a small surface (`incRefSlot`, `decRefSlot`,
`destroyAndDispose`) consumed by the cardinality wrappers (Section
5). Section 2 introduced the surface; this section finalises the
per-MM bodies.

### Surface

The shim's public-internal surface (callable only from the
cardinality wrappers — not from user code) is:

**Enforcement pick (v0.1.0):** documentation-only. The modules
`src/lockfree/managed_ref.nim` and `src/lockfree/managed_slice.nim`
sit at the top level of the package (not under `internal/`) so that
the post-T-INTEGRATE `queue.nim` / `bqueue.nim` can `import
lockfree/managed_ref` / `lockfree/managed_slice` without a
`internal/`-prefixed path. The "not for external import" contract is
enforced by:
1. A prominent header doc-comment in each module stating
   "Internal-only module; do not import directly. Use `Queue[ref T]`
   / `Queue[string]` / `Queue[seq[T]]` instead. See
   `docs/guide/managed-ref.md` / `docs/guide/managed-slice.md`."
2. `guide/managed-ref.md` and `guide/managed-slice.md` describe the
   user-facing `ref T` / `string` / `seq[T]` surface only; they do
   not document `ManagedRef[X]` / `ManagedSlice[T]` types or the
   `incRefSlot` / `decRefSlot` templates as user API.
3. The auto-generated `api/` reference under `mkdocstrings-nim` omits
   these modules from the user-facing nav (configured via
   per-module `:exclude:` directive in the mkdocs nav).

Stronger enforcement (moving under `internal/`, or `{.deprecated.}`
warnings on every export) is **deferred to v0.2.0** pending operator
feedback on whether the doc-only contract is sufficient. The pick is
revisitable; the module relocation is mechanical if a stronger pick
is later chosen.

The surface:

```nim
# managed_ref.nim
template incRefSlot*[X](mref: ManagedRef[X])
template decRefSlot*[X](mref: ManagedRef[X])
template isUniqueSlot*[X](mref: ManagedRef[X]): bool   # debug-only
proc toManagedRef*[X](r: sink ref X): ManagedRef[X] {.inline.}
proc toRef*[X](mref: ManagedRef[X]): ref X {.inline.}
proc toBits*[X](mref: ManagedRef[X]): uint {.inline.}
proc fromBits*[X](_: typedesc[ManagedRef[X]], bits: uint): ManagedRef[X] {.inline.}
const nilManagedRef*: ManagedRef[X] = ManagedRef[X](0)

# managed_slice.nim — analogous, plus
proc toManagedSlice*(s: sink string): ManagedSlice[char] {.inline.}
proc fromManagedSlice*(m: ManagedSlice[char]): string {.inline.}
proc toManagedSlice*[U](s: sink seq[U]): ManagedSlice[U] {.inline.}
proc fromManagedSlice*[U](m: ManagedSlice[U]): seq[U] {.inline.}
```

The four ops the queue actually invokes in hot paths are
`incRefSlot`, `decRefSlot`, `toManagedRef`/`toManagedSlice` (push
entry), and `toRef`/`fromManagedSlice` (pop exit). `isUniqueSlot` is
debug instrumentation only — it is used by the destructor walk
under `-d:lockfreeRefcountAudit` to assert that a slot's refcount
hits zero at the expected dec, never on the hot path.

The push/pop wrappers (Section 5) call these ops in the order
prescribed by the Path C trace in Section 2.4. Section 4 only spells
out the per-MM bodies and confirms that each body satisfies the
trace. The trace itself is not re-derived here.

---

## 4.2 MM × shim-op matrix (full enumeration)

The shim resolves to one of six arms per op. Each cell of the matrix
below names the C-RTL symbol the arm calls, with a file:line citation
into the Nim source tree at the pinned compiler version (Nim 2.2.10,
`~/.nimble/pkgcache/githubcom_nimlangNimgit_2210/lib/system/`).

### 4.2.1 ManagedRef per-MM matrix

| MM             | incRefSlot                                        | decRefSlot                                                | destroyAndDispose                                       | Notes                                                                                                                                                                                                                                                                                                                                       |
| -------------- | ------------------------------------------------- | --------------------------------------------------------- | ------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `--mm:none`    | `discard` (no-op)                                 | `discard` (no-op)                                         | `discard` (no-op)                                       | Pure bit transport per Phase 1.6 CRITICAL #2 disposition. The queue is a bit-transfer mechanism only; no refcount ops are emitted. The user is responsible for draining unpopped items before destroy (see §4.8).                                                                                                                            |
| `--mm:refc`    | `GC_ref(cast[ref X](bits))`                       | `GC_unref(cast[ref X](bits))`                             | implicit (refc tracing GC frees on cycle scan)          | refc uses a tracing collector with explicit `GC_ref`/`GC_unref` shims. The wrappers store no extra header; the refcount lives on the refc heap header. UNCERTAIN — see §4.11 OQ4.1: confirm `GC_ref` is the public symbol exposed by refc system module at the pinned compiler version. If not, the refc arm falls back to a copy/discard model (refc strings already do this; consistent).      |
| `--mm:arc`     | `nimIncRef(p)` — `arc.nim:167`                    | `nimDecRefIsLast(p)` — `arc.nim:238`                      | `nimDestroyAndDispose(p)` — `arc.nim:218`               | Direct symbol mapping. arc's `nimDecRefIsLast` returns `true` iff the dec brought the cell to zero; the shim's `decRefSlot` chains `if nimDecRefIsLast(p): nimDestroyAndDispose(p)`.                                                                                                                                                          |
| `--mm:orc`     | `nimIncRefCyclic(p, cyclic=false)` — `orc.nim:46` | `nimDecRefIsLastDyn(p)` — `orc.nim:529`                   | `nimDestroyAndDispose(p)` — `arc.nim:218`               | Two-flavour dec: `Dyn` (acyclic-fast-path with cycle bookkeeping) at orc.nim:529 vs `CyclicDyn` (always-cyclic) at orc.nim:517. Queue payloads are NOT marked cyclic at push because `T = ref X` for X = user type may or may not be cyclic from the queue's perspective; orc's runtime decides via the cell's `maybeCycle` bit. Acyclic-fast-path (`nimDecRefIsLastDyn`) is correct: it consults the cell's maybeCycle bit and routes to cycle collector on dec when the bit is set. |
| `--mm:atomicArc` | `nimIncRef(p)` (atomic) — `arc.nim:167`         | `nimDecRefIsLast(p)` (atomic dec) — `arc.nim:238,248-252` | `nimDestroyAndDispose(p)` — `arc.nim:218`               | Same C-RTL symbol names as arc. atomicArc's atomic-dec compile-time branch lives at `arc.nim:248-252` inside the body of `nimDecRefIsLast`. From the shim's perspective the arc and atomicArc arms are byte-identical; the C-RTL substitutes the atomic op transparently when `gcAtomicArc` is defined. The shim collapses both into one `when` arm. |
| nimony aufbruch | `arcInc(memLoc)`                                  | `arcDec(memLoc): bool`                                    | nimony's equivalent of `nimDestroyAndDispose` (TBD — see §7.4 OQ4.2) | Different signature shape: nimony's `arcInc`/`arcDec` operate on a `var int` *memLoc* (the refcount field of the heap header), not on `pointer p`. The shim adapter computes the address of the refcount field within the heap allocation (`addr cast[ptr NimHeapHeader](bits)[].rc`) and passes it to nimony. UNCERTAIN — see §4.11 OQ4.2: confirm the layout of nimony's heap header so the offset is correct. If the layout cannot be verified at the time of v0.1.0 ship, nimony's `ref T` arm is marked `notyet` per Section 6. |

### 4.2.2 ManagedSlice per-MM matrix

The string/seq shims call the **same** underlying C-RTL symbols
(`nimIncRef`/`nimDecRefIsLast`/`nimDestroyAndDispose`) because Nim 2's
`NimStringV2` (string heap header) and `NimSeqV2[T]` (seq heap header)
both carry the same `RefHeader` shape that `ref T` allocations carry
— see arc.nim's `head(p)` template (used at arc.nim:165, 173, 241,
etc.) which assumes `p -! sizeof(RefHeader)` is the cell origin
regardless of payload type. The cell ops are payload-agnostic; only
the cast back to `string`/`seq[T]` at pop time is payload-specific.

| MM             | incRefSlot (slice)                                | decRefSlot (slice)                                        | Notes                                                                                                                                                                                                                                                                                                                                       |
| -------------- | ------------------------------------------------- | --------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `--mm:none`    | `discard` (no-op)                                 | `discard` (no-op)                                         | Same rationale as ref. The bits are a raw pointer to a `NimStringV2`-shaped header; the user manages lifecycle.                                                                                                                                                                                                                              |
| `--mm:refc`    | copy-on-push, free-on-pop                         | implicit at pop                                           | refc strings are GC-managed value types with copy-on-write semantics; modelling them as refcounted transport would be wrong. Push copies the string body into a fresh refc allocation; pop reassembles into a refc string (which the refc GC will free in due course). UNCERTAIN — see §4.11 OQ4.3: confirm copy semantics match user expectation under refc strings ≥ Nim 2.0.4. |
| `--mm:arc`     | `nimIncRef(headerPtr)` — `arc.nim:167`            | `nimDecRefIsLast(headerPtr)` — `arc.nim:238`              | The `headerPtr` is the pointer stored in the slot — the `NimStringV2*` / `NimSeqV2[T]*`. arc treats it as any other refcounted cell. The fact that the cell content is a length-prefixed buffer is opaque to the refcount layer.                                                                                                              |
| `--mm:orc`     | `nimIncRefCyclic(headerPtr, false)` — `orc.nim:46`| `nimDecRefIsLastDyn(headerPtr)` — `orc.nim:529`           | Strings/seqs are not cyclic by construction (the heap header points only to a flat buffer with no `ref` fields). The cyclic flag is irrelevant; acyclic-fast-path is correct.                                                                                                                                                                |
| `--mm:atomicArc` | `nimIncRef(headerPtr)` — `arc.nim:167`          | `nimDecRefIsLast(headerPtr)` (atomic) — `arc.nim:238,248-252` | Same as arc.                                                                                                                                                                                                                                                                                                                                |
| nimony aufbruch | `arcInc(memLoc)` on header rc field               | `arcDec(memLoc)` on header rc field                       | If nimony's string/seq representation diverges from Nim 2's `NimStringV2`/`NimSeqV2`, ManagedSlice on nimony is marked `notyet` per Section 6. The handoff explicitly flagged this as an open item (Q4/Q5). UNCERTAIN — see §4.11 OQ4.4.                                                                                                       |

### 4.2.3 Op routing in the wrappers

The push wrapper (Section 5) does, per push:

```nim
# inside pushRef[X]
let mref = toManagedRef(item)   # sink ref X -> ManagedRef[X]; no incRef
incRefSlot(mref)                # queue takes a reference
if slotPushBits(toBits(mref)):
  result = true                  # incRef stays balanced by a future decRef
else:
  decRefSlot(mref)               # roll back the incRef; queue rejected
  result = false
# `item: sink ref X` goes out of scope here. Under arc/orc/atomicArc the
# compiler-emitted =destroy runs the matching dec on `item`; the call to
# `incRefSlot(mref)` above raised the count by one so this net is +1
# (the queue's reference). Under mm:none, both the destroy and the
# incRefSlot are no-ops.
```

The pop wrapper does, per pop:

```nim
# inside popRef[X]
let bits = slotPopBits()          # atomic claim, returns raw uint bits
let mref = fromBits(ManagedRef[X], bits)
result = some(toRef(mref))        # bit cast back; no incRef. Caller now owns the
                                  # +1 the queue held; queue's bookkeeping
                                  # is the matching missing -1.
# IMPORTANT: pop MUST clear the slot bits to nilManagedRef AFTER the
# atomic claim is published. See §4.5 for the per-arm clear mechanism
# (this is the Phase 1.6 implementation gotcha).
```

The destructor walk does, per live slot, at queue teardown:

```nim
# inside =destroy[Queue[T, ...]]
for slot in liveSlots(q):
  let bits = readSlotBits(slot)        # plain load is safe — no other thread
                                       # references this queue at =destroy time
  if bits != 0:                        # not nil
    decRefSlot(fromBits(ManagedRef[X], bits))
# arc/orc/atomicArc: the dec releases the +1 the queue held.
# mm:none: discard. The user must have drained first; if not, leak.
```

These three wrappers (push, pop, destructor walk) are the **only**
sites in the library that invoke shim ops. The cardinality typestate
files (Section 5 directs them to be lifted essentially verbatim from
v5.0.0 with the lift adapters) operate on uint bits and never see
`ManagedRef[X]` directly.

### 4.2.4 Cross-backend / cross-OS notes (per O4 + O5 resolutions 2026-06-06)

The MM × shim-op matrix above enumerates the shim arms per Nim MM
(orc, arc, refc, atomicArc, mm:none, nimony aufbruch). Two
orthogonal axes were added to v0.1.0 CI scope on 2026-06-06 (Section
6 cells 17 and 18) and merit explicit notes against the shim
matrix:

- **Windows + MSVC backend (Section 6 cell 17, per O4 resolution
  2026-06-06).** Under Windows + MSVC, the atomics shim uses
  `_InterlockedCompareExchange128` for DWCAS rather than the C11
  `__atomic_compare_exchange_n` / clang/gcc `__sync_*` intrinsic
  used on Linux/macOS. This arm is **already present in
  `imports/nim-debra/src/debra/atomics.nim`** (inherited via
  T-INTEGRATE.a). The shim API surface (CAS / DWCAS / fences) is
  identical; only the underlying intrinsic differs. From the
  ManagedRef / ManagedSlice perspective the MM × shim-op table above
  is unchanged — Windows runs the same `orc` arm as Linux/macOS,
  using `nimIncRefCyclic` / `nimDecRefIsLastDyn` /
  `nimDestroyAndDispose`. Section 6 cell 17 verifies this end-to-end
  under MSVC. No additional `when defined(windows):` arms are
  introduced at the shim level by this resolution.

- **`nim cpp` backend (Section 6 cell 18, per O5 resolution
  2026-06-06).** Under `nim cpp` the same source tree is compiled
  with `nim cpp` instead of `nim c`; the emitted code is C++ rather
  than C. The atomics shim is expected to compile under `nim cpp`
  without modification: the C atomics builtins (`__atomic_*` on
  gcc/clang, `_Interlocked*` on MSVC) are available from C++ as
  well, and the Nim runtime's `nimIncRef` / `nimDecRefIsLast` /
  `nimDestroyAndDispose` symbols are emitted with C-linkage by the
  Nim compiler regardless of target backend. The MM × shim-op table
  above is unchanged for `nim cpp`. Any C-specific construct
  surfaced by Section 6 cell 18 (e.g. C99 designated initializers,
  restrict-qualified pointers, identifier collisions with C++
  keywords like `class`/`template`) is flagged as a Phase 4 OQ at
  the time of discovery and resolved against the specific call site
  — the shim matrix itself does not pre-bake a `when defined(cpp):`
  arm.

These notes are informational against the matrix; they do not
introduce new MM arms or new shim ops. Section 6 cells 17 and 18 are
the CI gates that catch regressions in either axis.

---

## 4.3 ManagedRef[X] shim impl details

Section 2 introduced the type and the cast machinery. This section
finalises the per-MM template bodies and confirms the bit-transfer
guarantees.

### 4.3.1 Type definition

```nim
type
  ManagedRef*[X] {.distinct.} = uint
```

Identical to Section 2.2's introduction. The `distinct uint` allows
`Atomic[ManagedRef[X]]` and `Atomic[Pair[uint, ManagedRef[X]]]` to
compile under the lock-free / size constraints enforced by
`debra/atomics` (atomics.nim:1-15: "Statically assert
`alignof(Atomic[T]) >= sizeof(T)`"). The conversion functions are
pure cast templates; their codegen is the identity transform.

### 4.3.2 Conversion functions

```nim
proc toManagedRef*[X](r: sink ref X): ManagedRef[X] {.inline.} =
  result = ManagedRef[X](cast[uint](r))

proc toRef*[X](mref: ManagedRef[X]): ref X {.inline.} =
  result = cast[ref X](uint(mref))

proc toBits*[X](mref: ManagedRef[X]): uint {.inline.} =
  uint(mref)

proc fromBits*[X](_: typedesc[ManagedRef[X]], bits: uint): ManagedRef[X] {.inline.} =
  ManagedRef[X](bits)

const nilManagedRef*[X]: ManagedRef[X] = ManagedRef[X](0)
```

Critical invariant: NONE of these touch the refcount. `toManagedRef`
takes `sink ref X` so the user's parameter is consumed; the
compiler-emitted `=destroy` on the user's `ref X` would balance the
hidden inc that the compiler emitted at the call site of `pushRef`,
but the queue's wrapper inserts an explicit `incRefSlot` before the
sink expires to net out at +1 (the queue's reference). The Path C
trace in Section 2.4 is the source of truth for the bookkeeping; the
shim is the mechanism.

### 4.3.3 Per-MM template bodies

Final form of the templates introduced as a sketch in Section 2.2's
"Per-MM compat shim arms" block:

```nim
template incRefSlot*[X](mref: ManagedRef[X]) =
  when defined(gcArc) or defined(gcOrc) or defined(gcAtomicArc):
    if cast[pointer](uint(mref)) != nil:
      when defined(gcOrc):
        nimIncRefCyclic(cast[pointer](uint(mref)), false)
      else:
        nimIncRef(cast[pointer](uint(mref)))
  elif defined(gcRefc):
    if cast[ref X](uint(mref)) != nil:
      GC_ref(cast[ref X](uint(mref)))
  elif defined(nimony):
    if cast[pointer](uint(mref)) != nil:
      arcInc(cast[ptr NimHeapHeader](
        cast[pointer](uint(mref)) -! sizeof(NimHeapHeader)).rc)
  else: # mm:none
    discard

template decRefSlot*[X](mref: ManagedRef[X]) =
  when defined(gcArc) or defined(gcAtomicArc):
    if cast[pointer](uint(mref)) != nil:
      if nimDecRefIsLast(cast[pointer](uint(mref))):
        nimDestroyAndDispose(cast[pointer](uint(mref)))
  elif defined(gcOrc):
    if cast[pointer](uint(mref)) != nil:
      if nimDecRefIsLastDyn(cast[pointer](uint(mref))):
        nimDestroyAndDispose(cast[pointer](uint(mref)))
  elif defined(gcRefc):
    if cast[ref X](uint(mref)) != nil:
      GC_unref(cast[ref X](uint(mref)))
  elif defined(nimony):
    if cast[pointer](uint(mref)) != nil:
      if arcDec(cast[ptr NimHeapHeader](
          cast[pointer](uint(mref)) -! sizeof(NimHeapHeader)).rc):
        nimonyDestroyAndDispose(cast[pointer](uint(mref))) # symbol TBD — see §7.4 OQ4.2
  else: # mm:none
    discard

template isUniqueSlot*[X](mref: ManagedRef[X]): bool =
  when defined(gcArc) or defined(gcOrc) or defined(gcAtomicArc):
    isUniqueRef(cast[ref X](uint(mref)))   # arc.nim:155
  else:
    false # debug instrumentation only; not callable under refc/none/nimony
```

The orc arm uses `nimIncRefCyclic(p, cyclic=false)` rather than the
arc-shared `nimIncRef` because orc.nim defines `nimIncRef` only under
specific compile guards; the public surface under `gcOrc` is
`nimIncRefCyclic` (orc.nim:46). The `cyclic=false` argument is correct
for our use case: we are not asserting the cell is cyclic, only
incrementing the refcount; orc's runtime sets the cell's cycle bit
based on the type's actual structure, not our hint.

The atomicArc arm collapses with the arc arm in the `when` because
the C-RTL substitutes the atomic op transparently — see arc.nim's
`nimDecRefIsLast` body lines 248-252:
`when defined(gcAtomicArc) and hasThreadSupport: let oldCnt =
atomicDec(cell.count, rcIncrement) …` vs the non-atomic else branch.

### 4.3.4 Push wrapper sketch (per MM)

```nim
proc pushRef*[X, ...](q: var QueueRef[X, ...], item: sink ref X): bool =
  let mref = toManagedRef(item) # cast, no inc
  when not defined(mm_none):
    incRefSlot(mref)            # queue's +1
  result = q.slotPushBits(toBits(mref))
  when not defined(mm_none):
    if not result:
      decRefSlot(mref)          # roll back; queue rejected
  # `item` (sink) goes out of scope; compiler-emitted =destroy runs the
  # matching dec under arc/orc/atomicArc/refc (net zero on item). Under
  # mm:none, =destroy is also a no-op. Net effect: queue holds +1 on the
  # cell iff `result == true`.
```

The wrapper is identical in shape for every MM; the `when` arms
collapse to no-ops or symbol calls per the shim matrix above. There
is no per-MM `pushRef` body — there is one `pushRef`, and the shim
collapses.

### 4.3.5 Pop wrapper sketch (per MM)

```nim
proc popRef*[X, ...](q: var QueueRef[X, ...]): Option[ref X] =
  let bits = q.slotPopBitsAndClear()  # atomic claim + clear in one step;
                                      # see §4.5 for per-arm mechanism
  if bits == 0:
    result = none(ref X)
  else:
    let mref = fromBits(ManagedRef[X], bits)
    result = some(toRef(mref))
    # No shim op here. Queue's +1 transfers to the caller's `ref X`.
    # The caller's =destroy will balance it on drop.
```

The pop wrapper is MM-agnostic. The bit transfer is the same; the
balance is the caller's compiler-emitted `=destroy` (a no-op under
mm:none, an active dec under arc/orc/atomicArc, GC_unref under refc).

### 4.3.6 Bit-cast guarantees

The conversion functions rely on `cast[uint](r)` and
`cast[ref X](bits)` being identity at runtime. This holds because:

1. `ref X` is a single-word pointer under all MMs the library
   supports (the refc header doesn't change the *pointer* type — the
   pointer still points at the cell's payload, with the header at
   `p -! sizeof(RefHeader)`; see arc.nim's `head(p)` template).
2. `uint` is pointer-sized on all platforms we target (the
   `debra/atomics` substrate enforces `alignof(Atomic[T]) >=
   sizeof(T)` and the lock-free check rejects platforms where this
   does not hold; see atomics.nim:9-15).
3. `distinct uint` does not alter codegen — it is a compile-time
   wrapper only.

Therefore the cast round-trip preserves pointer identity, which is
the precondition for the shim's per-MM symbol calls to find the
correct cell header.

---

## 4.4 Path-C string / seq — `ManagedSlice[T]` box pattern (REWRITTEN 2026-06-06, v3)

**Lineage**: §4.4 has been rewritten three times within v0.1.0.

1. **v1** — `ManagedSlice[T] = distinct uint` shim with refcount
   symbols on a payload pointer. Rejected (refcount symbols on a
   non-RefHeader allocation — undefined behaviour). See VERDICT C
   of `docs/internal/section-4-4-string-seq-lifecycle-investigation-2026-06-06.md`.
2. **v2** — ManagedSlice deleted; `NimStringV2 = {len, p}` rode
   directly in `Pair.second` via inline transfer-ownership in
   queue.nim. Rejected: queue.nim shouldn't know V2 internals;
   complicated uniform `Pair[uint, SlotEncoding(T)]` slot model.
3. **v3 (IMPLEMENTED Wave A 2026-06-06, wired Wave C 2026-06-06)** —
   `ManagedSlice[T] = distinct uint` **restored as a box pointer**.
   Slot bits are an 8-byte distinct-uint pointer to a heap-allocated
   `StringBox` / `SeqBox[U]` wrapper. V2 payload lives inside the
   box; compiler-emitted `=destroy` on `box.v` drives payload cleanup
   through the official runtime path (`nimDestroyStrV1` → `frees`).
   The library manages the box's own lifecycle explicitly. ABI parity
   with `uint` is preserved.

This section documents v3. Source of truth:
`src/lockfree/managed_slice.nim` (Wave A) and
`src/lockfree/internal/path_c_wrap.nim` (Wave C wrappers).

### 4.4.1 Box layout

```nim
# src/lockfree/managed_slice.nim — Wave A
type
  StringBox = ptr object
    v: string

  SeqBox[U] = ptr object
    v: seq[U]

  ManagedSlice*[T] = distinct uint
```

The box is **manually managed** (library allocs and deallocs); the V2
payload inside the box (`box.v`) is **compiler-managed** (hooks fire
when the library invokes them). Because `box` is `ptr object`, Nim
does NOT emit a destructor for the box — `disposeSlot` is the
explicit lifecycle hook the queue runs during destroy-walk.

ABI parity (`sizeof(ManagedSlice[T]) == sizeof(uint)`) is asserted at
compile time inside `managed_slice.nim`; see §2.10.

### 4.4.2 wrap — heap-allocate the box and transfer the payload

```nim
proc wrap*(s: sink string): ManagedSlice[char] {.inline.} =
  let box = cast[StringBox](allocShared0(sizeof(string)))
  when defined(gcArc) or defined(gcOrc) or defined(gcAtomicArc) or
       defined(gcRefc):
    box.v = s
  else:
    # mm:none — strict bit-transport.
    copyMem(addr box.v, addr s, sizeof(string))
  result = ManagedSlice[char](cast[uint](box))
```

Per-MM:

- **arc / orc / atomicArc / refc**: `box.v = s` is a sink-assign into
  a zero-initialised LHS (the box came from `allocShared0`). The
  compiler-emitted `=sink` moves the payload pointer and zeroes the
  source.
- **mm:none**: `copyMem` per §2.8. Source `s` is NOT zeroed; caller
  owns payload lifecycle.

`seq[U]` arm is identical modulo type, with the R7
`supportsCopyMem(U)` guard at the top.

Why this sidesteps OQ4.6: no `wasMoved`-on-source dance. Sink-assign
into a zeroed LHS is the standard Nim 2.x idiom; the compiler emits
the correct sequence automatically. Library never touches
`NimStringV2` internals.

### 4.4.3 unwrap — move the payload out and deallocate the box

```nim
proc unwrap*(ms: ManagedSlice[char]): string {.inline.} =
  let box = cast[StringBox](ms.uint)
  when defined(gcArc) or defined(gcOrc) or defined(gcAtomicArc) or
       defined(gcRefc):
    result = move(box.v)
  else:
    copyMem(addr result, addr box.v, sizeof(string))
  deallocShared(box)
```

`move(box.v)` zeroes the field; `deallocShared(box)` releases the
box. Caller's local then owns the payload; scope-end `=destroy` runs
`nimDestroyStrV1` → `frees` → `dealloc(p)` through the standard
runtime path.

mm:none variant: `copyMem` per §2.8 (caller-owned payload).

### 4.4.4 Per-MM specifics

| MM | wrap | unwrap | disposeSlot |
|----|------|--------|-------------|
| arc / orc / atomicArc / refc | `allocShared0` + sink-assign | `move(box.v)` + `deallocShared(box)` | `=destroy(box.v)` + `deallocShared(box)` |
| mm:none | `allocShared0` + `copyMem` | `copyMem` + `deallocShared(box)` | `deallocShared(box)` only (caller-owned payload) |
| nimony | same as arc — Cell 14 `continue-on-error` validates (R4 / OQ4.7) | same as arc | same as arc |

The box pattern unifies the surface API across all four MMs; per-MM
behaviour falls out of how the compiler treats `box.v = s` and
`move(box.v)`. This is why the §4.4.4 (refc) arm no longer needs a
bespoke `freshAlloc` / `copyMem` push-side helper — sink-assign into
a zeroed box is correct under refc just as it is under arc.

### 4.4.5 disposeSlot — destructor walk for unpopped slots

```nim
proc disposeSlot*(ms: ManagedSlice[char]) {.inline.} =
  if ms.uint == 0:
    return
  let box = cast[StringBox](ms.uint)
  when defined(gcArc) or defined(gcOrc) or defined(gcAtomicArc) or
       defined(gcRefc):
    `=destroy`(box.v)
  # mm:none: no destructor — payload caller-owned per §2.8.
  deallocShared(box)
```

Key points:

- `ptr object` has no compiler-emitted destructor; `disposeSlot` is
  the *only* lifecycle hook against the box.
- Under arc/orc/atomicArc/refc: explicit `=destroy(box.v)` dispatches
  to the standard runtime path (`nimDestroyStrV1` for strings; the
  per-element loop + payload `dealloc` for seqs).
- Under mm:none: `disposeSlot` only `deallocShared`s the box.
  Payload is caller-owned per §2.8 strict contract.

Wave C wired `disposeSlot` into:

- `src/lockfree/queue.nim` segment destructor (walks each segment's
  cell array calling `disposeSlotEncoded[T](cell.bits)` when
  `seqIsLive` reports the slot has not been popped).
- `src/lockfree/bqueue.nim` `=destroy` (walks each slot of the
  storage array).

`disposeSlotEncoded` is the `path_c_wrap.nim` template that
dispatches to `managed_slice.disposeSlot` for string/seq (and
reconstructs+drops a ref for `ManagedRef[X]`; no-op for POD identity).
See §4.4.9 below for the wrap layer.

### 4.4.6 R7 element-type guard

```nim
proc wrap*[U](s: sink seq[U]): ManagedSlice[U] {.inline.} =
  static:
    assert supportsCopyMem(U),
      "seq[U] requires U to be POD (R7 guard; see §2.7)"
  ...
```

Rejects `seq[ref X]`, `seq[string]`, `seq[seq[Y]]` at compile time.
R7 regression case at
`tests/should_fail/managed_slice_seq_non_pod_rejected.nim` pins
substring `"supportsCopyMem"` (case #22 in the should_fail runner,
restored Wave D 2026-06-06).

Guard fires at the user's push site — `wrapOrIdentity[seq[NonPodElement]]`
resolves to `wrap[NonPodElement]`, triggering the static assert
immediately. Workarounds: POD-struct wrap, `Queue[ref seq[Foo], ...]`
(outer ref routes through `ManagedRef`), or struct-of-arrays.

### 4.4.7 Open-question resolutions (2026-06-06)

The fact-check report closes the Phase 2.5 OQs against §4.4; the v3
box pattern sidesteps each.

- **OQ4.1 — Per-MM symbol binding for string/seq lifecycle**:
  **SIDESTEPPED**. Compiler-emitted `=destroy(box.v)` inside
  `disposeSlot` dispatches to per-MM destructors; no direct
  `nimDestroyStrV1` / `nimDecRefIsLast` / RefHeader misuse.
- **OQ4.3 — Payload-pointer extraction divergence (V2 vs refc)**:
  **NOT RELEVANT**. Box stores the V2 (or refc) wrapper *directly*
  as `box.v`; the library never extracts `(len, p)`.
- **OQ4.5 — `NimStringV2.cap` tag-bit layout**: **NOT RELEVANT**.
  `strlitFlag` honoured by `frees` (strs_v2.nim:32-37) automatically
  when compiler-emitted `=destroy(box.v)` fires. Library does not
  read or mask `cap`.
- **OQ4.6 — `sink string` destroy ordering**: **SIDESTEPPED**.
  `allocShared0` zero-initialises the box's `v` field; sink-assign
  runs compiler-emitted `=sink` (atomic move + zero source). No
  `wasMoved` dance required.

**OQ4.7 — nimony NimStringV2 / NimSeqV2 layout and lifecycle**:
still open. The arc-equivalent box-pattern branch is expected to
work under nimony's value-type string. T-NIMONY-ARMS / Cell 14
validate with `continue-on-error` per R4 until nimony source is
consulted.

### 4.4.8 SlotEncoding[T] — compile-time mapping (Wave A)

`SlotEncoding(T)` is a `typeof` helper (typedesc-returning template)
mapping user-facing `T` to its on-the-wire slot encoding. Source of
truth: `src/lockfree/internal/slot_encoding.nim`.

```nim
template SlotEncoding*(T: typedesc): typedesc =
  when T is ref:
    ManagedRef[typeof(default(T)[])]
  elif T is string:
    ManagedSlice[char]
  elif T is seq:
    ManagedSlice[typeof(default(T)[0])]
  else:
    T
```

| User T | SlotEncoding(T) | Lifecycle |
|--------|------------------|-----------|
| `ref X` | `ManagedRef[X]` | refcount (§4.3) |
| `string` | `ManagedSlice[char]` | box pointer (§4.4) |
| `seq[U]` | `ManagedSlice[U]` | box pointer (§4.4) |
| POD `T` (sizeof ≤ uint) | `T` | identity |

**Cell layout impact** (Wave B / Wave C):

- `Segment[T, ...].cells: array[S, LCRQCell[SlotEncoding(T)]]`.
- `BQueue.storage: StorageN1[N, SlotEncoding(T)]`.
- Strict-LCRQ MPMC: `MPMCCellArrayN[N, SlotEncoding(T)]`.
- Eight typestate Base/Bound cast sites in `bqueue.nim` swapped
  Wave C to instantiate against `SlotEncoding(T)`.

User writes `Queue[ref Foo, ...]` / `Queue[string, ...]` /
`Queue[seq[int], ...]`; this template performs the wire-format
substitution invisibly. Internal-only — MUST NOT leak into public
docs/signatures.

### 4.4.9 Path-C wrap / unwrap layer (Wave C)

`src/lockfree/internal/path_c_wrap.nim` provides three templates the
queue cores call at push entry, pop exit, and destroy-walk:

```nim
template wrapOrIdentity*[T](item: sink T): auto =
  when T is ref:    toManagedRef(item)
  elif T is string: wrap(item)
  elif T is seq:    wrap(item)
  else:             item

template unwrapOrIdentity*[T](encoded: SlotEncoding(T)): T =
  when T is ref:    toRef(encoded)
  elif T is string: unwrap(encoded)
  elif T is seq:    unwrap(encoded)
  else:             encoded

template disposeSlotEncoded*[T](encoded: SlotEncoding(T)) =
  when T is ref:    decRefSlot(encoded)
  elif T is string: disposeSlot(encoded)
  elif T is seq:    disposeSlot(encoded)
  else:             discard
```

- `wrapOrIdentity` runs at every push entry. Caller's `sink` consumes
  the source; encoded form holds the bits the queue owns until pop
  or destroy-walk.
- `unwrapOrIdentity` runs at every pop exit. Pop transfers encoded
  bits back; caller's `=destroy` handles cleanup naturally.
- `disposeSlotEncoded` runs only during destroy-walk for an UNPOPPED
  slot. POD T: no-op. `ref X`: route to `managed_ref.decRefSlot`,
  which bit-casts the encoded value and calls the per-MM drop hook
  (arc/orc/atomicArc/refc → `GC_unref`; none → no-op; nimony →
  `arcDec`). string/seq: delegate to `managed_slice.disposeSlot`.

The `ref X` arm intentionally does NOT use the "reconstruct a local
`ref X` and let it leave scope" sketch from earlier drafts. Under
`--mm:arc` the compiler's cursor inference treats such a local as a
non-owning borrow and elides `=destroy`, which leaks the refcount.
Routing through `decRefSlot` (a direct `GC_unref` on the bit-cast
view, no local binding) is immune to cursor elision. The in-source
comment at `src/lockfree/internal/path_c_wrap.nim:99-122` records
this rationale alongside the implementation.

All arms tolerate the zero/nil-bits sentinel: `decRefSlot`
short-circuits on nil bits; `disposeSlot` checks the box pointer for
nil.

### 4.4.10 Lifecycle model (LOCKED Wave C)

Push and pop are **pure transfers**. NO `incRefSlot` / `decRefSlot`
calls inside wrap/unwrap helpers.

- **Push**: `wrapOrIdentity` transfers bits (POD identity) or
  box-allocates+sink-assigns (string/seq) or refcount-wraps (ref X).
  Caller's `sink` consumption + queue holding encoded bits = net
  refcount unchanged for ref; +1 box allocation for string/seq;
  identity for POD. **NO library inc/dec.**
- **Pop**: `unwrapOrIdentity` reconstructs the user-facing value
  (move under arc/orc/atomicArc/refc; copyMem under mm:none).
  Caller's `=destroy` on the returned local handles cleanup. **NO
  library inc/dec.**
- **Destroy-walk**: `disposeSlotEncoded(encoded)` explicitly destroys
  the payload. **Only library-managed cleanup point.** POD: no-op.
  ref: refcount drop. string/seq: destroy box payload + free box.

Net refcount across lifecycle is zero: every wrap that increments
(or allocates) is balanced by exactly one unwrap (or disposeSlot).

### 4.4.11 Encoded-once-above-loop pattern (Wave C contract)

In `queue.nim` strict-LCRQ MPMC push, encode is hoisted **above** the
`tryPublish` retry loop:

```nim
var encoded = wrapOrIdentity[T](item)   # encode ONCE
while ...:
  if tryPublish(segment, slot, encoded):  # by-copy on each retry
    return true
  # retry — `encoded` still holds bits
```

**Why above the loop**: `tryPublish` takes `value` by-copy on each
retry. If `wrapOrIdentity` were inside the loop, each retry would
`wasMoved`-out the source `item` after the first iteration (the
sink-assign inside `wrap` consumes its sink parameter), and
subsequent retries would publish zeros.

This is a **contract for future MPMC variants**: any push retry loop
must encode once above the loop. bqueue.nim push paths are mostly
single-shot (no retry loop) so the constraint is trivially satisfied.

### 4.4.12 Hard-error restructuring (Wave C)

Pre-Wave-C hard error at `queue.nim:1168` had two clauses:

```nim
when not supportsCopyMem(T) or sizeof(T) > sizeof(uint):
  {.error: "...requires supportsCopyMem(T)...".}
```

Wave C restructured to fire ONLY for the POD-identity arm:

```nim
# src/lockfree/queue.nim — Wave C (current)
static:
  when not (T is ref or T is string or T is seq):
    when sizeof(T) > sizeof(uint):
      {.error: """
Queue[T, ccMulti, ccMulti, ...] requires sizeof(T) <= sizeof(uint) starting
in v5.0.0 ...
For wide T payloads, use BQueue[T] (bounded MPMC, Vyukov per-slot seq)
which preserves move-only T support. See CHANGELOG.md v5.0.0 BREAKING.
""".}
```

Rationale:

- `supportsCopyMem(T)` clause **subsumed** by `path_c_admit` +
  `SlotEncoding`: refs/strings/seqs are admitted by Path-C and
  encoded to POD-fit forms (`ManagedRef[X]` and `ManagedSlice[T]`
  satisfy `supportsCopyMem` trivially as 8-byte distinct-uint).
- `sizeof(T) > sizeof(uint)` clause **retained** for POD-identity:
  plain POD T wider than 8 bytes still rejected with the v5.0.0
  "use BQueue" diagnostic. Strict-LCRQ DWCAS is intrinsically
  64-bit-payload-only.

v5.0.0 BREAKING user message preserved verbatim; only the gating
condition narrowed.


## 4.5 Per-arm cell shape matrix (full enumeration)

This section enumerates the cell shape for every cardinality arm
crossed with every payload type the library accepts. For each row
the table names the cell type, the per-slot atomics, the producer
write protocol, the consumer read protocol, and — most importantly
per the Phase 1.6 implementation gotcha — the *pop-clears-payload*
mechanism.

### 4.5.1 Cell shape per arm × payload (table)

| Arm                              | POD payload (T) cell type                      | ManagedRef payload cell type                                     | ManagedSlice payload cell type                                   |
| -------------------------------- | ----------------------------------------------- | ----------------------------------------------------------------- | ----------------------------------------------------------------- |
| Bounded SPSC (Sipsic)            | `StorageN1[N, T]` of plain `T` slots             | `StorageN1[N, uint]` (ManagedRef bits)                            | `StorageN1[N, uint]` (ManagedSlice bits)                          |
| Bounded MPSC (Mupsic)            | `MPMCCellArrayN[N, T]` (Vyukov seq + T payload) | `MPMCCellArrayN[N, uint]` (seq + ManagedRef bits)                 | `MPMCCellArrayN[N, uint]` (seq + ManagedSlice bits)               |
| Bounded SPMC (Sipmuc)            | `MPMCCellArrayN[N, T]` (Vyukov seq + T payload) | `MPMCCellArrayN[N, uint]` (seq + ManagedRef bits)                 | `MPMCCellArrayN[N, uint]` (seq + ManagedSlice bits)               |
| Bounded MPMC (Mupmuc)            | `MPMCCellArrayN[N, T]` (Vyukov seq + T payload) | `MPMCCellArrayN[N, uint]` (seq + ManagedRef bits)                 | `MPMCCellArrayN[N, uint]` (seq + ManagedSlice bits)               |
| Unbounded SPSC (UnboundedSipsic) | segment.data `array[S, T]` + segment.committed  | segment.data `array[S, uint]` + segment.committed                 | segment.data `array[S, uint]` + segment.committed                 |
| Unbounded MPSC (UnboundedMupsic) | segment.data `array[S, T]` + segment.committed  | segment.data `array[S, uint]` + segment.committed                 | segment.data `array[S, uint]` + segment.committed                 |
| Unbounded SPMC (UnboundedSipmuc) | segment.data `array[S, T]` + segment.committed  | segment.data `array[S, uint]` + segment.committed                 | segment.data `array[S, uint]` + segment.committed                 |
| Unbounded MPMC (UnboundedMupmuc) | segment.data `array[S, T]` + segment.committed  | segment.data `array[S, uint]` + segment.committed                 | segment.data `array[S, uint]` + segment.committed                 |

#### Notes on the matrix

- **Bounded MPSC/SPMC/MPMC** share `MPMCCellArrayN[N, T]` per
  `src/lockfree/typestates/mpmc_cell.nim:18-54` (cell shape at
  lines 18-47, array wrapper at 49-54). The cell holds
  an `Atomic[uint64]` seq and a `T` payload, padded to a cache-line
  multiple. Under ManagedRef/ManagedSlice payloads, `T = uint` so
  the cell is `{seq: Atomic[uint64], data: uint, pad: array[…, byte]}`
  — identical sizeof regardless of MM (the `distinct uint` cast does
  not change the slot type the cell array sees).
- **Bounded SPSC** uses `StorageN1[N, T]` (one extra slot for
  full/empty discrimination; see `storage_n1.nim:5-8`). No per-slot
  seq counter — head/tail in the queue header carry the protocol
  state. Under managed payloads `T = uint`.
- **Unbounded variants** use a segmented structure (per
  `unbounded_mpmc_push.nim:11-17` for the MPMC segment shape):
  `{data: array[S, T]; next: Atomic[ptr Segment]; tail: Atomic[int];
  prevConsumerIdx: Atomic[int]; committed: array[S, Atomic[bool]]}`.
  The protocol state is the `committed` flag array — a separate
  Atomic[bool] per slot. Pop reads `committed[i]` to decide whether
  the slot is published, then claims via head-cursor CAS. Under
  managed payloads `T = uint`.

**Q-DWCAS verdict (updated 2026-06-06 per Phase 4 source verification):**
the strict-LCRQ DWCAS-with-seq layout (`Atomic[Pair[uint, payload]]`
cell) is **already shipping in v0.1.0** for the MPMC unbounded arm.
The lockfreequeues integration tree at `feat/v5.0.0-impl` HEAD declares
`type LCRQCell*[T] = Atomic[Pair[uint, T]]` at
`src/lockfree/queue.nim:132` and implements the strict-LCRQ
fast-path consumer claim at queue.nim:1616-1632 (DWCAS `tryClaim` +
`prevConsumerIdx` two-tier coordination per §5.3). The DWCAS substrate
in `nim-debra/src/debra/atomics.nim` (Pair[A,B] at atomics.nim:414 plus
dwcas* family at atomics.nim:1406-1700+) is the substrate that powers
the shipped MPMC arm — not a future-rework-only artifact. Earlier
"future rework path, not v0.1.0 ship" language was stale relative to
the integration tree and is corrected per §7.9.1.

Section 4 below describes the v0.1.0 cell shapes as they actually are
in the integration tree: strict-LCRQ DWCAS for unbounded MPMC; Vyukov
seq-counter for bounded; committed-flag-per-slot for the unbounded
MPSC / SPSC / SPMC arms (which remain committed-flag in v0.1.0).

**Scope note on §7.4 OQ §2-6**: OQ §2-6 ("Verify that the atomics
surface lifts `ManagedRef[X]` through `Atomic[Pair[uint, ManagedRef[X]]]`
cleanly") **now is** a v0.1.0 fact-check item, not v0.2.0 substrate
prep, because the v0.1.0 unbounded MPMC arm DOES exercise
`Atomic[Pair[uint, T]]` and Path C dispatch (§4.6 + §4.10) may
instantiate `T = ManagedRef[X]` at managed-payload sites. Phase 2.5
fact-check must run OQ §2-6 on the resolved instantiation. See §7.4.3
for the canonical category disposition (now category-A, gating).

### 4.5.2 Pop-clears-payload mechanism (per arm)

This is the verification axis the Phase 1.6 implementation gotcha
demands: every arm must clear payload bits on pop so that the
destructor walk (§4.7) does not mistake an already-popped slot for a
live one. Under mm:none with bit-only transport the clear is required
even more strictly — an unclear slot is bit-aliased to a live ref
that the user may have already destroyed, and a subsequent
`destroyAndDrain` walk would dereference dangling bits.

**Phase 3.4 update (2026-06-06)**: the table below was originally
written against the lockfreequeues v5.0.0 source-of-truth (`grep`
verified at `/Users/eek/Development/lockfreequeues` HEAD on
2026-06-06), where all 8 pop sites use **plain reads**. The lockfree
integration substrate (the in-progress umbrella tree this design doc
targets) has already wrapped each read in `move(...)`. `move()` is
**observationally equivalent** to the `.reset()` mechanism in §4.5.3
family (1) for slot-clearing purposes: both leave the slot's bits at
0 (for POD T, and for `distinct uint` T such as ManagedRef[X] /
ManagedSlice[T]), and neither runs a destructor on the slot type
(ManagedRef / ManagedSlice have no `=destroy` per §4.5.3 — the
lifecycle is in the wrappers + caller-site). The destructor walk
(§4.7) reads slot bits and uses `seqIsLive(slot)` to skip
already-popped slots; a 0-bit slot is correctly classified as not-live.

The 8-arm v0.1.0 lift task family has been renamed
**T-VERIFY-POP-CLEARS.*** in the impl plan and scoped to regression
tests only (lock in the existing `move()` behavior so a future
refactor cannot silently revert to plain assignment). The
code-edit deliverable is closed by the prior integration substrate.

| Arm                  | Mechanism in lockfreequeues v5.0.0 source                                                                                                                                                                                                                                                                                                                                                  | Mechanism in lockfree integration tree                                                                                                                                                                                                                                                                                                                                                       | v0.1.0 disposition |
| -------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------ |
| Bounded SPSC         | `src/lockfree/typestates/spsc_pop.nim:72` reads `let value = queue.storage[op.slot]` and advances head. **Plain read; no clear.**                                                                                                                                                                                                                                                  | `src/lockfree/typestates/spsc_pop.nim:72` reads `let value = move(queue.storage[op.slot])`. `move()` leaves the slot at default(T) = 0 bits. **Observationally equivalent** to the §4.5.3 family (1) `.reset()` mechanism.                                                                                                                                                            | **T-VERIFY-POP-CLEARS.spsc** — regression test only. |
| Bounded MPSC         | `src/lockfree/typestates/mpsc_pop.nim:116` reads via `dataPtr` then `seqStore(op.slot, op.pos + uint64(N), moRelease)`. **Plain read; no clear.** The seq advance gates next-generation producers but the bits remain.                                                                                                                                                            | `src/lockfree/typestates/mpsc_pop.nim:116` reads `let value = move(queue.cells.dataPtr(op.slot)[])`. `move()` is sequenced before the seq advance at the release barrier in program order; the slot's 0-default is published with that release.                                                                                                                                  | **T-VERIFY-POP-CLEARS.mpsc** — regression test only. |
| Bounded SPMC         | `src/lockfree/typestates/spmc_pop.nim:98` mirror image of MPSC. **Plain read; no clear.**                                                                                                                                                                                                                                                                                          | `src/lockfree/typestates/spmc_pop.nim:98` uses `move(queue.cells.dataPtr(op.slot)[])`. Consumer-CAS exclusivity covers the move + clear pair.                                                                                                                                                                                                                                       | **T-VERIFY-POP-CLEARS.spmc** — regression test only. |
| Bounded MPMC         | `src/lockfree/typestates/mpmc_pop.nim:99` mirror image of MPSC/SPMC. **Plain read; no clear.**                                                                                                                                                                                                                                                                                     | `src/lockfree/typestates/mpmc_pop.nim:99` uses `move(queue.cells.dataPtr(op.slot)[])`. After the consumer's head-CAS publishes the claim, the dataPtr is exclusively owned until the seq is re-armed.                                                                                                                                                                            | **T-VERIFY-POP-CLEARS.mpmc** — regression test only. |
| Unbounded SPSC       | `src/lockfree/typestates/unbounded_spsc_pop.nim:120` reads `let value = slotAvail.segment.data[slotAvail.slot]`. **Plain read; no clear.**                                                                                                                                                                                                                                       | The lockfree integration tree inlines this into `src/lockfree/queue.nim:1360` as `let v = move(seg.data[head])`. `move()` clears the slot to default(T).                                                                                                                                                                                                                       | **T-VERIFY-POP-CLEARS.unbounded-spsc** — regression test only. |
| Unbounded MPSC       | `src/lockfree/typestates/unbounded_mpsc_pop.nim:169` reads `let value = slotAvail.segment.data[slotAvail.slot]`. **Plain read; no clear.**                                                                                                                                                                                                                                       | Inlined in `src/lockfree/queue.nim:874` as `let value = move(seg.data[head])`. The committed flag was already read; the consumer owns the slot after the head-cursor advance.                                                                                                                                                                                                  | **T-VERIFY-POP-CLEARS.unbounded-mpsc** — regression test only. |
| Unbounded SPMC       | `src/lockfree/typestates/unbounded_spmc_pop.nim:189` reads `let value = seg.data[claimed.slot]`. **Plain read; no clear.**                                                                                                                                                                                                                                                       | Inlined in `src/lockfree/queue.nim:1380` as `result = some(move(seg.data[seg.head]))`. SPMC: the head-CAS already gave exclusive ownership.                                                                                                                                                                                                                                    | **T-VERIFY-POP-CLEARS.unbounded-spmc** — regression test only. |
| Unbounded MPMC       | `src/lockfree/typestates/unbounded_mpmc_pop.nim:216` reads `let value = seg.data[claimed.slot]`. **Plain read; no clear.**                                                                                                                                                                                                                                                       | Inlined in `src/lockfree/queue.nim:1475` as `result = some(move(seg.data[mySlot]))`. MPMC committed-flag arm: the head-CAS published the claim; subsequent consumers see a different head value and skip this slot.                                                                                                                                                          | **T-VERIFY-POP-CLEARS.unbounded-mpmc** — regression test only. |

**Status summary (Phase 3.4 disposition):**

- lockfreequeues v5.0.0 source: all 8 cardinality arms use plain
  reads (no slot clear). Phase 3.4 `grep` verified this at
  `/Users/eek/Development/lockfreequeues` HEAD on 2026-06-06.
- lockfree integration tree: all 8 arms have been wrapped in
  `move(...)` as part of the prior integration substrate. The bounded
  4 sites live at `src/lockfree/typestates/{spsc,mpsc,spmc,mpmc}_pop.nim`;
  the unbounded 4 sites are inlined in `src/lockfree/queue.nim`
  at lines 874, 1360, 1380, 1475.
- The destructor walk (§4.7) is correct under both `move()` and
  `.reset()` semantics — both leave the slot at default(T), which the
  walk's `seqIsLive` / `slotIsCommittedAndUnread` predicates correctly
  classify as not-live.
- v0.1.0 work: 8 per-arm regression tests (T-VERIFY-POP-CLEARS.*)
  lock in the existing `move()` behavior. The code-edit deliverable
  is closed by the prior integration substrate.

**Historical note (pre-Phase 3.4 framing)**: earlier drafts of this
section described the v0.1.0 work as "T-INTEGRATE FIX — add `.reset()`
after the read". That framing remains semantically valid — `.reset()`
and `move()` are equivalent slot-clearing mechanisms for the design's
purposes — but the lift work has already happened in the integration
substrate using `move()`, so the v0.1.0 tasks are now regression-test
locks rather than code edits. No design intent has changed; only the
disposition of who edits the code (the prior integration agent did)
vs. who locks in the behavior (T-VERIFY-POP-CLEARS.* tests).

The original framing is preserved below for traceability:

> **T-INTEGRATE WORK in v0.1.0**, not deferred — per the
> operator's standing "no post-release deferral" rule (MEMORY.md:
> *feedback_v4_3_no_post_release_deferral*, generalised in
> *feedback_never_recommend_defer_to_followup*). The fix is mechanical
(eight one-line insertions, one per pop site) and the test surface
is direct (a destructor walk on a partially-consumed queue must not
see bits from already-popped slots).

### 4.5.3 Pop-clears mechanism rationale per arm

Three families of clear mechanism are in play:

1. **Plain `.reset()` after the value read** — used by every arm in
   v5.0.0's design space. The Nim-emitted `=destroy` (or `=sink`)
   for the slot type runs at the `.reset()` call. Under arc/orc/
   atomicArc with managed payloads the `reset` IS the dec; under
   mm:none the `reset` zeroes the bits.

   Wait — that's subtle. Under managed payloads the slot type is
   `uint` (the ManagedRef/ManagedSlice bits live in a `distinct
   uint` field). `reset(uint)` writes 0 and runs no destructor. The
   actual dec happens in the shim wrapper (`decRefSlot`) called by
   the pop wrapper AFTER the value transfer to the caller — see the
   pop wrapper sketch in §4.3.5 / §4.4.5: the caller-side `=destroy`
   on the reassembled `ref X` / `string` runs the dec.

   So the slot-side `.reset()` clears the *bits* (so the destructor
   walk sees nil and skips) but does NOT run the dec. The dec is
   accounted for by the caller's owned reference going out of
   scope. This is the correct model under all MMs: the slot is a bit
   transport, the lifecycle is in the wrappers and at the
   caller-site.

2. **DWCAS-atomic clear with the seq advance** — a *future* mechanism
   for the strict-LCRQ port. In strict-LCRQ the cell is
   `Atomic[Pair[uint, payload]]`; pop's CAS swings both halves at
   once, atomically clearing the payload and advancing the seq. This
   is NOT in v0.1.0; v0.1.0 uses the separate-write-after-flag
   approach.

3. **Separate-write-after-flag** — what v0.1.0 actually does. The
   sequence is (a) consumer claims via head-CAS or seq-load+seq-CAS,
   (b) consumer reads the payload, (c) consumer writes
   `slot.reset()` (zeroes the payload bits), (d) consumer publishes
   the slot's availability for next-generation producers via
   `seqStore(pos + N, moRelease)`. Step (c) is sequenced before step
   (d) in program order; the release at step (d) provides the
   happens-before edge for any future producer's acquire load to see
   the cleared bits.

   The single-consumer arms (SPSC, MPSC, SPMC, unbounded {SPSC, MPSC,
   SPMC}) all have a single consumer at the claim site, so step (b)
   ↔ step (c) cannot race with another consumer. The MPMC arm
   (bounded and unbounded) uses head-CAS to claim exclusivity for the
   slot read; the same exclusivity covers the clear because no other
   consumer's head-CAS can target this slot in the current
   generation. The Phase 1.6 gotcha verification (above) confirms
   this is the mechanism v0.1.0 will use, and that v5.0.0 source
   currently omits step (c).

---

## 4.6 Slot state predicates

### 4.6.1 Handoff Q10 finding (updated 2026-06-06)

Phase 4 source verification on 2026-06-06 (driven by the §4.6.2
refactor task) located the actual close-bit sites in the integration
tree at `feat/v5.0.0-impl` HEAD:

- `src/lockfree/queue.nim` declares
  `const CLOSED_BIT* = 1'u shl (sizeof(uint) * 8 - 1)` at line 122 and
  exercises the bit at **4 consumer-side test sites**: lines 1258,
  1568, 1656, 1711.
- `src/lockfree/bqueue.nim` contains **zero** `CLOSED_BIT`
  references (`grep -c CLOSED_BIT src/lockfree/bqueue.nim` →
  0). The bounded Vyukov substrate has no close-on-empty logic in
  v0.1.0.

The handoff Q10 "5 CLOSED_BIT sites across typestate files" framing
described a pre-integration snapshot; the integration tree
consolidated MPMC unbounded into `queue.nim` (4 sites, strict-LCRQ
arm) and left the bounded substrate close-bit-free.

T-INTEGRATE-PRE-PRED factors these 4 inline literals into named
predicates before the lift adapters are wired up. The destructor walk
(§4.7) consumes the same predicate names so the "is this slot live?"
check is a single named call, not an inline `and`-with-constant.

### 4.6.2 Predicate set — two families plus MPSC segment predicate

The three orthogonal substrates in v0.1.0 (bounded-Vyukov on
`MPMCCell[T]` with `Atomic[uint64]` seq counter; LCRQ-integration on
`LCRQCell[T] = Atomic[Pair[uint, T]]` with native-width DWCAS;
MPSC committed-flag on `Segment[T, ccMulti, ccSingle, S].committed:
array[S, Atomic[bool]]`) demand **three orthogonal predicate
families**. Conflating them would force one family to consume the
substrate type of another (e.g., a single `seqIsClosed` defined on
`uint64` could not be applied to the LCRQ `uint` Pair-first half
without a width cast that would silently misbehave on 32-bit hosts).

#### Family A — Bounded-Vyukov (typestates layer)

```nim
# Module: src/lockfree/typestates/slot_state.nim
#   (post-rename: src/lockfree/typestates/slot_state.nim)
# Substrate: MPMCCell[T] at src/lockfree/typestates/mpmc_cell.nim:28,
#   with payload.seq: Atomic[uint64] (line 25). The Vyukov seq counter is
#   conceptually 64-bit wide regardless of host pointer width (cf. §4 cell
#   layouts) — the explicit `uint64` is intentional and 32-bit-clean.
# Current call sites: none (placeholder family; reserved for future
#   bounded close-on-empty if ever added — bqueue.nim has zero CLOSED_BIT
#   sites in v0.1.0, verified via grep on 2026-06-06).

const ClosedBitB* = high(uint64) shr 1
  ## Vyukov-family close-bit. Suffix `B` (Bounded) distinguishes from
  ## the LCRQ family's `CLOSED_BIT` on platform-`uint`.

proc seqIsEmptyB*(s: uint64; pos: uint64): bool {.inline.}
  ## Vyukov empty: seq == pos (producer-side check).

proc seqIsFilledB*(s: uint64; pos: uint64): bool {.inline.}
  ## Vyukov filled: seq == pos + 1 (consumer-side check).

proc seqIsClosedB*(s: uint64): bool {.inline.}
  ## (s and ClosedBitB) != 0'u64 — placeholder for future bounded
  ## close-on-empty; zero call sites in v0.1.0.

proc seqIsClaimedB*(s: uint64; pos: uint64): bool {.inline.}
  ## s > pos + 1'u64 and not seqIsClosedB(s) — destructor walk on
  ## bounded MPMC.

proc seqIsLiveB*[T](slot: var MPMCCell[T]; pos: uint64): bool {.inline.}
  ## Loads slot.payload.seq with moRelaxed; returns
  ## seqIsFilledB(s, pos) and not seqIsClosedB(s).
```

#### Family B — LCRQ-integration (queue.nim layer)

```nim
# Module: src/lockfree/typestates/slot_state.nim, same module
#   file as Family A. Family B can alternatively live in a sibling
#   slot_state_lcrq.nim if the orchestrator prefers strict
#   file-per-family layout; the canonical choice for v0.1.0 is the
#   shared module with `B` / no-suffix naming to keep both families
#   visible side-by-side.
# Substrate: LCRQCell[T] = Atomic[Pair[uint, T]] at
#   src/lockfree/queue.nim:132 (declaration), with
#   `const CLOSED_BIT* = 1'u shl (sizeof(uint) * 8 - 1)` at
#   src/lockfree/queue.nim:122. CLOSED_BIT is platform-`uint` wide
#   (16-byte DWCAS on 64-bit hosts; 8-byte DWCAS on 32-bit, per cell
#   doc-comment at queue.nim:128-130).
# Current call sites: 4 in src/lockfree/queue.nim — lines 1258,
#   1568, 1656, 1711 (all consumer-side close-bit tests on `recheck.first`
#   or `inner.first` after a `load(seg.cells[mySlot], moAcquire)`).

proc seqIsClosed*(s: uint): bool {.inline.}
  ## (s and CLOSED_BIT) != 0'u — high-bit close sentinel per §2.2.
  ## Replaces the 4 inline literals in queue.nim listed above.

proc seqIsClaimed*(s: uint; pos: uint): bool {.inline.}
  ## s > pos + 1'u and not seqIsClosed(s) — destructor walk.

proc seqIsLiveLCRQ*[T](cell: var LCRQCell[T]; pos: uint): bool {.inline.}
  ## let p = cell.load(moRelaxed); p.first == pos + 1'u and
  ##   not seqIsClosed(p.first)
  ## Used by the §4.7 destructor walk on the strict-LCRQ MPMC arm.
```

#### MPSC committed-segment predicate (scoped to MPSC arm only)

```nim
# Module: src/lockfree/typestates/segment_state.nim
#   (post-rename: src/lockfree/typestates/segment_state.nim) —
#   sibling to slot_state.nim. The committed-flag substrate is an
#   array-of-Atomic[bool] per segment, not a per-cell seq counter,
#   so it gets its own module rather than mixing with the cell-level
#   predicate families above.
# Substrate: Segment[T, ccProd=ccMulti, ccCons=ccSingle, S] which carries
#   `committed: array[S, Atomic[bool]]` (per design §4 segment layouts).
# Current call site: TBD — consumed by the §4.7 destructor walk
#   (T-DESTRUCTOR-WALK in PG-7); MPSC pop sites already inline the
#   `committed[i].load` and are not refactored in v0.1.0 (the destructor
#   walk is the first consumer that needs a named predicate).

proc slotIsCommittedAndUnread*[T; S: static int](
    seg: var Segment[T, ccMulti, ccSingle, S];
    slot: int;
    prevConsumerIdx: int
): bool {.inline.}
  ## slot >= prevConsumerIdx and seg.committed[slot].load(moRelaxed) —
  ## true iff a producer has published this slot and the consumer cursor
  ## has not yet passed it. Used by the §4.7 destructor walk to decide
  ## whether to call decRefSlot on the payload.
```

#### Orthogonality rationale

Three substrates, three predicate families, three names:

| Family | Module | Cell/segment substrate | seq width | Current call sites |
|--------|--------|------------------------|-----------|--------------------|
| A — Bounded-Vyukov | `slot_state.nim` | `MPMCCell[T]` (Vyukov counter) | `uint64` | none (placeholder) |
| B — LCRQ-integration | `slot_state.nim` (or sibling) | `LCRQCell[T] = Atomic[Pair[uint, T]]` | platform `uint` | 4 in `queue.nim` (1258, 1568, 1656, 1711) |
| MPSC committed | `segment_state.nim` | `Segment[T, ccMulti, ccSingle, S].committed` | `Atomic[bool]` array | TBD (destructor walk) |

The orchestrator picks the most-intuitive concrete module layout
(one shared `slot_state.nim` with `B`/no-suffix names is the canonical
v0.1.0 choice; sibling `slot_state_vyukov.nim` + `slot_state_lcrq.nim`
is acceptable if file-per-family is preferred). Document the chosen
layout in the T-INTEGRATE-PRE-PRED commit message.

### 4.6.3 Location

The predicate modules live at:

- `src/lockfree/typestates/slot_state.nim` — Family A + Family B,
  sibling to the existing `mpmc_cell.nim` and `slot_seq_n.nim`.
- `src/lockfree/typestates/segment_state.nim` — MPSC committed-flag
  predicate, sibling to slot_state.nim.

They are imported by:

- `src/lockfree/queue.nim` — Family B `seqIsClosed` replaces the 4
  inline literals at lines 1258, 1568, 1656, 1711.
- The destructor walk (§4.7, T-DESTRUCTOR-WALK in PG-7) — Family B
  `seqIsLiveLCRQ` / `seqIsClaimed` (MPMC arm) + MPSC
  `slotIsCommittedAndUnread` (MPSC arm).
- Family A is **not** imported by any caller in v0.1.0; it is
  present as a placeholder for any future bounded close-on-empty
  rework, and its existence keeps the family-segregated layout
  symmetric across substrates.

### 4.6.4 Refactor scope

The 4 CLOSED_BIT inline sites in `src/lockfree/queue.nim`
(lines 1258, 1568, 1656, 1711) are rewritten to call Family-B
`seqIsClosed`. No edits to `bqueue.nim` (zero CLOSED_BIT sites). No
edits to the unbounded MPSC / SPSC / SPMC committed-flag pop sites in
v0.1.0 (the destructor walk is the first consumer that needs a named
predicate; the inline `committed[i].load` sites remain inline in pop
hot paths). This is a mechanical refactor — no semantic change — and
is a T-INTEGRATE pre-step before the cardinality wrappers are lifted
into the lockfree package.

### 4.6.5 32-bit substrate cleanliness note

The two families intentionally use different integer widths:

- Family A's seq counter is `Atomic[uint64]` because the Vyukov
  counter is conceptually 64-bit wide regardless of host pointer
  width; the `MPMCCell[T].payload.seq: Atomic[uint64]` declaration
  at `src/lockfree/typestates/mpmc_cell.nim:25` is preserved
  unchanged. On 32-bit hosts this routes through the Nim stdlib's
  `uint64` atomics, not a single CPU instruction.
- Family B uses platform-`uint` (matching `CLOSED_BIT*` at
  `src/lockfree/queue.nim:122` and the
  `LCRQCell[T] = Atomic[Pair[uint, T]]` declaration at line 132) so
  the DWCAS pair fits the platform's native double-word width
  (16 bytes on 64-bit, 8 bytes on 32-bit — see queue.nim:128-130).

No new source in v0.1.0 assumes `uint == uint64`. The substrate is
**32-bit-clean even though the v0.1.0 CI matrix is 64-bit only**
(see §2 / §4 32-bit note + §6.x.x for the matrix-cell scope; 32-bit
host CI is deferred to v0.2.0+).

---

## 4.7 Destructor walk integration

### 4.7.1 When the walk runs

The destructor walk runs from the queue type's `=destroy` hook —
specifically, the queue facade type (`Sipsic[N, T]`, `Mupsic[N, P, T]`,
`UnboundedMupmuc[S, T, MT]`, etc.) carries a `{.destroy.}` proc that
fires when the queue object's lifetime ends. This is:

- explicit user `=destroy(q)` call;
- queue variable going out of scope (under arc/orc/atomicArc);
- explicit `destroyAndDrain(q, callback)` from §4.8 (which first
  drains, then calls the destructor walk on the now-empty queue).

The walk is **not** part of the hot path. It runs once per queue,
during teardown, when no other thread can be operating on the
queue (per the lifecycle contract in Section 5 — there is no
concurrent destroy + push/pop).

**Precondition (cross-link to §5.1.6):** the destructor walk runs only
after `unbindClient` for every attached worker has completed (§5.1.6:
"Precondition: all attached workers joined"). No nebr pin is held during
the walk because all workers have unpinned; the walk operates on a
quiescent queue. This is the source of the "no concurrent destroy +
push/pop" guarantee — it is enforced at the API level by requiring
`bindClient` / `unbindClient` balancing before `=destroy` may fire (or
the typestate machinery raises `transitionError`).

### 4.7.2 Walk algorithm (per cardinality family)

**Bounded MPMC / MPSC / SPMC (Vyukov per-slot seq):**

```nim
proc walkLiveAndDecref*[N: static int, X](
    cells: var MPMCCellArrayN[N, ManagedRef[X]],
    head: uint64, tail: uint64
) =
  ## Walk slots in [head, tail), call decRefSlot on each live one.
  for vpos in head ..< tail:
    let slot = initRawN[N](int(vpos mod uint64(N))).validate().index()
    if seqIsLive(cells.cells[slot.slotValue], vpos):
      let bits = cells.dataPtr(slot)[]   # plain load; we own the queue
      decRefSlot(fromBits(ManagedRef[X], bits))
      # No need to clear; the queue is about to be freed. The clear
      # is only required for pop's mid-life correctness (§4.5.2).
```

**Bounded SPSC (head/tail with N+1 slot):**

```nim
proc walkLiveAndDecref*[N: static int, X](
    storage: var StorageN1[N, X], head: int, tail: int
) =
  var i = head
  while i != tail:
    let bits = cast[uint](storage.data[i mod (N + 1)])
    if bits != 0:
      decRefSlot(fromBits(ManagedRef[X], bits))
    i = (i + 1) mod (N + 1)
```

**Unbounded variants (segment walk):**

```nim
proc walkLiveAndDecref*[S: static int, X, MT: static int](
    q: var UnboundedMupmucBase[S, ManagedRef[X], MT]
) =
  # Walk every reachable segment from head to tail.
  var seg = q.headSegment
  while seg != nil:
    for slot in 0 ..< S:
      if slotIsCommittedAndUnread(seg[], slot,
                                   seg.prevConsumerIdx.load(moRelaxed)):
        let bits = cast[uint](seg.data[slot])
        if bits != 0:
          decRefSlot(fromBits(ManagedRef[X], bits))
    let nextSeg = seg.next.load(moRelaxed)
    seg = nextSeg
  # Segment memory is reclaimed by the nebr layer (Section 3), not by
  # this walk. The walk only handles per-slot payload decref.
```

The unbounded walk and the nebr retire path do **not** overlap: nebr
owns segment-memory reclamation; §4.7 owns per-slot payload decref.
At `=destroy(q)` time, the walk fires first (decrefs slot payloads),
then nebr's manager teardown retires the segments. Section 3.7 (nebr
queue-destroy interaction) handles the nebr-side cleanup.

### 4.7.3 Per-MM behaviour of the walk

| MM             | walkLiveAndDecref per-slot effect                                                                                              | Cell free at last ref?                         |
| -------------- | ------------------------------------------------------------------------------------------------------------------------------- | ----------------------------------------------- |
| `--mm:none`    | `decRefSlot` is `discard`. The walk is a no-op. Unpopped slot bits leak — see §4.7.4 below.                                     | n/a                                              |
| `--mm:refc`    | `decRefSlot` calls `GC_unref`; cell freed when GC reclaims.                                                                     | yes (deferred to GC scan)                        |
| `--mm:arc`     | `decRefSlot` calls `nimDecRefIsLast` and chains `nimDestroyAndDispose` on last-ref.                                              | yes (synchronous on last ref)                    |
| `--mm:orc`     | `decRefSlot` calls `nimDecRefIsLastDyn` and chains `nimDestroyAndDispose` on last-ref.                                          | yes (synchronous on last ref, cycle bookkeeping) |
| `--mm:atomicArc` | `decRefSlot` calls `nimDecRefIsLast` (atomic dec internally) and chains `nimDestroyAndDispose` on last-ref.                  | yes (synchronous on last ref)                    |
| nimony aufbruch | `decRefSlot` calls `arcDec` on the header rc field; on return-true chains nimony's dispose.                                    | yes (synchronous on last ref)                    |

### 4.7.4 mm:none strict contract

Per the Phase 1.6 CRITICAL #2 disposition: under `--mm:none` the
queue's `=destroy` does NOT iterate the live-slot range. There is no
decref to perform; there is no destruction to perform. The queue is
a pure bit-transport mechanism and the bits stored in unpopped slots
are the user's responsibility.

The strict-contract implementation:

```nim
proc =destroy*[T, ...](q: var Queue[T, ...]) =
  when not defined(mm_none):
    walkLiveAndDecref(q.cells, q.head.load(moRelaxed), q.tail.load(moRelaxed))
  # mm:none: no walk. User must drain or destroyAndDrain before destroy.
  # The queue's manager and segment memory are reclaimed below (or by
  # nebr for unbounded variants).
  reclaimManager(q)
```

If the user destroys a non-empty queue under mm:none WITHOUT calling
`drain` or `destroyAndDrain` first, the unpopped items leak. This
matches the mm:none semantic contract ("user manages lifecycle") and
is documented in `docs/guide/memory-management.md` per Section 2.4.5.

The `drain` / `destroyAndDrain` helpers (§4.8) make the strict-
contract path actually usable: a user who wants ARC-equivalent
teardown under mm:none simply calls `destroyAndDrain(q, cleanup)`
where `cleanup` is their per-item disposal callback.

---

## 4.8 Drain helper implementation

Per the Phase 1.6 CRITICAL #2 disposition, `drain` and
`destroyAndDrain` are REQUIRED in v0.1.0 — the mm:none strict
contract is *only* usable if these helpers exist.

### 4.8.1 Surface

```nim
iterator drain*[T, ...](q: var Queue[T, ...]): T
proc destroyAndDrain*[T, ...](q: var Queue[T, ...],
                              cleanup: proc(item: T) {.nimcall.})

iterator drain*[T, ...](q: var BoundedQueue[T, ...]): T
proc destroyAndDrain*[T, ...](q: var BoundedQueue[T, ...],
                              cleanup: proc(item: T) {.nimcall.})
```

`drain` pops items until the queue is empty, yielding each. The
caller observes the items via the iterator and is responsible for
disposing of them (e.g., manually calling user-side dispose in
mm:none, letting the iterator-bound `T` go out of scope under
arc/orc/atomicArc).

`destroyAndDrain` is a convenience wrapper that combines drain +
destroy: it iterates the queue calling `cleanup` on each item, then
fires the destructor walk and reclaims the queue. Under mm:none the
cleanup callback is the user's dispose path; under arc/orc/atomicArc
the cleanup is typically `proc(_: T) = discard` (the per-item
=destroy runs at the cleanup call boundary).

### 4.8.2 Implementation per cardinality

**Single-consumer arms (SPSC, MPSC, unbounded SPSC, unbounded MPSC):**

```nim
iterator drain*[N: static int, T](q: var Sipsic[N, T]): T =
  while true:
    let opt = q.pop()
    if opt.isSome:
      yield opt.get()
    else:
      break

proc destroyAndDrain*[N: static int, T](
    q: var Sipsic[N, T], cleanup: proc(item: T) {.nimcall.}
) =
  for item in drain(q):
    cleanup(item)
  # `=destroy(q)` fires at proc exit; the walk sees an empty queue
  # and is a no-op. Under mm:none this is the strict-contract path.
```

The single-consumer drain is straightforward: `pop` already serializes
on the head cursor, and the caller of `drain` is conceptually the
sole consumer for the destroy phase. No new synchronisation needed.

**Multi-consumer arms (SPMC, MPMC, unbounded SPMC, unbounded MPMC):**

The multi-consumer drain requires that the caller hold *exclusive*
ownership of the queue at drain time — there must be no concurrent
consumers competing for slots, otherwise the drain may miss items
that another consumer claimed but hasn't yet read.

The contract is: `drain` and `destroyAndDrain` are SAFE to call only
when the caller has exclusive ownership of the queue. Under arc/
orc/atomicArc this typically means "no other thread holds a `var`
reference to the queue"; under mm:none this is the user's
responsibility.

The implementation is identical to the single-consumer arms — the
caller calls `pop` until it returns `none`. Because the caller is
exclusive, the MPMC consumer-CAS-loop in `pop` always succeeds on
the first try (no contention), and the drain proceeds linearly.

```nim
iterator drain*[N, P: static int, T](q: var Mupmuc[N, P, T]): T =
  while true:
    let opt = q.pop()
    if opt.isSome:
      yield opt.get()
    else:
      break
```

The MPMC pop's defensive head-CAS still runs but always wins because
there is only one caller. The cost is one CAS per item — same as the
hot-path cost — which is acceptable for a teardown operation.

### 4.8.3 Why both `drain` and `destroyAndDrain`

`drain` alone lets the caller decide what to do with each item;
`destroyAndDrain` provides the common case (apply cleanup, then
destroy). Splitting them gives users two ergonomic options:

```nim
# Pattern A: drain, do something with the items, queue lives on.
for item in drain(myQueue):
  externalSystem.dispose(item)
# myQueue is still alive here — could be reused.

# Pattern B: drain + destroy in one call.
destroyAndDrain(myQueue, proc(item: ref Foo) = externalSystem.dispose(item))
# myQueue's storage is now reclaimed.
```

Pattern A is what the user wants for queue-reset semantics; Pattern B
is what the user wants for end-of-life cleanup. The two are not
interchangeable (Pattern A's user could call `=destroy(myQueue)`
afterward but it requires they remember to do so).

### 4.8.4 Under mm:none

Under mm:none these are the **only** safe teardown paths for a
non-empty queue. The user who pushed `ref Foo` items into the queue
and now wants to tear it down without leaking must call
`destroyAndDrain(q, dispose)` where `dispose: proc(item: ref Foo)`
runs the user's free routine for each item.

Equivalent contract phrased as a doctring on the queue type:

```text
Under --mm:none, the queue performs NO refcount or lifecycle ops
on payloads. If the queue is non-empty at =destroy time, the
payloads leak. To prevent this, the user MUST:

  - drain the queue with `drain(q)` and manage each yielded item, OR
  - call `destroyAndDrain(q, dispose)` with a callback that disposes
    of each item.

Both helpers are no-ops if the queue is already empty.
```

---

## 4.9 ABI guarantees per MM

Section 2 stated that the queue's ABI (`sizeof(Queue[T, …])`, member
offsets, alignment) is **identical** across MMs. Section 4 confirms
what implements that guarantee in the cell layer.

### 4.9.1 What the guarantee says

For any fixed `T` and queue facade, `sizeof(Sipsic[N, T])` is the
same value under `--mm:none`, `--mm:refc`, `--mm:arc`, `--mm:orc`,
and `--mm:atomicArc`. The field offsets are the same. The alignment
is the same. A queue object instantiated by one TU under `--mm:arc`
could in principle be operated on by another TU under `--mm:orc`
without layout mismatch — though doing so is a contract violation
for other reasons (the refcount semantics differ) and the library
documents that mixing MMs across TUs is forbidden.

### 4.9.2 What implements the guarantee

1. **Cell types are parameterised on payload size (uint or T), not
   MM.** `MPMCCellArrayN[N, uint]` has the same sizeof under every
   MM because `uint` has the same sizeof. The `distinct uint` wrapper
   on `ManagedRef`/`ManagedSlice` is compile-time only.
2. **Manager struct has no MM-conditional fields.** The nebr
   manager (Section 3) is MM-agnostic: it stores epoch counters and
   per-thread state in plain integer fields. There is no
   `when defined(arc): refcountField` inside the manager.
3. **Segment struct (unbounded) has no MM-conditional fields.**
   `MPMCSegment[S, T]` (unbounded_mpmc_push.nim:11-17) is shaped by
   `S` and `T` alone; no MM-conditional `committed_atomic_arc` vs
   `committed_arc` arms.
4. **The shim is compile-time only.** `incRefSlot`/`decRefSlot`
   expand to either symbol calls or `discard` at the call site; the
   queue struct itself has no shim-related fields.

### 4.9.3 What can break ABI

A future Nim release that changes the layout of `Atomic[uint]`,
`Atomic[uint64]`, or `Pair[A, B]` would break ABI for both code
compiled before and after the change. lockfree pins the supported
Nim version range in `lockfree.nimble` (Section 6) to fence this
risk. The pinned version is documented in Section 6 along with the
CI matrix that proves the layout holds across the pinned range.

A future Nim release that splits the RefHeader layout (currently
shared by `ref T`, `NimStringV2`, and `NimSeqV2[T]`) would NOT break
ABI but would break the shim: the slice-shim arms assume the
RefHeader sits at `payloadPtr -! sizeof(RefHeader)`. The centralised
shim (§4.1) is the audit point for this risk; the v0.1.0 ship pins
Nim 2.2.x and the shim is verified against arc.nim:155-165 and
the strs_v2.nim layout at that pin.

---

## 4.10 Cross-references to other sections

| Topic                                          | Where covered |
| ---------------------------------------------- | ------------- |
| Path C refcount lifecycle trace                | Section 2.4 (the source-of-truth trace; Section 4 only confirms shim mechanism) |
| `T constraint` catalog (POD vs ref vs slice)   | Section 2.1 (Section 4 references the resolved slot type per constraint) |
| `supportsCopyMem(ref T)` under mm:none         | Section 2.4.5 (the user-managed-lifecycle clause; Section 4.7.4 implements it) |
| nebr retire path / segment reclamation         | Section 3.4 (nebr owns segment memory; Section 4.7 owns per-slot payload decref) |
| nebr queue-destroy interaction                 | Section 3.7 (the destructor walk fires before nebr manager teardown) |
| Public push/pop/iterator signatures            | Section 5 (Section 4 sketches wrappers; Section 5 finalises the signatures) |
| `drain` and `destroyAndDrain` user docs        | Section 7.4 (docs IA places them in the memory-management guide) |
| CI matrix per MM                               | Section 6.2 (proves the shim arms compile + pass under each MM) |
| nimony partial-port (`notyet`)                 | Section 6.5 (the disposition path if Section 4.2's nimony arm cannot be finalised by v0.1.0 ship) |

---

## 4.11 Open questions for Phase 2.2 review

The following items are genuine uncertainties that should be
resolved during the Phase 2.5 fact-checking gate (or earlier if
discovery surfaces the data). They are NOT design forks — they are
verification tasks.

### OQ4.1 refc refcount symbol name at pinned Nim version

The refc arm of `incRefSlot`/`decRefSlot` calls `GC_ref` /
`GC_unref`. These are documented in Nim 1.x as the user-facing
public ref ops on tracing GCs. At Nim 2.2.10 the symbols are
exposed via the system module under refc but the precise binding
(`GC_ref` as proc vs template vs `{.deprecated.}`) needs spot-check.

**Resolution path:** grep
`~/.nimble/pkgcache/githubcom_nimlangNimgit_2210/lib/system/*.nim`
for `GC_ref` / `GC_unref` at refc compile-time arms. Confirm the
public surface or, if removed, switch the refc arm to copy-semantics
(consistent with the slice arm's refc treatment).

### OQ4.2 nimony heap header layout for the arcInc/arcDec adapter

The nimony shim adapter computes the address of the refcount field
within the heap header as `addr cast[ptr NimHeapHeader](bits -!
sizeof(NimHeapHeader)).rc`. The `NimHeapHeader` shape on nimony's
allocator is not yet verified.

**Resolution path:** read nimony's heap header type definition (per
handoff Q4: nimony research stored under /tmp/nimony-research/ if
present). If layout cannot be verified before v0.1.0 ship, the
nimony arm is marked `notyet` per Section 6.5 and ManagedRef on
nimony is partial-port.

### OQ4.3 refc slice copy semantics

The refc slice arm copies the string body at push time and discards
at pop time (Section 4.4.4). Confirm this matches user expectations
for `Queue[string, ...]` under refc — specifically, that the user
does not observe ref-shared string semantics across the queue
boundary.

**Resolution path:** test case in v0.1.0's CI: push a string, mutate
the source after push, pop the string, verify the popped string is
unchanged (i.e., the queue's transport is a value copy, not a
ref-share).

### OQ4.4 nimony string/seq representation

The handoff Q4/Q5 flagged this as an open item. If nimony's string/
seq representation differs from Nim 2.x's `NimStringV2`/`NimSeqV2`,
the slice shim's per-MM arm must either adapt or mark `notyet`.

**Resolution path:** read nimony's strs_v2/seqs_v2 equivalent.
Decision deferred to Section 6.5 (the partial-port disposition).

### OQ4.5 `NimStringV2.cap` tag-bit layout under arc/orc

The slice conversion functions (§4.4.2) read `s.p.cap` to populate
the reassembled string's cap field. The `cap` field in Nim 2.x
strings carries a tag bit (large vs small allocation, or shared
vs owned in some representations).

**Resolution path:** read
`~/.nimble/pkgcache/githubcom_nimlangNimgit_2210/lib/system/strs_v2.nim`
for the cap field's bit layout. If a tag bit is present, the
reassembly must mask appropriately. The shim is rewritten to use
whatever official accessor exists (`nimStringCap`, etc.) rather than
direct field access.

### OQ4.6 `sink string` destroy ordering for slice extraction

The slice push wrapper (§4.4.5) and the slice conversion
(`toManagedSlice`) extract the payload pointer from a `sink string`
parameter BEFORE the compiler-emitted `=destroy` runs. This is
correct under arc/orc/atomicArc (the destroy runs at proc exit, not
proc entry). Under nimony aufbruch the ordering should be the same
but is not yet verified.

**Resolution path:** test case in v0.1.0's CI: push a string under
each MM, verify the payload pointer is non-null at slot store time
(the test fails if the destroy ran before extraction).

### OQ4.7 v5.0.0 SPMC push facade — confirm cell shape

The bounded SPMC cell shape is asserted in §4.5.1 to be
`MPMCCellArrayN[N, T]` (Vyukov per-slot seq + payload), identical
to bounded MPMC/MPSC. Confirm by reading `spmc_push.nim` cell-array
field type.

**Resolution path:** grep `MPMCCellArrayN` /
`SipmucPushBase` / `SipmucBase` in `spmc_push.nim` and `sipmuc.nim`.
Expected: identical to mpmc_push / mpsc_push pattern. Section
verification is a 5-minute task during T-INTEGRATE.

### OQ4.8 Pop-clears refactor — sequence-of-edits per arm

The Phase 1.6 implementation gotcha (§4.5.2) names eight cardinality
arms in v5.0.0 source that omit the payload clear on pop. The
T-INTEGRATE fix is a one-line insertion per arm. Resolution: a
T-INTEGRATE pre-step that applies the eight edits and runs the
existing test suite (which should pass — the clear is correctness-
preserving and does not change observable behaviour for a
single-pass producer/consumer test). A new test exercises the
destructor walk on a partially-consumed queue.

### OQ4.9 Destructor walk + nebr ordering for unbounded

§4.7.2 (unbounded arm) and Section 3.7 (nebr queue-destroy
interaction) describe two phases of queue teardown: (1) walk live
slots and decref payloads, (2) reclaim segment memory via nebr.
Confirm the ordering is correct: phase 1 must complete before phase
2, otherwise decref reads through dangling segment pointers.

**Resolution path:** read the v5.0.0 unbounded queue's `=destroy`
(if present) and confirm the lift adapter sequences phase 1 before
phase 2 explicitly in the lockfree facade.

---

## 4.12 Section 4 self-check

- Per-MM × shim-op matrix is fully enumerated (ManagedRef in §4.2.1,
  ManagedSlice in §4.2.2) with file:line citations into the Nim
  source tree at the pinned compiler version.
- Per-arm × payload cell shape matrix is fully enumerated in §4.5.1.
  Every cardinality arm (8) × every payload type (3) has a cell type
  named, with citations into the lockfreequeues v5.0.0 source.
- Pop-clears-payload mechanism is verified per arm in §4.5.2. All
  eight arms currently OMIT the clear in v5.0.0; the T-INTEGRATE
  fix is specified per arm and is one-line-per-arm.
- Slot-state predicates are factored out of the v5.0.0 inline
  literals into a named module (§4.6); the 5 CLOSED_BIT sites the
  handoff Q10 finding identified are listed for refactor.
- Destructor walk algorithm is specified per cardinality family
  (§4.7.2) with per-MM behaviour (§4.7.3) and the mm:none strict
  contract (§4.7.4).
- Drain / destroyAndDrain helpers are specified with surface and
  per-cardinality implementation (§4.8). The mm:none strict-contract
  usability path is established.
- ABI guarantees per MM (§4.9) confirm the layout invariants and
  name what could break them.
- Cross-references to sibling sections (§4.10) are complete; no
  topic in this section overlaps with Sections 1, 2, 3, 5, 6, or 7.
- Open questions (§4.11) are resolution tasks, not design forks. The
  design is implementable as written; the OQs are verification work
  for Phase 2.5 fact-checking.

