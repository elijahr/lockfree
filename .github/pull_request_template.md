## Summary of Changes

<!-- Brief summary of what this PR does, why it is needed, and design decisions made. -->

## Motivation & Context

<!-- Closes #issue or describes the rationale. -->

## Queue & Concurrency Invariants

- [ ] Does this PR touch atomic memory orders, slot layouts, or typestates?
- [ ] If yes, have ABA hazards, memory fences, and NEBR epoch safety been audited?
- [ ] Are all allocations cross-thread safe (`allocShared0`/`deallocShared`)?

## Verification & Testing

- [ ] `nimble test` passes (unit tests + negative compile-fail controls)
- [ ] `nimble channel` passes (channel facade suite)
- [ ] `nimble cabi` passes (C ABI FFI suite)
- [ ] `nimble testStress` passes (100k throughput sweeps)
- [ ] Sanitizers run cleanly (`nimble testTSan`, `nimble testASan` if applicable)

## Documentation & Compatibility

- [ ] Documentation updated in `docs/` or `README.md`
- [ ] Zero breaking changes to `compat/lockfreequeues` or `smr/nebr` (or migration notes provided in `CHANGELOG.md`)
