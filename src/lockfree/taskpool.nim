## ===========================================================================
## Concurrency Topology: Work-Stealing TaskPool (Single-Worker Local LIFO Deque,
## Multi-Thief FIFO Steal)
## ===========================================================================
##
## A high-performance, non-blocking work-stealing task pool and scheduler built
## on ChaseLevDeque (Le, Pop, Cohen, Nardelli PPoPP '13) and TreiberStack.
##
## Topology:
##   - Workers: N worker threads pinned with individual ChaseLevDeque instances.
##   - Task Dispatch:
##       - Local worker push: LIFO bottom push/pop for optimal cache locality
##         and recursive fork-join task parallelism.
##       - External push: Non-blocking TreiberStack MPMC injector with
##         elimination-backoff.
##       - Work-Stealing: Starving workers steal FIFO batches (stealBatch) from
##         peer worker deques.
##   - Work-Sharing & Coordination:
##       - forkJoin: Fine-grained recursive task parallelism with work-stealing
##         help loop.
##       - parallelFor: Adaptive divide-and-conquer parallel loop scheduler.
##       - Graceful shutdown: Atomic stop flag with complete task draining and
##         thread join.
##   - Memory Safety:
##       - Supports Nim closures (`proc() {.closure, gcsafe.}`), C-ABI function
##         pointers (`proc(arg: pointer) {.cdecl, gcsafe.}`), and standard
##         nimcall procs (`proc(arg: pointer) {.nimcall, gcsafe.}`).
##       - Deterministic lifecycle management under ARC, ORC, and refc.
## ===========================================================================

import std/options
import std/cpuinfo
import std/os
import lockfree/atomics
import lockfree/atomics/backoff
import lockfree/backoff
import lockfree/deque
import lockfree/stack
import ./internal/aligned_alloc

type
  TaskKind* = enum
    tkClosure
    tkCdecl
    tkNimcall

  TaskProc* = proc(arg: pointer) {.nimcall, gcsafe.}
  CdeclTaskProc* = proc(arg: pointer) {.cdecl, gcsafe.}
  ClosureProc* = proc() {.closure, gcsafe.}

  ClosureRepr = object
    fn: pointer
    env: pointer

  TaskObj* = object
    kind*: TaskKind
    nimcallFn*: TaskProc
    cdeclFn*: CdeclTaskProc
    rawClosureFn*: pointer
    rawClosureEnv*: pointer
    arg*: pointer
    barrier*: ptr Atomic[int64]

  Task* = ptr TaskObj

  WorkerContext = object
    id: int
    pool: ptr TaskPoolCore
    deque: ChaseLevDeque[Task]

  TaskPoolCore = object
    numWorkers: int
    workers: ptr UncheckedArray[WorkerContext]
    threads: ptr UncheckedArray[Thread[ptr WorkerContext]]
    injector: TreiberStack[Task]
    stopFlag: Atomic[bool]
    pendingTasks: Atomic[int64]
    rc: Atomic[int]

  TaskPool* = object
    ## Work-stealing task pool and scheduler.
    core*: ptr TaskPoolCore

  # Ergonomic aliases per mandate
  ThreadPool* = TaskPool
  ConcurrentTaskPool* = TaskPool

proc shutdown*(pool: var TaskPool, wait: bool = true) {.gcsafe.}
proc freeCore(core: ptr TaskPoolCore) {.gcsafe.}

proc `=destroy`*(pool: var TaskPool) {.gcsafe.} =
  if pool.core != nil:
    if pool.core.rc.fetchSub(1, moRelease) == 1:
      threadFence(moAcquire)
      pool.shutdown(wait = true)
      freeCore(pool.core)
    pool.core = nil

proc `=copy`*(dest: var TaskPool, src: TaskPool) =
  if dest.core != src.core:
    `=destroy`(dest)
    dest.core = src.core
    if dest.core != nil:
      discard dest.core.rc.fetchAdd(1, moRelaxed)

proc `=sink`*(dest: var TaskPool, src: TaskPool) =
  if dest.core != src.core:
    `=destroy`(dest)
    dest.core = src.core

var gCurrentWorkerId {.threadvar.}: int
var gWorkerInitialized {.threadvar.}: bool

var gThreadRandState {.threadvar.}: uint64

