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

/**
 * @brief Optional cleanup callback invoked for remaining payloads when the
 * bounded priority queue is cleared or destroyed.
 */
typedef void (*lf_bpqueue_destructor_fn)(void* item, void* user_data);
#define lfq_bpqueue_destructor_fn lf_bpqueue_destructor_fn

/* ==========================================================================
 * 2. Opaque Handle & C ABI Operations (lfq_bpqueue_*)
 * ========================================================================== */

/**
 * @brief Opaque handle to a preallocated zero-SMR bounded concurrent min-priority queue.
 */
typedef struct lf_bpqueue lf_bpqueue_t;
#define lfq_bpqueue lf_bpqueue
#define lfq_bpqueue_t lf_bpqueue_t

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
lf_status_t lf_bpqueue_create(
    size_t capacity,
    lf_bpqueue_destructor_fn destructor,
    void* user_data,
    lf_bpqueue_t** out_bpqueue
);
#define lfq_bpqueue_create lf_bpqueue_create

/**
 * @brief Destroys a bounded priority queue, invoking `destructor` (if non-NULL)
 * on any remaining items and releasing the preallocated storage block.
 *
 * @param bpqueue Bounded priority queue handle.
 * @return LFQ_OK on success, or LFQ_ERR_INVALID_ARG if `bpqueue == NULL`.
 */
lf_status_t lf_bpqueue_destroy(lf_bpqueue_t* bpqueue);
#define lfq_bpqueue_destroy lf_bpqueue_destroy

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
lf_status_t lf_bpqueue_push(
    lf_bpqueue_t* bpqueue,
    int64_t priority,
    void* item
);
#define lfq_bpqueue_push lf_bpqueue_push

/**
 * @brief Atomically removes and returns the minimum-priority entry.
 *
 * @param bpqueue      Bounded priority queue handle.
 * @param out_priority Optional out-pointer receiving the popped priority (may be NULL).
 * @param out_item     Out-pointer receiving the popped payload pointer (`void*`).
 * @return LFQ_OK if an item was popped, LFQ_ERR_EMPTY if the queue is empty,
 *         or LFQ_ERR_INVALID_ARG if `bpqueue == NULL` or `out_item == NULL`.
 */
lf_status_t lf_bpqueue_pop_min(
    lf_bpqueue_t* bpqueue,
    int64_t* out_priority,
    void** out_item
);
#define lfq_bpqueue_pop_min lf_bpqueue_pop_min

/**
 * @brief Inspects the minimum-priority entry without removing it.
 *
 * @param bpqueue      Bounded priority queue handle.
 * @param out_priority Optional out-pointer receiving the minimum priority (may be NULL).
 * @param out_item     Out-pointer receiving the minimum payload pointer (`void*`).
 * @return LFQ_OK if an item was observed, LFQ_ERR_EMPTY if the queue is empty,
 *         or LFQ_ERR_INVALID_ARG if `bpqueue == NULL` or `out_item == NULL`.
 */
lf_status_t lf_bpqueue_peek_min(
    const lf_bpqueue_t* bpqueue,
    int64_t* out_priority,
    void** out_item
);
#define lfq_bpqueue_peek_min lf_bpqueue_peek_min

/**
 * @brief Clears all entries from the bounded priority queue (invoking the
 * configured `destructor`, if any, on each removed item).
 *
 * @param bpqueue Bounded priority queue handle.
 * @return LFQ_OK on success, or LFQ_ERR_INVALID_ARG if `bpqueue == NULL`.
 */
lf_status_t lf_bpqueue_clear(lf_bpqueue_t* bpqueue);
#define lfq_bpqueue_clear lf_bpqueue_clear

/**
 * @brief Returns the current number of active items in the bounded priority queue (`0 .. capacity`).
 */
size_t lf_bpqueue_len(const lf_bpqueue_t* bpqueue);
#define lfq_bpqueue_len lf_bpqueue_len

/**
 * @brief Returns the configured capacity of the bounded priority queue (`0` if `bpqueue == NULL`).
 */
size_t lf_bpqueue_capacity(const lf_bpqueue_t* bpqueue);
#define lfq_bpqueue_capacity lf_bpqueue_capacity

/**
 * @brief Returns `true` if the bounded priority queue is empty or `NULL`.
 */
bool lf_bpqueue_is_empty(const lf_bpqueue_t* bpqueue);
#define lfq_bpqueue_is_empty lf_bpqueue_is_empty

/**
 * @brief Returns `true` if the bounded priority queue has reached capacity (`false` if `bpqueue == NULL`).
 */
bool lf_bpqueue_is_full(const lf_bpqueue_t* bpqueue);
#define lfq_bpqueue_is_full lf_bpqueue_is_full

#ifdef __cplusplus
}
#endif

#endif /* LOCKFREE_BPQUEUE_H */
