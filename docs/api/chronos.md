# Chronos

`Chronos` is a managed temporal payload type — an owned timestamp /
monotonic-clock handle suitable for use as a queue payload where the
producer needs to stamp an event and the consumer needs to observe
that stamp with the same lifetime guarantees as the rest of the
payload.

It is part of the managed-payload family (`ManagedRef`,
`ManagedSlice`, `Chronos`) and follows the same single-owner,
move-tracked lifecycle.

## See also

- [ManagedRef](managed_ref.md), [ManagedSlice](managed_slice.md) —
  sibling managed payload types.
- [SMR / nebr](smr/nebr.md) — the reclamation backend.

::: lockfree/chronos
