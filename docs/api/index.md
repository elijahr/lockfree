# API Reference

`lockfree` v0.1.0 exposes two unified, cardinality-parameterized queue types (`BQueue` and `Queue`). Each
covers all four producer/consumer combinations (SPSC, MPSC, SPMC, MPMC),
selected at compile time via the `ccProd` and `ccCons` parameters. For callers migrating
from `lockfreequeues` (v4.2.0 / v5.0.0), a full backwards-compatibility layer
is provided in `lockfree/compat/lockfreequeues` and `lockfreequeues.nim`.

## Bounded Queue

Fixed-capacity ring buffer. Capacity and thread-registry sizes are
compile-time constants; the bounded body owns no heap state and needs no
memory-reclamation manager.

- **[BQueue](bqueue.md)** — `BQueue[T, ccProd, ccCons, N, P, C]`. SPSC
  is wait-free; multi-producer / multi-consumer shapes are lock-free.
  Multi sides use the Vyukov per-slot `seq`-counter protocol.

## Unbounded Queue

Dynamic-capacity linked-segment buffer; grows as needed. The SPSC shape
frees retired segments inline (no manager); the MP/MC shapes use in-tree
nebr epoch-based memory reclamation (`lockfree/smr/nebr`), with attach-time
thread registration.

- **[Queue](queue.md)** — `Queue[T, ccProd, ccCons, ST, S, MaxThreads]`.
  SPSC is wait-free; multi-producer / multi-consumer shapes are
  lock-free.

## Support Types

- **DeallocationStrategy** — Memory reclamation policy (unbounded
  reclaiming shapes):
  - `stManual` — Retire segments to the `DebraManager`. The user calls
    reclamation periodically. Best for `--mm:none`.
  - `stEager` — Retire segments and reclaim eagerly. Best for GC
    environments.
- **PinScopeCardinality** — `ccSingle` / `ccMulti`, the values supplied
  for the `ccProd` / `ccCons` type parameters.

## Performance Guarantees

| Guarantee | Meaning |
|-----------|---------|
| Wait-free | Operation completes in bounded steps regardless of other threads |
| Lock-free | At least one thread makes progress; individual threads may retry |

## Segment Size Selection (Unbounded `Queue`)

| Use Case | Recommended Size | Rationale |
|----------|------------------|-----------|
| Small items, high throughput | 256-1024 | Amortize allocation overhead |
| Large items (>1KB) | 16-64 | Avoid memory bloat |
| Low latency | 64-128 | Smaller = faster reclamation |
| Batch processing | 512-2048 | Match batch sizes |

Segment size should be a power of 2 and ideally a multiple of cache line
size (64 bytes on most systems).

## Cache Line Considerations

### Bounded `BQueue`

The bounded queue uses cache line alignment for head/tail pointers to
prevent false sharing. Capacity should be chosen to avoid unnecessary
padding:

- **Good**: 16, 32, 64, 128, 256 (power of 2)
- **Avoid**: Arbitrary values that don't align well

### Unbounded `Queue`

Segment size affects memory layout. Larger segments mean fewer
allocations but slower reclamation. Consider:

- Each segment has fixed overhead (~64 bytes for metadata)
- Item count per segment = segment size parameter
- Total segment memory = (segment size × item size) + overhead
