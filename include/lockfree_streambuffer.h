#ifndef LOCKFREE_STREAMBUFFER_H
#define LOCKFREE_STREAMBUFFER_H

#include <stdint.h>
#include <stdbool.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct lfq_stream_ring lfq_stream_ring_t;
typedef struct lfq_stream_ring lfq_streambuffer_t;

typedef struct {
    void* iov_base;
    size_t iov_len;
} lfq_iovec_slice_t;

typedef struct {
    lfq_iovec_slice_t first;
    lfq_iovec_slice_t second;
} lfq_iovec_pair_t;

/* StreamRing / StreamBuffer Lifecycle */
lfq_stream_ring_t* lfq_stream_ring_create(size_t capacity, bool use_virtual_mirror);
void lfq_stream_ring_destroy(lfq_stream_ring_t* ring);

lfq_streambuffer_t* lfq_streambuffer_create(size_t capacity, bool use_virtual_mirror);
void lfq_streambuffer_destroy(lfq_streambuffer_t* ring);

/* Metrics & Introspection */
size_t lfq_stream_ring_capacity(const lfq_stream_ring_t* ring);
size_t lfq_stream_ring_available_read(const lfq_stream_ring_t* ring);
size_t lfq_stream_ring_available_write(const lfq_stream_ring_t* ring);
bool lfq_stream_ring_is_empty(const lfq_stream_ring_t* ring);
bool lfq_stream_ring_is_full(const lfq_stream_ring_t* ring);

size_t lfq_streambuffer_capacity(const lfq_streambuffer_t* ring);
size_t lfq_streambuffer_available_read(const lfq_streambuffer_t* ring);
size_t lfq_streambuffer_available_write(const lfq_streambuffer_t* ring);
bool lfq_streambuffer_is_empty(const lfq_streambuffer_t* ring);
bool lfq_streambuffer_is_full(const lfq_streambuffer_t* ring);

/* Basic Read/Write Operations (Buffer Copy) */
size_t lfq_stream_ring_try_write(lfq_stream_ring_t* ring, const void* src, size_t len);
size_t lfq_stream_ring_try_read(lfq_stream_ring_t* ring, void* dst, size_t max_len);
size_t lfq_stream_ring_write_blocking(lfq_stream_ring_t* ring, const void* src, size_t len, int64_t timeout_ns);
size_t lfq_stream_ring_read_blocking(lfq_stream_ring_t* ring, void* dst, size_t max_len, int64_t timeout_ns);

size_t lfq_streambuffer_try_write(lfq_streambuffer_t* ring, const void* src, size_t len);
size_t lfq_streambuffer_try_read(lfq_streambuffer_t* ring, void* dst, size_t max_len);
size_t lfq_streambuffer_write_blocking(lfq_streambuffer_t* ring, const void* src, size_t len, int64_t timeout_ns);
size_t lfq_streambuffer_read_blocking(lfq_streambuffer_t* ring, void* dst, size_t max_len, int64_t timeout_ns);

/* Zero-Copy Two-Part IOVec Transactional APIs */
lfq_iovec_pair_t lfq_stream_ring_acquire_write_iov(lfq_stream_ring_t* ring, size_t requested_len);
void lfq_stream_ring_commit_write(lfq_stream_ring_t* ring, size_t bytes_written);

lfq_iovec_pair_t lfq_stream_ring_acquire_read_iov(lfq_stream_ring_t* ring, size_t requested_len);
void lfq_stream_ring_commit_read(lfq_stream_ring_t* ring, size_t bytes_read);

lfq_iovec_pair_t lfq_streambuffer_acquire_write_iov(lfq_streambuffer_t* ring, size_t requested_len);
void lfq_streambuffer_commit_write(lfq_streambuffer_t* ring, size_t bytes_written);

lfq_iovec_pair_t lfq_streambuffer_acquire_read_iov(lfq_streambuffer_t* ring, size_t requested_len);
void lfq_streambuffer_commit_read(lfq_streambuffer_t* ring, size_t bytes_read);

#ifdef __cplusplus
}
#endif

#endif /* LOCKFREE_STREAMBUFFER_H */
