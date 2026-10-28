/**
 * @file lockfree_bqueue128.h
 * @brief Standalone C99/C11 Header for 128-Bit DWCAS Bounded MPMC Queue
 *
 * Exposes `BQueue128[T, N]` across the C ABI boundary (`lf_bqueue128_*` and `lfq_bqueue128_*`),
 * providing a 128-bit hardware Double-Word Compare-And-Swap (DWCAS) bounded MPMC queue.
 * Each slot is a single 16-byte atomic word storing both sequence turn counter and 64-bit payload,
 * enabling single-instruction atomic slot publication without intermediate partial-write states.
 */

#ifndef LOCKFREE_BQUEUE128_H
#define LOCKFREE_BQUEUE128_H

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
 * bounded queue is cleared or destroyed.
 */
typedef void (*lf_bqueue128_destructor_fn)(void* item, void* user_data);
#define lfq_bqueue128_destructor_fn lf_bqueue128_destructor_fn

/* ==========================================================================
 * 2. Opaque Handle & C ABI Operations (lf_bqueue128_* / lfq_bqueue128_*)
 * ========================================================================== */

/**
 * @brief Opaque handle to a 128-bit DWCAS bounded lock-free MPMC queue.
 */
typedef struct lf_bqueue128 lf_bqueue128_t;
#define lfq_bqueue128 lf_bqueue128
#define lfq_bqueue128_t lf_bqueue128_t

/**
 * @brief Creates a new 128-bit DWCAS bounded lock-free MPMC queue.
 *
 * @param capacity   Maximum power-of-two capacity (`4 .. 65536`).
 * @param destructor Optional callback invoked on remaining items during clear/destroy (may be NULL).
 * @param user_data  Optional opaque user context passed to destructor (may be NULL).
 * @param out_queue  Out-pointer receiving the allocated bounded queue handle.
 * @return LF_OK on success, LF_ERR_INVALID_ARG if `capacity == 0` or `out_queue == NULL`,
 *         or LF_ERR_UNSUPPORTED if `capacity > 65536`.
 */
lf_status_t lf_bqueue128_create(
    size_t capacity,
    lf_bqueue128_destructor_fn destructor,
    void* user_data,
    lf_bqueue128_t** out_queue
);
#define lfq_bqueue128_create lf_bqueue128_create

/**
 * @brief Destroys a 128-bit DWCAS bounded queue, invoking `destructor` (if non-NULL)
 * on any remaining items and releasing memory.
 *
 * @param queue Bounded queue handle.
 * @return LF_OK on success, or LF_ERR_INVALID_ARG if `queue == NULL`.
 */
lf_status_t lf_bqueue128_destroy(lf_bqueue128_t* queue);
#define lfq_bqueue128_destroy lf_bqueue128_destroy

/**
 * @brief Attempts to enqueue an item using a single atomic 128-bit CAS.
 *
 * @param queue Bounded queue handle.
 * @param item  Payload pointer to enqueue.
 * @return LF_OK on success, LF_ERR_FULL if the queue is full, or LF_ERR_INVALID_ARG.
 */
lf_status_t lf_bqueue128_push(lf_bqueue128_t* queue, void* item);
#define lfq_bqueue128_push lf_bqueue128_push

/**
 * @brief Attempts to enqueue an item using a single atomic 128-bit CAS and
 * reports whether the queue transitioned from empty (0) to 1 item.
 *
 * Compares the consumer `head` cursor against the producer's claimed ticket
 * `pos` (`head >= pos`) after a sequentially-consistent StoreLoad barrier,
 * guaranteeing that at least one concurrent producer in an empty-to-nonempty
 * epoch observes `*out_was_empty = true` when the lowest-ticket producer
 * publishes.
 *
 * @param queue         Bounded queue handle.
 * @param item          Payload pointer to enqueue.
 * @param out_was_empty Optional out-pointer set to true if the queue was empty prior to this push (may be NULL).
 * @return LF_OK on success, LF_ERR_FULL if the queue is full, or LF_ERR_INVALID_ARG.
 */
lf_status_t lf_bqueue128_push_ex(lf_bqueue128_t* queue, void* item, bool* out_was_empty);
#define lfq_bqueue128_push_ex lf_bqueue128_push_ex

/**
 * @brief Attempts to dequeue an item using a single atomic 128-bit CAS.
 *
 * @param queue    Bounded queue handle.
 * @param out_item Out-pointer receiving the dequeued payload.
 * @return LF_OK on success, LF_ERR_EMPTY if the queue is empty, or LF_ERR_INVALID_ARG.
 */
lf_status_t lf_bqueue128_pop(lf_bqueue128_t* queue, void** out_item);
#define lfq_bqueue128_pop lf_bqueue128_pop

/**
 * @brief Inspects the front element without removing it.
 *
 * @param queue    Bounded queue handle.
 * @param out_item Out-pointer receiving the peeked payload.
 * @return LF_OK on success, LF_ERR_EMPTY if the queue is empty, or LF_ERR_INVALID_ARG.
 */
lf_status_t lf_bqueue128_peek(lf_bqueue128_t* queue, void** out_item);
#define lfq_bqueue128_peek lf_bqueue128_peek

/**
 * @brief Empties the queue, invoking destructor on each element if configured.
 *
 * @param queue Bounded queue handle.
 * @return LF_OK on success, or LF_ERR_INVALID_ARG.
 */
lf_status_t lf_bqueue128_clear(lf_bqueue128_t* queue);
#define lfq_bqueue128_clear lf_bqueue128_clear

/**
 * @brief Returns the approximate current number of elements in the queue.
 */
size_t lf_bqueue128_len(const lf_bqueue128_t* queue);
#define lfq_bqueue128_len lf_bqueue128_len

/**
 * @brief Returns the maximum capacity of the queue.
 */
size_t lf_bqueue128_capacity(const lf_bqueue128_t* queue);
#define lfq_bqueue128_capacity lf_bqueue128_capacity

/**
 * @brief Checks whether the queue is currently empty.
 */
bool lf_bqueue128_is_empty(const lf_bqueue128_t* queue);
#define lfq_bqueue128_is_empty lf_bqueue128_is_empty

/**
 * @brief Checks whether the queue is currently full.
 */
bool lf_bqueue128_is_full(const lf_bqueue128_t* queue);
#define lfq_bqueue128_is_full lf_bqueue128_is_full

#ifdef __cplusplus
}
#endif

#endif /* LOCKFREE_BQUEUE128_H */
