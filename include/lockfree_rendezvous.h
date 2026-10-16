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

/* ==========================================================================
 * 2. Opaque Handle & C ABI Operations (lfq_rendezvous_*)
 * ========================================================================== */

/**
 * @brief Opaque handle to a zero-buffer synchronous dual RendezvousChannel.
 */
typedef struct lfq_rendezvous lfq_rendezvous_t;

/**
 * @brief Creates a new zero-buffer synchronous RendezvousChannel.
 *
 * @param out_chan Out-pointer receiving the allocated channel handle.
 * @return LFQ_OK on success, or LFQ_ERR_INVALID_ARG / LFQ_ERR_OUT_OF_MEM.
 */
lfq_status_t lfq_rendezvous_create(lfq_rendezvous_t** out_chan);

/**
 * @brief Destroys a RendezvousChannel and releases all internal resources.
 *
 * @param chan Channel handle.
 * @return LFQ_OK on success, or LFQ_ERR_INVALID_ARG if chan is NULL.
 */
lfq_status_t lfq_rendezvous_destroy(lfq_rendezvous_t* chan);

/**
 * @brief Closes the channel and immediately wakes all blocked senders/receivers
 *        with LFQ_ERR_CLOSED.
 *
 * @param chan Channel handle.
 * @return LFQ_OK on success, or LFQ_ERR_INVALID_ARG if chan is NULL.
 */
lfq_status_t lfq_rendezvous_close(lfq_rendezvous_t* chan);

/**
 * @brief Checks whether the RendezvousChannel has been closed.
 *
 * @param chan Channel handle.
 * @return true if closed or chan is NULL, false otherwise.
 */
bool lfq_rendezvous_is_closed(const lfq_rendezvous_t* chan);

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
lfq_status_t lfq_rendezvous_send(
    lfq_rendezvous_t* chan,
    void* payload,
    uint64_t* out_corr_id
);

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
lfq_status_t lfq_rendezvous_recv(
    lfq_rendezvous_t* chan,
    void** out_payload,
    uint64_t* out_corr_id
);

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
lfq_status_t lfq_rendezvous_try_send(
    lfq_rendezvous_t* chan,
    void* payload,
    uint64_t* out_corr_id
);

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
lfq_status_t lfq_rendezvous_try_recv(
    lfq_rendezvous_t* chan,
    void** out_payload,
    uint64_t* out_corr_id
);

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
lfq_status_t lfq_rendezvous_send_timeout(
    lfq_rendezvous_t* chan,
    void* payload,
    int32_t timeout_ms,
    uint64_t* out_corr_id
);

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
lfq_status_t lfq_rendezvous_recv_timeout(
    lfq_rendezvous_t* chan,
    void** out_payload,
    int32_t timeout_ms,
    uint64_t* out_corr_id
);

#ifdef __cplusplus
}
#endif

#endif /* LOCKFREE_RENDEZVOUS_H */
