---
title: "lockfree/atomic_arc"
description: "API reference for lockfree/atomic_arc"
---

<pre>==============================================================================
Lock-Free 128-Bit DWCAS Split-Reference-Counted Pointer (`AtomicArc[T]`)
==============================================================================

Concurrency Topology &amp; Mathematical Model:
| Dimension               | Architectural Specification                                              |
|:------------------------|:-------------------------------------------------------------------------|
| **Primitives**          | `AtomicArc[T]` (`AtomicSharedPtr[T]`) &amp; `ArcGuard[T]` (`SharedPtr[T]`)   |
| **State Encoding**      | 128-bit `Pair[uint64, pointer]`: `(gen:32 | extCount:32, cbPtr:64)`      |
| **Atomic Substrate**    | Hardware 128-bit DWCAS (`cmpxchg16b` on x86_64, `caspal` on ARM64 LSE)   |
| **Reclamation Model**   | Biased Split-Reference Counting (`ArcSlotBias = 1'i64 shl 32`)           |
| **Progress Guarantees** | `load`: Lock-Free DWCAS (zero cache-line writes to control block)        |
|                         | `store` / `swap`: Lock-Free DWCAS + 1 atomic `fetchAdd` on evicted block |
|                         | `compareExchange`: Lock-Free DWCAS immune to concurrent `load` churn     |
| **C ABI Interop**       | C99 bindings declared in `include/lockfree_atomic_arc.h`                 |
==============================================================================</pre>


## Types

### `ArcDestroyCallback`

```nim
ArcDestroyCallback = proc (p: pointer) {.cdecl, gcsafe, raises: [].}
```

Optional single-argument custom destructor callback when <tt class="docutils literal"><span class="pre"><span class="Identifier">T</span> <span class="Keyword">is</span> <span class="Identifier">pointer</span></span></tt>.

### `ArcItemDestroyCallback`

```nim
ArcItemDestroyCallback = proc (item: pointer; userData: pointer) {.cdecl,
    gcsafe, raises: [].}
```

Optional C ABI destructor callback matching <tt class="docutils literal"><span class="pre"><span class="Identifier">lfq_item_destructor_fn</span></span></tt>.

### `ArcControlBlock`

```nim
ArcControlBlock[T] = object
  internalCount* {.align: 128.}: Atomic[int64]
  destroyCb*: ArcDestroyCallback
  itemDestroyCb*: ArcItemDestroyCallback
  userData*: pointer
  val*: T
```

### `ArcGuard`

```nim
ArcGuard[T] = object
  cb*: ptr ArcControlBlock[T]
```

Thread-safe reference-counted guard returned by <tt class="docutils literal"><span class="pre"><span class="Identifier">AtomicArc</span><span class="Punctuation">[</span><span class="Identifier">T</span><span class="Punctuation">]</span><span class="Operator">.</span><span class="Identifier">load</span><span class="Punctuation">(</span><span class="Punctuation">)</span></span></tt>, <tt class="docutils literal"><span class="pre"><span class="Identifier">swap</span><span class="Punctuation">(</span><span class="Punctuation">)</span></span></tt>, or constructed via <tt class="docutils literal"><span class="pre"><span class="Identifier">initArcGuard</span><span class="Punctuation">[</span><span class="Identifier">T</span><span class="Punctuation">]</span><span class="Punctuation">(</span><span class="Punctuation">)</span></span></tt>. Keeps the underlying payload alive until all guards and <tt class="docutils literal"><span class="pre"><span class="Identifier">AtomicArc</span><span class="Punctuation">[</span><span class="Identifier">T</span><span class="Punctuation">]</span></span></tt> slots referencing the control block have been released.

### `SharedPtr`

```nim
SharedPtr[T] = ArcGuard[T]
```

Ergonomic C++-style alias for <tt class="docutils literal"><span class="pre"><span class="Identifier">ArcGuard</span><span class="Punctuation">[</span><span class="Identifier">T</span><span class="Punctuation">]</span></span></tt>.

