# Section 2 — Type System and Payload Types

Status: Draft for Phase 2.2 review
Scope: v0.1.0 type-constraint catalog, internal slot types (`ManagedRef[X]`,
`ManagedSlice[T]`), `supportsCopyMem` MM dependency, the CRITICAL #1 Path C
`when T is ref:` composition matrix, nullable handling, rejection rules,
`mm:none` contract specifics, cross-MM portability, ABI stability.

Out of scope here (see other sections): module layout (§1), nebr / SMR
algorithm details (§3), per-MM cell shape implementation (§4), public API
surface signatures (§5), CI matrix (§6), docs IA / migration (§7).

Path C is locked. `ref T`, `string`, and `seq[T]` are user-facing payload
types. `ManagedRef[X]` and `ManagedSlice[T]` are internal slot
representations and never appear in the public API.

---

## 2.1 T constraint catalog

The queue is parameterised over a payload type `T`. The static dispatch
inside Queue and BQueue routes `T` to one of three internal arms:

| Arm | `T` shape | Slot representation | Hooks fired by library |
|---|---|---|---|
| POD | `supportsCopyMem(T) and sizeof(T) <= 8` | `T` (or `Pair[uint, T]` for DWCAS arms) | None |
| Managed ref | `T is ref` (Path C) | `ManagedRef[X]` (`distinct uint`) | `nimIncRef` / `nimDecRefIsLast` in wrappers |
| Path-C string/seq | `T is string` or `T is seq[U]` | `Pair[uint, T]` slot — `NimStringV2` / `NimSeqV2[U]` value transits `Pair.second` directly (no `ManagedSlice` indirection; removed 2026-06-06 per §2.3 + §4.4) | Inline transfer-ownership in queue.nim Path-C dispatch |

Everything else either dispatches to POD by virtue of `supportsCopyMem`
being true, or is statically rejected with a precise error message
(see §2.7). The catalog below enumerates each user-facing shape with the
arm it lands in and any constraints particular to that shape.

### POD types

Accepted unconditionally when `supportsCopyMem(T) and sizeof(T) <= 8`.

- All Nim primitives (`int`, `uint`, `int8..int64`, `float32`, `float64`,
  `bool`, `char`, enums of fitting size).
- `pointer`, `cstring`, `ptr T` for any `T`. These are raw pointers; the
  library transports the bits and does no lifecycle bookkeeping.
- Distinct types whose base satisfies the POD constraint (e.g.
  `type Id = distinct uint64`). `supportsCopyMem` propagates through
  `distinct` (verified against `Nim/lib/system.nim:1464` magic).
- `tuple[…]` and `object` whose every field satisfies the POD
  constraint AND whose total size is ≤ 8 bytes AND which has no
  user-defined `=copy` / `=destroy` / `=sink` hook. Verified via
  `supportsCopyMem`.
- `array[N, U]` where `U` is POD and `N * sizeof(U) <= 8`.

The `sizeof(T) <= 8` half of the constraint is independent of
`supportsCopyMem`; it comes from the DWCAS-bounded MPMC arm requiring
that the payload half of the `Pair[uint, payload]` slot fit in a machine
word so DWCAS is mechanically possible on the platforms we target
(x86_64 cmpxchg16b, arm64 LSE / ldxp+stxp). Smaller arms (SPSC,
single-producer, single-consumer) could in principle relax this, but
we keep one uniform constraint across all arms to keep the type story
simple and ABI-stable (see §2.10).

### `ref T` types — Path C user surface

Accepted for all five MMs (`arc`, `orc`, `atomicArc`, `refc`, `none`)
subject to the composition matrix in §2.5. The internal slot is
`ManagedRef[X]` (§2.2). User code writes `Queue[ref Foo, …]` or
`BQueue[ref Foo, …]`; the queue's `push` accepts a `ref Foo`, the
queue's `pop` returns `Option[ref Foo]`.

Rejected ref shapes are listed in §2.5 with the precise compile-error
text emitted by the static dispatch.

### `string` and `seq[T]` types — Path-C inline transfer-ownership

Accepted in v0.1.0 (Phase 1.5 Q3 IN). Internal slot is the same
`Pair[uint, T]` LCRQ slot used for POD payloads; the `NimStringV2`
value (`{len, p}`) transits `Pair.second` directly. There is no
`ManagedSlice` distinct-uint indirection — that type was removed
2026-06-06 (see §2.3 + §4.4 rewritten). User code writes
`Queue[string, …]` or `Queue[seq[int], …]`; semantics are the same
as `ref T`: ownership transfers from producer to consumer.

`seq[U]` recursively requires `U` to land in one of the three arms
(POD, managed ref, managed slice). `seq[ref Foo]` is a managed-slice
of managed-refs; the slice transports the seq header, and the seq's
own element hooks handle individual ref refcounting at user-side
construction time. The queue itself never walks slice contents.

### `ptr T` types

Accepted as POD (raw pointer, no hooks). Same shape as `pointer`.
Particularly useful under `--mm:none` where users manage lifetime
explicitly. The queue does not distinguish `ptr T` from `pointer`
at runtime; the type system distinguishes them at compile time.

### Distinct types

Accepted when the underlying base satisfies one of the three arms,
EXCEPT `distinct ref T` is REJECTED at the static dispatch (§2.5
row "distinct ref"). The reason is that `when T is ref:` does NOT
match a `distinct ref X` (Nim's type-matching rule for distinct
types), so the library cannot route a `distinct ref X` through the
managed-ref arm without an explicit `distinctBase` unwrap — and that
opens questions about whether the user's distinct wrapper expects
specific lifecycle semantics that the library would be silently
overriding. Reject and document.

### Object types containing managed fields

