# Examples

Runnable example programs demonstrating `lockfree`'s queues, SMR, and
endpoint API. Each example compiles standalone via the
examples-compile-only CI cell, so any drift between the examples and
the public API surfaces at PR time.

## Mapping to the v0.1.0 docs

The umbrella v0.1.0 design (§7.1.1) sketches an 8-slot example tree.
The existing examples already cover the conceptual ground; the table
below maps the design slots to the shipping files.

| Design slot | Shipping file | Demonstrates |
|---|---|---|
| 01_spsc_basic | [`spsc.nim`](spsc.nim) | Bounded SPSC, `newSpscQueue[int, N]()`, `push` / `pop`. |
| 02_mpmc_unbounded | [`mpmc.nim`](mpmc.nim) (bounded MPMC), [`event_collector.nim`](event_collector.nim) (unbounded MPSC) | Multi-cardinality endpoints, `getProducerHere`/`getConsumerHere`. |
| 03_managed_ref | [`job_scheduler.nim`](job_scheduler.nim) | `ref T` / `ptr T` payload patterns through unbounded MPMC. |
| 04_managed_slice | (pending PG-7) | `string` / `seq[T]` payloads via Path C. |
| 05_typestate_dual_api | [`event_collector.nim`](event_collector.nim), [`mpsc.nim`](mpsc.nim) | `Unbound → Bound → Closed` lifecycle. |
| 06_chronos_async | (pending PG-8) | Async endpoint via `-d:lockfreeChronos`. |
| 07_drain_strict | (pending PG-7) | `destroyAndDrain` strict-contract cleanup. |
| 08_mm_none_audio | [`audio_buffer.nim`](audio_buffer.nim) | Real-time audio pattern; bounded SPSC. (Compile under `--mm:none` for the strict-bit-transport demo.) |

The pending slots are gated on PG-7 / PG-8 implementation completion;
they will be added as numbered `0N_*.nim` files once the API surfaces
they exercise (`ManagedSlice`, `destroyAndDrain`, the chronos adapter)
are stable in the lifted source tree.

## Per-file index

| File | Cardinality | Boundedness | MM tested |
|---|---|---|---|
| [`spsc.nim`](spsc.nim) | SPSC | Bounded | All |
| [`spmc.nim`](spmc.nim) | SPMC | Bounded | All |
| [`mpsc.nim`](mpsc.nim) | MPSC | Bounded | All |
| [`mpmc.nim`](mpmc.nim) | MPMC | Bounded | All |
| [`audio_buffer.nim`](audio_buffer.nim) | SPSC | Bounded | `none`-friendly |
| [`task_fanout.nim`](task_fanout.nim) | SPMC | Unbounded | All |
| [`event_collector.nim`](event_collector.nim) | MPSC | Unbounded | All |
| [`job_scheduler.nim`](job_scheduler.nim) | MPMC | Unbounded | All |
| [`debra_cc_helpers.nim`](debra_cc_helpers.nim) | n/a (SMR primitive) | n/a | All |

## Running an example

```sh
nimble examples
```

Or run a single file directly:

```sh
nim c --threads:on -r examples/spsc.nim
```

For the `--mm:none` audio pattern:

```sh
nim c --threads:on --mm:none -r examples/audio_buffer.nim
```

## Further reading

- [Guide / getting started](../docs/guide/getting-started.md) — the install + first program.
- [Guide / queues](../docs/guide/queues/index.md) — the cardinality chooser.
- [Guide / managed-ref](../docs/guide/managed-ref.md) — `ref T` payloads.
- [Guide / typestates](../docs/guide/typestates.md) — endpoint lifecycle.