### `AtomicArcSlot`

```nim
AtomicArcSlot = Pair[uint64, pointer]
```

16-byte DWCAS payload:<ul class="simple"><li><tt class="docutils literal"><span class="pre"><span class="Identifier">first</span></span></tt>:  <tt class="docutils literal"><span class="pre"><span class="Punctuation">(</span><span class="Identifier">gen</span> <span class="Keyword">shl</span> <span class="DecNumber">32</span><span class="Punctuation">)</span> <span class="Keyword">or</span> <span class="Identifier">extCount</span></span></tt></li>
<li><tt class="docutils literal"><span class="pre"><span class="Identifier">second</span></span></tt>: <tt class="docutils literal"><span class="pre"><span class="Keyword">ptr</span> <span class="Identifier">ArcControlBlock</span><span class="Punctuation">[</span><span class="Identifier">T</span><span class="Punctuation">]</span></span></tt> (cast to <tt class="docutils literal"><span class="pre"><span class="Identifier">pointer</span></span></tt>)</li>
</ul>

### `AtomicArcCore`

```nim
AtomicArcCore[T] = object
  slot* {.align: 128.}: Atomic[AtomicArcSlot]
  rc* {.align: 128.}: Atomic[int]
```

### `AtomicArc`

```nim
AtomicArc[T] = object
  core*: ptr AtomicArcCore[T]
```

Lock-free atomic shared pointer backed by 128-bit DWCAS split-reference counting. Supports concurrent <tt class="docutils literal"><span class="pre"><span class="Identifier">load</span></span></tt>, <tt class="docutils literal"><span class="pre"><span class="Identifier">store</span></span></tt>, <tt class="docutils literal"><span class="pre"><span class="Identifier">swap</span></span></tt>, and <tt class="docutils literal"><span class="pre"><span class="Identifier">compareExchange</span></span></tt> without locks or background SMR threads.

### `AtomicSharedPtr`

```nim
AtomicSharedPtr[T] = AtomicArc[T]
```

Ergonomic C++-style alias for <tt class="docutils literal"><span class="pre"><span class="Identifier">AtomicArc</span><span class="Punctuation">[</span><span class="Identifier">T</span><span class="Punctuation">]</span></span></tt>.


## Constants

### `ArcSlotBias`

```nim
ArcSlotBias = 4294967296'i64
```

Reference weight contributed to <tt class="docutils literal"><span class="pre"><span class="Identifier">cb</span><span class="Operator">.</span><span class="Identifier">internalCount</span></span></tt> by each active <tt class="docutils literal"><span class="pre"><span class="Identifier">AtomicArc</span><span class="Punctuation">[</span><span class="Identifier">T</span><span class="Punctuation">]</span></span></tt> slot holding <tt class="docutils literal"><span class="pre"><span class="Identifier">cb</span></span></tt>. Prevents <tt class="docutils literal"><span class="pre"><span class="Identifier">cb</span><span class="Operator">.</span><span class="Identifier">internalCount</span></span></tt> from ever reaching <tt class="docutils literal"><span class="pre"><span class="DecNumber">0</span></span></tt> while <tt class="docutils literal"><span class="pre"><span class="Identifier">cb</span></span></tt> remains installed in any <tt class="docutils literal"><span class="pre"><span class="Identifier">AtomicArc</span><span class="Punctuation">[</span><span class="Identifier">T</span><span class="Punctuation">]</span></span></tt> slot.

### `ArcExtMask`

```nim
ArcExtMask = 0x00000000FFFFFFFF'u64
```

Low 32 bits of <tt class="docutils literal"><span class="pre"><span class="Identifier">slot</span><span class="Operator">.</span><span class="Identifier">first</span></span></tt> track external <tt class="docutils literal"><span class="pre"><span class="Identifier">load</span><span class="Punctuation">(</span><span class="Punctuation">)</span></span></tt> acquisitions for the current slot generation. High 32 bits track the monotonic slot generation.

