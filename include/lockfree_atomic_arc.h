/**
 * @file lockfree_atomic_arc.h
 * @brief Standalone C99/C11 Header for Lock-Free 128-Bit DWCAS AtomicArc & ArcGuard
 *
 * Exposes `AtomicArc[pointer]` (`lfq_atomic_arc_t`) and `ArcGuard[pointer]`
 * (`lfq_arc_guard_t`) across the C ABI boundary (`lfq_atomic_arc_*` and
 * `lfq_arc_guard_*`), supporting wait-free / lock-free 128-bit DWCAS
 * split-reference-counted `load`, `store`, `swap`, and `compare_exchange`
 * with deterministic payload reclamation via optional destructor callbacks.
 */

#ifndef LOCKFREE_ATOMIC_ARC_H
#define LOCKFREE_ATOMIC_ARC_H

#include <stddef.h>
#include <stdint.h>
#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

/* ==========================================================================
 * 1. Status Codes & Destructor Callback (Shared with lockfree.h)
 * ========================================================================== */

#ifndef LFQ_STATUS_DEFINED
#define LFQ_STATUS_DEFINED
typedef enum lfq_status {
    LFQ_OK                  =  0,
    LFQ_ERR_EMPTY           =  1,
    LFQ_ERR_FULL            =  2,
    LFQ_ERR_CLOSED          =  3,
    LFQ_ERR_INVALID_ARG     =  4,
    LFQ_ERR_REGISTRY_FULL   =  5,
    LFQ_ERR_UNSUPPORTED     =  6,
    LFQ_ERR_FAILURE         = -1,
    LFQ_ERR_PANIC           = -2
} lfq_status_t;
#endif

typedef void (*lfq_arc_destructor_fn)(void* item, void* user_data);

/* ==========================================================================
 * 2. Opaque Handles (lfq_atomic_arc_t & lfq_arc_guard_t)
 * ========================================================================== */

/**
 * @brief Opaque handle to a lock-free 128-bit DWCAS split-reference-counted
 *        atomic shared pointer (`AtomicArc[pointer]`).
 */
typedef struct lfq_atomic_arc lfq_atomic_arc_t;

/**
 * @brief Opaque handle to a reference-counted guard (`ArcGuard[pointer]`)
 *        keeping the underlying payload alive until released.
 */
typedef struct lfq_arc_guard lfq_arc_guard_t;

/* ==========================================================================
 * 3. ArcGuard Lifecycle & Accessors (lfq_arc_guard_*)
 * ========================================================================== */

/**
 * @brief Allocates a standalone reference-counted guard owning `item`.
 *
 * @param item       Pointer payload to manage (may be NULL for an empty guard).
 * @param destructor Optional callback invoked when the last reference is released.
 * @param user_data  Opaque context pointer passed to `destructor`.
 * @param out_guard  Out-pointer receiving the created guard handle.
 * @return LFQ_OK on success, or LFQ_ERR_INVALID_ARG / LFQ_ERR_FAILURE.
 */
lfq_status_t lfq_arc_guard_create(
    void* item,
    lfq_arc_destructor_fn destructor,
    void* user_data,
    lfq_arc_guard_t** out_guard
);

/**
 * @brief Returns the raw payload pointer protected by `guard`, or NULL if
 *        `guard` is NULL or empty.
 */
void* lfq_arc_guard_get(const lfq_arc_guard_t* guard);

/**
 * @brief Clones `guard`, atomically incrementing the underlying control block's
 *        reference count and returning a new independent `lfq_arc_guard_t*`.
 *
 * @param guard     Source guard handle (may be NULL).
 * @param out_clone Out-pointer receiving the cloned guard handle.
 * @return LFQ_OK on success, or LFQ_ERR_INVALID_ARG.
 */
lfq_status_t lfq_arc_guard_clone(
    const lfq_arc_guard_t* guard,
    lfq_arc_guard_t** out_clone
);

/**
 * @brief Releases `guard`, decrementing the control block's reference count
 *        and invoking its destructor if the total reference count reaches zero.
 *
 * @param guard Guard handle to release (no-op if NULL, returns LFQ_OK).
 * @return LFQ_OK on success.
 */
lfq_status_t lfq_arc_guard_release(lfq_arc_guard_t* guard);

/* ==========================================================================
 * 4. AtomicArc Lifecycle & Lock-Free DWCAS Operations (lfq_atomic_arc_*)
 * ========================================================================== */

/**
 * @brief Creates a new lock-free `lfq_atomic_arc_t` initialized with `initial_item`.
 *
 * @param initial_item Initial pointer payload (pass NULL for an empty AtomicArc).
 * @param destructor   Optional callback invoked when `initial_item`'s control
 *                     block reaches zero references.
 * @param user_data    Opaque context pointer passed to `destructor`.
 * @param out_arc      Out-pointer receiving the allocated AtomicArc handle.
 * @return LFQ_OK on success, or LFQ_ERR_INVALID_ARG / LFQ_ERR_FAILURE.
 */
lfq_status_t lfq_atomic_arc_create(
    void* initial_item,
    lfq_arc_destructor_fn destructor,
    void* user_data,
    lfq_atomic_arc_t** out_arc
);

/**
 * @brief Destroys `arc` and releases its slot reference to the currently
 *        installed control block. Any live `lfq_arc_guard_t` handles acquired
 *        prior to destruction remain valid until individually released.
 *
 * @param arc AtomicArc handle to destroy.
 * @return LFQ_OK on success, or LFQ_ERR_INVALID_ARG if `arc` is NULL.
 */
lfq_status_t lfq_atomic_arc_destroy(lfq_atomic_arc_t* arc);

