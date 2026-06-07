# Phase 2.4.5 Coherence Audit Report

**Date**: 2026-06-06
**Document under review**: `docs/internal/2026-06-05-umbrella-v0.1.0-design.md` (5865 lines, post-Phase-2.4)
**Companion under review**: `docs/internal/safety-argument.md` (529 lines)
**Verdict**: **COHERENT** (with 1 minor drift point)

## Summary

- Contradictions: **0**
- Gaps (decision not reflected): **0**
- Drift points (close but not exact): **1**

Top-line: the post-Phase-2.4 design doc faithfully encodes every operator-locked
decision from the handoff Session updates (lines 11-1105) and Phase 1.5
understanding doc. The Path C "ref T user-facing / ManagedRef internal" surface
is consistent across all sections (1, 2, 4, 5, 7), the mm:none strict bit-transport
contract is cross-referenced from §1.9, §2.8, §4.2.1, §4.8, and §5.7.3, the
nebr naming + D1/D2/D3/D4/D7 deviation honesty is captured in §3.2/§3.7/§3.8 +
the safety-argument companion, and the CRITICAL #5 publication-path deferral is
explicit in §1.2, §6.9.4, and §7.7. CI matrix §6 follows the smart-consolidation
rationale and the "no autonomous scope cuts" standing rule is encoded in §6.4 + §7.6.

