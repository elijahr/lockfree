/**
 * @file lockfree_bstack.h
 * @brief Standalone C99/C11 Header for Preallocated Zero-SMR Bounded Lock-Free Stack
 *
 * Exposes `BStack[T, Cap]` across the C ABI boundary (`lfq_bstack_*`),
 * providing a preallocated, zero-SMR, zero-hot-path-heap-allocation MPMC LIFO
 * stack with 64-bit ABA-tagged index CAS, an integrated Elimination-Backoff
 * Array, and optional payload cleanup callbacks upon clear/destruction.
 */

#ifndef LOCKFREE_BSTACK_H
#define LOCKFREE_BSTACK_H

#include <stddef.h>
#include <stdint.h>
#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

/* ==========================================================================
 * 1. Status Codes & Callback Types (Shared with lockfree.h)
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

/**
 * @brief Optional cleanup callback invoked for remaining payloads when the
 * bounded stack is cleared or destroyed.
 */
typedef void (*lfq_bstack_destructor_fn)(void* item, void* user_data);

/* ==========================================================================
 * 2. Opaque Handle & C ABI Operations (lfq_bstack_*)
 * ========================================================================== */

/**
 * @brief Opaque handle to a preallocated zero-SMR bounded lock-free LIFO stack.
 */
typedef struct lfq_bstack lfq_bstack_t;

/**
 * @brief Creates a new preallocated bounded lock-free LIFO stack.
 *
 * @param capacity   Maximum number of elements (`1 .. 65536`).
 * @param destructor Optional callback invoked on remaining items during clear/destroy (may be NULL).
 * @param user_data  Optional opaque user context passed to destructor (may be NULL).
 * @param out_stack  Out-pointer receiving the allocated bounded stack handle.
 * @return LFQ_OK on success, LFQ_ERR_INVALID_ARG if `capacity == 0` or `out_stack == NULL`,
 *         or LFQ_ERR_UNSUPPORTED if `capacity > 65536`.
 */
lfq_status_t lfq_bstack_create(
    size_t capacity,
    lfq_bstack_destructor_fn destructor,
    void* user_data,
    lfq_bstack_t** out_stack
);

/**
 * @brief Destroys a bounded stack, invoking `destructor` (if non-NULL) on any
 * remaining items and releasing the preallocated storage block.
 *
 * @param stack Bounded stack handle.
 * @return LFQ_OK on success, or LFQ_ERR_INVALID_ARG if `stack == NULL`.
 */
lfq_status_t lfq_bstack_destroy(lfq_bstack_t* stack);

/**
 * @brief Pushes `item` onto the top of the bounded stack without heap allocation.
 *
 * @param stack Bounded stack handle.
 * @param item  Opaque payload pointer (`void*`).
 * @return LFQ_OK on success, LFQ_ERR_FULL if the stack is at capacity,
 *         or LFQ_ERR_INVALID_ARG if `stack == NULL`.
 */
lfq_status_t lfq_bstack_push(
    lfq_bstack_t* stack,
    void* item
);

/**
 * @brief Pops the top item from the bounded stack in LIFO order.
 *
 * @param stack    Bounded stack handle.
 * @param out_item Out-pointer receiving the popped payload (`void*`).
 * @return LFQ_OK if an item was popped, LFQ_ERR_EMPTY if the stack is empty,
 *         or LFQ_ERR_INVALID_ARG if `stack == NULL` or `out_item == NULL`.
 */
lfq_status_t lfq_bstack_pop(
    lfq_bstack_t* stack,
    void** out_item
);

/**
 * @brief Inspects the top item of the bounded stack without removing it.
 *
 * @param stack    Bounded stack handle.
 * @param out_item Out-pointer receiving the top payload (`void*`).
 * @return LFQ_OK if an item was observed, LFQ_ERR_EMPTY if the stack is empty,
 *         or LFQ_ERR_INVALID_ARG if `stack == NULL` or `out_item == NULL`.
 */
lfq_status_t lfq_bstack_peek(
    const lfq_bstack_t* stack,
    void** out_item
);

/**
 * @brief Pops up to `max_count` items in LIFO order into `out_items`.
 *
 * @param stack     Bounded stack handle.
 * @param out_items Caller-allocated array of at least `max_count` `void*` slots.
 * @param max_count Maximum number of items to drain.
 * @return Number of items drained (`0` if empty or invalid arguments).
 */
size_t lfq_bstack_drain(
    lfq_bstack_t* stack,
    void** out_items,
    size_t max_count
);

/**
 * @brief Removes all items from the bounded stack (invoking `destructor` if
 * configured) and returns all slots to the preallocated free pool.
 *
 * @param stack Bounded stack handle.
 * @return LFQ_OK on success, or LFQ_ERR_INVALID_ARG if `stack == NULL`.
 */
lfq_status_t lfq_bstack_clear(lfq_bstack_t* stack);

/**
 * @brief Returns the current number of items in the bounded stack (`0 .. capacity`).
 */
size_t lfq_bstack_len(const lfq_bstack_t* stack);

/**
 * @brief Returns the configured capacity of the bounded stack (`0` if `stack == NULL`).
 */
size_t lfq_bstack_capacity(const lfq_bstack_t* stack);

/**
 * @brief Returns `true` if the bounded stack is empty or `NULL`.
 */
bool lfq_bstack_is_empty(const lfq_bstack_t* stack);

/**
 * @brief Returns `true` if all preallocated slots are in use (`false` if `stack == NULL`).
 */
bool lfq_bstack_is_full(const lfq_bstack_t* stack);

#ifdef __cplusplus
}
#endif

#endif /* LOCKFREE_BSTACK_H */
