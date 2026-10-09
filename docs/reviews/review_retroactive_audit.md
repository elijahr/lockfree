# Comprehensive Concurrency, Memory Safety, Dekker Reordering, and ARC Lifecycle Retroactive Audit Report: `BroadcastRing`, `TaskPool`, and `AsyncBridge`

**Author**: Caleb Thorne (`auditor-pegasus`), Verification & Adversarial Auditor  
**Date**: October 9, 2026  
**Target Substrate**: `lockfree` (v0.1.0-consolidated)  
**Target Components**: `src/lockfree/broadcast.nim`, `src/lockfree/taskpool.nim`, `src/lockfree/async_bridge.nim`  
**Deliverable**: `docs/reviews/review_retroactive_audit.md`  
**Auditor Verification Invariants**: Vyukov MPMQ Ring Invariants, Chase-Lev Work-Stealing Synchronization, Dekker Store-Load Memory Reordering, ARC/ORC Heap Safety, Advisory `rem-1` Compliance  

---

## 1. Executive Summary & Verdict

This retroactive adversarial audit provides a thorough code inspection of the core asynchronous, multi-cast, and worker pool infrastructure of `lockfree`: `BroadcastRing` / `TopicBus`, `TaskPool`, and `AsyncBridge`.

### Audit Verdict: CONDITIONAL RATIFICATION PENDING CRITICAL REMEDIATIONS
While the overarching architectures reflect advanced concurrent engineering principles, rigorous static analysis and memory model simulation have surfaced **one blocker defect (BLOCKER)**, **one critical use-after-free defect (CRITICAL)**, **two high-severity defects (HIGH)**, and **two medium-severity defects (MED)**. Immediate remediation is required by `implementer-kite` prior to production hardening.

| Finding ID | Severity | Component | Category | Summary |
|:---|:---|:---|:---|:---|
| **BLOCKER-03** | **BLOCKER** | `AsyncBridge` | Memory Ordering (rem-1) | Dekker Store-Load Reordering Causing Permanent Async Signal Lost-Wakeup |
| **CRITICAL-01** | **CRITICAL** | `BroadcastRing` | Memory Safety / UAF | Heap Corruption / Use-After-Free in `poll` Under `omDropOldest` Wrap-Around |
| **HIGH-01** | **HIGH** | `TopicBus` | Concurrency Bug | Split-Brain Ring Overwrite in `getOrCreateRing` via Unconditional `put` |
| **HIGH-02** | **HIGH** | `TaskPool` | ARC Lifetime / UAF | Closure Environment Use-After-Free in Detached `spawn(ClosureProc)` |
| **MED-01** | **MEDIUM** | `BroadcastRing` | Arithmetic Underflow | Unchecked Modular Subtraction in Sequence Distance Calculation |
| **MED-02** | **MEDIUM** | `TaskPool` | False Sharing | Lack of Cache-Line Isolation on Contended Worker Stealing Deques |

---

## 2. In-Depth Adversarial Analysis: `BroadcastRing` & `TopicBus` (`broadcast.nim`)

### 2.1 CRITICAL-01: Use-After-Free (UAF) in `poll` Under `omDropOldest`
In `src/lockfree/broadcast.nim` (lines 405-425):
```nim
# Reader thread polling a slot:
let vbox = slot.vbox.load(moAcquire)
if vbox != nil:
  incRef(vbox) # box.rc.fetchAdd(1, moRelaxed)
  ...
```
In `publish` (lines 280-310):
```nim
# Fast publisher wrapping around ring in omDropOldest mode:
let oldBox = slot.vbox.exchange(newBox, moAcqRel)
if oldBox != nil:
  decRef(oldBox) # If rc reaches 0: deallocShared(oldBox)
```

#### Detailed Execution Race Trace:
1. **Thread R (Reader)** executes `poll()`. It calculates the slot index and reads `vbox = slot.vbox.load(moAcquire)`. Pointer address `0x7fff1000` is loaded into a local register.
2. **Thread R is preempted** by the operating system kernel or hyperthread scheduler immediately before executing `incRef(vbox)`.
3. **Thread P (Fast Publisher)** enters `publish()` in `omDropOldest` mode. It publishes `Capacity` messages, wrapping around the entire ring buffer.
4. **Thread P overwrites the slot**:
   ```nim
   let oldBox = slot.vbox.exchange(newBox, moAcqRel)
   decRef(oldBox)
   ```
   `oldBox` has reference count 1 (held by the ring). `decRef` decrements `rc` to 0, which invokes `=destroy` and calls `deallocShared(oldBox)`. Address `0x7fff1000` is returned to the OS/heap allocator.
5. **Thread R resumes**:
   It executes `incRef(vbox)` (`box.rc.fetchAdd(1, moRelaxed)`) on the stale pointer `0x7fff1000`.
