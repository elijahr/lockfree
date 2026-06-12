# Chronos

`Chronos` is a managed temporal payload type — an owned timestamp /
monotonic-clock handle suitable for use as a queue payload where the
producer needs to stamp an event and the consumer needs to observe
that stamp with the same lifetime guarantees as the rest of the
payload.

It is part of the managed-payload family (`ManagedRef`,
`ManagedSlice`, `Chronos`) and follows the same single-owner,
move-tracked lifecycle.

## See also

- [ManagedRef](managed_ref.md), [ManagedSlice](managed_slice.md) —
  sibling managed payload types.
- [SMR / nebr](smr/nebr.md) — the reclamation backend.

::: lockfree/chronos

## Optional: chronos async-adapter integration build

`src/lockfree/chronos.nim` ALSO ships the
[chronos](https://github.com/status-im/nim-chronos) async-adapter
surface (`AsyncQueue` / `AsyncBQueue`) for callers who want an `await`-
shaped pop on top of the lock-free queues. The adapter is flag-only
opt-in (CRITICAL-4): the library never auto-detects chronos, and never
pulls it in transitively. To enable the adapter, install chronos in the
supported version range AND build with the `lockfreeChronos` define:

```bash
nimble install "chronos >= 4.0.0, < 5.0.0"
nim c -d:lockfreeChronos --threads:on --mm:orc your_app.nim
```

Both pieces are required:

- Building with `-d:lockfreeChronos` without chronos installed emits a
  compile-time `{.error: ...}` that points back to this section and
  the `nimble install` command above.
- Building without the flag skips the adapter entirely; the
  `AsyncQueue` / `AsyncBQueue` exports are invisible and chronos is
  NOT pulled in.

`lockfree.nimble` carries a `when defined(lockfreeChronos): requires
"chronos >= 4.0.0 & < 5.0.0"` conditional dep so downstream users who
pass the define get the version constraint enforced by nimble's
resolver.
