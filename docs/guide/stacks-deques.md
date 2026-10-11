# Concurrent Stacks & Deques

`lockfree` provides high-throughput concurrent stacks and deques specifically
engineered for cache efficiency, low allocation overhead, and work distribution.

---

## 1. TreiberStack (`lockfree/stack`)

`TreiberStack[T]` is a lock-free LIFO (Last-In, First-Out) stack augmented with
Hendler, Shavit, and Yerushalmi's **Elimination-Backoff Array**.

### The Elimination Backoff Principle

In a standard Treiber stack, all threads contend on a single atomic `top`
pointer, causing cacheline bouncing and CAS retries under high thread counts.

The Elimination-Backoff Array provides an alternative fast-path:
- When a thread experiences a CAS failure at the top pointer, it visits an array of random elimination slots.
- If a pushing thread meets a popping thread in the same slot within a bounded spin window, they **eliminate each other**: the pusher directly deposits its value into the popper's slot.
- Neither thread accesses the central `top` pointer, allowing stack throughput to scale linearly with core counts under heavy contention.

### Example

```nim
import lockfree

var stack = newTreiberStack[int]()

stack.push(10)
stack.push(20)

let val = stack.pop()
assert val.isSome and val.get() == 20
```

---

## 2. ChaseLevDeque (`lockfree/deque`)

`ChaseLevDeque[T]` is an asymmetric work-stealing circular deque based on the
canonical algorithm by David Chase and Yossi Lev, hardened with C11 atomic
memory orderings and bulk-stealing primitives.

### Topology: Owner vs. Thieves

The deque is designed for work-stealing schedulers:
- **Worker (Owner)**: Operates at the `bottom` of the deque using LIFO ordering (`pushBottom`, `popBottom`). Because the worker thread consumes the most recently added tasks, tasks remain hot in the CPU L1/L2 cache.
- **Thieves (Peers)**: Idle worker threads steal from the `top` of the deque using FIFO ordering (`steal`, `stealBatch`). Thieves take the oldest, largest grains of work, leaving fine-grained tasks for the owner.

### Example

```nim
import lockfree

var deque = newChaseLevDeque[int](initialCapacity = 128)

# Owner thread pushes work:
deque.pushBottom(1)
deque.pushBottom(2)

# Owner thread pops work:
var myTask: int
if deque.popBottom(myTask):
  echo "Owner executing: ", myTask

# Thief thread steals work:
var stolenTask: int
let status = deque.steal(stolenTask)
if status == StealOk:
  echo "Thief executing: ", stolenTask
```

See the [Stack API](../api/stack.md) and [Deque API](../api/deque.md) for full method listings.
