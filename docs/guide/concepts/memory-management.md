# Memory management

Nim supports five memory managers: `orc`, `arc`, `atomicArc`, `refc`,
and `none`. `lockfree` supports all five — but what that means for
queue payloads differs per manager. This page is the one-stop
narrative.

For the manager-by-manager defects fixed in v0.1.0, see the
[migration from lockfreequeues v5](../../migrations/from-lockfreequeues-v5.md#path-c-ref-t-and-string-seq-t-payloads).

## The five managers at a glance

| Manager | Refcount style | Cycle collector | Threaded |
|---------|----------------|-----------------|----------|
| `orc` | Deferred reference counting | Yes | Yes (default in 2.2+) |
| `arc` | Deferred reference counting | No | Yes |
| `atomicArc` | Atomic reference counting | No | Yes |
| `refc` | Mark-and-sweep + ref counting | Yes | Yes |
| `none` | No automatic management | No | Yes |

`orc` and `arc` are the modern defaults; `atomicArc` is the
sanitizer-friendly variant; `refc` is the legacy manager kept for
compatibility; `none` is for real-time work where the runtime cannot
allocate.

## What the queue does with payloads

`lockfree`'s queues store payloads in shared slots — usually a
`array[N, T]` for bounded queues, or a per-segment array for unbounded
queues. The semantic the queue enforces is:

> **Push transfers ownership into the queue. Pop transfers ownership
> out. Destroy of a still-occupied slot returns the payload to the
> destroying thread.**

For value types this is trivial: a memcpy moves the bytes in or out
and there is nothing to manage. For payloads with destructors —
`ref T`, `string`, `seq[T]` — the library has to drive the destructor
hooks correctly under each MM.

### Path C: the unified payload story

v0.1.0 adopts **Path C**, a unified internal pattern that handles
managed payload types uniformly across all five MMs. The key idea:
the queue encodes each slot as an 8-byte `SlotEncoding[T]` token. For
plain old data types the token *is* the payload (or a pointer to it).
For `ref T`, `string`, and `seq[T]`, the token is a distinct `uint`
that points at a heap-allocated *box* the queue owns until pop or
destroy reclaims it.

This means:

- **From the user's perspective**: `Queue[ref Foo]`, `Queue[string]`,
  and `Queue[seq[int]]` just work. No `ptr T` wrappers, no
  `-d:allowNonLockFreeQueueItems` escape hatch.
- **From the implementation's perspective**: every MM has a `when`
  arm that drives the same `disposeSlotEncoded` cleanup, but with the
  MM-specific refcount or seq-destroy invocation underneath.

See [ManagedRef](../managed-ref.md) and
[ManagedSlice](../managed-slice.md) for the user-facing API, and
[Slot ownership typestates](../slot-ownership-typestates.md) for cell lifecycle details.

## Per-manager notes

### `--mm:orc` (default)

`orc` is the recommended manager for `lockfree`. It is the default in
Nim 2.2+, runs under thread sanitizer cleanly (when not contended on
cycle-collector slow paths), and supports all payload types
including `ref T` with cycles.

```sh
nim c --threads:on --mm:orc -r myprog.nim
```

A small perf note: if your `ref T` payloads are known acyclic, mark
the type `{.acyclic.}` so the cycle collector can skip it on
destruction.

### `--mm:arc`

`arc` is `orc` minus the cycle collector. Faster on `ref` destruction,
but introduces a leak for cyclic data. Safe for the queue's internal
boxes (which are never cyclic).

```sh
nim c --threads:on --mm:arc -r myprog.nim
```

Use `arc` when your payloads are known acyclic and you want the
deferred refcounting without cycle-collector overhead.

### `--mm:atomicArc`

`atomicArc` swaps the deferred refcount for an atomic refcount. This
is the manager `lockfree`'s CI exercises under thread sanitizer
because the atomic refcount eliminates the "is this `ref` racing on
its refcount?" question.

```sh
nim c --threads:on --mm:atomicArc -r myprog.nim
```

`atomicArc` is slower than `arc` on single-threaded workloads (each
refcount op is an atomic RMW), but is the right call for highly
shared `ref` payloads under sanitizer.

### `--mm:refc`

`refc` is the legacy mark-and-sweep manager. `lockfree` supports it
for compatibility, but it is not the recommended default for new code.
The Path-C wrappers route through refc's `nimGCRefNoCycle` /
`nimGCUnrefNoCycle` for `ref T` payloads and a per-arm `=destroy`
for `string` / `seq[T]`.

```sh
nim c --threads:on --mm:refc -r myprog.nim
```

If you are starting fresh, prefer `orc` over `refc`. `refc` is
maintained for downstream projects that have not migrated.

### `--mm:none`

`--mm:none` disables Nim's runtime memory management entirely. This is
the right choice for audio, embedded real-time, and any environment
where the runtime cannot allocate.

Under `--mm:none`, the queue is a **strict bit transport**: it copies
bytes in on push, copies bytes out on pop, and **does nothing** on
slot-destroy of a still-occupied slot. The user owns every
allocation. The queue will compile-time-reject any payload type whose
default copy/sink hooks would touch a refcount.

```sh
nim c --threads:on --mm:none -r audio_prog.nim
```

A real-world example: the audio ringbuffer pattern, where the queue is
sized to the worst-case backlog at startup, payloads are POD structs
that own no heap memory, and the audio callback never allocates.

```nim
# Payload is plain old data; no destructor, no refcount, no heap.
type AudioSample = object
  left, right: float32

# Capacity = 2× the audio buffer size; enough for one buffer of slack.
var q = newSpscQueue[AudioSample, 2048]()

# In the audio callback (real-time priority):
discard q.push(AudioSample(left: 0.0, right: 0.0))

# In the worker thread:
let s = q.pop()
```

The strict drain contract is documented in
[ManagedSlice — drain helpers](../managed-slice.md#drain-helpers-strict-contract).

## Compile-time enforcement

Each queue type checks its `T` parameter at instantiation time:

- `Queue[ref Foo]` under `--mm:none` → compile-time error.
- `Queue[string]` under `--mm:none` → compile-time error.
- `Queue[seq[T]]` where T is non-POD under `--mm:none` → compile-time error.
- Any other valid combination → admitted.

The check is `static: assert` based and produces an actionable error
message pointing to this page when triggered.

## Further reading

- [ManagedRef](../managed-ref.md) — `ref T` payloads, end-to-end.
- [ManagedSlice](../managed-slice.md) — `string` / `seq[T]` payloads.
- [SMR / nebr](../smr/nebr.md) — how reclamation interacts with refcount cleanup.
- [Slot ownership typestates](../slot-ownership-typestates.md) — per-cell ownership and layout details.
