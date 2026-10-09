# Concurrency Architecture & Formal Invariants: Async Bridge Substrate

**Document ID**: `DESIGN-LOCKFREE-ASYNC-BRIDGE-001`  
**Author**: Marcus Vance (`architect-horsetail`), Staff Systems Architect  
**Reviewers**: Caleb Thorne (`auditor-pegasus`), Elena Rostova (`implementer-kite`), Supreme Orchestrator (`orchestrator-whipbird`)  
**Status**: RATIFIED ARCHITECTURAL SPECIFICATION  
**Target Substrate**: `lockfree` (v0.1.0-consolidated)  
**Deliverable**: `docs/designs/design_async_bridge.md`  

---

## Concurrency Topology & Substrate Banner

```
====================================================================================================
Concurrency Topology: Multi-Runtime Async Bridge Substrate (Wave 3C)
====================================================================================================
| Dimension              | Architectural Specification                                             |
|:-----------------------|:------------------------------------------------------------------------|
| **Target Runtimes**    | Dual Support: `std/asyncdispatch` (stdlib) & `chronos` (4.x / 5.x)        |
| **Target Containers**  | `BQueue`, `Queue` (LCRQ), `RendezvousChannel`, `ChaseLevDeque`, `BroadcastRing`|
| **Notification Engine**| Polyglot `AsyncSignal` (Event loop wakeups: `AsyncEvent`, OS eventfd, pipe)|
| **Fast-Path Dispatch** | Speculative Non-Blocking Poll (Zero-allocation synchronous fast path)   |
| **Slow-Path Dispatch** | Lock-Free Waiter Registration with Bilateral Unparking & Future Resolution|
| **Memory Reclamation** | Debra SMR (NEBR) with Strict Epoch Pin Isolation Across `await` Boundary|
| **Payload Storage**    | Single-Owner Atomic Pointer Transfer (`VBox[T]`) under ARC/ORC          |
| **Cancellation Safety**| Bilateral CAS Arbitration: Zero Item Loss Guaranteed on Coroutine Abort |
| **Heterogeneous Match**| Seamless cross-execution: OS Worker Threads <--> Async Event Loops       |
| **Threadpool Handoff** | Work-Stealing Taskpool Dispatch with Async Stream Aggregation            |
| **Opt-In Flags**       | Flag-only opt-in: `-d:lockfreeAsyncdispatch` and `-d:lockfreeChronos`     |
| **C ABI Interop**      | Foreign thread signaling (`lockfree_async_signal_trigger`)               |
====================================================================================================
```

---

## 1. Executive Summary & Problem Formulation

### 1.1 The Asynchronous Impedance Mismatch
Concurrent systems architectures face a fundamental dichotomy between two execution models:

