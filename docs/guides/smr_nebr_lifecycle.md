# NEBR Safe Memory Reclamation Lifecycle Guide

This guide provides a comprehensive architectural and operational reference for **NEBR (Neutralization-Enhanced Bounded Reclamation)** in `lockfree`. It covers epoch mechanics, deterministic thread registration, RAII epoch scoping (`withEpoch` / `pinScope`), real-time thread isolation, and strict memory leak avoidance contracts.

---

## 1. Executive Summary & Core Motivation

In lock-free concurrent data structures, traditional memory management cannot rely on mutual exclusion locks. When a node or segment is unlinked from a shared concurrent collection, reader threads may still hold references to that memory address and continue dereferencing its fields. Freeing memory immediately upon unlinking leads to classic **Use-After-Free (UAF)**, data corruption, and **ABA vulnerabilities**.

`lockfree` solves this problem using **NEBR**, an in-tree epoch-based memory reclaimer inspired by Trevor Brown's **DEBRA+ (PODC 2015)** algorithm. NEBR guarantees:
1. **Zero Garbage Collection Pauses**: Memory reclamation is deterministic, lock-free, and does not require runtime stop-the-world GC tracing.
2. **Signal-Driven Neutralization**: Solves the fundamental flaw of traditional Epoch-Based Reclamation (EBR) — where a single descheduled, stalled, or sleeping thread halts reclamation for the entire system, leading to unbounded memory accumulation.
3. **Formal Typestate Enforcement**: State transitions for threads (`Unregistered -> Registered -> Unpinned -> Pinned -> Retired -> Reclaimed`) are statically and dynamically verified to prevent double-free, use-after-free, and re-entrant pinning corruptions.

---

## 2. Theoretical Foundations: Epochs & Neutralization

### The Three-Epoch Sliding Window

NEBR maintains a monotonically increasing 64-bit global epoch counter (`manager.globalEpoch`). Time is logically divided into discrete epochs. Each registered thread records its observation of the global epoch in a dedicated cache-aligned thread slot.

```
       Global Epoch (E)
              │
  ┌───────────┼───────────┐
  ▼           ▼           ▼
Epoch E-2   Epoch E-1   Epoch E (Current)
 [RECLAIM]   [PENDING]   [ALLOC & RETIRE]
```

1. **Active Critical Section (Pinned)**: When a thread accesses lock-free shared structures, it *pins* itself to the current global epoch $e$.
2. **Retirement**: When a thread unlinks an object from a lock-free structure at epoch $e$, it does not free the memory. Instead, it places the pointer and its associated destructor into its thread-local **limbo bag** tagged with epoch $e$.
3. **Reclamation Invariant**: An object retired at epoch $e$ can only be safely deallocated when **all active threads have observed epoch $e+1$ or are unpinned**. At that point, no thread in the system can possibly hold a pointer to the retired object.

### The Stalled-Thread Pathology & NEBR Neutralization

In standard EBR, if thread $T_1$ enters a critical section at epoch $e$ and subsequently stalls (e.g. preempted by the OS scheduler, page fault, or blocking system call), the global safe epoch cannot advance past $e$. Limbo bags across all other threads grow without bound, resulting in severe memory leaks.

NEBR eliminates this failure mode via **signal-driven neutralization**:
- When other threads notice that the global epoch is stuck because a specific thread $T_{stalled}$ has remained pinned for multiple epoch cycles (`epochsBeforeNeutralize >= 2`), they invoke `neutralizeStalled(manager)`.
- The manager sends a POSIX signal (`SIGUSR1`) to $T_{stalled}$.
- The installed NEBR signal handler intercepts the signal and atomically marks the thread's slot as `neutralized = true` and `pinned = false`.
- The rest of the cluster proceeds with epoch advancement and memory reclamation without stalling.
- When $T_{stalled}$ wakes up, its exit guard acknowledges the neutralization event and cleans up its state safely.

---

## 3. Thread Registration Lifecycle

Every thread that participates in epoch-protected data operations must register with the `DebraManager`.

