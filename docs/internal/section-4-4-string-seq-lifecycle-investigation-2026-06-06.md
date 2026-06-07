# §4.4 String/Seq Lifecycle Investigation (2026-06-06)

Fact-check of design §4.4 (ManagedSlice[T] shim + per-MM cell layouts) against
Nim 2.2.10 runtime sources. Investigator: fact-checking subagent under
/develop Phase 4 thoroughness. Read-only investigation. No code edits.

**Pinned source under audit:**
- Design §4.4: `docs/internal/design-sections/04-mm-compat-shim-and-cell-layouts.md:445-633`
- Authored impl: `src/lockfree/managed_slice.nim`
- Nim 2.2.10 stdlib: `/Users/eek/.nimble/pkgcache/githubcom_nimlangNimgit_2210/lib/system/`

---

## 1. Verdict

### **VERDICT C — §4.4 contains multiple semantic drifts; section requires substantial rewrite.**

The design's load-bearing premise — that strings and seqs in Nim 2.x carry a
`RefHeader` on the payload allocation and are amenable to the same
`nimIncRef` / `nimDecRefIsLast` / `nimDestroyAndDispose` lifecycle as
`ref T` — **is false at the runtime level**. Specifically:

1. `NimStrPayload` (strs_v2.nim:16-18) and `NimSeqPayload[T]` (seqs_v2.nim:24-26)
   have a 2-word `{cap: int; data: UncheckedArray[…]}` header. **No `RefHeader`
   is prefixed.** The allocation is a single `alloc(contentSize(cap))` /
   `alignedAlloc0(...)` (strs_v2.nim:39-49, seqs_v2.nim:41-49); there is no
   `nimNewObj` invocation (which is what places the `RefHeader` for `ref T`;
   arc.nim:107-126).
2. Strings/seqs in Nim 2.x arc/orc/atomicArc are **value types with copy
   semantics + a strlitFlag-driven COW optimisation for string literals**
   (strs_v2.nim:28 `isLiteral`; strs_v2.nim:195-211 `nimAsgnStrV2`). They are
   not refcounted; there is no `+1/-1` accounting on the payload pointer.
3. The only destroy entrypoint for `NimStringV2` is `nimDestroyStrV1`
   (strs_v2.nim:236-237), which is `{.compilerRtl, inl.}` and simply calls
   the `frees` template (strs_v2.nim:32-37). Because it is `inl`, it is
   emitted per-translation-unit only when the compiler's `=destroy` codegen
   needs it; it is **not a cross-module-callable C symbol** that a user
   shim can `importc` and call by passing a raw payload pointer. (Seq has
   no `nimDestroySeqV1` analogue at all — the destroy for a seq is open-
   coded into the per-T `=destroy` hook emitted by the compiler.)
4. `nimDecRefIsLast(p)` and `nimDestroyAndDispose(p)` (arc.nim:218-229,
   238-263) operate on a pointer whose `head(p)` (arc.nim:59-60) is a
   `RefHeader`. Calling them on a `NimStrPayload*` (which has `cap` at
   offset 0, not `rc`) will treat the `cap` field as the refcount and
   the byte preceding the payload allocation as a `RefHeader` — that
   memory is uninitialised / belongs to the allocator metadata. Behaviour
   is undefined; in practice you would get heap corruption.

The authored implementation in `managed_slice.nim:129-142` and §4.4.3
both encode this incorrect model. The "link error was a missing import"
explanation (raised during T-MANAGED-SLICE acceptance) is incorrect; the
deeper problem is that **the symbols being imported do not apply to the
operand being passed**, even if linking succeeds.

