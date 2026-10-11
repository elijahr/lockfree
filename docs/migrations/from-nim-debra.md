# Migrating from `nim-debra` / `debra`

`lockfree` v0.1.0 absorbs the `nim-debra` package into the umbrella as
the `lockfree/smr/nebr` submodule. The reclamation algorithm is the
same — only the package name, import paths, and attribution change.

If you depended on `nim-debra` only transitively via `lockfreequeues`,
read [Migrating from lockfreequeues v5](from-lockfreequeues-v5.md)
instead. This page is for users who imported `debra` directly.

> **Naming note.** The upstream nimble package was published as
> `nim-debra` and imported as `debra` (the `nim-` prefix is a nimble
> convention, not part of the module name). This page covers the
> consolidation for both the package name and the import name; an
> earlier draft of the design listed a separate `from-debra-package.md`
> page, which would have duplicated the content here. There is no
> separate page — both audiences land on this one.

## Package rename

```diff
- nimble install nim-debra
+ nimble install lockfree
```

```diff
# In your .nimble
- requires "debra >= 0.8.0"
+ requires "lockfree >= 0.1.0"
```

The version reset is intentional — `lockfree` is a new umbrella
package starting at v0.1.0.

<!-- TODO post-rename: confirm Nimble registry transfer once
     publication path is decided. nim-debra is frozen at 0.8.x. -->

## Import path changes

```diff
- import debra
+ import lockfree/smr/nebr

- import debra/atomics
+ import lockfree/atomics

- import debra/typestates
+ import lockfree/typestates
```

The submodules align as follows:

| Old (nim-debra) | New (lockfree) |
|---|---|
| `debra` | `lockfree/smr/nebr` |
| `debra/atomics` | `lockfree/atomics` |
| `debra/typestates` | `lockfree/typestates` |

## Symbol mapping

All public symbols carry the same name and the same signature; only
the qualifier changes.

| Old symbol | New symbol | Notes |
|---|---|---|
| `debra/atomics.Atomic[T]` | `lockfree/atomics.Atomic[T]` | API-identical. |
| `debra.Manager` | `lockfree/smr/nebr.Manager` | API-identical. |
| `debra.newManager` | `lockfree/smr/nebr.newManager` | API-identical. |
| `debra.register` | `lockfree/smr/nebr.register` | API-identical. |
| `debra.pin` / `debra.unpin` | `lockfree/smr/nebr.pin` / `unpin` | API-identical. |
| `debra.retire` | `lockfree/smr/nebr.retire` | API-identical. |
| `debra.reclaim` | `lockfree/smr/nebr.reclaim` | API-identical. |
| `debra.neutralizeStalled` | `lockfree/smr/nebr.neutralizeStalled` | API-identical. |
| `debra/typestates` | `lockfree/typestates` | API-identical for the SMR FSM. |
| `DebraManager` (legacy alias) | `nebr.Manager` | Legacy alias retained for one release. |
| `DebraRegistrationError` | `DebraRegistrationError` | Exception type name **retained** for source compatibility. |

The reclamation algorithm itself is unchanged. The behavioral
contract (pin / unpin / retire / reclaim / neutralize) is unchanged.
Only the names of the package and the submodule prefix change.

## Attribution

The implementation is inspired by Brown 2015 DEBRA+ (Distributed Epoch-Based
Reclamation, "+" variant with signal-based neutralization). See
[guide/smr/nebr.md](../guide/smr/nebr.md) for the deviation table and implementation
details.

## Test of the migration

```nim
# pre-migration_smoke.nim (nim-debra)
import debra

var manager = newManager(maxThreads = 2)
manager.register()
manager.pin()
manager.unpin()
echo "OK"
```

```nim
# post-migration_smoke.nim (v0.1.0)
import lockfree/smr/nebr

var manager = newManager(maxThreads = 2)
manager.register()
manager.pin()
manager.unpin()
echo "OK"
```

Both should produce `OK` and exit cleanly.

## Further reading

- [SMR / nebr](../guide/smr/nebr.md) — manager lifecycle, deviation table.
- [SMR fundamentals](../guide/concepts/smr.md) — the problem nebr solves.
- Internal: [debra-plus-provenance.md](https://github.com/elijahr/lockfree/blob/devel/docs/internal/debra-plus-provenance.md) — the full deviation analysis.
