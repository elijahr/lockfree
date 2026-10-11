# Channel

`lockfree/channel` provides an ergonomic CSP-style channel facade over
bounded (`BQueue`) and unbounded (`Queue`) lock-free FIFO queues, featuring
automatic thread-local registration.

## Overview

- **Channel types**: Bounded (`ckBounded`) with fixed capacity, or Unbounded (`ckUnbounded`).
- **Endpoints**: `Sender[T]` and `Receiver[T]`.
- **Operations**: Non-blocking `trySend`/`tryRecv`, blocking `send`/`recv` with adaptive backoff.
- **Thread Safety**: Multi-Producer Multi-Consumer (MPMC) safe. Automatic thread-local storage (`{.threadvar.}`) caching.

## Example

```nim
import lockfree

var (tx, rx) = newChannel[int](capacity = 64)

# Push item
discard tx.trySend(42)

# Pop item
let val = rx.tryRecv()
assert val.isSome and val.get() == 42
```

::: lockfree/channel
