#ifndef LOCKFREE_RATELIMIT_H
#define LOCKFREE_RATELIMIT_H

#include <stdint.h>
#include <stdbool.h>
#include <stddef.h>

#if defined(__STDC_VERSION__) && __STDC_VERSION__ >= 201112L
  #include <stdalign.h>
#elif !defined(alignas)
  #if defined(_MSC_VER)
    #define alignas(x) __declspec(align(x))
  #elif defined(__GNUC__) || defined(__clang__)
    #define alignas(x) __attribute__((aligned(x)))
  #else
    #define alignas(x)
  #endif
#endif

#ifdef __cplusplus
extern "C" {
#endif

/* Status codes matching lockfree C ABI */
#ifndef LFQ_STATUS_DEFINED
#define LFQ_STATUS_DEFINED
typedef enum {
    LFQ_ERR_PANIC         = -2,
    LFQ_ERR_FAILURE       = -1,
    LFQ_OK                =  0,
    LFQ_ERR_EMPTY         =  1,
    LFQ_ERR_FULL          =  2,
    LFQ_ERR_CLOSED        =  3,
    LFQ_ERR_INVALID_ARG   =  4,
    LFQ_ERR_REGISTRY_FULL =  5,
    LFQ_ERR_UNSUPPORTED   =  6
} lfq_status_t;
#endif

/* 128-bit packed atomic state */
typedef struct {
    uint64_t last_timestamp_ns;
    uint64_t tokens_or_level;
} lfq_rate_limit_state_t;

/* TokenBucket structure */
typedef struct {
    alignas(64) lfq_rate_limit_state_t state;
    uint64_t capacity;
    uint64_t refill_rate_per_sec;
    uint64_t scale_factor;
} lfq_token_bucket_t;

/* LeakyBucket (GCRA) structure */
typedef struct {
    alignas(64) lfq_rate_limit_state_t state;
    uint64_t burst_tolerance_ns;
    uint64_t leak_rate_per_sec;
    uint64_t scale_factor;
} lfq_leaky_bucket_t;

/* TokenBucket API */
int lfq_token_bucket_init(lfq_token_bucket_t* bucket, uint64_t capacity, uint64_t refill_rate);
bool lfq_token_bucket_try_acquire(lfq_token_bucket_t* bucket, uint64_t tokens);
bool lfq_token_bucket_acquire_timeout(lfq_token_bucket_t* bucket, uint64_t tokens, int64_t timeout_ns);
uint64_t lfq_token_bucket_available(const lfq_token_bucket_t* bucket);

/* LeakyBucket (GCRA) API */
int lfq_leaky_bucket_init(lfq_leaky_bucket_t* bucket, uint64_t burst_tolerance_ns, uint64_t leak_rate);
bool lfq_leaky_bucket_try_consume(lfq_leaky_bucket_t* bucket, uint64_t weight);
bool lfq_leaky_bucket_consume_timeout(lfq_leaky_bucket_t* bucket, uint64_t weight, int64_t timeout_ns);
uint64_t lfq_leaky_bucket_water_level(const lfq_leaky_bucket_t* bucket);

#ifdef __cplusplus
}
#endif

#endif /* LOCKFREE_RATELIMIT_H */