### `ArcGenStep`

```nim
ArcGenStep = 4294967296'u64
```

Added to the high 32-bit generation counter on every slot replacement.

### `ArcExtFlushThreshold`

```nim
ArcExtFlushThreshold = 1073741824'u64
```

If a single slot accumulates &gt;= 2^30 <tt class="docutils literal"><span class="pre"><span class="Identifier">load</span><span class="Punctuation">(</span><span class="Punctuation">)</span></span></tt> operations without being replaced, the reader flushes <tt class="docutils literal"><span class="pre"><span class="Identifier">ArcExtFlushThreshold</span></span></tt> back into <tt class="docutils literal"><span class="pre"><span class="Identifier">cb</span><span class="Operator">.</span><span class="Identifier">internalCount</span></span></tt> so the 32-bit external counter never overflows.


## Procedures & Functions

### `allocControlBlock`

```nim
proc allocControlBlock[T](item: sink T; initialCount: int64;
                          destroyCb: ArcDestroyCallback = nil;
                          itemDestroyCb: ArcItemDestroyCallback = nil;
                          userData: pointer = nil): ptr ArcControlBlock[T] {.
    inline.}
```

### `destroyControlBlock`

```nim
proc destroyControlBlock[T](cb: ptr ArcControlBlock[T]) {.inline, gcsafe.}
```

### `releaseSlotRef`

```nim
proc releaseSlotRef[T](cb: ptr ArcControlBlock[T]; extCount: uint64) {.inline,
    gcsafe.}
```

Reconciles a swapped-out slot's <tt class="docutils literal"><span class="pre"><span class="Identifier">extCount</span></span></tt> against its <tt class="docutils literal"><span class="pre"><span class="Identifier">ArcSlotBias</span></span></tt> in <tt class="docutils literal"><span class="pre"><span class="Identifier">cb</span><span class="Operator">.</span><span class="Identifier">internalCount</span></span></tt>. If total remaining references reach 0, destroys <tt class="docutils literal"><span class="pre"><span class="Identifier">cb</span></span></tt>.

### ``=destroy``

```nim
proc `=destroy`[T](self: var ArcGuard[T]) {.gcsafe, raises: [].}
```

### ``=copy``

```nim
proc `=copy`[T](dest: var ArcGuard[T]; src: ArcGuard[T])
```

### ``=sink``

```nim
proc `=sink`[T](dest: var ArcGuard[T]; src: ArcGuard[T])
```

### `initArcGuard`

```nim
proc initArcGuard[T](val: sink T; destroyCb: ArcDestroyCallback = nil): ArcGuard[
    T] {.inline.}
```

Allocates a new reference-counted control block owning <tt class="docutils literal"><span class="pre"><span class="Identifier">val</span></span></tt> and returns an <tt class="docutils literal"><span class="pre"><span class="Identifier">ArcGuard</span><span class="Punctuation">[</span><span class="Identifier">T</span><span class="Punctuation">]</span></span></tt> with initial reference count 1.

### `initArcGuard`

```nim
proc initArcGuard[T](val: sink T; itemDestroyCb: ArcItemDestroyCallback;
                     userData: pointer): ArcGuard[T] {.inline.}
```

Allocates a new reference-counted control block owning <tt class="docutils literal"><span class="pre"><span class="Identifier">val</span></span></tt> with a <tt class="docutils literal"><span class="pre"><span class="Punctuation">(</span><span class="Identifier">item</span><span class="Punctuation">,</span> <span class="Identifier">userData</span><span class="Punctuation">)</span></span></tt> destructor callback and returns an <tt class="docutils literal"><span class="pre"><span class="Identifier">ArcGuard</span><span class="Punctuation">[</span><span class="Identifier">T</span><span class="Punctuation">]</span></span></tt>.

### `newArcGuard`