proc threadRand(maxVal: int): int {.inline.} =
  if maxVal <= 1: return 0
  if gThreadRandState == 0:
    var local: int
    gThreadRandState = cast[uint64](addr local) xor 0x9e3779b97f4a7c15'u64
  # Xorshift64*
  var x = gThreadRandState
  x = x xor (x shr 12)
  x = x xor (x shl 25)
  x = x xor (x shr 27)
  gThreadRandState = x
  let r = x * 0x2545F4914F6CDD1D'u64
  return int(r mod uint64(maxVal))

proc newTask(fn: ClosureProc, barrier: ptr Atomic[int64] = nil): Task =
  result = cast[Task](allocShared0(sizeof(TaskObj)))
  result.kind = tkClosure
  let r = cast[ClosureRepr](fn)
  result.rawClosureFn = r.fn
  result.rawClosureEnv = r.env
  result.barrier = barrier

proc newTask(fn: TaskProc, arg: pointer, barrier: ptr Atomic[int64] = nil): Task =
  result = cast[Task](allocShared0(sizeof(TaskObj)))
  result.kind = tkNimcall
  result.nimcallFn = fn
  result.arg = arg
  result.barrier = barrier

proc newTask(fn: CdeclTaskProc, arg: pointer, barrier: ptr Atomic[int64] = nil): Task =
  result = cast[Task](allocShared0(sizeof(TaskObj)))
  result.kind = tkCdecl
  result.cdeclFn = fn
  result.arg = arg
  result.barrier = barrier