```
                  ┌──────────────────────┐
                  │     Unregistered     │
                  └──────────┬───────────┘
                             │ manager.registerThread()
                             ▼
                  ┌──────────────────────┐
                  │      Registered      │
                  │   (Allocated Slot)   │
                  └──────────┬───────────┘
                             │
            ┌────────────────┴────────────────┐
            ▼                                 ▼
   ┌─────────────────┐               ┌─────────────────┐
   │    Unpinned     │◄──────────────┤     Pinned      │
   │   (Quiescent)   │  pinScope /   │ (Active Read/   │
   └────────┬────────┘   withEpoch   │  Write Section) │
            │                        └─────────────────┘
            │ manager.unregisterThread()
            │ [Preconditions: unpinned + empty limbo]
            ▼
   ┌─────────────────┐
   │  Slot Released  │
   │  (Clean for     │
   │   Next Thread)  │
   └─────────────────┘
```

### Initializing the Manager

A `DebraManager` is parameterized by two compile-time constants:
- `MaxThreads: static int`: The maximum number of concurrent registered threads.
- `CC: static PinScopeCardinality`: Consumer cardinality (`ccSingle` or `ccMulti`).

```nim
import lockfree/smr/nebr

# Manager sized for up to 16 concurrent threads
var manager = initDebraManager[16]()
setGlobalManager(addr manager)
```

> [!TIP]
> Size `MaxThreads` for the **peak concurrent registered threads**, not lifetime total threads, provided departing threads unregister cleanly.

### Registering an Operating Thread

Registration is **thread-affine**: it must be executed on the thread that will perform the concurrent operations.

```nim
var handle = manager.registerThread()
```

If all `MaxThreads` slots are occupied, `registerThread` raises `DebraRegistrationError`.

### Unregistering a Thread: Preconditions & Slot Recycling

When a worker thread finishes or terminates, it must return its slot to the pool via `unregisterThread`:

```nim
manager.unregisterThread(handle)
```

`unregisterThread` enforces two non-negotiable memory-safety preconditions via `doAssert`:
1. **Thread Must Be Unpinned**: The calling thread must have exited all critical sections (`not slot.pinned`). Unregistering from within a critical section is a fatal programming error.
2. **Thread Must Have Drained Its Limbo Bags**: The thread must repeatedly call `reclaimNow(handle)` until it returns `0` (and `slot.currentBag == nil and slot.limboBagTail == nil`).

#### Why Draining Limbo Bags is Mandatory
Slots in `DebraManager` are pre-allocated and reused in place. When a slot is released, its index becomes immediately eligible for acquisition by a new thread. Because NEBR does not maintain a centralized, global orphan-bag adoption list, any lingering retired objects left in the slot's limbo bags would either:
- Leak permanently, or
- Be walked by the *new* thread under an unrelated epoch, triggering catastrophic **Use-After-Free** or **double-free** crashes.

---

## 4. RAII Scoping: `withEpoch` and `pinScope`

Manual `pin()` and `unpin()` calls are dangerous: exceptions, early returns, or unexpected breaks can leave a slot permanently pinned, halting global memory reclamation.

`lockfree` provides two RAII mechanisms that leverage Nim's `=destroy` hooks to guarantee safe epoch exit under all control flow paths.

### 1. `withEpoch` (Recommended Block-Form RAII)

`withEpoch` automatically pins the thread to the current epoch upon block entry and guarantees unpinning upon block exit:

```nim
import lockfree/smr/nebr

# Read-only critical section:
withEpoch(handle):
  let head = sharedQueue.head.load(moAcquire)
  if head != nil:
    processData(head.payload)
# Thread is guaranteed unpinned here, even if processData raised an exception
```

To retire objects inside the critical section, pass a binding variable name:

```nim
proc freeNode(p: pointer) {.nimcall.} =
  dealloc(p)

withEpoch(handle, slot):
  let oldNode = atomicSwap(sharedNode, newNode)
  if oldNode != nil:
    slot.retire(oldNode, freeNode)
```

### 2. `pinScope` (Explicit Typestate RAII Guard)

For scenarios requiring fine-grained control or lifetime passing across procs:

```nim
block:
  var scope = pinScope(unpinned(handle))
  var ready = retireReady(scope.state)
  ready.retire(oldPointer, freeNode)
  # scope `=destroy` automatically unpins and acknowledges any signals
```

