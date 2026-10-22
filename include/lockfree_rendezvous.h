/**
 * @file lockfree_rendezvous.h
 * @brief Standalone C99/C11 Header for Zero-Buffer Synchronous Dual RendezvousChannel
 *
 * Exposes the wait-free / lock-free dual synchronous channel (`RendezvousChannel`)
 * across the C ABI boundary (`lfq_rendezvous_*`), supporting bilateral handoff,
 * correlation IDs, bounded timeouts, and channel closure with waiter cancellation.
 */

#ifndef LOCKFREE_RENDEZVOUS_H
#define LOCKFREE_RENDEZVOUS_H

#include <stddef.h>
#include <stdint.h>
#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

/* ==========================================================================
 * 1. Status Codes (Shared with lockfree.h)
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

/* ==========================================================================
 * 2. Opaque Handle & C ABI Operations (lfq_rendezvous_*)
 * ========================================================================== */

/**
 * @brief Opaque handle to a zero-buffer synchronous dual RendezvousChannel.
 */
typedef struct lf_rendezvous lf_rendezvous_t;
#define lfq_rendezvous lf_rendezvous
#define lfq_rendezvous_t lf_rendezvous_t

/**
 * @brief Creates a new zero-buffer synchronous RendezvousChannel.
 *
 * @param out_chan Out-pointer receiving the allocated channel handle.
 * @return LFQ_OK on success, or LFQ_ERR_INVALID_ARG / LFQ_ERR_OUT_OF_MEM.
 */
lf_status_t lf_rendezvous_create(lf_rendezvous_t** out_chan);
#define lfq_rendezvous_create lf_rendezvous_create

/**
 * @brief Destroys a RendezvousChannel and releases all internal resources.
 *
 * @param chan Channel handle.
 * @return LFQ_OK on success, or LFQ_ERR_INVALID_ARG if chan is NULL.
 */
lf_status_t lf_rendezvous_destroy(lf_rendezvous_t* chan);
#define lfq_rendezvous_destroy lf_rendezvous_destroy

/**
 * @brief Closes the channel and immediately wakes all blocked senders/receivers
 *        with LFQ_ERR_CLOSED.
 *
 * @param chan Channel handle.
 * @return LFQ_OK on success, or LFQ_ERR_INVALID_ARG if chan is NULL.
 */
lf_status_t lf_rendezvous_close(lf_rendezvous_t* chan);
#define lfq_rendezvous_close lf_rendezvous_close

/**
 * @brief Checks whether the RendezvousChannel has been closed.
 *
 * @param chan Channel handle.
 * @return true if closed or chan is NULL, false otherwise.
 */
bool lf_rendezvous_is_closed(const lf_rendezvous_t* chan);
#define lfq_rendezvous_is_closed lf_rendezvous_is_closed

/**
 * @brief Synchronously sends a pointer payload, blocking until a receiver pairs
 *        with this sender or the channel is closed.
 *
 * @param chan        Channel handle.
 * @param payload     Pointer payload to transfer to the pairing receiver.
 * @param out_corr_id Optional out-pointer receiving the nonzero correlation ID
 *                    shared with the paired receiver (may be NULL).
 * @return LFQ_OK on bilateral handoff, LFQ_ERR_CLOSED if closed, or LFQ_ERR_INVALID_ARG.
 */
lf_status_t lf_rendezvous_send(
    lf_rendezvous_t* chan,
    void* payload,
    uint64_t* out_corr_id
);
#define lfq_rendezvous_send lf_rendezvous_send

/**
 * @brief Synchronously receives a pointer payload, blocking until a sender pairs
 *        with this receiver or the channel is closed.
 *
 * @param chan        Channel handle.
 * @param out_payload Out-pointer receiving the transferred pointer payload.
 * @param out_corr_id Optional out-pointer receiving the nonzero correlation ID
 *                    shared with the paired sender (may be NULL).
 * @return LFQ_OK on bilateral handoff, LFQ_ERR_CLOSED if closed, or LFQ_ERR_INVALID_ARG.
 */
lf_status_t lf_rendezvous_recv(
    lf_rendezvous_t* chan,
    void** out_payload,
    uint64_t* out_corr_id
);
#define lfq_rendezvous_recv lf_rendezvous_recv

/**
 * @brief Attempts an immediate non-blocking send if a waiting receiver is already
 *        published on the dual treiber/elimination state.
 *
 * @param chan        Channel handle.
 * @param payload     Pointer payload to transfer.
 * @param out_corr_id Optional out-pointer receiving the correlation ID (may be NULL).
 * @return LFQ_OK if paired immediately, LFQ_ERR_EMPTY if no waiting receiver,
 *         LFQ_ERR_CLOSED if closed, or LFQ_ERR_INVALID_ARG.
 */
lf_status_t lf_rendezvous_try_send(
    lf_rendezvous_t* chan,
    void* payload,
    uint64_t* out_corr_id
);
#define lfq_rendezvous_try_send lf_rendezvous_try_send

/**
 * @brief Attempts an immediate non-blocking receive if a waiting sender is already
 *        published on the dual treiber/elimination state.
 *
 * @param chan        Channel handle.
 * @param out_payload Out-pointer receiving the transferred pointer payload.
 * @param out_corr_id Optional out-pointer receiving the correlation ID (may be NULL).
 * @return LFQ_OK if paired immediately, LFQ_ERR_EMPTY if no waiting sender,
 *         LFQ_ERR_CLOSED if closed, or LFQ_ERR_INVALID_ARG.
 */
lf_status_t lf_rendezvous_try_recv(
    lf_rendezvous_t* chan,
    void** out_payload,
    uint64_t* out_corr_id
);
#define lfq_rendezvous_try_recv lf_rendezvous_try_recv

/**
 * @brief Synchronously sends a pointer payload with a bounded timeout in milliseconds.
 *
 * @param chan        Channel handle.
 * @param payload     Pointer payload to transfer.
 * @param timeout_ms  Maximum wait duration in milliseconds.
 * @param out_corr_id Optional out-pointer receiving the correlation ID (may be NULL).
 * @return LFQ_OK on handoff, LFQ_ERR_EMPTY on timeout, LFQ_ERR_CLOSED if closed,
 *         or LFQ_ERR_INVALID_ARG.
 */
lf_status_t lf_rendezvous_send_timeout(
    lf_rendezvous_t* chan,
    void* payload,
    int32_t timeout_ms,
    uint64_t* out_corr_id
);
#define lfq_rendezvous_send_timeout lf_rendezvous_send_timeout

/**
 * @brief Synchronously receives a pointer payload with a bounded timeout in milliseconds.
 *
 * @param chan        Channel handle.
 * @param out_payload Out-pointer receiving the transferred pointer payload.
 * @param timeout_ms  Maximum wait duration in milliseconds.
 * @param out_corr_id Optional out-pointer receiving the correlation ID (may be NULL).
 * @return LFQ_OK on handoff, LFQ_ERR_EMPTY on timeout, LFQ_ERR_CLOSED if closed,
 *         or LFQ_ERR_INVALID_ARG.
 */
lf_status_t lf_rendezvous_recv_timeout(
    lf_rendezvous_t* chan,
    void** out_payload,
    int32_t timeout_ms,
    uint64_t* out_corr_id
);
#define lfq_rendezvous_recv_timeout lf_rendezvous_recv_timeout

#ifdef __cplusplus
}
#endif

#endif /* LOCKFREE_RENDEZVOUS_H */
