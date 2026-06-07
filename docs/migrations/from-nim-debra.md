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

## Attribution change (Brown 2015 DEBRA+, not Brown 2017 NBR)

The upstream `nim-debra` README originally cited Brown 2017
("Neutralization-Based Reclamation"). This attribution was
**incorrect**: the implementation is inspired by Brown 2015 DEBRA+
(Distributed Epoch-Based Reclamation, "+" variant with signal-based
neutralization), not Brown 2017 NBR. The two are distinct algorithms
with related goals.

v0.1.0 corrects the attribution:

```diff
- This implementation follows Brown 2017, including the SIGUSR1 protocol
- for neutralizing threads that have stalled inside a critical section.
+ This implementation is inspired by Brown 2015 DEBRA+, with documented
+ deviations from the original paper. See guide/smr/nebr.md for the
+ deviation table; see internal/debra-plus-provenance.md for the full
+ bibliographic discussion.
```

If you cited "Brown 2017" or "NBR" in your own README based on the
nim-debra attribution, update those citations to "Brown 2015 DEBRA+
(inspired by; see deviation table)" or similar.

For the full deviation analysis (D1–D9), see the
[nebr deviation table](../guide/smr/nebr.md#deviations-from-brown-2015-debra)
and the
[internal provenance document](https://github.com/elijahr/lockfree/blob/devel/docs/internal/debra-plus-provenance.md).

## The `debra_plus.nim` name slot

`lockfree` reserves the name `lockfree/smr/debra_plus` for a future
**faithful** Brown 2015 DEBRA+ port (with `sigsetjmp` recovery and
hazard pointers). v0.1.0 does **not** ship a `debra_plus`
implementation; the slot is held to make the future migration path
explicit.

If you need a faithful Brown 2015 port today, it is not available
through `lockfree`. The existing `nebr` covers the
neutralization-protocol use case; the `debra_plus` slot is reserved
for the cases where the deviations matter to your safety argument.

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
