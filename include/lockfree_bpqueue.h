/**
 * @file lockfree_bpqueue.h
 * @brief Standalone C99/C11 Header for Preallocated Zero-SMR Bounded Priority Queue
 *
 * Exposes `BPriorityQueue[T, Cap]` across the C ABI boundary (`lfq_bpqueue_*`),
 * providing a preallocated, zero-SMR, zero-hot-path-heap-allocation concurrent
 * min-priority queue with 64-bit signed integer priority keys, `void*` payloads,
 * strict FIFO tie-breaking for equal priorities, and optional payload cleanup
 * callbacks upon clear/destruction.
 */

#ifndef LOCKFREE_BPQUEUE_H
#define LOCKFREE_BPQUEUE_H

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
 * bounded priority queue is cleared or destroyed.
 */
typedef void (*lfq_bpqueue_destructor_fn)(void* item, void* user_data);

/* ==========================================================================
 * 2. Opaque Handle & C ABI Operations (lfq_bpqueue_*)
 * ========================================================================== */

/**
 * @brief Opaque handle to a preallocated zero-SMR bounded concurrent min-priority queue.
 */
typedef struct lfq_bpqueue lfq_bpqueue_t;

/**
 * @brief Creates a new preallocated bounded concurrent min-priority queue.
 *
 * @param capacity    Maximum number of entries (`1 .. 65536`).
 * @param destructor  Optional callback invoked on remaining items during clear/destroy (may be NULL).
 * @param user_data   Optional opaque user context passed to destructor (may be NULL).
 * @param out_bpqueue Out-pointer receiving the allocated bounded priority queue handle.
 * @return LFQ_OK on success, LFQ_ERR_INVALID_ARG if `capacity == 0` or `out_bpqueue == NULL`,
 *         or LFQ_ERR_UNSUPPORTED if `capacity > 65536`.
 */
lfq_status_t lfq_bpqueue_create(
    size_t capacity,
    lfq_bpqueue_destructor_fn destructor,
    void* user_data,
    lfq_bpqueue_t** out_bpqueue
);

/**
 * @brief Destroys a bounded priority queue, invoking `destructor` (if non-NULL)
 * on any remaining items and releasing the preallocated storage block.
 *
 * @param bpqueue Bounded priority queue handle.
 * @return LFQ_OK on success, or LFQ_ERR_INVALID_ARG if `bpqueue == NULL`.
 */
lfq_status_t lfq_bpqueue_destroy(lfq_bpqueue_t* bpqueue);

/**
 * @brief Inserts a `(priority, item)` entry into the bounded priority queue
 * without heap allocation. Lower numerical `priority` values are popped first
 * (min-priority queue). Equal `priority` entries are popped in strict FIFO
 * insertion order.
 *
 * @param bpqueue  Bounded priority queue handle.
 * @param priority 64-bit signed priority key (lower = higher priority).
 * @param item     Opaque payload pointer (`void*`).
 * @return LFQ_OK on success, LFQ_ERR_FULL if `len == capacity`,
 *         or LFQ_ERR_INVALID_ARG if `bpqueue == NULL`.
 */
lfq_status_t lfq_bpqueue_push(
    lfq_bpqueue_t* bpqueue,
    int64_t priority,
    void* item
);

/**
 * @brief Atomically removes and returns the minimum-priority entry.
 *
 * @param bpqueue      Bounded priority queue handle.
 * @param out_priority Optional out-pointer receiving the popped priority (may be NULL).
 * @param out_item     Out-pointer receiving the popped payload pointer (`void*`).
 * @return LFQ_OK if an item was popped, LFQ_ERR_EMPTY if the queue is empty,
 *         or LFQ_ERR_INVALID_ARG if `bpqueue == NULL` or `out_item == NULL`.
 */
lfq_status_t lfq_bpqueue_pop_min(
    lfq_bpqueue_t* bpqueue,
    int64_t* out_priority,
    void** out_item
);

/**
 * @brief Inspects the minimum-priority entry without removing it.
 *
 * @param bpqueue      Bounded priority queue handle.
 * @param out_priority Optional out-pointer receiving the minimum priority (may be NULL).
 * @param out_item     Out-pointer receiving the minimum payload pointer (`void*`).
 * @return LFQ_OK if an item was observed, LFQ_ERR_EMPTY if the queue is empty,
 *         or LFQ_ERR_INVALID_ARG if `bpqueue == NULL` or `out_item == NULL`.
 */
lfq_status_t lfq_bpqueue_peek_min(
    const lfq_bpqueue_t* bpqueue,
    int64_t* out_priority,
    void** out_item
);

/**
 * @brief Clears all entries from the bounded priority queue (invoking the
 * configured `destructor`, if any, on each removed item).
 *
 * @param bpqueue Bounded priority queue handle.
 * @return LFQ_OK on success, or LFQ_ERR_INVALID_ARG if `bpqueue == NULL`.
 */
lfq_status_t lfq_bpqueue_clear(lfq_bpqueue_t* bpqueue);

/**
 * @brief Returns the current number of active items in the bounded priority queue (`0 .. capacity`).
 */
size_t lfq_bpqueue_len(const lfq_bpqueue_t* bpqueue);

/**
 * @brief Returns the configured capacity of the bounded priority queue (`0` if `bpqueue == NULL`).
 */
size_t lfq_bpqueue_capacity(const lfq_bpqueue_t* bpqueue);

/**
 * @brief Returns `true` if the bounded priority queue is empty or `NULL`.
 */
bool lfq_bpqueue_is_empty(const lfq_bpqueue_t* bpqueue);

/**
 * @brief Returns `true` if the bounded priority queue has reached capacity (`false` if `bpqueue == NULL`).
 */
bool lfq_bpqueue_is_full(const lfq_bpqueue_t* bpqueue);

#ifdef __cplusplus
}
#endif

#endif /* LOCKFREE_BPQUEUE_H */
