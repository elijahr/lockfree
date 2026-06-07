# ManagedRef — `ref T` payloads

`lockfree` v0.1.0 stores `ref T` payloads in queue slots directly. No
`ptr T` wrapping. No `-d:allowNonLockFreeQueueItems` escape hatch.
This page is the user-facing story.

If you only want to push and pop `ref` values, the short version is:

```nim
type Node = ref object
  value: int

var q = newSpscQueue[Node, 16]()
discard q.push(Node(value: 42))
let n = q.pop()       # Option[Node]: some(Node(value: 42))
```

That works under all four supported memory managers (`orc`, `arc`,
`atomicArc`, `refc`). It does **not** work under `--mm:none` —
`--mm:none` is strict bit transport and forbids destructor-bearing
payloads. See [Memory management](concepts/memory-management.md).

## How it works (briefly)

Internally, each queue slot is an 8-byte `SlotEncoding[T]` token. For
`ref T`, the token is a distinct `uint` carrying the ref's raw
pointer; the actual ref payload lives wherever the MM placed it
(`orc` / `arc` / `atomicArc` heap, `refc` heap).

The semantic is:

- **Push** consumes one reference from the caller (`sink`-style move
  into the queue). The slot now holds the only reference.
- **Pop** transfers the reference back to the caller. The slot is
  cleared. Refcount net change is zero across the round-trip.
- **Destroy on still-occupied slot** drops the queue's reference,
  invoking `=destroy` for the `ref T` via the per-MM hook.

The name `ManagedRef[X]` is the *internal* slot-representation type;
end-users do not write `ManagedRef[Foo]` in their code. The package
documents it for clarity about what the slot holds, not for direct
use.

## Per-MM behavior

| MM | Slot publish path | Slot clear path |
|---|---|---|
| `orc` | `nimIncRef` on box; encode pointer | `nimDecRef` via destroy-walk |
| `arc` | `nimIncRef` on box; encode pointer | `nimDecRef` via destroy-walk |
| `atomicArc` | Atomic `nimIncRef` on box | Atomic `nimDecRef` via destroy-walk |
| `refc` | `nimGCRefNoCycle` on box | `nimGCUnrefNoCycle` via destroy-walk |
| `none` | **rejected at compile time** | n/a |

Under all four supported managers, the queue counts the
push-and-pop round-trip as zero net refcount change: push transfers
+1, pop transfers −1, and the destroy-walk handles cleanup of any
slots still occupied at queue teardown.

## Cleanup and reclamation

For the bounded arms (`BQueue`), slot cleanup happens at queue
destruction. The queue walks its slot array, invokes
`disposeSlotEncoded` on each occupied slot, and frees the slot
storage.

For the unbounded multi-consumer arms (`Queue`), slot cleanup is more
subtle. When a consumer claims a slot, the slot's payload is moved
out and the queue's per-slot ownership is dropped immediately. The
segment itself is *retired* via [nebr](smr/nebr.md) once every slot
in the segment has been claimed; nebr's reclaim pass eventually frees
the segment after every reading thread has moved on.

This means: **a `ref T` payload is dropped at pop time, not at
segment-reclaim time.** The segment-reclaim pass frees only the
segment metadata, not the payload. The payload's lifetime ends at
pop.

## Cycle-collector interaction

Under `--mm:orc`, `ref` cycles involving queue-resident payloads
trigger the cycle collector when the queue is destroyed. The cycle
collector's traversal pauses other threads briefly; if your queue
holds many cyclic `ref` payloads, mark the type `{.acyclic.}`:

```nim
type Node {.acyclic.} = ref object
  value: int
```

`{.acyclic.}` skips the cycle collector for this type. Only mark
types that genuinely cannot form a cycle through their `ref` fields.

Under `--mm:arc`, cycles leak; the manager does not collect them. Use
`--mm:arc` only when payloads are known acyclic.

Under `--mm:atomicArc`, cycle behavior matches `arc`: cycles leak.

Under `--mm:refc`, cycles are collected by the mark-and-sweep pass at
the cost of a full heap traversal.

## Composition matrix (informational)

The full `ref T` composition matrix lives in the internal design doc
([§2.5](https://github.com/elijahr/lockfree/blob/devel/docs/internal/design-sections/02-type-system-and-payload-types.md)).
It is a 25-row enumeration of `ref of X` shapes (`ref int`,
`ref Object`, `ref ref T`, `ref array[N, T]`, `ref tuple`, `ref proc`,
`ref UncheckedArray`, closure environments, etc.) with an ACCEPT or
REJECT verdict per row.

User-facing summary:

- `ref Object` and `ref int` — ACCEPT under all managed MMs.
- `ref ref T` — ACCEPT; the inner `ref` is part of the payload.
- `ref array[N, T]` with small N — ACCEPT.
- `ref UncheckedArray[T]` — ACCEPT but `T` must be POD.
- `ref proc` — ACCEPT; closures carry environment refs.
- `ref T` under `--mm:none` — REJECT (compile-time).

If your `ref` shape falls outside this informal summary, consult the
design-doc matrix.

## Examples

- [`examples/03_managed_ref.nim`](https://github.com/elijahr/lockfree/blob/devel/examples/03_managed_ref.nim) — round-trip a `ref Node` through a bounded SPSC queue.
- [`examples/job_scheduler.nim`](https://github.com/elijahr/lockfree/blob/devel/examples/job_scheduler.nim) — historical `ptr T` job-scheduler pattern; the v0.1.0 equivalent uses `ref` directly.

## Further reading

- [ManagedSlice](managed-slice.md) — `string` / `seq[T]` payloads.
- [Memory management](concepts/memory-management.md) — per-MM
  publish / cleanup details.
- [Typestates](typestates.md) — the endpoint lifecycle around `ref`-bearing queues.