proc executeAndFree(task: Task, core: ptr TaskPoolCore) =
  if task == nil: return
  try:
    case task.kind
    of tkNimcall:
      if task.nimcallFn != nil:
        task.nimcallFn(task.arg)
    of tkCdecl:
      if task.cdeclFn != nil:
        task.cdeclFn(task.arg)
    of tkClosure:
      if task.rawClosureFn != nil:
        let rawFn = cast[proc(env: pointer) {.nimcall, gcsafe.}](task.rawClosureFn)
        rawFn(task.rawClosureEnv)
  finally:
    if task.barrier != nil:
      discard task.barrier[].fetchSub(1'i64, moRelease)
    deallocShared(task)
    if core != nil:
      discard core.pendingTasks.fetchSub(1'i64, moRelease)

proc spawnTask(core: ptr TaskPoolCore, task: Task) =
  discard core.pendingTasks.fetchAdd(1'i64, moRelaxed)
  if gWorkerInitialized and gCurrentWorkerId >= 0 and gCurrentWorkerId < core.numWorkers:
    core.workers[gCurrentWorkerId].deque.pushBottom(task)
  else:
    core.injector.push(task)

proc helpWork*(pool: TaskPool): bool =
  ## Attempts to execute one task from the local deque, global injector, or by
  ## stealing from a peer worker. Returns `true` if a task was executed, `false`
  ## if no pending task was found.
  let core = pool.core
  if unlikely(core == nil): return false

  # 1. Local deque (LIFO order, worker owner only)
  if gWorkerInitialized and gCurrentWorkerId >= 0 and gCurrentWorkerId < core.numWorkers:
    let opt = core.workers[gCurrentWorkerId].deque.popBottom()
    if opt.isSome:
      executeAndFree(opt.get, core)
      return true

  # 2. Global injector (MPMC TreiberStack)
  let injOpt = core.injector.pop()
  if injOpt.isSome:
    executeAndFree(injOpt.get, core)
    return true

  # 3. Work-Stealing: attempt batch steal or single steal from peers
  let numW = core.numWorkers
  if numW > 0:
    let myId = if gWorkerInitialized: gCurrentWorkerId else: -1
    let startIdx = if myId >= 0:
                     (myId + 1 + threadRand(numW)) mod numW
                   else:
                     threadRand(numW)
    for offset in 0 ..< numW:
      let victim = (startIdx + offset) mod numW
      if victim == myId: continue

      # Try stealBatch if thief is a worker
      if myId >= 0:
        var batch: array[8, Task]
        let stolenCount = core.workers[victim].deque.stealBatch(batch, 8)
        if stolenCount > 0:
          # Push extra tasks to own local deque
          for bIdx in 1 ..< stolenCount:
            core.workers[myId].deque.pushBottom(batch[bIdx])
          executeAndFree(batch[0], core)
          return true
      else:
        # External thief: single steal
        let stolenOpt = core.workers[victim].deque.steal()
        if stolenOpt.isSome:
          executeAndFree(stolenOpt.get, core)
          return true

  return false

proc workerThreadEntry(ctx: ptr WorkerContext) {.thread, nimcall, gcsafe.} =
  gCurrentWorkerId = ctx.id
  gWorkerInitialized = true
  let pool = ctx.pool
  var spins = 0

  while not pool.stopFlag.load(moAcquire):
    # 1. Local deque
    let localTask = ctx.deque.popBottom()
    if localTask.isSome:
      spins = 0
      executeAndFree(localTask.get, pool)
      continue

    # 2. Global injector
    let injOpt = pool.injector.pop()
    if injOpt.isSome:
      spins = 0
      executeAndFree(injOpt.get, pool)
      continue

    # 3. Peer stealing
    var stolen = false
    let numW = pool.numWorkers
    if numW > 1:
      let startIdx = (ctx.id + 1 + threadRand(numW)) mod numW
      for offset in 0 ..< numW:
        let victim = (startIdx + offset) mod numW
        if victim == ctx.id: continue

        var batch: array[8, Task]
        let stolenCount = pool.workers[victim].deque.stealBatch(batch, 8)
        if stolenCount > 0:
          spins = 0
          for bIdx in 1 ..< stolenCount:
            ctx.deque.pushBottom(batch[bIdx])
          executeAndFree(batch[0], pool)
          stolen = true
          break

    if stolen:
      continue

    # 4. Idle backoff
    inc spins
    if spins < 32:
      cpuPause()
    elif spins < 128:
      schedYield()
    else:
      sleep(1)
      spins = 32

  # Drain phase on shutdown
  while true:
    let t = ctx.deque.popBottom()
    if t.isSome:
      executeAndFree(t.get, pool)
      continue
    let inj = pool.injector.pop()
    if inj.isSome:
      executeAndFree(inj.get, pool)
      continue
    break

proc initTaskPool*(numWorkers: int = 0): TaskPool =
  ## Initializes a new `TaskPool` with `numWorkers` threads. If `numWorkers <=
  ## 0`, defaults to `countProcessors()`.
  var nw = numWorkers
  if nw <= 0:
    nw = countProcessors()
  if nw < 1:
    nw = 1

  let core = cast[ptr TaskPoolCore](allocShared0(sizeof(TaskPoolCore)))
  core.numWorkers = nw
  core.workers = cast[ptr UncheckedArray[WorkerContext]](allocShared0(sizeof(WorkerContext) * nw))
  core.threads = cast[ptr UncheckedArray[Thread[ptr WorkerContext]]](allocShared0(sizeof(Thread[ptr WorkerContext]) * nw))
  core.injector = initTreiberStack[Task]()
  core.stopFlag.store(false, moRelaxed)
  core.pendingTasks.store(0, moRelaxed)
  core.rc.store(1, moRelaxed)

  for i in 0 ..< nw:
    core.workers[i].id = i
    core.workers[i].pool = core
    core.workers[i].deque = initChaseLevDeque[Task](128)
    createThread(core.threads[i], workerThreadEntry, addr core.workers[i])

  result.core = core

proc initThreadPool*(numWorkers: int = 0): ThreadPool {.inline.} =
  ## Ergonomic alias for `initTaskPool`.
  initTaskPool(numWorkers)

proc initConcurrentTaskPool*(numWorkers: int = 0): ConcurrentTaskPool {.inline.} =
  ## Ergonomic alias for `initTaskPool`.
  initTaskPool(numWorkers)

proc isNil*(pool: TaskPool): bool {.inline.} =
  ## Returns true if the pool handle is uninitialized.
  pool.core == nil

proc numWorkers*(pool: TaskPool): int {.inline.} =
  ## Returns the number of worker threads in the pool.
  if pool.core != nil: pool.core.numWorkers else: 0

proc len*(pool: TaskPool): int64 {.inline.} =
  ## Returns an estimate of pending/active tasks in the pool.
  if pool.core != nil: pool.core.pendingTasks.load(moRelaxed) else: 0

proc spawn*(pool: TaskPool, fn: ClosureProc) =
  ## Submits a closure task to the pool.
  assert pool.core != nil, "TaskPool is uninitialized"
  let t = newTask(fn)
  pool.core.spawnTask(t)

proc spawn*(pool: TaskPool, fn: TaskProc, arg: pointer) =
  ## Submits a nimcall function pointer task to the pool.
  assert pool.core != nil, "TaskPool is uninitialized"
  let t = newTask(fn, arg)
  pool.core.spawnTask(t)

proc spawn*(pool: TaskPool, fn: CdeclTaskProc, arg: pointer) =
  ## Submits a C-ABI cdecl function pointer task to the pool.
  assert pool.core != nil, "TaskPool is uninitialized"
  let t = newTask(fn, arg)
  pool.core.spawnTask(t)

proc sync*(pool: TaskPool) =
  ## Blocks until all active and queued tasks in the pool have completed. The
  ## calling thread actively assists in executing tasks while waiting.
  let core = pool.core
  if unlikely(core == nil): return
  var spins = 0
  while core.pendingTasks.load(moAcquire) > 0:
    if not pool.helpWork():
      inc spins
      if spins < 32:
        cpuPause()
      elif spins < 128:
        schedYield()
      else:
        sleep(1)
        spins = 32

proc forkJoin*(pool: TaskPool, left: ClosureProc, right: ClosureProc) =
  ## Executes `left` and `right` concurrently. `right` is spawned to the pool
  ## while `left` is executed immediately on the current thread. The calling
  ## thread actively assists with work until `right` finishes.
  let core = pool.core
  assert core != nil, "TaskPool is uninitialized"

  var barrier {.align: CacheLineBytes.}: Atomic[int64]
  barrier.store(1, moRelaxed)

  let rightTask = newTask(right, addr barrier)
  core.spawnTask(rightTask)

  left()

  var spins = 0
  while barrier.load(moAcquire) > 0:
    if not pool.helpWork():
      inc spins
      if spins < 32:
        cpuPause()
      elif spins < 128:
        schedYield()
      else:
        sleep(1)
        spins = 32

proc forkJoin*(pool: TaskPool, tasks: openArray[ClosureProc]) =
  ## Executes an arbitrary number of closure tasks concurrently using
  ## work-stealing.
  if tasks.len == 0: return
  if tasks.len == 1:
    tasks[0]()
    return
  if tasks.len == 2:
    pool.forkJoin(tasks[0], tasks[1])
    return

  let core = pool.core
  assert core != nil, "TaskPool is uninitialized"

  var barrier {.align: CacheLineBytes.}: Atomic[int64]
  barrier.store(int64(tasks.len - 1), moRelaxed)

  for i in 1 ..< tasks.len:
    let t = newTask(tasks[i], addr barrier)
    core.spawnTask(t)

  tasks[0]()

  var spins = 0
  while barrier.load(moAcquire) > 0:
    if not pool.helpWork():
      inc spins
      if spins < 32:
        cpuPause()
      elif spins < 128:
        schedYield()
      else:
        sleep(1)
        spins = 32

proc parallelForImpl(
    pool: TaskPool,
    first, last, effChunk: int,
    fn: proc(i: int) {.closure, gcsafe.}
) {.gcsafe.} =
  let count = last - first + 1
  if count <= effChunk:
    for i in first .. last:
      fn(i)
  else:
    let mid = first + count div 2
    pool.forkJoin(
      proc() {.closure, gcsafe.} = pool.parallelForImpl(first, mid - 1, effChunk, fn),
      proc() {.closure, gcsafe.} = pool.parallelForImpl(mid, last, effChunk, fn)
    )

proc parallelFor*(
    pool: TaskPool,
    first, last: int,
    fn: proc(i: int) {.closure, gcsafe.},
    chunkSize: int = 0
) =
  ## Executes iterations in parallel for `i` in `first .. last` (inclusive)
  ## using recursive divide-and-conquer work-stealing.
  if last < first: return
  let count = last - first + 1
  if count == 1:
    fn(first)
    return

  let numW = max(1, pool.numWorkers)
  let effChunk = if chunkSize > 0: chunkSize else: max(1, count div (numW * 4))
  pool.parallelForImpl(first, last, effChunk, fn)

proc parallelFor*(
    pool: TaskPool,
    slice: HSlice[int, int],
    fn: proc(i: int) {.closure, gcsafe.},
    chunkSize: int = 0
) {.inline.} =
  ## Executes iterations in parallel for `i` in `slice.a .. slice.b`
  ## (inclusive).
  pool.parallelFor(slice.a, slice.b, fn, chunkSize)

type
  ParallelForCdeclPayload = object
    pool: TaskPool
    first, last, effChunk: int
    fn: proc(i: int, arg: pointer) {.cdecl, gcsafe.}
    arg: pointer

proc runCdeclChunk(payload: ptr ParallelForCdeclPayload) {.cdecl, gcsafe.}

proc runCdeclTaskProc(arg: pointer) {.cdecl, gcsafe.} =
  runCdeclChunk(cast[ptr ParallelForCdeclPayload](arg))

proc runCdeclChunk(payload: ptr ParallelForCdeclPayload) {.cdecl, gcsafe.} =
  let count = payload.last - payload.first + 1
  if count <= payload.effChunk:
    for i in payload.first .. payload.last:
      payload.fn(i, payload.arg)
  else:
    let mid = payload.first + count div 2
    var rightPayload = ParallelForCdeclPayload(
      pool: payload.pool,
      first: mid,
      last: payload.last,
      effChunk: payload.effChunk,
      fn: payload.fn,
      arg: payload.arg
    )
    var barrier {.align: CacheLineBytes.}: Atomic[int64]
    barrier.store(1, moRelaxed)
    let rightTask = newTask(runCdeclTaskProc, cast[pointer](addr rightPayload), addr barrier)
    payload.pool.core.spawnTask(rightTask)

    var leftPayload = ParallelForCdeclPayload(
      pool: payload.pool,
      first: payload.first,
      last: mid - 1,
      effChunk: payload.effChunk,
      fn: payload.fn,
      arg: payload.arg
    )
    runCdeclChunk(addr leftPayload)

    var spins = 0
    while barrier.load(moAcquire) > 0:
      if not payload.pool.helpWork():
        inc spins
        if spins < 32:
          cpuPause()
        elif spins < 128:
          schedYield()
        else:
          sleep(1)
          spins = 32

proc parallelFor*(
    pool: TaskPool,
    first, last: int,
    fn: proc(i: int, arg: pointer) {.cdecl, gcsafe.},
    arg: pointer,
    chunkSize: int = 0
) =
  ## C-ABI compatible parallel for loop executing `fn(i, arg)` for `first ..
  ## last`.
  if last < first: return
  let count = last - first + 1
  if count == 1:
    fn(first, arg)
    return

  let numW = max(1, pool.numWorkers)
  let effChunk = if chunkSize > 0: chunkSize else: max(1, count div (numW * 4))
  var payload = ParallelForCdeclPayload(
    pool: pool,
    first: first,
    last: last,
    effChunk: effChunk,
    fn: fn,
    arg: arg
  )
  runCdeclChunk(addr payload)

proc shutdown*(pool: var TaskPool, wait: bool = true) {.gcsafe.} =
  ## Gracefully shuts down the task pool and joins all worker threads.
  let core = pool.core
  if core == nil: return
  if core.stopFlag.exchange(true, moRelease):
    # Already initiated shutdown
    return

  if wait:
    pool.sync()

  for i in 0 ..< core.numWorkers:
    joinThread(core.threads[i])

  # Drain and free any residual tasks in injector or worker deques
  while true:
    let opt = core.injector.pop()
    if opt.isSome:
      executeAndFree(opt.get, core)
    else:
      break

  for i in 0 ..< core.numWorkers:
    while true:
      let opt = core.workers[i].deque.popBottom()
      if opt.isSome:
        executeAndFree(opt.get, core)
      else:
        break
    `=destroy`(core.workers[i].deque)

proc join*(pool: var TaskPool) {.inline.} =
  ## Waits for all pending tasks and shuts down the pool.
  pool.shutdown(wait = true)

proc freeCore(core: ptr TaskPoolCore) {.gcsafe.} =
  if core != nil:
    if core.workers != nil:
      deallocShared(core.workers)
      core.workers = nil
    if core.threads != nil:
      deallocShared(core.threads)
      core.threads = nil
    `=destroy`(core.injector)
    deallocShared(core)


proc `$`*(pool: TaskPool): string =
  if pool.core == nil:
    "TaskPool(uninitialized)"
  else:
    "TaskPool[workers=" & $pool.numWorkers & ", pending=" & $pool.len & "]"
