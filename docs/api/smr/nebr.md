# nebr (SMR)

`lockfree/smr/nebr` is the umbrella's safe-memory-reclamation backend.
It is the renamed-in-v0.1.0 successor to the upstream nim-debra
DEBRA+ implementation (Brown 2015, with the R6 attribution
correction tracked in the umbrella's working substrate).

`nebr` exposes the `NebrManager`, the per-thread handle, the
attach / detach lifecycle, and the retire / reclaim entry points used
by the umbrella's multi-producer / multi-consumer queue shapes and
by the managed-payload types.

## See also

- [SMR concept guide](../../guide/concepts/smr.md) — high-level
  motivation and lifecycle.
- [nebr user guide](../../guide/smr/nebr.md) — usage patterns and
  attach/detach examples.
- [Migration from nim-debra](../../migrations/from-nim-debra.md) —
  migration guide for upstream nim-debra users.

::: lockfree/smr/nebr
