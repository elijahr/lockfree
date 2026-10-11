# Channels & Synchronous Rendezvous

`lockfree` offers high-throughput, multi-producer multi-consumer (MPMC) channel
primitives designed to replace locks and manual condition variables in
concurrent workflows.

## 1. Ergonomic Channel Facade (`lockfree/channel`)

The `Channel[T]` facade provides Go-style CSP communication semantics built on
top of lock-free queue substrates.

### Features

- **Buffer Topologies**:
  - Bounded (`ckBounded`): Backed by `BQueue` with zero allocations in steady state.
  - Unbounded (`ckUnbounded`): Backed by `Queue` with dynamic segment allocation and Debra SMR.
- **Thread-Local Endpoint Caching**: Uses `{.threadvar.}` to automatically cache thread-registered producers and consumers. Callers do not need to manually pass or attach thread handles.
- **Progress Guarantees**: Non-blocking `trySend` / `tryRecv` operations are wait-free or lock-free; blocking `send` / `recv` use adaptive exponential backoff before sleeping.

### Basic Usage

```nim
import lockfree

# Create a bounded channel with capacity 64
var (tx, rx) = newChannel[int](capacity = 64)

# Producer thread
proc producer() {.thread.} =
  for i in 1..10:
    tx.send(i)
  tx.close()

# Consumer thread
proc consumer() {.thread.} =
  var item: int
  while rx.recv(item):
    echo "Received: ", item

var p, c: Thread[void]
createThread(p, producer)
createThread(c, consumer)
joinThreads(p, c)
```

---

## 2. Synchronous Rendezvous Channel (`lockfree/rendezvous`)

When producer and consumer threads must perform a synchronous, bilateral
handoff without any intermediate buffer, reach for `RendezvousChannel[T]`.

### Features

- **Strict Zero-Buffer**: Capacity is 0. Senders block until a receiver arrives, and receivers block until a sender delivers data.
- **Scherer & Scott Dual Queue**: Waiters enqueue atomic request nodes into an MPMC dual queue.
- **Kernel Futex Parking**: Waiting threads park using lightweight OS futexes (`ulock_wait` on macOS, `WaitOnAddress` on Windows, native `futex` on Linux), consuming 0% CPU cycles while idle.
- **Correlation IDs**: Generates monotonic 64-bit transaction tokens for request-reply tracing.

### Basic Usage

```nim
import lockfree

var rendezvous = newRendezvousChannel[string]()

# Thread 1 sends and blocks until received:
# rendezvous.send("payload")

# Thread 2 receives:
# let msg = rendezvous.recv()
```

---

## 3. Async Integration (`lockfreeChronos` & `async_bridge`)

For event-driven asynchronous runtimes, `lockfree` integrates with
[Chronos](https://github.com/status-im/nim-chronos) via `-d:lockfreeChronos`, and
provides non-blocking poll helpers via `lockfree/async_bridge`.

See the [Channel API Reference](../api/channel.md) and [Rendezvous API Reference](../api/rendezvous.md).