### The Non-Reentrancy Invariant

> [!CAUTION]
> **Nested Pinning is Strictly Prohibited.**  
> Attempting to call `withEpoch` or `pinScope` while the thread is already pinned on the same handle will fail a `doAssert` even in release builds (`pinScope: thread already pinned (re-entrant pin?)`). Nested pinning corrupts the thread's epoch tracking and masks when the critical section actually terminates.

---

## 5. Real-Time vs Background GC Thread Isolation

A primary reason for using lock-free data structures in high-frequency trading, real-time audio DSP, and telecommunications is predictable latency without jitter. Deallocating memory (`free()` or `dealloc()`) is non-deterministic: it can trigger system memory manager locks, page unmapping, and kernel transition overhead.

NEBR enables complete decoupling of lock-free data exchange from memory deallocation latency.

```
       REAL-TIME THREADS                     BACKGROUND RECLAIMER
 ┌───────────────────────────┐            ┌─────────────────────────┐
 │ 1. withEpoch(handle, slot)│            │                         │
 │ 2. Read / Pop / CAS       │            │  Loop every 5-50ms:     │
 │ 3. slot.retire(ptr, dtor) │            │                         │
 │ 4. Exit withEpoch         │            │  1. manager.advance()   │
 └─────────────┬─────────────┘            │  2. reclaimNow(handle)  │
               │ Fast (O(1) pointer append│                         │
               │ into local limbo bag)    │  Deallocates retired    │
               ▼                          │  objects without        │
 ┌───────────────────────────┐            │  stalling real-time     │
 │ Thread-Local Limbo Bag    │            │  data pipelines.        │
 └───────────────────────────┘            └─────────────────────────┘
```

### Architectural Isolation Patterns

#### Pattern A: Real-Time Worker (Zero-Deallocation Latency)
Real-time worker threads only retire pointers into their local limbo bags using `retire(p, dtor)`. They **never** call `reclaimNow()` or `retireAndReclaim(..., eager = true)` in latency-critical loops:
- Retiring is an $O(1)$, zero-allocation operation (inserting into a pre-allocated segment or buffer).
- No kernel allocator locks are ever acquired on the hot execution path.

#### Pattern B: Dedicated Background Reclaimer Thread
A single background maintenance thread is assigned to periodically advance the global epoch and invoke reclamation passes:
- Sweeps quiescent threads.
- Frees accumulated limbo bags in bulk.
- Runs `neutralizeStalled()` if any thread has been preempted while holding an epoch pin.

#### Pattern C: Opportunistic Reclaimer (Standard Application Code)
For workloads where microsecond-level latency jitter is acceptable, use `retireAndReclaim`:

```nim
# Retires the node and opportunistically attempts to reclaim eligible objects:
retireAndReclaim(handle, nodePtr, freeNode, eager = true)
```

---

## 6. Memory Leak Avoidance & Operational Checklist

To guarantee bounded memory usage and prevent leaks in production services, follow these guidelines:

### Rule 1: Always Advance Epochs at Regular Cadence
If nobody advances `manager.globalEpoch`, no retired objects can ever become epoch-safe for reclamation.
- Use `handle.advanceEvery(N)` in hot worker loops (e.g. $N = 32$ or $N = 128$). This amortizes atomic stores so only every $N$-th iteration performs an atomic `fetchAdd` on the global epoch.
- Alternatively, have a background maintenance thread advance the epoch periodically (e.g. every 10ms).

### Rule 2: Keep Critical Sections Bounded & Ephemeral
Never execute blocking I/O, sleep operations, network calls, or long computations while holding a pin:
```nim
# ❌ ANTI-PATTERN: Blocking I/O inside withEpoch
withEpoch(handle):
  let data = queue.pop()
  socket.send(data) # STALLS ALL CLUSTER RECLAMATION!

# ✅ CORRECT: Extract payload, unpin immediately, then perform I/O
var data: Option[int]
withEpoch(handle):
  data = queue.pop()
if data.isSome:
  socket.send(data.get)
```