A `T` that is itself an object with a `ref X` field, a `string` field,
or a `seq[U]` field has `supportsCopyMem(T) = false`. It does not
satisfy the POD arm. It does not satisfy `T is ref` (it's a value
type). It does not satisfy `T is string` or `T is seq`. It falls
through the static dispatch and hits an `{.error.}` overload with the
message:

> Queue item type `<T>` is a value type containing managed fields
> (`ref`, `string`, or `seq`). Wrap the value in a `ref <T>` and pass
> the ref through the queue, or split the managed fields out and
> transport them separately.

Rationale: routing a value type with embedded managed fields through
the queue would require either (a) deep-copying every field at push
and pop, which destroys the lock-free transport story, or (b) hiding
the managed fields behind `distinct uint` while the type-system
still sees them as managed, which fails (auto-emitted `=destroy`
walks fire on slot scope exit). Forcing the user to wrap in `ref T`
makes the ownership transfer explicit and routes through the well-
understood managed-ref arm.

### Tuple types containing managed fields

Same disposition as object types containing managed fields. Same
error message (substitute "tuple" for "value type"). Same rationale.

A pure-POD tuple (`tuple[a, b: int]`) lands in the POD arm and is
accepted, provided total size ≤ 8 bytes.

### Generic constraints

The queue's `T` is unconstrained at the outer generic; the constraints
fire inside the body via `when T is ref:` / `when T is string` /
`when not supportsCopyMem(T):` and the `{.error.}` overloads
documented in §2.7. We deliberately do not write
`proc push[T: Pod or RefType or …](…)` at the outer signature; this
keeps the error messages emanating from the static-dispatch site
(precise file/line in the user's code) rather than from a generic
overload-resolution failure (which would say "no overload matches
push(Queue[Foo], Foo)" — unhelpful).

Users may instantiate the queue with any `T` they like; the failures
fire on the first call to `push` or `pop`, with messages that name
both `T` and the queue's full type signature.

---

## 2.2 `ManagedRef[X]` internal type definition

`ManagedRef[X]` is the slot representation for `ref T` payloads under
Path C. It is NEVER user-facing; the only places it appears are
inside `src/lockfree/internal/nebr/managed_ref.nim` (the definition
and per-MM shims) and the static-dispatch arms in
`src/lockfree/internal/queue/*.nim` that read and write the slot.

```nim
type
  ManagedRef*[X] {.distinct.} = uint
```

Rationale for `distinct uint` (not `distinct ptr X`):

1. `Atomic[uint]` and `Atomic[Pair[uint, uint]]` compile and produce
   the right `cmpxchg16b` / `ldxp`+`stxp` instructions across all
   atomics backends we target. `Atomic[ptr X]` is less well-trodden
   in our atomics surface and the strict-LCRQ DWCAS arm cannot
   tolerate "may or may not compile depending on backend." `uint`
   is the safe substrate.
2. `distinct uint` opacifies the type at the compiler's lifecycle
   pass: no implicit `=destroy` / `=copy` is emitted on the slot
   value because the compiler sees POD bits. The library wrappers
   call `nimIncRef` / `nimDecRefIsLast` manually at the precise
   points where the lifecycle requires it (push, pop, queue-destroy
   walk).
3. Bit-level pointer transport. The cast round-trip
   `cast[uint](myRef) ↔ cast[ManagedRef[X]](bits) ↔
   cast[ref X](toBits(mref))` is a no-op at runtime and preserves
   the pointer identity required for refcount operations to find
   the correct heap header.

### Per-MM compat shim arms

```nim
template incRefSlot*[X](mref: ManagedRef[X]) =
  when defined(gcArc) or defined(gcOrc) or defined(gcAtomicArc):
    if cast[pointer](uint(mref)) != nil:
      nimIncRef(cast[pointer](uint(mref)))
  elif defined(gcRefc):
    GC_ref(cast[ref X](uint(mref)))
  elif defined(nimony):
    # nimony aufbruch atomic-arc equivalent; arcInc takes `var int` (the
    # refcount field), NOT a pointer. Compute the address of the `rc`
    # field within the heap header. NimHeapHeader layout TBD — see §7.4 OQ4.2.
    if cast[pointer](uint(mref)) != nil:
      arcInc(cast[ptr NimHeapHeader](
        cast[pointer](uint(mref)) -! sizeof(NimHeapHeader)).rc)
  else:  # mm:none
    discard  # no-op

template decRefSlot*[X](mref: ManagedRef[X]) =
  when defined(gcArc) or defined(gcOrc) or defined(gcAtomicArc):
    if cast[pointer](uint(mref)) != nil:
      if nimDecRefIsLast(cast[pointer](uint(mref))):
        nimDestroyAndDispose(cast[pointer](uint(mref)))
  elif defined(gcRefc):
    GC_unref(cast[ref X](uint(mref)))
  elif defined(nimony):
    # arcDec also takes `var int`; same heap-header offset computation.
    if cast[pointer](uint(mref)) != nil:
      if arcDec(cast[ptr NimHeapHeader](
          cast[pointer](uint(mref)) -! sizeof(NimHeapHeader)).rc):
        nimonyDestroyAndDispose(cast[pointer](uint(mref))) # symbol TBD — see §7.4 OQ4.2
  else:  # mm:none
    discard  # no-op
```

`nimIncRef`, `nimDecRefIsLast`, and `nimDestroyAndDispose` are
verified to be the actual symbols emitted by Nim under `--mm:arc` and
`--mm:orc` (`Nim/lib/system/arc.nim:167`, `Nim/lib/system/arc.nim:238`,
`Nim/lib/system/arc.nim:218`). `atomicArc` reuses the same symbols
with the atomic-dec compile-time branch inside `nimDecRefIsLast`
(`arc.nim:248-252`).

### Internal API (tentative names; finalised in §4)

```nim
proc toManagedRef*[X](r: ref X): ManagedRef[X] {.inline.}
proc toRef*[X](mref: ManagedRef[X]): ref X {.inline.}
proc toBits*[X](mref: ManagedRef[X]): uint {.inline.}
proc fromBits*[X](_: typedesc[ManagedRef[X]], bits: uint): ManagedRef[X] {.inline.}
const nilManagedRef*: ManagedRef[X] = ManagedRef[X](0)
```

All four are `cast`-based no-ops at codegen. `toRef` does not call
`incRefSlot` — it is a bit transfer; the wrapper at the call site is
responsible for the lifecycle accounting per the lifecycle trace in
the handoff.

### Why NEVER user-facing

The user-facing API is `ref T`. The Path C revision (handoff line
505+) explicitly inverted the original Q2 answer: making
`ManagedRef[X]` part of the public API forces users to think about
the slot's lifecycle, leaks an implementation detail into the
documentation surface, and prevents the queue from being a drop-in
container for existing `ref T`-shaped code. Keeping it internal lets
users write idiomatic Nim and lets the library do the bookkeeping
once, correctly, in one place.

---

## 2.3 Path-C string / seq handling — `ManagedSlice[T]` box pointer (RESTORED 2026-06-06, v3)

**Lineage**: §2.3 was rewritten three times within the v0.1.0 design
cycle.

1. **v1 (pre-2026-06-06)** — `ManagedSlice[T] = distinct uint` with
   refcount symbols (`nimIncRef` etc.) on the payload pointer.
   Rejected: those symbols require a `RefHeader`-prefixed allocation;
   `NimStrPayload` has none. See VERDICT C of the fact-check report
   `docs/internal/section-4-4-string-seq-lifecycle-investigation-2026-06-06.md`.
2. **v2 (2026-06-06 morning)** — `ManagedSlice` deleted entirely;
   `NimStringV2 = {len, p}` rode directly in `Pair.second`. Rejected
   because it forced queue.nim to know about V2 internals and
   complicated the uniform `Pair[uint, SlotEncoding(T)]` slot model.
3. **v3 (2026-06-06 afternoon, IMPLEMENTED)** —
   `ManagedSlice[T] = distinct uint` **restored as a box pointer**.
   Slot bits are an 8-byte distinct-uint pointer to a heap-allocated
   `StringBox` / `SeqBox[U]` wrapper. The V2 payload lives inside the
   box; the compiler-emitted `=destroy` on the box's `v` field drives
   payload cleanup through the official runtime path. The library
   handles the box's own lifecycle explicitly.

Source of truth: `src/lockfree/managed_slice.nim` (Wave A, wired
Wave C). See §4.4 (rewritten) for the full mechanism.

### Type declaration

```nim
type
  ManagedSlice*[T] = distinct uint
    ## Slot encoding for ``string`` (T = char) or ``seq[U]`` (T = U).
    ## Sizeof == sizeof(uint); alignof == alignof(uint). Internal —
    ## NEVER user-facing.
```

### Semantics

- **Box pointer.** The slot value, reinterpreted as `pointer`,
  references a heap-allocated `StringBox = ptr object; v: string`
  (or `SeqBox[U] = ptr object; v: seq[U]`). Allocated with
  `allocShared0(sizeof(string))` — zero-initialised so a sink-assign
  into `box.v` has a well-defined zeroed LHS.
- **Library-managed box lifecycle.** The queue calls `allocShared0`
  during `wrap` (push) and `deallocShared` during `unwrap` (pop) OR
  during `disposeSlot` (destroy-walk).
- **ABI parity with `uint`.** Asserted at compile time via
  `assert sizeof(ManagedSlice[char]) == sizeof(uint)`. Required by
  §2.10 so the slot `Pair[uint, SlotEncoding(T)]` keeps its
  DWCAS-compatible footprint.
- **Asymmetric with `ManagedRef[X]` only in lifecycle mechanism.**
  Both are 8-byte `distinct uint` slot encodings. Both fit DWCAS.
  `ManagedRef[X]` uses Nim's compiler-emitted refcount hooks;
  `ManagedSlice[T]` uses explicit `allocShared` / `deallocShared`
  because string/seq payloads do not carry a `RefHeader`. The
  compiler-emitted `=destroy` on `box.v` still drives payload cleanup
  through `nimDestroyStrV1` → `frees`, honouring `strlitFlag`
  automatically.

### Per-MM treatment

| MM | wrap | unwrap | disposeSlot |
|----|------|--------|-------------|
| arc / orc / atomicArc / refc | `allocShared0` + sink-assign `box.v = s` | `move(box.v)` + `deallocShared(box)` | `=destroy(box.v)` + `deallocShared(box)` |
| mm:none | `allocShared0` + `copyMem(addr box.v, addr s, sizeof(string))` (per §2.8) | `copyMem` + `deallocShared(box)` | `deallocShared(box)` only (payload caller-owned per §2.8) |
| nimony | same as arc; Cell 14 `continue-on-error` validates per R4 (OQ4.7) | same as arc | same as arc |

### Citation

- Implementation: `src/lockfree/managed_slice.nim` (Wave A, 2026-06-06).
- Slot mapping: `src/lockfree/internal/slot_encoding.nim` (Wave A);
  Path-C wrap layer: `src/lockfree/internal/path_c_wrap.nim` (Wave C).
- Fact-check report: VERDICT C at
  `docs/internal/section-4-4-string-seq-lifecycle-investigation-2026-06-06.md`.
- Nim source: `Nim/lib/system/strs_v2.nim:16-22`, `:236-237`;
  `Nim/lib/system/seqs_v2.nim:24-31`; `Nim/lib/system/system.nim:1076`.

### T-constraint for `seq[U]`

For `seq[U]` payloads, `U` itself must satisfy `supportsCopyMem`. The
guard lives in `managed_slice.nim`:

```nim
proc wrap*[U](s: sink seq[U]): ManagedSlice[U] {.inline.} =
  static:
    assert supportsCopyMem(U),
      "seq[U] requires U to be POD (R7 guard; see §2.7)"
  ...
```

This is the concrete code form of R7's mitigation (§7.5). It fires at
the user's `Queue[seq[NonPodElement], ...]` push site (the push
wrapper resolves `wrapOrIdentity[seq[NonPodElement]]` to
`wrap[NonPodElement]`, which triggers the static guard). The R7
should_fail regression case
(`tests/should_fail/managed_slice_seq_non_pod_rejected.nim`) pins
the substring `"supportsCopyMem"`.

Element shapes:

- `seq[int]`, `seq[float]`, `seq[Foo]` (POD `Foo`) — box transports
  the seq header; element-side hooks are no-op.
- `seq[string]`, `seq[seq[U]]` — REJECTED at compile time by R7.
  Workaround: wrap element in a POD struct or use `ref seq[...]`.
- `seq[ref Foo]` — REJECTED at compile time by R7. Workaround: use
  `Queue[ref seq[Foo], ...]` (outer ref routes through `ManagedRef`).

The queue itself NEVER walks slice contents; it transports the box
pointer, and the user-side `=destroy` on the popped seq drives any
element-side bookkeeping.

---

## 2.4 `supportsCopyMem` MM dependency analysis

`supportsCopyMem(T)` is a compiler magic
(`Nim/lib/pure/typetraits.nim:94`, `Nim/lib/system.nim:1464`) that
returns true when `T` is safe to bit-copy with `copyMem`. Its return
value for `ref T` depends on the active MM:

| MM | `supportsCopyMem(ref T)` | Rationale |
|---|---|---|
| `--mm:none` | TRUE | `ref T` lowers to a raw pointer; no implicit hooks; bit-copy is safe |
| `--mm:refc` | FALSE | Implicit `GC_ref` / `GC_unref` shims emitted at assignment points |
| `--mm:arc` | FALSE | Generated `=destroy` emitted; bit-copy bypasses it |
| `--mm:orc` | FALSE | Generated `=destroy` + cycle collector hooks; bit-copy bypasses both |
| `--mm:atomicArc` | FALSE | Atomic refcount ops; bit-copy bypasses them |

This drives the Path C decision directly: under managed MMs, we
CANNOT use `ref T` as the slot type (the compiler would emit hooks
that fire at slot scope exit, racing the queue's own bookkeeping).
We need an opaque substrate that hides the ref from the lifecycle
pass — `distinct uint`. Under `--mm:none` we could in principle let
`ref T` be the slot type directly (no hooks fire), but for ABI
uniformity (§2.10) we use the same `ManagedRef[X]` substrate; the
inc/dec shims compile down to discard.

### Subtle interaction: `supportsCopyMem(ref T)` under mm:none

Under `--mm:none`, `supportsCopyMem(ref T) = TRUE` but `T` itself
may have non-trivial initialisation or destruction semantics. For
example, `ref Foo` where `Foo` has a user-defined `=destroy` —
under mm:none, the `ref Foo` is a raw pointer and our slot bits are
the pointer; the `Foo` object's `=destroy` will fire when the user
calls `dealloc` on their heap allocation, NOT when the queue
transports the slot.

This is the right behaviour: the queue is bit transport; lifecycle
is the user's responsibility under mm:none. We document this in
`docs/guide/memory-management.md` so users with mm:none + non-trivial
ref destructors are not surprised by the queue ignoring their hook.

---

## 2.5 CRITICAL #1 — Path C `when T is ref:` composition matrix

This is the deferred CRITICAL finding from Phase 1.6 devil's advocate.
The table below enumerates every ref-of-X shape that could plausibly
appear at the user's `Queue[T, …]` instantiation site, with the
actual Nim type-system behaviour and the library's accept/reject
decision.

Column meanings:

- **`when T is ref:` matches?** — does the static dispatch route this
  `T` through the managed-ref arm?
- **Bit-cast round-trip?** — does
  `cast[ManagedRef[X]](cast[uint](item))` followed by
  `cast[ref X](toBits(mref))` produce a pointer that refers to the
  original heap allocation?
- **Refcount works?** — do `nimIncRef` / `nimDecRefIsLast` on the
  bit-cast pointer manipulate the correct RefHeader (the one Nim
  emitted at the `new(X)` site)?
- **Accept/Reject** — final decision for v0.1.0.

| # | Shape | Example | `when T is ref:` matches? | Bit-cast round-trip? | Refcount works? | Decision | Rationale / error message |
|---|---|---|---|---|---|---|---|
| 1 | Plain `ref` to POD | `Queue[ref int]` | yes | yes | yes (arc/orc/atomicArc/refc); n/a no-op (none) | **ACCEPT** | Canonical case. `ref int` is a single heap-allocated int with a standard RefHeader. |
| 2 | Plain `ref` to object | `Queue[ref Foo]` where `type Foo = object` | yes | yes | yes | **ACCEPT** | Canonical case. Identical handling to ref int; the RefHeader layout doesn't care about the object's field shape. |
| 3 | `ref object of RootObj` | `type Bar = ref object of RootObj` then `Queue[Bar]` | yes | yes | yes | **ACCEPT** | RootObj subclasses use the same RefHeader. Inheritance metadata is on the object, not on the ref. |
| 4 | `ref` to tuple | `Queue[ref tuple[a, b: int]]` | yes | yes | yes | **ACCEPT** | Tuple is a value type; `ref tuple` is a single heap allocation with standard header. |
| 5 | `ref` to named object containing tuple | `type Foo = object; tup: tuple[a, b: int]` then `Queue[ref Foo]` | yes | yes | yes | **ACCEPT** | Same as #2. The tuple field is internal to the object; no impact on header layout. |
| 6 | `ref` to object containing `ref` field | `type Foo = object; child: ref Bar` then `Queue[ref Foo]` | yes | yes | yes for outer ref; inner ref accounted by user-side Foo lifecycle | **ACCEPT** | Outer ref's RefHeader is what the queue manipulates. Inner ref's lifecycle fires when the outer `Foo` is destroyed (consumer's scope exit). No interaction with queue bookkeeping. |
| 7 | `distinct ref Foo` | `type MyHandle = distinct ref Foo` then `Queue[MyHandle]` | **NO** | yes (mechanically) | yes (mechanically) | **REJECT** | `when T is ref:` does NOT match distinct types per Nim type-matching rules; routing through the POD arm would skip lifecycle bookkeeping and leak refs. Error message: `"Queue item type 'MyHandle' is a distinct ref alias. Distinct ref types bypass the queue's automatic refcount bookkeeping and would leak. Unwrap with distinctBase at the call site, or define your own push/pop wrappers that handle the lifecycle."` |
| 8 | `ref ref Foo` | `Queue[ref ref Foo]` | yes (matches outermost ref) | yes (mechanically — bits are the outer ref pointer) | partially — outer ref's RefHeader is touched; inner ref's lifecycle ambiguous | **REJECT** | Nested-ref lifecycle is too ambiguous to bookkeep correctly without surprise. The outer ref points to a heap-allocated `ref Foo` (8-byte allocation); incing the outer ref does NOT inc the inner ref. Users almost always want a single level of indirection. Error message: `"Queue item type 'ref ref Foo' is a nested ref. Nested refs have ambiguous lifecycle semantics under the queue's bookkeeping. Use a single ref to a wrapper type (e.g. ref tuple[inner: ref Foo]) or restructure to a single level of indirection."` |
| 9 | `ref array[N, T]` | `Queue[ref array[8, int]]` | yes | yes | yes | **ACCEPT** | `ref array[N, T]` is a single heap allocation of `N * sizeof(T)` bytes plus the RefHeader. Refcount bookkeeping is identical to `ref Foo`. |
| 10 | `ref seq[T]` | `Queue[ref seq[int]]` | yes | yes | yes for outer ref; inner seq's heap header lifecycle is the seq's own concern (fires when the ref-wrapped seq is destroyed) | **ACCEPT** | Same disposition as #6. The outer ref is what we bookkeep; the inner seq is the consumer's lifecycle concern. |
| 11 | `ref string` | `Queue[ref string]` | yes | yes | yes (outer ref) | **ACCEPT** | Same as #10. Note: distinct from `Queue[string]` (which routes through Path-C inline transfer-ownership; see §2.3). `Queue[ref string]` routes through ManagedRef. Both are valid; users choose based on whether they want shared-pointer semantics or move semantics. |
| 12 | `ref proc(): int` | `Queue[ref proc(): int]` | yes | yes | yes | **ACCEPT** | A heap-allocated `proc` value (closure or otherwise) with standard RefHeader. The bookkeeping does not care about what's inside the allocation. Users rarely do this, but the library does not need to special-case it. |
| 13 | `ref` of a closure type (the closure-wrapper `tuple[prc, env]`) | `Queue[ref ClosureType]` | yes | yes | yes for outer ref; inner env-ref lifecycle is closure's concern | **ACCEPT** | Same disposition as #6. |
| 14 | `ref` of object with user-defined `=destroy` | `proc =destroy*(x: var Foo) = …` then `Queue[ref Foo]` | yes | yes | yes — the user's `=destroy` fires when the FINAL ref's refcount reaches zero, which is the consumer's scope exit | **ACCEPT** | The queue's bookkeeping (inc on push, dec on pop balanced; final dec on consumer scope exit) preserves the user's `=destroy` semantics exactly. The user's hook fires at the right time. |
| 15 | `ref` of generic instantiation | `Queue[ref MyGeneric[int]]` | yes | yes | yes | **ACCEPT** | The instantiation `MyGeneric[int]` is a concrete type at the queue's instantiation site; no special handling required. |
| 16 | `T = string` | `Queue[string]` | n/a (different arm: `when T is string:`) | n/a | n/a | **ACCEPT** | Routes through Path-C transfer-ownership inline in queue.nim (§2.3 + §4.4 rewritten 2026-06-06). No `ManagedSlice` indirection; `NimStringV2` value rides directly in `Pair.second`. |
| 17 | `T = seq[U]` | `Queue[seq[int]]` | n/a (different arm: `when T is seq:`) | n/a | n/a | **ACCEPT** | Same Path-C transfer-ownership treatment as `string` (no `ManagedSlice`). `U` must satisfy `supportsCopyMem` per R7 guard. |
| 18 | `T = seq[ref U]` | `Queue[seq[ref Foo]]` | n/a (outer arm: `when T is seq:`) | outer slice round-trips; inner refs are seq-internal | inner refs bookkept by seq's own element hooks at user-side construction | **ACCEPT** | The queue transports the seq header; the inner refs are the seq's lifecycle problem. |
| 19 | `T = seq[seq[U]]` | `Queue[seq[seq[int]]]` | n/a | n/a | n/a | **ACCEPT** | Same as #18. Nested managed structures inside the seq are the seq's lifecycle problem. |
| 20 | `ptr T` for POD T | `Queue[ptr int]` | no | n/a | n/a (no refcount) | **ACCEPT** | POD arm. Raw pointer; user manages lifecycle. mm:none friendly. |
| 21 | `cstring` | `Queue[cstring]` | no | n/a | n/a | **ACCEPT** | POD arm. `cstring` is a raw `char*`; the library transports the bits. User-side caveat: `cstring` literals are static-storage and outlive everything; user-allocated `cstring`s have user-managed lifecycle. Documented as POD. |
| 22 | `pointer` | `Queue[pointer]` | no | n/a | n/a | **ACCEPT** | POD arm. Raw pointer. mm:none friendly. |
| 23 | `ref` of acyclic structure | `type Node = ref object; next: Node` then `Queue[Node]` | yes | yes | yes | **ACCEPT** | Standard refcount works; user-side cycles (if any) are the user's responsibility (use orc for cycle collection). |
| 24 | `ref` of `RootRef` | `Queue[RootRef]` | yes | yes | yes | **ACCEPT** | `RootRef = ref RootObj`; same as #3. |
| 25 | `ref` to `void`-equivalent (`type Foo = ref object`) with no fields | `Queue[ref Foo]` (Foo has no fields) | yes | yes | yes | **ACCEPT** | The empty-object ref still has a RefHeader; bookkeeping works. |

### Notes on verification

Rows 1-6, 9-15, 23-25 are mechanical applications of the standard
Nim type-matching rules (`when T is ref:` matches any `ref X` for
any `X` including objects, tuples, arrays, procs, closures, generic
instantiations) and the standard arc/orc RefHeader layout (every
`new(X)` allocation has the same header prefix; refcount ops only
touch the header). These are verified against
`Nim/lib/system/arc.nim:167` (`nimIncRef`) and
`Nim/lib/system/arc.nim:238` (`nimDecRefIsLast`) which both operate
on `p: pointer` without consulting the underlying type.

Row 7 (distinct ref) is verified against the documented Nim
type-matching rule that distinct types do not match the underlying
type's typeclass without explicit `distinctBase`. The library could
in principle add a `when T is distinct and distinctBase(T) is ref:`
arm and route through ManagedRef with `distinctBase` unwrapping, but
the operator review during Phase 1.6 flagged this as a footgun (the
user's distinct wrapper presumably exists to enforce some invariant
that the queue would silently bypass). Reject with a clear error.

Row 8 (`ref ref T`) is rejected on lifecycle ambiguity. The outer
ref points at a heap allocation that itself contains a `ref T`. Our
bookkeeping would inc/dec the outer ref's RefHeader correctly, but
the inner ref's lifecycle depends on the outer ref's `=destroy`
firing at the right moment, which it does — but the user almost
certainly does not want their `ref Foo` boxed inside another ref
just to pass through the queue. Reject and tell them to restructure.

Row 18-19 (`seq[ref U]`, `seq[seq[U]]`): mechanically accepted but
documented with a caveat. The queue transports the outer seq's heap
header; the inner managed elements are the seq's lifecycle concern
at the user's construction and destruction sites. The queue does
NOT walk seq contents.

### Rows marked UNCERTAIN (none in current matrix)

All rows have a definite disposition based on the verification
above. If implementation reveals a corner case not captured here
(for example: a particular `ref` shape under refc that the GC_ref
shim cannot handle), surface it as a Phase 2.5 verification finding
and update this matrix.

---

## 2.6 Nullable T handling

`Queue[ref T]` may receive `nil` from the user. The library accepts
nil pushes: the slot bits become 0, which IS the empty-slot sentinel
across all arms. This collision is intentional, not problematic:

- The slot's empty/full state is NOT determined by the payload bits
  alone. It is determined by the Vyukov seq counter (BQueue arms),
  the segment's head/tail counters (unbounded arms), or the
  committed flag (MPSC / SPSC arms). Bits = 0 with seq = "ready
  for consumer" means "the producer pushed nil." Bits = 0 with seq
  = "ready for producer" means "no producer has touched this slot
  yet." The seq disambiguates.
- Pop on a slot whose bits are 0 and whose seq says "ready for
  consumer" returns `some(nil)` — the user's `ref T` is nil. Pop
  on a slot whose seq says "no producer has filled this" returns
  `none(ref T)` regardless of bits.
- The `incRefSlot` / `decRefSlot` shims (§2.2) explicitly check
  `cast[pointer](uint(mref)) != nil` before calling `nimIncRef` /
  `nimDecRefIsLast`. nil bits = no-op. This matches arc/orc's own
  behaviour (`Nim/lib/system/arc.nim:167-175` — `nimIncRef`
  unconditionally increments, but our shim guards on nil before
  the call).

Under `--mm:none`, all of the above still applies; the inc/dec
shims are no-op so nil-handling is degenerate.

The handoff references a "`when compiles(value.isNil)` nullable
precondition." Under Path C this becomes: the queue ACCEPTS nil
pushes for `ref T`, `ptr T`, `pointer`, `cstring`, and any other
nullable type. We do NOT reject nil at the API. Users who want
non-nil enforcement should wrap with `not nil` at the call site
(Nim's strictNotNil experimental).

---

## 2.7 ref T rejection rules

Rejections happen at the static-dispatch site inside the queue's
`push` and `pop` (and analogously for BQueue). The implementation
strategy mirrors the existing v5.0.0 lockfreequeues pattern — the
analogous `when T is ref:` reject arms appear in the v5.0.0 per-arm
files (`src/lockfree/mupmuc.nim`, `mupsic.nim`, `sipmuc.nim`,
`sipsic.nim`, and their `unbounded_*` counterparts). After
T-INTEGRATE.a–.c these arms collapse into `src/lockfree/queue.nim`;
the exact line ranges in the consolidated file are determined at
lift time and tracked by §7.4 OQ4.8 (per-arm pop-clears refactor):

```nim
proc push[T, …](self: var Queue[T, …], item: sink T): bool =
  when T is ref ref:
    {.error: "Queue item type '" & $T & "' is a nested ref. " &
      "Nested refs have ambiguous lifecycle semantics. " &
      "Use a single ref to a wrapper type, or restructure to " &
      "a single level of indirection.".}
  elif T is distinct and distinctBase(T) is ref:
    {.error: "Queue item type '" & $T & "' is a distinct ref alias. " &
      "Distinct ref types bypass the queue's automatic refcount " &
      "bookkeeping and would leak. Unwrap with distinctBase at the " &
      "call site, or define your own push/pop wrappers that handle " &
      "the lifecycle.".}
  elif T is object and not supportsCopyMem(T):
    {.error: "Queue item type '" & $T & "' is a value type containing " &
      "managed fields (ref, string, or seq). Wrap in `ref " & $T & "` " &
      "and pass the ref through the queue, or split the managed " &
      "fields out and transport them separately.".}
  elif T is tuple and not supportsCopyMem(T):
    {.error: "Queue item type '" & $T & "' is a tuple containing " &
      "managed fields … (same message, substitute 'tuple').".}
  elif T is ref:
    # Path C managed-ref arm
    …
  elif T is string or T is seq:
    # Path-C inline transfer-ownership arm (no ManagedSlice indirection;
    # see §2.3 + §4.4 rewritten 2026-06-06).
    …
  elif supportsCopyMem(T) and sizeof(T) <= 8:
    # POD arm
    …
  else:
    {.error: "Queue item type '" & $T & "' is not supported. " &
      "Supported payloads: POD types ≤ 8 bytes, `ref T`, `string`, " &
      "`seq[T]`, `ptr T`, `pointer`, `cstring`. See " &
      "docs/guide/memory-management.md for the full constraint matrix.".}
```

The error messages mention `docs/guide/memory-management.md` so
users hitting a rejection have a clear next step.

The order of the `when`/`elif` chain matters: the rejection arms
(`ref ref`, `distinct ref`, object/tuple with managed fields) must
come BEFORE the accept arms, because Nim evaluates the chain in
order. If the POD arm matched first via `supportsCopyMem` returning
true for some edge case, we would silently accept something that
should reject.

Row order is verified safe: the `ref ref` arm does **not** match
`ref Foo` for non-ref `Foo` (because `ref ref` means `ref (ref X)`,
which is `ref Foo` only when `Foo == ref X` for some `X`); and the
`T is distinct and distinctBase(T) is ref` arm does **not** match
plain `ref` because non-distinct types fail `T is distinct`. The
admit-arm `T is ref` therefore catches exactly the intended population
(direct `ref` to a non-ref user type) without overlap from the upstream
reject arms.

---

## 2.8 mm:none + ref T contract details

Building on §1's overview and the Phase 1.6 CRITICAL #2 lock-in:

Under `--mm:none`:

- `ref T` IS just a raw pointer. `supportsCopyMem(ref T) = TRUE`
  (§2.4). No `=copy`, `=destroy`, `=sink`, or `GC_ref` / `GC_unref`
  hooks are emitted by the compiler.
- The `incRefSlot` / `decRefSlot` templates (§2.2) match the
  `else` arm — they expand to `discard`. No code is emitted at
  the call site.
- The slot still uses the `ManagedRef[X]` substrate. ABI is
  identical to arc/orc/atomicArc builds (§2.10).
- The queue does NOT incorrectly assume hooks fire. Specifically,
  the lifecycle trace from the handoff (push: nimIncRef +
  proc-exit =destroy balanced; pop: =copy from some(item) +
  proc-exit =destroy balanced) compiles to: push: discard + no
  hook = pure bit copy. Pop: discard + no hook = pure bit copy.
  Net: ZERO instructions emitted for lifecycle, just the slot
  transport.
- This is the "pure bit transport" mode the handoff describes.

### Drain helpers (REQUIRED per Phase 1.6 CRITICAL #2)

```nim
iterator drain*[T, …](q: var Queue[T, …]): T
iterator drain*[T, …](q: var BQueue[T, …]): T
proc destroyAndDrain*[T, …](q: var Queue[T, …], cleanup: proc(item: T))
proc destroyAndDrain*[T, …](q: var BQueue[T, …], cleanup: proc(item: T))
```

Available across all cardinality arms. `drain` yields each unpopped
item until the queue is empty (single-threaded contract: the user
ensures no concurrent producers during drain). `destroyAndDrain`
runs the user's `cleanup` callback on each remaining item, then
tears down the queue. Under mm:none, users who do not drain leak
all unpopped pointers — the queue does not touch their bits. This
is documented prominently in `docs/guide/memory-management.md`.

### No different code path under mm:none

The codegen is identical at the source level. The `when defined(…)`
discriminators inside `incRefSlot` / `decRefSlot` route the
expansion. The queue's outer code (segment management, atomic CAS,
seq counters) is byte-for-byte the same.

---

## 2.9 Cross-MM portability

The same Nim source for `Queue[ref Foo, …]` and `BQueue[ref Foo, …]`
compiles and runs under all five target MMs without source changes:

- `--mm:arc`
- `--mm:orc`
- `--mm:atomicArc`
- `--mm:refc`
- `--mm:none`

Build-time MM selection is the user's. No user-side conditional
imports, no per-MM wrapper code, no per-MM type aliases. The
library's compat shim arms (§2.2, §2.3) absorb the entire MM
differential.

The nimony aufbruch port is an open item: ManagedRef and
ManagedSlice are expected to port; if they do not, the v0.1.0
nimony build ships with `ref T`, `string`, and `seq[T]` payloads
marked `notyet` (per handoff line 427-430), and POD payloads work.

---

## 2.10 ABI stability claims

The on-disk layout of `Queue[T, …]` and `BQueue[T, …]` is
identical across the four supported Nim MMs (arc, orc, atomicArc,
none — refc is a legacy code path and we do not promise ABI parity
with it). Specifically:

- `sizeof(Queue[T, …])` is the same.
- The field offsets of `Queue`'s members (headSegment, tailSegment,
  itemCount, manager reference, …) are the same.
- The slot type's representation (`T` for POD, `ManagedRef[X]` for
  managed-ref, `ManagedSlice[T]` for managed-slice) has the same
  `sizeof` and alignment.
- Atomic word sizes are unchanged.

Why this matters:

- Cross-MM regression tests can construct a queue under one MM,
  serialize the struct, and load it under another MM (test
  infrastructure only — not a user-facing feature).
- Mixed-MM deployments (e.g. an arc binary calling into a
  precompiled `--mm:none` library) see compatible queue layouts.
  This is uncommon and not officially supported, but the ABI
  identity removes a class of surprise.

What we do NOT guarantee:

- ABI stability across Nim compiler versions. A future Nim that
  changes `Atomic[uint]`'s representation, or changes how
  `distinct uint` is laid out, breaks our ABI. We pin compiler
  versions in CI.
- ABI stability across the lockfree library's own minor versions.
  v0.1.0 → v0.2.0 may add fields. v0.x → v0.x.y patch releases will
  preserve ABI within the patch series.
- ABI stability with refc. refc's `ref T` representation differs
  enough from arc/orc that the slot bits, while bookkept correctly,
  are NOT bit-compatible with arc/orc slot bits. Cross-MM data
  exchange is arc ↔ orc ↔ atomicArc ↔ none only.

### 2.10.1 32-bit substrate cleanliness (theoretical; not in v0.1.0 CI matrix)

The v0.1.0 CI matrix is **64-bit only** (Linux x86_64, Linux arm64,
macOS arm64, Windows x86_64). 32-bit host cells are deferred to
v0.2.0+ and the existing "macOS x86_64 — NO" §7.9 row is symptomatic
of the same scope-cut policy (we do not pretend to certify hosts we
do not run CI on).

Independently of the matrix scope, the **source substrate is
32-bit-clean**: no new code introduced by v0.1.0 assumes `uint ==
uint64`. The two relevant width choices are intentional and
documented in §4.6.5:

- Bounded MPMC `MPMCCell[T].payload.seq: Atomic[uint64]` (at
  `src/lockfree/typestates/mpmc_cell.nim:25`) is conceptually a
  64-bit Vyukov counter regardless of host pointer width. On 32-bit
  hosts this routes through the Nim stdlib's `uint64` atomics path,
  not a single-instruction CAS.
- Strict-LCRQ `LCRQCell[T] = Atomic[Pair[uint, T]]` (at
  `src/lockfree/queue.nim:132`) uses platform-`uint` so the
  DWCAS pair fits the platform's native double-word width: 16 bytes
  on 64-bit, 8 bytes on 32-bit (see queue.nim:128-130). `CLOSED_BIT*`
  at queue.nim:122 is correspondingly `1'u shl (sizeof(uint) * 8 - 1)`
  — high bit of `uint`, not of `uint64`.

The §4.6 predicate families (Family A on `uint64`, Family B on
`uint`) preserve these widths through their signatures; Family A and
Family B intentionally do not share a `seqIsClosed` symbol so a
silent `uint64` ↔ `uint` width punning cannot occur.

What this buys: the codebase is **ready** to add a 32-bit cell to the
CI matrix in v0.2.0+ without source rework. What it does NOT buy:
v0.1.0 certification on 32-bit hosts — that requires the CI cell,
which is out of scope.

---

## 2.11 Open questions for Phase 2.2 review

The following questions are NOT design forks (Path C is locked, the
composition matrix above is the operator-reviewable enumeration).
They are verification items that Phase 2.2 should close before any
code lands:

1. **Distinct base with no `is ref` parent — does `T is distinct and
   distinctBase(T) is ref` compile cleanly?** The `when` chain in
   §2.7 relies on `distinctBase` working for arbitrary `T`. Verify
   that `distinctBase(int)` is safe (it should evaluate to `int`)
   and that the `distinctBase(T) is ref` test short-circuits on
   non-distinct `T` without compiler error. If not, restructure to
   `when T is distinct:` outer, `when distinctBase(T) is ref:`
   inner.

2. **nimony `arcInc` / `arcDec` symbol names** — confirmed with
   nimony's stdlib? Handoff Q4/Q5 referenced these names but Phase
   2 should verify against nimony aufbruch's current source. If
   the symbol names differ, update the `incRefSlot` / `decRefSlot`
   templates.

3. **`ref array[N, T]` with very large N** — does
   `nimIncRef`/`nimDecRefIsLast` correctly handle large heap
   allocations (e.g. N = 1_000_000)? The RefHeader is fixed-size,
   so this should "just work," but if there is a Nim corner case
   we should know it.

4. **Closure environment refs (#13 in matrix)** — closures hold a
   ref to their captured environment. `Queue[ref ClosureType]`
   ACCEPT relies on the outer ref's bookkeeping being independent
   of the closure's env-ref bookkeeping. Spot-check with a closure
   that captures a managed type.

5. **`Queue[ref Foo]` where Foo has `{.acyclic.}`** — does
   `nimIncRef`/`nimDecRefIsLast` skip cycle-collector overhead on
   acyclic refs under orc? If yes, document the performance note.
   If no, no impact on correctness; matrix row 23 stays ACCEPT
   unconditionally.

6. **Strict-LCRQ DWCAS with `Pair[uint, ManagedRef[X]]`** — verify
   that the atomics surface lifts `ManagedRef[X]` (a `distinct
   uint`) through `Atomic[Pair[uint, ManagedRef[X]]]` cleanly.
   `distinct uint` should be transparent to atomics templates, but
   if there is a generic-instantiation snag, surface it now rather
   than at implementation.

7. **Drain helper signatures** — Section 5 should finalise the
   public signatures (`iterator drain*` parameters, `cleanup`
   callback signature with raises annotation, etc.). The shapes
   listed in §2.8 are placeholders.

These are scoped as "verify before code lands," not "redesign
before code lands." If any item turns up a genuine design fork, it
escalates back to a Phase 1 question via the standard
AskUserQuestion path.
