# Legacy cardinalities — unbounded SPSC / SPMC / MPSC

The unbounded MPMC arm uses [strict-LCRQ](strict-lcrq-mpmc.md). The
other three unbounded arms — SPSC, SPMC, and MPSC — use a simpler
**committed-flag** segment-chain protocol. This page documents that
protocol and the per-arm tradeoffs.

The name "legacy" is descriptive, not deprecating: these arms are not
going away. They are simpler because they do not need the strict-LCRQ
progress rule, and they ship in v0.1.0 unchanged.

## Two publication protocols

`lockfree` deliberately ships two publication protocols across its
unbounded arms:

| Arm | Publication | Why |
|---|---|---|
| Unbounded SPSC | Single store + segment-bound counter | One producer, one consumer; no contention to resolve. |
| Unbounded SPMC | Committed flag per slot | Multiple consumers race on `tryClaim`; producer publishes a committed bit. |
| Unbounded MPSC | Committed flag per slot | Multiple producers race on `tryReserve`; producer publishes a committed bit. |
| Unbounded MPMC | Strict-LCRQ (DWCAS) | Multiple producers AND consumers; strict-LCRQ progress rule needed. |

Both protocols are correct. The committed-flag form is two-store; the
DWCAS form is one-store but requires double-word CAS support. The
choice is per-arm and per-paper-citation, not per-user.

## Unbounded SPSC

```nim
import lockfree
import lockfree/endpoint

var q = newUnboundedSpscQueue[int, stEager, 64, 1]()
# Note: SPSC needs no nebr — the consumer is the only freer.
```

SPSC is special-cased: there is no `nebr.Manager` because there is
only one consumer, and the consumer is the only thread that advances
the segment chain. Retired segments are freed inline by the consumer.

```nim
var producer = q.getProducerHere()
producer.push(42)

var consumer = q.getConsumerHere()
let v = consumer.pop()
```

`MaxThreads` for SPSC is conventionally `1` (because there is no
nebr); the slot is unused.

## Unbounded SPMC

```nim
import lockfree
import lockfree/endpoint

var q = newUnboundedSpmcQueue[int, stEager, 64, 4]()
```

One producer side; up to four consumer endpoints. Each consumer
endpoint binds to its operating thread once. The internal
`nebr.Manager` is sized for 4 lifetime threads (`MaxThreads = 4`).

```nim
var producer = q.getProducerHere()
producer.push(42)

# On each consumer thread:
var consumer = q.getConsumerHere()
let v = consumer.pop()
```

Cardinality-protocol detail: SPMC consumers contend on segment
advance (when the active segment drains). The committed-flag form's
single-store publish + double-load consume is sufficient because
producers do not contend.

## Unbounded MPSC

```nim
import lockfree
import lockfree/endpoint

var q = newUnboundedMpscQueue[int, stEager, 64, 4]()
```

Up to four producer endpoints; one consumer side. Each producer
endpoint binds to its operating thread once.

```nim
# On each producer thread:
var producer = q.getProducerHere()
producer.push(42)

# On the single consumer thread (use bindConsumer for the one-shot bind):
var consumer = q.getConsumerHere()
let v = consumer.pop()
```

Cardinality-protocol detail: MPSC producers race on `tryReserve` to
claim a slot. The committed-flag form's single-store publish is
sufficient because consumers do not contend.

## Choosing among the unbounded arms

If you are confident about the cardinality of each side at design
time, pick the matching arm directly. The SPSC arm in particular is
substantially cheaper than the multi-consumer arms because it
sidesteps `nebr` entirely.

If your cardinality varies (e.g. a configurable number of consumers),
default to the MPMC arm; the strict-LCRQ progress rule degrades
gracefully when one side ends up with only one endpoint.

## Cell layout consequence

The committed-flag arms publish via two atomic stores (payload, then
committed-bit). The strict-LCRQ arm publishes via one DWCAS. This
shows up in the per-slot cell layout:

| Arm | Cell layout |
|---|---|
| SPSC | `T` payload + per-segment head/tail counters |
| SPMC, MPSC | `T` payload + per-slot `Atomic[bool]` committed flag |
| MPMC (strict-LCRQ) | `Atomic[Pair[uint, T]]` — DWCAS publish + close-bit sentinel |

For most payload types, the difference is invisible at the user level.
For Path-C payloads (`ref T`, `string`, `seq[T]`) the slot is an 8-byte
encoded token regardless of arm, with the box pointer carrying the
heap-allocated payload.

## Further reading

- Maged M. Michael and Michael L. Scott, "Simple, Fast, and Practical
  Non-Blocking and Blocking Concurrent Queue Algorithms" (PODC 1996).
  The M&S queue is the conceptual basis of the segment-chain
  committed-flag form.
- [Strict-LCRQ MPMC](strict-lcrq-mpmc.md) — the MPMC arm.
- [`api/queue`](../../api/queue.md) — auto-generated symbol reference.
