#ifndef LOCKFREE_STREAMBUFFER_H
#define LOCKFREE_STREAMBUFFER_H

#include <stdint.h>
#include <stdbool.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

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

typedef struct lf_stream_ring lf_stream_ring_t;
#define lfq_stream_ring lf_stream_ring
#define lfq_stream_ring_t lf_stream_ring_t
typedef struct lf_stream_ring lf_streambuffer_t;
#define lfq_stream_ring lf_stream_ring
#define lfq_streambuffer_t lf_streambuffer_t

typedef struct {

    void* iov_base;
    size_t iov_len;

} lf_iovec_slice_t;
#define lfq_iovec_slice_t lf_iovec_slice_t

typedef struct {

    lf_iovec_slice_t first;
    lf_iovec_slice_t second;

} lf_iovec_pair_t;
#define lfq_iovec_pair_t lf_iovec_pair_t

/* StreamRing / StreamBuffer Lifecycle */
lf_stream_ring_t* lf_stream_ring_create(size_t capacity, bool use_virtual_mirror);
#define lfq_stream_ring_create lf_stream_ring_create
void lf_stream_ring_destroy(lf_stream_ring_t* ring);
#define lfq_stream_ring_destroy lf_stream_ring_destroy

lf_streambuffer_t* lf_streambuffer_create(size_t capacity, bool use_virtual_mirror);
#define lfq_streambuffer_create lf_streambuffer_create
void lf_streambuffer_destroy(lf_streambuffer_t* ring);
#define lfq_streambuffer_destroy lf_streambuffer_destroy

/* Metrics & Introspection */
size_t lf_stream_ring_capacity(const lf_stream_ring_t* ring);
#define lfq_stream_ring_capacity lf_stream_ring_capacity
size_t lf_stream_ring_available_read(const lf_stream_ring_t* ring);
#define lfq_stream_ring_available_read lf_stream_ring_available_read
size_t lf_stream_ring_available_write(const lf_stream_ring_t* ring);
#define lfq_stream_ring_available_write lf_stream_ring_available_write
bool lf_stream_ring_is_empty(const lf_stream_ring_t* ring);
#define lfq_stream_ring_is_empty lf_stream_ring_is_empty
bool lf_stream_ring_is_full(const lf_stream_ring_t* ring);
#define lfq_stream_ring_is_full lf_stream_ring_is_full

size_t lf_streambuffer_capacity(const lf_streambuffer_t* ring);
#define lfq_streambuffer_capacity lf_streambuffer_capacity
size_t lf_streambuffer_available_read(const lf_streambuffer_t* ring);
#define lfq_streambuffer_available_read lf_streambuffer_available_read
size_t lf_streambuffer_available_write(const lf_streambuffer_t* ring);
#define lfq_streambuffer_available_write lf_streambuffer_available_write
bool lf_streambuffer_is_empty(const lf_streambuffer_t* ring);
#define lfq_streambuffer_is_empty lf_streambuffer_is_empty
bool lf_streambuffer_is_full(const lf_streambuffer_t* ring);
#define lfq_streambuffer_is_full lf_streambuffer_is_full

/* Basic Read/Write Operations (Buffer Copy) */
size_t lf_stream_ring_try_write(lf_stream_ring_t* ring, const void* src, size_t len);
#define lfq_stream_ring_try_write lf_stream_ring_try_write
size_t lf_stream_ring_try_read(lf_stream_ring_t* ring, void* dst, size_t max_len);
#define lfq_stream_ring_try_read lf_stream_ring_try_read
size_t lf_stream_ring_write_blocking(lf_stream_ring_t* ring, const void* src, size_t len, int64_t timeout_ns);
#define lfq_stream_ring_write_blocking lf_stream_ring_write_blocking
size_t lf_stream_ring_read_blocking(lf_stream_ring_t* ring, void* dst, size_t max_len, int64_t timeout_ns);
#define lfq_stream_ring_read_blocking lf_stream_ring_read_blocking

size_t lf_streambuffer_try_write(lf_streambuffer_t* ring, const void* src, size_t len);
#define lfq_streambuffer_try_write lf_streambuffer_try_write
size_t lf_streambuffer_try_read(lf_streambuffer_t* ring, void* dst, size_t max_len);
#define lfq_streambuffer_try_read lf_streambuffer_try_read
size_t lf_streambuffer_write_blocking(lf_streambuffer_t* ring, const void* src, size_t len, int64_t timeout_ns);
#define lfq_streambuffer_write_blocking lf_streambuffer_write_blocking
size_t lf_streambuffer_read_blocking(lf_streambuffer_t* ring, void* dst, size_t max_len, int64_t timeout_ns);
#define lfq_streambuffer_read_blocking lf_streambuffer_read_blocking

