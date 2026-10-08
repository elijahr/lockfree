/* ==============================================================================
 * Comprehensive C ABI Test Harness: tests/cabi/test_cabi.c
 * ==============================================================================
 *
 * Verifies that standard C99/C11 code can compile against `include/lockfree.h`
 * without any Nim headers, link against `liblockfree.a`, and interact with:
 *   1. MPMC Bounded & Unbounded Queues (acquire, push, pop, batch pop, close)
 *   2. Treiber Stack with Elimination-Backoff (push, pop, peek, drain, destructor)
 *   3. Chase-Lev Work-Stealing Deque (push/pop bottom, steal/batch top, destructor)
 *   4. Multithreaded concurrent producer/consumer execution via POSIX threads
 * ============================================================================== */

#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <stdbool.h>
#include <assert.h>
#include <pthread.h>
#include "lockfree.h"

/* Nim runtime initialization symbol exported by liblockfree.a */
extern void NimMain(void);

/* Test helper macros */
#define TEST_ASSERT(cond, msg) \
    do { \
        if (!(cond)) { \
            fprintf(stderr, "ASSERTION FAILED [%s:%d]: %s\n", __FILE__, __LINE__, msg); \
            exit(1); \
        } \
    } while (0)

/* Destructor tracking struct */
typedef struct {
    uintptr_t sum_destroyed;
    size_t count_destroyed;
} destructor_tracker_t;

static void test_destructor_fn(void* item, void* user_data) {
    destructor_tracker_t* tracker = (destructor_tracker_t*)user_data;
    if (tracker != NULL) {
        tracker->sum_destroyed += (uintptr_t)item;
        tracker->count_destroyed++;
    }
}

/* -------------------------------------------------------------------------
 * Test 1: Bounded Queue Lifecycle, Push/Pop & Aliases
 * ------------------------------------------------------------------------- */
static void test_cabi_bounded_queue(void) {
    printf("Running test_cabi_bounded_queue...\n");
    lfq_queue_t* queue = NULL;
    lfq_status_t status = lfq_bounded_mpmc_create(8, 2, 2, NULL, NULL, &queue);
    TEST_ASSERT(status == LFQ_OK && queue != NULL, "lfq_bounded_mpmc_create failed");
    TEST_ASSERT(lfq_queue_is_empty(queue), "New queue should be empty");
    TEST_ASSERT(lfq_queue_len(queue) == 0, "New queue len should be 0");
    TEST_ASSERT(!lfq_queue_is_closed(queue), "New queue should not be closed");

    lfq_producer_t* prod = NULL;
    lfq_consumer_t* cons = NULL;
    status = lfq_producer_acquire(queue, &prod);
    TEST_ASSERT(status == LFQ_OK && prod != NULL, "lfq_producer_acquire failed");
    status = lfq_consumer_acquire(queue, &cons);
    TEST_ASSERT(status == LFQ_OK && cons != NULL, "lfq_consumer_acquire failed");

    /* Push via lfq_push */
    status = lfq_push(prod, (void*)(uintptr_t)101);
    TEST_ASSERT(status == LFQ_OK, "lfq_push failed");

    /* Push via alias lfq_queue_push */
    status = lfq_queue_push(prod, (void*)(uintptr_t)102);
    TEST_ASSERT(status == LFQ_OK, "lfq_queue_push failed");

    TEST_ASSERT(lfq_queue_len(queue) == 2, "Queue len should be 2");
    TEST_ASSERT(!lfq_queue_is_empty(queue), "Queue should not be empty");

    /* Pop via lfq_pop */
    void* item = NULL;
    status = lfq_pop(cons, &item);
    TEST_ASSERT(status == LFQ_OK && (uintptr_t)item == 101, "lfq_pop failed or wrong value");

    /* Pop via alias lfq_queue_pop */
    status = lfq_queue_pop(cons, &item);
    TEST_ASSERT(status == LFQ_OK && (uintptr_t)item == 102, "lfq_queue_pop failed or wrong value");

    /* Pop on empty */
    status = lfq_pop(cons, &item);
    TEST_ASSERT(status == LFQ_ERR_EMPTY, "lfq_pop on empty should return LFQ_ERR_EMPTY");

    /* Test close */
    status = lfq_queue_close(queue);
    TEST_ASSERT(status == LFQ_OK, "lfq_queue_close failed");
    TEST_ASSERT(lfq_queue_is_closed(queue), "Queue should be closed");

    /* Push on closed returns LFQ_ERR_CLOSED */
    status = lfq_push(prod, (void*)(uintptr_t)103);
    TEST_ASSERT(status == LFQ_ERR_CLOSED, "Push on closed queue should return LFQ_ERR_CLOSED");

    status = lfq_producer_release(prod);
    TEST_ASSERT(status == LFQ_OK, "lfq_producer_release failed");
    status = lfq_consumer_release(cons);
    TEST_ASSERT(status == LFQ_OK, "lfq_consumer_release failed");

    status = lfq_queue_destroy(queue);
    TEST_ASSERT(status == LFQ_OK, "lfq_queue_destroy failed");
    printf("test_cabi_bounded_queue PASSED.\n");
}

