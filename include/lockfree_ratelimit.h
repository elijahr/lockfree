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

#ifndef LFQ_CACHELINE_BYTES
  #if (defined(__APPLE__) && (defined(__arm64__) || defined(__aarch64__))) || defined(__powerpc__) || defined(__ppc__)
    #define LFQ_CACHELINE_BYTES 128
  #else
    #define LFQ_CACHELINE_BYTES 64
  #endif
#endif

/* 128-bit packed atomic state */
typedef struct {

    uint64_t last_timestamp_ns;
    uint64_t tokens_or_level;

} lf_rate_limit_state_t;
#define lfq_rate_limit_state_t lf_rate_limit_state_t

/* TokenBucket structure */
typedef struct {

    alignas(LFQ_CACHELINE_BYTES) lf_rate_limit_state_t state;
    uint64_t capacity;
    uint64_t refill_rate_per_sec;
    uint64_t scale_factor;

} lf_token_bucket_t;
#define lfq_token_bucket_t lf_token_bucket_t

/* LeakyBucket (GCRA) structure */
typedef struct {

    alignas(LFQ_CACHELINE_BYTES) lf_rate_limit_state_t state;
    uint64_t burst_tolerance_ns;
    uint64_t leak_rate_per_sec;
    uint64_t scale_factor;

} lf_leaky_bucket_t;
#define lfq_leaky_bucket_t lf_leaky_bucket_t

/* TokenBucket API */
int lf_token_bucket_init(lf_token_bucket_t* bucket, uint64_t capacity, uint64_t refill_rate);
#define lfq_token_bucket_init lf_token_bucket_init
lf_token_bucket_t* lf_token_bucket_create(uint64_t capacity, uint64_t refill_rate);
#define lfq_token_bucket_create lf_token_bucket_create
void lf_token_bucket_destroy(lf_token_bucket_t* bucket);
#define lfq_token_bucket_destroy lf_token_bucket_destroy
void lf_token_bucket_reset(lf_token_bucket_t* bucket, uint64_t tokens);
#define lfq_token_bucket_reset lf_token_bucket_reset
bool lf_token_bucket_try_acquire(lf_token_bucket_t* bucket, uint64_t tokens);
#define lfq_token_bucket_try_acquire lf_token_bucket_try_acquire
bool lf_token_bucket_acquire_timeout(lf_token_bucket_t* bucket, uint64_t tokens, int64_t timeout_ns);
#define lfq_token_bucket_acquire_timeout lf_token_bucket_acquire_timeout
uint64_t lf_token_bucket_available(const lf_token_bucket_t* bucket);
#define lfq_token_bucket_available lf_token_bucket_available

/* LeakyBucket (GCRA) API */
int lf_leaky_bucket_init(lf_leaky_bucket_t* bucket, uint64_t burst_tolerance_ns, uint64_t leak_rate);
#define lfq_leaky_bucket_init lf_leaky_bucket_init
lf_leaky_bucket_t* lf_leaky_bucket_create(uint64_t burst_tolerance_ns, uint64_t leak_rate);
#define lfq_leaky_bucket_create lf_leaky_bucket_create
void lf_leaky_bucket_destroy(lf_leaky_bucket_t* bucket);
#define lfq_leaky_bucket_destroy lf_leaky_bucket_destroy
void lf_leaky_bucket_reset(lf_leaky_bucket_t* bucket);
#define lfq_leaky_bucket_reset lf_leaky_bucket_reset
bool lf_leaky_bucket_try_consume(lf_leaky_bucket_t* bucket, uint64_t weight);
#define lfq_leaky_bucket_try_consume lf_leaky_bucket_try_consume
bool lf_leaky_bucket_consume_timeout(lf_leaky_bucket_t* bucket, uint64_t weight, int64_t timeout_ns);
#define lfq_leaky_bucket_consume_timeout lf_leaky_bucket_consume_timeout
uint64_t lf_leaky_bucket_water_level(const lf_leaky_bucket_t* bucket);
#define lfq_leaky_bucket_water_level lf_leaky_bucket_water_level

#ifdef __cplusplus
}
#endif

#endif /* LOCKFREE_RATELIMIT_H */
