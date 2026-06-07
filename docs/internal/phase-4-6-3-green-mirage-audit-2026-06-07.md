# Phase 4.6.3 Green-Mirage Audit (2026-06-07)

## Summary
- Tests spot-checked: 5
- Mutation tests: 3 (incRefSlot removed, drain skip-first, withBound defer-close removed)
- Green-mirage findings: 2
- Real-coverage findings: 2 (1 inconclusive — environmental gate)

## Per-test findings

### 1. `tests/t_destructor_walk.nim` — REAL COVERAGE

**Claim:** ref-T refcount lifecycle balances through transit; queue's `=destroy`
on UNPOPPED slots invokes `disposeSlotEncoded` → `decRefSlot`.

**Actual assertion shape:** Suite A (10 tests) captures `let baseline = liveCount()`,
pushes RefCounter instances into a block-scoped queue, then `check liveCount() == baseline`
after the block. Suites B/C/D push N items (string/seq/POD) and run scope-exit destroy;
asserts the program does not crash. Suite E does partial-drain and asserts both the
drained sequence equality (full `seq[T]` comparison) AND clean scope exit. Suite F
asserts `drained == @["alpha","beta","gamma"]`.

**Mutation:** Commented out `incRefSlot(mrefView)` in
`src/lockfree/internal/path_c_wrap.nim:59` (the ref-T arm of `wrapOrIdentity`).

**Result:** RED — first test fails with **SIGSEGV** during refcount underflow on
destroy walk. The destroy-walk's `decRefSlot` attempts to dec a ref whose +1 was
never claimed; aborts on the alloc path. Test caught the broken implementation
immediately.

**Verdict:** SOLID. The refcount balance assertion (`liveCount() == baseline`)
plus the SIGSEGV-on-underflow behavior provide strong coverage of the ref-T
lifecycle.

---

### 2. `tests/composition/t_path_c_matrix.nim` — REAL COVERAGE (with one minor gap)

**Claim:** Covers all §2.5 ACCEPT rows of the Path-C 25-row composition matrix.

**Actual assertion shape:** Each row instantiates the queue, performs a real
push + pop, and asserts payload equality via `check body(q) == <expected>` or
similar full-value equality. Rows verified:
- Row 1 (ref int): `check body(q) == 42` after `qref.pop().get[]`
- Row 9 (RefArray8): `check body(q) == 17` after dereferencing element [3]
- Row 18 (seq[Foo]): `check popped.len == 3` + per-element `v` checks
- Row 19 (seq[seq[int]]): `check popped[0] == @[1,2]` + `popped[1] == @[3,4,5]`
- Row 23 (Node linked): `check body(q) == 12` (head.v*10 + next.v)

All checked rows perform a real round-trip with structural equality assertions
(Level 4-5 on the Assertion Strength Ladder — full payload equality, not
substring or existence).

**MINOR GAP:** Row 14 (RefWithDestroy) declares `var destroyCount {.global.}: int = 0`
and increments it inside `=destroy(x: DestroyTarget)`, but **destroyCount is never
read in any assertion**. The row asserts only `body(q) == 55` (the payload value).
A broken `=destroy` invocation would not be caught here — the global counter
is dead state. Row 18 lifecycle (CountedRef) DOES assert
`finalCount == baseline`, which compensates for the seq[ref U] arm; but the
direct ref-with-destroy arm at row 14 has no destroy-fire assertion.

**Mutation:** Not performed (matrix not in 3-mutation budget).

**Verdict:** SOLID for round-trip coverage. PARTIAL for destroy-fire verification
on row 14 (the global `destroyCount` is unused — vestigial state).

---

### 3. `tests/t_drain.nim` — REAL COVERAGE

**Claim:** Drain yields all items in pop order.

**Actual assertion shape:** Every drain test builds `var drained: seq[T] = @[]`,
iterates `for x in drain(q): drained.add(x)`, then asserts the FULL sequence
with structural equality, e.g.:
- `check drained == @["a", "b", "c"]`
- `check drained == @[10, 20]`
- `check drained == @[@[1, 2], @[3]]`
- `check drained == newSeq[int]()` (empty case)
- `check drained == @[100, 200]` (destroyAndDrain callback)