6. **Failure Mode**: **Use-After-Free (UAF) and Heap Metadata Corruption**. If `0x7fff1000` has been reallocated by another thread, `fetchAdd` silently corrupts arbitrary memory. If it has been unmapped, an instant `SIGSEGV` crash occurs.

#### Root Cause:
`BroadcastRing` relies on naive reference counting without an epoch-based Reclamation (Debra SMR) or Hazard Pointer scheme to safeguard slot payload pointers between the initial load and the reference count increment.

#### Remediation:
Protect slot reads using Debra SMR or maintain payload boxes in an epoch-quarantined ring where old boxes are only retired after the slowest reader epoch has advanced past the overwrite sequence.

---

### 2.2 HIGH-01: Split-Brain Ring Overwrite in `TopicBus.getOrCreateRing`
In `src/lockfree/broadcast.nim` (lines 502-514):
```nim
proc getOrCreateRing*[T](bus: TopicBus[T], topic: string): BroadcastRing[T] =
  let existing = bus.core.topics.get(topic)
  if existing.isSome:
    return existing.get
  let newRing = newBroadcastRing[T](bus.core.capacity, bus.core.overflowMode)
  let prev = bus.core.topics.put(topic, newRing) # <-- BUG: Unconditional put!
  return newRing
```

#### Adversarial Failure Analysis:
- `put` unconditionally overwrites an existing entry in the concurrent map.
- If two threads (Thread 1 and Thread 2) call `getOrCreateRing("market-data")` simultaneously for a new topic:
  1. Thread 1 creates `Ring_A`.
  2. Thread 2 creates `Ring_B`.
  3. Thread 1 calls `topics.put("market-data", Ring_A)`.
  4. Thread 2 calls `topics.put("market-data", Ring_B)`, overwriting `Ring_A`.
- Thread 1 returns `Ring_A` and publishes messages to it.
- Thread 2 returns `Ring_B` and attaches subscribers to it.
- **Result**: **Split-Brain Message Partitioning**. Subscribers attached to `Ring_B` will never receive any messages published to `Ring_A`. Messages are silently lost.

#### Remediation:
Replace `topics.put(topic, newRing)` with `putIfAbsent` or `computeIfAbsent`:
```nim
let (val, inserted) = bus.core.topics.putIfAbsent(topic, newRing)
if not inserted:
  # Another thread won the race; discard newRing and return existing
  return val
return newRing
```

---

## 3. In-Depth Adversarial Analysis: `TaskPool` (`taskpool.nim`)

### 3.1 HIGH-02: Closure Environment Use-After-Free in Detached `spawn(ClosureProc)`
In `src/lockfree/taskpool.nim` (lines 110-145 and 280-310):
```nim
type
  ClosureRepr = object
    fn: pointer
    env: pointer

proc newTask(fn: ClosureProc): Task =
  let cr = cast[ClosureRepr](fn)
  result = Task(
    kind: tkClosure,
    rawClosureFn: cr.fn,
    rawClosureEnv: cr.env,
    ...
  )

proc spawn*(pool: TaskPool, fn: ClosureProc) =
  let task = newTask(fn)
  pool.schedule(task)
  # Procedure exits immediately!
```

#### Execution Race Trace:
1. An application caller calls `pool.spawn(proc() = echo localCapturedVar)`.
2. Nim's ARC/ORC runtime allocates a closure environment on the heap for `localCapturedVar` and increments its reference count for the duration of the `spawn` parameter.
3. `newTask` strips the type system guarantees by casting `fn` to `ClosureRepr` and storing raw pointers `rawClosureFn` and `rawClosureEnv`.
4. `spawn` enqueues the `Task` and **returns immediately**.
5. The caller's stack frame unwinds. The compiler-inserted `=destroy(fn)` executes, decrementing the closure environment's reference count to 0 and immediately calling `deallocShared(cr.env)`.
6. Later, a worker thread pops the task and invokes:
   ```nim
   let fn = cast[proc(env: pointer) {.nimcall.}](task.rawClosureFn)
   fn(task.rawClosureEnv) # Accesses deallocated memory!
   ```
7. **Failure Mode**: **Immediate Heap Corruption / Use-After-Free**. In `forkJoin`, this is masked because the caller blocks synchronously until all subtasks finish. In asynchronous `spawn`, it is an absolute memory safety violation.

#### Remediation:
Wrap the closure environment in an atomic ARC container, or explicitly invoke `GC_ref(cr.env)` / `incRef` when creating the task, paired with `GC_unref(cr.env)` / `decRef` in the worker thread upon task completion.

---

## 4. In-Depth Adversarial Analysis: `AsyncBridge` (`async_bridge.nim`)

