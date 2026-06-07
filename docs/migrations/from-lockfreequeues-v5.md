# Migrating from `lockfreequeues` v5.x

`lockfree` v0.1.0 is the umbrella consolidation of `lockfreequeues` v5
and `nim-debra`. This page covers everything a `lockfreequeues` v5
user needs to migrate.

If you are coming from `lockfreequeues` v4 or earlier, first read the
v4 → v5 migration in the
[v5.0.0 migration page](../migrations/v5.0.0.md), then come back here
for the v5 → v0.1.0 (umbrella) step.

## Package rename

```diff
- nimble install lockfreequeues
+ nimble install lockfree
```

```diff
# In your .nimble
- requires "lockfreequeues >= 5.0.0"
+ requires "lockfree >= 0.1.0"
```

The version reset is intentional. `lockfree` is a new umbrella
package; v0.1.0 is its first release. The internal API substrate is
the lifted `lockfreequeues` v5 substrate plus the lifted `nim-debra`
substrate, but the umbrella's versioning starts fresh.

<!-- TODO post-rename: confirm Nimble registry name once publication
     path is decided. The lockfreequeues package is frozen at v5.x. -->

## Import path changes

```diff
- import lockfreequeues
+ import lockfree
```

Submodule imports likewise:

```diff
- import lockfreequeues/endpoint
+ import lockfree/endpoint

- import lockfreequeues/role_tags
+ import lockfree/role_tags

- import lockfreequeues/atomics
+ import lockfree/atomics
```

The library is structured the same way; only the umbrella name
changes.

## Removed: `-d:allowNonLockFreeQueueItems`

In v5, `Queue[ref T]` was rejected at compile time unless you set
`-d:allowNonLockFreeQueueItems`. v0.1.0 supports `ref T` directly via
[Path C](../guide/managed-ref.md). The flag is **removed**:

```diff
- nim c --threads:on -d:allowNonLockFreeQueueItems -r myprog.nim
+ nim c --threads:on -r myprog.nim
```

If your code still passes the flag, you get a deprecation warning;
the flag itself is a no-op. The compile-time `ref T` guard is gone:
your `Queue[ref Foo]` instantiation now succeeds and the queue stores
the ref directly.

If your v5 code wrapped a `ref` in a `ptr` to sidestep the guard, you
can keep the `ptr` pattern (it still works) or simplify to direct
`ref`:

```diff
type Node = ref object
  value: int

- var q = newSpscQueue[ptr Node, 16]()
- discard q.push(addr myNode)
+ var q = newSpscQueue[Node, 16]()
+ discard q.push(myNode)
```

See [ManagedRef](../guide/managed-ref.md) for the full `ref T` story
and the per-MM cleanup behavior.

## `string` / `seq[T]` payloads

v5 did not accept `string` or `seq[T]` as queue payloads under any MM
other than `--mm:none` with bit-transport. v0.1.0 accepts both
directly under `orc`, `arc`, `atomicArc`, and `refc`:

```nim
var sq = newSpscQueue[string, 16]()
discard sq.push("hello")
echo sq.pop()  # Some("hello")

var iq = newSpscQueue[seq[int], 16]()
discard iq.push(@[1, 2, 3])
echo iq.pop()  # Some(@[1, 2, 3])
```

`--mm:none` still rejects `string` and `seq[T]` (the strict
bit-transport contract forbids destructor-bearing payloads). See
[ManagedSlice](../guide/managed-slice.md) for the box-pattern story
and the nesting rules.

## Endpoint API: unchanged

The v5.0.0 `Unbound → Bound → Closed` endpoint lifecycle is
**preserved verbatim** in v0.1.0. `getProducer`, `bindToThread`,
`close`, `getProducerHere`, `getConsumerHere`, `bindConsumer` all
have the same signatures. The `Tag` generic and the role-tag
discrimination pragmas are also unchanged.

```nim
# v5.0.0 code — works in v0.1.0 unchanged.
var q = newMpmcQueue[int, 16, 4, 4]()
var producer = q.getProducerHere()
producer.push(42)
producer.close()
```

The only thing that changed in the endpoint layer is the import path
(`lockfreequeues/endpoint` → `lockfree/endpoint`).

## Strict-LCRQ MPMC: unchanged (still ships)

v5.0.0 shipped the strict-LCRQ MPMC unbounded queue
(`Queue[T, ccMulti, ccMulti, …]`) via the LCRQ DWCAS protocol.
v0.1.0 ships this same arm unchanged. The
`supportsCopyMem(T) AND sizeof(T) <= 8` constraint from v5.0.0 is
**relaxed** in v0.1.0: `ref T`, `string`, and `seq[T]` now work via
Path C box pointers, which fit in 8 bytes.

```nim
# v5.0.0: rejected unless T is small POD.
# v0.1.0: works.
var q = newUnboundedMpmcQueue[ref Node, stEager, 64, 4]()
```

## `nim-debra` is absorbed

In v5, the `Queue` multi-consumer arms depended on
`nim-debra` for safe segment reclamation. v0.1.0 absorbs nim-debra
into the umbrella as the `nebr` submodule. You no longer need a
separate `requires "debra >= …"` line in your `.nimble`.

For end-user queue code, this is invisible: the unbounded
multi-consumer arms still manage their own internal manager. If you
import `debra` directly, see
[Migrating from nim-debra](from-nim-debra.md).

## Module-path layout reference

| v5 path | v0.1.0 path |
|---|---|
| `lockfreequeues` | `lockfree` |
| `lockfreequeues/bqueue` | `lockfree/bqueue` |
| `lockfreequeues/queue` | `lockfree/queue` |
| `lockfreequeues/endpoint` | `lockfree/endpoint` |
| `lockfreequeues/role_tags` | `lockfree/role_tags` |
| `lockfreequeues/atomics` | `lockfree/atomics` |
| `lockfreequeues/strategy` | `lockfree/strategy` |
| `lockfreequeues/exceptions` | `lockfree/exceptions` |
| (was via `debra` dep) `debra` | `lockfree/smr/nebr` |
| (was via `debra` dep) `debra/atomics` | `lockfree/atomics` |
| (was via `debra` dep) `debra/typestates` | `lockfree/typestates` |

## Test of the migration

```nim
# pre-migration_smoke.nim (drop-in compile under v5 with lockfreequeues)
import options
import lockfreequeues

var q = newSpscQueue[int, 16]()
discard q.push(42)
echo q.pop()  # Some(42)
```

```nim
# post-migration_smoke.nim (v0.1.0)
import options
import lockfree

var q = newSpscQueue[int, 16]()
discard q.push(42)
echo q.pop()  # Some(42)
```

Compile and run both; the v0.1.0 output should match the v5 output
byte-for-byte. If you see differences, file an issue against
[lockfree](https://github.com/elijahr/lockfree/issues).

## Further reading

- [Migrating from nim-debra](from-nim-debra.md) — for direct
  `nim-debra` users.
- [v4 → v5 migration](../migrations/v5.0.0.md) — for users still on v4.
- [ManagedRef](../guide/managed-ref.md), [ManagedSlice](../guide/managed-slice.md) —
  the new payload-type stories.
