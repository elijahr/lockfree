# lockfree

Lock-free concurrency primitives, data structures, and safe memory reclamation for Nim and C.

`lockfree` provides production-grade, non-blocking concurrent data structures
designed for maximum multicore scalability, deterministic latency, and zero
mutual-exclusion overhead. Every collection is engineered from first principles
using hardware atomics, adaptive backoff, and robust safe memory reclamation (SMR).

---

## The 10 Core Collections & Architecture

| Collection | Canonical Type | Underlying Algorithm | Concurrency Topology | Progress Guarantee |
| :--- | :--- | :--- | :--- | :--- |
| **Bounded Queue** | `BQueue[T, ...]` | Dmitry Vyukov Per-Slot Sequence Counters | SPSC, MPSC, SPMC, MPMC | SPSC: **Wait-Free**<br>MPMC: **Lock-Free** |
| **Unbounded Queue** | `Queue[T, ...]` | Morrison & Afek Strict-LCRQ with 128-bit DWCAS | SPSC, MPSC, SPMC, MPMC | SPSC: **Wait-Free**<br>MPMC: **Lock-Free** |
| **Concurrent Channel** | `Channel[T]` | Facade over `BQueue` / `Queue` with TLS Auto-Registration | MPMC (Multi-Producer Multi-Consumer) | **Lock-Free** |
| **Synchronous Rendezvous** | `RendezvousChannel[T]` | Scherer & Scott Synchronous Dual Queue with OS Futex | MPMC (Multi-Producer Multi-Consumer) | Match: **Lock-Free**<br>Wait: **Kernel Futex** |
| **Concurrent Map / Table** | `Ctrie[K, V]` | Aleksandar Prokopec Concurrent Hash Array Mapped Trie | MPMC (Multi-Producer Multi-Consumer) | Lookup: **Wait-Free**<br>Mutation: **Lock-Free**<br>Snapshot: **$O(1)$ Wait-Free** |
| **Sorted Map / Table** | `SkipListMap[K, V]` | Fraser & Herlihy SkipList with Harris Logical Marking | MPMC (Multi-Producer Multi-Consumer) | Lookup: **Wait-Free**<br>Mutation: **Lock-Free** |
| **Concurrent Set** | `SkipListSet[T]` | Fraser & Herlihy SkipList with Harris Logical Marking | MPMC (Multi-Producer Multi-Consumer) | Membership: **Wait-Free**<br>Mutation: **Lock-Free** |
| **Concurrent Stack** | `TreiberStack[T]` | Treiber Stack with Hendler Elimination-Backoff Array | MPMC (Multi-Producer Multi-Consumer) | **Lock-Free** (linear scaling under contention) |
| **Work-Stealing Deque** | `ChaseLevDeque[T]` | Chase-Lev Dynamic Circular Deque with C11 Fences | Single-Worker / Multi-Thief | Worker: **Lock-Free**<br>Thieves: **Lock-Free** |
| **Broadcast Ring / Pub-Sub** | `BroadcastRing[T]` | Lock-Free Multicast Ring with Dynamic Reader Cursors | SPMC / MPMC Fan-Out | Readers: **Wait-Free / Lock-Free**<br>Writers: **Lock-Free** |

### Additional Concurrency Primitives

- **Work-Stealing TaskPool (`TaskPool`)**: Multi-threaded scheduler coordinating per-worker `ChaseLevDeque` instances and global `TreiberStack` task injection.
- **Traffic Shaping (`RateLimiter`)**: Hardware 128-bit DWCAS `TokenBucket` and `LeakyBucket` (GCRA) rate limiters.
- **Byte Streaming (`StreamBuffer`)**: High-throughput circular byte stream ring buffer for packet framing and audio streams.
- **Safe Memory Reclamation (`nebr`)**: Neutralizable Epoch-Based Reclamation with `SIGUSR1` thread neutralization.
- **C Foreign Function Interface (`lockfree.h`, `libcabi`)**: C99-compliant interface exposing all primitives with zero-copy pointer transport and an exception firewall.

---

## Installation

Install via Nimble:

```sh
nimble install lockfree
```

Or add to your `.nimble` package file:

```nim
requires "lockfree >= 0.1.0"
```

---

## Compatibility