/* -------------------------------------------------------------------------
 * Test 2: Unbounded Queue Lifecycle, Batch Pop & Destructor
 * ------------------------------------------------------------------------- */
static void test_cabi_unbounded_queue(void) {
    printf("Running test_cabi_unbounded_queue...\n");
    destructor_tracker_t tracker = {0, 0};
    lfq_queue_t* queue = NULL;
    lfq_status_t status = lfq_unbounded_mpmc_create(16, 4, test_destructor_fn, &tracker, &queue);
    TEST_ASSERT(status == LFQ_OK && queue != NULL, "lfq_unbounded_mpmc_create failed");

    lfq_producer_t* prod = NULL;
    lfq_consumer_t* cons = NULL;
    status = lfq_producer_acquire(queue, &prod);
    TEST_ASSERT(status == LFQ_OK && prod != NULL, "lfq_producer_acquire failed");
    status = lfq_consumer_acquire(queue, &cons);
    TEST_ASSERT(status == LFQ_OK && cons != NULL, "lfq_consumer_acquire failed");

    for (uintptr_t i = 1; i <= 10; i++) {
        status = lfq_push(prod, (void*)i);
        TEST_ASSERT(status == LFQ_OK, "lfq_push failed");
    }
    TEST_ASSERT(lfq_queue_len(queue) == 10, "Queue len should be 10");

    /* Batch pop 6 items */
    void* batch_items[8];
    size_t popped = lfq_pop_batch(cons, batch_items, 6);
    TEST_ASSERT(popped == 6, "lfq_pop_batch should pop 6 items");
    for (size_t i = 0; i < 6; i++) {
        TEST_ASSERT((uintptr_t)batch_items[i] == (i + 1), "Batch item mismatch");
    }
    TEST_ASSERT(lfq_queue_len(queue) == 4, "Remaining queue len should be 4");

    status = lfq_producer_release(prod);
    TEST_ASSERT(status == LFQ_OK, "lfq_producer_release failed");
    status = lfq_consumer_release(cons);
    TEST_ASSERT(status == LFQ_OK, "lfq_consumer_release failed");

    /* Destroy queue with remaining items (7, 8, 9, 10). Destructor should clean them up! */
    status = lfq_queue_destroy(queue);
    TEST_ASSERT(status == LFQ_OK, "lfq_queue_destroy failed");
    TEST_ASSERT(tracker.count_destroyed == 4, "Destructor should be called 4 times for remaining items");
    TEST_ASSERT(tracker.sum_destroyed == (7 + 8 + 9 + 10), "Destructor item sum mismatch");
    printf("test_cabi_unbounded_queue PASSED.\n");
}

/* -------------------------------------------------------------------------
 * Test 3: Treiber Stack Lifecycle, LIFO, Peek, Drain & Destructor
 * ------------------------------------------------------------------------- */
