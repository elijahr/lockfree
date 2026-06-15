# API Reference

!!! info "Frozen historical mirror"
    This page is part of the **nim-debra T0 documentation mirror** (see
    [Provenance](PROVENANCE.md)). The standalone `debra` package no longer
    exists — it was consolidated into the lockfree umbrella as
    `lockfree/smr/nebr` at the T0 merge point. Because there is no `debra`
    package to introspect, the auto-generated API tables that once lived on
    this page cannot be regenerated and have been replaced with this pointer.

    For the **live, supported SMR API**, see:

    - [SMR API reference — `lockfree/smr/nebr`](../../api/smr/nebr.md)
    - [SMR guide — `nebr`](../../guide/smr/nebr.md)

The sections below record the public surface that the original
`debra` package exposed at the consolidation point. Each maps to the
current `lockfree/smr/nebr` module; consult the live API reference above
for the up-to-date, auto-extracted signatures.

## Atomics

Custom atomics module with compile-time lock-free guarantees, per-op
memory-order validation, and DWCAS (16-byte / 128-bit) atomics via
`Atomic[Pair[A, B]]`. Now part of lockfree as
[`lockfree/atomics`](../../api/atomics.md); see
[guide/atomics.md](guide/atomics.md) for the narrative overview.

---

## Main Module

DEBRA+ manager, thread registration, pin/unpin, retire, and reclamation
entry points. Now part of lockfree as
[`lockfree/smr/nebr`](../../api/smr/nebr.md).

---

## Core Types

Type definitions for the DEBRA+ manager and thread state.

---

## Constants

Configuration constants for the DEBRA+ algorithm.

---

## Limbo Bags

Data structures for thread-local retire queues.

---

## Signal Handling

POSIX signal handling for the neutralization protocol.

---

## Typestates

The original `debra.typestates.*` modules enforced the DEBRA+ protocol at
compile time. The equivalent live typestates ship with lockfree; see the
[SMR API reference](../../api/smr/nebr.md).

### Signal Handler

Signal handler installation lifecycle.

---

### Manager

Manager initialization and shutdown lifecycle.

---

### Registration

Thread registration lifecycle.

---

### Thread Slot

Thread slot allocation and release.

---

### Epoch Guard

Pin/unpin critical section lifecycle.

---

### Retire

Object retirement to limbo bags.

---

### Reclamation

Safe memory reclamation from limbo bags.

---

### Neutralization

Thread neutralization protocol.

---

### Epoch Advance

Global epoch advancement.