/* Zero-Copy Two-Part IOVec Transactional APIs */
lf_iovec_pair_t lf_stream_ring_acquire_write_iov(lf_stream_ring_t* ring, size_t requested_len);
#define lfq_stream_ring_acquire_write_iov lf_stream_ring_acquire_write_iov
void lf_stream_ring_commit_write(lf_stream_ring_t* ring, size_t bytes_written);
#define lfq_stream_ring_commit_write lf_stream_ring_commit_write

lf_iovec_pair_t lf_stream_ring_acquire_read_iov(lf_stream_ring_t* ring, size_t requested_len);
#define lfq_stream_ring_acquire_read_iov lf_stream_ring_acquire_read_iov
void lf_stream_ring_commit_read(lf_stream_ring_t* ring, size_t bytes_read);
#define lfq_stream_ring_commit_read lf_stream_ring_commit_read

lf_iovec_pair_t lf_streambuffer_acquire_write_iov(lf_streambuffer_t* ring, size_t requested_len);
#define lfq_streambuffer_acquire_write_iov lf_streambuffer_acquire_write_iov
void lf_streambuffer_commit_write(lf_streambuffer_t* ring, size_t bytes_written);
#define lfq_streambuffer_commit_write lf_streambuffer_commit_write

lf_iovec_pair_t lf_streambuffer_acquire_read_iov(lf_streambuffer_t* ring, size_t requested_len);
#define lfq_streambuffer_acquire_read_iov lf_streambuffer_acquire_read_iov
void lf_streambuffer_commit_read(lf_streambuffer_t* ring, size_t bytes_read);
#define lfq_streambuffer_commit_read lf_streambuffer_commit_read

/* Zero-Copy Two-Phase Reserve/Commit & Peek/Consume APIs (Status-Returning) */

/**
 * @brief Reserves up to `requested_bytes` of contiguous (or split wrap-around)
 *        writable space in the stream buffer without copying.
 *
 * When `requested_bytes == 0`, reserves all currently available writable bytes.
 * If the reservation wraps around the physical ring boundary (when virtual
 * mirroring is disabled), both `(*out_ptr1, *out_len1)` and
 * `(*out_ptr2, *out_len2)` are populated; otherwise `*out_ptr2` is set to
 * `NULL` and `*out_len2` is set to `0`.
 *
 * @param sb               Stream buffer handle (must not be NULL).
 * @param requested_bytes  Number of bytes to reserve, or 0 for all available.
 * @param out_ptr1         Output pointer to the primary writable segment (must not be NULL).
 * @param out_len1         Output byte length of the primary segment (must not be NULL).
 * @param out_ptr2         Output pointer to the wrap-around writable segment (must not be NULL).
 * @param out_len2         Output byte length of the wrap-around segment (must not be NULL).
 * @return `LF_OK` on success, `LF_ERR_FULL` if fewer than `requested_bytes`
 *         (or 0 bytes when `requested_bytes == 0`) are available, or
 *         `LF_ERR_INVALID_ARG` if any pointer argument is NULL or
 *         `requested_bytes` exceeds ring capacity.
 */
lf_status_t lf_stream_reserve_write(
    lf_streambuffer_t* sb,
    size_t requested_bytes,
    uint8_t** out_ptr1,
    size_t* out_len1,
    uint8_t** out_ptr2,
    size_t* out_len2
);
#define lfq_stream_reserve_write lf_stream_reserve_write

/**
 * @brief Commits `committed_bytes` previously written into regions obtained
 *        from `lf_stream_reserve_write`, publishing them to the consumer with
 *        release memory ordering.
 *
 * `committed_bytes` must not exceed the byte count reserved by the preceding
 * `lf_stream_reserve_write` call (`*out_len1 + *out_len2`). Passing
 * `committed_bytes == 0` cancels the active reservation without advancing the
 * write cursor and returns `LF_OK`.
 *
 * @param sb               Stream buffer handle (must not be NULL).
 * @param committed_bytes  Number of bytes actually written (must not exceed
 *                         the byte count reserved by the preceding
 *                         `lf_stream_reserve_write` call).
 * @return `LF_OK` on success, or `LF_ERR_INVALID_ARG` if `sb` is NULL or
 *         `committed_bytes` exceeds the active reservation or available write space.
 */
lf_status_t lf_stream_commit_write(
    lf_streambuffer_t* sb,
    size_t committed_bytes
);
#define lfq_stream_commit_write lf_stream_commit_write