Level 5 GOLD assertions throughout — full expected `seq[T]` constructed and
compared. The brief's question "asserts equals expected `seq[T]` or just counts?"
is answered: every assertion uses full-sequence equality. No count-only,
no length-only, no substring.

**Mutation:** Modified the SPSC drain iterator at
`src/lockfree/bqueue.nim:950-960` to skip the first popped item via a
`skipped` flag.

**Result:** RED — 5 tests fail:
- `spsc bounded — string drain yields in FIFO order`: `drained was @["b", "c"]` vs `@["a","b","c"]`
- `spsc bounded — POD drain`: `drained was @[20]` vs `@[10, 20]`
- `bounded spsc — callback applied to every item then destroy`: `@[200]` vs `@[100, 200]`
- `unbounded spsc — string callback`: similar
- `mm:none drain contract`: `drained was @[8, 9]` vs `@[7, 8, 9]`

Each failure cites the missing first element in clear diff form. Strong RED visibility.

**Verdict:** SOLID. Full-sequence equality + multiple-cardinality coverage.

---

### 4. `tests/t_chronos.nim` — COVERAGE INCONCLUSIVE (gated off)

**Claim:** Cancellation discipline — cancelling a pop Future raises CancelledError
and the queue remains usable after.

**Actual assertion shape:** Inside `popFut.cancelSoon()` block, asserts
`raised == true` after catching `CancelledError`. THEN asserts post-cancel
queue consistency: `check q.push(99) == true` + `waitFor(q.pop()) == some(99)`.
This IS a substantive cancellation contract test.

**Mutation attempted:** Changed `raise e` → `discard e; return none(T)` at
`src/lockfree/chronos.nim:227-230`.

**Result:** **INCONCLUSIVE — the entire test body is `when (compiles do:
import chronos)`-gated and that gate evaluates FALSE in the local
nimble environment.** Both the baseline run AND the mutated run produced
`Success: Execution finished` with no test output (verified via a
`probegate.nim` instrumented file that printed `CHRONOS GATED OFF`
through `nimble c -r`).

**GREEN MIRAGE PATTERN — "silent skip on missing optional dep":** The
`t_chronos.nim` file uses a `compiles do: import chronos` gate to make the
file a no-op when chronos isn't reachable. In CI lanes where chronos IS
installed this gate opens and the test runs. But on this dev environment
the file silently produces zero test output, and a developer running
`nim c -r tests/t_chronos.nim` could believe cancellation is verified
when nothing executes. The mutation could not be killed because the test
never ran.

**The assertion design itself (when reached) is sound** — the
`raised == true` + post-cancel `push + pop == some(99)` ladder would catch
the mutation under a chronos-available run. The Phase 4.6.3 environmental
gap is dev-machine visibility, not test design.

**Verdict:** UNVERIFIED IN THIS ENV. Recommend a single explicit-error sentinel
test outside the gate that fails compilation (or runs `echo "chronos test gated"`
via a non-gated `static:` check + CI assertion) so silent skip is loud.
Alternatively, require chronos as a dev dep via `lockfree.nimble`.

---

### 5. `tests/t_typestate_dual_api.nim` — **GREEN MIRAGE CONFIRMED**

**Claim (per file docstring):** `withBoundEndpoint` releases binding at scope exit.

**Actual assertion shape:** Every test uses pattern
`withBoundProducer(q, p): check p.push(x)` then immediately `q.pop()` outside
the block. **No test does a follow-up `withBoundProducer`/`withBoundConsumer`
to verify the producer/consumer slot was released and is re-bindable.**

Looking at the BQueue MPSC test (lines 27-33):
```nim
var q = newBQueue[int, ccMulti, ccSingle, 16, 4, 0]()
withBoundProducer(q, p):
  check p.push(42)
  check p.push(43)
check q.pop() == some(42)   # ← outside-the-block check uses bare q.pop()
check q.pop() == some(43)
check q.pop().isNone
```

The post-block `q.pop()` calls go through the bare queue, NOT through a
new `withBoundProducer`. So whether the `defer: close()` actually ran or not
is invisible to these assertions.

