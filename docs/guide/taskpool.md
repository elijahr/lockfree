# TaskPool: Work-Stealing Scheduler

`lockfree/taskpool` implements a high-performance work-stealing task pool and
scheduler designed for low-latency thread parallelism and fork-join workloads.

---

## 1. Architecture

The scheduler orchestrates three coordinated lock-free components:
- **Per-Worker `ChaseLevDeque`**: Each worker thread has its own circular work-stealing deque. Worker tasks are pushed to and popped from the local bottom pointer in LIFO order, ensuring maximum cache locality.
- **Global `TreiberStack`**: External tasks injected by non-worker threads enter a central lock-free stack before being consumed by worker threads.
- **Randomized Work-Stealing**: When a worker exhausts its own deque, it randomly selects peer workers and attempts to steal work from the top of their deques.

---

## 2. Spawning Tasks

`TaskPool` supports both raw procedure pointers (`proc()`) and heap-allocated
closures (`proc() {.closure.}`).

For closures, `TaskPool` safely manages cross-thread ARC/ORC lifecycle
invariants to prevent cycle-collector corruption across thread boundaries.

### Example

```nim
import lockfree

# Initialize a pool with 4 worker threads
var pool = newTaskPool(numThreads = 4)

var counter = 0
for i in 1..100:
  pool.spawn(proc() =
    # Task work
    discard
  )

# Wait for all scheduled tasks to complete
pool.sync()

pool.shutdown()
```

---

## 3. Parallel Iteration

`TaskPool` provides built-in parallel chunking to distribute loops across CPU
cores with minimal scheduling overhead:

```nim
import lockfree

var pool = newTaskPool(numThreads = 8)

var data = newSeq[int](10_000)

pool.parallelFor(0, data.len, proc(idx: int) =
  data[idx] = idx * 2
)

pool.sync()
```

See the [TaskPool API Reference](../api/taskpool.md).
