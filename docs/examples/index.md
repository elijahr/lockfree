# Examples

The `examples/` directory at the repo root holds runnable, single-file
demonstrations of the user-facing API surface. Each file is intentionally
small and focused; together they cover the four bounded cardinalities,
two unbounded cardinalities, debra cancellation-callbacks, an audio
ringbuffer pattern under `--mm:none`, a fan-out task scheduler, and an
event-collection pattern.

The §7.1.1 design canon names eight illustrative files
(`basic-queue.nim`, `ref-payload.nim`, `slice-payload.nim`,
`smr-only.nim`, `custom-types.nim`, `bounded-pipeline.nim`,
`nimony-compat.nim`, `mm-none-audio.nim`). The shipping repo retains
the lockfreequeues-era names below — the IA mapping is by topic, not
file name. See the per-example sections for the topic each one
demonstrates.

All examples build under `--threads:on --mm:arc` (the project default
since v0.1.0). See [Getting Started](../guide/getting-started.md) for
the full toolchain.

## Bounded queues (`BQueue[T, ccProd, ccCons, N, P, C]`)

### `examples/spsc.nim` — basic queue / single-producer single-consumer

Source: [`examples/spsc.nim`](https://github.com/elijahr/lockfree/blob/devel/examples/spsc.nim)

The minimal canonical intro. Single producer thread, single consumer
thread, `int` payload, capacity 8. Mirrors the §7.1.1 `basic-queue.nim`
slot.

### `examples/mpsc.nim` — multi-producer single-consumer pipeline

Source: [`examples/mpsc.nim`](https://github.com/elijahr/lockfree/blob/devel/examples/mpsc.nim)

Bounded MPSC pipeline pattern. N producer threads, one consumer
thread. Mirrors the §7.1.1 `bounded-pipeline.nim` slot.

### `examples/spmc.nim` — single-producer multi-consumer fan-out

Source: [`examples/spmc.nim`](https://github.com/elijahr/lockfree/blob/devel/examples/spmc.nim)

Bounded SPMC fan-out pattern. One producer thread, N consumer threads.

### `examples/mpmc.nim` — multi-producer multi-consumer

Source: [`examples/mpmc.nim`](https://github.com/elijahr/lockfree/blob/devel/examples/mpmc.nim)

The fully symmetric bounded case with per-thread producer and consumer
endpoints via `getProducerHere()` / `getConsumerHere()`.

## Specialised patterns

### `examples/audio_buffer.nim` — ringbuffer under `--mm:none`

Source: [`examples/audio_buffer.nim`](https://github.com/elijahr/lockfree/blob/devel/examples/audio_buffer.nim)

Real-time audio processing pattern: fixed latency, no allocation, wait-
free push/pop. Mirrors the §7.1.1 `mm-none-audio.nim` slot.

### `examples/event_collector.nim` — collecting events into a sink

Source: [`examples/event_collector.nim`](https://github.com/elijahr/lockfree/blob/devel/examples/event_collector.nim)

Demonstrates using a queue as a typed event sink across threads.
Touches the `ref T` and `seq[U]` Path-C payload arms.

### `examples/job_scheduler.nim` — bounded job scheduling

Source: [`examples/job_scheduler.nim`](https://github.com/elijahr/lockfree/blob/devel/examples/job_scheduler.nim)

Worker-pool pattern with bounded backpressure. Touches the
custom-types Path-C admit arm.

### `examples/task_fanout.nim` — task fan-out

Source: [`examples/task_fanout.nim`](https://github.com/elijahr/lockfree/blob/devel/examples/task_fanout.nim)

Companion to `spmc.nim` showing a richer fan-out workload with
heterogeneous task types.

### `examples/debra_cc_helpers.nim` — nebr cancellation callbacks

Source: [`examples/debra_cc_helpers.nim`](https://github.com/elijahr/lockfree/blob/devel/examples/debra_cc_helpers.nim)

Demonstrates `lockfree/smr/nebr` reclamation callbacks outside the
queue context. Mirrors the §7.1.1 `smr-only.nim` slot.

## §7.1.1 mapping summary

| §7.1.1 canonical name | Shipping example |
|---|---|
| `basic-queue.nim` | `spsc.nim` |
| `ref-payload.nim` | (use any of `mpmc.nim` / `event_collector.nim`; the `ref T` admit arm is covered by tests/composition/t_path_c_matrix.nim) |
| `slice-payload.nim` | (the string/seq admit arms are covered by tests/composition/t_path_c_matrix.nim and tests/t_managed_slice.nim) |
| `smr-only.nim` | `debra_cc_helpers.nim` |
| `custom-types.nim` | `job_scheduler.nim` |
| `bounded-pipeline.nim` | `mpsc.nim` |
| `nimony-compat.nim` | (gated on nimony port; see `guide/nimony.md`) |
| `mm-none-audio.nim` | `audio_buffer.nim` |

The §7.1.1 names were the design-time slot list; the shipping names
above are the topical demonstrations actually present in `examples/`.
A future doc-cleanup pass may rename the shipping files to match the
canon, or backfill the missing canonical names if user demand surfaces.