```nim
proc newArcGuard[T](val: sink T; destroyCb: ArcDestroyCallback = nil): ArcGuard[
    T] {.inline.}
```

### `initSharedPtr`

```nim
proc initSharedPtr[T](val: sink T; destroyCb: ArcDestroyCallback = nil): SharedPtr[
    T] {.inline.}
```

### `isNil`

```nim
proc isNil[T](self: ArcGuard[T]): bool {.inline.}
```

### `get`

```nim
proc get[T](self: ArcGuard[T]): lent T {.inline.}
```

Returns an immutable lent reference to the managed value. Raises <tt class="docutils literal"><span class="pre"><span class="Identifier">NilAccessDefect</span></span></tt> if <tt class="docutils literal"><span class="pre"><span class="Identifier">self</span><span class="Operator">.</span><span class="Identifier">isNil</span></span></tt>.

### ``[]``

```nim
proc `[]`[T](self: ArcGuard[T]): lent T {.inline.}
```

### `rawPtr`

```nim
proc rawPtr[T](self: ArcGuard[T]): ptr T {.inline.}
```

Returns a raw pointer to the payload inside the control block, or <tt class="docutils literal"><span class="pre"><span class="Keyword">nil</span></span></tt> if the guard is empty. Valid for the lifetime of <tt class="docutils literal"><span class="pre"><span class="Identifier">self</span></span></tt>.

### `tryGet`

```nim
proc tryGet[T](self: ArcGuard[T]): Option[T] {.inline.}
```

### `clone`

```nim
proc clone[T](self: ArcGuard[T]): ArcGuard[T] {.inline.}
```

Explicitly clones the guard, incrementing the control block's reference count.

### `reset`

```nim
proc reset[T](self: var ArcGuard[T]) {.inline.}
```

Releases the guard's reference and resets it to <tt class="docutils literal"><span class="pre"><span class="Keyword">nil</span></span></tt>.

### ``==``

```nim
proc `==`[T](a, b: ArcGuard[T]): bool {.inline.}
```

Pointer-identity equality between two <tt class="docutils literal"><span class="pre"><span class="Identifier">ArcGuard</span><span class="Punctuation">[</span><span class="Identifier">T</span><span class="Punctuation">]</span></span></tt> handles.

### ``=destroy``

```nim
proc `=destroy`[T](self: var AtomicArc[T]) {.gcsafe, raises: [].}
```

### ``=copy``

```nim
proc `=copy`[T](dest: var AtomicArc[T]; src: AtomicArc[T])
```

### ``=sink``

```nim
proc `=sink`[T](dest: var AtomicArc[T]; src: AtomicArc[T])
```

### `initAtomicArc`

```nim
proc initAtomicArc[T](): AtomicArc[T]
```

Initializes an empty (<tt class="docutils literal"><span class="pre"><span class="Keyword">nil</span></span></tt>) <tt class="docutils literal"><span class="pre"><span class="Identifier">AtomicArc</span><span class="Punctuation">[</span><span class="Identifier">T</span><span class="Punctuation">]</span></span></tt>.

### `initAtomicArc`

```nim
proc initAtomicArc[T](val: sink T; destroyCb: ArcDestroyCallback = nil): AtomicArc[
    T]
```

Initializes a new <tt class="docutils literal"><span class="pre"><span class="Identifier">AtomicArc</span><span class="Punctuation">[</span><span class="Identifier">T</span><span class="Punctuation">]</span></span></tt> owning <tt class="docutils literal"><span class="pre"><span class="Identifier">val</span></span></tt>.

### `initAtomicArc`

```nim
proc initAtomicArc[T](val: sink T; itemDestroyCb: ArcItemDestroyCallback;
                      userData: pointer): AtomicArc[T]
```

