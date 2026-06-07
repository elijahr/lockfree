# Getting started

Your first five minutes with `lockfree`: install, write a bounded SPSC
program, write an unbounded MPMC program, learn when to reach for the
standalone reclaimer.

If you are coming from `lockfreequeues` or `nim-debra`, the package was
renamed in v0.1.0; see
[Migrations](../migrations/from-lockfreequeues-v5.md) and
[Migrations from nim-debra](../migrations/from-nim-debra.md) for the
import-path map.

## Install

```sh
nimble install lockfree
```

`lockfree` requires Nim `>= 2.2.0` and is published on the Nimble
registry under the package name `lockfree`. The runtime dependencies
are `typestates >= 0.10.0` and (transitively, until the SMR is fully
absorbed) `debra >= 0.8.0`.

Pin a version in your own `.nimble` file:

```text
# In yourproject.nimble
requires "lockfree == 0.1.0"
```

Use `>= 0.1.0` only if you are willing to ride minor-version changes;
the public API is stable across patches.

## Verify the install

```nim
# verify.nim
import options
import lockfree

var q = newSpscQueue[int, 16]()
discard q.push(42)
echo q.pop()  # prints "Some(42)"
```

Compile and run with threads on:

```sh
nim c --threads:on -r verify.nim
```

The queues require `--threads:on` even when only one thread touches
them, because the implementation references `Atomic[T]` and
`Thread[T]`. This is the default in Nim 2.2+; explicit `--threads:on`
is a no-op there but still safe to set.

## Your first bounded queue (SPSC)

The smallest useful program: one producer, one consumer, one bounded
queue.

```nim
import options
import os
import lockfree

# Capacity 16, item type int.
var queue = newSpscQueue[int, 16]()

proc producerFunc() {.thread.} =
  for i in 1 .. 8:
    while not queue.push(i):
      sleep(0)  # push returns false when full

proc consumerFunc() {.thread.} =
  var seen = 0
  while seen < 8:
    let item = queue.pop()
    if item.isSome:
      echo "got ", item.get
      inc seen
    else:
      sleep(0)

var threads: array[2, Thread[void]]
createThread(threads[0], producerFunc)
createThread(threads[1], consumerFunc)
joinThreads(threads)
```

Both `push` and `pop` are wait-free on this SPSC arm. The output is
deterministic: `got 1` through `got 8`.

See [Queues / bounded-vyukov](queues/bounded-vyukov.md) for the
multi-producer / multi-consumer variants.

## Your first unbounded queue (MPMC)

The unbounded MPMC arm uses the strict-LCRQ algorithm (Morrison & Afek
2013) with a DWCAS publish protocol and signal-driven epoch-based
reclamation for safe segment freeing. The user-facing code does not have
to know any of that — the queue handles its own reclaimer:

```nim
import options
import lockfree
import lockfree/endpoint
import lockfree/role_tags

# Unbounded MPMC: segment size 64, registry sized for 4 lifetime threads.
var queue = newUnboundedMpmcQueue[int, stEager, 64, 4]()

var producer = queue.getProducerHere()  # registers this thread
producer.push(42)

var consumer = queue.getConsumerHere()
let item = consumer.pop()  # some(42)
assert item == some(42)
```

The `*Here` templates are sugar for `getProducer()` + `bindToThread()`
when the caller is also the operating thread. For the
parent-obtains-then-hands-off-to-worker pattern, use the explicit
`getProducer()` + `bindToThread()` pair so registration lands on the
worker thread. See [Typestates](typestates.md) for the full lifecycle.

The `MaxThreads` parameter (the `4` above) counts the lifetime number
of distinct threads that will ever operate the queue, not the
concurrent count. Sizing matters: `nebr` has no per-thread unregister,
so each `bindToThread()` consumes a registry slot for the manager's
lifetime.

## When to reach for `nebr` directly

`nebr` is exposed as a standalone reclaimer for users building their
own lock-free data structures. If you are only using the queues, you
never need to import `nebr` directly — the unbounded multi-consumer
queues manage their own private manager.

Reach for `nebr` when you are writing a lock-free stack, hash table,
skiplist, or other reclaimable structure. See
[SMR / nebr](smr/nebr.md) for the manager lifecycle, the pin / unpin
protocol, and the retire / reclaim cadence.

```nim
# Standalone nebr (sketch — see smr/nebr.md for the full surface)
import lockfree/smr/nebr

var manager = newManager(maxThreads = 4)
manager.register()

# In your reclaimable critical section:
manager.pin()
let snapshot = atomicLoad(myAtomic)
# … use snapshot …
manager.unpin()

# When you retire a node:
manager.retire(node)

# Periodically (or at known safe points):
manager.reclaim()
```

## Common pitfalls

### "Item type is not lock-free safe"

Prior to v0.1.0, `lockfreequeues` rejected `ref T`, `string`, and
`seq[T]` payloads at compile time because slot copies could race with
refcount updates. v0.1.0 supports all three directly via the
[ManagedRef](managed-ref.md) and [ManagedSlice](managed-slice.md)
paths. The `-d:allowNonLockFreeQueueItems` flag is removed; if your
code set it, the compile-time guard is gone and the flag is now a
no-op (with a deprecation warning).

### Forgetting `--threads:on`

If you see `'Atomic' is not declared` or `'Thread' undeclared`, add
`--threads:on` to your compile flags or set `switch("threads", "on")`
in `config.nims`. The flag is the default under Nim 2.2+ but does not
hurt to set explicitly.

### Sizing `MaxThreads` too small

Each `bindToThread()` consumes a registry slot for the lifetime of the
manager. If you exhaust the registry, the call raises a
`DebraRegistrationError`. Size `MaxThreads` to the lifetime distinct
thread count, not the concurrent count.

## Next steps

- [Bounded vs unbounded](queues/index.md) — the cardinality chooser.
- [ManagedRef](managed-ref.md) / [ManagedSlice](managed-slice.md) — `ref T`,
  `string`, and `seq[T]` payloads.
- [Typestates](typestates.md) — the `Unbound → Bound → Closed` lifecycle and the
  `withBoundEndpoint` RAII wrapper.
- [SMR / nebr](smr/nebr.md) — the standalone reclaimer.
