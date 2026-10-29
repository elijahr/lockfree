## Path-C admission dispatch — the user-facing `T` type-class gate that sits
## at the head of every `Queue` / `BQueue` push, pop, drain entry point.
##
## Behaviour
## ---------
## * Path-C string / seq handling (no `ManagedSlice` indirection).
## * `when T is ref:` composition matrix (25 rows; verbatim REJECT messages for
##   rows 7 and 8).
## * Nullable T handling (`nil` passthrough — not a reject).
## * ref T rejection rules (canonical `when` / `elif` chain shape).
## * mm:none + ref T contract details (pure bit transport).
## * ManagedRef[X] shim impl details (per-MM inc/dec wrappers).
## * Path-C string / seq inline transfer-ownership: `sink string` / `sink
##   seq[U]` flow through the slot's `Pair.second` half. Per-MM treatment lives
##   at the call site inside the queue's push/pop body; this admission template
##   only validates the type-class.
##
## Why a template, not a `when` block inlined at every call site
## ------------------------------------------------------------
##
## The reject/accept chain repeats VERBATIM at every user-facing push, pop, and
## drain entry across both `queue.nim` and `bqueue.nim`. Inlining it 14+ times
## would bake the REJECT messages into copies that drift the moment someone
## updates one and forgets the others. Centralising it in one template makes the
## matrix the single source of truth.
##
## The template expands to a `when` chain that emits either a compile-time
## `{.error.}` (REJECT rows + unsupported fallback) or expands to nothing
## (ACCEPT rows).
##
## NOT user-facing
## ---------------
##
## This module is an internal implementation detail. Users see only the `Queue`
## / `BQueue` types and their push/pop/drain APIs.

import std/[macros, strutils, typetraits]

proc hasManagedFieldsImpl(n: NimNode, depth: int = 0): bool {.compileTime.}

proc hasManagedFieldsRec(rec: NimNode, depth: int): bool {.compileTime.} =
  if rec.isNil or depth > 32: return false
  case rec.kind
  of nnkRecList:
    for c in rec:
      if hasManagedFieldsRec(c, depth + 1): return true
  of nnkIdentDefs:
    if rec.len >= 2:
      return hasManagedFieldsImpl(rec[^2], depth + 1)
  of nnkRecCase:
    if rec.len > 0 and hasManagedFieldsRec(rec[0], depth + 1): return true
    for i in 1 ..< rec.len:
      let b = rec[i]
      if b.len > 0 and hasManagedFieldsRec(b[^1], depth + 1): return true
  else:
    discard
  return false

proc hasManagedFieldsImpl(n: NimNode, depth: int = 0): bool {.compileTime.} =
  if n.isNil or depth > 32: return false
  case n.kind
  of nnkBracketExpr:
    if n.len >= 2 and n[0].kind in {nnkSym, nnkIdent} and eqIdent(n[0], "typeDesc"):
      return hasManagedFieldsImpl(n[1], depth + 1)
    if n.len >= 1 and n[0].kind in {nnkSym, nnkIdent}:
      let head = n[0].strVal.toLowerAscii()
      if head == "seq":
        return true
      if head in ["ptr", "distinct", "set", "proc", "iterator", "range", "enum", "var", "lent", "sink"]:
        return false
      if head == "array":
        return hasManagedFieldsImpl(n[^1], depth + 1)
    let impl = n.getTypeImpl()
    if impl.kind notin {nnkNilLit, nnkSym, nnkIdent, nnkBracketExpr}:
      return hasManagedFieldsImpl(impl, depth + 1)
  of nnkSym, nnkIdent:
    if n.strVal == "string":
      return true
    if n.kind == nnkSym:
      let impl = n.getTypeImpl()
      if impl.kind in {nnkSym, nnkIdent}:
        return impl.strVal == "string"
      elif impl.kind != nnkNilLit:
        return hasManagedFieldsImpl(impl, depth + 1)
  of nnkRefTy:
    return true
  of nnkPtrTy, nnkDistinctTy, nnkEnumTy, nnkProcTy, nnkIteratorTy:
    return false
  of nnkObjectTy:
    if n.len >= 2 and n[1].kind == nnkOfInherit and n[1].len > 0:
      if hasManagedFieldsImpl(n[1][0], depth + 1): return true
    if n.len >= 3:
      if hasManagedFieldsRec(n[2], depth + 1): return true
  of nnkTupleTy, nnkTupleClassTy, nnkTupleConstr:
    for c in n:
      if c.kind == nnkIdentDefs:
        if c.len >= 2 and hasManagedFieldsImpl(c[^2], depth + 1): return true
      else:
        if hasManagedFieldsImpl(c, depth + 1): return true
  else:
    discard
  return false