Initializes a new <tt class="docutils literal"><span class="pre"><span class="Identifier">AtomicArc</span><span class="Punctuation">[</span><span class="Identifier">T</span><span class="Punctuation">]</span></span></tt> owning <tt class="docutils literal"><span class="pre"><span class="Identifier">val</span></span></tt> with a <tt class="docutils literal"><span class="pre"><span class="Punctuation">(</span><span class="Identifier">item</span><span class="Punctuation">,</span> <span class="Identifier">userData</span><span class="Punctuation">)</span></span></tt> destructor callback.

### `initAtomicArc`

```nim
proc initAtomicArc[T](guard: ArcGuard[T]): AtomicArc[T]
```

Initializes a new <tt class="docutils literal"><span class="pre"><span class="Identifier">AtomicArc</span><span class="Punctuation">[</span><span class="Identifier">T</span><span class="Punctuation">]</span></span></tt> sharing ownership of <tt class="docutils literal"><span class="pre"><span class="Identifier">guard</span></span></tt>.

### `newAtomicArc`

```nim
proc newAtomicArc[T](): AtomicArc[T] {.inline.}
```

### `newAtomicArc`

```nim
proc newAtomicArc[T](val: sink T; destroyCb: ArcDestroyCallback = nil): AtomicArc[
    T] {.inline.}
```

### `newAtomicArc`

```nim
proc newAtomicArc[T](guard: ArcGuard[T]): AtomicArc[T] {.inline.}
```

### `initAtomicSharedPtr`

```nim
proc initAtomicSharedPtr[T](): AtomicSharedPtr[T] {.inline.}
```

### `initAtomicSharedPtr`

```nim
proc initAtomicSharedPtr[T](val: sink T; destroyCb: ArcDestroyCallback = nil): AtomicSharedPtr[
    T] {.inline.}
```

### `initAtomicSharedPtr`

```nim
proc initAtomicSharedPtr[T](guard: SharedPtr[T]): AtomicSharedPtr[T] {.inline.}
```

### `isNil`

```nim
proc isNil[T](self: AtomicArc[T]): bool {.inline, gcsafe.}
```

Returns <tt class="docutils literal"><span class="pre"><span class="Identifier">true</span></span></tt> if the <tt class="docutils literal"><span class="pre"><span class="Identifier">AtomicArc</span><span class="Punctuation">[</span><span class="Identifier">T</span><span class="Punctuation">]</span></span></tt> is uninitialized or currently holds <tt class="docutils literal"><span class="pre"><span class="Keyword">nil</span></span></tt>.

### `load`

```nim
proc load[T](self: AtomicArc[T]): ArcGuard[T] {.inline, gcsafe.}
```

Atomically loads an <tt class="docutils literal"><span class="pre"><span class="Identifier">ArcGuard</span><span class="Punctuation">[</span><span class="Identifier">T</span><span class="Punctuation">]</span></span></tt> from <tt class="docutils literal"><span class="pre"><span class="Identifier">self</span></span></tt> using 128-bit DWCAS. Increments the slot's 32-bit external counter atomically with pointer observation so the control block cannot be reclaimed by a concurrent <tt class="docutils literal"><span class="pre"><span class="Identifier">store</span></span></tt> / <tt class="docutils literal"><span class="pre"><span class="Identifier">swap</span></span></tt> / <tt class="docutils literal"><span class="pre"><span class="Identifier">compareExchange</span></span></tt>.

### `loadOpt`

```nim
proc loadOpt[T](self: AtomicArc[T]): Option[T] {.inline, gcsafe.}
```

Atomically loads a copy of the current value wrapped in <tt class="docutils literal"><span class="pre"><span class="Identifier">Option</span><span class="Punctuation">[</span><span class="Identifier">T</span><span class="Punctuation">]</span></span></tt>, or <tt class="docutils literal"><span class="pre"><span class="Identifier">none</span><span class="Punctuation">(</span><span class="Identifier">T</span><span class="Punctuation">)</span></span></tt> if the <tt class="docutils literal"><span class="pre"><span class="Identifier">AtomicArc</span><span class="Punctuation">[</span><span class="Identifier">T</span><span class="Punctuation">]</span></span></tt> is currently empty.

