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
#include <time.h>
#include "lockfree.h"
#include "lockfree_ratelimit.h"

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

    /* 4. Section 9.1 C-Style Functions */
    lf_rendezvous_t* rchan = lf_rendezvous_create();
    TEST_ASSERT(rchan != NULL, "lf_rendezvous_create failed");
    TEST_ASSERT(!lf_rendezvous_try_send(rchan, (void*)(uintptr_t)99, NULL), "try_send empty should return false");
    TEST_ASSERT(!lf_rendezvous_try_recv(rchan, &item, NULL), "try_recv empty should return false");
    TEST_ASSERT(!lf_rendezvous_send_timeout(rchan, (void*)(uintptr_t)99, 10, NULL), "send_timeout empty should return false");
    TEST_ASSERT(!lf_rendezvous_recv_timeout(rchan, &item, 10, NULL), "recv_timeout empty should return false");

    rz_thread_arg_t rz_s_arg = {
        (lfq_rendezvous_t*)rchan,
        1,
        777,
        NULL
    };
    pthread_t th_s2;
    pthread_create(&th_s2, NULL, rz_sender_worker, &rz_s_arg);
    uint64_t r_cid = 0;
    int recv_res = lf_rendezvous_recv(rchan, &item, &r_cid);
    TEST_ASSERT(recv_res == 0, "lf_rendezvous_recv failed");
    TEST_ASSERT((uintptr_t)item == 777, "Item payload mismatch in lf_rendezvous_recv");
    TEST_ASSERT(r_cid > 0, "Correlation ID should be positive");
    pthread_join(th_s2, NULL);

    lf_rendezvous_close(rchan);
    lf_rendezvous_destroy(rchan);

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
    const size_t STRESS_THREADS = 4;
    const size_t ITERS_PER_TH = 500;
    test_atomic_size_t total_acquired = 0;
    pthread_t ths[STRESS_THREADS];
    tb_stress_arg_t args[STRESS_THREADS];

    for (size_t i = 0; i < STRESS_THREADS; i++) {
        args[i].bucket = shared_tb;
        args[i].iterations = ITERS_PER_TH;
        args[i].total_acquired = &total_acquired;
        pthread_create(&ths[i], NULL, tb_stress_worker, &args[i]);
    }
    for (size_t i = 0; i < STRESS_THREADS; i++) {
        pthread_join(ths[i], NULL);
    }
    TEST_ASSERT(ATOMIC_LOAD(&total_acquired) == STRESS_THREADS * ITERS_PER_TH, "Total acquired mismatch");
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
    test_cabi_concurrency();

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