macro hasManagedFields*(T: typedesc): untyped =
  newLit(hasManagedFieldsImpl(T.getTypeImpl()))

template pathCAdmit*(T: typedesc) =
  ## Static dispatch / admission gate for `Queue[T, ...]` and `BQueue[T, ...]`
  ## push, pop, drain entries.
  ##
  ## Emits compile-time `{.error.}` for the REJECT rows (distinct ref alias row
  ## 7, nested `ref ref` row 8, value types with managed fields) and the
  ## unsupported-T fallback. Accept rows (`ref T`, `string`, `seq[U]`, POD)
  ## expand to nothing; their per-MM lifecycle handling lives at the call site
  ## below.
  ##
  ## The chain ORDER MATTERS. Reject arms must come BEFORE accept arms so a `ref
  ## ref Foo` does not match the plain `T is ref` accept arm by way of "outer
  ## ref still matches `is ref`."
  ##
  ## Row order verification:
  ##
  ## * `T is ref and (T is ref ref ...)` reject arm matches nested refs. `T is
  ##   ref` plain accept arm fires only for direct `ref` to a non-ref user type,
  ##   never for `ref ref`.
  ## * `T is distinct and distinctBase(T) is ref` reject arm matches
  ##   distinct-of-ref aliases. Plain `T is distinct` does not match
  ##   non-distinct types so the downstream `T is ref` accept arm catches
  ##   exactly the intended population.
  ##
  ## Nullable note: `nil` for `ref T`, `ptr T`, `pointer`, and `cstring` is
  ## ACCEPTED (slot bits = 0, disambiguated by the seq counter / committed flag
  ## at the slot-state predicate layer). The admit chain does NOT reject `nil`.
  # Reject row 8 — nested ref. The canonical form uses the literal `T is ref
  # ref` typeclass; verified working under Nim 2.x typeclass matching (`ref ref
  # X` matches the `ref ref` typeclass; `ref X` does NOT — see Nim typeclass
  # rules and the corresponding `tests/should_fail/` rejection case).
  when T is ref ref:
    {.error: "Queue item type '" & $T & "' is a nested ref. " &
      "Nested refs have ambiguous lifecycle semantics. " &
      "Use a single ref to a wrapper type, or restructure to " &
      "a single level of indirection.".}
  # Reject row 7 — distinct ref alias.
  elif T is distinct and distinctBase(T) is ref:
    {.error: "Queue item type '" & $T & "' is a distinct ref alias. " &
      "Distinct ref types bypass the queue's automatic refcount " &
      "bookkeeping and would leak. Unwrap with distinctBase at the " &
      "call site, or define your own push/pop wrappers that handle " &
      "the lifecycle.".}
  # Value-type-with-managed-fields rejects. These would silently leak if routed
  # through any of the accept arms. Types with custom `=copy {.error.}` but no
  # managed fields are safe POD/value types.
  elif (T is object or T is tuple) and hasManagedFields(T):
    {.error: "Queue item type '" & $T & "' is a value type containing " &
      "managed fields (ref, string, or seq). Wrap in `ref " & $T & "` " &
      "and pass the ref through the queue, or split the managed " &
      "fields out and transport them separately.".}
  # Accept row band 1 — `ref T` (rows 1-6, 9-15, 23-25). Per-MM ManagedRef[X]
  # inc/dec lives in managed_ref.nim and fires at the call site's push/pop body
  # (queue.nim / bqueue.nim).
  elif T is ref:
    discard
  # Accept row 16 — `string`. Per-MM transfer-ownership (`sink` extract,
  # `wasMoved`, payload park) lives at the call site.
  elif T is string:
    discard
  # Accept rows 17-19 — `seq[U]`. No element-type guard: seq[ref U] and
  # seq[seq[U]] are ACCEPTED. Inner-element lifecycle is handled by Nim's
  # compiler-emitted seq =destroy when the box is reconstructed at pop or
  # destroy-walk. The library's transport is the outer seq value (boxed in
  # ManagedSlice); inner refs are the seq's lifecycle problem.
  elif T is seq:
    discard
  # Accept rows 20-22 + plain POD — `ptr T`, `cstring`, `pointer`, and any
  # plain POD that satisfies `supportsCopyMem` or has no managed fields.
  elif supportsCopyMem(T) or ((T is object or T is tuple) and not hasManagedFields(T)):
    discard
  # Unsupported fallback (default arm).
  else:
    {.error: "Queue item type '" & $T & "' is not supported. " &
      "Supported payloads: POD types, `ref T`, `string`, " &
      "`seq[T]`, `ptr T`, `pointer`, `cstring`. See " &
      "docs/guide/memory-management.md for the full constraint matrix.".}
