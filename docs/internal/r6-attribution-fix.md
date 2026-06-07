# R6 Attribution Fix — Brown 2017 → Brown 2015 DEBRA+

**Status**: RESOLVED (PG-D T-DOCS-RETHINK.c, 2026-06-06).
**Created by**: PG-3 T-INTEGRATE.d (umbrella v0.1.0 impl plan).
**Risk addressed**: R6 — incorrect attribution of the SMR algorithm to Brown 2017
("NBR") when it actually derives from Brown 2015 ("DEBRA+").

## Resolution (2026-06-06)

The corrected attribution and the cross-link to
`docs/internal/debra-plus-provenance.md` are now landed in
`docs/guide/smr/nebr.md` (see the "Attribution" section at the top
of that page and the inline link in the "Deviations from Brown 2015
DEBRA+" section). The migration guide
`docs/migrations/from-nim-debra.md` also includes a dedicated
"Attribution change" section pointing readers to the deviation
table.

This marker file is preserved (not deleted) as a historical record
of the R6 risk and the integrative work that resolved it. The
companion deferrals from T-INTEGRATE.d (README.md, docs/migration.md,
docs/index.md, etc.) below remain valid follow-ups for the
publication-path PR; PG-D's user-facing rewrites are now complete.

## Background

The upstream `nim-debra` README (`imports/nim-debra/README.md`, line 31)
claims:

> This implementation follows Brown 2017, including the SIGUSR1 protocol for
> neutralizing threads that have stalled inside a critical section.

This attribution is incorrect. The implementation is inspired by **Brown
2015 DEBRA+** (the "+" variant of DEBRA with signal-based neutralization),
not Brown 2017 NBR (Neutralization-Based Reclamation). See
`docs/internal/debra-plus-provenance.md` for the full bibliographic
discussion.

Brown 2017 NBR is a different algorithm with a related goal (signal-based
neutralization); confusing the two misrepresents the prior-art lineage.

## What needs to happen

1. **`imports/nim-debra/README.md`** is deleted by PG-4 T-INTEGRATE.f.
   No edit to that file is needed (it goes away).

2. **The new `docs/guide/smr/nebr.md`** (created by PG-D T-DOCS-RETHINK)
   MUST carry the corrected attribution:

   > Inspired by Brown 2015 DEBRA+ (Distributed Epoch-Based Reclamation,
   > "+" variant with signal-based neutralization for stalled threads).
   > Not to be confused with Brown 2017 NBR, which is a distinct algorithm.

3. **`docs/guide/smr/nebr.md`** MUST cross-link the provenance doc:

   > See `docs/internal/debra-plus-provenance.md` for the full
   > bibliographic discussion and the rationale for the corrected
   > attribution.

## Why this is a marker, not an edit

The target document (`docs/guide/smr/nebr.md`) does not yet exist. It
is the deliverable of PG-D (Docs phase) per the umbrella v0.1.0 impl
plan. Pre-creating it inside PG-3 would scope-creep across the PG
boundary and risk drift against PG-D's IA decisions.

## Acceptance for PG-D

When PG-D T-DOCS-RETHINK lands, this file becomes obsolete. PG-D MUST:

- Create `docs/guide/smr/nebr.md` with the corrected attribution
  (Brown 2015 DEBRA+, not Brown 2017 NBR).
- Cross-link `docs/internal/debra-plus-provenance.md` from that page.
- Delete this marker file (`docs/internal/r6-attribution-fix.md`).

## Companion deferrals from T-INTEGRATE.d

T-INTEGRATE.d swept the *mechanical* text references (source comments,
nimble metadata, examples, benchmark adapters, top-level test comments).
Public-facing documentation was DEFERRED to PG-D because the rewrites
require editorial judgement about v5.0.0 messaging:

- **`README.md`** — 7 `nim-debra`/`DEBRA+` references in current claims,
  dependency tables, and external URLs (`https://github.com/elijahr/nim-debra`).
  PG-D must decide whether to (a) remove the dependency claim (post-lift
  there is no nim-debra dep), (b) keep the URL as a "historical upstream"
  link, or (c) replace with a guide/smr/nebr.md link.
- **`docs/migration.md`** — 4 references. Migration guidance from v4.x
  needs current-state rewrite.
- **`docs/index.md`** — 3 references including dependency table and
  citation block.
- **`docs/guide/safety-model.md`, `docs/guide/memory-management.md`** —
  1 ref each, linking to the upstream repo.
- **`docs/api/index.md`, `docs/api/queue.md`** — 1 ref each.
- **`docs/contributing.md`** — 1 ref.
- **`docs/design/v5-port-candidates-from-v4.3.md`** — 3 refs (a design
  doc, possibly intentional).
- **`THIRD_PARTY_LICENSES.md`** — licensing record entry for nim-debra.
  Decision needed: does lockfreequeues continue citing the upstream
  license post-absorption? (Yes is probably correct — the lifted code
  carries its license.)

The internal design / plan / audit docs under `docs/internal/` were
intentionally preserved verbatim (they describe the merge plan and
its rationale; rewriting them would falsify the historical record).

`CHANGELOG.md` was also preserved verbatim for the same reason
(historical record).
