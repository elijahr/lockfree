# ManagedSlice

`ManagedSlice[T]` is a single-owner, move-tracked, contiguous
allocation of `T` elements with an explicit length. It is the
managed-payload analog of `ManagedRef[T]` for arrays.

`ManagedSlice` is the recommended payload type when queueing
batched / array-shaped work that must outlive the producer's stack
frame and cannot be passed as `ptr T` because the consumer needs the
length too. Like `ManagedRef`, it integrates with the umbrella's
SMR (`nebr`) for deferred reclamation.

## See also

- [ManagedRef](managed_ref.md) — single-element managed payload.
- [Chronos](chronos.md) — managed temporal payload.
- [SMR / nebr](smr/nebr.md) — the reclamation backend.

::: lockfree/managed_slice
