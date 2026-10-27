---
title: "lockfree/constants"
description: "API reference for lockfree/constants"
---

Constants for DEBRA+ implementation.


## Constants

### `DefaultMaxThreads`

```nim
DefaultMaxThreads = 64
```

Default maximum number of threads that can be registered.

### `DefaultCacheLineBytes`

```nim
DefaultCacheLineBytes = 128
```

### `CacheLineBytes`

```nim
CacheLineBytes {.intdefine.}: int = 128
```

Cache line size for alignment to prevent false sharing. Defaults to 128 on Apple Silicon (macOS ARM64) and PowerPC, and 64 on x86_64 and standard AArch64. Override with <tt class="docutils literal"><span class="pre"><span class="Operator">-</span><span class="Identifier">d</span><span class="Punctuation">:</span><span class="Identifier">CacheLineBytes</span><span class="Operator">=</span><span class="DecNumber">64</span></span></tt> or <tt class="docutils literal"><span class="pre"><span class="Operator">-</span><span class="Identifier">d</span><span class="Punctuation">:</span><span class="Identifier">CacheLineBytes</span><span class="Operator">=</span><span class="DecNumber">128</span></span></tt>.


## Templates

### `QuiescentSignal`

```nim
template QuiescentSignal(): cint
```

