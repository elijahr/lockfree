#ifndef LOCKFREE_STREAMBUFFER_H
#define LOCKFREE_STREAMBUFFER_H

#include <stdint.h>
#include <stdbool.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
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