static void test_cabi_stack(void) {
    printf("Running test_cabi_stack...\n");
    destructor_tracker_t tracker = {0, 0};
    lfq_stack_t* stack = NULL;
    lfq_status_t status = lfq_stack_create(test_destructor_fn, &tracker, &stack);
    TEST_ASSERT(status == LFQ_OK && stack != NULL, "lfq_stack_create failed");
    TEST_ASSERT(lfq_stack_is_empty(stack), "New stack should be empty");
    TEST_ASSERT(lfq_stack_len(stack) == 0, "New stack len should be 0");

    void* item = NULL;
    status = lfq_stack_pop(stack, &item);
    TEST_ASSERT(status == LFQ_ERR_EMPTY, "Pop on empty stack should return LFQ_ERR_EMPTY");
    status = lfq_stack_peek(stack, &item);
    TEST_ASSERT(status == LFQ_ERR_EMPTY, "Peek on empty stack should return LFQ_ERR_EMPTY");

    /* Push 3 items: 10, 20, 30 */
    status = lfq_stack_push(stack, (void*)(uintptr_t)10);
    TEST_ASSERT(status == LFQ_OK, "lfq_stack_push 10 failed");
    status = lfq_stack_push(stack, (void*)(uintptr_t)20);
    TEST_ASSERT(status == LFQ_OK, "lfq_stack_push 20 failed");
    status = lfq_stack_push(stack, (void*)(uintptr_t)30);
    TEST_ASSERT(status == LFQ_OK, "lfq_stack_push 30 failed");

    TEST_ASSERT(!lfq_stack_is_empty(stack), "Stack should not be empty");
    TEST_ASSERT(lfq_stack_len(stack) == 3, "Stack len should be 3");

    /* Peek top item -> 30 */
    status = lfq_stack_peek(stack, &item);
    TEST_ASSERT(status == LFQ_OK && (uintptr_t)item == 30, "Peek failed or wrong item");
    TEST_ASSERT(lfq_stack_len(stack) == 3, "Peek should not remove item");

    /* Pop top item -> 30 (LIFO order) */
    status = lfq_stack_pop(stack, &item);
    TEST_ASSERT(status == LFQ_OK && (uintptr_t)item == 30, "Pop LIFO failed or wrong item");
    TEST_ASSERT(lfq_stack_len(stack) == 2, "Stack len should be 2");

    /* Drain remaining 2 items */
    void* drained[4];
    size_t count = lfq_stack_drain(stack, drained, 4);
    TEST_ASSERT(count == 2, "Drain should return 2 items");
    TEST_ASSERT((uintptr_t)drained[0] == 20 && (uintptr_t)drained[1] == 10, "Drain items order mismatch");
    TEST_ASSERT(lfq_stack_is_empty(stack), "Stack should be empty after drain");

    /* Push items for destructor test */
    status = lfq_stack_push(stack, (void*)(uintptr_t)55);
    TEST_ASSERT(status == LFQ_OK, "Push 55 failed");
    status = lfq_stack_push(stack, (void*)(uintptr_t)65);
    TEST_ASSERT(status == LFQ_OK, "Push 65 failed");

    /* Destroy stack: tracker should record destruction of 55 and 65 */
    status = lfq_stack_destroy(stack);
    TEST_ASSERT(status == LFQ_OK, "lfq_stack_destroy failed");
    TEST_ASSERT(tracker.count_destroyed == 2, "Stack destructor should be called twice");
    TEST_ASSERT(tracker.sum_destroyed == (55 + 65), "Stack destructor sum mismatch");
    printf("test_cabi_stack PASSED.\n");
}

/* -------------------------------------------------------------------------
 * Test 4: Chase-Lev Deque Lifecycle, Worker Pop (LIFO), Thief Steal (FIFO)
 * ------------------------------------------------------------------------- */
