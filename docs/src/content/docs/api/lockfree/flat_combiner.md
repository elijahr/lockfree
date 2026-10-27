---
title: "lockfree/flat_combiner"
description: "API reference for lockfree/flat_combiner"
---

=========================================================================== Concurrency Topology: Hendler-Incze-Shavit-Tzafrir Flat Combiner (<tt class="docutils literal"><span class="pre"><span class="Identifier">FlatCombiner</span><span class="Punctuation">[</span><span class="Identifier">T</span><span class="Punctuation">,</span> <span class="Identifier">Op</span><span class="Punctuation">,</span> <span class="Identifier">Res</span><span class="Punctuation">]</span></span></tt>)<hr />
<p>A high-throughput synchronization adapter implementing <strong>Flat Combining</strong> (Hendler, Incze, Shavit, &amp; Tzafrir, <em>&quot;Flat Combining and the Synchronization-Parallelism Tradeoff&quot;</em>, SPAA 2010).</p>
<p>Flat Combining transforms any sequential data structure <tt class="docutils literal"><span class="pre"><span class="Identifier">T</span></span></tt> into a linearizable, high-throughput concurrent data structure without fine-grained CAS retry storms or cache-line ping-pong on internal nodes:</p>
<ol class="simple"><li><strong>Cache-Line Isolated Publication Records (`PublicationRecord`)</strong>: Each participating thread owns a 64-byte aligned publication record in a lock-free Treiber publication list (<tt class="docutils literal"><span class="pre"><span class="Identifier">pubHead</span></span></tt>). Threads announce an operation (<tt class="docutils literal"><span class="pre"><span class="Identifier">Op</span></span></tt> or a custom callback) in their local record and spin on their private cache line (<tt class="docutils literal"><span class="pre"><span class="Identifier">status</span></span></tt>).</li>
<li><strong>Single-Combiner Batch Execution</strong>: One thread acquires the combiner lease (<tt class="docutils literal"><span class="pre"><span class="Identifier">combinerLock</span></span></tt>), scans the active publication list, and applies all pending operations sequentially to <tt class="docutils literal"><span class="pre"><span class="Identifier">state</span><span class="Punctuation">:</span> <span class="Keyword">var</span> <span class="Identifier">T</span></span></tt> while <tt class="docutils literal"><span class="pre"><span class="Identifier">state</span></span></tt> remains hot in L1 cache.</li>
<li><strong>Contention-Adaptive Multi-Round Leasing</strong>: When peer contention is detected during a combining pass, the combiner retains its lease for up to <tt class="docutils literal"><span class="pre"><span class="Identifier">maxCombiningRounds</span></span></tt> consecutive sweeps so newly submitted operations from awakened threads are combined immediately without lock handoff overhead. Under uncontended single-thread access, the combiner takes a zero-publication fast path and releases immediately.</li>
<li><strong>Periodic Publication-List Pruning</strong>: Every <tt class="docutils literal"><span class="pre"><span class="Identifier">cleanupInterval</span></span></tt> combining passes, stale idle records are safely unlinked from interior positions of <tt class="docutils literal"><span class="pre"><span class="Identifier">pubHead</span></span></tt> via an atomic <tt class="docutils literal"><span class="pre"><span class="Identifier">prsIdle</span> <span class="Operator">-&gt;</span> <span class="Identifier">prsUnlinking</span> <span class="Operator">-&gt;</span> <span class="Identifier">prsUnlinked</span></span></tt> handshake that eliminates list-traversal data races under C11 and ThreadSanitizer.</li>
</ol>


## Types

### `FlatCombinerApplyFn`

```nim
FlatCombinerApplyFn[T; Op; Res] = proc (state: var T; op: Op): Res {.gcsafe.}
```

Typed operation reducer applied by the combiner to <tt class="docutils literal"><span class="pre"><span class="Identifier">state</span></span></tt>.

### `FlatCombinerCustomFn`

```nim
FlatCombinerCustomFn[T] = proc (state: var T; ctx: pointer) {.nimcall, gcsafe.}
```

Low-level type-erased operation callback applied by the combiner to <tt class="docutils literal"><span class="pre"><span class="Identifier">state</span></span></tt>.