### Rule 3: Always Drain Limbo Bags Before Thread Termination
When tearing down dynamic worker threads:
```nim
# Teardown sequence for exiting worker:
while reclaimNow(handle) > 0:
  os.sleep(1) # Allow other threads to advance epochs
manager.unregisterThread(handle)
```

### Rule 4: Periodically Neutralize Stalled Threads
In multi-tenant or server environments where threads may be descheduled or suspended, execute `neutralizeStalled` periodically:
```nim
# Send SIGUSR1 to any thread that has remained pinned for >= 2 epoch cycles:
let signaled = manager.neutralizeStalled(epochsBeforeNeutralize = 2)
```

---

## 7. Complete End-to-End Implementation Examples

### Example 1: Custom Lock-Free Node Storage with `withEpoch`

```nim
import lockfree/smr/nebr
import lockfree/atomics

type
  Node = ptr object
    val: int
    next: Atomic[pointer]

proc freeNode(p: pointer) {.nimcall.} =
  dealloc(p)

var manager = initDebraManager[8]()
setGlobalManager(addr manager)

proc workerThread(handle: ThreadHandle[8, ccSingle], sharedHead: ptr Atomic[pointer]) =
  # Allocate and publish
  let newNode = cast[Node](alloc0(sizeof(int) + sizeof(Atomic[pointer])))
  newNode.val = 42

  # Critical section using withEpoch:
  withEpoch(handle, slot):
    let oldHead = cast[Node](sharedHead[].exchange(cast[pointer](newNode), moAcquireRelease))
    if oldHead != nil:
      # Retire old node: safe from concurrent readers
      slot.retire(cast[pointer](oldHead), freeNode)

  # Amortize epoch progression
  handle.advanceEvery(32)
```

### Example 2: Dedicated Background Reclaimer Pipeline

```nim
import std/[os, times]
import lockfree/smr/nebr

type ClusterState = object
  manager: DebraManager[16, ccSingle]
  running: Atomic[bool]

proc backgroundReclaimer(state: ptr ClusterState) {.thread.} =
  let handle = state.manager.registerThread()
  
  while state.running.load(moAcquire):
    # 1. Advance the global epoch
    state.manager.advance()
    
    # 2. Reclaim safe limbo bags for this thread
    discard reclaimNow(handle)
    
    # 3. Neutralize any threads stuck for > 2 epochs
    discard state.manager.neutralizeStalled(epochsBeforeNeutralize = 2)
    
    os.sleep(10) # 10ms reclaimer heartbeat
    
  # Clean drain on shutdown
  while reclaimNow(handle) > 0:
    discard
  state.manager.unregisterThread(handle)
```

---

## 8. Summary Table: SMR API Cheat Sheet

| API Function | Location | Operational Purpose | Latency Impact |
|:---|:---|:---|:---|
| `initDebraManager[N]()` | `smr/nebr` | Allocates and initializes manager with $N$ thread slots. | Setup time only |
| `registerThread(manager)` | `smr/nebr` | Binds current thread to an available slot; installs signal handler. | Fast (atomic bitmask search) |
| `unregisterThread(mgr, h)` | `smr/nebr` | Releases slot for reuse. Requires unpinned + empty limbo. | $O(1)$ verification |
| `withEpoch(h) do: ...` | `smr/nebr` | RAII epoch guard. Enters current epoch, auto-unpins on exit. | 1 atomic store + 1 atomic store |
| `withEpoch(h, slot) do:`| `smr/nebr` | RAII epoch guard with injected `RetireReady` binding. | 1 atomic store + 1 atomic store |
| `slot.retire(ptr, dtor)` | `smr/nebr` | Retires a pointer into thread-local limbo bag. | $O(1)$ non-blocking append |
| `reclaimNow(handle)` | `smr/nebr` | Checks safe epoch and frees eligible retired objects. | Dependent on limbo size |
| `retireAndReclaim(...)` | `smr/nebr` | Retires object and eagerly attempts reclamation. | Mixed (includes deallocation) |
| `advanceEvery(handle, N)`| `smr/nebr` | Increments local counter; advances global epoch every $N$ calls. | 1 non-atomic inc (mostly) |
| `neutralizeStalled(mgr)` | `smr/nebr` | Scans and sends `SIGUSR1` to threads stalling reclamation. | Scan overhead |