static void test_cabi_deque(void) {
    printf("Running test_cabi_deque...\n");
    destructor_tracker_t tracker = {0, 0};
    lfq_deque_t* deque = NULL;
    lfq_status_t status = lfq_deque_create(32, test_destructor_fn, &tracker, &deque);
    TEST_ASSERT(status == LFQ_OK && deque != NULL, "lfq_deque_create failed");
    TEST_ASSERT(lfq_deque_is_empty(deque), "New deque should be empty");
    TEST_ASSERT(lfq_deque_len(deque) == 0, "New deque len should be 0");
    TEST_ASSERT(lfq_deque_capacity(deque) >= 32, "Deque capacity should be >= 32");

    void* item = NULL;
    status = lfq_deque_pop(deque, &item);
    TEST_ASSERT(status == LFQ_ERR_EMPTY, "Pop on empty deque should return LFQ_ERR_EMPTY");
    status = lfq_deque_steal(deque, &item);
    TEST_ASSERT(status == LFQ_ERR_EMPTY, "Steal on empty deque should return LFQ_ERR_EMPTY");

    /* Worker pushes items: 100, 200, 300, 400 */
    status = lfq_deque_push(deque, (void*)(uintptr_t)100);
    TEST_ASSERT(status == LFQ_OK, "lfq_deque_push 100 failed");
    status = lfq_deque_push(deque, (void*)(uintptr_t)200);
    TEST_ASSERT(status == LFQ_OK, "lfq_deque_push 200 failed");
    status = lfq_deque_push(deque, (void*)(uintptr_t)300);
    TEST_ASSERT(status == LFQ_OK, "lfq_deque_push 300 failed");
    status = lfq_deque_push(deque, (void*)(uintptr_t)400);
    TEST_ASSERT(status == LFQ_OK, "lfq_deque_push 400 failed");

    TEST_ASSERT(!lfq_deque_is_empty(deque), "Deque should not be empty");
    TEST_ASSERT(lfq_deque_len(deque) == 4, "Deque len should be 4");

    /* Thief steals 1 item -> FIFO order from top: 100 */
    status = lfq_deque_steal(deque, &item);
    TEST_ASSERT(status == LFQ_OK && (uintptr_t)item == 100, "Thief steal failed or wrong item");
    TEST_ASSERT(lfq_deque_len(deque) == 3, "Deque len should be 3");

    /* Worker pops 1 item -> LIFO order from bottom: 400 */
    status = lfq_deque_pop(deque, &item);
    TEST_ASSERT(status == LFQ_OK && (uintptr_t)item == 400, "Worker pop failed or wrong item");
    TEST_ASSERT(lfq_deque_len(deque) == 2, "Deque len should be 2");

    /* Thief steals batch of remaining 2 items (200, 300) */
    void* stolen[4];
    size_t stolen_count = lfq_deque_steal_batch(deque, stolen, 4);
    TEST_ASSERT(stolen_count == 2, "Steal batch count should be 2");
    TEST_ASSERT((uintptr_t)stolen[0] == 200 && (uintptr_t)stolen[1] == 300, "Steal batch order mismatch");
    TEST_ASSERT(lfq_deque_is_empty(deque), "Deque should be empty after steal batch");

    /* Destructor verification: push 3 items and destroy deque */
    status = lfq_deque_push(deque, (void*)(uintptr_t)10);
    TEST_ASSERT(status == LFQ_OK, "Push 10 failed");
    status = lfq_deque_push(deque, (void*)(uintptr_t)20);
    TEST_ASSERT(status == LFQ_OK, "Push 20 failed");
    status = lfq_deque_push(deque, (void*)(uintptr_t)30);
    TEST_ASSERT(status == LFQ_OK, "Push 30 failed");

    status = lfq_deque_destroy(deque);
    TEST_ASSERT(status == LFQ_OK, "lfq_deque_destroy failed");
    TEST_ASSERT(tracker.count_destroyed == 3, "Deque destructor count should be 3");
    TEST_ASSERT(tracker.sum_destroyed == (10 + 20 + 30), "Deque destructor sum mismatch");
    printf("test_cabi_deque PASSED.\n");
}

/* -------------------------------------------------------------------------
 * Test 5: Concurrent Multithreaded MPMC Queue Test via pthreads
 * ------------------------------------------------------------------------- */
#define NUM_PRODUCERS 4
#define NUM_CONSUMERS 4
#define ITEMS_PER_PROD 2500
#define TOTAL_ITEMS (NUM_PRODUCERS * ITEMS_PER_PROD)

typedef struct {
    lfq_queue_t* queue;
    size_t start_val;
    size_t count;
} thread_prod_arg_t;

typedef struct {
    lfq_queue_t* queue;
    size_t target_count;
    _Atomic size_t* total_popped;
    _Atomic uint64_t* checksum;
} thread_cons_arg_t;

static void* thread_prod_worker(void* raw_arg) {
    thread_prod_arg_t* arg = (thread_prod_arg_t*)raw_arg;
    lfq_producer_t* prod = NULL;
    lfq_status_t s = lfq_producer_acquire(arg->queue, &prod);
    TEST_ASSERT(s == LFQ_OK && prod != NULL, "Thread producer acquire failed");

    for (size_t i = 0; i < arg->count; i++) {
        uintptr_t val = arg->start_val + i;
        while (lfq_push(prod, (void*)val) == LFQ_ERR_FULL) {
            #if defined(__x86_64__) || defined(_M_X64)
            __asm__ volatile("pause");
            #elif defined(__aarch64__) || defined(_M_ARM64)
            __asm__ volatile("yield");
            #endif
        }
    }
    lfq_producer_release(prod);
    return NULL;
}