### `FlatCombinerConfig`

```nim
FlatCombinerConfig = object
  maxCombiningRounds*: int
  cleanupInterval*: int
  adaptiveSpinCount*: int
```

### `PublicationRecord`

```nim
PublicationRecord[T; Op; Res] = object
  status* {.align: 128.}: Atomic[uint32]
  age*: Atomic[uint64]
  ownerTid*: uint64
  next*: Atomic[pointer]     ## Next `ptr PublicationRecord[T, Op, Res]` in `pubHead`
  allNext*: pointer          ## Next `ptr PublicationRecord[T, Op, Res]` in `allRecordsHead`
  customFn*: FlatCombinerCustomFn[T]
  customCtx*: pointer
  op*: Op
  res*: Res
```

### `FlatCombinerCore`

```nim
FlatCombinerCore[T; Op; Res] = object
  combinerLock* {.align: 128.}: Atomic[uint64]
  passCount* {.align: 128.}: Atomic[uint64]
  totalCombinedOps*: Atomic[uint64]
  activeRecords*: Atomic[int]
  pubHead* {.align: 128.}: Atomic[pointer]
  allRecordsHead* {.align: 128.}: Atomic[pointer]
  combinerId*: uint64
  maxCombiningRounds*: int
  cleanupInterval*: int
  adaptiveSpinCount*: int
  rc*: Atomic[int]
  applyFn*: FlatCombinerApplyFn[T, Op, Res]
  state* {.align: 128.}: T
```

### `FlatCombiner`

```nim
FlatCombiner[T; Op; Res] = object
  core*: ptr FlatCombinerCore[T, Op, Res]
```

Concurrent Flat-Combining wrapper around sequential data structure <tt class="docutils literal"><span class="pre"><span class="Identifier">T</span></span></tt>. Can be instantiated as <tt class="docutils literal"><span class="pre"><span class="Identifier">FlatCombiner</span><span class="Punctuation">[</span><span class="Identifier">T</span><span class="Punctuation">,</span> <span class="Identifier">Op</span><span class="Punctuation">,</span> <span class="Identifier">Res</span><span class="Punctuation">]</span></span></tt> for typed operation dispatch or <tt class="docutils literal"><span class="pre"><span class="Identifier">FlatCombiner</span><span class="Punctuation">[</span><span class="Identifier">T</span><span class="Punctuation">]</span></span></tt> for closure/callback dispatch.


## Constants

### `CacheLine`

```nim
CacheLine = 128
```

### `DefaultCombiningRounds`

```nim
DefaultCombiningRounds = 16
```

Default maximum number of consecutive combining sweeps per lease under contention.

### `DefaultCleanupInterval`

```nim
DefaultCleanupInterval = 64
```

Default number of combining passes between publication list pruning sweeps.

### `DefaultAdaptiveSpinCount`

```nim
DefaultAdaptiveSpinCount = 24
```

Brief pause iterations between multi-round sweeps when peers are active.

### `prsUnlinked`

```nim
prsUnlinked = 0'u32
```

Record is idle and NOT linked in <tt class="docutils literal"><span class="pre"><span class="Identifier">pubHead</span></span></tt>.

### `prsIdle`

```nim
prsIdle = 1'u32
```

Record is linked in <tt class="docutils literal"><span class="pre"><span class="Identifier">pubHead</span></span></tt> and idle between requests.

### `prsPendingTyped`

```nim
prsPendingTyped = 2'u32
```

Record holds a pending typed <tt class="docutils literal"><span class="pre"><span class="Identifier">Op</span></span></tt> request.

### `prsPendingCustom`

```nim
prsPendingCustom = 3'u32
```

Record holds a pending custom callback (<tt class="docutils literal"><span class="pre"><span class="Identifier">customFn</span></span></tt>).

### `prsDone`

```nim
prsDone = 4'u32
```

Request executed by combiner; result ready for owner.

### `prsUnlinking`

```nim
prsUnlinking = 5'u32
```

Transient state held by combiner while unlinking idle record.


## Procedures & Functions

### ``=destroy``

```nim
proc `=destroy`[T, Op, Res](self: var FlatCombiner[T, Op, Res]) {.raises: [].}
```