### `store`

```nim
proc store[T](self: AtomicArc[T]; guard: ArcGuard[T]) {.gcsafe.}
```

Atomically replaces the pointer in <tt class="docutils literal"><span class="pre"><span class="Identifier">self</span></span></tt> with <tt class="docutils literal"><span class="pre"><span class="Identifier">guard</span></span></tt> and releases the previous control block's slot reference.

### `store`

```nim
proc store[T](self: AtomicArc[T]; val: sink T;
              destroyCb: ArcDestroyCallback = nil) {.gcsafe.}
```

Allocates a new control block for <tt class="docutils literal"><span class="pre"><span class="Identifier">val</span></span></tt> and atomically stores it into <tt class="docutils literal"><span class="pre"><span class="Identifier">self</span></span></tt>.

### `store`

```nim
proc store[T](self: AtomicArc[T]; val: sink T;
              itemDestroyCb: ArcItemDestroyCallback; userData: pointer) {.gcsafe.}
```

Allocates a new control block for <tt class="docutils literal"><span class="pre"><span class="Identifier">val</span></span></tt> with <tt class="docutils literal"><span class="pre"><span class="Punctuation">(</span><span class="Identifier">itemDestroyCb</span><span class="Punctuation">,</span> <span class="Identifier">userData</span><span class="Punctuation">)</span></span></tt> and atomically stores it into <tt class="docutils literal"><span class="pre"><span class="Identifier">self</span></span></tt>.

### `storeNil`

```nim
proc storeNil[T](self: AtomicArc[T]) {.inline, gcsafe.}
```

Atomically clears <tt class="docutils literal"><span class="pre"><span class="Identifier">self</span></span></tt> to <tt class="docutils literal"><span class="pre"><span class="Keyword">nil</span></span></tt>.

### `swap`

```nim
proc swap[T](self: AtomicArc[T]; guard: ArcGuard[T]): ArcGuard[T] {.gcsafe.}
```

Atomically replaces the pointer in <tt class="docutils literal"><span class="pre"><span class="Identifier">self</span></span></tt> with <tt class="docutils literal"><span class="pre"><span class="Identifier">guard</span></span></tt> and returns the previous value as an <tt class="docutils literal"><span class="pre"><span class="Identifier">ArcGuard</span><span class="Punctuation">[</span><span class="Identifier">T</span><span class="Punctuation">]</span></span></tt>.

### `swap`

```nim
proc swap[T](self: AtomicArc[T]; val: sink T;
             destroyCb: ArcDestroyCallback = nil): ArcGuard[T] {.gcsafe.}
```

Allocates a new control block for <tt class="docutils literal"><span class="pre"><span class="Identifier">val</span></span></tt>, atomically swaps it into <tt class="docutils literal"><span class="pre"><span class="Identifier">self</span></span></tt>, and returns the previous value as an <tt class="docutils literal"><span class="pre"><span class="Identifier">ArcGuard</span><span class="Punctuation">[</span><span class="Identifier">T</span><span class="Punctuation">]</span></span></tt>.

### `swap`

```nim
proc swap[T](self: AtomicArc[T]; val: sink T;
             itemDestroyCb: ArcItemDestroyCallback; userData: pointer): ArcGuard[
    T] {.gcsafe.}
```

Allocates a new control block for <tt class="docutils literal"><span class="pre"><span class="Identifier">val</span></span></tt> with <tt class="docutils literal"><span class="pre"><span class="Punctuation">(</span><span class="Identifier">itemDestroyCb</span><span class="Punctuation">,</span> <span class="Identifier">userData</span><span class="Punctuation">)</span></span></tt>, atomically swaps it into <tt class="docutils literal"><span class="pre"><span class="Identifier">self</span></span></tt>, and returns the previous value as an <tt class="docutils literal"><span class="pre"><span class="Identifier">ArcGuard</span><span class="Punctuation">[</span><span class="Identifier">T</span><span class="Punctuation">]</span></span></tt>.

