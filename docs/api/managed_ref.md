# ManagedRef

`ManagedRef[T]` is a single-owner, move-tracked reference to a
heap-allocated `T`, owned by an underlying reclamation scheme.

Unlike `ref T` (GC-managed) or `ptr T` (raw, unmanaged), `ManagedRef`
carries an explicit ownership/lifetime contract that integrates with
the umbrella's SMR (`nebr`) and with the queue payload protocols.
Construction allocates; moves transfer ownership; destruction either
retires through the manager (when alive) or is a no-op (when moved
out / sunk).

## See also

- [ManagedSlice](managed_slice.md) — managed-payload analog for
  contiguous arrays.
- [Chronos](chronos.md) — managed temporal payload.
- [SMR / nebr](smr/nebr.md) — the reclamation backend used by the
  managed payload types.

::: lockfree/managed_ref