### ``=copy``

```nim
proc `=copy`[T, Op, Res](dest: var FlatCombiner[T, Op, Res];
                         src: FlatCombiner[T, Op, Res])
```

### ``=sink``

```nim
proc `=sink`[T, Op, Res](dest: var FlatCombiner[T, Op, Res];
                         src: FlatCombiner[T, Op, Res])
```

### `defaultFlatCombinerConfig`

```nim
proc defaultFlatCombinerConfig(maxCombiningRounds: int = DefaultCombiningRounds;
                               cleanupInterval: int = DefaultCleanupInterval;
    adaptiveSpinCount: int = DefaultAdaptiveSpinCount): FlatCombinerConfig {.
    inline, raises: [], tags: [], forbids: [].}
```

### `initFlatCombiner`

```nim
proc initFlatCombiner[T, Op, Res](initialState: sink T;
                                  applyFn: FlatCombinerApplyFn[T, Op, Res];
    maxCombiningRounds: int = DefaultCombiningRounds; cleanupInterval: int = DefaultCleanupInterval;
    adaptiveSpinCount: int = DefaultAdaptiveSpinCount): FlatCombiner[T, Op, Res]
```

Initializes a typed <tt class="docutils literal"><span class="pre"><span class="Identifier">FlatCombiner</span><span class="Punctuation">[</span><span class="Identifier">T</span><span class="Punctuation">,</span> <span class="Identifier">Op</span><span class="Punctuation">,</span> <span class="Identifier">Res</span><span class="Punctuation">]</span></span></tt> with an initial sequential <tt class="docutils literal"><span class="pre"><span class="Identifier">state</span></span></tt> and reducer <tt class="docutils literal"><span class="pre"><span class="Identifier">applyFn</span></span></tt>.

### `newFlatCombiner`

```nim
proc newFlatCombiner[T, Op, Res](initialState: sink T;
                                 applyFn: FlatCombinerApplyFn[T, Op, Res];
    maxCombiningRounds: int = DefaultCombiningRounds;
                                 cleanupInterval: int = DefaultCleanupInterval;
    adaptiveSpinCount: int = DefaultAdaptiveSpinCount): FlatCombiner[T, Op, Res] {.
    inline.}
```

### `initFlatCombiner`

```nim
proc initFlatCombiner[T](initialState: sink T;
                         maxCombiningRounds: int = DefaultCombiningRounds;
                         cleanupInterval: int = DefaultCleanupInterval;
                         adaptiveSpinCount: int = DefaultAdaptiveSpinCount): FlatCombiner[
    T, pointer, pointer]
```

Initializes a single-parameter <tt class="docutils literal"><span class="pre"><span class="Identifier">FlatCombiner</span><span class="Punctuation">[</span><span class="Identifier">T</span><span class="Punctuation">]</span></span></tt> for closure, callback, or <tt class="docutils literal"><span class="pre"><span class="Identifier">withCombined</span></span></tt> block execution.

### `newFlatCombiner`

```nim
proc newFlatCombiner[T](initialState: sink T;
                        maxCombiningRounds: int = DefaultCombiningRounds;
                        cleanupInterval: int = DefaultCleanupInterval;
                        adaptiveSpinCount: int = DefaultAdaptiveSpinCount): FlatCombiner[
    T, pointer, pointer] {.inline.}
```

### `initFlatCombiner`

```nim
proc initFlatCombiner[T](): FlatCombiner[T, pointer, pointer] {.inline.}
```

Initializes a <tt class="docutils literal"><span class="pre"><span class="Identifier">FlatCombiner</span><span class="Punctuation">[</span><span class="Identifier">T</span><span class="Punctuation">]</span></span></tt> with <tt class="docutils literal"><span class="pre"><span class="Identifier">default</span><span class="Punctuation">(</span><span class="Identifier">T</span><span class="Punctuation">)</span></span></tt>.

### `newFlatCombiner`

```nim
proc newFlatCombiner[T](): FlatCombiner[T, pointer, pointer] {.inline.}
```

### `combine`

```nim
proc combine[T, Op, Res](self: FlatCombiner[T, Op, Res]; op: Op): Res {.gcsafe.}
```

