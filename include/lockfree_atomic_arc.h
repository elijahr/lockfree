/**
 * @file lockfree_atomic_arc.h
 * @brief Standalone C99/C11 Header for Lock-Free 128-Bit DWCAS AtomicArc & ArcGuard
 *
 * Exposes `AtomicArc[pointer]` (`lf_atomic_arc_t`) and `ArcGuard[pointer]`
 * (`lf_arc_guard_t`) across the C ABI boundary (`lfq_atomic_arc_*` and
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

#ifndef LF_STATUS_DEFINED
#define LF_STATUS_DEFINED
typedef enum lf_status {
    LF_ERR_PANIC           = -2,
    LF_ERR_FAILURE         = -1,
    LF_OK                  =  0,
    LF_ERR_EMPTY           =  1,
    LF_ERR_FULL            =  2,
    LF_ERR_CLOSED          =  3,
    LF_ERR_INVALID_ARG     =  4,
    LF_ERR_REGISTRY_FULL   =  5,
    LF_ERR_UNSUPPORTED     =  6
} lf_status_t;

#ifndef LFQ_STATUS_DEFINED
#define LFQ_STATUS_DEFINED
#define lfq_status_t lf_status_t
#define lfq_status lf_status
#define LFQ_OK                  LF_OK
#define LFQ_ERR_EMPTY           LF_ERR_EMPTY
#define LFQ_ERR_FULL            LF_ERR_FULL
#define LFQ_ERR_CLOSED          LF_ERR_CLOSED
#define LFQ_ERR_INVALID_ARG     LF_ERR_INVALID_ARG
#define LFQ_ERR_REGISTRY_FULL   LF_ERR_REGISTRY_FULL
#define LFQ_ERR_UNSUPPORTED     LF_ERR_UNSUPPORTED
#define LFQ_ERR_FAILURE         LF_ERR_FAILURE
#define LFQ_ERR_PANIC           LF_ERR_PANIC
#endif
#endif

typedef void (*lf_arc_destructor_fn)(void* item, void* user_data);
#define lfq_arc_destructor_fn lf_arc_destructor_fn

/* ==========================================================================
 * 2. Opaque Handles (lf_atomic_arc_t & lf_arc_guard_t)
 * ========================================================================== */

/**
 * @brief Opaque handle to a lock-free 128-bit DWCAS split-reference-counted
 *        atomic shared pointer (`AtomicArc[pointer]`).
 */
typedef struct lf_atomic_arc lf_atomic_arc_t;
#define lfq_atomic_arc lf_atomic_arc
#define lfq_atomic_arc_t lf_atomic_arc_t

/**
 * @brief Opaque handle to a reference-counted guard (`ArcGuard[pointer]`)
 *        keeping the underlying payload alive until released.
 */
typedef struct lf_arc_guard lf_arc_guard_t;
#define lfq_arc_guard lf_arc_guard
#define lfq_arc_guard_t lf_arc_guard_t

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
lf_status_t lf_arc_guard_create(
    void* item,
    lf_arc_destructor_fn destructor,
    void* user_data,
    lf_arc_guard_t** out_guard
);
#define lfq_arc_guard_create lf_arc_guard_create

/**
 * @brief Returns the raw payload pointer protected by `guard`, or NULL if
 *        `guard` is NULL or empty.
 */
void* lf_arc_guard_get(const lf_arc_guard_t* guard);
#define lfq_arc_guard_get lf_arc_guard_get

/**
 * @brief Clones `guard`, atomically incrementing the underlying control block's
 *        reference count and returning a new independent `lf_arc_guard_t*`.
 *
 * @param guard     Source guard handle (may be NULL).
 * @param out_clone Out-pointer receiving the cloned guard handle.
 * @return LFQ_OK on success, or LFQ_ERR_INVALID_ARG.
 */
lf_status_t lf_arc_guard_clone(
    const lf_arc_guard_t* guard,
    lf_arc_guard_t** out_clone
);
#define lfq_arc_guard_clone lf_arc_guard_clone

/**
 * @brief Releases `guard`, decrementing the control block's reference count
 *        and invoking its destructor if the total reference count reaches zero.
 *
 * @param guard Guard handle to release (no-op if NULL, returns LFQ_OK).
 * @return LFQ_OK on success.
 */
lf_status_t lf_arc_guard_release(lf_arc_guard_t* guard);
#define lfq_arc_guard_release lf_arc_guard_release

/* ==========================================================================
 * 4. AtomicArc Lifecycle & Lock-Free DWCAS Operations (lfq_atomic_arc_*)
 * ========================================================================== */

/**
 * @brief Creates a new lock-free `lf_atomic_arc_t` initialized with `initial_item`.
 *
 * @param initial_item Initial pointer payload (pass NULL for an empty AtomicArc).
 * @param destructor   Optional callback invoked when `initial_item`'s control
 *                     block reaches zero references.
 * @param user_data    Opaque context pointer passed to `destructor`.
 * @param out_arc      Out-pointer receiving the allocated AtomicArc handle.
 * @return LFQ_OK on success, or LFQ_ERR_INVALID_ARG / LFQ_ERR_FAILURE.
 */