### 4.1 BLOCKER-03 (Advisory `rem-1`): Dekker Store-Load Reordering in `AsyncBQueue` and `AsyncQueue`
In `src/lockfree/async_bridge.nim` (lines 176-225):
```nim
# Consumer (recvAsync):
proc recvAsync*[T](self: AsyncBQueue[T]): Future[T] {.async.} =
  while true:
    self.consumerSignal.clear()
    self.hasWaitingConsumers.store(true, moRelease) # [Store 1]
    let itemOpt = self.queue.pop()                  # [Load 1: queue state]
    if itemOpt.isSome:
      self.hasWaitingConsumers.store(false, moRelaxed)
      return itemOpt.get
    await self.consumerSignal.wait()                # Coroutine suspends

# Producer (sendAsync):
proc sendAsync*[T](self: AsyncBQueue[T], item: sink T): Future[bool] {.async.} =
  ...
  if self.queue.push(item):                         # [Store 2: queue state]
    if self.hasWaitingConsumers.load(moAcquire):    # [Load 2]
      self.consumerSignal.fire()
    return true
```

#### Hardware Memory Model Reordering Proof (Dekker Hazard):
On modern hardware architectures (x86_64, AArch64, ARMv8/v9):
- A store with `moRelease` guarantees preceding writes are committed before the store, but does **NOT** prevent subsequent loads from being reordered before the store (`Store-Load reordering`).
- In `recvAsync`:
  - `[Store 1]` (`hasWaitingConsumers = true`) is followed by `[Load 1]` (`self.queue.pop()`).
  - The CPU core can speculatively execute `[Load 1]` before flushing `[Store 1]` to the coherent cache hierarchy!
- Concurrently in `sendAsync`:
  - `[Store 2]` (`queue.push()`) is executed.
  - `[Load 2]` (`hasWaitingConsumers.load(moAcquire)`) reads `false` because `[Store 1]` has not yet drained from the consumer core's store buffer!
- Result:
  - Consumer observes `pop() == isNone` (queue empty).
  - Producer observes `hasWaitingConsumers == false` and **does NOT fire `consumerSignal`**!
  - Consumer executes `await self.consumerSignal.wait()`.
  - **Permanent Hang (Deadlock)**: The consumer coroutine sleeps forever despite an item sitting ready in the queue!

#### Strict Advisory `rem-1` Compliance Rule:
Under Advisory `rem-1`, all dual-flag coordination between asynchronous signals and lock-free queues must enforce **Sequential Consistency (`moSeqCst`)** on waiter flags or execute an explicit `atomicFence(moSeqCst)` to eliminate Store-Load reordering.

#### Remediation:
1. Upgrade `hasWaitingConsumers` and `hasWaitingProducers` stores and loads to `moSeqCst`:
   ```nim
   self.hasWaitingConsumers.store(true, moSeqCst)
   ```
2. In producer:
   ```nim
   discard self.queue.push(item)
   atomicFence(moSeqCst)
   if self.hasWaitingConsumers.load(moSeqCst):
     self.consumerSignal.fire()
   ```

---

## 5. Advisory `rem-1` Compliance Matrix

| Audit Dimension | `BroadcastRing` | `TaskPool` | `AsyncBridge` | Status |
|:---|:---|:---|:---|:---|
| **Dekker Store-Load Reordering** | N/A (Lock-free ring) | Verified Sound | **VIOLATION (BLOCKER-03)** | Remediation Required |
| **Unsigned Subtraction Underflow** | **WARNING (MED-01)** | Verified Sound | Verified Sound | Guard `targetSeq - slowestSeq` |
| **False Sharing (`CacheLineBytes`)** | **WARNING (MED-02)** | **WARNING (MED-02)** | Aligned | Pad Atomics |
| **ARC/ORC Lifecycle Safety** | **VIOLATION (CRITICAL-01)** | **VIOLATION (HIGH-02)** | Verified Sound | Fix UAF on Env and Slot Boxes |
| **Boundary Conditions (Zero/Empty)** | Handled | Handled | Handled | Verified Sound |

---

## 6. Remediation Action Plan for `implementer-kite`

1. **AsyncBridge (BLOCKER-03)**:
   - Immediately upgrade all `hasWaitingConsumers` and `hasWaitingProducers` atomic stores/loads to `moSeqCst`.
   - Add explicit stress test in `tests/test_async_bridge.nim` verifying zero dropped signals under high coroutine churn.
2. **BroadcastRing (CRITICAL-01 & HIGH-01)**:
   - In `TopicBus.getOrCreateRing`, replace `put` with `putIfAbsent` to prevent split-brain routing.
   - For `BroadcastRing.poll`, quarantine evicted slot boxes using Debra SMR or add an atomic validation loop verifying `slot.seq` before and after `incRef`.
3. **TaskPool (HIGH-02)**:
   - In `spawn(ClosureProc)`, increment closure environment reference count upon queue insertion and decrement upon task execution.

**Certification**: Pending remediation of `BLOCKER-03`, `CRITICAL-01`, and `HIGH-01`.