The single drift point is a phrasing artifact at design-doc line 3968 ("the POD
path is what v5.0.0 already ships") that contradicts the handoff lock-in that
**no lockfreequeues v5.0.0 will ever ship**; recommend a one-word fix.

## Findings by category

### Identity decisions

| Sub-decision | Status | Citation |
|---|---|---|
| v0.1.0 fresh start; no tag carry-over | **PASS** | design §1.2 line 156 ("Version: 0.1.0 (fresh start under the new name)"); handoff line 367 ("v0.1.0 fresh start, no tag carry-over") |
| Package name `lockfree`; module path `lockfree/<submodule>` | **PASS** | design §1.3 lines 175-215 (full module tree); handoff line 273 / 1112 |
| SMR namespace `lockfree/smr/<strategy>` | **PASS** | design §1.3 lines 207-208, §3.2 lines 1411-1413; handoff lines 1014-1024 |
| v0.1.0 ships `nebr` only; `debra_plus.nim` RESERVED | **PASS** | design §1.3 line 207 ("debra_plus.nim # RESERVED"), §3.2.1 lines 1411-1413, §3.2.2 lines 1511-1527; handoff lines 1014-1029 |
| Future strategy stubs commented but NOT built | **PASS** | design §1.3 lines 207-209 (all four — `ebr.nim`, `debra_plus.nim`, `hazard.nim`, `ibr.nim`, `nbr.nim` — listed as RESERVED comments, not buildable files) |
| lockfreequeues frozen until lockfree-temp v0.1.0 solid | **PASS (1 drift point)** | design §1.2 lines 161-163 ("ships in lockfree-temp"), §7.7 lines 5508-5525; handoff lines 300-336. **DRIFT**: design line 3968 says "v5.0.0 already ships" — see Drift Points below. |

### Path C (refcounted payload API)

| Sub-decision | Status | Citation |
|---|---|---|
| `ref T` is USER-FACING; `ManagedRef[X]` is INTERNAL-ONLY | **PASS** | design §1.9 line 487, §2.5 line 1014, §5.1.4 lines 3954-3968; handoff lines 506-513, 539-544 |
| Same for `ManagedSlice[T]` (user surface = `string` / `seq[T]`) | **PASS** | design §1.9 line 487, §2.6/§2.7 implicit, §5.1.4 lines 3956-3968 (explicit "no `Queue[ManagedSlice[T]]` leakage"), §5.7 §7.4 IA `guide/managed-slice.md` |
| Applies to BOTH Queue and BQueue across all cardinality arms | **PASS** | design §2.5 lines 1014-1305 (the CRITICAL #1 composition matrix), §4.2/§4.5 per-MM rows for both, §5.1.5 §5.2 (BQueue Path C); handoff lines 686-693 ("Path C applies to both bounded and unbounded queues") |
| User never writes `ManagedRef[X]` or `ManagedSlice[T]` | **PASS** | design lines 334, 548 (`var q: Queue[ref Job, ...] # user writes ref Job, NOT ManagedRef`), 3968 (explicit no-leakage statement). NO sample in §5 uses `Queue[ManagedRef[T], ...]` form. |
| Internal dispatch via `when T is ref:` and `when T is string\|seq:` | **PASS** | design §5.1.4 lines 3954-3968, §4.2.3, §4.5 cell-shape table |

### mm:none

| Sub-decision | Status | Citation |
|---|---|---|
| mm:none REQUIRED (Phase 1.5 Q4 / CRITICAL #2 lock-in) | **PASS** | design §1.2 line 162-style required-MMs row, §2.8 ("mm:none + ref T contract details"), §4.2.1 mm:none row at line 2659 (`discard` for all ops); handoff lines 416-420, 803-820 |
| Contract: pure bit transport; queue does NOT touch unpopped slot bits at destroy | **PASS** | design §2.8 lines 1214-1257, §4.2.1 line 2659 ("Pure bit transport per Phase 1.6 CRITICAL #2 disposition"), §4.7.4, §5.7.3 lines 3445-3479; handoff lines 805-816 |
| User owns lifecycle under mm:none | **PASS** | design §2.4.5 line 1009 (`docs/guide/memory-management.md` cross-ref), §4.7.4 line 3466 ("mm:none: no walk. User must drain or destroyAndDrain"), §5.7.3 lines 4401-4402; handoff lines 813-816 |
| Drain helpers REQUIRED for both Queue and BQueue | **PASS** | design §4.8 lines 1240-1254 (signatures spelled out), §5.7 line 3493-3498 (user-facing surface), §4.8 across all cardinality arms (lines 3520, 3528, 3560); handoff lines 824-833 |
| "Undrained at destroy = leak" prominent in docs/guide/memory-management.md | **PASS** | design §1.9 (1-line summary), §2.8 lines 1248-1250, §5.7.3 lines 3473-3479, §7.4 IA places `guide/memory-management.md` in the user nav; §7.6 row #2 cross-references all four sections |

### Refcount lifecycle

| Sub-decision | Status | Citation |
|---|---|---|
| Library inc paired with library dec WITHIN each library scope | **PASS** | design §2.4 (the Path C trace, source-of-truth, referenced from §3677, §4.2.3), §4.2.3 lines 2701-2702 ("`incRefSlot(mref)` above raised the count by one so this net is +1"), lines 2864-2865 ("matching dec under arc/orc/atomicArc/refc (net zero on item)"); handoff lines 587-624 (lifecycle trace table) |
| Consumer never inherits orphan library refcount obligation | **PASS** | design §2.4 trace + lines 2784-2785 ("sink expires to net out at +1 (the queue's reference). The Path C trace in Section 2.4 is the source of truth"); handoff line 622 ("Library never hands the consumer an orphan inc obligation") |
| Decref ONLY at queue-destroy-walk for abandoned non-empty queues | **PASS** | design §3.7 (nebr queue-destroy interaction), §4.7 unbounded-arm destructor walk, §4.7.4 mm:none non-walk row; handoff lines 638-665 ("only one place — the queue-destroy walk over live slots"). Pop and EBR-reclaim explicitly do NOT decref. |
| Pop's claim CAS MUST clear payload bits across ALL cardinality arms | **PASS** | design §4.7 pop-clears table at lines 3184-3193 ("ALL eight cardinality arms in lockfreequeues" — table enumerates each arm with status + T-INTEGRATE FIX), §5.4 §7.6 row #2-related risks, R2 row at line 5465 ("Pop-clears-payload latent bug across 8 cardinality arms ... T-INTEGRATE work item per arm; explicit verification test per arm"); handoff lines 731-755 |

### SMR (nebr)

| Sub-decision | Status | Citation |
|---|---|---|
| Module name `nebr` NOT `debra_plus` | **PASS** | design §1.3 lines 256-260 ("module is `nebr` (Neutralizable EBR), NOT `debra_plus`. The name `debra_plus` is reserved on disk"), §3.2.2 lines 1511-1527; handoff lines 989-1024 |
| Q-FAITHFUL deviations (D1, D2, D3, D4, D7) acknowledged honestly | **PASS** | design §3.2.1 D1–D9 deviation table at lines 1482-1500, §3.7 (D4 manual neutralization), §3.8 (D3 + D7 not implemented); safety-argument.md §1 explicit ("The paper proof (Brown 2015, §4) does not apply because nebr deviates from the paper in five semantic ways (D1, D2, D3, D4, D7)"); handoff lines 965-988 |
| nim-debra's README line 34 softened to "Inspired by" in T-INTEGRATE.d | **PASS** | design line 478 (T-INTEGRATE.d text-rewrite description), §7.6 R6 row at line 5469 ("T-INTEGRATE.d sweep fixes README line 34 + softens attribution to 'inspired by Brown 2015 (DEBRA)'"); handoff lines 1004-1006 |
| Safety argument is BOTH informal prose AND typestate-encoded for tractable properties | **PASS** | design §3 references `safety-argument.md`; safety-argument.md is the informal prose; design §3 + Section 3 cross-references nim-typestates FSMs (manager state machine, pin lifecycle, retire-bag state); handoff lines 1050-1083 |
| D3 (sigsetjmp recovery) + D7 (hazard pointers) DOCUMENTED AS KNOWN SCOPE — NOT recommended as deferral | **PASS** | design §3.8 lines 1961-2012 ("What nebr does NOT implement (D3, D7)") — documented as known omissions with rationale; NOT framed as "defer to v0.2.0" recommendation. Safety-argument §1.2 line "What nebr does NOT guarantee" lists in-operation recovery openly as a non-guarantee. |
| Q-DWCAS no-switch verdict reflected; DEBRA+ algorithm doesn't use DWCAS | **PASS** | design lines 3150-3153 ("Q-DWCAS verdict (referenced for completeness): the strict-LCRQ DWCAS-with-seq layout..."), §1 DWCAS substrate moves to `lockfree/atomics` (lines 269, 310, 463, 475), and is for strict-LCRQ queue only; handoff lines 943-963 |

### Iterator + async

| Sub-decision | Status | Citation |
|---|---|---|
| Tier 1 sync iterators IN v0.1.0 | **PASS** | design §5.5 (per ToC line 67), §5 iterator sigs lines 4081-4093 (`iterator drain*[T; ccProd: static PinScopeCardinality, ST; S, MaxThreads]...`), line 4069 ("Tier 1 is the only iterator tier shipping in v0.1.0") |
| Tier 2 raw notify primitive DROPPED | **PASS** | design line 147 (`Tier 1 (threads/locks) and Tier 2 (custom) adapters | NO (out of scope)`), line 4069 ("Tier 2 dropped"), line 4117 ("Tier 2 dropped per handoff §'Q6'"), line 4664 (`Tier 2 is explicitly dropped`), §7.6 row line 5577 ("Tier 2 raw notify primitive | NO"); handoff lines 919-925 |
| Tier 3 chronos adapter IN v0.1.0 | **PASS** | design §5.6 (chronos adapter), §6.10 CI cell 12 (chronos cell), line 4117 ("chronos adapter is the only async tier shipping in v0.1.0") |
| chronos optional dep with hybrid pattern | **PASS** | design line 386 + line 4122 + line 4294 — the exact `when defined(lockfreeChronos) or (compiles do: import chronos):` pattern from handoff §"CRITICAL #4"; §5.6 table at lines 4312-4326 enumerates all four operator cases (A/B/C/D from handoff lines 853-878) |
| NO hard error in else branch (silent module-empty) | **PASS** | design §5.6.5/6 lines 4524-4534 ("Without chronos installed AND without -d:lockfreeChronos: ... (lockfree/chronos.nim's body is gated...)") — silent empty body, no `{.error.}` in the default-no branch |
| Helpful error only when `-d:lockfreeChronos` set but chronos missing | **PASS** | design lines 390-393 — exact error message text, gated only when `-d:lockfreeChronos` is set without chronos; §5.6.6 line 4336-4340 OQ5.5 documents the exact wording |
| chronos NOT listed as hard requirement in lockfree.nimble | **PASS** | design lines 354-355 ("chronos is NOT a hard requirement"), §5.6 lines 4326 ("The library does not transitively pull in chronos") |

### Nimony

| Sub-decision | Status | Citation |
|---|---|---|
| First-class IN ARCHITECTURE (real `when defined(nimony):` arms, not stubs) | **PASS** | design §4.2.1 nimony aufbruch row at line 2664 (real `arcInc(memLoc)` / `arcDec(memLoc)` impl, with shim address-computation logic), §6.7 line 4922-4928 ("Real `when defined(nimony):` arms in atomics shim, smr / nebr, ManagedRef / ManagedSlice. NOT hand-waved. NOT stubbed. NOT `{.error: "not yet ported".}`"); handoff lines 902-920 |
| continue-on-error IN CI ONLY (PR-flow ergonomics) | **PASS** | design §6.7 line 4922 + line 4774 (CI cell 14 nimony with `continue-on-error: true`), line 4802 ("continue-on-error: true because nimony is pre-release"); handoff lines 906-914 |
| Target `aufbruch` mode | **PASS** | design line 824, 906, 1279, 1345, 2548, 2664, 2684, 3450, 3765, 4774 (CI cell 14 aufbruch mode), 4802, 4922 — pervasive `aufbruch` references |
| Partial port acceptable; doc the gap in `docs/guide/nimony.md` | **PASS** | design §4.2.1 nimony rows note "If ... cannot be verified at the time of v0.1.0 ship, nimony's `ref T` arm is marked `notyet` per Section 6" (line 2664); §7.4 IA places `guide/nimony.md` in user nav (line 5237-ish); §7.6 R4 row line 5467 ("partial-port acceptance per CRITICAL #5 disposition") |
| Nimony status badge + weekly verification policy | **PASS** | design §6.7 lines 4922-4976 ("Watch: dedicated nimony status badge in README; AGENTS.md says 'verify nimony cell weekly; treat sustained red as v0.2 blocker'"); line 5132 ("dedicated status badge, AGENTS.md watch policy") |

### CI matrix

| Sub-decision | Status | Citation |
|---|---|---|
| Comprehensive coverage with smart consolidation (NOT full union; NOT trim) | **PASS** | design §6.3 lines 4699-4707 ("Comprehensive: every MM lane ... must be exercised" + "Smart consolidation: do not run every MM × every OS") |
| All MM lanes (orc, arc, refc, atomicArc, none) at least once | **PASS** | design §6.3 line 4701 explicit enumeration, §6.3.1 row C1-C6 lines 4731-4736 (MM coverage matrix) |
| All OS targets (Linux x86_64, Linux arm64, macOS arm64) at least once | **PASS** | design §6.3 line 4701 explicit enumeration; cell table lines 4772+ has rows for ubuntu-latest, ubuntu-24.04-arm, macos-latest |
| TSAN + ASAN via env-flag on shared jobs, NOT duplicate jobs | **PASS** | design §6.3 line 4706 ("Sanitizers are env-flag toggles on the baseline lane, not duplicated cells"), §6.3.1 rows C11/C12 at lines 4741-4742 |
| Valgrind + Helgrind on Linux x86_64 | **PASS** | design §6.6 (toc line 78), §6.3.1 rows C13/C14 at lines 4743-4744 ("Valgrind memcheck on baseline lane" / "Helgrind race detection on baseline lane") |
| Nim devel cell + nimony cell (continue-on-error) | **PASS** | design §6.3.1 C15 line 4745 (Nim devel `continue-on-error: true`) + C16 line 4746 (Nimony `continue-on-error: true`) |
| chronos CI cell | **PASS** | design §6.3.1 C17 line 4747, cell-12 row at line 4772 |
| 20-min wall-clock target with baseline-measurement requirement | **PASS** | design §6.4 (per toc line 76), line 4713-4717 ("Operator's target: ≤ 20 minutes end-to-end on the GitHub Actions free tier ... this target is NOT confirmed feasible until a baseline measurement is taken") |
| NO autonomous scope cuts to hit 20-min target | **PASS** | design §6.4 line 4715 ("Per operator standing rule 'no autonomous scope cuts' ... Phase 2 design cannot autonomously cut coverage to fit a 20-minute budget"), line 4819 ("we do NOT silently drop Helgrind or the macOS cell to hit 20") |

### Publication path (CRITICAL #5)

| Sub-decision | Status | Citation |
|---|---|---|
| Phase 2 design EXCLUDES rename event / branch cleanup / tag deletion / archive repo creation / nimble registry / docs URL switchover | **PASS** | design §7.7 lines 5501-5525 ("Per Phase 1.6 CRITICAL #5 disposition: the v0.1.0 design doc does NOT specify ..." — enumerates exact exclusions matching handoff line 859-868), §1.2 line 161 ("Publication path (per CRITICAL #5 deferral)"), §6.9.4 line 5034 ("Post-rename validation (deferred per CRITICAL #5)") |
| Phase 2 design INCLUDES only code/CI-affecting structure | **PASS** | design §7.7 lines 5515-5525 lists exactly the four included items (CI release job structure, bot configuration, nimble package metadata, AGENTS.md propagation) matching handoff lines 870-876 |

### Standing rules / anti-rules

| Sub-decision | Status | Citation |
|---|---|---|
| NO autonomous scope cuts; no contingency-cut-order list anywhere | **PASS** | design §6.4 line 4715, line 4819, §7.6 row #3 at line 5604 ("§7.6 explicitly records the operator standing rule (`feedback_no_autonomous_scope_cuts`) and refuses to ship a cut-order list; cuts surface via AskUserQuestion at the point of blocker"), line 5484 ("scope cuts** (memory: feedback_no_autonomous_scope_cuts)") |
| Operator handles PR #31, PR #30 closure; not on develop's task list | **PASS** | NOT in design's task list (no §7 task reference to PR #31 or PR #30); design §7.5 task list (lines 5533+) starts from T0 and goes T-INTEGRATE.a-f. Handoff lines 310-318 list these as operator-handled. |
| Bot config: gemini-code-assist + axiomantic-momus | **PASS** | design §6.11 lines 5063-5080 (primary gemini-code-assist, parallel axiomantic-momus informational unless gemini unavailable — matches memory `feedback_momus_dance_after_iteration`); §6.11.3 lines 5073-5078 explicitly overrides the user-global styleseatbot default via AGENTS.md |

### Anti-rules (verifying NONE appear)

| Anti-rule | Status | Evidence |
|---|---|---|
| No "scope cut order" or "if we hit a wall" contingency planning | **PASS** | grep `scope cut` → 4 hits, ALL in the form "no autonomous scope cuts" / "refuses to ship a cut-order list" / "we do NOT silently drop". No contingency-cut-order table exists. |
| No "defer to v0.2.0 if X" RECOMMENDATIONS | **PASS** | Deferred items (D3, D7, publication path, future SMR strategies) are documented as known scope/non-guarantees, not as autonomous recommendations. R-rows §7.6 frame nimony partial-port as "acceptance per CRITICAL #5 disposition" (operator-directed), not as a recommendation. |
| No reference to "DEBRA+" as the v0.1.0 module name | **PASS** | All 15 "DEBRA+" hits are bibliographic (Brown 2015 DEBRA+), Q-FAITHFUL provenance, OR the explicit "renamed from 'DEBRA+' per Q-FAITHFUL" entry at line 137. All 20 `debra_plus` hits are reserved-name slot or future-work references — no v0.1.0 module call-site uses it. |
| No assumption that v5.0.0 of lockfreequeues was released | **DRIFT — 1 hit** | design line 3968: "The POD path is what v5.0.0 already ships." Contradicts handoff lines 324-336 ("no v5.0.0 will ever exist under the lockfreequeues package name ... lockfreequeues stays frozen"). See Drift Points below. All other v5.0.0 references in the design doc correctly frame it as "the lockfreequeues v5.0.0 source baseline that we are lifting" (lines 4679, 4691, 5247, etc.) — i.e., a git source state, NOT a shipped release. |
| No DWCAS-switch recommendation for DEBRA+ | **PASS** | design lines 3150-3153 explicitly record the Q-DWCAS no-switch verdict; §7.6 has no DWCAS-switch action item. |

## Cross-doc consistency

- **Design doc vs handoff Session updates**: Coherent. Every locked decision in handoff
  lines 11-1105 (Session updates) maps to a concrete section in the design doc with a
  cross-reference. Path C lifecycle trace (handoff lines 587-624) → design §2.4. mm:none
  contract (handoff lines 803-833) → design §2.8 + §4.2.1 + §4.8 + §5.7.3. nebr naming
  (handoff lines 1014-1029) → design §1.3 + §3.2.2. CRITICAL #5 deferral (handoff lines
  843-876) → design §7.7. nimony first-class + continue-on-error (handoff lines 902-920)
  → design §6.7.

- **Design doc vs understanding doc**: Coherent. The understanding doc captures the same
  decisions in a more compact form; design doc expands them with file:line cites and
  per-MM tables. No polarity inversions detected.

- **Design doc vs safety-argument.md**: Coherent. Safety-argument §1 names D1/D2/D3/D4/D7
  as the deviations that invalidate the paper proof; this matches design §3.2.1's D1–D9
  table verbatim. Safety-argument §1.1 invariants (S1, S2, S3) align with design §3
  section structure. Safety-argument explicitly cites `imports/nim-debra/src/debra/` with
  the note that T-INTEGRATE.b preserves line numbers via pure file-move — consistent
  with design lines 463-477 T-INTEGRATE.a-c.

## Drift Points

### DP1: "v5.0.0 already ships" phrasing at design line 3968 (MINOR)

**Design doc, line 3968 (in §5.1.4 Path C internal dispatch)**:

> The POD path is what v5.0.0 already ships. The ref and slice arms add the per-MM shim
> layer (§4.3 / §4.4) and are net-new in v0.1.0.

**Handoff, lines 324-336**:

> Handoff Q13 finding ("v5.0.0 NOT YET TAGGED") is no longer a "wait" signal; it's now
> permanent (no v5.0.0 will ever exist under the lockfreequeues package name). ...
> lockfreequeues stays frozen ...

**Analysis**: The handoff Session updates lock in that v5.0.0 of `lockfreequeues` will
never ship as a published release. The design doc's line 3968 phrasing "what v5.0.0
already ships" reads as if v5.0.0 had been released. Elsewhere in the design doc
(e.g., lines 4679, 4691, 5247) v5.0.0 is correctly framed as the **source baseline**
we are lifting (e.g., "v0.1.0 of the consolidated `lockfree` repo inherits ... lockfreequeues
v5.0.0 CI baseline"), which is correct — that source state exists on the `feat/v5.0.0-impl`
branch even though no v5.0.0 git tag will ever be cut on `lockfreequeues`.

**Severity**: MINOR. The intent of line 3968 is clearly "the POD path is what the
lockfreequeues v5.0.0 source baseline already implements" — a statement about source
state, not about a released artifact. But the literal phrasing "already ships" can be
read as asserting a released v5.0.0, which contradicts the handoff lock-in.

**Recommended fix**: change line 3968 from "what v5.0.0 already ships" to "what the
lockfreequeues v5.0.0 source baseline already implements" (or equivalent). One-line
edit, no structural impact.

## Recommendations for Phase 2.4 (or further fixes)

Only one suggested edit; see DP1 above:

- **Line 3968**: rephrase "what v5.0.0 already ships" → "what the lockfreequeues
  v5.0.0 source baseline already implements" (or equivalent phrasing that makes
  clear we're talking about source state, not a shipped release).

No structural changes required. The design doc is otherwise ready for Phase 2.5
(fact-checking).