/**
 * @brief Returns true if `arc` is NULL or currently holds a NULL payload.
 */
bool lfq_atomic_arc_is_null(const lfq_atomic_arc_t* arc);

/**
 * @brief Atomically loads an `lfq_arc_guard_t` from `arc` using 128-bit DWCAS.
 *        If `arc` currently holds NULL, `*out_guard` is set to NULL and
 *        `LFQ_OK` is returned.
 *
 * @param arc       AtomicArc handle.
 * @param out_guard Out-pointer receiving the acquired guard (or NULL if empty).
 * @return LFQ_OK on success, or LFQ_ERR_INVALID_ARG.
 */
lfq_status_t lfq_atomic_arc_load(
    const lfq_atomic_arc_t* arc,
    lfq_arc_guard_t** out_guard
);

/**
 * @brief Allocates a new control block for `new_item` (or clears to NULL if
 *        `new_item == NULL`) and atomically stores it into `arc`.
 *
 * @param arc        AtomicArc handle.
 * @param new_item   New pointer payload (or NULL to clear the slot).
 * @param destructor Optional destructor callback for `new_item`.
 * @param user_data  Opaque context pointer passed to `destructor`.
 * @return LFQ_OK on success, or LFQ_ERR_INVALID_ARG.
 */
lfq_status_t lfq_atomic_arc_store(
    lfq_atomic_arc_t* arc,
    void* new_item,
    lfq_arc_destructor_fn destructor,
    void* user_data
);

/**
 * @brief Atomically stores an existing `guard` into `arc` (sharing ownership of
 *        `guard`'s control block, or clearing `arc` if `guard == NULL`).
 *
 * @param arc   AtomicArc handle.
 * @param guard Guard whose control block will be installed (remains valid).
 * @return LFQ_OK on success, or LFQ_ERR_INVALID_ARG.
 */
lfq_status_t lfq_atomic_arc_store_guard(
    lfq_atomic_arc_t* arc,
    const lfq_arc_guard_t* guard
);

/**
 * @brief Allocates a new control block for `new_item` (or NULL if
 *        `new_item == NULL`), atomically swaps it into `arc`, and returns the
 *        previous value as an `lfq_arc_guard_t*` in `*out_old_guard`.
 *
 * @param arc           AtomicArc handle.
 * @param new_item      New pointer payload (or NULL).
 * @param destructor    Optional destructor callback for `new_item`.
 * @param user_data     Opaque context pointer passed to `destructor`.
 * @param out_old_guard Out-pointer receiving the displaced guard (or NULL if
 *                      previous slot was empty).
 * @return LFQ_OK on success, or LFQ_ERR_INVALID_ARG.
 */
lfq_status_t lfq_atomic_arc_swap(
    lfq_atomic_arc_t* arc,
    void* new_item,
    lfq_arc_destructor_fn destructor,
    void* user_data,
    lfq_arc_guard_t** out_old_guard
);

/**
 * @brief Atomically swaps `guard` into `arc` and returns the previous value as
 *        an `lfq_arc_guard_t*` in `*out_old_guard`.
 *
 * @param arc           AtomicArc handle.
 * @param guard         Guard to install into `arc` (may be NULL).
 * @param out_old_guard Out-pointer receiving the displaced guard (or NULL).
 * @return LFQ_OK on success, or LFQ_ERR_INVALID_ARG.
 */
lfq_status_t lfq_atomic_arc_swap_guard(
    lfq_atomic_arc_t* arc,
    const lfq_arc_guard_t* guard,
    lfq_arc_guard_t** out_old_guard
);

/**
 * @brief Atomically compares the control block in `arc` against `*inout_expected`
 *        and, if equal, replaces it with `desired` (`*out_swapped = true`).
 *        If not equal, releases `*inout_expected`, updates `*inout_expected` to
 *        hold a guard to the current value of `arc` (or NULL if empty), and sets
 *        `*out_swapped = false`.
 *
 * @param arc            AtomicArc handle.
 * @param inout_expected Pointer to the expected guard handle; updated on mismatch.
 * @param desired        Desired guard handle to install on match (may be NULL).
 * @param out_swapped    Out-pointer receiving true on CAS success, false on mismatch.
 * @return LFQ_OK on success, or LFQ_ERR_INVALID_ARG.
 */
lfq_status_t lfq_atomic_arc_compare_exchange_guard(
    lfq_atomic_arc_t* arc,
    lfq_arc_guard_t** inout_expected,
    const lfq_arc_guard_t* desired,
    bool* out_swapped
);

/**
 * @brief Convenience `compare_exchange` that wraps `desired_item` in a new
 *        control block on match; if the CAS fails, `desired_item`'s control
 *        block (and its `destructor`, if non-NULL) is cleaned up immediately
 *        and `*inout_expected` is updated to the current guard.
 *
 * @param arc            AtomicArc handle.
 * @param inout_expected Pointer to the expected guard handle; updated on mismatch.
 * @param desired_item   Desired pointer payload (or NULL).
 * @param destructor     Optional destructor callback for `desired_item`.
 * @param user_data      Opaque context pointer passed to `destructor`.
 * @param out_swapped    Out-pointer receiving true on CAS success, false on mismatch.
 * @return LFQ_OK on success, or LFQ_ERR_INVALID_ARG.
 */
lfq_status_t lfq_atomic_arc_compare_exchange(
    lfq_atomic_arc_t* arc,
    lfq_arc_guard_t** inout_expected,
    void* desired_item,
    lfq_arc_destructor_fn destructor,
    void* user_data,
    bool* out_swapped
);

#ifdef __cplusplus
}
#endif

#endif /* LOCKFREE_ATOMIC_ARC_H */