§4.4 needs more than an §4.4.3 patch. The drifts touch §4.4.1 (slot
semantics — "RefHeader the C-RTL uses for ref T allocations"), §4.4.2
(`cast[ptr NimStringV2](addr s)` is correct for the stack-side wrapper
layout, but the comment that the payload pointer is "the refcount-bearing
cell" is false), §4.4.3 (forward decls bind symbols that don't fit), and
§4.4.5 (the "+1 the queue held" framing in `popSlice`). §4.4.4 (refc
copy-semantics arm) is the **only sub-section that survives unchanged**;
its model — value types, copy at push, discard at pop — is in fact the
correct model for arc/orc/atomicArc too.

---

## 2. Per-§4.4-sub-section findings

| § | Design claim (quote) | Nim 2.x actual | Match | Implication |
|---|---|---|---|---|
| 4.4.1 | "The bits stored in a `ManagedSlice[char]` are a pointer to a `NimStringV2` heap header" (04-mm:454-455) | A `NimStringV2` is the **stack-side wrapper** `{len: int; p: ptr NimStrPayload}` (strs_v2.nim:20-22). The heap allocation is the `NimStrPayload` `{cap: int; data: UncheckedArray[char]}` (strs_v2.nim:16-18). What lives on the heap is the payload, not the wrapper. | drifts-semantically | The slot bits, per §4.4.2 code (`cast[ptr NimStringV2](addr s).p`), are actually a pointer to `NimStrPayload`, not to `NimStringV2`. Wording is wrong; the cast in §4.4.2 happens to extract the right field. |
| 4.4.1 | "Both headers carry the same RefHeader the C-RTL uses for `ref T` allocations, which is why the arc/orc/atomicArc shim arms reuse the same symbol names" (04-mm:457-459) | `NimStrPayload` is allocated by `allocPayload` → bare `alloc(contentSize(newLen))` (strs_v2.nim:39-43). `NimSeqPayload` via `newSeqPayload` → bare `alignedAlloc0(...)` (seqs_v2.nim:41-49). **Neither allocation places a `RefHeader`.** Only `nimNewObj` / `nimNewObjUninit` (arc.nim:107-150) do that, and those are exclusively for `ref T`. | **drifts-semantically** (load-bearing) | The reuse-of-symbol-names justification is invalid. `nimIncRef(p)` does `increment head(p)` (arc.nim:167-175) which dereferences memory at `p - sizeof(RefHeader)` — for a `NimStrPayload*` that memory is allocator metadata. Undefined behaviour. |
| 4.4.1 | "the RefHeader sits at `p -! sizeof(RefHeader)`" (04-mm:478) | False for string/seq payloads (above). True for `ref T` (`head` template, arc.nim:59-60). | drifts-semantically | Same as above. |
| 4.4.1 | "UNCERTAIN — see §4.11 OQ4.5: cap field's tag bits (large/small allocation discriminator) under arc/orc must be verified" (04-mm:480-485) | The bit in question is **strlitFlag**, defined in system.nim:1076 as `1 shl (sizeof(int)*8 - 2)` — the high bit (bit 62 on 64-bit, bit 30 on 32-bit). Used to mark *string-literal payloads* (compile-time-static memory) so `=copy`/`=destroy` can shallow-copy and skip dealloc (strs_v2.nim:28 `isLiteral`, :32-37 `frees`, :195-211 `nimAsgnStrV2`). It is **not** a large/small allocation discriminator. | drifts-cosmetically (interpretation) + semantic (purpose) | Spot-check completed — see OQ4.5 below. The model "literal vs heap-owned" matters for the shim: if a literal is pushed, the shim must NOT free the payload at destroy time. |
| 4.4.2 | `cast[ptr NimStringV2](addr s).p` extracts payload pointer (04-mm:490-493) | Layout-correct for arc/orc/atomicArc/nimony (`NimStringV2 = {len, p}`, strs_v2.nim:20-22; `sizeof(string) == 2*sizeof(int)`). | matches | Verified for V2. |
| 4.4.2 | Same idiom for seq (04-mm:505-507) | `NimSeqV2[T] = {len: int; p: ptr NimSeqPayload[T]}` (seqs_v2.nim:28-31). Layout-identical to NimStringV2 modulo element type. | matches | Verified. |
| 4.4.2 | `var s: NimStringV2; s.p = …; s.cap = s.p.cap; cast[string](s)` (04-mm:499-503) | `NimStringV2` has fields `{len, p}` — **there is no `cap` field** on `NimStringV2`. `cap` lives on `NimStrPayload`. So `s.cap = s.p.cap` does not compile under V2 layouts. The authored impl in `managed_slice.nim` is the source of truth; design code is *pseudocode that mis-names a field*. | drifts-semantically | Field name mistake in design. `len` is what reassembly needs (probably from a separate slot or recomputed from payload, since the payload has only `cap`, not `len`). **This is a real gap**: the slot stores only the payload pointer; from the payload alone you cannot recover the string's `len`. You can recover `cap`, but not the user's logical `len`. |
| 4.4.2 | "the destroy zeroes the `p` field after the read, so the extracted pointer survives" (04-mm:520-525) | The compiler-emitted `=destroy(s)` for `sink string` calls `nimDestroyStrV1(s)` → `frees(s)` → `dealloc(s.p)` (strs_v2.nim:236-237, :32-37). **It does not zero `s.p` before deallocating.** After destroy, `s.p` is a dangling pointer pointing to freed memory. Extracting the pointer before destroy and using it after destroy is a **use-after-free**, not a survives-because-of-nil-check pattern. | drifts-semantically (load-bearing) | OQ4.6 ramifications below. The "survives because the destroy sees nil" claim is incorrect; the destroy does not nil the pointer. |
| 4.4.3 | `nimIncRef(cast[pointer](uint(mslice)))` for arc/atomicArc (04-mm:537-542) | `nimIncRef(p)` does `increment head(p)` (arc.nim:167-175) which interprets `p - sizeof(RefHeader)` as a `RefHeader`. **For a `NimStrPayload*`, that memory is allocator bookkeeping, not a refcount field.** Either UB or a corruption-on-decrement timebomb. | **drifts-semantically (load-bearing)** | The entire incref/decref contract is wrong for string/seq. Needs replacement with transfer-ownership semantics OR copy semantics. |
| 4.4.3 | `nimDecRefIsLast` + `nimDestroyAndDispose` for orc/arc (04-mm:556-560) | `nimDestroyAndDispose(p)` casts `p` to `ptr PNimTypeV2` and calls `rti.destructor(p)` (arc.nim:218-229). **For a string payload `p` there is no `PNimTypeV2` at offset 0** — the offset-0 field is `cap: int`. UB. | **drifts-semantically (load-bearing)** | Same. |
| 4.4.3 | refc arm `discard` — "the copy in the push wrapper goes out of scope at pop" (04-mm:543-547) | refc string is `NimStringDesc` `{len, reserved, data: UncheckedArray[char]}` (system.nim:469-478), `NimString = ptr NimStringDesc`. Strings under refc ARE pointer-typed (sizeof(string) == sizeof(pointer)). GC reclaims them; user doesn't manage refcounts. | matches | refc arm is correct as written. |
| 4.4.3 | nimony arm: `arcInc` on `cast[ptr NimHeapHeader](p -! sizeof(NimHeapHeader)).rc` (04-mm:548-551) | Under nimony, strings/seqs have their own representation (see OQ4.4 §4.11). Whether nimony allocates string/seq payloads with a `NimHeapHeader` prefix is **not verifiable from Nim 2.2.10 sources alone** — it requires nimony source which is out of scope here. The compiler in the Nim 2.x line does not. | inconclusive (out of scope) | Needs nimony source consultation. Keep as open question for now. |
| 4.4.4 | refc slice arm: "fresh string/seq on the refc heap and `copyMem`'s the user's bytes into it; pop reassembles" (04-mm:564-585) | refc strings ARE heap-allocated value types with implicit copy-on-assignment. The pattern as described works at the semantic level. | matches | This arm is the only sub-section whose model is correct. **The right model for arc/orc/atomicArc is closer to this than to §4.4.3's refcount model.** |
| 4.4.5 | `pushSlice`: after `toManagedSlice(item)`, `incRefSliceSlot(mslice)` (04-mm:600-604) | Inherits the §4.4.3 incref breakage. | drifts-semantically | Same fix as 4.4.3. |
| 4.4.5 | `popSlice`: "the reassembled string/seq's caller-side `=destroy` will balance the +1 the queue held" (04-mm:622-628) | There is no "+1 the queue held" because string/seq payloads have no refcount field. The reassembled string's caller-side `=destroy` will call `nimDestroyStrV1` → `dealloc(s.p)` (strs_v2.nim:236-237 → :32-37), which frees the payload that the queue handed over. If the slot still held a copy of the same pointer, the next pop / destroy would double-free. | drifts-semantically | The correct framing is **transfer-ownership**: pop clears the slot AND hands the unique-owned payload pointer to the reassembled NimStringV2; the caller's `=destroy` then deallocates exactly once. This requires that `slotPopBitsAndClear` truly clears the slot (which §4.5 documents). |

---

## 3. Open question resolutions

### OQ4.1 — Per-MM symbol binding for string/seq lifecycle

**Resolution: NO cross-module-callable C symbol exists for "free a NimStringV2/NimSeqV2 payload" in Nim 2.x runtime.**

Evidence:
- `nimDestroyStrV1` (strs_v2.nim:236-237) is `{.compilerRtl, inl.}`. The `inl`
  pragma means the compiler may inline it at the call site; the emission rule
  for `compilerRtl, inl` is "emit per-TU when needed by `=destroy` codegen". No
  guarantee of a stable cross-module C symbol.
- There is **no `nimDestroySeqV1`** at all in seqs_v2.nim. The seq destroy is
  open-coded by the compiler per element type T (because element destructors
  must run before the buffer is freed).
- `nimIncRef` / `nimDecRefIsLast` / `nimDestroyAndDispose` (arc.nim:167, 238,
  218) DO exist as cross-module-callable compilerRtl symbols, but their
  operand contract is **a pointer to a RefHeader-prefixed allocation**
  (head(p) = p - sizeof(RefHeader); arc.nim:59-60). String/seq payloads are
  NOT RefHeader-prefixed (see verdict §1, point 1).

**Viable implementation paths (per the brief's enumeration):**

- **(A) Always-copy**: push allocates a fresh refc-style heap buffer and
  `copyMem`s; pop reassembles and lets the caller's `=destroy` reclaim. This
  is what §4.4.4 already specifies for refc and what the brief identifies as
  option A. Cost: O(len) per push/pop pair. Simplicity: very high.
- **(B) Transfer-ownership + cast-shell on destroy walk**: push extracts the
  payload pointer from the `sink` parameter and parks the bare pointer in the
  slot; pop reconstructs a `NimStringV2` shell `{len: <recovered>, p: <slot>}`
  and returns it; the caller's compiler-emitted `=destroy` runs
  `nimDestroyStrV1` → `dealloc(s.p)`, deallocating the single owner exactly
  once. Cost: O(1) per push/pop. Complication: `len` must be stored somewhere
  (slot is one word; need a second slot word OR pack len into the slot —
  Section 4.5 already uses uint64 slots for ManagedRef/ManagedSlice, so this
  may already be the model). The strlitFlag must be honoured (literal-string
  pushes must not be deallocated; per strs_v2.nim:32-37 `frees` template,
  `nimDestroyStrV1` already handles this — but only if the recovered `cap`
  field still has the strlitFlag bit set, which it will because the slot
  holds the same payload pointer).
- **(C) Manual dealloc + strlitFlag check**: pop calls a hand-rolled
  `freeStrPayload(p)` that mirrors `frees`: check strlitFlag, then `dealloc`
  or `deallocShared` per threads-mode. Cost: O(1). Complication: must
  duplicate the threads-mode branching from strs_v2.nim:32-37.

**(B) and (C) are nearly identical**; (B) lets the compiler emit the dealloc
for free at the cost of needing to fake up a proper `NimStringV2` shell with
the right `len`.

### OQ4.3 — Payload-pointer extraction divergence (V2 vs refc)

**Resolution:**

- **Arc/orc/atomicArc/nimony (NimStringV2 layout)**: `string` is a stack
  wrapper `{len: int; p: ptr NimStrPayload}` (strs_v2.nim:20-22).
  `sizeof(string) == 2*sizeof(int)`. Extraction:
  `cast[ptr NimStringV2](addr s).p` extracts the payload pointer. The
  design's §4.4.2 cast is layout-correct.
- **refc (NimStringDesc layout)**: `string` IS itself a pointer (`NimString
  = ptr NimStringDesc`, system.nim:478). `sizeof(string) == sizeof(pointer)`.
  Extraction:
  `cast[pointer](s)` IS the payload pointer (modulo the `TGenericSeq` base,
  which has `len, reserved` at the head — system.nim:469-477). The string's
  `len` lives in `s.len` (i.e., the heap header).

The two layouts are completely different. §4.4.2 only shows the V2 cast; the
refc cast is implicit in §4.4.4's "copy semantics — refc owns the lifetime".

### OQ4.5 — NimStringV2.cap tag-bit layout

**Resolution:**

- **`strlitFlag = 1 shl (sizeof(int)*8 - 2)`** (system.nim:1076).
  - On 64-bit: bit 62 (the second-highest bit, since `sizeof(int)*8 == 64`,
    shift by 62).
  - On 32-bit: bit 30.
- It is **NOT** the highest bit. The highest bit position
  (`shl (sizeof(int)*8 - 1)`) is `seqShallowFlag = low(int)` (system.nim:1075),
  which is a sign-bit marker for the legacy refc `seqShallowFlag`. (For V2
  payloads, only `strlitFlag` is used; `seqShallowFlag` is refc-era.)
- Purpose: **literal-string sentinel** — set when the payload pointer
  references compile-time-static memory (a string literal baked into the
  binary). When set, `=copy` shallow-copies the literal (strs_v2.nim:197-201
  `nimAsgnStrV2`) and `=destroy` skips the `dealloc` (strs_v2.nim:32-37
  `frees`). When mutating a literal, `nimPrepareStrMutationV2`
  (strs_v2.nim:220-222) clones into a fresh heap allocation.
- Reading the true capacity: `s.p.cap and not strlitFlag`
  (strs_v2.nim:251, :83, :166).
- Same flag and same semantics for seqs (seqs_v2.nim:72, :75, :105, :107,
  :137, :157, :174, :210, :233).

**Implication for the shim**: if option (B) or (C) is taken, the destroy
path MUST mirror `frees`'s literal check, OR (under B) reconstruct a proper
`NimStringV2` and let the compiler-emitted destroy do it. If literal-string
pushes are not handled, attempting to `dealloc` a literal payload (which
lives in .rodata or similar) will crash.

### OQ4.6 — `sink string` destroy ordering

**Resolution: the design's claim is incorrect.**

Design says (04-mm:520-525): "the compiler-emitted `=destroy` on the sink
would balance the implicit incRef that the compiler emitted at the call
site, but `toManagedSlice` extracts the payload pointer BEFORE the destroy
runs (the destroy zeroes the `p` field after the read, so the extracted
pointer survives — the destroy sees a nil `p` and does nothing)."

What actually happens for `sink string`:
1. At the call site, `sink` parameter passing in Nim 2.x with destructors
   emits a **move** when the source is consumed (no incRef — strings have no
   refcount). The caller's stack-side `s` is wasMoved (its `p` zeroed,
   `len = 0`).
2. Inside the proc, the parameter `s` owns the payload.
3. At proc return, the compiler emits `=destroy(s)` which calls
   `nimDestroyStrV1(s)` → `frees(s)` → `dealloc(s.p)` (strs_v2.nim:236 →
   :32-37). **`frees` does NOT zero `s.p` before the dealloc** (the template
   body just does the dealloc).
4. Therefore, extracting `s.p` into the slot and letting destroy run **frees
   the payload that the slot now points at** — use-after-free at the next
   pop.

The correct discipline for the `sink string` arm is to **`wasMoved(s)`
explicitly inside `toManagedSlice` after extracting the pointer**, so that
the compiler-emitted destroy sees an already-moved (nil-p) string and skips
the dealloc. This is the standard Nim 2.x ownership-transfer idiom. Pattern:

```nim
proc toManagedSlice*(s: sink string): ManagedSlice[char] {.inline.} =
  let p = cast[ptr NimStringV2](addr s).p
  cast[ptr NimStringV2](addr s).p = nil  # OR `wasMoved(s)` for full reset
  cast[ptr NimStringV2](addr s).len = 0
  result = ManagedSlice[char](cast[uint](p))
```

(The design's surface idiom — `cast` to extract `p` — is right; the
explanation of WHY the destroy doesn't free it is wrong, and an
implementation that relies on the wrong explanation will use-after-free.)

### NEW OQ — Are seq[U] payloads identical layout to string payloads modulo element type?

**Resolution: YES, modulo `data: UncheckedArray[U]` vs `data:
UncheckedArray[char]` and alignment.**

- `NimStrPayload = {cap: int; data: UncheckedArray[char]}` (strs_v2.nim:16-18).
- `NimSeqPayload[T] = {cap: int; data: UncheckedArray[T]}` (seqs_v2.nim:24-26).
- `NimStringV2 = {len: int; p: ptr NimStrPayload}` (strs_v2.nim:20-22).
- `NimSeqV2[T] = {len: int; p: ptr NimSeqPayload[T]}` (seqs_v2.nim:28-31).
- Both payloads share `strlitFlag` semantics (see OQ4.5).
- Seq adds element-alignment via `align(sizeof(NimSeqPayloadBase),
  elemAlign)` (seqs_v2.nim:45, :63, :90) — the header is padded so the
  element data is aligned to `alignof(T)`. String doesn't need this because
  `alignof(char) == 1`.

The design's layout claim in §4.4.1 is correct in shape; only the
"RefHeader-prefixed" claim is wrong.

---

## 4. Canonical layout reference

### `NimStringV2` (stack-side wrapper) — strs_v2.nim:20-22
```
+----------------+
| len: int       |  offset 0
+----------------+
| p: ptr Payload |  offset sizeof(int)
+----------------+
sizeof = 2 * sizeof(int)   (16 bytes on 64-bit)
```

### `NimStrPayload` (heap-side, ref'd by NimStringV2.p) — strs_v2.nim:16-18
```
+----------------+
| cap: int       |  offset 0  (high bits hold strlitFlag = 1 shl 62 on 64-bit)
+----------------+
| data: char[]   |  offset sizeof(int), UncheckedArray
+----------------+
Allocated by alloc(contentSize(newLen)) = alloc(newLen+1+sizeof(int))
NO RefHeader prefix.
```

### `NimSeqV2[T]` — seqs_v2.nim:28-31
```
+----------------+
| len: int       |  offset 0
+----------------+
| p: ptr Payload |  offset sizeof(int)
+----------------+
```

### `NimSeqPayload[T]` — seqs_v2.nim:24-26
```
+----------------+
| cap: int       |  offset 0  (high bits = strlitFlag)
+----------------+
| pad to elemAlign|
+----------------+
| data: T[]      |  offset align(sizeof(NimSeqPayloadBase), alignof(T))
+----------------+
Allocated by alignedAlloc0(...) per seqs_v2.nim:45.
NO RefHeader prefix.
```

### `RefHeader` (only for `ref T`) — arc.nim:34-46
```
+----------------+   <- p - sizeof(RefHeader)
| rc: int        |  refcount (with low rcShift bits reserved; arc.nim:21-29)
+----------------+
| (orc) rootIdx  |  only when -d:gcOrc
+----------------+
                 |   <- p (the pointer user code holds)
| object body    |
| ...            |
+----------------+
Placed by nimNewObj / nimNewObjUninit (arc.nim:107-150). NEVER placed
by allocPayload / newSeqPayload. Therefore NEVER present on string
or seq payloads.
```

### `NimStringDesc` (refc legacy) — system.nim:469-478
```
NimStringDesc inherits TGenericSeq:
+----------------+   <- the `string` value itself (single pointer)
| len: int       |  TGenericSeq.len
+----------------+
| reserved: int  |  TGenericSeq.reserved (holds strlitFlag, seqShallowFlag)
+----------------+
| data: char[]   |  NimStringDesc.data, UncheckedArray
+----------------+
NimString = ptr NimStringDesc; under refc, sizeof(string) == sizeof(pointer).
```

---

## 5. Per-MM ManagedSlice contract — what `wrap`/`unwrap`/`inc`/`dec`/`reset` ACTUALLY need to do

Under the corrected model (option B — transfer-ownership; preferred):

| MM | wrap (push) | unwrap (pop) | incRefSliceSlot | decRefSliceSlot | reset (drop slot) |
|---|---|---|---|---|---|
| arc / atomicArc / orc | Extract payload `p`, save `len`, `wasMoved` the source. Pack `(p, len)` into the slot (2 words). | Read `(p, len)` from slot, build `NimStringV2{len, p}`, return as string. Slot is cleared by `slotPopBitsAndClear`. | **no-op** (slot owns the unique payload; there is no refcount) | **no-op on inc/dec balance**; on drop call `nimDestroyStrV1`-equivalent: free payload honouring strlitFlag, OR reconstruct shell + let compiler `=destroy` run | reconstruct `NimStringV2{len, p}`, run `=destroy` via discard pattern, slot bits cleared |
| refc | Allocate fresh refc string, copyMem bytes, pack pointer into slot. | Build refc string from slot pointer; GC reclaims. | no-op | no-op | discard (GC) |
| mm:none | n/a (no managed slices under mm:none per design Section 2.x; or fall back to copy) | n/a | discard | discard | discard |
| nimony | Depends on nimony runtime — out of scope; needs separate investigation. | — | — | — | — |

Key observation: **there is no per-MM "+1/-1" slot operation needed for
strings/seqs.** The push-success / pop-success flow naturally transfers
unique ownership. The only places work happens are:
- On push-fail: reconstruct and destroy the would-have-been payload (so it
  doesn't leak).
- On pop-success: hand ownership to the reassembled string (caller's
  `=destroy` reclaims).
- On queue-destroy with unpopped slots: walk slots, reconstruct + destroy
  each.

This is dramatically simpler than the refcount-flavoured contract in §4.4.3.

---

## 6. Recommended implementation path

**Recommend option (B): transfer-ownership + cast-shell on destroy walk.**

Tradeoff analysis (one paragraph):

(A) always-copy is the simplest and lets the refc arm and the V2 arms share
one implementation, but it pays O(len) on every push and every pop, defeating
the lockfree-queue's zero-copy promise for large strings/seqs and forcing
the user to think about copy cost on every site. (B) transfer-ownership
preserves O(1) push/pop, keeps the user-visible API identical to plain
`string`/`seq[T]`, and reuses the compiler's already-emitted `=destroy`
codegen for the reassembled value — at the cost of one explicit
`wasMoved`-style cleanup inside `toManagedSlice` and a `reset` walker for
queue-destruction. The complication of strlitFlag handling and threads-mode
dealloc routing is absorbed transparently by going through a reconstructed
`NimStringV2` shell (the compiler's emitted destroy calls
`nimDestroyStrV1` → `frees`, which already encapsulates both concerns).
(C) manual dealloc + strlitFlag is functionally equivalent to (B) but
duplicates `frees`'s logic in the shim, which means tracking Nim runtime
internals on every Nim version bump — a maintenance burden (B) avoids.
**(B) is the most-correct, least-deferred, most-ergonomic, easiest-to-
understand path.** It does require a small bit of unsafe-shell construction
on pop, but that idiom is already present in the design's §4.4.2 and is
intrinsically tied to the layout — there is no way to avoid it short of
giving up O(1).

For refc, retain §4.4.4's copy-semantics arm verbatim — that section is
correct as written.

For mm:none, the design's discard arms are correct (no GC, no destructors;
ownership tracking is the user's responsibility — this is documented in
Section 2.x).

For nimony, defer — surface as a remaining open question.

---

## 7. Recommended §4.4 edits (action list for design rewrite)

1. **§4.4.1 — rewrite the layout description.** Replace the "RefHeader
   the C-RTL uses for ref T allocations" claim. Use the diagrams from §4 of
   this report. Cite strs_v2.nim:16-22 and seqs_v2.nim:24-31. State
   explicitly that string/seq payloads do NOT carry a RefHeader and are NOT
   refcounted.
2. **§4.4.2 — fix the reassembly pseudocode field name.** Replace `s.cap =
   s.p.cap` with the correct field (`s.len = <recovered length>`), and
   explain that `len` must be stored alongside the payload pointer in the
   slot (the slot is then 2 words, not 1; or use a separate per-slot length
   array — design decision; cross-reference §4.5 cell shape).
3. **§4.4.2 — fix the sink-destroy explanation.** Replace the "destroy
   zeroes p" framing with the correct "we must `wasMoved` the source after
   extracting the payload pointer" framing. Quote `frees` template
   (strs_v2.nim:32-37) as evidence that destroy does not nil the pointer.
4. **§4.4.3 — rewrite the per-MM template bodies completely.** Drop the
   `nimIncRef` / `nimDecRefIsLast` / `nimDestroyAndDispose` calls in the
   arc/orc/atomicArc arms. Replace with transfer-ownership semantics
   (per §5 of this report). Keep the refc arm verbatim. For nimony, mark
   as TBD pending nimony runtime investigation.
5. **§4.4.4 — keep verbatim.** This sub-section is the only one whose
   model is correct.
6. **§4.4.5 — rewrite push/pop wrappers** to reflect transfer-ownership.
   Replace "+1 the queue held" framing throughout. Add the queue-destroy
   walker that reconstructs `NimStringV2` shells from unpopped slots so
   leftover payloads aren't leaked.
7. **§4.11 OQ4.1 — close as resolved by this report.** Cite this document.
8. **§4.11 OQ4.3 — close as resolved by this report.** Cite this document.
9. **§4.11 OQ4.5 — close as resolved by this report.** Document
   `strlitFlag` location, value, and purpose.
10. **§4.11 OQ4.6 — close as resolved by this report.** Document the
    `wasMoved` requirement.
11. **Add a new OQ4.7** for nimony string/seq layout and lifecycle,
    feeding §4.4.3's nimony arm.

**Estimated rewrite scope: medium-to-large.** Roughly half of §4.4
(specifically 4.4.1, 4.4.3, parts of 4.4.2, and 4.4.5) needs material
rewriting. §4.4.4 is untouched.

---

## 8. Open questions remaining

- **Nimony string/seq layout and lifecycle.** This investigation only
  covers Nim 2.2.10. Nimony has its own runtime; whether nimony places a
  `NimHeapHeader` (or any RefHeader-equivalent) on string/seq payloads,
  and whether `arcInc` / `arcDec` are valid on payload pointers under
  nimony, requires nimony-source review. Until then the nimony arm in
  §4.4.3 should be a stub.
- **Slot bit-packing for the (p, len) pair.** Option B requires the slot
  to carry both the payload pointer and the logical length. Whether this
  is two slot words (changing the queue cell shape from `uint` to
  `uint64`-pair / object) or pointer-tag-packing or a side-array
  depends on §4.5 cell-shape decisions. This needs a focused micro-design
  pass.
- **Queue-destroy walker.** When a `QueueSlice[T]` is destroyed with
  un-popped payloads still in slots, those payloads must be reclaimed.
  The current design does not specify this walker. Needs a §4.4.6 or
  §4.4.5 amendment.
- **Atomicity of slot writes for (p, len) under MPSC/MPMC arms.** A
  two-word slot store cannot be atomic on most ISAs without DWCAS.
  §4.5 already documents the Vyukov-seq pattern that resolves this
  (commit-on-seq); confirm the resolution applies here as well.

---

## Bibliography

- [DESIGN] `docs/internal/design-sections/04-mm-compat-shim-and-cell-layouts.md:445-633` — §4.4 ManagedSlice shim impl details, sub-sections 4.4.1 through 4.4.5.
- [DESIGN-OQ] same file:1432 — §4.11 OQ4.4 nimony string/seq representation.
- [NIM-STRS] `/Users/eek/.nimble/pkgcache/githubcom_nimlangNimgit_2210/lib/system/strs_v2.nim:16-22` — `NimStrPayload` and `NimStringV2` layouts.
- [NIM-STRS] same file:28 — `isLiteral` template (strlitFlag check).
- [NIM-STRS] same file:32-37 — `frees` template (literal-aware dealloc; threads-mode branch).
- [NIM-STRS] same file:39-43 — `allocPayload` (bare alloc, no RefHeader).
- [NIM-STRS] same file:236-237 — `nimDestroyStrV1` (`compilerRtl, inl`).
- [NIM-STRS] same file:251 — `capacity` proc (demonstrates `s.p.cap and not strlitFlag`).
- [NIM-SEQS] `/Users/eek/.nimble/pkgcache/githubcom_nimlangNimgit_2210/lib/system/seqs_v2.nim:24-31` — `NimSeqPayload[T]` and `NimSeqV2[T]` layouts.
- [NIM-SEQS] same file:41-49 — `newSeqPayload` (alignedAlloc0, no RefHeader).
- [NIM-SEQS] same file:72-75 — strlitFlag use in `prepareSeqAdd`.
- [NIM-ARC] `/Users/eek/.nimble/pkgcache/githubcom_nimlangNimgit_2210/lib/system/arc.nim:34-46` — `RefHeader` definition.
- [NIM-ARC] same file:59-60 — `head` template (`p - sizeof(RefHeader)`).
- [NIM-ARC] same file:107-126, 127-150 — `nimNewObj` / `nimNewObjUninit` (the only RefHeader-placing allocators).
- [NIM-ARC] same file:167-175 — `nimIncRef(p)`.
- [NIM-ARC] same file:218-229 — `nimDestroyAndDispose(p)` (uses `cast[ptr PNimTypeV2](p)`).
- [NIM-ARC] same file:238-263 — `nimDecRefIsLast(p)`.
- [NIM-ARC] same file:265-273 — `GC_ref` / `GC_unref` (exported; require `ref T`).
- [NIM-SYS] `/Users/eek/.nimble/pkgcache/githubcom_nimlangNimgit_2210/lib/system.nim:469-478` — `TGenericSeq`, `NimStringDesc`, `NimString` (refc layout).
- [NIM-SYS] same file:1076 — `strlitFlag = 1 shl (sizeof(int)*8 - 2)`.
- [NIM-SYS] same file:1075 — `seqShallowFlag = low(int)` (high bit, refc-era).
- [IMPL] `src/lockfree/managed_slice.nim:115-142` — authored impl reflecting the (incorrect) refcount model.

---

## Return summary

```
ARTIFACTS_WRITTEN:
  - /Users/eek/Development/lockfree/docs/internal/section-4-4-string-seq-lifecycle-investigation-2026-06-06.md (≈430 lines)
SKILL_INVOCATION: fact-checking
VERDICT: C
KEY_FINDINGS:
  - NimStrPayload/NimSeqPayload have NO RefHeader; payloads are not refcounted; strings/seqs are value types with COW strlitFlag
  - nimIncRef/nimDecRefIsLast/nimDestroyAndDispose interpret p as RefHeader-prefixed; passing payload pointers is UB
  - nimDestroyStrV1 is compilerRtl+inl (per-TU emit), no cross-module C symbol for "free a string payload"
  - design §4.4.2 reassembly uses non-existent NimStringV2.cap field; must store/recover len some other way
  - design §4.4.2 sink-destroy "p is zeroed" claim is false; frees does not nil p; correct pattern is explicit wasMoved
  - strlitFlag = 1 shl (sizeof(int)*8-2), bit 62 on 64-bit, literal-string sentinel (not large/small-alloc discriminator)
  - §4.4.4 refc copy-semantics arm is the only sub-section that survives; same model should extend to arc/orc/atomicArc
RECOMMENDED_IMPL_PATH: B (transfer-ownership + cast-shell on destroy walk) — preserves O(1) push/pop, reuses compiler-emitted =destroy via reconstructed NimStringV2 shell, avoids duplicating frees/strlitFlag logic in shim; (A) always-copy is simpler but defeats zero-copy; (C) manual dealloc duplicates runtime internals
OQ_RESOLUTIONS:
  OQ4.1 = NO cross-module symbol exists for string/seq payload free; arc/orc/atomicArc symbols are for ref T only
  OQ4.3 = V2 string is 2-word wrapper {len,p}; refc string IS a pointer (sizeof = sizeof(pointer)); layouts diverge completely
  OQ4.5 = strlitFlag at bit 62 (64-bit) / bit 30 (32-bit); literal-string sentinel; NOT large/small discriminator
  OQ4.6 = sink destroy DOES free p (does not nil it first); shim MUST wasMoved the source after extracting payload pointer
DESIGN_EDIT_SCOPE: medium-to-large — §4.4.1, §4.4.2, §4.4.3, §4.4.5 require material rewrites; §4.4.4 untouched; 4 open questions resolved, 1 new (nimony) opened
```
