---
title: "lockfree/smr/nebr/limbo"
description: "API reference for lockfree/smr/nebr/limbo"
---

<p>Limbo bag data structures for DEBRA+ retire queues.</p>
<p>A limbo bag holds up to 64 retired objects. Bags are linked together forming a thread-local retire queue.</p>


## Types

### `Destructor`

```nim
Destructor = proc (p: pointer) {.nimcall, raises: [].}
```

Destructor for retired objects. Marked <tt class="docutils literal"><span class="pre"><span class="Identifier">raises</span><span class="Punctuation">:</span> <span class="Punctuation">[</span><span class="Punctuation">]</span></span></tt> so the cleanup paths in <tt class="docutils literal"><span class="pre"><span class="Operator">=</span><span class="Identifier">destroy</span></span></tt> (which itself cannot raise) can call them without an <tt class="docutils literal"><span class="pre"><span class="Identifier">unlisted</span> <span class="Identifier">exception</span></span></tt> effect warning. EBR destructors are reclamation hooks and should not raise; if cleanup can fail, handle it inside the destructor.

### `RetiredObject`

```nim
RetiredObject = object
  data*: pointer
  destructor*: Destructor
```

### `LimboBag`

```nim
LimboBag = object
  objects*: array[LimboBagSize, RetiredObject]
  count*: int
  epoch*: uint64
  next*: ptr LimboBag
```


## Constants

### `LimboBagSize`

```nim
LimboBagSize = 64
```


## Procedures & Functions

### `allocLimboBag`

```nim
proc allocLimboBag(): ptr LimboBag {.raises: [], tags: [], forbids: [].}
```

Allocate a new empty limbo bag.

### `freeLimboBag`

```nim
proc freeLimboBag(bag: ptr LimboBag) {.raises: [], tags: [], forbids: [].}
```

Free a limbo bag (does NOT call destructors).

### `reclaimBag`

```nim
proc reclaimBag(bag: ptr LimboBag) {.raises: [], tags: [RootEffect], forbids: [].}
```

Call destructors for all objects in bag, then free bag.

