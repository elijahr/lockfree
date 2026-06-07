# ManagedSlice — `string` / `seq[T]` payloads

`lockfree` v0.1.0 stores `string` and `seq[T]` payloads in queue slots
directly. This page is the user-facing story; the per-MM cell layout
lives in the [memory management](concepts/memory-management.md)
narrative.

## The short version

```nim
import options
import lockfree

# string payloads
var sq = newSpscQueue[string, 16]()
discard sq.push("hello")
echo sq.pop()  # Some("hello")

# seq[int] payloads
var iq = newSpscQueue[seq[int], 16]()
discard iq.push(@[1, 2, 3])
echo iq.pop()  # Some(@[1, 2, 3])
```

Works under `orc`, `arc`, `atomicArc`, and `refc`. Forbidden under
`--mm:none` (the strict bit transport contract rejects any payload
with a destructor at compile time).

## The box pattern

Internally, each `string` / `seq[T]` payload is *boxed*: the queue
heap-allocates a small block via `allocShared0`, moves the payload
into the box, and stores an 8-byte pointer to the box in the slot.

The box pattern is what makes the queue's slot uniformly 8 bytes
regardless of the payload's actual size, and it is what enables
correctness across the four supported MMs without per-MM cell
layouts.

The lifecycle:

1. **Push**: `allocShared0` a box; sink-assign the payload into the
   box; store the box pointer in the slot.
2. **Pop**: read the box pointer; sink-assign the payload out of the
   box; `deallocShared` the box.
3. **Destroy-walk on still-occupied slot**: read the box pointer;
   invoke the per-MM `=destroy` on the boxed payload (which frees
   the heap-allocated string/seq data); `deallocShared` the box.

The compiler emits the per-MM destructor for the boxed value at
each per-MM `when` arm; this is what differs across `orc` vs `refc`
vs the others.

## Nesting rules — what `T` is admitted inside `seq[T]`

A `Queue[seq[T]]` recursively interrogates `T`. The rules:

- `seq[int]`, `seq[float]`, `seq[bool]`, `seq[Object-of-POD]` —
  ADMITTED under all four managed MMs.
- `seq[ref U]` — **ADMITTED in v0.1.0** (relaxed 2026-06-06 per R7
  follow-up). The inner `ref U` carries its own per-MM hooks; the
  compiler-emitted `=destroy(seq[ref U])` invokes those hooks
  correctly during the destroy-walk.
- `seq[seq[U]]` — **ADMITTED in v0.1.0** (also relaxed 2026-06-06).
  The compiler-emitted nested-seq `=destroy` recurses correctly.
- `seq[string]` — ADMITTED; strings carry their own `=destroy`.

Earlier drafts of the design rejected `seq[ref U]` and `seq[seq U]`
to avoid lifetime leaks through the queue boundary. The R7 follow-up
relaxed this once the per-MM box destructor was verified to drive the
compiler-emitted `=destroy(seq[X])` for any X that the compiler
itself admits.

The user-visible takeaway: if `seq[T]` compiles outside the queue,
it compiles inside the queue.

## `--mm:none` rejection

Under `--mm:none`, `Queue[string]` and `Queue[seq[T]]` are
compile-time-rejected. The strict bit-transport contract forbids any
payload whose default copy/sink hooks would touch heap memory.

If you need string-like data on `--mm:none`, the user owns the
allocation entirely. A common pattern is a fixed-size character array
inside a POD object:

```nim
type
  AudioTrackName = object
    bytes: array[64, char]
    length: uint8

var q = newSpscQueue[AudioTrackName, 16]()
discard q.push(AudioTrackName(bytes: ['t', 'r', 'a', 'c', 'k'], length: 5))
```

See [Memory management](concepts/memory-management.md#-mm-none) for
the broader `--mm:none` discussion.

## Drain helpers (strict contract)

For `--mm:none` deployments AND for the explicit-drain pattern under
the other managers, the library ships `destroyAndDrain` as a strict
drain helper:

```nim
proc cleanup(s: var string) =
  # User-supplied cleanup callback; the queue does not allocate.
  s.setLen(0)

q.destroyAndDrain(cleanup)
```

The strict-contract version requires the user to supply a per-item
cleanup callback. The queue invokes the callback on every occupied
slot before freeing slot storage. There is a POD-only overload
(`destroyAndDrain()`) that uses `discard` as the implicit callback for
payloads with no destructor; non-POD payloads must supply a callback
explicitly.

## Examples

- [`examples/04_managed_slice.nim`](https://github.com/elijahr/lockfree/blob/devel/examples/04_managed_slice.nim) — `string` round-trip through an SPSC queue.
- [`examples/07_drain_strict.nim`](https://github.com/elijahr/lockfree/blob/devel/examples/07_drain_strict.nim) — `destroyAndDrain` pattern.
- [`examples/08_mm_none_audio.nim`](https://github.com/elijahr/lockfree/blob/devel/examples/08_mm_none_audio.nim) — `--mm:none` audio ringbuffer.

## Further reading

- [ManagedRef](managed-ref.md) — `ref T` payloads.
- [Memory management](concepts/memory-management.md) — per-MM
  publish / cleanup details.
- [Typestates](typestates.md) — endpoint lifecycle.