/**
 * @brief Peeks at all currently available readable bytes in the stream buffer
 *        without copying or advancing the read cursor.
 *
 * If the readable region wraps around the physical ring boundary (when virtual
 * mirroring is disabled), both `(*out_ptr1, *out_len1)` and
 * `(*out_ptr2, *out_len2)` are populated; otherwise `*out_ptr2` is set to
 * `NULL` and `*out_len2` is set to `0`.
 *
 * @param sb        Stream buffer handle (must not be NULL).
 * @param out_ptr1  Output pointer to the primary readable segment (must not be NULL).
 * @param out_len1  Output byte length of the primary segment (must not be NULL).
 * @param out_ptr2  Output pointer to the wrap-around readable segment (must not be NULL).
 * @param out_len2  Output byte length of the wrap-around segment (must not be NULL).
 * @return `LF_OK` on success, `LF_ERR_EMPTY` if 0 readable bytes are available,
 *         or `LF_ERR_INVALID_ARG` if any pointer argument is NULL.
 */
lf_status_t lf_stream_peek_read(
    const lf_streambuffer_t* sb,
    const uint8_t** out_ptr1,
    size_t* out_len1,
    const uint8_t** out_ptr2,
    size_t* out_len2
);
#define lfq_stream_peek_read lf_stream_peek_read

/**
 * @brief Advances the consumer read cursor by `consumed_bytes` after reading
 *        from segments obtained via `lf_stream_peek_read`, releasing buffer
 *        space back to the producer with release memory ordering.
 *
 * @param sb              Stream buffer handle (must not be NULL).
 * @param consumed_bytes  Number of bytes consumed (must not exceed currently
 *                        available readable bytes).
 * @return `LF_OK` on success, or `LF_ERR_INVALID_ARG` if `sb` is NULL or
 *         `consumed_bytes` exceeds available readable bytes.
 */
lf_status_t lf_stream_consume_read(
    lf_streambuffer_t* sb,
    size_t consumed_bytes
);
#define lfq_stream_consume_read lf_stream_consume_read

/* -------------------------------------------------------------------------
 * MPMCStreamRing (Multi-Producer Multi-Consumer Byte Stream Ring)
 * ------------------------------------------------------------------------- */

typedef struct lf_mpmc_stream_ring lf_mpmc_stream_ring_t;
#define lfq_mpmc_stream_ring lf_mpmc_stream_ring
#define lfq_mpmc_stream_ring_t lf_mpmc_stream_ring_t

/* MPMCStreamRing Lifecycle */
lf_mpmc_stream_ring_t* lf_mpmc_stream_ring_create(size_t capacity);
#define lfq_mpmc_stream_ring_create lf_mpmc_stream_ring_create
void lf_mpmc_stream_ring_destroy(lf_mpmc_stream_ring_t* ring);
#define lfq_mpmc_stream_ring_destroy lf_mpmc_stream_ring_destroy

/* MPMCStreamRing Introspection */
size_t lf_mpmc_stream_ring_capacity(const lf_mpmc_stream_ring_t* ring);
#define lfq_mpmc_stream_ring_capacity lf_mpmc_stream_ring_capacity
size_t lf_mpmc_stream_ring_available_read(lf_mpmc_stream_ring_t* ring);
#define lfq_mpmc_stream_ring_available_read lf_mpmc_stream_ring_available_read
size_t lf_mpmc_stream_ring_available_write(lf_mpmc_stream_ring_t* ring);
#define lfq_mpmc_stream_ring_available_write lf_mpmc_stream_ring_available_write
bool lf_mpmc_stream_ring_is_empty(lf_mpmc_stream_ring_t* ring);
#define lfq_mpmc_stream_ring_is_empty lf_mpmc_stream_ring_is_empty
bool lf_mpmc_stream_ring_is_full(lf_mpmc_stream_ring_t* ring);
#define lfq_mpmc_stream_ring_is_full lf_mpmc_stream_ring_is_full

/* MPMCStreamRing Two-Phase Atomic Ticket Read/Write Operations */
size_t lf_mpmc_stream_ring_try_write(lf_mpmc_stream_ring_t* ring, const void* src, size_t len);
#define lfq_mpmc_stream_ring_try_write lf_mpmc_stream_ring_try_write
size_t lf_mpmc_stream_ring_try_read(lf_mpmc_stream_ring_t* ring, void* dst, size_t max_len);
#define lfq_mpmc_stream_ring_try_read lf_mpmc_stream_ring_try_read

#ifdef __cplusplus
}
#endif

#endif /* LOCKFREE_STREAMBUFFER_H */