static void* thread_cons_worker(void* raw_arg) {
    thread_cons_arg_t* arg = (thread_cons_arg_t*)raw_arg;
    lfq_consumer_t* cons = NULL;
    lfq_status_t s = lfq_consumer_acquire(arg->queue, &cons);
    TEST_ASSERT(s == LFQ_OK && cons != NULL, "Thread consumer acquire failed");

    void* item = NULL;
    while (*arg->total_popped < arg->target_count) {
        if (lfq_pop(cons, &item) == LFQ_OK) {
            uintptr_t val = (uintptr_t)item;
            (*arg->total_popped)++;
            *arg->checksum += val;
        } else {
            #if defined(__x86_64__) || defined(_M_X64)
            __asm__ volatile("pause");
            #elif defined(__aarch64__) || defined(_M_ARM64)
            __asm__ volatile("yield");
            #endif
        }
    }
    lfq_consumer_release(cons);
    return NULL;
}

static void test_cabi_concurrency(void) {
    printf("Running test_cabi_concurrency (%d prods x %d items)...\n", NUM_PRODUCERS, ITEMS_PER_PROD);
    lfq_queue_t* queue = NULL;
    lfq_status_t s = lfq_unbounded_mpmc_create(64, 16, NULL, NULL, &queue);
    TEST_ASSERT(s == LFQ_OK && queue != NULL, "lfq_unbounded_mpmc_create failed");

    pthread_t prod_threads[NUM_PRODUCERS];
    pthread_t cons_threads[NUM_CONSUMERS];
    thread_prod_arg_t prod_args[NUM_PRODUCERS];
    thread_cons_arg_t cons_args[NUM_CONSUMERS];

    _Atomic size_t total_popped = 0;
    _Atomic uint64_t checksum = 0;
    uint64_t expected_checksum = 0;

    for (size_t i = 1; i <= TOTAL_ITEMS; i++) {
        expected_checksum += i;
    }

    for (size_t i = 0; i < NUM_CONSUMERS; i++) {
        cons_args[i].queue = queue;
        cons_args[i].target_count = TOTAL_ITEMS;
        cons_args[i].total_popped = &total_popped;
        cons_args[i].checksum = &checksum;
        pthread_create(&cons_threads[i], NULL, thread_cons_worker, &cons_args[i]);
    }

    for (size_t i = 0; i < NUM_PRODUCERS; i++) {
        prod_args[i].queue = queue;
        prod_args[i].start_val = i * ITEMS_PER_PROD + 1;
        prod_args[i].count = ITEMS_PER_PROD;
        pthread_create(&prod_threads[i], NULL, thread_prod_worker, &prod_args[i]);
    }

    for (size_t i = 0; i < NUM_PRODUCERS; i++) {
        pthread_join(prod_threads[i], NULL);
    }
    for (size_t i = 0; i < NUM_CONSUMERS; i++) {
        pthread_join(cons_threads[i], NULL);
    }

    TEST_ASSERT(total_popped == TOTAL_ITEMS, "Total popped count mismatch");
    TEST_ASSERT(checksum == expected_checksum, "Checksum mismatch");

    s = lfq_queue_destroy(queue);
    TEST_ASSERT(s == LFQ_OK, "lfq_queue_destroy failed");
    printf("test_cabi_concurrency PASSED.\n");
}

/* -------------------------------------------------------------------------
 * Main Entry Point
 * ------------------------------------------------------------------------- */
int main(void) {
    printf("Initializing Nim runtime via NimMain()...\n");
    NimMain();
    printf("Nim runtime initialized successfully.\n");

    test_cabi_bounded_queue();
    test_cabi_unbounded_queue();
    test_cabi_stack();
    test_cabi_deque();
    test_cabi_concurrency();

    printf("\n>>> ALL C ABI TESTS COMPLETED SUCCESSFULLY! <<<\n");
    return 0;
}
