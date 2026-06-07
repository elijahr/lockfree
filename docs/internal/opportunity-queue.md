# Opportunity Queue

Cleanup / refactor candidates flagged during routine work. Each entry is a
note for a future pass, not a blocker for the current task.

## 2026-06-06

- **queue.nim:54,58 — nebr DuplicateModuleImport hint** (flagged Wave D).
  Harmless `DuplicateModuleImport` hint at queue.nim:54 and :58 (nebr import
  duplication). Worth deduping in a future cleanup pass. Pre-existing
  condition unrelated to PG-6 unified-encoding work.

- **withBoundEndpoint RAII close coverage gap** (flagged Phase 4.6 fix
  pass 2026-06-07). The Phase 4.6.3 green-mirage audit found that
  `t_typestate_dual_api.nim` didn't structurally verify `defer:
  endpoint.close()` fires at scope exit. The fix pass added re-bind
  contract tests, but mutation revealed BQueue same-thread RAII close
  is unobservable to single-thread unittest: BQueue's `close()` is a
  typestate-only no-op, and slot acquisition is keyed by
  `getThreadId()`, so same-thread re-bind reuses the slot regardless
  of close(). Queue's `close()` does real work (debra
  unregisterThread); that path is exercised by cross-thread tests +
  chronos suite, NOT by single-thread unittest. **Genuine mutation-killable
  RAII coverage requires a Queue unbounded MPMC multi-thread test.**
  Not a release blocker for v0.1.0 (the locked typestate API design IS
  sound; the gap is only in test coverage of one specific failure mode).
  PG-9 + chronos cross-thread tests cover the real Queue close path
  empirically; a dedicated single-thread mutation-killer test is the
  follow-up.

- **ref-T sink + unittest2 + arc closure-capture interaction** (flagged
  T-DRAIN-HELPERS 2026-06-06). Subagent found: ref-T direct push inside
  unittest2 `test`/`suite` body under `--mm:arc` corrupts the second push's
  bits (`@[1, 6]` instead of `@[1, 2]` for two consecutive ref-T pushes).
  Same code works outside unittest2. Same code works for the Wave C smoke
  ref-T cases (single-push-per-test pattern via Bound producer).
  **Hypothesis**: unittest2 wraps test bodies in a closure; sink-moved
  ref-T values may interact with the closure capture in a way that
  corrupts subsequent moves. Could be Nim 2.2.10 closure-capture bug,
  unittest2 macro expansion changing sink semantics, OR our wrap/wasMoved
  interacting poorly with the closure's lifted-environment refcount
  tracking.
  **Current coverage**: ref-T smoke uses single-push pattern; broader
  payload coverage via string/seq[int] (identical Path-C lowering). Not a
  release blocker for v0.1.0 if workaround pattern is documented.
  **To investigate**: minimal repro in standalone .nim file; bisect to
  determine root cause; either fix wrap implementation OR document a
  "don't use unittest2 with multi-push ref-T tests" caveat. PG-9
  T-TEST-COMPOSITION will surface broader cases.