lf_status_t lf_atomic_arc_create(
    void* initial_item,
    lf_arc_destructor_fn destructor,
    void* user_data,
    lf_atomic_arc_t** out_arc
);
#define lfq_atomic_arc_create lf_atomic_arc_create

/**
 * @brief Destroys `arc` and releases its slot reference to the currently
 *        installed control block. Any live `lf_arc_guard_t` handles acquired
 *        prior to destruction remain valid until individually released.
 *
 * @param arc AtomicArc handle to destroy.
 * @return LFQ_OK on success, or LFQ_ERR_INVALID_ARG if `arc` is NULL.
 */
lf_status_t lf_atomic_arc_destroy(lf_atomic_arc_t* arc);
#define lfq_atomic_arc_destroy lf_atomic_arc_destroy

/**
 * @brief Returns true if `arc` is NULL or currently holds a NULL payload.
 */
bool lf_atomic_arc_is_null(const lf_atomic_arc_t* arc);
#define lfq_atomic_arc_is_null lf_atomic_arc_is_null

/**
 * @brief Atomically loads an `lf_arc_guard_t` from `arc` using 128-bit DWCAS.
 *        If `arc` currently holds NULL, `*out_guard` is set to NULL and
 *        `LFQ_OK` is returned.
 *
 * @param arc       AtomicArc handle.
 * @param out_guard Out-pointer receiving the acquired guard (or NULL if empty).
 * @return LFQ_OK on success, or LFQ_ERR_INVALID_ARG.
 */
lf_status_t lf_atomic_arc_load(
    const lf_atomic_arc_t* arc,
    lf_arc_guard_t** out_guard
);
#define lfq_atomic_arc_load lf_atomic_arc_load

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
lf_status_t lf_atomic_arc_store(
    lf_atomic_arc_t* arc,
    void* new_item,
    lf_arc_destructor_fn destructor,
    void* user_data
);
#define lfq_atomic_arc_store lf_atomic_arc_store

/**
 * @brief Atomically stores an existing `guard` into `arc` (sharing ownership of
 *        `guard`'s control block, or clearing `arc` if `guard == NULL`).
 *
 * @param arc   AtomicArc handle.
 * @param guard Guard whose control block will be installed (remains valid).
 * @return LFQ_OK on success, or LFQ_ERR_INVALID_ARG.
 */
lf_status_t lf_atomic_arc_store_guard(
    lf_atomic_arc_t* arc,
    const lf_arc_guard_t* guard
);
#define lfq_atomic_arc_store_guard lf_atomic_arc_store_guard

/**
 * @brief Allocates a new control block for `new_item` (or NULL if
 *        `new_item == NULL`), atomically swaps it into `arc`, and returns the
 *        previous value as an `lf_arc_guard_t*` in `*out_old_guard`.
 *
 * @param arc           AtomicArc handle.
 * @param new_item      New pointer payload (or NULL).
 * @param destructor    Optional destructor callback for `new_item`.
 * @param user_data     Opaque context pointer passed to `destructor`.
 * @param out_old_guard Out-pointer receiving the displaced guard (or NULL if
 *                      previous slot was empty).
 * @return LFQ_OK on success, or LFQ_ERR_INVALID_ARG.
 */
lf_status_t lf_atomic_arc_swap(
    lf_atomic_arc_t* arc,
    void* new_item,
    lf_arc_destructor_fn destructor,
    void* user_data,
    lf_arc_guard_t** out_old_guard
);
#define lfq_atomic_arc_swap lf_atomic_arc_swap

/**
 * @brief Atomically swaps `guard` into `arc` and returns the previous value as
 *        an `lf_arc_guard_t*` in `*out_old_guard`.
 *
 * @param arc           AtomicArc handle.
 * @param guard         Guard to install into `arc` (may be NULL).
 * @param out_old_guard Out-pointer receiving the displaced guard (or NULL).
 * @return LFQ_OK on success, or LFQ_ERR_INVALID_ARG.
 */
lf_status_t lf_atomic_arc_swap_guard(
    lf_atomic_arc_t* arc,
    const lf_arc_guard_t* guard,
    lf_arc_guard_t** out_old_guard
);
#define lfq_atomic_arc_swap_guard lf_atomic_arc_swap_guard

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
lf_status_t lf_atomic_arc_compare_exchange_guard(
    lf_atomic_arc_t* arc,
    lf_arc_guard_t** inout_expected,
    const lf_arc_guard_t* desired,
    bool* out_swapped
);
#define lfq_atomic_arc_compare_exchange_guard lf_atomic_arc_compare_exchange_guard

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
lf_status_t lf_atomic_arc_compare_exchange(
    lf_atomic_arc_t* arc,
    lf_arc_guard_t** inout_expected,
    void* desired_item,
    lf_arc_destructor_fn destructor,
    void* user_data,
    bool* out_swapped
);
#define lfq_atomic_arc_compare_exchange lf_atomic_arc_compare_exchange

#ifdef __cplusplus
}
#endif

#endif /* LOCKFREE_ATOMIC_ARC_H */
