---
title: "lockfree/taskpool"
description: "API reference for lockfree/taskpool"
---

=========================================================================== Concurrency Topology: Work-Stealing TaskPool (Single-Worker Local LIFO Deque, Multi-Thief FIFO Steal)<hr />
<p>A high-performance, non-blocking work-stealing task pool and scheduler built on ChaseLevDeque (Le, Pop, Cohen, Nardelli PPoPP '13) and TreiberStack.</p>
<p>Topology:</p>
<ul class="simple"><li>Workers: N worker threads pinned with individual ChaseLevDeque instances.</li>
<li>Task Dispatch:<ul class="simple"><li>Local worker push: LIFO bottom push/pop for optimal cache locality and recursive fork-join task parallelism.</li>
<li>External push: Non-blocking TreiberStack MPMC injector with elimination-backoff.</li>
<li>Work-Stealing: Starving workers steal FIFO batches (stealBatch) from peer worker deques.</li>
</ul>
</li>
<li>Work-Sharing &amp; Coordination:<ul class="simple"><li>forkJoin: Fine-grained recursive task parallelism with work-stealing help loop.</li>
<li>parallelFor: Adaptive divide-and-conquer parallel loop scheduler.</li>
<li>Graceful shutdown: Atomic stop flag with complete task draining and thread join.</li>
</ul>
</li>
<li>Memory Safety:<ul class="simple"><li>Supports Nim closures (<tt class="docutils literal"><span class="pre"><span class="Keyword">proc</span><span class="Punctuation">(</span><span class="Punctuation">)</span> <span class="Punctuation">{</span><span class="Operator">.</span><span class="Identifier">closure</span><span class="Punctuation">,</span> <span class="Identifier">gcsafe</span><span class="Operator">.</span><span class="Punctuation">}</span></span></tt>), C-ABI function pointers (<tt class="docutils literal"><span class="pre"><span class="Keyword">proc</span><span class="Punctuation">(</span><span class="Identifier">arg</span><span class="Punctuation">:</span> <span class="Identifier">pointer</span><span class="Punctuation">)</span> <span class="Punctuation">{</span><span class="Operator">.</span><span class="Identifier">cdecl</span><span class="Punctuation">,</span> <span class="Identifier">gcsafe</span><span class="Operator">.</span><span class="Punctuation">}</span></span></tt>), and standard nimcall procs (<tt class="docutils literal"><span class="pre"><span class="Keyword">proc</span><span class="Punctuation">(</span><span class="Identifier">arg</span><span class="Punctuation">:</span> <span class="Identifier">pointer</span><span class="Punctuation">)</span> <span class="Punctuation">{</span><span class="Operator">.</span><span class="Identifier">nimcall</span><span class="Punctuation">,</span> <span class="Identifier">gcsafe</span><span class="Operator">.</span><span class="Punctuation">}</span></span></tt>).</li>
<li>
<h1><a class="toc-backref" id="deterministic-lifecycle-management-under-arc-orc-and-refcdot" href="#deterministic-lifecycle-management-under-arc-orc-and-refcdot">Deterministic lifecycle management under ARC, ORC, and refc.</a></h1></li>
</ul>
</li>
</ul>


## Types

### `TaskKind`

```nim
TaskKind = enum
  tkClosure, tkCdecl, tkNimcall
```

### `TaskProc`

```nim
TaskProc = proc (arg: pointer) {.nimcall, gcsafe.}
```

### `CdeclTaskProc`

```nim
CdeclTaskProc = proc (arg: pointer) {.cdecl, gcsafe.}
```

### `ClosureProc`

```nim
ClosureProc = proc () {.closure, gcsafe.}
```

### `TaskObj`

```nim
TaskObj = object
  kind*: TaskKind
  heapAllocated*: bool
  nimcallFn*: TaskProc
  cdeclFn*: CdeclTaskProc
  rawClosureFn*: pointer
  rawClosureEnv*: pointer
  arg*: pointer
  barrier*: ptr Atomic[int64]
```

### `Task`

```nim
Task = ptr TaskObj
```

### `TaskPool`

```nim
TaskPool = object
  core*: ptr TaskPoolCore
```

Work-stealing task pool and scheduler.

### `ThreadPool`

```nim
ThreadPool = TaskPool
```

### `ConcurrentTaskPool`

```nim
ConcurrentTaskPool = TaskPool
```


## Procedures & Functions

### `shutdown`

```nim
proc shutdown(pool: var TaskPool; wait: bool = true) {.gcsafe,
    raises: [Exception, DebraRegistrationError],
    tags: [RootEffect, TypestateOp], forbids: [].}
```

### ``=destroy``

```nim
proc `=destroy`(pool: var TaskPool) {.gcsafe, raises: [], tags: [RootEffect],
                                      forbids: [].}
```

### ``=copy``

```nim
proc `=copy`(dest: var TaskPool; src: TaskPool) {.raises: [],
    tags: [RootEffect], forbids: [].}
```

### ``=sink``

```nim
proc `=sink`(dest: var TaskPool; src: TaskPool) {.raises: [],
    tags: [RootEffect], forbids: [].}
```

### `helpWork`

```nim
proc helpWork(pool: TaskPool): bool {.raises: [Exception, DebraRegistrationError],
                                      tags: [RootEffect, TypestateOp],
                                      forbids: [].}
```

Attempts to execute one task from the local deque, global injector, or by stealing from a peer worker. Returns <tt class="docutils literal"><span class="pre"><span class="Identifier">true</span></span></tt> if a task was executed, <tt class="docutils literal"><span class="pre"><span class="Identifier">false</span></span></tt> if no pending task was found.

### `initTaskPool`

```nim
proc initTaskPool(numWorkers: int = 0): TaskPool {.
    raises: [ResourceExhaustedError], tags: [], forbids: [].}
```

Initializes a new <tt class="docutils literal"><span class="pre"><span class="Identifier">TaskPool</span></span></tt> with <tt class="docutils literal"><span class="pre"><span class="Identifier">numWorkers</span></span></tt> threads. If <tt class="docutils literal"><span class="pre"><span class="Identifier">numWorkers</span> <span class="Operator">&lt;=</span> <span class="DecNumber">0</span></span></tt>, defaults to <tt class="docutils literal"><span class="pre"><span class="Identifier">countProcessors</span><span class="Punctuation">(</span><span class="Punctuation">)</span></span></tt>.

### `initThreadPool`

```nim
proc initThreadPool(numWorkers: int = 0): ThreadPool {.inline,
    raises: [ResourceExhaustedError], tags: [], forbids: [].}
```

Ergonomic alias for <tt class="docutils literal"><span class="pre"><span class="Identifier">initTaskPool</span></span></tt>.

### `initConcurrentTaskPool`

```nim
proc initConcurrentTaskPool(numWorkers: int = 0): ConcurrentTaskPool {.inline,
    raises: [ResourceExhaustedError], tags: [], forbids: [].}
```

Ergonomic alias for <tt class="docutils literal"><span class="pre"><span class="Identifier">initTaskPool</span></span></tt>.

### `isNil`

```nim
proc isNil(pool: TaskPool): bool {.inline, raises: [], tags: [], forbids: [].}
```

Returns true if the pool handle is uninitialized.

### `numWorkers`

```nim
proc numWorkers(pool: TaskPool): int {.inline, raises: [], tags: [], forbids: [].}
```

Returns the number of worker threads in the pool.

### `len`

```nim
proc len(pool: TaskPool): int64 {.inline, raises: [], tags: [], forbids: [].}
```

Returns an estimate of pending/active tasks in the pool.

### `spawn`

```nim
proc spawn(pool: TaskPool; fn: ClosureProc) {.raises: [], tags: [RootEffect],
    forbids: [].}
```

Submits a closure task to the pool.

### `spawn`

```nim
proc spawn(pool: TaskPool; fn: TaskProc; arg: pointer) {.raises: [],
    tags: [RootEffect], forbids: [].}
```

Submits a nimcall function pointer task to the pool.

### `spawn`

```nim
proc spawn(pool: TaskPool; fn: CdeclTaskProc; arg: pointer) {.raises: [],
    tags: [RootEffect], forbids: [].}
```

Submits a C-ABI cdecl function pointer task to the pool.

### `sync`

```nim
proc sync(pool: TaskPool) {.raises: [Exception, DebraRegistrationError],
                            tags: [RootEffect, TypestateOp], forbids: [].}
```

Blocks until all active and queued tasks in the pool have completed. The calling thread actively assists in executing tasks while waiting.

### `forkJoin`

```nim
proc forkJoin(pool: TaskPool; left: ClosureProc; right: ClosureProc) {.
    raises: [Exception, DebraRegistrationError],
    tags: [RootEffect, TypestateOp], forbids: [].}
```

Executes <tt class="docutils literal"><span class="pre"><span class="Identifier">left</span></span></tt> and <tt class="docutils literal"><span class="pre"><span class="Identifier">right</span></span></tt> concurrently. <tt class="docutils literal"><span class="pre"><span class="Identifier">right</span></span></tt> is spawned to the pool while <tt class="docutils literal"><span class="pre"><span class="Identifier">left</span></span></tt> is executed immediately on the current thread. The calling thread actively assists with work until <tt class="docutils literal"><span class="pre"><span class="Identifier">right</span></span></tt> finishes.

### `forkJoin`

```nim
proc forkJoin(pool: TaskPool; tasks: openArray[ClosureProc]) {.
    raises: [Exception, DebraRegistrationError],
    tags: [RootEffect, TypestateOp], forbids: [].}
```

Executes an arbitrary number of closure tasks concurrently using work-stealing.

### `parallelFor`

```nim
proc parallelFor(pool: TaskPool; first, last: int;
                 fn: proc (i: int) {.closure, gcsafe.}; chunkSize: int = 0) {.
    raises: [Exception, DebraRegistrationError],
    tags: [RootEffect, TypestateOp], forbids: [].}
```

Executes iterations in parallel for <tt class="docutils literal"><span class="pre"><span class="Identifier">i</span></span></tt> in <tt class="docutils literal"><span class="pre"><span class="Identifier">first</span> <span class="Operator">..</span> <span class="Identifier">last</span></span></tt> (inclusive) using chunked work-stealing tasks without closure environment heap allocations.

### `parallelFor`

```nim
proc parallelFor(pool: TaskPool; slice: HSlice[int, int];
                 fn: proc (i: int) {.closure, gcsafe.}; chunkSize: int = 0) {.
    inline, raises: [Exception, DebraRegistrationError],
    tags: [RootEffect, TypestateOp], forbids: [].}
```

Executes iterations in parallel for <tt class="docutils literal"><span class="pre"><span class="Identifier">i</span></span></tt> in <tt class="docutils literal"><span class="pre"><span class="Identifier">slice</span><span class="Operator">.</span><span class="Identifier">a</span> <span class="Operator">..</span> <span class="Identifier">slice</span><span class="Operator">.</span><span class="Identifier">b</span></span></tt> (inclusive).

### `parallelFor`

```nim
proc parallelFor(pool: TaskPool; first, last: int;
                 fn: proc (i: int; arg: pointer) {.cdecl, gcsafe.};
                 arg: pointer; chunkSize: int = 0) {.
    raises: [Exception, DebraRegistrationError],
    tags: [RootEffect, TypestateOp], forbids: [].}
```

C-ABI compatible parallel for loop executing <tt class="docutils literal"><span class="pre"><span class="Identifier">fn</span><span class="Punctuation">(</span><span class="Identifier">i</span><span class="Punctuation">,</span> <span class="Identifier">arg</span><span class="Punctuation">)</span></span></tt> for <tt class="docutils literal"><span class="pre"><span class="Identifier">first</span> <span class="Operator">..</span> <span class="Identifier">last</span></span></tt>.

### `join`

```nim
proc join(pool: var TaskPool) {.inline,
                                raises: [Exception, DebraRegistrationError],
                                tags: [RootEffect, TypestateOp], forbids: [].}
```

Waits for all pending tasks and shuts down the pool.

### ``$``

```nim
proc `$`(pool: TaskPool): string {.raises: [], tags: [], forbids: [].}
```

