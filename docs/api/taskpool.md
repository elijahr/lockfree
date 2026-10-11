# TaskPool (Work-Stealing Scheduler)

`lockfree/taskpool` implements a production-grade work-stealing thread pool and
task scheduler combining per-worker `ChaseLevDeque` instances with a global
`TreiberStack` for external task injection.

## Overview

- **Core Type**: `TaskPool`
- **Ergonomic Aliases**: `ThreadPool`, `ConcurrentTaskPool`
- **Work-Stealing Architecture**: Starving worker threads steal from peer Chase-Lev deques using randomized victim selection.
- **Task Types**: `spawn(proc)` (raw procedure pointers) and `spawn(closure)` (heap-allocated closures with cross-thread ARC/ORC lifecycle safety).
- **Parallel Patterns**: `sync()`, `parallelFor()`.

## Example

```nim
import lockfree

var pool = newTaskPool(numThreads = 4)

var x = 0
pool.spawn(proc() =
  x = 42
)

pool.sync()
assert x == 42
pool.shutdown()
```

::: lockfree/taskpool