| Dimension | Supported Matrix |
| :--- | :--- |
| **Nim Compiler** | `>= 2.2.10` |
| **Memory Managers** | `orc` (default), `arc`, `atomicArc`, `none` (`refc` retired) |
| **Backends** | C, C++ |
| **Threading** | `--threads:on` required (default in Nim 2.2+) |
| **Platforms (CI-verified)** | Linux x86_64, Linux arm64, macOS arm64, Windows |
| **Sanitizers (CI-verified)** | ThreadSanitizer (TSan under `atomicArc`), AddressSanitizer (ASan) |
| **C ABI** | C99 / C++11 header `include/lockfree.h`, shared & static libraries |
| **License** | MIT |

---

## Quick Start

### 1. Bounded & Unbounded Queues

```nim
import lockfree

# Fixed-capacity wait-free SPSC ring buffer (zero allocation)
var boundedQ = newSpscQueue[int, 64]()
discard boundedQ.push(42)
assert boundedQ.pop() == some(42)

# Dynamic unbounded MPMC queue backed by Debra SMR
var unboundedQ = newMpmcQueue[string, 64, 4]()
var prod = unboundedQ.getProducerHere()
var cons = unboundedQ.getConsumerHere()

prod.push("hello lockfree")
assert cons.pop() == some("hello lockfree")
```

### 2. CSP Channels

```nim
import lockfree

var (tx, rx) = newChannel[int](capacity = 32)

# Thread-local auto-registration caches handles automatically
tx.send(1337)
var received: int
if rx.recv(received):
  echo "Received: ", received
```

### 3. Concurrent Map (`Ctrie`) with $O(1)$ Snapshots

```nim
import lockfree

var map = newCtrie[string, int]()

discard map.put("counter", 1)
discard map.putIfAbsent("users", 100)

# Atomic transformation
discard map.atomicUpdate("counter", proc(v: int): int = v + 1)

# O(1) wait-free point-in-time snapshot
let snap = map.snapshot()
for (k, v) in snap.pairs():
  echo k, " = ", v
```

### 4. Work-Stealing TaskPool

```nim
import lockfree

var pool = newTaskPool(numThreads = 4)

for i in 1..10:
  pool.spawn(proc() =
    # Executed concurrently across worker deques
    discard
  )

pool.sync()
pool.shutdown()
```

### 5. C ABI (`include/lockfree.h`)

Any C or C++ application can include `lockfree.h` and link against `liblockfree`:

```c
#include "lockfree.h"
#include <stdio.h>
#include <assert.h>

int main(void) {
    lfq_queue_t* q = NULL;
    lfq_status_t rc = lfq_bounded_create(1024, sizeof(void*), &q);
    assert(rc == LFQ_OK);

    int val = 999;
    rc = lfq_bounded_push(q, &val);
    assert(rc == LFQ_OK);

    void* popped = NULL;
    rc = lfq_bounded_pop(q, &popped);
    assert(rc == LFQ_OK && *(int*)popped == 999);

    lfq_bounded_destroy(q);
    return 0;
}
```

---

## Detailed Guides & Documentation

- [User Guide](guide/user_guide.md) — Exhaustive guide mapping colloquial data structure names to `lockfree` types.
- [Queues Guide](guide/queues/index.md) — Deep dive into Vyukov bounded and strict-LCRQ unbounded queues.
- [Channels & Rendezvous](guide/channels.md) — Buffered CSP channels and synchronous zero-capacity handoffs.
- [Maps & Sets](guide/maps-sets.md) — Concurrent Hash Trie (Ctrie) and Fraser & Herlihy SkipLists.
- [Stacks & Deques](guide/stacks-deques.md) — Treiber stack with elimination backoff and Chase-Lev work-stealing.
- [Broadcast Ring](guide/broadcast.md) — Multicast ring buffers and topic-based pub-sub.
- [TaskPool](guide/taskpool.md) — Work-stealing scheduler and parallel loops.
- [C ABI](guide/cabi.md) — C99 Foreign Function Interface and library integration.
- [Safe Memory Reclamation (nebr)](guide/smr/nebr.md) — Epoch-based reclamation and thread neutralization.
- [Hardware Atomics](guide/atomics.md) — Memory orderings, 128-bit DWCAS, and adaptive backoff loops.
- [API Reference](api/index.md) — Complete module and symbol reference.
- [Migration Guide](migration.md) — Migration paths from `lockfreequeues` and `nim-debra`.