**Mutation:** Removed the `defer: discard endpoint.close()` lines in both
`withBoundProducer` and `withBoundConsumer` templates at
`src/lockfree/typestates/with_bound.nim:73-74` and `:87-88`.

**Result:** **GREEN — all 12 tests still pass.** The "releases binding at
scope exit" claim is NOT verified by any assertion in the suite. The RAII
contract is structurally untested.

**Production impact:** If the `close()` were inadvertently dropped from
the template (e.g., during a refactor), the binding would leak past the
block. For ccMulti producer slots that means the slot stays "owned" by
the first thread, and subsequent `withBoundProducer` calls from the same
thread might succeed (slot-already-owned re-acquire) but a DIFFERENT
thread calling `withBoundProducer` could see "no available slot" if the
slot pool is saturated. This is silently broken in this test suite.

**Fix code (add at least one test per template):**
```nim
test "BQueue MPSC — withBoundProducer releases slot on scope exit":
  var q = newBQueue[int, ccMulti, ccSingle, 16, 1, 0]()  # single-slot pool
  withBoundProducer(q, p):
    check p.push(1)
  # If the slot wasn't released, the next withBoundProducer would fail
  # (raise or assertion) when the pool is single-slot.
  withBoundProducer(q, p2):
    check p2.push(2)
  check q.pop() == some(1)
  check q.pop() == some(2)

test "BQueue SPMC — withBoundConsumer releases slot on scope exit":
  var q = newBQueue[int, ccSingle, ccMulti, 16, 0, 1]()  # single-slot pool
  check q.push(1)
  check q.push(2)
  withBoundConsumer(q, c):
    check c.pop() == some(1)
  withBoundConsumer(q, c2):
    check c2.pop() == some(2)
```

**Verdict:** GREEN MIRAGE. The test file name and docstring claim RAII
release semantics that the assertions do not exercise.

---

## Cross-test gaps

- **`destroyCount` global in t_path_c_matrix.nim is incremented but never asserted.**
  Either remove (dead state) or add a row that pushes a `RefWithDestroy`, lets the
  queue scope-exit destroy it, and asserts `destroyCount` changed by the expected delta.
- **Chronos gate silence.** `t_chronos.nim` runs zero tests in environments where
  chronos isn't found, and produces no diagnostic. Either declare chronos as a dev
  dependency in `lockfree.nimble` so the gate always opens locally, or emit a
  loud `echo "T-CHRONOS: gated off — chronos not installed"` so silent skip is
  observable.
- **`withBoundEndpoint` RAII release contract is unverified end-to-end.** See
  Finding 5 fix code.

## Recommendation

**needs 2 fixes (1 critical RAII gap, 1 visibility gap):**

1. **CRITICAL (Finding 5 — green mirage):** Add the two tests above to
   `tests/t_typestate_dual_api.nim` that verify the RAII close actually
   releases the slot, exercising single-slot pool saturation/release.
   Effort: trivial (10 minutes, drop-in tests).

2. **MODERATE (Finding 4 — silent skip):** Either add chronos to the
   dev dependencies in `lockfree.nimble` (so `nimble test` always runs
   t_chronos), OR add an out-of-gate echo so missing chronos is visible.
   Effort: trivial (5 minutes for echo; moderate if adding the dep
   triggers downstream dep churn).

3. **MINOR (cross-test):** Remove or use `destroyCount` in
   `tests/composition/t_path_c_matrix.nim`. Effort: trivial.

Mutation tests 1 (`incRefSlot`) and 2 (drain skip-first) confirmed strong
RED visibility on those code paths. The `withBound` mutation is the
load-bearing finding for this audit.

## Mutation log (verified restored)

- `src/lockfree/internal/path_c_wrap.nim:59` — `incRefSlot` commented → SIGSEGV → restored.
- `src/lockfree/bqueue.nim:950-960` — skip-first variant → 5 test fails → restored.
- `src/lockfree/typestates/with_bound.nim:73-74, 87-88` — `defer: close` removed → 12/12 still pass (mirage) → restored.

`git diff` on the four mutated files is empty post-restoration.
