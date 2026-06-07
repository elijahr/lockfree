# Bounded queue (Vyukov)

`BQueue[T, ccProd, ccCons, N, P, C]` is the bounded ring-buffer queue.
A single underlying algorithm — Dmitry Vyukov's per-slot sequence
counter — covers all four cardinalities. SPSC is wait-free on both
sides; SPMC and MPSC are wait-free on the single side and lock-free on
the multi side; MPMC is lock-free on both sides.

## The algorithm in 30 seconds

Each slot in the ring buffer carries an atomic *sequence counter*:

- A producer claims slot `i` only when the counter equals the
  producer's expected sequence for that slot.
- After writing the payload, the producer publishes by storing the
  next expected sequence into the counter.
- A consumer claims slot `i` only when the counter equals the
  consumer's expected sequence (one greater than the producer's
  initial expected sequence for that slot).
- After reading the payload, the consumer publishes by storing the
  next expected sequence (wrapping to the next loop's expected
  producer sequence).

The protocol is described in detail at
[1024cores.net/home/lock-free-algorithms/queues/bounded-mpmc-queue](https://www.1024cores.net/home/lock-free-algorithms/queues/bounded-mpmc-queue).

The single-cardinality variants degenerate naturally: SPSC needs only
two counters total (head and tail) and can short-circuit the
per-slot-counter dance.

## Construction

```nim
import options
import lockfree

# SPSC: capacity 16, no view counts needed.
var spsc = newSpscQueue[int, 16]()

# MPSC: capacity 16, 4 producer views, single consumer side.
var mpsc = newMpscQueue[int, 16, 4]()

# SPMC: capacity 16, single producer side, 4 consumer views.
var spmc = newSpmcQueue[int, 16, 4]()

# MPMC: capacity 16, 4 producer views, 4 consumer views.
var mpmc = newMpmcQueue[int, 16, 4, 4]()
```

The `P` and `C` parameters bound the number of distinct producer /
consumer endpoints, not the concurrent count. Each endpoint
`bindToThread()`s exactly once over its lifetime.

## Push / pop

For SPSC, push and pop are direct on the queue:

```nim
var q = newSpscQueue[int, 16]()
discard q.push(42)    # returns false if full
let v = q.pop()       # Option[int]
```

For multi-cardinality arms, push/pop go through endpoints:

```nim
import lockfree/endpoint

var q = newMpmcQueue[int, 16, 4, 4]()

var producer = q.getProducerHere()  # Unbound → Bound on this thread
producer.push(42)

var consumer = q.getConsumerHere()
let v = consumer.pop()  # Option[int]
```

See [Typestates](../typestates.md) for the `Unbound → Bound → Closed`
endpoint lifecycle and the `withBoundEndpoint` RAII wrapper.

## Capacity sizing

Vyukov bounded queues do **not** require power-of-two capacity. Any
positive `N` compiles and runs. The wrap arithmetic is modulo against
`N`, which the compiler can lower to a bitmask on power-of-two `N`.

For hot-path code, prefer powers of two; for everyday use, pick the
capacity that matches your domain (e.g. a 64-slot audio buffer, a
1024-slot job queue).

## Power-of-two not required

Unlike many lock-free ring buffers, `BQueue` accepts arbitrary
positive `N`. The library still recommends powers of two for hot
paths (the compiler can sometimes lower the modulo to a mask), but
the constraint is not enforced.

## Memory layout

Storage is inline: a `BQueue` value owns its `array[N, T]` slot
storage plus per-side head/tail counters. No heap allocation.

This means:

- A `BQueue` is **copyable** (field-wise copy is sound; copies do not
  alias the slot storage). For shared-queue patterns, pass by `var` or
  `ptr` — copying a queue you are concurrently pushing into produces
  two independent queues sharing no state.
- A `BQueue` has no destructor side effects beyond freeing its slot
  storage. Under `--mm:none`, the storage lives wherever you placed
  the queue value (stack, heap, global).

For payloads carrying destructors (`ref T`, `string`, `seq[T]`), see
[ManagedRef](../managed-ref.md) and [ManagedSlice](../managed-slice.md)
— the queue drives those destructors via Path C.

## Cardinality interactions with payload type

| Cardinality | Plain values | `ref T` | `string` / `seq[T]` |
|---|---|---|---|
| SPSC | All MMs incl. `--mm:none` | All except `--mm:none` | All except `--mm:none` |
| SPMC | All MMs incl. `--mm:none` | All except `--mm:none` | All except `--mm:none` |
| MPSC | All MMs incl. `--mm:none` | All except `--mm:none` | All except `--mm:none` |
| MPMC | All MMs incl. `--mm:none` | All except `--mm:none` | All except `--mm:none` |

The `--mm:none` row reflects strict bit transport: the queue refuses
to compile if your payload has a destructor under `--mm:none`. See
[Memory management](../concepts/memory-management.md#-mm-none) for
the audio ringbuffer pattern.

## Further reading

- [`api/bqueue`](../../api/bqueue.md) — auto-generated symbol reference.
- Dmitry Vyukov's lock-free queue writings on `1024cores.net`.
