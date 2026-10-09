# Concurrency Architecture & Formal Invariants: RendezvousChannel[T]

**Document ID**: `DESIGN-LOCKFREE-RENDEZVOUS-001`  
**Author**: Marcus Vance (`architect-horsetail`), Staff Systems Architect  
**Reviewers**: Caleb Thorne (`auditor-pegasus`), Elena Rostova (`implementer-kite`), Supreme Orchestrator (`orchestrator-whipbird`)  
**Status**: RATIFIED ARCHITECTURAL SPECIFICATION  
**Target Substrate**: `lockfree` (v0.1.0-consolidated)  
**Deliverable**: `docs/designs/design_rendezvous_channel.md`  

---

## Concurrency Topology & Substrate Banner

```
====================================================================================================
Concurrency Topology: MPMC Synchronous Zero-Buffer Dual Channel (RendezvousChannel[T])
====================================================================================================
| Dimension              | Architectural Specification                                             |
|:-----------------------|:------------------------------------------------------------------------|
| **Topologies**         | MPMC Synchronous Dual Channel (CSP / Go unbuffered `make(chan T)`)       |
| **Buffer Capacity**    | Strictly Zero (No intermediate ring buffer or linked queue segment)     |
| **Delivery Model**     | Bilateral 1-to-1 Rendezvous (Sender & receiver must meet in real time)   |
| **Matching Engine**    | Dual lock-free queue with bilateral CAS arbitration (Scherer & Scott)   |
| **Thread Suspension**  | OS-native futex (`ulock_wait` on Darwin, `WaitOnAddress`, Linux futex) |
| **Correlation Tracking**| Monotonic 64-bit correlation IDs for req/rep RPC pair tracing            |
| **Timeouts**           | Bounded timeouts (`trySend`, `sendWithTimeout`, `tryRecv`, `recvTimeout`)|
| **Payload Storage**    | Single-owner atomic pointer transfer (`VBox[T]`) under ARC/ORC          |
| **Memory Reclamation** | Debra SMR (NEBR, `src/lockfree/smr/nebr/`) for waiter node retirement    |
| **Cache Alignment**    | Waiter nodes and channel anchors aligned to `CacheLineBytes` (64/128B)   |
| **Progress Guarantees**| Immediate Match: Lock-Free; Parking Path: Wait-Free Coordination        |
| **C ABI Interop**      | Full C99 foreign thread support with `lockfree_rendezvous.h` bindings    |
====================================================================================================
```

---

## 1. Executive Summary & Architectural Motivation

### 1.1 Contrast: Buffered Queues vs Synchronous Rendezvous
Existing container surfaces in `lockfree` provide asynchronous buffered queues (`BQueue`, `Queue`, `ChaseLevDeque`, `BroadcastRing`). In all these structures, a sender deposits a message into memory and continues immediately, decoupling the sender's timeline from the receiver's timeline.

However, fundamental concurrent design patterns require **synchronous bilateral coordination**:
$$\text{Send}(m) \iff \text{Recv}(m) \quad \text{simultaneously}$$
1. **Communicating Sequential Processes (CSP)**: Tony Hoare's foundational process calculus requires rendezvous synchronization where communication represents an event shared identically by both processes.
2. **Go Unbuffered Channels (`make(chan T)`)**: Senders block until receivers arrive; receivers block until senders arrive. The transaction confirms that the recipient has physically taken custody of the data before the sender proceeds.
3. **Zero-Allocation RPC / Thread Handoff**: When passing large data buffers or execution leases between worker pools, zero-buffer rendezvous guarantees zero intermediate memory copies, zero queue memory bloat, and instantaneous backpressure propagation.
4. **Deterministic Step Synchronization**: In simulation engines, test harnesses, and lock-step distributed state machines, rendezvous provides formal barriers with payload transfer.

`RendezvousChannel[T]` implements a high-performance, cache-aligned, lock-free **dual data structure** providing Go-style zero-buffer synchronous channel semantics with bilateral matching, monotonic correlation IDs, bounded timeouts, ARC/ORC safety, and C ABI interop.

---

## 2. Theoretical Foundations: Dual Data Structures

