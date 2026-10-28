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

#ifndef _POSIX_C_SOURCE
#define _POSIX_C_SOURCE 199309L
#endif
#ifndef _DEFAULT_SOURCE
#define _DEFAULT_SOURCE
#endif

#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <stdbool.h>
#include <assert.h>
#include <pthread.h>
#include <time.h>
#include "lockfree.h"
#include "lockfree_ratelimit.h"
#include "lockfree_streambuffer.h"
#include "lockfree_associative.h"
#include <string.h>

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

/* Atomic primitives compatible with C99 builtins and C11 stdatomic */
#if defined(__STDC_VERSION__) && __STDC_VERSION__ >= 201112L && !defined(__STDC_NO_ATOMICS__)
#include <stdatomic.h>
typedef atomic_size_t test_atomic_size_t;
typedef atomic_uint_least64_t test_atomic_uint64_t;
#define ATOMIC_INC(p) atomic_fetch_add(p, 1)
#define ATOMIC_ADD(p, v) atomic_fetch_add(p, (v))
#define ATOMIC_LOAD(p) atomic_load(p)
#else
typedef size_t test_atomic_size_t;
typedef uint64_t test_atomic_uint64_t;
#define ATOMIC_INC(p) __sync_fetch_and_add((p), 1)
#define ATOMIC_ADD(p, v) __sync_fetch_and_add((p), (v))
#define ATOMIC_LOAD(p) __sync_fetch_and_add((p), 0)
#endif

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

typedef struct {
    uintptr_t sum_keys;
    uintptr_t sum_vals;
    size_t count_destroyed;
} destructor_entry_tracker_t;

