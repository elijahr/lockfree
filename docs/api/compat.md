# Legacy Compatibility Layer (`compat/lockfreequeues`)

`lockfree/compat/lockfreequeues` provides a zero-breakage drop-in replacement
for code written against `lockfreequeues` v4.2.0 and `nim-debra`.

Legacy applications can either:
- Update import paths from `import lockfreequeues` to `import lockfree/compat/lockfreequeues`
- Retain `import lockfreequeues` (which resolves via the top-level compatibility shim `src/lockfreequeues.nim`)

## Bounded Legacy Types

Historical type aliases retain capacity and thread configuration parameters first, with payload type `T` last:

| Legacy Type | Parameters | Underlying Substrate | Description |
|---|---|---|---|
| `Sipsic[N, T]` | Capacity `N`, Type `T` | `BQueue[T, ccSingle, ccSingle, N, 0, 0]` | Bounded Single-Producer Single-Consumer |
| `Mupsic[N, P, T]` | Capacity `N`, Producers `P`, Type `T` | `BQueue[T, ccMulti, ccSingle, N, P, 0]` | Bounded Multi-Producer Single-Consumer |
| `Sipmuc[N, C, T]` | Capacity `N`, Consumers `C`, Type `T` | `BQueue[T, ccSingle, ccMulti, N, 0, C]` | Bounded Single-Producer Multi-Consumer |
| `Mupmuc[N, P, C, T]` | Capacity `N`, Producers `P`, Consumers `C`, Type `T` | `BQueue[T, ccMulti, ccMulti, N, P, C]` | Bounded Multi-Producer Multi-Consumer |

### Bounded Constructors

- `newSipsicQueue[T, N]() -> Sipsic[N, T]`
- `newMupsicQueue[T, N, P]() -> Mupsic[N, P, T]`
- `newSipmucQueue[T, N, C]() -> Sipmuc[N, C, T]`
- `newMupmucQueue[T, N, P, C]() -> Mupmuc[N, P, C, T]`

## Unbounded Legacy Types

Unbounded type aliases retain historical parameter orders and default deallocation strategies:

| Legacy Type | Parameters | Underlying Substrate | Description |
|---|---|---|---|
| `UnboundedSipsic[T, ST, S]` | Type `T`, Strategy `ST`, Segment Size `S` | `Queue[T, ccSingle, ccSingle, ST, S, 1]` | Unbounded SPSC (inline segment free) |
| `UnboundedMupsic[T, ST, S, MaxThreads]` | Type `T`, Strategy `ST`, Segment Size `S`, Threads `MaxThreads` | `Queue[T, ccMulti, ccSingle, ST, S, MaxThreads]` | Unbounded MPSC (committed flags + SMR) |
| `UnboundedSipmuc[T, ST, S, MaxThreads]` | Type `T`, Strategy `ST`, Segment Size `S`, Threads `MaxThreads` | `Queue[T, ccSingle, ccMulti, ST, S, MaxThreads]` | Unbounded SPMC (committed flags + SMR) |
| `UnboundedMupmuc[T, ST, S, MaxThreads]` | Type `T`, Strategy `ST`, Segment Size `S`, Threads `MaxThreads` | `Queue[T, ccMulti, ccMulti, ST, S, MaxThreads]` | Unbounded MPMC (strict-LCRQ + SMR) |

### Unbounded Constructors

- `newUnboundedSipsicQueue[T, S]() -> UnboundedSipsic[T, stEager, S]`
- `newUnboundedMupsicQueue[T, S, MaxThreads](manager = nil) -> UnboundedMupsic[T, stEager, S, MaxThreads]`
- `newUnboundedSipmucQueue[T, S, MaxThreads](manager = nil) -> UnboundedSipmuc[T, stEager, S, MaxThreads]`
- `newUnboundedMupmucQueue[T, S, MaxThreads](manager = nil) -> UnboundedMupmuc[T, stEager, S, MaxThreads]`

## Implicit Handle Registration

In `lockfreequeues` v4.2.0, calling `getProducer` or `getConsumer` allowed immediate push/pop operations without manual thread-affinity binding. The compatibility shim preserves this behavior: `getProducer` and `getConsumer` automatically register and attach the calling thread if it is not already registered with the underlying queue or SMR manager.

## SMR Compatibility (`debra`)

The module re-exports `DebraManager` and `ThreadHandle` from `lockfree/smr/nebr`. Code using `import debra` resolves transparently via `src/debra.nim`.