1. **Physical Multithreading with Lock-Free Algorithms**:
   - Heavyweight OS threads executing lock-free algorithms (e.g. Dmitry Vyukov's bounded MPMC queue, Morrison & Afek LCRQ, Chase-Lev work-stealing deques, Scherer-Scott synchronous dual channels).
   - Synchronization relies on hardware atomic primitives (`compareExchange`, `fetchAdd`), memory barriers (`moAcquire`, `moRelease`, `moSeqCst`), CPU backoff (`pause`, spinning), and OS-native futex parking (`WaitOnAddress`, `ulock_wait`, `SYS_futex`).
   - SMR (Safe Memory Reclamation) algorithms like Debra NEBR track active thread epochs through thread-local pin counters.

2. **Cooperative Asynchronous Event Loops**:
   - Lightweight green coroutines multiplexed over one or more event loop threads (Nim `std/asyncdispatch` or Status `chronos`).
   - Cooperative scheduling via non-blocking state machine transformation (`{.async.}` / `Future[T]`).
   - Blocking an event loop thread on a lock-free spin loop or an OS futex halts the entire reactor, starving all concurrent coroutines scheduled on that thread!

### 1.2 The Wave 3C Mandate
Wave 3C bridges this architectural gap. It provides a zero-overhead, memory-safe, lock-free async adapter layer that allows asynchronous coroutines in both `std/asyncdispatch` and `chronos` to interact directly with `lockfree` concurrent primitives without blocking the host event loop.

The bridge operates across all five foundational concurrent primitives:
- **Bounded Queues (`BQueue[T]`)**: Bounded FIFO queues with async backpressure (suspending producers on full queues, suspending consumers on empty queues).
- **Unbounded Queues (`Queue[T]`)**: Morrison & Afek LCRQ with non-blocking lock-free enqueue and asynchronous consumer awaiting.
- **Synchronous Dual Channels (`RendezvousChannel[T]`)**: CSP-style zero-buffer synchronous handoff where coroutines can rendezvous with other coroutines OR with physical OS threads.
- **Work-Stealing Deques (`ChaseLevDeque[T]`)**: Worker threads operating with high cache locality, while async thief coroutines steal work without polling.
- **Broadcast Rings (`BroadcastRing[T]` / `TopicBus[T]`)**: 1-to-N fan-out multicast streams where async subscribers await published messages with configurable drop or backpressure semantics.

---

## 2. Core Architectural Subsystems

### 2.1 The Polyglot `AsyncSignal` Abstraction
Different async runtimes employ incompatible notification primitives. `std/asyncdispatch` relies on `asyncdispatch.AsyncEvent` (backed by selector self-pipes or Windows event handles), whereas `chronos` employs `chronos.AsyncEvent` (backed by a high-performance user-space sticky atomic flag and event loop wakeups).

To avoid code duplication while maintaining zero abstraction overhead, Wave 3C introduces the internal `AsyncSignal` abstraction:

```nim
type
  AsyncSignalKind* = enum
    askAsyncDispatch,
    askChronos,
    askNativeEventFd,
    askNativePipe

  AsyncSignal* = object
    case kind*: AsyncSignalKind
    of askAsyncDispatch:
      when defined(lockfreeAsyncdispatch):
        dispEvent*: asyncdispatch.AsyncEvent
      else:
        dispPlaceholder*: pointer
    of askChronos:
      when defined(lockfreeChronos):
        chronosEvent*: chronos.AsyncEvent
      else:
        chronosPlaceholder*: pointer
    of askNativeEventFd:
      eventFd*: cint
    of askNativePipe:
      pipeFds*: array[2, cint]
```

#### Universal Signal Semantics
Every `AsyncSignal` variant MUST satisfy the following operational invariants:
1. **Thread-Safe Cross-Thread Fire (`fire()`)**: Can be invoked from any physical OS thread, worker thread, or interrupt handler without taking mutexes.
2. **Sticky Semantics**: If `fire()` is called before `wait()` is entered, the subsequent `wait()` completes immediately without suspending.
3. **Idempotence**: Multiple consecutive calls to `fire()` before a `clear()` collapse into a single wakeup.
4. **Zero Allocation on Wakeup**: Waking a waiting coroutine does not perform dynamic memory allocation.

---

### 2.2 Fast-Path Speculative Non-Blocking Execution
Under high throughput, contention is dynamic: data is frequently available immediately. Routing every queue pop or channel receive through the async scheduler introduces significant event-loop context-switching overhead and allocates unneeded `Future` state.

Wave 3C enforces the **Fast-Path Speculative Execution Rule**:

```
Coroutine calls asyncPop()
          |
          v
[Speculative Non-Blocking TryPop]
          |
     +----+----+
     |         |
  Success    Empty / Contended
     |         |
     v         v
Return       [Slow Path: Allocate Waiter]
Immediate    [Register on Lock-Free Waiter List]
Future(T)    [Double-Check TryPop]
             [await AsyncSignal.wait()]
```

#### Algorithmic Invariant: Immediate Future Short-Circuit
- If `tryPop()`, `tryRecv()`, or `trySteal()` succeeds on the first attempt, the adapter constructs an **immediately resolved Future**:
  - In `chronos`: `newFutureCompleted(val)` (zero suspension).
  - In `asyncdispatch`: `newFuture[T]()` with `fut.complete(val)` returned synchronously before yielding.
- No callback is registered with the reactor loop, and no event handle is primed. This achieves parity with synchronous lock-free throughput under loaded conditions.

---

### 2.3 Slow-Path Waiter Registration & The Double-Check Protocol

When the speculative fast path fails, the coroutine must suspend. However, coordinating a concurrent lock-free queue with an asynchronous event loop creates a notorious concurrency hazard: the **Lost-Wakeup Race Window**.

#### The Lost-Wakeup Race Condition
Consider a naive slow path:
1. Consumer checks queue: it is empty.
2. Producer pushes item to queue and checks if any async consumer is waiting.
3. Producer sees no registered waiter; producer continues.
4. Consumer registers its `AsyncSignal` and calls `await signal.wait()`.
5. **Deadlock**: The consumer waits forever even though an item is available in the queue!

#### The Double-Check Protocol
To eliminate this race without introducing heavyweight locks, Wave 3C establishes the **Double-Check Protocol**:

```
Consumer (Async Event Loop)                Producer (Worker Thread)
---------------------------                ------------------------
1. Clear AsyncSignal flag
2. result = queue.tryPop()
   if result.isSome: return result
3. Register AsyncWaiter on WaiterList
   (Atomic CAS / release store)
4. RETRY: result = queue.tryPop()
   if result.isSome:
     Unregister AsyncWaiter
     return result
5. await signal.wait()
                                           A. queue.push(item)
                                           B. Check WaiterList
                                           C. If Waiter found:
                                              Remove Waiter
                                              signal.fire()
6. Loop to step 1 (Sticky Flag Handling)
```

**Formal Invariant**: The signal flag MUST be cleared *before* the final `tryPop()` check. If a producer executes between step 4 and step 5, `signal.fire()` sets the sticky flag, causing `await signal.wait()` to return immediately.

---

## 3. Safe Memory Reclamation (NEBR / Debra) Isolation Invariant

### 3.1 The Catastrophic Epoch Stall Problem
The `lockfree` repository utilizes Debra NEBR (Neutral Epoch-Based Reclamation, `src/lockfree/smr/nebr/`) for reclamation of retired queue and ctrie nodes. Under Debra:
- An active thread enters a **Pin Scope** (`pin()`), publishing its thread-local epoch.
- The global epoch cannot advance beyond the minimum epoch of any pinned thread.
- When all threads advance, retired memory buffers are safely reclaimed.

```
[ CRITICAL ARCHITECTURAL HAZARD: PINNING ACROSS ASYNC SUSPENSION ]

Thread 1 (Event Loop):
  pin()                       <--- Thread enters Pin Scope
  let node = deref(head)
  await event.wait()          <--- COROUTINE SUSPENDS! Event loop switches tasks!
  ... hours later ...
  unpin()

CONSEQUENCE:
While the coroutine is suspended awaiting an item, Thread 1 remains PINNED.
The global epoch CANNOT ADVANCE.
All concurrent producer threads retain ALL retired nodes in memory.
Result: OOM (Out Of Memory) crash and complete reclamation starvation!
```

### 3.2 The Strict Pin Scope Boundary Invariant
To guarantee that SMR never suffers from suspension-induced epoch stalls, Wave 3C enforces the **Strict Pin Scope Boundary Invariant**:

$$\forall c \in \text{Coroutines}, \quad \text{PinScope}(c) \cap \text{SuspensionPoints}(c) = \emptyset$$

**Rules of Enforcement**:
1. **Never `await` Inside a Pin Scope**: It is a fatal compilation error or architectural violation to execute `await` while holding a Debra/NEBR pin.
2. **Extract-Unpin-Yield Sequence**:
   - Enter Pin Scope (`pin()`).
   - Atomically dereference node and extract payload into a managed `VBox[T]` or local value.
   - Exit Pin Scope (`unpin()`).
   - Only AFTER the pin scope is fully closed may the coroutine yield, suspend, or await an `AsyncSignal`.
3. **Typestates Pragma Enforcement**:
   - All async adapter functions interacting with SMR must compile under `/Users/eek/.nimble/bin/typestates verify -W src/` with zero transitions active across async transform boundaries.

---

## 4. Container-Specific Architectural Adaptations

```
+-----------------------------------------------------------------------------------------------+
|                                    Wave 3C Container Adapters                                 |
+-----------------------------------------------------------------------------------------------+
| Container               | Adapter Type                 | Fast Path       | Suspension Trigger |
|:------------------------|:-----------------------------|:----------------|:-------------------|
| `BQueue[T]`             | `AsyncBQueue[T]`             | `tryPush`/`tryPop`| Empty/Full         |
| `Queue[T]` (LCRQ)       | `AsyncQueue[T]`              | `tryPop`        | Empty              |
| `RendezvousChannel[T]`  | `AsyncRendezvousChannel[T]`  | `trySend`/`tryRecv`| No Peer Present  |
| `ChaseLevDeque[T]`      | `AsyncChaseLevDeque[T]`      | `trySteal`      | Empty Deque        |
| `BroadcastRing[T]`      | `AsyncBroadcastCursor[T]`    | `tryRecv`       | No New Sequence    |
+-----------------------------------------------------------------------------------------------+
```

### 4.1 Bounded Queue: `AsyncBQueue[T]`
Bounded queues require bi-directional synchronization:
1. **Consumer Suspension (Empty Queue)**: Consumers await when `head == tail`.
2. **Producer Backpressure (Full Queue)**: Producers await when `tail - head == capacity`.

#### Waiter Dual Ring Structure
`AsyncBQueue` maintains two waiter structures:
- `emptyWaiters`: Lock-free Treiber stack of waiting consumers.
- `fullWaiters`: Lock-free Treiber stack of waiting producers.

```nim
type
  AsyncBQueue*[T; ccProd, ccCons: static PinScopeCardinality; N, P, C: static int] = ref object
    queue*: BQueue[T, ccProd, ccCons, N, P, C]
    consumerSignal*: AsyncSignal
    producerSignal*: AsyncSignal
    hasWaitingConsumers*: Atomic[bool]
    hasWaitingProducers*: Atomic[bool]
```

- When a producer successfully pushes an item:
  - If `hasWaitingConsumers.load(moAcquire)` is true:
    - Atomically reset flag and invoke `consumerSignal.fire()`.
- When a consumer successfully pops an item:
  - If `hasWaitingProducers.load(moAcquire)` is true:
    - Atomically reset flag and invoke `producerSignal.fire()`.

---

### 4.2 Unbounded Queue: `AsyncQueue[T]` (Morrison & Afek LCRQ)
Unbounded queues never block producers because capacity expands dynamically via linked ring nodes. Therefore, `AsyncQueue[T]` only requires **Consumer Suspension**:
- Producers always execute synchronously via lock-free `enqueue()`.
- SPSC mode uses Debra-free direct pop with zero pin overhead.
- MPMC mode executes `tryPop()` inside an ephemeral pin scope, extracts `Option[T]`, closes pin scope, and suspends on `emptySignal` if `none()`.

---

### 4.3 Synchronous Zero-Buffer Channel: `AsyncRendezvousChannel[T]`
`RendezvousChannel[T]` (Wave 3B) provides CSP-style zero-buffer synchronous handoff. Senders and receivers must meet in real time.

In an asynchronous context, `AsyncRendezvousChannel[T]` enables **Heterogeneous Synchronization**:
- **Case 1: Async Coroutine <---> Async Coroutine**: Both parties suspend cooperatively on their respective event loops without blocking threads.
- **Case 2: Worker Thread <---> Async Coroutine**: A physical worker thread calls synchronous `send(m)` (parking on OS futex), while an async coroutine calls `await recv()`. The arrival of the coroutine matches the thread, transfers data, wakes the thread via futex, and completes the coroutine's `Future`!
- **Case 3: Async Coroutine <---> Worker Thread**: An async coroutine calls `await send(m)` (suspending on event loop), while a worker thread calls synchronous `recv()`. The thread completes the rendezvous, waking the coroutine via `AsyncSignal.fire()`.

#### Dual Waiter Node for Async Rendezvous
```nim
type
  AsyncWaiterKind = enum
    awkThreadSync,  ## Physical OS thread (uses Parker futex)
    awkAsyncDispatch,## std/asyncdispatch Future
    awkChronos      ## chronos Future

  AsyncRendezvousWaiter[T] = object
    mode*: RendezvousMode             ## rmSender or rmReceiver
    state*: Atomic[RendezvousState]   ## rsWaiting, rsMatched, rsCancelled
    correlationId*: uint64
    payload*: Atomic[ptr VBox[T]]
    kind*: AsyncWaiterKind
    parker*: Parker                   ## For awkThreadSync
    signal*: AsyncSignal              ## For awkAsyncDispatch / awkChronos
    next*: Atomic[ptr AsyncRendezvousWaiter[T]]
```

When an opposing party arrives:
1. It atomically claims the waiter node via `state.compareExchange(rsWaiting, rsMatched, moAcqRel)`.
2. It transfers the payload pointer.
3. Based on `kind`, it executes either `parker.unpark()` (for OS thread) or `signal.fire()` (for async coroutine).

---

### 4.4 Work-Stealing Deque: `AsyncChaseLevDeque[T]`
In task parallelism engines (such as `lockfree/taskpool.nim`), worker threads push and pop tasks locally from the bottom of their `ChaseLevDeque` in LIFO order.

`AsyncChaseLevDeque[T]` allows **Asynchronous Thief Coroutines** to steal tasks from the top in FIFO order:
- A worker thread runs pure CPU work synchronously.
- When an event-loop coroutine runs out of tasks, it executes `asyncSteal()`:
  1. Speculative fast path: calls `deque.steal()`.
  2. If an item is stolen, return immediately.
  3. If empty, registers an `AsyncSignal` with the deque's thief-waiter list.
  4. The worker thread, upon pushing new tasks to `bottom`, fires the thief signal if thieves are registered.

---

### 4.5 Broadcast Ring Buffer: `AsyncBroadcastRing[T]` & `AsyncTopicBus[T]`
`BroadcastRing[T]` (Wave 3A) delivers every message to all registered readers via independent sequence cursors.

`AsyncBroadcastCursor[T]` transforms a broadcast subscriber into an **Asynchronous Stream**:
```nim
type
  AsyncBroadcastCursor*[T] = ref object
    cursor*: BroadcastCursor[T]
    ring*: BroadcastRing[T]
    signal*: AsyncSignal
```

#### Consumer API:
```nim
proc recv*[T](self: AsyncBroadcastCursor[T]): Future[Option[T]] {.async.}
```
1. Reads next sequence slot from `BroadcastRing`.
2. If sequence has been published, extracts payload and advances cursor immediately.
3. If sequence is pending, registers `signal` with the ring's reader-notification list and calls `await signal.wait()`.
4. Publishers advancing the ring tail trigger reader signals via batch notification.

---

## 5. Cancellation Semantics & Zero Item Loss Invariant

### 5.1 The Asynchronous Cancellation Dilemma
In modern async programming, operations can be cancelled at any time due to:
- Timeouts (`withTimeout`, `sendWithTimeout`).
- Client disconnections.
- Structured concurrency cancellation scopes.

When a coroutine awaiting `await queue.pop()` is cancelled, a severe race condition occurs:
**What happens if the producer delivers an item at the exact microsecond the consumer is cancelled?**
- If the adapter ignores cancellation, the consumer leaks or drops the item.
- If the adapter accepts cancellation but the item was already dequeued, the item vanishes into the void!

### 5.2 Bilateral CAS Arbitration Protocol
To ensure the **Zero Item Loss Invariant**, Wave 3C specifies a formal 3-state bilateral CAS arbitration protocol for every async waiter node:

```
                  +--------------------+
                  |     wsPending      |
                  +---------+----------+
                            |
             +--------------+--------------+
             |                             |
      Producer Wins CAS             Canceller Wins CAS
(state -> wsMatched, moAcqRel)   (state -> wsCancelled, moAcqRel)
             |                             |
             v                             v
  +--------------------+        +--------------------+
  |     wsMatched      |        |    wsCancelled     |
  +--------------------+        +--------------------+
  - Item custody handed off.    - Item NOT touched.
  - Operation CANNOT cancel.    - Waiter unlinked from list.
  - Must deliver to Future.     - CancelledError propagates.
```

#### Protocol State Machine Rules:
1. **Producer Action**:
   ```nim
   if waiter.state.compareExchange(wsPending, wsMatched, moAcqRel):
     # Producer won arbitration.
     waiter.payload.store(itemBox, moRelease)
     waiter.signal.fire()
   else:
     # Waiter was cancelled! Producer retains custody of item
     # and offers it to the next available waiter or leaves it in queue.
   ```
2. **Canceller Action**:
   ```nim
   if waiter.state.compareExchange(wsPending, wsCancelled, moAcqRel):
     # Cancellation won arbitration.
     # Waiter safely removed. No item was dequeued.
     raise newException(CancelledError, "Async operation cancelled")
   else:
     # PRODUCER ALREADY MATCHED! Cancellation was preempted.
     # The item has been transferred. The coroutine MUST NOT drop it!
     # The Future completes with the item; cancellation is deferred or ignored.
   ```

**Architectural Guarantee**: Under no interleaving of execution can an item be removed from a container without being delivered to a valid consumer.

---

## 6. Threadpool Dispatch & Worker Thread Integration

### 6.1 Bi-Directional Offloading Architecture
Wave 3C provides tight integration between async event loops and `lockfree/taskpool.nim`:

```
[ Async Event Loop Thread ]
             |
             | dispatchToThreadpool(proc() = ...)
             v
+-------------------------------------------------------------+
| Taskpool (Worker Threads 1 .. N)                            |
| - Chase-Lev work-stealing task queues                       |
| - High-throughput CPU-bound processing                      |
+-------------------------------------------------------------+
             |
             | Results pushed to AsyncQueue[T] / AsyncSignal
             v
[ Async Event Loop Thread wakes and processes Future result ]
```

### 6.2 Async Taskpool Future Bridge
```nim
proc spawnAsync*[T](pool: Taskpool, task: proc(): T {.gcsafe.}): Future[T] =
  ## Offloads a blocking CPU-bound computation to the lockfree taskpool
  ## and returns a Future[T] that completes on the caller's event loop
  ## upon task completion without spinning.
```
- The caller allocates a promise/future and attaches an `AsyncSignal`.
- The task is scheduled on the worker threadpool.
- Upon completion, the worker thread places the result in the shared box and executes `signal.fire()`.
- The event loop resumes the calling coroutine with the computed result.

---

## 7. C ABI & Foreign Thread Interoperability

To allow foreign C threads (e.g. audio processing threads, network kernel drivers, embedded C libraries) to push data into Nim async queues and wake Nim event loops, Wave 3C exports C ABI bindings:

### Header Specification: `include/lockfree_async_bridge.h`
```c
#ifndef LOCKFREE_ASYNC_BRIDGE_H
#define LOCKFREE_ASYNC_BRIDGE_H

#include <stdint.h>
#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef void* lfq_async_queue_t;
typedef void* lfq_async_signal_t;

// Push an item from a foreign C thread into an async queue and trigger the event loop
int lfq_async_queue_push(lfq_async_queue_t queue, const void* item, size_t size);

// Manually fire an async signal from a foreign thread
void lfq_async_signal_fire(lfq_async_signal_t signal);

#ifdef __cplusplus
}
#endif

#endif // LOCKFREE_ASYNC_BRIDGE_H
```

Foreign threads write items with release semantics and fire the `AsyncSignal` using thread-safe system calls (`eventfd_write` on Linux, `write` on POSIX self-pipe, or `SetEvent` on Windows).

---

## 8. Compilation Flags & Modular Structure

### 8.1 Opt-In Activation Matrix
Following the established design pattern in `src/lockfree/chronos.nim`, the async bridge is strictly **flag-only opt-in**:

| Compiler Flag | Backend Activated | Dependencies Required |
|:---|:---|:---|
| `-d:lockfreeChronos` | `lockfree/chronos.nim` | `chronos >= 4.0.0, < 5.0.0` |
| `-d:lockfreeAsyncdispatch` | `lockfree/asyncdispatch_bridge.nim` | Standard library `std/asyncdispatch` |
| None | None (Sync Only) | Zero additional dependencies |

### 8.2 Diagnostic Install Hints
If a user compiles with `-d:lockfreeChronos` without having `chronos` installed, the compiler emits a fail-fast diagnostic error:
```nim
when defined(lockfreeChronos) and not chronosReachable:
  {.error: "lockfree/chronos: -d:lockfreeChronos was set but chronos is not installed. Run `nimble install chronos`.".}
```

Similarly, if `-d:lockfreeAsyncdispatch` is specified on a backend incompatible with threads, a compile-time assertion fails immediately:
```nim
when defined(lockfreeAsyncdispatch) and not compileOption("threads"):
  {.error: "lockfree/asyncdispatch requires --threads:on for cross-thread lock-free coordination.".}
```

---

## 9. Formal Memory Ordering & Synchronization Proofs

### 9.1 Memory Ordering Invariant Table

| Operation | Atomic Target | Order | Formal Justification |
|:---|:---|:---|:---|
| `waiter.state` CAS | `Atomic[RendezvousState]` | `moAcqRel` | Synchronizes matching party with cancelling or waiting party; guarantees payload visibility. |
| `payload` store | `Atomic[ptr VBox[T]]` | `moRelease` | Establishes happens-before relationship between payload write and waiter unparking. |
| `payload` load | `Atomic[ptr VBox[T]]` | `moAcquire` | Guarantees consumer observes initialized memory of payload box after match. |
| `hasWaitingConsumers` store | `Atomic[bool]` | `moRelease` | Ensures queue state updates are visible to consumer before notification is sent. |
| `hasWaitingConsumers` load | `Atomic[bool]` | `moAcquire` | Ensures producer observes registered waiters without stale cache effects. |
| Sticky flag load/store | `AsyncEvent` | `moSeqCst` | Precludes instruction reordering across the double-check lost-wakeup window. |

### 9.2 Linearization Points
1. **Successful Fast-Path Pop**: Linearizes at the underlying container's atomic pop linearization point (e.g. CAS on queue head).
2. **Successful Fast-Path Push**: Linearizes at the underlying container's atomic push linearization point.
3. **Slow-Path Consumer Match**: Linearizes at the CAS transition of `waiter.state` from `wsPending` to `wsMatched`.
4. **Slow-Path Cancellation**: Linearizes at the CAS transition of `waiter.state` from `wsPending` to `wsCancelled`.

---

## 10. Verification & Test Matrix

Wave 3C requires full test coverage across both runtimes and multi-threaded stress harnesses:

1. **Unit Acceptance Tests**:
   - `tests/t_async_bqueue.nim`: SPSC, MPSC, SPMC, MPMC push/pop with `asyncdispatch`.
   - `tests/t_async_queue.nim`: Unbounded LCRQ async push/pop.
   - `tests/t_async_rendezvous.nim`: Bilateral coroutine-to-coroutine and thread-to-coroutine matching.
   - `tests/t_async_broadcast.nim`: Multicast pub-sub cursor streams with async awaiting.
2. **Adversarial Cancellation Suite**:
   - Rapid timeout cancellation (`withTimeout(pop(), 1.nanosecond)`).
   - High-concurrency cancellation races: 16 producers, 16 consumers rapidly cancelling `Future`s.
   - Assert zero item loss: sum of all produced items MUST equal sum of consumed items.
3. **TSan & Memory Leak Audit**:
   - Run under `--mm:orc` and `--mm:arc` with ThreadSanitizer enabled (`--passC:-fsanitize=thread --passL:-fsanitize=thread`).
   - Confirm zero race conditions in `AsyncSignal` wakeups and zero memory leaks under cancelled futures.