The theoretical underpinning of `RendezvousChannel[T]` is the **Dual Data Structure** pioneered by William N. Scherer III and Michael L. Scott (2006, *"Dual Data Structures for Synchronous Queue and Channel Operations"*, PPoPP '06).

### 2.1 The Duality Principle
In an asynchronous queue, the data structure stores **data values**. In a synchronous dual channel, the data structure stores either:
- **Offered Data (Senders Waiting)**: A list of senders holding data, waiting for receivers.
- **Reservations (Receivers Waiting)**: A list of receivers holding empty slots, waiting for senders.

At any point in time, the channel is in one of three states:
1. **Empty**: No threads waiting.
2. **Sender-Pending**: $\ge 1$ senders queued; no receivers queued.
3. **Receiver-Pending**: $\ge 1$ receivers queued; no senders queued.

**Fundamental Invariant**: Senders and receivers NEVER queue simultaneously. The arrival of an opposing thread triggers an immediate bilateral match rather than queuing.

```
                  Dual Channel State Diagram:
                  
                     +--------------------+
                     |    Channel Empty   |
                     |  head == tail == 0 |
                     +---------+----------+
                               |
            +------------------+------------------+
            | (Sender arrives)                    | (Receiver arrives)
            v                                     v
+-----------------------+             +-----------------------+
|    Senders Queued     |             |   Receivers Queued    |
| mode == wmSender      |             | mode == wmReceiver    |
| (data values pending) |             | (requests pending)    |
+-----------+-----------+             +-----------+-----------+
            |                                     |
            | (Receiver arrives)                  | (Sender arrives)
            +-----------------> MATCH <-----------+
                                  |
                                  v
                      +-----------------------+
                      | Bilateral Data Handoff|
                      | CAS state -> rsMatched|
                      | Unpark waiting thread |
                      +-----------------------+
```

---

## 3. Node Hierarchy & Memory Geometry

```
                   Dual Queue Layout & Node Topology
                   
      Channel Core:
      +-------------------------------------------------------------+
      | head: Atomic[ptr WaiterNode[T]] (CacheLine aligned)         |
      | tail: Atomic[ptr WaiterNode[T]] (CacheLine aligned)         |
      | nextCorrId: Atomic[uint64]                                  |
      +-------------------------------------------------------------+
                                     |
                                     v
      Waiter Node (CacheLine Aligned):
      +-------------------------------------------------------------+
      | mode: WaiterMode (wmSender | wmReceiver)                    |
      | state: Atomic[RendezvousState] (Waiting | Matched | Canc)   |
      | vbox: Atomic[ptr VBox[T]] (Payload pointer)                 |
      | correlationId: uint64                                       |
      | next: Atomic[ptr WaiterNode[T]]                             |
      | parker: Parker (OS Futex / Event primitive)                 |
      +-------------------------------------------------------------+
```

### 3.1 Waiter Node (`RendezvousWaiter[T]`)
Each waiting thread constructs or acquires a `RendezvousWaiter[T]` node. The node is cache-aligned to prevent false sharing during concurrent CAS matching and unparking.

```nim
type
  WaiterMode* = enum
    wmSender       ## Thread is offering a value
    wmReceiver     ## Thread is requesting a value

  RendezvousState* = enum
    rsWaiting      ## Actively enqueued, waiting for partner
    rsMatched      ## Partner arrived and won CAS; data transferred
    rsCancelled    ## Thread timed out or aborted before match
    rsCompleted    ## Partner acknowledged handoff; node can be recycled

  RendezvousWaiter*[T] = object
    mode*: WaiterMode
    state*: Atomic[RendezvousState]
    vbox*: Atomic[ptr VBox[T]]         ## Data transfer box
    correlationId*: uint64             ## Monotonic transaction ID
    next*: Atomic[ptr RendezvousWaiter[T]]
    parker*: Parker                    ## OS-level thread suspension handle
    pad: array[CacheLineBytes - sizeof(Atomic[RendezvousState]) - sizeof(Atomic[pointer]) - 32, byte]
```

### 3.2 The Channel Core (`RendezvousChannelCore[T]`)
```nim
type
  RendezvousChannelCore*[T] = object
    head*: Atomic[ptr RendezvousWaiter[T]]
    padHead: array[CacheLineBytes - sizeof(Atomic[pointer]), byte]

    tail*: Atomic[ptr RendezvousWaiter[T]]
    padTail: array[CacheLineBytes - sizeof(Atomic[pointer]), byte]

    nextCorrId*: Atomic[uint64]        ## Monotonic correlation sequence counter
    rc*: Atomic[int]                   ## Channel handle refcount
    isClosed*: Atomic[bool]            ## Channel close sentinel

  RendezvousChannel*[T] = object
    core*: ptr RendezvousChannelCore[T]
```

---

## 4. Algorithmic State Machines for Core Operations

### 4.1 Synchronous Send (`send`)
```nim
proc send*[T](self: RendezvousChannel[T], item: sink T): uint64 =
  ## Synchronously sends `item`, blocking until a receiver consumes it.
  ## Returns the unique monotonic correlation ID for this rendezvous.
  let core = self.core
  let myVBox = allocVBox(item)
  let corrId = core.nextCorrId.fetchAdd(1, moRelaxed) + 1

  while true:
    if core.isClosed.load(moAcquire):
      decRef(myVBox)
      raise newException(ChannelClosedDefect, "RendezvousChannel is closed")

    let h = core.head.load(moAcquire)
    let t = core.tail.load(moAcquire)

    if h == t or t.mode == wmSender:
      # -------------------------------------------------------------
      # Case A: Queue is empty or contains other Senders.
      # Must enqueue ourselves as a waiting sender and park.
      # -------------------------------------------------------------
      var myWaiter = allocWaiter[T](
        mode = wmSender,
        vbox = myVBox,
        corrId = corrId
      )
      if core.enqueueWaiter(myWaiter):
        # Park until matched or cancelled
        myWaiter.parker.park()

        # Wake up: verify we were matched
        if myWaiter.state.load(moAcquire) == rsMatched:
          deallocWaiter(myWaiter)
          return corrId
        else:
          # Abnormal wakeup / cancellation
          deallocWaiter(myWaiter)
          raise newException(RendezvousDefect, "Send interrupted")
      else:
        # Enqueue CAS collided; free node and retry loop
        deallocWaiter(myWaiter)
        cpuRelax()

    else:
      # -------------------------------------------------------------
      # Case B: Queue contains waiting Receivers!
      # We must match with the head receiver.
      # -------------------------------------------------------------
      let headWaiter = core.dequeueWaiter(wmReceiver)
      if headWaiter != nil:
        # Attempt to claim the match via CAS
        var expected = rsWaiting
        if headWaiter.state.compareExchangeStrong(expected, rsMatched, moAcqRel, moRelaxed):
          # Match won! Transfer payload pointer directly into receiver's slot
          headWaiter.vbox.store(myVBox, moRelease)
          headWaiter.correlationId = corrId

          # Wake up the receiver
          headWaiter.parker.unpark()
          return corrId
        else:
          # Receiver was cancelled or matched concurrently; try next
          cpuRelax()
```

### 4.2 Synchronous Receive (`recv`)
```nim
proc recv*[T](self: RendezvousChannel[T], outVal: var T): uint64 =
  ## Synchronously blocks until a sender arrives with a value.
  ## Transfers the payload to `outVal` and returns the rendezvous correlation ID.
  let core = self.core

  while true:
    let h = core.head.load(moAcquire)
    let t = core.tail.load(moAcquire)

    if h == t or t.mode == wmReceiver:
      # -------------------------------------------------------------
      # Case A: Queue is empty or contains other Receivers.
      # Enqueue ourselves as a waiting receiver and park.
      # -------------------------------------------------------------
      var myWaiter = allocWaiter[T](
        mode = wmReceiver,
        vbox = nil,
        corrId = 0
      )
      if core.enqueueWaiter(myWaiter):
        myWaiter.parker.park()

        if myWaiter.state.load(moAcquire) == rsMatched:
          let transferredBox = myWaiter.vbox.load(moAcquire)
          outVal = transferredBox.val
          let cid = myWaiter.correlationId
          decRef(transferredBox)
          deallocWaiter(myWaiter)
          return cid
        else:
          deallocWaiter(myWaiter)
          raise newException(RendezvousDefect, "Receive interrupted")
      else:
        deallocWaiter(myWaiter)
        cpuRelax()

    else:
      # -------------------------------------------------------------
      # Case B: Queue contains waiting Senders!
      # Match with head sender.
      # -------------------------------------------------------------
      let senderWaiter = core.dequeueWaiter(wmSender)
      if senderWaiter != nil:
        var expected = rsWaiting
        if senderWaiter.state.compareExchangeStrong(expected, rsMatched, moAcqRel, moRelaxed):
          let transferredBox = senderWaiter.vbox.load(moAcquire)
          outVal = transferredBox.val
          let cid = senderWaiter.correlationId

          # Sender already holds refcount; take ownership
          decRef(transferredBox)
          senderWaiter.parker.unpark()
          return cid
        else:
          cpuRelax()
```

---

## 5. Non-Blocking & Bounded Timeout Operations

Low-latency and real-time systems cannot tolerate unbounded thread parking. `RendezvousChannel[T]` provides four non-blocking and bounded-timeout primitives:

```nim
proc trySend*[T](self: RendezvousChannel[T], item: sink T, outCorrId: var uint64): bool
proc sendWithTimeout*[T](self: RendezvousChannel[T], item: sink T, timeoutMs: int, outCorrId: var uint64): bool
proc tryRecv*[T](self: RendezvousChannel[T], outVal: var T, outCorrId: var uint64): bool
proc recvWithTimeout*[T](self: RendezvousChannel[T], outVal: var T, timeoutMs: int, outCorrId: var uint64): bool
```

### 5.1 Timeout Cancellation Race Resolution
When a timed-out waiter awakens:
```
           +---------------------------------------------+
           |           Timeout Expired in Parker         |
           +----------------------+----------------------+
                                  |
                                  v
           +---------------------------------------------+
           |  CAS(waiter.state: rsWaiting -> rsCancelled)|
           +----------------------+----------------------+
                                  |
                  +---------------+---------------+
                  | CAS Succeeded                 | CAS Failed (Partner won CAS!)
                  v                               v
         +-----------------+             +-----------------+
         | Cancelled!      |             | Partner matched |
         | Unlink & Return |             | Accept payload  |
         | false           |             | Return true     |
         +-----------------+             +-----------------+
```
**Invariant**: If the timeout expires at the exact moment a partner attempts to match:
1. The waiting thread attempts `CAS(waiter.state, rsWaiting, rsCancelled)`.
2. If the waiting thread wins the CAS, it is officially cancelled. The partner will fail its match CAS and look for another waiter. The sender reclaims its `VBox[T]`.
3. If the partner wins the match CAS first, the cancellation CAS fails! The waiting thread **must** accept the payload and complete successfully, returning `true`. This prevents phantom drops where data is transferred to a thread that thought it timed out.

---

## 6. Monotonic Correlation IDs & RPC Pairing

Every rendezvous handoff carries a globally unique, monotonically increasing 64-bit sequence identifier (`correlationId`).

### 6.1 Formal Invariants
1. **Uniqueness**:
   $$\forall T_1, T_2 \in \text{CompletedRendezvous}, \quad T_1 \neq T_2 \implies \text{corrId}(T_1) \neq \text{corrId}(T_2)$$
2. **Monotonicity**: Correlation IDs increase strictly monotonically: $1, 2, 3, \dots, 2^{64}-1$.
3. **Bilateral Symmetry**: Both sender and receiver observe the **exact same** `correlationId` upon return from a successful rendezvous.

### 6.2 Application: Request / Reply RPC Over Zero-Buffer Channels
```nim
# Client Side:
let reqChan = newRendezvousChannel[Request]()
let repChan = newRendezvousChannel[Response]()

let reqId = reqChan.send(Request(action: "QueryBalance"))
# Wait for corresponding response
var rep: Response
let repId = repChan.recv(rep)
assert reqId == rep.correlationId
```

---

## 7. OS-Level Thread Parking (`Parker`)

To eliminate high CPU burn during waits while maintaining microsecond-level latency, `RendezvousChannel[T]` employs an abstraction over OS-native futex primitives:

```nim
type
  Parker* = object
    when defined(linux):
      futexWord*: Atomic[int32]
    elif defined(macosx) or defined(macos) or defined(ios):
      # Darwin ulock primitive (SYS___ulock_wait / SYS___ulock_wake)
      ulockWord*: Atomic[uint32]
    elif defined(windows):
      # Windows 8+ WaitOnAddress / WakeByAddressSingle
      waitWord*: Atomic[int32]
    else:
      # POSIX pthread_mutex + pthread_cond fallback
      cond: Cond
      lock: Lock
      flag: bool
```

### 7.1 Spin-Before-Park Optimization
Before invoking an OS syscall to park the thread, the waiter executes an adaptive short spin loop:
- First 64 iterations: `cpuPause()` (hardware pause instruction).
- If unmatched after spin threshold: invoke OS futex park.
- Result: Microsecond-latency thread handoffs avoid the ~2-5 microsecond kernel context switch overhead when threads meet near-simultaneously.

---

## 8. ARC/ORC Destructor Safety & VBox Transfer

In a zero-buffer synchronous handoff, object ownership must be transferred directly from the sending thread's stack to the receiving thread's stack without intermediate heap retention.

### 8.1 The Atomic Handover Protocol
```
    Sending Thread                                Receiving Thread
+--------------------+                        +--------------------+
| Alloc VBox(item)   |                        | Alloc WaiterNode   |
| rc = 1             |                        | vbox = nil         |
+---------+----------+                        +---------+----------+
          |                                             |
          |                                             v
          |                                   +--------------------+
          |                                   | Enqueue & Park     |
          |                                   +---------+----------+
          v                                             |
+--------------------+                                  |
| Dequeue Waiter     |                                  |
| CAS state->rsMatched                                  |
| Store waiter.vbox  | =============================>   |
| Unpark receiver    |                                  v
+--------------------+                        +--------------------+
| Return corrId      |                        | Wakeup from park   |
+--------------------+                        | Load waiter.vbox   |
                                              | outVal = vbox.val  |
                                              | decRef(vbox) -> 0  |
                                              | (Free VBox memory) |
                                              +--------------------+
```
- **Sender**: Wraps payload into `ptr VBox[T]` with `rc = 1`.
- **Receiver**: Extracts `vbox.val`. Decrements `vbox.rc` to 0, which invokes `=destroy` on the wrapper and frees the unmanaged pointer.
- **Cancellation**: If the sender times out before being matched, it decrements its own `vbox.rc` to 0, safely destroying `val` without leaks.

---

## 9. C ABI Interop Specification (`lockfree_rendezvous.h`)

For cross-language interoperability (C, C++, Rust, Zig, Python), `RendezvousChannel` exports a production-grade C ABI passing 64-bit pointers as untyped handles.

### 9.1 C Header (`include/lockfree_rendezvous.h`)
```c
#ifndef LOCKFREE_RENDEZVOUS_H
#define LOCKFREE_RENDEZVOUS_H

#include <stdint.h>
#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct lf_rendezvous lf_rendezvous_t;

// Channel Lifecycle
lf_rendezvous_t* lf_rendezvous_create(void);
void lf_rendezvous_destroy(lf_rendezvous_t* chan);
void lf_rendezvous_close(lf_rendezvous_t* chan);

// Blocking Rendezvous Operations
int lf_rendezvous_send(lf_rendezvous_t* chan, void* payload, uint64_t* out_corr_id);
int lf_rendezvous_recv(lf_rendezvous_t* chan, void** out_payload, uint64_t* out_corr_id);

// Non-Blocking Rendezvous Operations (0 timeout)
bool lf_rendezvous_try_send(lf_rendezvous_t* chan, void* payload, uint64_t* out_corr_id);
bool lf_rendezvous_try_recv(lf_rendezvous_t* chan, void** out_payload, uint64_t* out_corr_id);

// Bounded Timeout Rendezvous Operations (milliseconds)
bool lf_rendezvous_send_timeout(lf_rendezvous_t* chan, void* payload, int timeout_ms, uint64_t* out_corr_id);
bool lf_rendezvous_recv_timeout(lf_rendezvous_t* chan, void** out_payload, int timeout_ms, uint64_t* out_corr_id);

#ifdef __cplusplus
}
#endif

#endif // LOCKFREE_RENDEZVOUS_H
```

---

## 10. Memory Ordering, Fences & Synchronization Table

| Memory Operation | Atomic Variable | Required Ordering | Formal Architectural Rationale |
|:---|:---|:---|:---|
| **Correlation Ticket** | `nextCorrId` | `moRelaxed` | Relaxed atomic fetch-and-add suffices; ordering is enforced by the handshake CAS. |
| **Queue Head Read** | `head` | `moAcquire` | Synchronizes with enqueues/dequeues by peer threads. |
| **Queue Tail Swap** | `tail` | `moAcqRel` | Enqueuing a waiter requires acquire to observe existing nodes and release to publish new node. |
| **Match Handshake** | `waiter.state` | `moAcqRel` | Winner of the CAS claims the rendezvous; establishes bilateral synchronization. |
| **VBox Delivery** | `waiter.vbox` | `moRelease` | Sender publishes payload pointer before unparking receiver. |
| **VBox Receipt** | `waiter.vbox` | `moAcquire` | Receiver synchronizes with sender's payload release fence before dereferencing. |
| **Channel Closed** | `isClosed` | `moAcquire` / `moRelease` | Broadcasts channel closure to all waiting and arriving threads. |

---

## 11. Complete Nim API Surface

```nim
type
  RendezvousChannel*[T] = object
    core: ptr RendezvousChannelCore[T]

# Constructors & Lifecycle
proc initRendezvousChannel*[T](): RendezvousChannel[T]
proc close*[T](self: RendezvousChannel[T])
proc isClosed*[T](self: RendezvousChannel[T]): bool

# Blocking Synchronous Handoff
proc send*[T](self: RendezvousChannel[T], item: sink T): uint64 {.discardable.}
proc recv*[T](self: RendezvousChannel[T], outVal: var T): uint64 {.discardable.}
proc recv*[T](self: RendezvousChannel[T]): (T, uint64)

# Non-Blocking Handoff
proc trySend*[T](self: RendezvousChannel[T], item: sink T, outCorrId: var uint64): bool
proc tryRecv*[T](self: RendezvousChannel[T], outVal: var T, outCorrId: var uint64): bool

# Bounded Timeout Handoff
proc sendWithTimeout*[T](
    self: RendezvousChannel[T],
    item: sink T,
    timeoutMs: int,
    outCorrId: var uint64
): bool

proc recvWithTimeout*[T](
    self: RendezvousChannel[T],
    outVal: var T,
    timeoutMs: int,
    outCorrId: var uint64
): bool

# Ergonomic Operators
template `<<-`*[T](chan: RendezvousChannel[T], val: T) = chan.send(val)
template `->>`*[T](chan: RendezvousChannel[T], val: untyped) = discard chan.recv(val)
```

---

## 12. Verification & Auditor Verification Criteria

```
+-----------------------------------------------------------------------------------+
| Stage 1: Architectural Specification & Formal Invariants (design_rendezvous_channel.md) |
| Author: architect-horsetail | Two-Key Gate Pass & Orchestrator Ratification       |
+-----------------------------------------+-----------------------------------------+
                                          |
                                          v
+-----------------------------------------------------------------------------------+
| Stage 2: Dual Queue & Parker Implementation (src/lockfree/rendezvous.nim)         |
| Scherer-Scott dual matching, ulock/futex Parker, correlation counter, VBox transfer|
+-----------------------------------------+-----------------------------------------+
                                          |
                                          v
+-----------------------------------------------------------------------------------+
| Stage 3: C ABI Bindings & C99 Test Harness (src/lockfree/cabi_rendezvous.nim)     |
| Unified lockfree_rendezvous.h, foreign thread parking, zero-copy pointer transfer |
+-----------------------------------------+-----------------------------------------+
                                          |
                                          v
+-----------------------------------------------------------------------------------+
| Stage 4: Concurrency Stress Test Suite (tests/t_rendezvous.nim)                   |
| 8-Sender / 8-Receiver 100k throughput hammer, timeout race stress, TSAN validation|
+-----------------------------------------------------------------------------------+
```

### 12.1 Key Verification Invariants
1. **Zero-Buffer Invariant**: At no point in time can a message reside in the channel without an active sender or receiver thread physically blocked or waiting on it.
2. **Correlation ID Identity**: Under 16 concurrent threads executing 100,000 requests, every sender's returned `corrId` must match the corresponding receiver's returned `corrId` with zero duplicates and zero skipped IDs.
3. **No Phantom Deliveries on Timeout**: When a thread times out, it must either return `false` with the payload intact, or return `true` with the match completed. No message may ever be lost to a cancelled partner.
4. **TSan Cleanliness**: All pointer transitions on `head`, `tail`, and `waiter.state` must pass ThreadSanitizer (`-d:tsan`) with 0 data races.

---

**Architectural Sign-off**:  
*Marcus Vance (`architect-horsetail`), Staff Systems Architect, 2026-10-08*
