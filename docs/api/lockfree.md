# lockfree (umbrella)

The top-level `lockfree` module re-exports the umbrella's public API:
the bounded and unbounded queues, the SMR (`nebr`) facilities, the
typestates facade, and the managed payload types (`ManagedRef`,
`ManagedSlice`, `Chronos`).

In nearly all cases, downstream code only needs `import lockfree` —
the submodule paths below are documented for callers that prefer a
narrower import surface (for example, pulling just `lockfree/atomics`
without the queues).

## See also

- [BQueue](bqueue.md) — bounded queue.
- [Queue](queue.md) — unbounded queue.
- [ManagedRef](managed_ref.md), [ManagedSlice](managed_slice.md),
  [Chronos](chronos.md) — managed payload types.
- [SMR / nebr](smr/nebr.md) — epoch-based safe memory reclamation.
- [Typestates facade](typestates.md) — slot / segment / endpoint state
  machines used by the queue bodies.

::: lockfree