static void test_entry_destructor_fn(void* key, void* val, void* user_data) {
    destructor_entry_tracker_t* tracker = (destructor_entry_tracker_t*)user_data;
    if (tracker != NULL) {
        tracker->sum_keys += (uintptr_t)key;
        tracker->sum_vals += (uintptr_t)val;
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
 * Test 5: Table (MPMC Ordered Key-Value Map) Lifecycle, Put, Get, Del, Contains
 * ------------------------------------------------------------------------- */
static void test_cabi_table(void) {
    printf("Running test_cabi_table...\n");
    destructor_entry_tracker_t tracker = {0, 0, 0};
    lfq_table_t* table = NULL;
    lfq_status_t status = lfq_table_create(test_entry_destructor_fn, &tracker, &table);
    TEST_ASSERT(status == LFQ_OK && table != NULL, "lfq_table_create failed");
    TEST_ASSERT(lfq_table_is_empty(table), "New table should be empty");
    TEST_ASSERT(lfq_table_len(table) == 0, "New table len should be 0");

    void* val = NULL;
    status = lfq_table_get(table, (void*)(uintptr_t)1, &val);
    TEST_ASSERT(status == LFQ_ERR_EMPTY, "Get on empty table should return LFQ_ERR_EMPTY");
    TEST_ASSERT(!lfq_table_contains(table, (void*)(uintptr_t)1), "Empty table should not contain key 1");

    /* Put 3 items: (1 -> 100), (2 -> 200), (3 -> 300) */
    bool inserted = false;
    status = lfq_table_put(table, (void*)(uintptr_t)1, (void*)(uintptr_t)100, &inserted);
    TEST_ASSERT(status == LFQ_OK && inserted, "lfq_table_put 1 failed");
    status = lfq_table_put(table, (void*)(uintptr_t)2, (void*)(uintptr_t)200, &inserted);
    TEST_ASSERT(status == LFQ_OK && inserted, "lfq_table_put 2 failed");
    status = lfq_table_put(table, (void*)(uintptr_t)3, (void*)(uintptr_t)300, &inserted);
    TEST_ASSERT(status == LFQ_OK && inserted, "lfq_table_put 3 failed");

    TEST_ASSERT(!lfq_table_is_empty(table), "Table should not be empty");
    TEST_ASSERT(lfq_table_len(table) == 3, "Table len should be 3");
    TEST_ASSERT(lfq_table_contains(table, (void*)(uintptr_t)1), "Table should contain key 1");
    TEST_ASSERT(lfq_table_contains(table, (void*)(uintptr_t)2), "Table should contain key 2");
    TEST_ASSERT(lfq_table_contains(table, (void*)(uintptr_t)3), "Table should contain key 3");

    /* Get items */
    status = lfq_table_get(table, (void*)(uintptr_t)1, &val);
    TEST_ASSERT(status == LFQ_OK && (uintptr_t)val == 100, "Get key 1 failed or wrong val");
    status = lfq_table_get(table, (void*)(uintptr_t)2, &val);
    TEST_ASSERT(status == LFQ_OK && (uintptr_t)val == 200, "Get key 2 failed or wrong val");
    status = lfq_table_get(table, (void*)(uintptr_t)3, &val);
    TEST_ASSERT(status == LFQ_OK && (uintptr_t)val == 300, "Get key 3 failed or wrong val");

    /* Update existing key 2 -> 250 */
    status = lfq_table_put(table, (void*)(uintptr_t)2, (void*)(uintptr_t)250, &inserted);
    TEST_ASSERT(status == LFQ_OK && !inserted, "Update key 2 should return inserted == false");
    TEST_ASSERT(lfq_table_len(table) == 3, "Table len should remain 3 after update");
    status = lfq_table_get(table, (void*)(uintptr_t)2, &val);
    TEST_ASSERT(status == LFQ_OK && (uintptr_t)val == 250, "Get updated key 2 failed or wrong val");

    /* Delete key 2 */
    bool deleted = false;
    status = lfq_table_delete(table, (void*)(uintptr_t)2, &deleted);
    TEST_ASSERT(status == LFQ_OK && deleted, "lfq_table_delete 2 failed");
    TEST_ASSERT(lfq_table_len(table) == 2, "Table len should be 2 after delete");
    TEST_ASSERT(!lfq_table_contains(table, (void*)(uintptr_t)2), "Key 2 should no longer be present");

    /* Delete non-existent key returns LFQ_ERR_EMPTY */
    status = lfq_table_delete(table, (void*)(uintptr_t)999, &deleted);
    TEST_ASSERT(status == LFQ_ERR_EMPTY && !deleted, "Delete non-existent key should return LFQ_ERR_EMPTY");

    /* Remove key 1 via alias lfq_table_remove */
    bool removed = false;
    status = lfq_table_remove(table, (void*)(uintptr_t)1, &removed);
    TEST_ASSERT(status == LFQ_OK && removed, "lfq_table_remove 1 failed");
    TEST_ASSERT(lfq_table_len(table) == 1, "Table len should be 1 after remove");

    /* Destroy table with remaining entry (3 -> 300): destructor should be invoked! */
    status = lfq_table_destroy(table);
    TEST_ASSERT(status == LFQ_OK, "lfq_table_destroy failed");
    TEST_ASSERT(tracker.count_destroyed == 1, "Table destructor count should be 1");
    TEST_ASSERT(tracker.sum_keys == 3 && tracker.sum_vals == 300, "Table destructor key/val sum mismatch");
    printf("test_cabi_table PASSED.\n");
}

/* -------------------------------------------------------------------------
 * Test 6: Set (MPMC Ordered Set) Lifecycle, Insert, Remove, Contains
 * ------------------------------------------------------------------------- */
static void test_cabi_set(void) {
    printf("Running test_cabi_set...\n");
    destructor_tracker_t tracker = {0, 0};
    lfq_set_t* set = NULL;
    lfq_status_t status = lfq_set_create(test_destructor_fn, &tracker, &set);
    TEST_ASSERT(status == LFQ_OK && set != NULL, "lfq_set_create failed");
    TEST_ASSERT(lfq_set_is_empty(set), "New set should be empty");
    TEST_ASSERT(lfq_set_len(set) == 0, "New set len should be 0");
    TEST_ASSERT(!lfq_set_contains(set, (void*)(uintptr_t)42), "Empty set should not contain 42");

    /* Insert 3 items: 10, 20, 30 */
    bool inserted = false;
    status = lfq_set_insert(set, (void*)(uintptr_t)10, &inserted);
    TEST_ASSERT(status == LFQ_OK && inserted, "lfq_set_insert 10 failed");
    status = lfq_set_insert(set, (void*)(uintptr_t)20, &inserted);
    TEST_ASSERT(status == LFQ_OK && inserted, "lfq_set_insert 20 failed");
    status = lfq_set_insert(set, (void*)(uintptr_t)30, &inserted);
    TEST_ASSERT(status == LFQ_OK && inserted, "lfq_set_insert 30 failed");

    TEST_ASSERT(!lfq_set_is_empty(set), "Set should not be empty");
    TEST_ASSERT(lfq_set_len(set) == 3, "Set len should be 3");
    TEST_ASSERT(lfq_set_contains(set, (void*)(uintptr_t)10), "Set should contain 10");
    TEST_ASSERT(lfq_set_contains(set, (void*)(uintptr_t)20), "Set should contain 20");
    TEST_ASSERT(lfq_set_contains(set, (void*)(uintptr_t)30), "Set should contain 30");

    /* Insert duplicate 20 */
    status = lfq_set_insert(set, (void*)(uintptr_t)20, &inserted);
    TEST_ASSERT(status == LFQ_OK && !inserted, "Duplicate insert should return inserted == false");
    TEST_ASSERT(lfq_set_len(set) == 3, "Set len should remain 3 after duplicate insert");

    /* Remove 20 */
    bool removed = false;
    status = lfq_set_remove(set, (void*)(uintptr_t)20, &removed);
    TEST_ASSERT(status == LFQ_OK && removed, "lfq_set_remove 20 failed");
    TEST_ASSERT(lfq_set_len(set) == 2, "Set len should be 2 after remove");
    TEST_ASSERT(!lfq_set_contains(set, (void*)(uintptr_t)20), "Set should not contain 20 after remove");

    /* Remove non-existent item returns LFQ_ERR_EMPTY */
    status = lfq_set_remove(set, (void*)(uintptr_t)999, &removed);
    TEST_ASSERT(status == LFQ_ERR_EMPTY && !removed, "Remove non-existent item should return LFQ_ERR_EMPTY");

    /* Destroy set with remaining items (10, 30): destructor should clean them up! */
    status = lfq_set_destroy(set);
    TEST_ASSERT(status == LFQ_OK, "lfq_set_destroy failed");
    TEST_ASSERT(tracker.count_destroyed == 2, "Set destructor count should be 2");
    TEST_ASSERT(tracker.sum_destroyed == (10 + 30), "Set destructor sum mismatch");
    printf("test_cabi_set PASSED.\n");
}

/* -------------------------------------------------------------------------
 * Test 7: Ctrie (MPMC Concurrent Hash Trie) & Wait-Free Snapshots
 * ------------------------------------------------------------------------- */
static void test_cabi_ctrie(void) {
    printf("Running test_cabi_ctrie...\n");
    destructor_entry_tracker_t tracker = {0, 0, 0};
    lfq_ctrie_t* ctrie = NULL;
    lfq_status_t status = lfq_ctrie_create(test_entry_destructor_fn, &tracker, &ctrie);
    TEST_ASSERT(status == LFQ_OK && ctrie != NULL, "lfq_ctrie_create failed");
    TEST_ASSERT(lfq_ctrie_is_empty(ctrie), "New ctrie should be empty");
    TEST_ASSERT(lfq_ctrie_len(ctrie) == 0, "New ctrie len should be 0");
    TEST_ASSERT(!lfq_ctrie_contains(ctrie, (void*)(uintptr_t)42), "Empty ctrie should not contain 42");

    /* Insert 4 entries: 10->100, 20->200, 30->300, 40->400 */
    bool inserted = false;
    status = lfq_ctrie_insert(ctrie, (void*)(uintptr_t)10, (void*)(uintptr_t)100, &inserted);
    TEST_ASSERT(status == LFQ_OK && inserted, "lfq_ctrie_insert 10 failed");
    status = lfq_ctrie_insert(ctrie, (void*)(uintptr_t)20, (void*)(uintptr_t)200, &inserted);
    TEST_ASSERT(status == LFQ_OK && inserted, "lfq_ctrie_insert 20 failed");
    status = lfq_ctrie_insert(ctrie, (void*)(uintptr_t)30, (void*)(uintptr_t)300, &inserted);
    TEST_ASSERT(status == LFQ_OK && inserted, "lfq_ctrie_insert 30 failed");
    status = lfq_ctrie_insert(ctrie, (void*)(uintptr_t)40, (void*)(uintptr_t)400, &inserted);
    TEST_ASSERT(status == LFQ_OK && inserted, "lfq_ctrie_insert 40 failed");

    TEST_ASSERT(!lfq_ctrie_is_empty(ctrie), "Ctrie should not be empty");
    TEST_ASSERT(lfq_ctrie_len(ctrie) == 4, "Ctrie len should be 4");

    void* val = NULL;
    status = lfq_ctrie_lookup(ctrie, (void*)(uintptr_t)10, &val);
    TEST_ASSERT(status == LFQ_OK && (uintptr_t)val == 100, "Lookup 10 failed or wrong value");
    status = lfq_ctrie_lookup(ctrie, (void*)(uintptr_t)20, &val);
    TEST_ASSERT(status == LFQ_OK && (uintptr_t)val == 200, "Lookup 20 failed or wrong value");
    status = lfq_ctrie_lookup(ctrie, (void*)(uintptr_t)30, &val);
    TEST_ASSERT(status == LFQ_OK && (uintptr_t)val == 300, "Lookup 30 failed or wrong value");
    status = lfq_ctrie_lookup(ctrie, (void*)(uintptr_t)40, &val);
    TEST_ASSERT(status == LFQ_OK && (uintptr_t)val == 400, "Lookup 40 failed or wrong value");

    /* Lookup non-existent key returns LFQ_ERR_EMPTY */
    status = lfq_ctrie_lookup(ctrie, (void*)(uintptr_t)999, &val);
    TEST_ASSERT(status == LFQ_ERR_EMPTY, "Lookup non-existent key should return LFQ_ERR_EMPTY");

    /* Create Wait-Free Snapshot */
    lfq_ctrie_snapshot_t* snap = NULL;
    status = lfq_ctrie_snapshot(ctrie, &snap);
    TEST_ASSERT(status == LFQ_OK && snap != NULL, "lfq_ctrie_snapshot failed");
    TEST_ASSERT(!lfq_ctrie_snapshot_is_empty(snap), "Snapshot should not be empty");
    TEST_ASSERT(lfq_ctrie_snapshot_len(snap) == 4, "Snapshot len should be 4");
    TEST_ASSERT(lfq_ctrie_snapshot_contains(snap, (void*)(uintptr_t)10), "Snapshot should contain 10");
    TEST_ASSERT(lfq_ctrie_snapshot_contains(snap, (void*)(uintptr_t)20), "Snapshot should contain 20");
    TEST_ASSERT(lfq_ctrie_snapshot_contains(snap, (void*)(uintptr_t)30), "Snapshot should contain 30");
    TEST_ASSERT(lfq_ctrie_snapshot_contains(snap, (void*)(uintptr_t)40), "Snapshot should contain 40");
    void* snap_val = NULL;
    status = lfq_ctrie_snapshot_lookup(snap, (void*)(uintptr_t)20, &snap_val);
    TEST_ASSERT(status == LFQ_OK && (uintptr_t)snap_val == 200, "Snapshot lookup 20 failed");

    /* Mutate active ctrie after snapshot: update 10, remove 20, insert 50 */
    status = lfq_ctrie_put(ctrie, (void*)(uintptr_t)10, (void*)(uintptr_t)1000, &inserted);
    TEST_ASSERT(status == LFQ_OK && !inserted, "Update 10 should return inserted == false");
    bool removed = false;
    status = lfq_ctrie_remove(ctrie, (void*)(uintptr_t)20, &removed);
    TEST_ASSERT(status == LFQ_OK && removed, "lfq_ctrie_remove 20 failed");
    status = lfq_ctrie_insert(ctrie, (void*)(uintptr_t)50, (void*)(uintptr_t)500, &inserted);
    TEST_ASSERT(status == LFQ_OK && inserted, "Insert 50 failed");

    /* Verify active ctrie state */
    TEST_ASSERT(lfq_ctrie_len(ctrie) == 4, "Active ctrie len should be 4 (10, 30, 40, 50)");
    TEST_ASSERT(!lfq_ctrie_contains(ctrie, (void*)(uintptr_t)20), "Active ctrie should not contain 20");
    TEST_ASSERT(lfq_ctrie_contains(ctrie, (void*)(uintptr_t)50), "Active ctrie should contain 50");
    status = lfq_ctrie_lookup(ctrie, (void*)(uintptr_t)10, &val);
    TEST_ASSERT(status == LFQ_OK && (uintptr_t)val == 1000, "Active ctrie key 10 should be updated to 1000");

    /* Verify Snapshot Isolation: snap must be unmodified point-in-time view */
    TEST_ASSERT(lfq_ctrie_snapshot_len(snap) == 4, "Snapshot len must remain 4");
    TEST_ASSERT(lfq_ctrie_snapshot_contains(snap, (void*)(uintptr_t)20), "Snapshot must still contain 20");
    TEST_ASSERT(!lfq_ctrie_snapshot_contains(snap, (void*)(uintptr_t)50), "Snapshot must not contain 50");
    status = lfq_ctrie_snapshot_lookup(snap, (void*)(uintptr_t)10, &snap_val);
    TEST_ASSERT(status == LFQ_OK && (uintptr_t)snap_val == 100, "Snapshot key 10 must still be 100");
    status = lfq_ctrie_snapshot_lookup(snap, (void*)(uintptr_t)20, &snap_val);
    TEST_ASSERT(status == LFQ_OK && (uintptr_t)snap_val == 200, "Snapshot key 20 must still be 200");

    /* Destroy snapshot */
    status = lfq_ctrie_snapshot_destroy(snap);
    TEST_ASSERT(status == LFQ_OK, "lfq_ctrie_snapshot_destroy failed");

    /* Destroy active ctrie: remaining items (10, 30, 40, 50) destructed */
    status = lfq_ctrie_destroy(ctrie);
    TEST_ASSERT(status == LFQ_OK, "lfq_ctrie_destroy failed");
    TEST_ASSERT(tracker.count_destroyed == 4, "Ctrie destructor count should be 4");
    TEST_ASSERT(tracker.sum_keys == (10 + 30 + 40 + 50), "Ctrie destructor key sum mismatch");
    TEST_ASSERT(tracker.sum_vals == (1000 + 300 + 400 + 500), "Ctrie destructor val sum mismatch");
    printf("test_cabi_ctrie PASSED.\n");
}

/* -------------------------------------------------------------------------
 * Test 8: BroadcastRing (MPMC / SPMC Multicast Broadcast Ring)
 * ------------------------------------------------------------------------- */
static void test_cabi_broadcast(void) {
    printf("Running test_cabi_broadcast...\n");
    lfq_broadcast_t* ring = NULL;
    lfq_status_t status = lfq_broadcast_create(16, LFQ_OVERFLOW_DROP_OLDEST, 8, &ring);
    TEST_ASSERT(status == LFQ_OK && ring != NULL, "lfq_broadcast_create failed");
    TEST_ASSERT(lfq_broadcast_capacity(ring) >= 16, "Capacity should be >= 16");
    TEST_ASSERT(lfq_broadcast_len(ring) == 0, "Initial len should be 0");
    TEST_ASSERT(lfq_broadcast_is_empty(ring), "Initial ring should be empty");
    TEST_ASSERT(lfq_broadcast_subscriber_count(ring) == 0, "Initial subscriber count should be 0");

    /* Subscribe 2 cursors from latest */
    lfq_broadcast_cursor_t* cur1 = NULL;
    lfq_broadcast_cursor_t* cur2 = NULL;
    status = lfq_broadcast_subscribe(ring, LFQ_SUB_FROM_LATEST, &cur1);
    TEST_ASSERT(status == LFQ_OK && cur1 != NULL, "Subscribe cur1 failed");
    status = lfq_broadcast_subscribe(ring, LFQ_SUB_FROM_LATEST, &cur2);
    TEST_ASSERT(status == LFQ_OK && cur2 != NULL, "Subscribe cur2 failed");
    TEST_ASSERT(lfq_broadcast_subscriber_count(ring) == 2, "Subscriber count should be 2");

    /* Publish 2 items: 100 and 200 */
    status = lfq_broadcast_publish(ring, (void*)(uintptr_t)100);
    TEST_ASSERT(status == LFQ_OK, "Publish 100 failed");
    status = lfq_broadcast_publish(ring, (void*)(uintptr_t)200);
    TEST_ASSERT(status == LFQ_OK, "Publish 200 failed");
    TEST_ASSERT(lfq_broadcast_len(ring) == 2, "Ring len should be 2");
    TEST_ASSERT(!lfq_broadcast_is_empty(ring), "Ring should not be empty");

    /* Cursor 1 reads via try_read */
    void* item1 = NULL;
    status = lfq_broadcast_try_read(cur1, &item1);
    TEST_ASSERT(status == LFQ_OK && (uintptr_t)item1 == 100, "cur1 read 100 failed");
    status = lfq_broadcast_try_read(cur1, &item1);
    TEST_ASSERT(status == LFQ_OK && (uintptr_t)item1 == 200, "cur1 read 200 failed");
    status = lfq_broadcast_try_read(cur1, &item1);
    TEST_ASSERT(status == LFQ_ERR_EMPTY, "cur1 should be empty now");

    /* Cursor 2 reads via poll */
    void* item2 = NULL;
    size_t skipped = 0;
    lfq_poll_result_t poll_res;
    status = lfq_broadcast_poll(cur2, &item2, &skipped, &poll_res);
    TEST_ASSERT(status == LFQ_OK && (uintptr_t)item2 == 100 && poll_res == LFQ_POLL_SUCCESS, "cur2 poll 100 failed");
    status = lfq_broadcast_poll(cur2, &item2, &skipped, &poll_res);
    TEST_ASSERT(status == LFQ_OK && (uintptr_t)item2 == 200 && poll_res == LFQ_POLL_SUCCESS, "cur2 poll 200 failed");
    status = lfq_broadcast_poll(cur2, &item2, &skipped, &poll_res);
    TEST_ASSERT(status == LFQ_ERR_EMPTY && poll_res == LFQ_POLL_EMPTY, "cur2 poll should be empty");

    /* Subscribe Cursor 3 with FROM_EARLIEST: should replay existing messages */
    lfq_broadcast_cursor_t* cur3 = NULL;
    status = lfq_broadcast_subscribe(ring, LFQ_SUB_FROM_EARLIEST, &cur3);
    TEST_ASSERT(status == LFQ_OK && cur3 != NULL, "Subscribe cur3 failed");
    TEST_ASSERT(lfq_broadcast_subscriber_count(ring) == 3, "Subscriber count should be 3");

    void* item3 = NULL;
    status = lfq_broadcast_try_read(cur3, &item3);
    TEST_ASSERT(status == LFQ_OK && (uintptr_t)item3 == 100, "cur3 replay 100 failed");
    status = lfq_broadcast_try_read(cur3, &item3);
    TEST_ASSERT(status == LFQ_OK && (uintptr_t)item3 == 200, "cur3 replay 200 failed");

    /* Unsubscribe all cursors */
    status = lfq_broadcast_unsubscribe(cur1);
    TEST_ASSERT(status == LFQ_OK, "Unsubscribe cur1 failed");
    status = lfq_broadcast_unsubscribe(cur2);
    TEST_ASSERT(status == LFQ_OK, "Unsubscribe cur2 failed");
    status = lfq_broadcast_unsubscribe(cur3);
    TEST_ASSERT(status == LFQ_OK, "Unsubscribe cur3 failed");
    TEST_ASSERT(lfq_broadcast_subscriber_count(ring) == 0, "Subscriber count should be 0");

    /* Destroy ring */
    status = lfq_broadcast_destroy(ring);
    TEST_ASSERT(status == LFQ_OK, "lfq_broadcast_destroy failed");

    /* TopicBus lifecycle, multi-topic pub/sub, and introspection */
    lfq_topic_bus_t* bus = NULL;
    status = lfq_topic_bus_create(16, LFQ_OVERFLOW_DROP_OLDEST, 8, &bus);
    TEST_ASSERT(status == LFQ_OK && bus != NULL, "lfq_topic_bus_create failed");
    TEST_ASSERT(lfq_topic_bus_topic_count(bus) == 0, "Initial topic count should be 0");
    TEST_ASSERT(!lfq_topic_bus_has_topic(bus, "orders"), "Initial bus should not have orders topic");

    lfq_broadcast_cursor_t* cur_orders = NULL;
    lfq_broadcast_cursor_t* cur_trades = NULL;
    status = lfq_topic_bus_subscribe(bus, "orders", LFQ_SUB_FROM_LATEST, &cur_orders);
    TEST_ASSERT(status == LFQ_OK && cur_orders != NULL, "Subscribe orders failed");
    status = lfq_topic_bus_subscribe(bus, "trades", LFQ_SUB_FROM_LATEST, &cur_trades);
    TEST_ASSERT(status == LFQ_OK && cur_trades != NULL, "Subscribe trades failed");
    TEST_ASSERT(lfq_topic_bus_topic_count(bus) == 2, "Topic count should be 2");
    TEST_ASSERT(lfq_topic_bus_has_topic(bus, "orders"), "Bus should have orders topic");
    TEST_ASSERT(lfq_topic_bus_has_topic(bus, "trades"), "Bus should have trades topic");
    TEST_ASSERT(!lfq_topic_bus_has_topic(bus, "quotes"), "Bus should not have quotes topic");

    status = lfq_topic_bus_publish(bus, "orders", (void*)(uintptr_t)501);
    TEST_ASSERT(status == LFQ_OK, "Publish orders failed");
    status = lfq_topic_bus_publish(bus, "trades", (void*)(uintptr_t)502);
    TEST_ASSERT(status == LFQ_OK, "Publish trades failed");

    void* bus_item = NULL;
    status = lfq_broadcast_try_read(cur_orders, &bus_item);
    TEST_ASSERT(status == LFQ_OK && (uintptr_t)bus_item == 501, "Read orders failed");
    status = lfq_broadcast_try_read(cur_orders, &bus_item);
    TEST_ASSERT(status == LFQ_ERR_EMPTY, "Orders cursor should be empty");

    status = lfq_broadcast_try_read(cur_trades, &bus_item);
    TEST_ASSERT(status == LFQ_OK && (uintptr_t)bus_item == 502, "Read trades failed");
    status = lfq_broadcast_try_read(cur_trades, &bus_item);
    TEST_ASSERT(status == LFQ_ERR_EMPTY, "Trades cursor should be empty");

    TEST_ASSERT(lfq_broadcast_unsubscribe(cur_orders) == LFQ_OK, "Unsubscribe cur_orders failed");
    TEST_ASSERT(lfq_broadcast_unsubscribe(cur_trades) == LFQ_OK, "Unsubscribe cur_trades failed");
    TEST_ASSERT(lfq_topic_bus_destroy(bus) == LFQ_OK, "lfq_topic_bus_destroy failed");

    printf("test_cabi_broadcast PASSED.\n");
}

/* -------------------------------------------------------------------------
 * Test 9: RendezvousChannel (Zero-Buffer Synchronous Dual Channel)
 * ------------------------------------------------------------------------- */

typedef struct {
    lfq_rendezvous_t* chan;
    size_t count;
    uintptr_t start_val;
    uint64_t* corr_ids;
} rz_thread_arg_t;

static void* rz_sender_worker(void* raw_arg) {
    rz_thread_arg_t* arg = (rz_thread_arg_t*)raw_arg;
    for (size_t i = 0; i < arg->count; i++) {
        uintptr_t val = arg->start_val + i;
        uint64_t cid = 0;
        lfq_status_t s = lfq_rendezvous_send(arg->chan, (void*)val, &cid);
        TEST_ASSERT(s == LFQ_OK, "lfq_rendezvous_send failed in sender worker");
        TEST_ASSERT(cid > 0, "Correlation ID should be positive");
        if (arg->corr_ids != NULL) {
            arg->corr_ids[i] = cid;
        }
    }
    return NULL;
}

static void* rz_receiver_worker(void* raw_arg) {
    rz_thread_arg_t* arg = (rz_thread_arg_t*)raw_arg;
    for (size_t i = 0; i < arg->count; i++) {
        void* item = NULL;
        uint64_t cid = 0;
        lfq_status_t s = lfq_rendezvous_recv(arg->chan, &item, &cid);
        TEST_ASSERT(s == LFQ_OK, "lfq_rendezvous_recv failed in receiver worker");
        uintptr_t val = (uintptr_t)item;
        TEST_ASSERT(val == arg->start_val + i, "Received item mismatch");
        TEST_ASSERT(cid > 0, "Correlation ID should be positive");
        if (arg->corr_ids != NULL) {
            arg->corr_ids[i] = cid;
        }
    }
    return NULL;
}

typedef struct {
    lfq_rendezvous_t* chan;
    lfq_status_t result_status;
} rz_close_waiter_arg_t;

static void* rz_close_waiter_worker(void* raw_arg) {
    rz_close_waiter_arg_t* arg = (rz_close_waiter_arg_t*)raw_arg;
    void* item = NULL;
    uint64_t cid = 0;
    arg->result_status = lfq_rendezvous_recv(arg->chan, &item, &cid);
    return NULL;
}

static void test_cabi_rendezvous(void) {
    printf("Running test_cabi_rendezvous...\n");
    lfq_rendezvous_t* chan = NULL;
    lfq_status_t status = lfq_rendezvous_create(&chan);
    TEST_ASSERT(status == LFQ_OK && chan != NULL, "lfq_rendezvous_create failed");
    TEST_ASSERT(!lfq_rendezvous_is_closed(chan), "Channel should not be closed initially");

    /* 1. Immediate non-blocking operations on empty channel */
    uint64_t corr_id = 0;
    void* item = NULL;
    status = lfq_rendezvous_try_send(chan, (void*)(uintptr_t)42, &corr_id);
    TEST_ASSERT(status == LFQ_ERR_EMPTY, "try_send without receiver must return LFQ_ERR_EMPTY");
    status = lfq_rendezvous_try_recv(chan, &item, &corr_id);
    TEST_ASSERT(status == LFQ_ERR_EMPTY, "try_recv without sender must return LFQ_ERR_EMPTY");

    /* 2. Bounded timeout operations without matching peer */
    status = lfq_rendezvous_send_timeout(chan, (void*)(uintptr_t)42, 10, &corr_id);
    TEST_ASSERT(status == LFQ_ERR_EMPTY, "send_timeout without receiver must return LFQ_ERR_EMPTY");
    status = lfq_rendezvous_recv_timeout(chan, &item, 10, &corr_id);
    TEST_ASSERT(status == LFQ_ERR_EMPTY, "recv_timeout without sender must return LFQ_ERR_EMPTY");

    /* 3. Bilateral handoff across threads with correlation ID identity */
    const size_t NUM_HANDOFFS = 200;
    uint64_t* sender_cids = (uint64_t*)calloc(NUM_HANDOFFS, sizeof(uint64_t));
    uint64_t* receiver_cids = (uint64_t*)calloc(NUM_HANDOFFS, sizeof(uint64_t));
    TEST_ASSERT(sender_cids != NULL && receiver_cids != NULL, "calloc failed");

    rz_thread_arg_t sender_arg = {
        chan,
        NUM_HANDOFFS,
        1000,
        sender_cids
    };
    rz_thread_arg_t receiver_arg = {
        chan,
        NUM_HANDOFFS,
        1000,
        receiver_cids
    };

    pthread_t th_recv, th_send;
    pthread_create(&th_recv, NULL, rz_receiver_worker, &receiver_arg);
    pthread_create(&th_send, NULL, rz_sender_worker, &sender_arg);

    pthread_join(th_send, NULL);
    pthread_join(th_recv, NULL);

    /* Verify 100% correlation ID identity between sender and receiver */
    for (size_t i = 0; i < NUM_HANDOFFS; i++) {
        TEST_ASSERT(sender_cids[i] != 0, "Sender cid must be non-zero");
        TEST_ASSERT(receiver_cids[i] != 0, "Receiver cid must be non-zero");
        TEST_ASSERT(sender_cids[i] == receiver_cids[i], "Sender and receiver corrId must match identically!");
        if (i > 0) {
            TEST_ASSERT(sender_cids[i] > sender_cids[i - 1], "Correlation IDs must be monotonically increasing");
        }
    }
    free(sender_cids);
    free(receiver_cids);

    /* 5. Channel closure and cancellation of waiting threads */
    lfq_rendezvous_t* chan_close = NULL;
    status = lfq_rendezvous_create(&chan_close);
    TEST_ASSERT(status == LFQ_OK && chan_close != NULL, "lfq_rendezvous_create failed");

    rz_close_waiter_arg_t close_arg = {
        chan_close,
        LFQ_OK
    };
    pthread_t th_close;
    pthread_create(&th_close, NULL, rz_close_waiter_worker, &close_arg);

    /* Give thread time to park in recv */
    struct timespec ts;
    ts.tv_sec = 0;
    ts.tv_nsec = 30000000; /* 30 ms */
    nanosleep(&ts, NULL);

    status = lfq_rendezvous_close(chan_close);
    TEST_ASSERT(status == LFQ_OK, "lfq_rendezvous_close failed");
    TEST_ASSERT(lfq_rendezvous_is_closed(chan_close), "Channel should be closed");

    pthread_join(th_close, NULL);
    TEST_ASSERT(close_arg.result_status == LFQ_ERR_CLOSED, "Waiting receiver should receive LFQ_ERR_CLOSED on channel close");

    /* Subsequent operations on closed channel must return LFQ_ERR_CLOSED */
    status = lfq_rendezvous_send(chan_close, (void*)(uintptr_t)1, &corr_id);
    TEST_ASSERT(status == LFQ_ERR_CLOSED, "send on closed channel must return LFQ_ERR_CLOSED");
    status = lfq_rendezvous_recv(chan_close, &item, &corr_id);
    TEST_ASSERT(status == LFQ_ERR_CLOSED, "recv on closed channel must return LFQ_ERR_CLOSED");
    status = lfq_rendezvous_try_send(chan_close, (void*)(uintptr_t)1, &corr_id);
    TEST_ASSERT(status == LFQ_ERR_CLOSED, "try_send on closed channel must return LFQ_ERR_CLOSED");
    status = lfq_rendezvous_try_recv(chan_close, &item, &corr_id);
    TEST_ASSERT(status == LFQ_ERR_CLOSED, "try_recv on closed channel must return LFQ_ERR_CLOSED");
    status = lfq_rendezvous_send_timeout(chan_close, (void*)(uintptr_t)1, 10, &corr_id);
    TEST_ASSERT(status == LFQ_ERR_CLOSED, "send_timeout on closed channel must return LFQ_ERR_CLOSED");
    status = lfq_rendezvous_recv_timeout(chan_close, &item, 10, &corr_id);
    TEST_ASSERT(status == LFQ_ERR_CLOSED, "recv_timeout on closed channel must return LFQ_ERR_CLOSED");

    status = lfq_rendezvous_destroy(chan_close);
    TEST_ASSERT(status == LFQ_OK, "lfq_rendezvous_destroy on closed channel failed");

    /* Destroy original channel */
    status = lfq_rendezvous_destroy(chan);
    TEST_ASSERT(status == LFQ_OK, "lfq_rendezvous_destroy failed");

    printf("test_cabi_rendezvous PASSED.\n");
}

/* -------------------------------------------------------------------------
 * Test 10: Rate Limiters (TokenBucket & LeakyBucket GCRA)
 * ------------------------------------------------------------------------- */

typedef struct {
    lfq_token_bucket_t* bucket;
    size_t iterations;
    test_atomic_size_t* total_acquired;
} tb_stress_arg_t;

static void* tb_stress_worker(void* raw_arg) {
    tb_stress_arg_t* arg = (tb_stress_arg_t*)raw_arg;
    for (size_t i = 0; i < arg->iterations; i++) {
        while (!lfq_token_bucket_try_acquire(arg->bucket, 1)) {
            #if defined(__x86_64__) || defined(_M_X64)
            __asm__ volatile("pause");
            #elif defined(__aarch64__) || defined(_M_ARM64)
            __asm__ volatile("yield");
            #endif
        }
        ATOMIC_INC(arg->total_acquired);
    }
    return NULL;
}

static void test_cabi_ratelimit(void) {
    printf("Running test_cabi_ratelimit...\n");

    /* 1. Stack-Allocated TokenBucket */
    lfq_token_bucket_t tb;
    int rc = lfq_token_bucket_init(&tb, 50, 100);
    TEST_ASSERT(rc == 0, "lfq_token_bucket_init failed");
    TEST_ASSERT(lfq_token_bucket_available(&tb) == 50, "Available tokens should be 50");

    bool ok = lfq_token_bucket_try_acquire(&tb, 20);
    TEST_ASSERT(ok, "try_acquire 20 should succeed");
    TEST_ASSERT(lfq_token_bucket_available(&tb) == 30, "Available tokens should be 30");

    ok = lfq_token_bucket_try_acquire(&tb, 30);
    TEST_ASSERT(ok, "try_acquire 30 should succeed");
    TEST_ASSERT(lfq_token_bucket_available(&tb) == 0, "Available tokens should be 0");

    ok = lfq_token_bucket_try_acquire(&tb, 1);
    TEST_ASSERT(!ok, "try_acquire 1 from empty bucket should fail");

    /* Reset */
    lfq_token_bucket_reset(&tb, 50);
    TEST_ASSERT(lfq_token_bucket_available(&tb) == 50, "Reset should restore tokens");

    /* Timed Acquire */
    ok = lfq_token_bucket_try_acquire(&tb, 50);
    TEST_ASSERT(ok, "try_acquire 50 should succeed");
    ok = lfq_token_bucket_acquire_timeout(&tb, 1, 50000000); /* 50ms timeout; 1 token refilled in 10ms */
    TEST_ASSERT(ok, "acquire_timeout should succeed after refill");

    /* Timed Acquire fail-fast */
    ok = lfq_token_bucket_try_acquire(&tb, lfq_token_bucket_available(&tb));
    ok = lfq_token_bucket_acquire_timeout(&tb, 50, 1000); /* 1us timeout for 50 tokens (needs 500ms) */
    TEST_ASSERT(!ok, "acquire_timeout should fail fast when deficit exceeds timeout");

    /* Null Resilience */
    TEST_ASSERT(lfq_token_bucket_init(NULL, 10, 10) == -1, "Init NULL bucket should return -1");
    TEST_ASSERT(!lfq_token_bucket_try_acquire(NULL, 1), "try_acquire NULL bucket should fail");
    TEST_ASSERT(!lfq_token_bucket_acquire_timeout(NULL, 1, 100), "acquire_timeout NULL bucket should fail");
    TEST_ASSERT(lfq_token_bucket_available(NULL) == 0, "available NULL bucket should return 0");
    lfq_token_bucket_reset(NULL, 10);

    /* 2. Heap-Allocated TokenBucket */
    lfq_token_bucket_t* heap_tb = lfq_token_bucket_create(100, 200);
    TEST_ASSERT(heap_tb != NULL, "lfq_token_bucket_create failed");
    TEST_ASSERT(lfq_token_bucket_available(heap_tb) == 100, "Heap bucket available mismatch");
    TEST_ASSERT(lfq_token_bucket_try_acquire(heap_tb, 40), "try_acquire on heap bucket failed");
    TEST_ASSERT(lfq_token_bucket_available(heap_tb) == 60, "Heap bucket available after acquire mismatch");
    lfq_token_bucket_destroy(heap_tb);
    lfq_token_bucket_destroy(NULL);

    /* 3. Concurrent Multithreaded Contention on TokenBucket */
    lfq_token_bucket_t* shared_tb = lfq_token_bucket_create(1000, 50000);
    TEST_ASSERT(shared_tb != NULL, "shared_tb create failed");
    enum { TB_STRESS_THREADS = 4 };
    const size_t ITERS_PER_TH = 500;
    test_atomic_size_t total_acquired = 0;
    pthread_t ths[TB_STRESS_THREADS];
    tb_stress_arg_t args[TB_STRESS_THREADS];

    for (size_t i = 0; i < TB_STRESS_THREADS; i++) {
        args[i].bucket = shared_tb;
        args[i].iterations = ITERS_PER_TH;
        args[i].total_acquired = &total_acquired;
        pthread_create(&ths[i], NULL, tb_stress_worker, &args[i]);
    }
    for (size_t i = 0; i < TB_STRESS_THREADS; i++) {
        pthread_join(ths[i], NULL);
    }
    TEST_ASSERT(ATOMIC_LOAD(&total_acquired) == TB_STRESS_THREADS * ITERS_PER_TH, "Total acquired mismatch");
    lfq_token_bucket_destroy(shared_tb);

    /* 4. Stack-Allocated LeakyBucket (GCRA) */
    lfq_leaky_bucket_t lb;
    rc = lfq_leaky_bucket_init(&lb, 200000000, 10); /* burst tolerance 200ms, leak rate 10/sec */
    TEST_ASSERT(rc == 0, "lfq_leaky_bucket_init failed");
    ok = lfq_leaky_bucket_try_consume(&lb, 1);
    TEST_ASSERT(ok, "cell 1 should conform");
    ok = lfq_leaky_bucket_try_consume(&lb, 1);
    TEST_ASSERT(ok, "cell 2 should conform");
    TEST_ASSERT(lfq_leaky_bucket_water_level(&lb) > 0, "Water level should be positive");

    /* Reset */
    lfq_leaky_bucket_reset(&lb);
    TEST_ASSERT(lfq_leaky_bucket_water_level(&lb) == 0, "Water level after reset should be 0");

    /* Timed Consume */
    ok = lfq_leaky_bucket_consume_timeout(&lb, 1, 50000000);
    TEST_ASSERT(ok, "consume_timeout should succeed");

    /* Null Resilience */
    TEST_ASSERT(lfq_leaky_bucket_init(NULL, 0, 0) == -1, "Init NULL leaky bucket should return -1");
    TEST_ASSERT(!lfq_leaky_bucket_try_consume(NULL, 1), "try_consume NULL leaky bucket should fail");
    TEST_ASSERT(!lfq_leaky_bucket_consume_timeout(NULL, 1, 100), "consume_timeout NULL leaky bucket should fail");
    TEST_ASSERT(lfq_leaky_bucket_water_level(NULL) == 0, "water_level NULL leaky bucket should return 0");
    lfq_leaky_bucket_reset(NULL);

    /* 5. Heap-Allocated LeakyBucket */
    lfq_leaky_bucket_t* heap_lb = lfq_leaky_bucket_create(100000000, 50);
    TEST_ASSERT(heap_lb != NULL, "lfq_leaky_bucket_create failed");
    TEST_ASSERT(lfq_leaky_bucket_try_consume(heap_lb, 1), "try_consume heap leaky bucket failed");
    lfq_leaky_bucket_destroy(heap_lb);
    lfq_leaky_bucket_destroy(NULL);

    printf("test_cabi_ratelimit PASSED.\n");
}

/* -------------------------------------------------------------------------
 * Test 11: Concurrent Multithreaded MPMC Queue Test via pthreads
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
    test_atomic_size_t* total_popped;
    test_atomic_uint64_t* checksum;
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
    while (ATOMIC_LOAD(arg->total_popped) < arg->target_count) {
        if (lfq_pop(cons, &item) == LFQ_OK) {
            uintptr_t val = (uintptr_t)item;
            ATOMIC_INC(arg->total_popped);
            ATOMIC_ADD(arg->checksum, (uint64_t)val);
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

    test_atomic_size_t total_popped = 0;
    test_atomic_uint64_t checksum = 0;
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

    TEST_ASSERT(ATOMIC_LOAD(&total_popped) == TOTAL_ITEMS, "Total popped count mismatch");
    TEST_ASSERT(ATOMIC_LOAD(&checksum) == expected_checksum, "Checksum mismatch");

    s = lfq_queue_destroy(queue);
    TEST_ASSERT(s == LFQ_OK, "lfq_queue_destroy failed");
    printf("test_cabi_concurrency PASSED.\n");
}

/* -------------------------------------------------------------------------
 * Test 12: StreamRing / StreamBuffer C ABI (Zero-Copy Streaming I/O)
 * ------------------------------------------------------------------------- */
typedef struct {
    lfq_stream_ring_t* ring;
    size_t total_bytes;
    test_atomic_uint64_t* checksum;
} streambuffer_worker_arg_t;

static void* streambuffer_producer_worker(void* raw_arg) {
    streambuffer_worker_arg_t* arg = (streambuffer_worker_arg_t*)raw_arg;
    size_t sent = 0;
    uint8_t val = 0;
    while (sent < arg->total_bytes) {
        size_t chunk = 64;
        if (sent + chunk > arg->total_bytes) {
            chunk = arg->total_bytes - sent;
        }
        lfq_iovec_pair_t iov = lfq_stream_ring_acquire_write_iov(arg->ring, chunk);
        size_t avail = iov.first.iov_len + iov.second.iov_len;
        if (avail == 0) {
            #if defined(__x86_64__) || defined(_M_X64)
            __asm__ volatile("pause");
            #elif defined(__aarch64__) || defined(_M_ARM64)
            __asm__ volatile("yield");
            #endif
            continue;
        }
        /* Fill first slice */
        uint8_t* p1 = (uint8_t*)iov.first.iov_base;
        for (size_t i = 0; i < iov.first.iov_len; i++) {
            p1[i] = val++;
        }
        /* Fill second slice if any */
        uint8_t* p2 = (uint8_t*)iov.second.iov_base;
        for (size_t i = 0; i < iov.second.iov_len; i++) {
            p2[i] = val++;
        }
        lfq_stream_ring_commit_write(arg->ring, avail);
        sent += avail;
    }
    return NULL;
}

static void* streambuffer_consumer_worker(void* raw_arg) {
    streambuffer_worker_arg_t* arg = (streambuffer_worker_arg_t*)raw_arg;
    size_t received = 0;
    uint64_t local_checksum = 0;
    while (received < arg->total_bytes) {
        size_t chunk = 128;
        if (received + chunk > arg->total_bytes) {
            chunk = arg->total_bytes - received;
        }
        lfq_iovec_pair_t iov = lfq_stream_ring_acquire_read_iov(arg->ring, chunk);
        size_t avail = iov.first.iov_len + iov.second.iov_len;
        if (avail == 0) {
            #if defined(__x86_64__) || defined(_M_X64)
            __asm__ volatile("pause");
            #elif defined(__aarch64__) || defined(_M_ARM64)
            __asm__ volatile("yield");
            #endif
            continue;
        }
        const uint8_t* p1 = (const uint8_t*)iov.first.iov_base;
        for (size_t i = 0; i < iov.first.iov_len; i++) {
            local_checksum += p1[i];
        }
        const uint8_t* p2 = (const uint8_t*)iov.second.iov_base;
        for (size_t i = 0; i < iov.second.iov_len; i++) {
            local_checksum += p2[i];
        }
        lfq_stream_ring_commit_read(arg->ring, avail);
        received += avail;
    }
    ATOMIC_ADD(arg->checksum, local_checksum);
    return NULL;
}

static void test_cabi_streambuffer(void) {
    printf("Running test_cabi_streambuffer...\n");

    /* 1. Lifecycle and Metrics */
    lfq_stream_ring_t* ring = lfq_stream_ring_create(1024, false);
    TEST_ASSERT(ring != NULL, "lfq_stream_ring_create failed");
    TEST_ASSERT(lfq_stream_ring_capacity(ring) == 1024, "Stream ring capacity mismatch");
    TEST_ASSERT(lfq_stream_ring_available_read(ring) == 0, "Available read should be 0");
    TEST_ASSERT(lfq_stream_ring_available_write(ring) == 1024, "Available write should be 1024");
    TEST_ASSERT(lfq_stream_ring_is_empty(ring), "Should be empty");
    TEST_ASSERT(!lfq_stream_ring_is_full(ring), "Should not be full");

    /* 2. Basic Copy Read/Write */
    const char* msg = "Hello, LockFree StreamRing C ABI!";
    size_t msg_len = strlen(msg);
    size_t written = lfq_stream_ring_try_write(ring, msg, msg_len);
    TEST_ASSERT(written == msg_len, "try_write length mismatch");
    TEST_ASSERT(lfq_stream_ring_available_read(ring) == msg_len, "Available read mismatch");
    TEST_ASSERT(lfq_stream_ring_available_write(ring) == 1024 - msg_len, "Available write mismatch");
    TEST_ASSERT(!lfq_stream_ring_is_empty(ring), "Should not be empty");

    char buf[64];
    memset(buf, 0, sizeof(buf));
    size_t read_bytes = lfq_stream_ring_try_read(ring, buf, sizeof(buf));
    TEST_ASSERT(read_bytes == msg_len, "try_read length mismatch");
    TEST_ASSERT(memcmp(buf, msg, msg_len) == 0, "Read data content mismatch");
    TEST_ASSERT(lfq_stream_ring_is_empty(ring), "Should be empty after read");

    /* 3. Zero-Copy IOVec Wrap-Around Test */
    lfq_stream_ring_destroy(ring);
    ring = lfq_stream_ring_create(1024, false);
    TEST_ASSERT(ring != NULL, "lfq_stream_ring_create failed");

    /* Advance head and tail to offset 1000 */
    uint8_t dummy[1000];
    memset(dummy, 0xCC, sizeof(dummy));
    written = lfq_stream_ring_try_write(ring, dummy, sizeof(dummy));
    TEST_ASSERT(written == sizeof(dummy), "Dummy write failed");
    read_bytes = lfq_stream_ring_try_read(ring, dummy, sizeof(dummy));
    TEST_ASSERT(read_bytes == sizeof(dummy), "Dummy read failed");
    TEST_ASSERT(lfq_stream_ring_is_empty(ring), "Should be empty after dummy read");

    /* Now write cursor is at 1000. Request 100 bytes (24 bytes remaining to capacity 1024, 76 bytes wrap) */
    lfq_iovec_pair_t w_iov = lfq_stream_ring_acquire_write_iov(ring, 100);
    TEST_ASSERT(w_iov.first.iov_len == 24, "First write slice length should be 24");
    TEST_ASSERT(w_iov.first.iov_base != NULL, "First write slice base should not be NULL");
    TEST_ASSERT(w_iov.second.iov_len == 76, "Second write slice length should be 76");
    TEST_ASSERT(w_iov.second.iov_base != NULL, "Second write slice base should not be NULL");

    memset(w_iov.first.iov_base, 0xAA, 24);
    memset(w_iov.second.iov_base, 0xBB, 76);
    lfq_stream_ring_commit_write(ring, 100);
    TEST_ASSERT(lfq_stream_ring_available_read(ring) == 100, "Available read should be 100");

    /* Read via IOVec */
    lfq_iovec_pair_t r_iov = lfq_stream_ring_acquire_read_iov(ring, 100);
    TEST_ASSERT(r_iov.first.iov_len == 24, "First read slice length should be 24");
    TEST_ASSERT(r_iov.second.iov_len == 76, "Second read slice length should be 76");
    const uint8_t* r1 = (const uint8_t*)r_iov.first.iov_base;
    for (size_t i = 0; i < 24; i++) {
        TEST_ASSERT(r1[i] == 0xAA, "Slice 1 byte mismatch");
    }
    const uint8_t* r2 = (const uint8_t*)r_iov.second.iov_base;
    for (size_t i = 0; i < 76; i++) {
        TEST_ASSERT(r2[i] == 0xBB, "Slice 2 byte mismatch");
    }
    lfq_stream_ring_commit_read(ring, 100);
    TEST_ASSERT(lfq_stream_ring_is_empty(ring), "Should be empty after commit read");

    /* 4. Blocking I/O with Timeout */
    /* Empty ring read with 1ms timeout should return 0 */
    read_bytes = lfq_stream_ring_read_blocking(ring, buf, 10, 1000000);
    TEST_ASSERT(read_bytes == 0, "read_blocking on empty ring should timeout with 0 bytes");

    written = lfq_stream_ring_write_blocking(ring, "BLOCKING", 8, 10000000);
    TEST_ASSERT(written == 8, "write_blocking failed");
    read_bytes = lfq_stream_ring_read_blocking(ring, buf, 8, 10000000);
    TEST_ASSERT(read_bytes == 8, "read_blocking failed");
    TEST_ASSERT(memcmp(buf, "BLOCKING", 8) == 0, "read_blocking content mismatch");

    lfq_stream_ring_destroy(ring);

    /* 5. StreamBuffer Aliases & Creation */
    lfq_streambuffer_t* sbuf = lfq_streambuffer_create(512, false);
    TEST_ASSERT(sbuf != NULL, "lfq_streambuffer_create failed");
    TEST_ASSERT(lfq_streambuffer_capacity(sbuf) == 512, "Capacity mismatch");
    TEST_ASSERT(lfq_streambuffer_is_empty(sbuf), "Should be empty");
    TEST_ASSERT(!lfq_streambuffer_is_full(sbuf), "Should not be full");
    TEST_ASSERT(lfq_streambuffer_available_read(sbuf) == 0, "Available read mismatch");
    TEST_ASSERT(lfq_streambuffer_available_write(sbuf) == 512, "Available write mismatch");

    written = lfq_streambuffer_try_write(sbuf, "ALIASTEST", 9);
    TEST_ASSERT(written == 9, "streambuffer try_write failed");
    read_bytes = lfq_streambuffer_try_read(sbuf, buf, sizeof(buf));
    TEST_ASSERT(read_bytes == 9, "streambuffer try_read failed");
    TEST_ASSERT(memcmp(buf, "ALIASTEST", 9) == 0, "streambuffer content mismatch");

    lfq_iovec_pair_t sb_iov = lfq_streambuffer_acquire_write_iov(sbuf, 32);
    TEST_ASSERT(sb_iov.first.iov_len + sb_iov.second.iov_len == 32, "IOVec length mismatch");
    lfq_streambuffer_commit_write(sbuf, 32);
    lfq_iovec_pair_t sb_riov = lfq_streambuffer_acquire_read_iov(sbuf, 32);
    TEST_ASSERT(sb_riov.first.iov_len + sb_riov.second.iov_len == 32, "Read IOVec length mismatch");
    lfq_streambuffer_commit_read(sbuf, 32);

    written = lfq_streambuffer_write_blocking(sbuf, "BLK", 3, 5000000);
    TEST_ASSERT(written == 3, "streambuffer write_blocking failed");
    read_bytes = lfq_streambuffer_read_blocking(sbuf, buf, 3, 5000000);
    TEST_ASSERT(read_bytes == 3, "streambuffer read_blocking failed");

    /* 6. Status-returning Two-Phase Reserve/Commit & Peek/Consume C ABI */
    uint8_t* ptr1 = NULL;
    size_t len1 = 0;
    uint8_t* ptr2 = NULL;
    size_t len2 = 0;
    const uint8_t* cptr1 = NULL;
    const uint8_t* cptr2 = NULL;

    TEST_ASSERT(lf_stream_reserve_write(NULL, 16, &ptr1, &len1, &ptr2, &len2) == LF_ERR_INVALID_ARG, "reserve_write NULL sb");
    TEST_ASSERT(lf_stream_reserve_write(sbuf, 16, NULL, &len1, &ptr2, &len2) == LF_ERR_INVALID_ARG, "reserve_write NULL out_ptr1");
    TEST_ASSERT(lf_stream_reserve_write(sbuf, 16, &ptr1, NULL, &ptr2, &len2) == LF_ERR_INVALID_ARG, "reserve_write NULL out_len1");
    TEST_ASSERT(lf_stream_reserve_write(sbuf, 1024, &ptr1, &len1, &ptr2, &len2) == LF_ERR_INVALID_ARG, "reserve_write > cap");
    TEST_ASSERT(lf_stream_peek_read(sbuf, &cptr1, &len1, &cptr2, &len2) == LF_ERR_EMPTY, "peek_read on empty sbuf");

    TEST_ASSERT(lf_stream_reserve_write(sbuf, 32, &ptr1, &len1, &ptr2, &len2) == LF_OK, "lf_stream_reserve_write 32 failed");
    TEST_ASSERT(ptr1 != NULL && (len1 + len2) == 32, "lf_stream_reserve_write slice lengths mismatch");
    for (size_t i = 0; i < len1; i++) ptr1[i] = (uint8_t)(i + 1);
    for (size_t i = 0; i < len2; i++) ptr2[i] = (uint8_t)(len1 + i + 1);
    TEST_ASSERT(lf_stream_commit_write(sbuf, 32) == LF_OK, "lf_stream_commit_write 32 failed");

    TEST_ASSERT(lf_stream_peek_read(sbuf, &cptr1, &len1, &cptr2, &len2) == LF_OK, "lf_stream_peek_read 32 failed");
    TEST_ASSERT(cptr1 != NULL && (len1 + len2) == 32, "lf_stream_peek_read slice lengths mismatch");
    for (size_t i = 0; i < len1; i++) TEST_ASSERT(cptr1[i] == (uint8_t)(i + 1), "peek_read slice 1 byte mismatch");
    for (size_t i = 0; i < len2; i++) TEST_ASSERT(cptr2[i] == (uint8_t)(len1 + i + 1), "peek_read slice 2 byte mismatch");
    TEST_ASSERT(lf_stream_consume_read(sbuf, 32) == LF_OK, "lf_stream_consume_read 32 failed");
    TEST_ASSERT(lf_streambuffer_is_empty(sbuf), "sbuf should be empty after consume_read");

    lfq_streambuffer_destroy(sbuf);

    /* 6. Null Resilience */
    lfq_stream_ring_destroy(NULL);
    lfq_streambuffer_destroy(NULL);
    TEST_ASSERT(lfq_stream_ring_capacity(NULL) == 0, "capacity(NULL) should be 0");
    TEST_ASSERT(lfq_stream_ring_available_read(NULL) == 0, "available_read(NULL) should be 0");
    TEST_ASSERT(lfq_stream_ring_available_write(NULL) == 0, "available_write(NULL) should be 0");
    TEST_ASSERT(lfq_stream_ring_is_empty(NULL), "is_empty(NULL) should be true");
    TEST_ASSERT(!lfq_stream_ring_is_full(NULL), "is_full(NULL) should be false");
    TEST_ASSERT(lfq_stream_ring_try_write(NULL, "a", 1) == 0, "try_write(NULL) should be 0");
    TEST_ASSERT(lfq_stream_ring_try_read(NULL, buf, 1) == 0, "try_read(NULL) should be 0");
    TEST_ASSERT(lfq_stream_ring_write_blocking(NULL, "a", 1, 100) == 0, "write_blocking(NULL) should be 0");
    TEST_ASSERT(lfq_stream_ring_read_blocking(NULL, buf, 1, 100) == 0, "read_blocking(NULL) should be 0");
    lfq_iovec_pair_t null_iov = lfq_stream_ring_acquire_write_iov(NULL, 10);
    TEST_ASSERT(null_iov.first.iov_len == 0 && null_iov.second.iov_len == 0, "acquire_write_iov(NULL) should return empty");
    null_iov = lfq_stream_ring_acquire_read_iov(NULL, 10);
    TEST_ASSERT(null_iov.first.iov_len == 0 && null_iov.second.iov_len == 0, "acquire_read_iov(NULL) should return empty");
    lfq_stream_ring_commit_write(NULL, 10);
    lfq_stream_ring_commit_read(NULL, 10);

    /* 7. Concurrent SPSC Producer-Consumer Thread Test */
    const size_t CONCURRENT_BYTES = 50000;
    lfq_stream_ring_t* conc_ring = lfq_stream_ring_create(4096, false);
    TEST_ASSERT(conc_ring != NULL, "Concurrent ring create failed");

    test_atomic_uint64_t cons_checksum = 0;
    streambuffer_worker_arg_t prod_arg = {
        .ring = conc_ring,
        .total_bytes = CONCURRENT_BYTES,
        .checksum = NULL
    };
    streambuffer_worker_arg_t cons_arg = {
        .ring = conc_ring,
        .total_bytes = CONCURRENT_BYTES,
        .checksum = &cons_checksum
    };

    pthread_t th_prod, th_cons;
    pthread_create(&th_prod, NULL, streambuffer_producer_worker, &prod_arg);
    pthread_create(&th_cons, NULL, streambuffer_consumer_worker, &cons_arg);

    pthread_join(th_prod, NULL);
    pthread_join(th_cons, NULL);

    /* Calculate expected checksum */
    uint64_t expected_checksum = 0;
    uint8_t v = 0;
    for (size_t i = 0; i < CONCURRENT_BYTES; i++) {
        expected_checksum += v++;
    }
    TEST_ASSERT(ATOMIC_LOAD(&cons_checksum) == expected_checksum, "Concurrent stream checksum mismatch");
    TEST_ASSERT(lfq_stream_ring_is_empty(conc_ring), "Concurrent ring should be empty after test");

    lfq_stream_ring_destroy(conc_ring);

    /* 8. MPMCStreamRing C ABI Test */
    lfq_mpmc_stream_ring_t* mpmc_ring = lfq_mpmc_stream_ring_create(1024);
    TEST_ASSERT(mpmc_ring != NULL, "lfq_mpmc_stream_ring_create failed");
    TEST_ASSERT(lfq_mpmc_stream_ring_capacity(mpmc_ring) == 1024, "MPMCStreamRing capacity mismatch");
    TEST_ASSERT(lfq_mpmc_stream_ring_available_read(mpmc_ring) == 0, "MPMCStreamRing initial available_read should be 0");
    TEST_ASSERT(lfq_mpmc_stream_ring_available_write(mpmc_ring) == 1024, "MPMCStreamRing initial available_write should be 1024");
    TEST_ASSERT(lfq_mpmc_stream_ring_is_empty(mpmc_ring), "MPMCStreamRing should be empty initially");
    TEST_ASSERT(!lfq_mpmc_stream_ring_is_full(mpmc_ring), "MPMCStreamRing should not be full initially");

    const char* mpmc_msg = "MPMCStreamRing C99 Test Payload";
    size_t mpmc_msg_len = strlen(mpmc_msg);
    size_t mpmc_w = lfq_mpmc_stream_ring_try_write(mpmc_ring, mpmc_msg, mpmc_msg_len);
    TEST_ASSERT(mpmc_w == mpmc_msg_len, "lfq_mpmc_stream_ring_try_write failed");
    TEST_ASSERT(lfq_mpmc_stream_ring_available_read(mpmc_ring) == mpmc_msg_len, "MPMCStreamRing available_read mismatch");
    TEST_ASSERT(!lfq_mpmc_stream_ring_is_empty(mpmc_ring), "MPMCStreamRing should not be empty after write");

    memset(buf, 0, sizeof(buf));
    size_t mpmc_r = lfq_mpmc_stream_ring_try_read(mpmc_ring, buf, sizeof(buf));
    TEST_ASSERT(mpmc_r == mpmc_msg_len, "lfq_mpmc_stream_ring_try_read failed");
    TEST_ASSERT(memcmp(buf, mpmc_msg, mpmc_msg_len) == 0, "MPMCStreamRing read payload mismatch");
    TEST_ASSERT(lfq_mpmc_stream_ring_is_empty(mpmc_ring), "MPMCStreamRing should be empty after read");

    lfq_mpmc_stream_ring_destroy(mpmc_ring);
    lfq_mpmc_stream_ring_destroy(NULL);
    TEST_ASSERT(lfq_mpmc_stream_ring_capacity(NULL) == 0, "mpmc capacity(NULL) should be 0");
    TEST_ASSERT(lfq_mpmc_stream_ring_available_read(NULL) == 0, "mpmc available_read(NULL) should be 0");
    TEST_ASSERT(lfq_mpmc_stream_ring_available_write(NULL) == 0, "mpmc available_write(NULL) should be 0");
    TEST_ASSERT(lfq_mpmc_stream_ring_is_empty(NULL), "mpmc is_empty(NULL) should be true");
    TEST_ASSERT(!lfq_mpmc_stream_ring_is_full(NULL), "mpmc is_full(NULL) should be false");

    printf("test_cabi_streambuffer PASSED.\n");
}

/* -------------------------------------------------------------------------
 * Test 13: Atomic Associative Map Operations (Ctrie & SkipListMap)
 * ------------------------------------------------------------------------- */

static void* test_mapping_cb(const void* key, size_t key_len, void* user_data) {
    (void)key_len;
    (void)user_data;
    uintptr_t k = (uintptr_t)key;
    return (void*)(k * 10);
}

static void* test_update_cb(const void* old_val, size_t old_val_len, void* user_data) {
    (void)old_val_len;
    (void)user_data;
    uintptr_t v = (uintptr_t)old_val;
    return (void*)(v + 1);
}

typedef struct {
    lfq_ctrie_t* ctrie;
    lfq_skiplist_t* skiplist;
    size_t increments;
    void* target_key;
} assoc_worker_arg_t;

static void* assoc_ctrie_worker(void* raw_arg) {
    assoc_worker_arg_t* arg = (assoc_worker_arg_t*)raw_arg;
    for (size_t i = 0; i < arg->increments; i++) {
        void* out_v = NULL;
        size_t out_len = 0;
        bool ok = lfq_ctrie_atomic_update(arg->ctrie, arg->target_key, 0, test_update_cb, NULL, &out_v, &out_len);
        TEST_ASSERT(ok, "ctrie atomic_update must succeed on present key");
    }
    return NULL;
}

static void* assoc_skiplist_worker(void* raw_arg) {
    assoc_worker_arg_t* arg = (assoc_worker_arg_t*)raw_arg;
    for (size_t i = 0; i < arg->increments; i++) {
        void* out_v = NULL;
        size_t out_len = 0;
        bool ok = lfq_skiplist_atomic_update(arg->skiplist, arg->target_key, 0, test_update_cb, NULL, &out_v, &out_len);
        TEST_ASSERT(ok, "skiplist atomic_update must succeed on present key");
    }
    return NULL;
}

static void test_cabi_associative(void) {
    printf("Running test_cabi_associative...\n");

    /* 1. Ctrie compute_if_absent & atomic_update */
    lfq_ctrie_t* ctrie = NULL;
    lfq_status_t s = lfq_ctrie_create(NULL, NULL, &ctrie);
    TEST_ASSERT(s == LFQ_OK && ctrie != NULL, "lfq_ctrie_create failed");

    void* out_val = NULL;
    size_t out_len = 0;

    /* computeIfAbsent on absent key: should compute 42 * 10 = 420 */
    bool ok = lfq_ctrie_compute_if_absent(ctrie, (void*)(uintptr_t)42, 0, test_mapping_cb, NULL, &out_val, &out_len);
    TEST_ASSERT(ok, "compute_if_absent on absent key should succeed");
    TEST_ASSERT((uintptr_t)out_val == 420, "Computed value mismatch");

    /* computeIfAbsent on existing key: should return existing value (420) without re-computing */
    out_val = NULL;
    ok = lfq_ctrie_compute_if_absent(ctrie, (void*)(uintptr_t)42, 0, test_mapping_cb, NULL, &out_val, &out_len);
    TEST_ASSERT(ok, "compute_if_absent on existing key should succeed");
    TEST_ASSERT((uintptr_t)out_val == 420, "Existing value mismatch");

    /* atomicUpdate on missing key: should return false */
    ok = lfq_ctrie_atomic_update(ctrie, (void*)(uintptr_t)999, 0, test_update_cb, NULL, &out_val, &out_len);
    TEST_ASSERT(!ok, "atomic_update on missing key must return false");

    /* atomicUpdate on existing key: should increment 420 -> 421 */
    ok = lfq_ctrie_atomic_update(ctrie, (void*)(uintptr_t)42, 0, test_update_cb, NULL, &out_val, &out_len);
    TEST_ASSERT(ok, "atomic_update on existing key must succeed");
    TEST_ASSERT((uintptr_t)out_val == 421, "Updated value mismatch");

    /* 2. SkipListMap compute_if_absent & atomic_update */
    lfq_table_t* table = NULL;
    s = lfq_table_create(NULL, NULL, &table);
    TEST_ASSERT(s == LFQ_OK && table != NULL, "lfq_table_create failed");
    lfq_skiplist_t* skiplist = (lfq_skiplist_t*)table;

    /* computeIfAbsent on absent key */
    out_val = NULL;
    ok = lfq_skiplist_compute_if_absent(skiplist, (void*)(uintptr_t)55, 0, test_mapping_cb, NULL, &out_val, &out_len);
    TEST_ASSERT(ok, "skiplist compute_if_absent on absent key should succeed");
    TEST_ASSERT((uintptr_t)out_val == 550, "Computed value mismatch");

    /* computeIfAbsent on existing key */
    out_val = NULL;
    ok = lfq_skiplist_compute_if_absent(skiplist, (void*)(uintptr_t)55, 0, test_mapping_cb, NULL, &out_val, &out_len);
    TEST_ASSERT(ok, "skiplist compute_if_absent on existing key should succeed");
    TEST_ASSERT((uintptr_t)out_val == 550, "Existing value mismatch");

    /* atomicUpdate on missing key */
    ok = lfq_skiplist_atomic_update(skiplist, (void*)(uintptr_t)999, 0, test_update_cb, NULL, &out_val, &out_len);
    TEST_ASSERT(!ok, "skiplist atomic_update on missing key must return false");

    /* atomicUpdate on existing key */
    ok = lfq_skiplist_atomic_update(skiplist, (void*)(uintptr_t)55, 0, test_update_cb, NULL, &out_val, &out_len);
    TEST_ASSERT(ok, "skiplist atomic_update on existing key must succeed");
    TEST_ASSERT((uintptr_t)out_val == 551, "Updated value mismatch");

    /* Table aliases */
    out_val = NULL;
    ok = lfq_table_compute_if_absent(table, (void*)(uintptr_t)77, 0, test_mapping_cb, NULL, &out_val, &out_len);
    TEST_ASSERT(ok && (uintptr_t)out_val == 770, "table alias compute_if_absent failed");
    ok = lfq_table_atomic_update(table, (void*)(uintptr_t)77, 0, test_update_cb, NULL, &out_val, &out_len);
    TEST_ASSERT(ok && (uintptr_t)out_val == 771, "table alias atomic_update failed");

    /* 3. Null resilience */
    TEST_ASSERT(!lfq_ctrie_compute_if_absent(NULL, NULL, 0, NULL, NULL, NULL, NULL), "ctrie compute NULL resilience");
    TEST_ASSERT(!lfq_ctrie_atomic_update(NULL, NULL, 0, NULL, NULL, NULL, NULL), "ctrie update NULL resilience");
    TEST_ASSERT(!lfq_skiplist_compute_if_absent(NULL, NULL, 0, NULL, NULL, NULL, NULL), "skiplist compute NULL resilience");
    TEST_ASSERT(!lfq_skiplist_atomic_update(NULL, NULL, 0, NULL, NULL, NULL, NULL), "skiplist update NULL resilience");

    /* 4. Concurrent Multithreaded Lost-Update Stress Test */
    const size_t NUM_THREADS = 4;
    const size_t INCS_PER_THREAD = 2500;
    pthread_t c_ths[NUM_THREADS];
    pthread_t s_ths[NUM_THREADS];
    assoc_worker_arg_t c_args[NUM_THREADS];
    assoc_worker_arg_t s_args[NUM_THREADS];

    /* Put initial 0 for counter keys */
    void* counter_key = (void*)(uintptr_t)12345;
    bool inserted = false;
    lfq_ctrie_insert(ctrie, counter_key, (void*)(uintptr_t)0, &inserted);
    lfq_table_put(table, counter_key, (void*)(uintptr_t)0, &inserted);

    for (size_t i = 0; i < NUM_THREADS; i++) {
        c_args[i].ctrie = ctrie;
        c_args[i].skiplist = skiplist;
        c_args[i].increments = INCS_PER_THREAD;
        c_args[i].target_key = counter_key;
        pthread_create(&c_ths[i], NULL, assoc_ctrie_worker, &c_args[i]);

        s_args[i].ctrie = ctrie;
        s_args[i].skiplist = skiplist;
        s_args[i].increments = INCS_PER_THREAD;
        s_args[i].target_key = counter_key;
        pthread_create(&s_ths[i], NULL, assoc_skiplist_worker, &s_args[i]);
    }

    for (size_t i = 0; i < NUM_THREADS; i++) {
        pthread_join(c_ths[i], NULL);
        pthread_join(s_ths[i], NULL);
    }

    /* Verify zero lost updates! Final value MUST be exactly NUM_THREADS * INCS_PER_THREAD */
    uintptr_t expected_total = NUM_THREADS * INCS_PER_THREAD;
    void* final_ctrie_val = NULL;
    lfq_ctrie_lookup(ctrie, counter_key, &final_ctrie_val);
    TEST_ASSERT((uintptr_t)final_ctrie_val == expected_total, "Ctrie lost updates detected!");

    void* final_skiplist_val = NULL;
    lfq_table_get(table, counter_key, &final_skiplist_val);
    TEST_ASSERT((uintptr_t)final_skiplist_val == expected_total, "SkipList lost updates detected!");

    lfq_ctrie_destroy(ctrie);
    lfq_table_destroy(table);

    printf("test_cabi_associative PASSED.\n");
}

/* -------------------------------------------------------------------------
 * Test 14: AtomicArc & ArcGuard (128-Bit DWCAS Split-Refcount)
 * ------------------------------------------------------------------------- */
typedef struct {
    test_atomic_size_t destroyed_count;
    test_atomic_uint64_t destroyed_sum;
} arc_c_tracker_t;

static void arc_c_destructor(void* item, void* user_data) {
    arc_c_tracker_t* tr = (arc_c_tracker_t*)user_data;
    if (tr != NULL) {
        ATOMIC_INC(&tr->destroyed_count);
        ATOMIC_ADD(&tr->destroyed_sum, (uint64_t)(uintptr_t)item);
    }
}

static void test_cabi_atomic_arc(void) {
    printf("Running test_cabi_atomic_arc...\n");
    arc_c_tracker_t tracker = { 0, 0 };
    lfq_atomic_arc_t* arc = NULL;
    lfq_status_t st = lfq_atomic_arc_create((void*)(uintptr_t)100, arc_c_destructor, &tracker, &arc);
    TEST_ASSERT(st == LFQ_OK && arc != NULL, "lfq_atomic_arc_create failed");
    TEST_ASSERT(!lfq_atomic_arc_is_null(arc), "arc should not be null");

    lfq_arc_guard_t* g1 = NULL;
    st = lfq_atomic_arc_load(arc, &g1);
    TEST_ASSERT(st == LFQ_OK && g1 != NULL, "lfq_atomic_arc_load failed");
    TEST_ASSERT((uintptr_t)lfq_arc_guard_get(g1) == 100, "lfq_arc_guard_get mismatch");

    st = lfq_atomic_arc_store(arc, (void*)(uintptr_t)200, arc_c_destructor, &tracker);
    TEST_ASSERT(st == LFQ_OK, "lfq_atomic_arc_store failed");
    TEST_ASSERT(ATOMIC_LOAD(&tracker.destroyed_count) == 0, "100 should still be alive via g1");

    TEST_ASSERT(lfq_arc_guard_release(g1) == LFQ_OK, "lfq_arc_guard_release failed");
    TEST_ASSERT(ATOMIC_LOAD(&tracker.destroyed_count) == 1, "100 should be destroyed after g1 release");
    TEST_ASSERT(ATOMIC_LOAD(&tracker.destroyed_sum) == 100, "destroyed_sum should be 100");

    TEST_ASSERT(lfq_atomic_arc_destroy(arc) == LFQ_OK, "lfq_atomic_arc_destroy failed");
    TEST_ASSERT(ATOMIC_LOAD(&tracker.destroyed_count) == 2, "200 should be destroyed after arc destroy");
    TEST_ASSERT(ATOMIC_LOAD(&tracker.destroyed_sum) == 300, "destroyed_sum should be 300");
    printf("test_cabi_atomic_arc PASSED.\n");
}

/* -------------------------------------------------------------------------
 * Test 15: FlatCombiner (lfq_flat_combiner_*) Lifecycle & Combining
 * ------------------------------------------------------------------------- */
typedef struct {
    int64_t acc;
    int destroyed;
} fc_cabi_state_t;

static void* fc_cabi_default_op(void* state, void* op_arg, void* user_data) {
    fc_cabi_state_t* st = (fc_cabi_state_t*)state;
    intptr_t delta = (intptr_t)op_arg;
    intptr_t bonus = user_data != NULL ? (intptr_t)user_data : 0;
    st->acc += (int64_t)(delta + bonus);
    return (void*)(intptr_t)st->acc;
}

static void* fc_cabi_mul_op(void* state, void* op_arg, void* user_data) {
    (void)user_data;
    fc_cabi_state_t* st = (fc_cabi_state_t*)state;
    intptr_t factor = (intptr_t)op_arg;
    st->acc *= (int64_t)factor;
    return (void*)(intptr_t)st->acc;
}

static void fc_cabi_destructor(void* state, void* user_data) {
    if (state != NULL) {
        fc_cabi_state_t* st = (fc_cabi_state_t*)state;
        st->destroyed += 1;
    }
    if (user_data != NULL) {
        int* flag = (int*)user_data;
        *flag += 1;
    }
}

static void test_cabi_flat_combiner(void) {
    printf("Running test_cabi_flat_combiner...\n");

    fc_cabi_state_t state = {0, 0};
    int destroy_flag = 0;
    lfq_flat_combiner_t* combiner = NULL;

    TEST_ASSERT(lfq_flat_combiner_create(NULL, fc_cabi_default_op, NULL, NULL, 0, 0, NULL) == LFQ_ERR_INVALID_ARG,
                "lfq_flat_combiner_create NULL out_combiner should fail");

    lfq_status_t st = lfq_flat_combiner_create(
        &state,
        fc_cabi_default_op,
        fc_cabi_destructor,
        &destroy_flag,
        8,
        64,
        &combiner
    );
    TEST_ASSERT(st == LFQ_OK && combiner != NULL, "lfq_flat_combiner_create failed");

    void* res = NULL;
    st = lfq_flat_combiner_combine(combiner, (void*)(intptr_t)15, &res);
    TEST_ASSERT(st == LFQ_OK, "lfq_flat_combiner_combine failed");

    state.acc = 10;
    st = lfq_flat_combiner_combine_fn(combiner, fc_cabi_mul_op, (void*)(intptr_t)4, NULL, &res);
    TEST_ASSERT(st == LFQ_OK && (intptr_t)res == 40 && state.acc == 40, "lfq_flat_combiner_combine_fn failed");
    TEST_ASSERT(lfq_flat_combiner_total_combined_ops(combiner) == 2, "total_combined_ops should be 2");
    TEST_ASSERT(lfq_flat_combiner_pass_count(combiner) >= 1, "pass_count should be >= 1");

    destroy_flag = 0;
    st = lfq_flat_combiner_destroy(combiner);
    TEST_ASSERT(st == LFQ_OK, "lfq_flat_combiner_destroy failed");
    TEST_ASSERT(state.destroyed == 1 && destroy_flag == 1, "FlatCombiner state destructor not invoked");

    printf("test_cabi_flat_combiner PASSED.\n");
}

/* -------------------------------------------------------------------------
 * Test 16: Bounded Stack (lfq_bstack_*) Lifecycle, Bounds, LIFO & MPMC
 * ------------------------------------------------------------------------- */
typedef struct {
    lfq_bstack_t* stack;
    size_t items_per_thread;
    size_t thread_idx;
    test_atomic_uint64_t* pop_sum;
    test_atomic_size_t* pop_count;
} bstack_worker_arg_t;

static void* bstack_mpmc_worker(void* raw_arg) {
    bstack_worker_arg_t* arg = (bstack_worker_arg_t*)raw_arg;
    size_t pushed = 0;
    size_t popped = 0;
    while (pushed < arg->items_per_thread || popped < arg->items_per_thread) {
        if (pushed < arg->items_per_thread) {
            uintptr_t val = (arg->thread_idx * 10000ULL) + pushed + 1ULL;
            if (lfq_bstack_push(arg->stack, (void*)val) == LFQ_OK) {
                pushed++;
            }
        }
        if (popped < arg->items_per_thread) {
            void* item = NULL;
            if (lfq_bstack_pop(arg->stack, &item) == LFQ_OK) {
                ATOMIC_ADD(arg->pop_sum, (uint64_t)(uintptr_t)item);
                ATOMIC_INC(arg->pop_count);
                popped++;
            }
        }
    }
    return NULL;
}

static void test_cabi_bstack(void) {
    printf("Running test_cabi_bstack...\n");

    lfq_bstack_t* bs = NULL;
    TEST_ASSERT(lfq_bstack_create(0, NULL, NULL, &bs) == LFQ_ERR_INVALID_ARG, "bstack capacity 0 must fail");
    TEST_ASSERT(lfq_bstack_create(8, NULL, NULL, NULL) == LFQ_ERR_INVALID_ARG, "bstack NULL out_stack must fail");
    TEST_ASSERT(lfq_bstack_create(65537, NULL, NULL, &bs) == LFQ_ERR_UNSUPPORTED, "bstack capacity > 65536 must return UNSUPPORTED");
    TEST_ASSERT(lfq_bstack_destroy(NULL) == LFQ_ERR_INVALID_ARG, "bstack destroy NULL must fail");
    TEST_ASSERT(lfq_bstack_push(NULL, (void*)1) == LFQ_ERR_INVALID_ARG, "bstack push NULL must fail");
    TEST_ASSERT(lfq_bstack_pop(NULL, NULL) == LFQ_ERR_INVALID_ARG, "bstack pop NULL must fail");
    TEST_ASSERT(lfq_bstack_peek(NULL, NULL) == LFQ_ERR_INVALID_ARG, "bstack peek NULL must fail");
    TEST_ASSERT(lfq_bstack_drain(NULL, NULL, 4) == 0, "bstack drain NULL must return 0");
    TEST_ASSERT(lfq_bstack_clear(NULL) == LFQ_ERR_INVALID_ARG, "bstack clear NULL must fail");
    TEST_ASSERT(lfq_bstack_len(NULL) == 0, "bstack len NULL must be 0");
    TEST_ASSERT(lfq_bstack_capacity(NULL) == 0, "bstack capacity NULL must be 0");
    TEST_ASSERT(lfq_bstack_is_empty(NULL) == true, "bstack is_empty NULL must be true");
    TEST_ASSERT(lfq_bstack_is_full(NULL) == false, "bstack is_full NULL must be false");

    arc_c_tracker_t tracker = { 0, 0 };
    lfq_status_t st = lfq_bstack_create(7, arc_c_destructor, &tracker, &bs);
    TEST_ASSERT(st == LFQ_OK && bs != NULL, "lfq_bstack_create(7) failed");
    TEST_ASSERT(lfq_bstack_capacity(bs) == 7, "bstack capacity should be 7");
    TEST_ASSERT(lfq_bstack_len(bs) == 0 && lfq_bstack_is_empty(bs) && !lfq_bstack_is_full(bs), "initial bstack state mismatch");

    void* out_item = NULL;
    TEST_ASSERT(lfq_bstack_pop(bs, &out_item) == LFQ_ERR_EMPTY, "pop on empty bstack must return LFQ_ERR_EMPTY");
    TEST_ASSERT(lfq_bstack_peek(bs, &out_item) == LFQ_ERR_EMPTY, "peek on empty bstack must return LFQ_ERR_EMPTY");

    /* Verify (void*)0 payload push, peek, and pop (CRIT-02) */
    TEST_ASSERT(lfq_bstack_push(bs, (void*)0) == LFQ_OK, "bstack push (void*)0 failed");
    out_item = (void*)(uintptr_t)0xDEADBEEF;
    TEST_ASSERT(lfq_bstack_peek(bs, &out_item) == LFQ_OK && out_item == NULL, "bstack peek (void*)0 failed");
    out_item = (void*)(uintptr_t)0xDEADBEEF;
    TEST_ASSERT(lfq_bstack_pop(bs, &out_item) == LFQ_OK && out_item == NULL, "bstack pop (void*)0 failed");

    for (size_t i = 1; i <= 7; i++) {
        TEST_ASSERT(lfq_bstack_push(bs, (void*)(uintptr_t)(i * 10)) == LFQ_OK, "bstack push within capacity failed");
    }
    TEST_ASSERT(lfq_bstack_len(bs) == 7 && lfq_bstack_is_full(bs) && !lfq_bstack_is_empty(bs), "full bstack state mismatch");
    TEST_ASSERT(lfq_bstack_push(bs, (void*)(uintptr_t)80) == LFQ_ERR_FULL, "bstack push beyond capacity must return LFQ_ERR_FULL");

    TEST_ASSERT(lfq_bstack_peek(bs, &out_item) == LFQ_OK && (uintptr_t)out_item == 70, "bstack peek LIFO top mismatch");
    TEST_ASSERT(lfq_bstack_len(bs) == 7, "bstack peek must not remove item");

    /* Drain top 3 items via lfq_bstack_drain (CRIT-01): 70, 60, 50 */
    void* drained[4] = { NULL, NULL, NULL, NULL };
    TEST_ASSERT(lfq_bstack_drain(bs, NULL, 3) == 0, "bstack drain NULL out_items must return 0");
    TEST_ASSERT(lfq_bstack_drain(bs, drained, 0) == 0, "bstack drain max_count 0 must return 0");
    size_t dcount = lfq_bstack_drain(bs, drained, 3);
    TEST_ASSERT(dcount == 3, "bstack drain should drain 3 items");
    TEST_ASSERT((uintptr_t)drained[0] == 70 && (uintptr_t)drained[1] == 60 && (uintptr_t)drained[2] == 50,
                "bstack drain LIFO order mismatch");

    /* Pop next 2 in LIFO order: 40, 30 */
    for (size_t expected = 40; expected >= 30; expected -= 10) {
        out_item = NULL;
        TEST_ASSERT(lfq_bstack_pop(bs, &out_item) == LFQ_OK && (uintptr_t)out_item == expected, "bstack LIFO pop order mismatch");
    }
    TEST_ASSERT(lfq_bstack_len(bs) == 2, "bstack len after 5 pops should be 2");

    /* Clear remaining 2 items (20, 10) -> destructor called for both */
    TEST_ASSERT(lfq_bstack_clear(bs) == LFQ_OK, "lfq_bstack_clear failed");
    TEST_ASSERT(lfq_bstack_is_empty(bs) && lfq_bstack_len(bs) == 0, "bstack should be empty after clear");
    TEST_ASSERT(ATOMIC_LOAD(&tracker.destroyed_count) == 2 && ATOMIC_LOAD(&tracker.destroyed_sum) == 30, "bstack clear destructor mismatch");

    /* Push 1 item (99) and destroy -> destructor called on destroy */
    TEST_ASSERT(lfq_bstack_push(bs, (void*)(uintptr_t)99) == LFQ_OK, "bstack push after clear failed");
    TEST_ASSERT(lfq_bstack_destroy(bs) == LFQ_OK, "lfq_bstack_destroy failed");
    TEST_ASSERT(ATOMIC_LOAD(&tracker.destroyed_count) == 3 && ATOMIC_LOAD(&tracker.destroyed_sum) == 129, "bstack destroy destructor mismatch");

    /* Multithreaded MPMC stress test */
    lfq_bstack_t* mpmc_bs = NULL;
    TEST_ASSERT(lfq_bstack_create(128, NULL, NULL, &mpmc_bs) == LFQ_OK, "bstack create 128 failed");
    const size_t NTHREADS = 4;
    const size_t NITEMS = 1000;
    pthread_t ths[4];
    bstack_worker_arg_t args[4];
    test_atomic_uint64_t pop_sum = 0;
    test_atomic_size_t pop_count = 0;
    uint64_t expected_sum = 0;
    for (size_t t = 0; t < NTHREADS; t++) {
        for (size_t j = 0; j < NITEMS; j++) {
            expected_sum += (uint64_t)((t * 10000ULL) + j + 1ULL);
        }
        args[t].stack = mpmc_bs;
        args[t].items_per_thread = NITEMS;
        args[t].thread_idx = t;
        args[t].pop_sum = &pop_sum;
        args[t].pop_count = &pop_count;
        pthread_create(&ths[t], NULL, bstack_mpmc_worker, &args[t]);
    }
    for (size_t t = 0; t < NTHREADS; t++) {
        pthread_join(ths[t], NULL);
    }
    TEST_ASSERT(ATOMIC_LOAD(&pop_count) == NTHREADS * NITEMS, "bstack MPMC pop_count mismatch");
    TEST_ASSERT(ATOMIC_LOAD(&pop_sum) == expected_sum, "bstack MPMC pop_sum conservation mismatch");
    TEST_ASSERT(lfq_bstack_destroy(mpmc_bs) == LFQ_OK, "bstack MPMC destroy failed");

    printf("test_cabi_bstack PASSED.\n");
}

/* -------------------------------------------------------------------------
 * Test 17: Bounded Priority Queue (lfq_bpqueue_*) Ordering, FIFO & MPMC
 * ------------------------------------------------------------------------- */
typedef struct {
    lfq_bpqueue_t* pq;
    size_t items_per_thread;
    size_t thread_idx;
    test_atomic_uint64_t* pop_sum;
    test_atomic_size_t* pop_count;
} bpqueue_worker_arg_t;

static void* bpqueue_mpmc_worker(void* raw_arg) {
    bpqueue_worker_arg_t* arg = (bpqueue_worker_arg_t*)raw_arg;
    size_t pushed = 0;
    size_t popped = 0;
    while (pushed < arg->items_per_thread || popped < arg->items_per_thread) {
        if (pushed < arg->items_per_thread) {
            uintptr_t val = (arg->thread_idx * 10000ULL) + pushed + 1ULL;
            int64_t prio = (int64_t)((pushed * 17 + arg->thread_idx) % 64);
            if (lfq_bpqueue_push(arg->pq, prio, (void*)val) == LFQ_OK) {
                pushed++;
            }
        }
        if (popped < arg->items_per_thread) {
            int64_t out_prio = 0;
            void* item = NULL;
            if (lfq_bpqueue_pop_min(arg->pq, &out_prio, &item) == LFQ_OK) {
                ATOMIC_ADD(arg->pop_sum, (uint64_t)(uintptr_t)item);
                ATOMIC_INC(arg->pop_count);
                popped++;
            }
        }
    }
    return NULL;
}

static void test_cabi_bpqueue(void) {
    printf("Running test_cabi_bpqueue...\n");

    lfq_bpqueue_t* pq = NULL;
    TEST_ASSERT(lfq_bpqueue_create(0, NULL, NULL, &pq) == LFQ_ERR_INVALID_ARG, "bpqueue capacity 0 must fail");
    TEST_ASSERT(lfq_bpqueue_create(8, NULL, NULL, NULL) == LFQ_ERR_INVALID_ARG, "bpqueue NULL out_pqueue must fail");
    TEST_ASSERT(lfq_bpqueue_create(65537, NULL, NULL, &pq) == LFQ_ERR_UNSUPPORTED, "bpqueue capacity > 65536 must return UNSUPPORTED");
    TEST_ASSERT(lfq_bpqueue_destroy(NULL) == LFQ_ERR_INVALID_ARG, "bpqueue destroy NULL must fail");
    TEST_ASSERT(lfq_bpqueue_push(NULL, 1, (void*)1) == LFQ_ERR_INVALID_ARG, "bpqueue push NULL must fail");
    TEST_ASSERT(lfq_bpqueue_pop_min(NULL, NULL, NULL) == LFQ_ERR_INVALID_ARG, "bpqueue pop_min NULL must fail");
    TEST_ASSERT(lfq_bpqueue_peek_min(NULL, NULL, NULL) == LFQ_ERR_INVALID_ARG, "bpqueue peek_min NULL must fail");
    TEST_ASSERT(lfq_bpqueue_clear(NULL) == LFQ_ERR_INVALID_ARG, "bpqueue clear NULL must fail");
    TEST_ASSERT(lfq_bpqueue_len(NULL) == 0, "bpqueue len NULL must be 0");
    TEST_ASSERT(lfq_bpqueue_capacity(NULL) == 0, "bpqueue capacity NULL must be 0");
    TEST_ASSERT(lfq_bpqueue_is_empty(NULL) == true, "bpqueue is_empty NULL must be true");
    TEST_ASSERT(lfq_bpqueue_is_full(NULL) == false, "bpqueue is_full NULL must be false");

    arc_c_tracker_t tracker = { 0, 0 };
    lfq_status_t st = lfq_bpqueue_create(6, arc_c_destructor, &tracker, &pq);
    TEST_ASSERT(st == LFQ_OK && pq != NULL, "lfq_bpqueue_create(6) failed");
    TEST_ASSERT(lfq_bpqueue_capacity(pq) == 6, "bpqueue capacity should be 6");
    TEST_ASSERT(lfq_bpqueue_len(pq) == 0 && lfq_bpqueue_is_empty(pq) && !lfq_bpqueue_is_full(pq), "initial bpqueue state mismatch");

    int64_t out_prio = 0;
    void* out_item = NULL;
    TEST_ASSERT(lfq_bpqueue_pop_min(pq, &out_prio, &out_item) == LFQ_ERR_EMPTY, "pop_min on empty bpqueue must return LFQ_ERR_EMPTY");
    TEST_ASSERT(lfq_bpqueue_peek_min(pq, &out_prio, &out_item) == LFQ_ERR_EMPTY, "peek_min on empty bpqueue must return LFQ_ERR_EMPTY");

    /* Push 6 items including duplicate priorities (20) to verify FIFO tie-breaking */
    TEST_ASSERT(lfq_bpqueue_push(pq, 30, (void*)(uintptr_t)300) == LFQ_OK, "bpqueue push 1 failed");
    TEST_ASSERT(lfq_bpqueue_push(pq, 10, (void*)(uintptr_t)100) == LFQ_OK, "bpqueue push 2 failed");
    TEST_ASSERT(lfq_bpqueue_push(pq, 20, (void*)(uintptr_t)201) == LFQ_OK, "bpqueue push 3 failed");
    TEST_ASSERT(lfq_bpqueue_push(pq, 20, (void*)(uintptr_t)202) == LFQ_OK, "bpqueue push 4 failed");
    TEST_ASSERT(lfq_bpqueue_push(pq, 50, (void*)(uintptr_t)500) == LFQ_OK, "bpqueue push 5 failed");
    TEST_ASSERT(lfq_bpqueue_push(pq, 40, (void*)(uintptr_t)400) == LFQ_OK, "bpqueue push 6 failed");
    TEST_ASSERT(lfq_bpqueue_is_full(pq) && lfq_bpqueue_len(pq) == 6, "bpqueue should be full at 6");
    TEST_ASSERT(lfq_bpqueue_push(pq, 5, (void*)(uintptr_t)50) == LFQ_ERR_FULL, "bpqueue 7th push must return LFQ_ERR_FULL");

    /* Peek min: priority 10, value 100 */
    TEST_ASSERT(lfq_bpqueue_peek_min(pq, &out_prio, &out_item) == LFQ_OK && out_prio == 10 && (uintptr_t)out_item == 100, "bpqueue peek_min mismatch");

    /* Pop first 4 items: (10,100), (20,201), (20,202), (30,300) */
    const int64_t exp_prios[4] = { 10, 20, 20, 30 };
    const uintptr_t exp_vals[4] = { 100, 201, 202, 300 };
    for (size_t i = 0; i < 4; i++) {
        out_prio = -1;
        out_item = NULL;
        TEST_ASSERT(lfq_bpqueue_pop_min(pq, &out_prio, &out_item) == LFQ_OK, "bpqueue pop_min failed");
        TEST_ASSERT(out_prio == exp_prios[i] && (uintptr_t)out_item == exp_vals[i], "bpqueue priority/FIFO order mismatch");
    }
    TEST_ASSERT(lfq_bpqueue_len(pq) == 2, "bpqueue len should be 2");

    /* Clear remaining 2 items (400, 500) -> destructor invoked */
    TEST_ASSERT(lfq_bpqueue_clear(pq) == LFQ_OK, "lfq_bpqueue_clear failed");
    TEST_ASSERT(ATOMIC_LOAD(&tracker.destroyed_count) == 2 && ATOMIC_LOAD(&tracker.destroyed_sum) == 900, "bpqueue clear destructor mismatch");

    TEST_ASSERT(lfq_bpqueue_push(pq, 1, (void*)(uintptr_t)77) == LFQ_OK, "bpqueue push after clear failed");
    TEST_ASSERT(lfq_bpqueue_destroy(pq) == LFQ_OK, "lfq_bpqueue_destroy failed");
    TEST_ASSERT(ATOMIC_LOAD(&tracker.destroyed_count) == 3 && ATOMIC_LOAD(&tracker.destroyed_sum) == 977, "bpqueue destroy destructor mismatch");

    /* Multithreaded MPMC stress test */
    lfq_bpqueue_t* mpmc_pq = NULL;
    TEST_ASSERT(lfq_bpqueue_create(128, NULL, NULL, &mpmc_pq) == LFQ_OK, "bpqueue create 128 failed");
    const size_t NTHREADS = 4;
    const size_t NITEMS = 800;
    pthread_t ths[4];
    bpqueue_worker_arg_t args[4];
    test_atomic_uint64_t pop_sum = 0;
    test_atomic_size_t pop_count = 0;
    uint64_t expected_sum = 0;
    for (size_t t = 0; t < NTHREADS; t++) {
        for (size_t j = 0; j < NITEMS; j++) {
            expected_sum += (uint64_t)((t * 10000ULL) + j + 1ULL);
        }
        args[t].pq = mpmc_pq;
        args[t].items_per_thread = NITEMS;
        args[t].thread_idx = t;
        args[t].pop_sum = &pop_sum;
        args[t].pop_count = &pop_count;
        pthread_create(&ths[t], NULL, bpqueue_mpmc_worker, &args[t]);
    }
    for (size_t t = 0; t < NTHREADS; t++) {
        pthread_join(ths[t], NULL);
    }
    TEST_ASSERT(ATOMIC_LOAD(&pop_count) == NTHREADS * NITEMS, "bpqueue MPMC pop_count mismatch");
    TEST_ASSERT(ATOMIC_LOAD(&pop_sum) == expected_sum, "bpqueue MPMC pop_sum conservation mismatch");
    TEST_ASSERT(lfq_bpqueue_destroy(mpmc_pq) == LFQ_OK, "bpqueue MPMC destroy failed");

    printf("test_cabi_bpqueue PASSED.\n");
}

/* -------------------------------------------------------------------------
 * Test 18: Bounded Hash Table (lfq_btable_*) CRUD, Tombstones, Associative & MPMC
 * ------------------------------------------------------------------------- */
typedef struct {
    test_atomic_size_t count;
    test_atomic_uint64_t key_sum;
    test_atomic_uint64_t val_sum;
} btable_c_tracker_t;

static void btable_c_destructor(void* key, void* val, void* user_data) {
    btable_c_tracker_t* tr = (btable_c_tracker_t*)user_data;
    if (tr != NULL) {
        ATOMIC_INC(&tr->count);
        ATOMIC_ADD(&tr->key_sum, (uint64_t)(uintptr_t)key);
        ATOMIC_ADD(&tr->val_sum, (uint64_t)(uintptr_t)val);
    }
}

static void* btable_c_mapping_fn(const void* key, void* user_data) {
    uintptr_t mult = user_data != NULL ? (uintptr_t)user_data : 10;
    return (void*)((uintptr_t)key * mult);
}

static void* btable_c_update_fn(const void* key, void* old_val, void* user_data) {
    (void)key;
    uintptr_t delta = user_data != NULL ? (uintptr_t)user_data : 1;
    return (void*)((uintptr_t)old_val + delta);
}

static void* btable_c_zero_update_fn(const void* key, void* old_val, void* user_data) {
    (void)key;
    (void)old_val;
    (void)user_data;
    return (void*)0;
}

typedef struct {
    lfq_btable_t* table;
    size_t increments;
    void* key;
} btable_worker_arg_t;

static void* btable_upsert_worker(void* raw_arg) {
    btable_worker_arg_t* arg = (btable_worker_arg_t*)raw_arg;
    for (size_t i = 0; i < arg->increments; i++) {
        void* out_val = NULL;
        lfq_status_t st = lfq_btable_upsert(
            arg->table,
            arg->key,
            (void*)(uintptr_t)1,
            btable_c_update_fn,
            (void*)(uintptr_t)1,
            &out_val
        );
        TEST_ASSERT(st == LFQ_OK, "lfq_btable_upsert in worker failed");
    }
    return NULL;
}

static void test_cabi_btable(void) {
    printf("Running test_cabi_btable...\n");

    lfq_btable_t* bt = NULL;
    TEST_ASSERT(lfq_btable_create(0, NULL, NULL, &bt) == LFQ_ERR_INVALID_ARG, "btable capacity 0 must fail");
    TEST_ASSERT(lfq_btable_create(8, NULL, NULL, NULL) == LFQ_ERR_INVALID_ARG, "btable NULL out_table must fail");
    TEST_ASSERT(lfq_btable_create(65537, NULL, NULL, &bt) == LFQ_ERR_UNSUPPORTED, "btable capacity > 65536 must return UNSUPPORTED");
    TEST_ASSERT(lfq_btable_destroy(NULL) == LFQ_ERR_INVALID_ARG, "btable destroy NULL must fail");
    TEST_ASSERT(lfq_btable_put(NULL, (void*)1, (void*)1, NULL) == LFQ_ERR_INVALID_ARG, "btable put NULL must fail");
    TEST_ASSERT(lfq_btable_insert(NULL, (void*)1, (void*)1, NULL) == LFQ_ERR_INVALID_ARG, "btable insert NULL must fail");
    TEST_ASSERT(lfq_btable_get(NULL, (void*)1, NULL) == LFQ_ERR_INVALID_ARG, "btable get NULL must fail");
    TEST_ASSERT(lfq_btable_delete(NULL, (void*)1, NULL) == LFQ_ERR_INVALID_ARG, "btable delete NULL must fail");
    TEST_ASSERT(lfq_btable_take(NULL, (void*)1, NULL) == LFQ_ERR_INVALID_ARG, "btable take NULL must fail");
    TEST_ASSERT(lfq_btable_contains(NULL, (void*)1) == false, "btable contains NULL must be false");
    TEST_ASSERT(lfq_btable_len(NULL) == 0 && lfq_btable_capacity(NULL) == 0, "btable len/capacity NULL must be 0");
    TEST_ASSERT(lfq_btable_is_empty(NULL) == true && lfq_btable_is_full(NULL) == false, "btable empty/full NULL mismatch");

    btable_c_tracker_t tracker = { 0, 0, 0 };
    lfq_status_t st = lfq_btable_create(8, btable_c_destructor, &tracker, &bt);
    TEST_ASSERT(st == LFQ_OK && bt != NULL, "lfq_btable_create(8) failed");
    TEST_ASSERT(lfq_btable_capacity(bt) == 8 && lfq_btable_len(bt) == 0 && lfq_btable_is_empty(bt), "btable initial state mismatch");

    /* Verify (void*)0 key & value operations in compute_if_absent, upsert, atomic_update, take (CRIT-02) */
    void* zval = (void*)(uintptr_t)0xDEADBEEF;
    TEST_ASSERT(lfq_btable_compute_if_absent(bt, (void*)0, btable_c_mapping_fn, (void*)(uintptr_t)10, &zval) == LFQ_OK && zval == NULL,
                "btable compute_if_absent returning (void*)0 failed");
    zval = (void*)(uintptr_t)0xDEADBEEF;
    TEST_ASSERT(lfq_btable_atomic_update(bt, (void*)0, btable_c_zero_update_fn, NULL, &zval) == LFQ_OK && zval == NULL,
                "btable atomic_update returning (void*)0 failed");
    zval = (void*)(uintptr_t)0xDEADBEEF;
    TEST_ASSERT(lfq_btable_take(bt, (void*)0, &zval) == LFQ_OK && zval == NULL,
                "btable take returning (void*)0 failed");
    zval = (void*)(uintptr_t)0xDEADBEEF;
    TEST_ASSERT(lfq_btable_upsert(bt, (void*)0, (void*)0, btable_c_zero_update_fn, NULL, &zval) == LFQ_OK && zval == NULL,
                "btable upsert inserting (void*)0 failed");
    TEST_ASSERT(lfq_btable_take(bt, (void*)0, &zval) == LFQ_OK && zval == NULL,
                "btable take after upsert (void*)0 failed");

    /* Fill 8 entries (keys 1..8) */
    for (uintptr_t k = 1; k <= 8; k++) {
        bool inserted = false;
        st = lfq_btable_put(bt, (void*)k, (void*)(k * 100), &inserted);
        TEST_ASSERT(st == LFQ_OK && inserted == true, "lfq_btable_put new key failed");
    }
    TEST_ASSERT(lfq_btable_len(bt) == 8 && lfq_btable_is_full(bt), "btable should be full at 8");

    /* 9th distinct key must return LFQ_ERR_FULL */
    bool inserted = true;
    TEST_ASSERT(lfq_btable_put(bt, (void*)(uintptr_t)9, (void*)(uintptr_t)900, &inserted) == LFQ_ERR_FULL && inserted == false,
                "lfq_btable_put 9th key must return LFQ_ERR_FULL");
    TEST_ASSERT(lfq_btable_insert(bt, (void*)(uintptr_t)9, (void*)(uintptr_t)900, &inserted) == LFQ_ERR_FULL && inserted == false,
                "lfq_btable_insert 9th key must return LFQ_ERR_FULL");

    /* Updating an existing key (key 3) at full capacity via put succeeds */
    inserted = true;
    TEST_ASSERT(lfq_btable_put(bt, (void*)(uintptr_t)3, (void*)(uintptr_t)333, &inserted) == LFQ_OK && inserted == false,
                "lfq_btable_put update at full capacity must succeed");
    void* val = NULL;
    TEST_ASSERT(lfq_btable_get(bt, (void*)(uintptr_t)3, &val) == LFQ_OK && (uintptr_t)val == 333, "updated value mismatch");

    /* insert on existing key 3 at full capacity leaves value unchanged and returns LFQ_OK with inserted=false */
    inserted = true;
    TEST_ASSERT(lfq_btable_insert(bt, (void*)(uintptr_t)3, (void*)(uintptr_t)999, &inserted) == LFQ_OK && inserted == false,
                "lfq_btable_insert existing key must return LFQ_OK with inserted=false");
    TEST_ASSERT(lfq_btable_get(bt, (void*)(uintptr_t)3, &val) == LFQ_OK && (uintptr_t)val == 333, "insert must not overwrite existing key");

    /* Tombstone cycling: delete and insert 64 times at capacity boundary */
    for (uintptr_t cycle = 0; cycle < 64; cycle++) {
        bool deleted = false;
        uintptr_t victim = (cycle % 8) + 1;
        TEST_ASSERT(lfq_btable_delete(bt, (void*)victim, &deleted) == LFQ_OK && deleted == true, "tombstone cycle delete failed");
        TEST_ASSERT(lfq_btable_put(bt, (void*)victim, (void*)(victim * 100), &inserted) == LFQ_OK && inserted == true, "tombstone cycle re-insert failed");
    }

    /* Take key 8 and verify associative operations */
    val = NULL;
    TEST_ASSERT(lfq_btable_take(bt, (void*)(uintptr_t)8, &val) == LFQ_OK && (uintptr_t)val == 800, "lfq_btable_take failed");
    TEST_ASSERT(!lfq_btable_contains(bt, (void*)(uintptr_t)8) && lfq_btable_len(bt) == 7, "key 8 should be removed");

    /* compute_if_absent on absent key 8 */
    val = NULL;
    TEST_ASSERT(lfq_btable_compute_if_absent(bt, (void*)(uintptr_t)8, btable_c_mapping_fn, (void*)(uintptr_t)100, &val) == LFQ_OK && (uintptr_t)val == 800,
                "lfq_btable_compute_if_absent absent key failed");
    /* compute_if_absent on absent key 9 when full -> LFQ_ERR_FULL */
    TEST_ASSERT(lfq_btable_compute_if_absent(bt, (void*)(uintptr_t)9, btable_c_mapping_fn, (void*)(uintptr_t)100, &val) == LFQ_ERR_FULL,
                "lfq_btable_compute_if_absent when full must return LFQ_ERR_FULL");

    /* atomic_update on existing key 8 (800 -> 805) and absent key 99 (-> LFQ_ERR_EMPTY) */
    TEST_ASSERT(lfq_btable_atomic_update(bt, (void*)(uintptr_t)8, btable_c_update_fn, (void*)(uintptr_t)5, &val) == LFQ_OK && (uintptr_t)val == 805,
                "lfq_btable_atomic_update existing key failed");
    TEST_ASSERT(lfq_btable_atomic_update(bt, (void*)(uintptr_t)99, btable_c_update_fn, (void*)(uintptr_t)5, &val) == LFQ_ERR_EMPTY,
                "lfq_btable_atomic_update absent key must return LFQ_ERR_EMPTY");

    /* Clear all 8 entries -> destructor called 8 times */
    TEST_ASSERT(lfq_btable_clear(bt) == LFQ_OK, "lfq_btable_clear failed");
    TEST_ASSERT(lfq_btable_is_empty(bt) && lfq_btable_len(bt) == 0, "btable should be empty after clear");
    TEST_ASSERT(ATOMIC_LOAD(&tracker.count) == 8, "btable clear destructor count should be 8");
    TEST_ASSERT(ATOMIC_LOAD(&tracker.key_sum) == 36, "btable clear destructor key_sum should be 1+..+8 = 36");

    /* Multithreaded atomic counter stress via lfq_btable_upsert */
    const size_t NTHREADS = 4;
    const size_t INCS = 1000;
    pthread_t ths[4];
    btable_worker_arg_t wargs[4];
    void* shared_key = (void*)(uintptr_t)42;
    for (size_t t = 0; t < NTHREADS; t++) {
        wargs[t].table = bt;
        wargs[t].increments = INCS;
        wargs[t].key = shared_key;
        pthread_create(&ths[t], NULL, btable_upsert_worker, &wargs[t]);
    }
    for (size_t t = 0; t < NTHREADS; t++) {
        pthread_join(ths[t], NULL);
    }
    val = NULL;
    TEST_ASSERT(lfq_btable_get(bt, shared_key, &val) == LFQ_OK && (uintptr_t)val == NTHREADS * INCS,
                "btable concurrent upsert lost updates");

    TEST_ASSERT(lfq_btable_destroy(bt) == LFQ_OK, "lfq_btable_destroy failed");
    TEST_ASSERT(ATOMIC_LOAD(&tracker.count) == 9, "btable destroy should invoke destructor on remaining key 42");

    printf("test_cabi_btable PASSED.\n");
}

/* -------------------------------------------------------------------------
 * Test: BQueue128 128-Bit DWCAS Bounded MPMC Queue
 * ------------------------------------------------------------------------- */
static void test_cabi_bqueue128(void) {
    printf("Running test_cabi_bqueue128...\n");
    lf_bqueue128_t* q = NULL;
    TEST_ASSERT(lf_bqueue128_create(0, NULL, NULL, &q) == LF_ERR_INVALID_ARG, "Create 0 cap should fail");
    TEST_ASSERT(lf_bqueue128_create(65537, NULL, NULL, &q) == LF_ERR_UNSUPPORTED, "Create >65536 should fail");
    TEST_ASSERT(lf_bqueue128_create(4, NULL, NULL, &q) == LF_OK, "lf_bqueue128_create(4) failed");
    TEST_ASSERT(q != NULL, "q should not be NULL");
    TEST_ASSERT(lf_bqueue128_capacity(q) == 4, "Capacity should be 4");
    TEST_ASSERT(lf_bqueue128_len(q) == 0, "Len should be 0");
    TEST_ASSERT(lf_bqueue128_is_empty(q) == true, "Queue should be empty");
    TEST_ASSERT(lf_bqueue128_is_full(q) == false, "Queue should not be full");

    for (uintptr_t i = 1; i <= 4; i++) {
        TEST_ASSERT(lf_bqueue128_push(q, (void*)(i * 10)) == LF_OK, "Push failed");
    }
    TEST_ASSERT(lf_bqueue128_is_full(q) == true, "Queue should be full");
    TEST_ASSERT(lf_bqueue128_push(q, (void*)999) == LF_ERR_FULL, "Push to full queue should fail");

    void* peeked = NULL;
    TEST_ASSERT(lf_bqueue128_peek(q, &peeked) == LF_OK, "Peek failed");
    TEST_ASSERT((uintptr_t)peeked == 10, "Peeked item mismatch");

    for (uintptr_t i = 1; i <= 4; i++) {
        void* popped = NULL;
        TEST_ASSERT(lf_bqueue128_pop(q, &popped) == LF_OK, "Pop failed");
        TEST_ASSERT((uintptr_t)popped == i * 10, "Popped item mismatch");
    }
    void* popped = NULL;
    TEST_ASSERT(lf_bqueue128_pop(q, &popped) == LF_ERR_EMPTY, "Pop on empty queue should return EMPTY");
    TEST_ASSERT(lf_bqueue128_is_empty(q) == true, "Queue should be empty");

    /* Test clear */
    TEST_ASSERT(lf_bqueue128_push(q, (void*)42) == LF_OK, "Push before clear failed");
    TEST_ASSERT(lf_bqueue128_clear(q) == LF_OK, "Clear failed");
    TEST_ASSERT(lf_bqueue128_is_empty(q) == true, "Queue should be empty after clear");

    TEST_ASSERT(lf_bqueue128_destroy(q) == LF_OK, "Destroy failed");

    /* Backward compatibility aliases */
    lfq_bqueue128_t* lq = NULL;
    TEST_ASSERT(lfq_bqueue128_create(8, NULL, NULL, &lq) == LFQ_OK, "lfq_bqueue128_create failed");
    bool was_empty = false;
    TEST_ASSERT(lf_bqueue128_push_ex(lq, (void*)77, &was_empty) == LF_OK && was_empty == true, "lf_bqueue128_push_ex 0->1 failed");
    TEST_ASSERT(lfq_bqueue128_push_ex(lq, (void*)88, &was_empty) == LFQ_OK && was_empty == false, "lfq_bqueue128_push_ex 1->2 failed");
    void* litem = NULL;
    TEST_ASSERT(lfq_bqueue128_pop(lq, &litem) == LFQ_OK && (uintptr_t)litem == 77, "lfq pop 77 failed");
    TEST_ASSERT(lfq_bqueue128_pop(lq, &litem) == LFQ_OK && (uintptr_t)litem == 88, "lfq pop 88 failed");
    TEST_ASSERT(lfq_bqueue128_destroy(lq) == LFQ_OK, "lfq destroy failed");

    printf("test_cabi_bqueue128 PASSED.\n");
}

/* -------------------------------------------------------------------------
 * Test: Primary lf_* Modern Prefix Direct Interoperability
 * ------------------------------------------------------------------------- */
static void test_cabi_lf_modern_prefix(void) {
    printf("Running test_cabi_lf_modern_prefix...\n");
    lf_queue_t* queue = NULL;
    lf_status_t status = lf_bounded_mpmc_create(8, 2, 2, NULL, NULL, &queue);
    TEST_ASSERT(status == LF_OK && queue != NULL, "lf_bounded_mpmc_create failed");
    TEST_ASSERT(lf_queue_is_empty(queue), "lf_queue_is_empty failed");

    lf_producer_t* prod = NULL;
    lf_consumer_t* cons = NULL;
    TEST_ASSERT(lf_producer_acquire(queue, &prod) == LF_OK, "lf_producer_acquire failed");
    TEST_ASSERT(lf_consumer_acquire(queue, &cons) == LF_OK, "lf_consumer_acquire failed");

    bool was_empty = false;
    TEST_ASSERT(lf_push_ex(prod, (void*)(uintptr_t)42, &was_empty) == LF_OK && was_empty == true, "lf_push_ex 0->1 failed");
    TEST_ASSERT(lf_queue_push_ex(prod, (void*)(uintptr_t)43, &was_empty) == LF_OK && was_empty == false, "lf_queue_push_ex 1->2 failed");
    TEST_ASSERT(lf_queue_len(queue) == 2, "lf_queue_len failed");

    void* item = NULL;
    TEST_ASSERT(lf_pop(cons, &item) == LF_OK && (uintptr_t)item == 42, "lf_pop 42 failed");
    TEST_ASSERT(lf_pop(cons, &item) == LF_OK && (uintptr_t)item == 43, "lf_pop 43 failed");
    TEST_ASSERT(lf_pop(cons, &item) == LF_ERR_EMPTY, "lf_pop on empty failed");

    TEST_ASSERT(lf_producer_release(prod) == LF_OK, "lf_producer_release failed");
    TEST_ASSERT(lf_consumer_release(cons) == LF_OK, "lf_consumer_release failed");
    TEST_ASSERT(lf_queue_destroy(queue) == LF_OK, "lf_queue_destroy failed");
    printf("test_cabi_lf_modern_prefix PASSED.\n");
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
    test_cabi_table();
    test_cabi_set();
    test_cabi_ctrie();
    test_cabi_broadcast();
    test_cabi_rendezvous();
    test_cabi_ratelimit();
    test_cabi_streambuffer();
    test_cabi_associative();
    test_cabi_atomic_arc();
    test_cabi_flat_combiner();
    test_cabi_bstack();
    test_cabi_bpqueue();
    test_cabi_btable();
    test_cabi_bqueue128();
    test_cabi_concurrency();
    test_cabi_lf_modern_prefix();

    /* TaskPool C ABI */
    printf("Running test_cabi_taskpool...\n");
    lfq_taskpool_t* pool = NULL;
    lfq_status_t tp_status = lfq_taskpool_create(4, &pool);
    TEST_ASSERT(tp_status == LFQ_OK && pool != NULL, "lfq_taskpool_create failed");
    TEST_ASSERT(lfq_taskpool_num_workers(pool) == 4, "TaskPool worker count should be 4");
    tp_status = lfq_taskpool_destroy(pool);
    TEST_ASSERT(tp_status == LFQ_OK, "lfq_taskpool_destroy failed");
    printf("test_cabi_taskpool PASSED.\n");

    printf("\n>>> ALL C ABI TESTS COMPLETED SUCCESSFULLY! <<<\n");
    return 0;
}
