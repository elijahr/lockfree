# `BQueue128` API Reference

Hardware 128-Bit Double-Word Compare-And-Swap (DWCAS) Bounded MPMC Queue.

```nim
import lockfree
```

## Type Definition

```nim
type
  BQueue128Slot*[T] = Atomic[Pair[uint64, T]]

  BQueue128*[T: uint64 | int64 | pointer | int, N: static int] = object
    head* {.align: CacheLineBytes.}: Atomic[uint64]
    tail* {.align: CacheLineBytes.}: Atomic[uint64]
    cells* {.align: CacheLineBytes.}: array[N, BQueue128Slot[T]]
```

### Static Constraints

- `N > 0` and `(N and (N - 1)) == 0` (Capacity must be a power of two).
- `sizeof(T) <= 8` (Payload must be 64 bits or smaller).
- `Pair[uint64, T]` is 16 bytes with 16-byte alignment.

---

## Constructors & Allocators

### `initBQueue128`

```nim
proc initBQueue128*[T: uint64 | int64 | pointer | int, N: static int](): BQueue128[T, N]
```

Initializes an inlined value object on the stack or embeds it in another struct.
All slots are pre-initialized with their initial turn sequences (`pos = index`).

---

### `allocAlignedBQueue128` / `freeAlignedBQueue128`

```nim
proc allocAlignedBQueue128*[T: uint64 | int64 | pointer | int, N: static int](): ptr BQueue128[T, N]
proc freeAlignedBQueue128*[T, N](q: ptr BQueue128[T, N])
```

Allocates a `BQueue128` instance on the shared heap with strict `CacheLineBytes` (64/128-byte) alignment, guaranteeing that neither `head`, `tail`, nor the inlined slot array suffer from cacheline false sharing or cross-boundary straddling.

---

## Operations

### `tryPush`

```nim
proc tryPush*[T, N](self: var BQueue128[T, N], val: T): bool
```

Attempts to enqueue `val` into the queue using a single hardware 128-bit CAS.

- **Returns**: `true` if enqueued successfully; `false` if the queue is full.
- **Progress**: Lock-free / Wait-free slot publication.

---

### `tryPop`

```nim
proc tryPop*[T, N](self: var BQueue128[T, N], outVal: var T): bool
```

Attempts to dequeue an item from the queue using a single hardware 128-bit CAS.

- **Returns**: `true` and stores the item into `outVal` if available; `false` if the queue is empty.
- **Progress**: Lock-free / Wait-free slot recycling.

---

### `pop`

```nim
proc pop*[T, N](self: var BQueue128[T, N]): Option[T]
```

Convenience wrapper around `tryPop` returning `Option[T]`.

---

### `tryPeek`

```nim
proc tryPeek*[T, N](self: BQueue128[T, N], outVal: var T): bool
```

Non-destructively reads the item at the front of the queue without dequeuing it.

- **Returns**: `true` if an item is ready; `false` if the queue is empty.

---

### `clear`

```nim
proc clear*[T, N](self: var BQueue128[T, N])
```

Drains all elements currently in the queue, advancing slot sequences to the next valid producer turns.

---

### Introspection

```nim
proc capacity*[T, N](self: BQueue128[T, N]): int {.inline.}
proc len*[T, N](self: BQueue128[T, N]): int {.inline.}
proc isEmpty*[T, N](self: BQueue128[T, N]): bool {.inline.}
proc isFull*[T, N](self: BQueue128[T, N]): bool {.inline.}
```

- `capacity`: Returns the compile-time capacity `N`.
- `len`: Returns the approximate instantaneous element count (`tail - head`).
- `isEmpty`: Returns `true` if `tail <= head`.
- `isFull`: Returns `true` if `tail - head >= N`.