<p>Submits a typed operation <tt class="docutils literal"><span class="pre"><span class="Identifier">op</span></span></tt> to the <tt class="docutils literal"><span class="pre"><span class="Identifier">FlatCombiner</span></span></tt> and returns its <tt class="docutils literal"><span class="pre"><span class="Identifier">Res</span></span></tt>.</p>
<p>Fast path: if <tt class="docutils literal"><span class="pre"><span class="Identifier">combinerLock</span></span></tt> is free, acquires the combiner lease directly, executes <tt class="docutils literal"><span class="pre"><span class="Identifier">op</span></span></tt> in L1 cache, and sweeps <tt class="docutils literal"><span class="pre"><span class="Identifier">pubHead</span></span></tt> if any peers have published requests. Contended path: publishes <tt class="docutils literal"><span class="pre"><span class="Identifier">op</span></span></tt> in the thread's 128-byte aligned <tt class="docutils literal"><span class="pre"><span class="Identifier">PublicationRecord</span></span></tt> and awaits completion by the active combiner (or takes over as combiner if the lock becomes free).</p>

### `combineRaw`

```nim
proc combineRaw[T, Op, Res](self: FlatCombiner[T, Op, Res];
                            fn: FlatCombinerCustomFn[T]; ctx: pointer) {.gcsafe.}
```

Executes a low-level callback <tt class="docutils literal"><span class="pre"><span class="Identifier">fn</span><span class="Punctuation">(</span><span class="Identifier">state</span><span class="Punctuation">,</span> <span class="Identifier">ctx</span><span class="Punctuation">)</span></span></tt> under the combiner lease.

### `combine`

```nim
proc combine[T, Op, Res, R](self: FlatCombiner[T, Op, Res];
                            fn: proc (state: var T): R {.gcsafe.}): R {.gcsafe.}
```

Executes an arbitrary closure <tt class="docutils literal"><span class="pre"><span class="Identifier">fn</span><span class="Punctuation">(</span><span class="Identifier">state</span><span class="Punctuation">)</span><span class="Punctuation">:</span> <span class="Identifier">R</span></span></tt> via Flat Combining and returns <tt class="docutils literal"><span class="pre"><span class="Identifier">R</span></span></tt>.

### `combine`

```nim
proc combine[T, Op, Res](self: FlatCombiner[T, Op, Res];
                         fn: proc (state: var T) {.gcsafe.}) {.gcsafe.}
```

Executes a void mutating closure <tt class="docutils literal"><span class="pre"><span class="Identifier">fn</span><span class="Punctuation">(</span><span class="Identifier">state</span><span class="Punctuation">)</span></span></tt> via Flat Combining.

### `isInitialized`

```nim
proc isInitialized[T, Op, Res](self: FlatCombiner[T, Op, Res]): bool {.inline.}
```

### `passCount`

```nim
proc passCount[T, Op, Res](self: FlatCombiner[T, Op, Res]): uint64 {.inline.}
```

Returns the total number of combining passes executed so far.

### `totalCombinedOps`

```nim
proc totalCombinedOps[T, Op, Res](self: FlatCombiner[T, Op, Res]): uint64 {.
    inline.}
```

Returns the total number of individual operations executed across all passes.

### `activePublicationRecords`

```nim
proc activePublicationRecords[T, Op, Res](self: FlatCombiner[T, Op, Res]): int {.
    inline.}
```

Returns the number of thread publication records currently linked in <tt class="docutils literal"><span class="pre"><span class="Identifier">pubHead</span></span></tt>.

### `avgBatchSize`

```nim
proc avgBatchSize[T, Op, Res](self: FlatCombiner[T, Op, Res]): float {.inline.}
```

Returns the average number of operations combined per pass.


## Templates

### `withCombined`

```nim
template withCombined[T, Op, Res](self: FlatCombiner[T, Op, Res];
                                  stateSym: untyped; body: untyped): untyped
```

Executes <tt class="docutils literal"><span class="pre"><span class="Identifier">body</span></span></tt> with mutable access to the sequential state bound to <tt class="docutils literal"><span class="pre"><span class="Identifier">stateSym</span></span></tt> inside a flat-combining critical section.