### `exchange`

```nim
proc exchange[T](self: AtomicArc[T]; guard: ArcGuard[T]): ArcGuard[T] {.inline,
    gcsafe.}
```

### `exchange`

```nim
proc exchange[T](self: AtomicArc[T]; val: sink T;
                 destroyCb: ArcDestroyCallback = nil): ArcGuard[T] {.inline,
    gcsafe.}
```

### `compareExchange`

```nim
proc compareExchange[T](self: AtomicArc[T]; expected: var ArcGuard[T];
                        desired: ArcGuard[T]): bool {.gcsafe.}
```

Atomically compares the control block pointer in <tt class="docutils literal"><span class="pre"><span class="Identifier">self</span></span></tt> with <tt class="docutils literal"><span class="pre"><span class="Identifier">expected</span><span class="Operator">.</span><span class="Identifier">cb</span></span></tt>.<ul class="simple"><li>If equal, replaces <tt class="docutils literal"><span class="pre"><span class="Identifier">self</span></span></tt> with <tt class="docutils literal"><span class="pre"><span class="Identifier">desired</span></span></tt> and returns <tt class="docutils literal"><span class="pre"><span class="Identifier">true</span></span></tt> (<tt class="docutils literal"><span class="pre"><span class="Identifier">expected</span></span></tt> is unchanged). Regardless of concurrent <tt class="docutils literal"><span class="pre"><span class="Identifier">load</span><span class="Punctuation">(</span><span class="Punctuation">)</span></span></tt> operations modifying the slot's external count, the CAS retries as long as the control block pointer continues to match <tt class="docutils literal"><span class="pre"><span class="Identifier">expected</span><span class="Operator">.</span><span class="Identifier">cb</span></span></tt>.</li>
<li>If not equal, updates <tt class="docutils literal"><span class="pre"><span class="Identifier">expected</span></span></tt> to hold a guard to the current value of <tt class="docutils literal"><span class="pre"><span class="Identifier">self</span></span></tt> and returns <tt class="docutils literal"><span class="pre"><span class="Identifier">false</span></span></tt>.</li>
</ul>

### `compareExchange`

```nim
proc compareExchange[T](self: AtomicArc[T]; expected: var ArcGuard[T];
                        desiredVal: sink T; destroyCb: ArcDestroyCallback = nil): bool {.
    inline, gcsafe.}
```

Convenience overload that wraps <tt class="docutils literal"><span class="pre"><span class="Identifier">desiredVal</span></span></tt> in a temporary <tt class="docutils literal"><span class="pre"><span class="Identifier">ArcGuard</span><span class="Punctuation">[</span><span class="Identifier">T</span><span class="Punctuation">]</span></span></tt> and performs <tt class="docutils literal"><span class="pre"><span class="Identifier">compareExchange</span></span></tt>. If the CAS fails, <tt class="docutils literal"><span class="pre"><span class="Identifier">desiredVal</span></span></tt>'s control block is automatically destroyed before returning <tt class="docutils literal"><span class="pre"><span class="Identifier">false</span></span></tt>.

### `compareExchange`

```nim
proc compareExchange[T](self: AtomicArc[T]; expected: var ArcGuard[T];
                        desiredVal: sink T;
                        itemDestroyCb: ArcItemDestroyCallback; userData: pointer): bool {.
    inline, gcsafe.}
```

### `compareExchangeStrong`

```nim
proc compareExchangeStrong[T](self: AtomicArc[T]; expected: var ArcGuard[T];
                              desired: ArcGuard[T]): bool {.inline, gcsafe.}
```

### `compareExchangeWeak`

```nim
proc compareExchangeWeak[T](self: AtomicArc[T]; expected: var ArcGuard[T];
                            desired: ArcGuard[T]): bool {.inline, gcsafe.}
```

