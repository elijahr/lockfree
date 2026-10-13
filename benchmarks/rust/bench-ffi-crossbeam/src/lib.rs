//! C-ABI cdylib wrapping Rust concurrency libraries for the `lockfree` benchmark suite.
//!
//! Exposes `extern "C"` shims for:
//! - Queues: `crossbeam_queue::{ArrayQueue, SegQueue}`, `flume`, `kanal`
//! - Rendezvous (0-buffer): `crossbeam_channel::bounded(0)`, `flume::bounded(0)`, `kanal::bounded(0)`
//! - Associative Maps & Sets: `dashmap::DashMap`, `flurry::HashMap`, `crossbeam_skiplist::{SkipMap, SkipSet}`
//! - Work-Stealing Deques: `crossbeam_deque::{Worker, Stealer}`
//! - Broadcast & Pub-Sub: `tokio::sync::broadcast`, `bus::Bus`
//! - Rate Limiters & Stream Buffers: `governor::RateLimiter`, `rtrb::RingBuffer`
//! - TaskPools & SMR: `rayon::ThreadPool`, `crossbeam_epoch`

use crossbeam_deque::{Steal, Stealer, Worker};
use crossbeam_queue::{ArrayQueue, SegQueue};
use crossbeam_skiplist::{SkipMap, SkipSet};
use dashmap::DashMap;
use governor::{Quota, RateLimiter};
use rayon::prelude::*;
use std::cell::UnsafeCell;
use std::num::NonZeroU32;
use std::os::raw::{c_char, c_void};
use std::sync::atomic::{AtomicU64, Ordering};

// ---------------- Version getters (v5.0.0-wave Item 1 + v5.1 expansion) ----------------

#[no_mangle]
pub extern "C" fn bench_ffi_crossbeam_queue_version() -> *const c_char {
    static V: &str = concat!(env!("BENCH_DEP_CROSSBEAM_QUEUE_VERSION"), "\0");
    V.as_ptr() as *const c_char
}

#[no_mangle]
pub extern "C" fn bench_ffi_crossbeam_deque_version() -> *const c_char {
    static V: &str = concat!(env!("BENCH_DEP_CROSSBEAM_DEQUE_VERSION"), "\0");
    V.as_ptr() as *const c_char
}

#[no_mangle]
pub extern "C" fn bench_ffi_crossbeam_skiplist_version() -> *const c_char {
    static V: &str = concat!(env!("BENCH_DEP_CROSSBEAM_SKIPLIST_VERSION"), "\0");
    V.as_ptr() as *const c_char
}

#[no_mangle]
pub extern "C" fn bench_ffi_crossbeam_channel_version() -> *const c_char {
    static V: &str = concat!(env!("BENCH_DEP_CROSSBEAM_CHANNEL_VERSION"), "\0");
    V.as_ptr() as *const c_char
}

#[no_mangle]
pub extern "C" fn bench_ffi_crossbeam_epoch_version() -> *const c_char {
    static V: &str = concat!(env!("BENCH_DEP_CROSSBEAM_EPOCH_VERSION"), "\0");
    V.as_ptr() as *const c_char
}

#[no_mangle]
pub extern "C" fn bench_ffi_dashmap_version() -> *const c_char {
    static V: &str = concat!(env!("BENCH_DEP_DASHMAP_VERSION"), "\0");
    V.as_ptr() as *const c_char
}

#[no_mangle]
pub extern "C" fn bench_ffi_flurry_version() -> *const c_char {
    static V: &str = concat!(env!("BENCH_DEP_FLURRY_VERSION"), "\0");
    V.as_ptr() as *const c_char
}

#[no_mangle]
pub extern "C" fn bench_ffi_flume_version() -> *const c_char {
    static V: &str = concat!(env!("BENCH_DEP_FLUME_VERSION"), "\0");
    V.as_ptr() as *const c_char
}

#[no_mangle]
pub extern "C" fn bench_ffi_kanal_version() -> *const c_char {
    static V: &str = concat!(env!("BENCH_DEP_KANAL_VERSION"), "\0");
    V.as_ptr() as *const c_char
}

#[no_mangle]
pub extern "C" fn bench_ffi_tokio_version() -> *const c_char {
    static V: &str = concat!(env!("BENCH_DEP_TOKIO_VERSION"), "\0");
    V.as_ptr() as *const c_char
}

#[no_mangle]
pub extern "C" fn bench_ffi_bus_version() -> *const c_char {
    static V: &str = concat!(env!("BENCH_DEP_BUS_VERSION"), "\0");
    V.as_ptr() as *const c_char
}

#[no_mangle]
pub extern "C" fn bench_ffi_governor_version() -> *const c_char {
    static V: &str = concat!(env!("BENCH_DEP_GOVERNOR_VERSION"), "\0");
    V.as_ptr() as *const c_char
}

#[no_mangle]
pub extern "C" fn bench_ffi_rtrb_version() -> *const c_char {
    static V: &str = concat!(env!("BENCH_DEP_RTRB_VERSION"), "\0");
    V.as_ptr() as *const c_char
}

#[no_mangle]
pub extern "C" fn bench_ffi_rayon_version() -> *const c_char {
    static V: &str = concat!(env!("BENCH_DEP_RAYON_VERSION"), "\0");
    V.as_ptr() as *const c_char
}

// ---------------- ArrayQueue (bounded MPMC) ----------------

#[no_mangle]
pub extern "C" fn cb_array_init(capacity: usize) -> *mut c_void {
    if capacity == 0 {
        return std::ptr::null_mut();
    }
    let q = Box::new(ArrayQueue::<u64>::new(capacity));
    Box::into_raw(q) as *mut c_void
}

/// # Safety
/// `q` must be a valid pointer returned by `cb_array_init`.
#[no_mangle]
pub unsafe extern "C" fn cb_array_push(q: *mut c_void, item: u64) -> bool {
    if q.is_null() {
        return false;
    }
    let q = unsafe { &*(q as *const ArrayQueue<u64>) };
    q.push(item).is_ok()
}

/// # Safety
/// `q` must be a valid pointer returned by `cb_array_init`; `out` must be writable.
#[no_mangle]
pub unsafe extern "C" fn cb_array_pop(q: *mut c_void, out: *mut u64) -> bool {
    if q.is_null() || out.is_null() {
        return false;
    }
    let q = unsafe { &*(q as *const ArrayQueue<u64>) };
    match q.pop() {
        Some(v) => {
            unsafe {
                std::ptr::write(out, v);
            }
            true
        }
        None => false,
    }
}

/// # Safety
/// `q` must be a pointer previously returned by `cb_array_init`.
#[no_mangle]
pub unsafe extern "C" fn cb_array_destroy(q: *mut c_void) {
    if q.is_null() {
        return;
    }
    drop(unsafe { Box::from_raw(q as *mut ArrayQueue<u64>) });
}

// ---------------- SegQueue (unbounded MPMC) ----------------

#[no_mangle]
pub extern "C" fn cb_seg_init() -> *mut c_void {
    let q = Box::new(SegQueue::<u64>::new());
    Box::into_raw(q) as *mut c_void
}

/// # Safety
/// `q` must be a live SegQueue pointer.
#[no_mangle]
pub unsafe extern "C" fn cb_seg_push(q: *mut c_void, item: u64) -> bool {
    if q.is_null() {
        return false;
    }
    let q = unsafe { &*(q as *const SegQueue<u64>) };
    q.push(item);
    true
}

/// # Safety
/// `q` must be a live SegQueue pointer; `out` must be writable.
#[no_mangle]
pub unsafe extern "C" fn cb_seg_pop(q: *mut c_void, out: *mut u64) -> bool {
    if q.is_null() || out.is_null() {
        return false;
    }
    let q = unsafe { &*(q as *const SegQueue<u64>) };
    match q.pop() {
        Some(v) => {
            unsafe {
                std::ptr::write(out, v);
            }
            true
        }
        None => false,
    }
}

/// # Safety
/// `q` must be a pointer previously returned by `cb_seg_init`.
#[no_mangle]
pub unsafe extern "C" fn cb_seg_destroy(q: *mut c_void) {
    if q.is_null() {
        return;
    }
    drop(unsafe { Box::from_raw(q as *mut SegQueue<u64>) });
}

// ============================================================
// flume bounded + unbounded + rendezvous (0-capacity)
// ============================================================

struct FlumePair {
    tx: flume::Sender<u64>,
    rx: flume::Receiver<u64>,
}

#[no_mangle]
pub extern "C" fn flume_init(capacity: usize) -> *mut c_void {
    if capacity == 0 {
        return std::ptr::null_mut();
    }
    let (tx, rx) = flume::bounded::<u64>(capacity);
    let pair = Box::new(FlumePair { tx, rx });
    Box::into_raw(pair) as *mut c_void
}

/// # Safety
/// `q` must be a live FlumePair pointer.
#[no_mangle]
pub unsafe extern "C" fn flume_push(q: *mut c_void, item: u64) -> bool {
    if q.is_null() {
        return false;
    }
    let pair = unsafe { &*(q as *const FlumePair) };
    pair.tx.try_send(item).is_ok()
}

/// # Safety
/// `q` must be a live FlumePair pointer; `out` must be writable.
#[no_mangle]
pub unsafe extern "C" fn flume_pop(q: *mut c_void, out: *mut u64) -> bool {
    if q.is_null() || out.is_null() {
        return false;
    }
    let pair = unsafe { &*(q as *const FlumePair) };
    match pair.rx.try_recv() {
        Ok(v) => {
            unsafe {
                std::ptr::write(out, v);
            }
            true
        }
        Err(_) => false,
    }
}

/// # Safety
/// `q` must be a pointer previously returned by `flume_init`.
#[no_mangle]
pub unsafe extern "C" fn flume_destroy(q: *mut c_void) {
    if q.is_null() {
        return;
    }
    drop(unsafe { Box::from_raw(q as *mut FlumePair) });
}

#[no_mangle]
pub extern "C" fn flume_unbounded_init() -> *mut c_void {
    let (tx, rx) = flume::unbounded::<u64>();
    let pair = Box::new(FlumePair { tx, rx });
    Box::into_raw(pair) as *mut c_void
}

/// # Safety
/// `q` must be a live FlumePair pointer.
#[no_mangle]
pub unsafe extern "C" fn flume_unbounded_push(q: *mut c_void, item: u64) -> bool {
    if q.is_null() {
        return false;
    }
    let pair = unsafe { &*(q as *const FlumePair) };
    pair.tx.send(item).is_ok()
}

/// # Safety
/// See `flume_pop`.
#[no_mangle]
pub unsafe extern "C" fn flume_unbounded_pop(q: *mut c_void, out: *mut u64) -> bool {
    if q.is_null() || out.is_null() {
        return false;
    }
    let pair = unsafe { &*(q as *const FlumePair) };
    match pair.rx.try_recv() {
        Ok(v) => {
            unsafe {
                std::ptr::write(out, v);
            }
            true
        }
        Err(_) => false,
    }
}

/// # Safety
/// `q` must be a pointer previously returned by `flume_unbounded_init`.
#[no_mangle]
pub unsafe extern "C" fn flume_unbounded_destroy(q: *mut c_void) {
    if q.is_null() {
        return;
    }
    drop(unsafe { Box::from_raw(q as *mut FlumePair) });
}

#[no_mangle]
pub extern "C" fn flume_rendezvous_init() -> *mut c_void {
    let (tx, rx) = flume::bounded::<u64>(0);
    let pair = Box::new(FlumePair { tx, rx });
    Box::into_raw(pair) as *mut c_void
}

/// # Safety
/// `q` must be a live FlumePair pointer.
#[no_mangle]
pub unsafe extern "C" fn flume_rendezvous_send(q: *mut c_void, item: u64) -> bool {
    if q.is_null() {
        return false;
    }
    let pair = unsafe { &*(q as *const FlumePair) };
    pair.tx.send(item).is_ok()
}

/// # Safety
/// `q` must be a live FlumePair pointer; `out` must be writable.
#[no_mangle]
pub unsafe extern "C" fn flume_rendezvous_recv(q: *mut c_void, out: *mut u64) -> bool {
    if q.is_null() || out.is_null() {
        return false;
    }
    let pair = unsafe { &*(q as *const FlumePair) };
    match pair.rx.recv() {
        Ok(v) => {
            unsafe {
                std::ptr::write(out, v);
            }
            true
        }
        Err(_) => false,
    }
}

/// # Safety
/// `q` must be a pointer previously returned by `flume_rendezvous_init`.
#[no_mangle]
pub unsafe extern "C" fn flume_rendezvous_destroy(q: *mut c_void) {
    if q.is_null() {
        return;
    }
    drop(unsafe { Box::from_raw(q as *mut FlumePair) });
}

// ============================================================
// kanal bounded + unbounded + rendezvous (0-capacity)
// ============================================================

struct KanalPair {
    tx: kanal::Sender<u64>,
    rx: kanal::Receiver<u64>,
}

#[no_mangle]
pub extern "C" fn kanal_init(capacity: usize) -> *mut c_void {
    if capacity == 0 {
        return std::ptr::null_mut();
    }
    let (tx, rx) = kanal::bounded::<u64>(capacity);
    let pair = Box::new(KanalPair { tx, rx });
    Box::into_raw(pair) as *mut c_void
}

/// # Safety
/// `q` must be a live KanalPair pointer.
#[no_mangle]
pub unsafe extern "C" fn kanal_push(q: *mut c_void, item: u64) -> bool {
    if q.is_null() {
        return false;
    }
    let pair = unsafe { &*(q as *const KanalPair) };
    pair.tx.try_send(item).unwrap_or(false)
}

/// # Safety
/// `q` must be a live KanalPair pointer; `out` must be writable.
#[no_mangle]
pub unsafe extern "C" fn kanal_pop(q: *mut c_void, out: *mut u64) -> bool {
    if q.is_null() || out.is_null() {
        return false;
    }
    let pair = unsafe { &*(q as *const KanalPair) };
    match pair.rx.try_recv() {
        Ok(Some(v)) => {
            unsafe {
                std::ptr::write(out, v);
            }
            true
        }
        Ok(None) | Err(_) => false,
    }
}

/// # Safety
/// `q` must be a pointer previously returned by `kanal_init`.
#[no_mangle]
pub unsafe extern "C" fn kanal_destroy(q: *mut c_void) {
    if q.is_null() {
        return;
    }
    drop(unsafe { Box::from_raw(q as *mut KanalPair) });
}

#[no_mangle]
pub extern "C" fn kanal_unbounded_init() -> *mut c_void {
    let (tx, rx) = kanal::unbounded::<u64>();
    let pair = Box::new(KanalPair { tx, rx });
    Box::into_raw(pair) as *mut c_void
}

/// # Safety
/// `q` must be a live KanalPair pointer.
#[no_mangle]
pub unsafe extern "C" fn kanal_unbounded_push(q: *mut c_void, item: u64) -> bool {
    if q.is_null() {
        return false;
    }
    let pair = unsafe { &*(q as *const KanalPair) };
    pair.tx.try_send(item).unwrap_or(false)
}

/// # Safety
/// See `kanal_pop`.
#[no_mangle]
pub unsafe extern "C" fn kanal_unbounded_pop(q: *mut c_void, out: *mut u64) -> bool {
    if q.is_null() || out.is_null() {
        return false;
    }
    let pair = unsafe { &*(q as *const KanalPair) };
    match pair.rx.try_recv() {
        Ok(Some(v)) => {
            unsafe {
                std::ptr::write(out, v);
            }
            true
        }
        Ok(None) | Err(_) => false,
    }
}

/// # Safety
/// `q` must be a pointer previously returned by `kanal_unbounded_init`.
#[no_mangle]
pub unsafe extern "C" fn kanal_unbounded_destroy(q: *mut c_void) {
    if q.is_null() {
        return;
    }
    drop(unsafe { Box::from_raw(q as *mut KanalPair) });
}

#[no_mangle]
pub extern "C" fn kanal_rendezvous_init() -> *mut c_void {
    let (tx, rx) = kanal::bounded::<u64>(0);
    let pair = Box::new(KanalPair { tx, rx });
    Box::into_raw(pair) as *mut c_void
}

/// # Safety
/// `q` must be a live KanalPair pointer.
#[no_mangle]
pub unsafe extern "C" fn kanal_rendezvous_send(q: *mut c_void, item: u64) -> bool {
    if q.is_null() {
        return false;
    }
    let pair = unsafe { &*(q as *const KanalPair) };
    pair.tx.send(item).is_ok()
}

/// # Safety
/// `q` must be a live KanalPair pointer; `out` must be writable.
#[no_mangle]
pub unsafe extern "C" fn kanal_rendezvous_recv(q: *mut c_void, out: *mut u64) -> bool {
    if q.is_null() || out.is_null() {
        return false;
    }
    let pair = unsafe { &*(q as *const KanalPair) };
    match pair.rx.recv() {
        Ok(v) => {
            unsafe {
                std::ptr::write(out, v);
            }
            true
        }
        Err(_) => false,
    }
}

/// # Safety
/// `q` must be a pointer previously returned by `kanal_rendezvous_init`.
#[no_mangle]
pub unsafe extern "C" fn kanal_rendezvous_destroy(q: *mut c_void) {
    if q.is_null() {
        return;
    }
    drop(unsafe { Box::from_raw(q as *mut KanalPair) });
}

// ============================================================
// crossbeam-channel rendezvous (0-capacity)
// ============================================================

struct CbChannelPair {
    tx: crossbeam_channel::Sender<u64>,
    rx: crossbeam_channel::Receiver<u64>,
}

#[no_mangle]
pub extern "C" fn cb_rendezvous_init() -> *mut c_void {
    let (tx, rx) = crossbeam_channel::bounded::<u64>(0);
    let pair = Box::new(CbChannelPair { tx, rx });
    Box::into_raw(pair) as *mut c_void
}

/// # Safety
/// `q` must be a live CbChannelPair pointer.
#[no_mangle]
pub unsafe extern "C" fn cb_rendezvous_send(q: *mut c_void, item: u64) -> bool {
    if q.is_null() {
        return false;
    }
    let pair = unsafe { &*(q as *const CbChannelPair) };
    pair.tx.send(item).is_ok()
}

/// # Safety
/// `q` must be a live CbChannelPair pointer; `out` must be writable.
#[no_mangle]
pub unsafe extern "C" fn cb_rendezvous_recv(q: *mut c_void, out: *mut u64) -> bool {
    if q.is_null() || out.is_null() {
        return false;
    }
    let pair = unsafe { &*(q as *const CbChannelPair) };
    match pair.rx.recv() {
        Ok(v) => {
            unsafe {
                std::ptr::write(out, v);
            }
            true
        }
        Err(_) => false,
    }
}

/// # Safety
/// `q` must be a pointer previously returned by `cb_rendezvous_init`.
#[no_mangle]
pub unsafe extern "C" fn cb_rendezvous_destroy(q: *mut c_void) {
    if q.is_null() {
        return;
    }
    drop(unsafe { Box::from_raw(q as *mut CbChannelPair) });
}

// ============================================================
// Associative Maps & Sets: DashMap, Flurry, SkipMap, SkipSet
// ============================================================

#[no_mangle]
pub extern "C" fn dm_init() -> *mut c_void {
    let m = Box::new(DashMap::<u64, u64>::with_capacity(65536));
    Box::into_raw(m) as *mut c_void
}

/// # Safety
/// `m` must be a live DashMap pointer; `out` must be writable.
#[no_mangle]
pub unsafe extern "C" fn dm_get(m: *mut c_void, key: u64, out: *mut u64) -> bool {
    if m.is_null() || out.is_null() {
        return false;
    }
    let map = unsafe { &*(m as *const DashMap<u64, u64>) };
    match map.get(&key) {
        Some(v) => {
            unsafe {
                std::ptr::write(out, *v);
            }
            true
        }
        None => false,
    }
}

/// # Safety
/// `m` must be a live DashMap pointer.
#[no_mangle]
pub unsafe extern "C" fn dm_put(m: *mut c_void, key: u64, val: u64) -> bool {
    if m.is_null() {
        return false;
    }
    let map = unsafe { &*(m as *const DashMap<u64, u64>) };
    map.insert(key, val);
    true
}

/// # Safety
/// `m` must be a live DashMap pointer.
#[no_mangle]
pub unsafe extern "C" fn dm_remove(m: *mut c_void, key: u64) -> bool {
    if m.is_null() {
        return false;
    }
    let map = unsafe { &*(m as *const DashMap<u64, u64>) };
    map.remove(&key).is_some()
}

/// # Safety
/// `m` must be a live DashMap pointer.
#[no_mangle]
pub unsafe extern "C" fn dm_iter_sum(m: *mut c_void) -> u64 {
    if m.is_null() {
        return 0;
    }
    let map = unsafe { &*(m as *const DashMap<u64, u64>) };
    let mut sum = 0u64;
    for entry in map.iter() {
        sum = sum.wrapping_add(*entry.value());
    }
    sum
}

/// # Safety
/// `m` must be a pointer returned by `dm_init`.
#[no_mangle]
pub unsafe extern "C" fn dm_destroy(m: *mut c_void) {
    if m.is_null() {
        return;
    }
    drop(unsafe { Box::from_raw(m as *mut DashMap<u64, u64>) });
}

// ---------------- flurry::HashMap<u64, u64> ----------------

#[no_mangle]
pub extern "C" fn flurry_init() -> *mut c_void {
    let m = Box::new(flurry::HashMap::<u64, u64>::with_capacity(65536));
    Box::into_raw(m) as *mut c_void
}

/// # Safety
/// `m` must be a live flurry::HashMap pointer; `out` must be writable.
#[no_mangle]
pub unsafe extern "C" fn flurry_get(m: *mut c_void, key: u64, out: *mut u64) -> bool {
    if m.is_null() || out.is_null() {
        return false;
    }
    let map = unsafe { &*(m as *const flurry::HashMap<u64, u64>) };
    let guard = map.guard();
    match map.get(&key, &guard) {
        Some(&v) => {
            unsafe {
                std::ptr::write(out, v);
            }
            true
        }
        None => false,
    }
}

/// # Safety
/// `m` must be a live flurry::HashMap pointer.
#[no_mangle]
pub unsafe extern "C" fn flurry_put(m: *mut c_void, key: u64, val: u64) -> bool {
    if m.is_null() {
        return false;
    }
    let map = unsafe { &*(m as *const flurry::HashMap<u64, u64>) };
    let guard = map.guard();
    map.insert(key, val, &guard);
    true
}

/// # Safety
/// `m` must be a live flurry::HashMap pointer.
#[no_mangle]
pub unsafe extern "C" fn flurry_remove(m: *mut c_void, key: u64) -> bool {
    if m.is_null() {
        return false;
    }
    let map = unsafe { &*(m as *const flurry::HashMap<u64, u64>) };
    let guard = map.guard();
    map.remove(&key, &guard).is_some()
}

/// # Safety
/// `m` must be a pointer returned by `flurry_init`.
#[no_mangle]
pub unsafe extern "C" fn flurry_destroy(m: *mut c_void) {
    if m.is_null() {
        return;
    }
    drop(unsafe { Box::from_raw(m as *mut flurry::HashMap<u64, u64>) });
}

// ---------------- crossbeam_skiplist::SkipMap<u64, u64> ----------------

#[no_mangle]
pub extern "C" fn cb_skipmap_init() -> *mut c_void {
    let m = Box::new(SkipMap::<u64, u64>::new());
    Box::into_raw(m) as *mut c_void
}

/// # Safety
/// `m` must be a live SkipMap pointer; `out` must be writable.
#[no_mangle]
pub unsafe extern "C" fn cb_skipmap_get(m: *mut c_void, key: u64, out: *mut u64) -> bool {
    if m.is_null() || out.is_null() {
        return false;
    }
    let map = unsafe { &*(m as *const SkipMap<u64, u64>) };
    match map.get(&key) {
        Some(entry) => {
            unsafe {
                std::ptr::write(out, *entry.value());
            }
            true
        }
        None => false,
    }
}

/// # Safety
/// `m` must be a live SkipMap pointer.
#[no_mangle]
pub unsafe extern "C" fn cb_skipmap_put(m: *mut c_void, key: u64, val: u64) -> bool {
    if m.is_null() {
        return false;
    }
    let map = unsafe { &*(m as *const SkipMap<u64, u64>) };
    map.insert(key, val);
    true
}

/// # Safety
/// `m` must be a live SkipMap pointer.
#[no_mangle]
pub unsafe extern "C" fn cb_skipmap_remove(m: *mut c_void, key: u64) -> bool {
    if m.is_null() {
        return false;
    }
    let map = unsafe { &*(m as *const SkipMap<u64, u64>) };
    map.remove(&key).is_some()
}

/// # Safety
/// `m` must be a pointer returned by `cb_skipmap_init`.
#[no_mangle]
pub unsafe extern "C" fn cb_skipmap_destroy(m: *mut c_void) {
    if m.is_null() {
        return;
    }
    drop(unsafe { Box::from_raw(m as *mut SkipMap<u64, u64>) });
}

// ---------------- crossbeam_skiplist::SkipSet<u64> ----------------

#[no_mangle]
pub extern "C" fn cb_skipset_init() -> *mut c_void {
    let s = Box::new(SkipSet::<u64>::new());
    Box::into_raw(s) as *mut c_void
}

/// # Safety
/// `s` must be a live SkipSet pointer.
#[no_mangle]
pub unsafe extern "C" fn cb_skipset_contains(s: *mut c_void, key: u64) -> bool {
    if s.is_null() {
        return false;
    }
    let set = unsafe { &*(s as *const SkipSet<u64>) };
    set.contains(&key)
}

/// # Safety
/// `s` must be a live SkipSet pointer.
#[no_mangle]
pub unsafe extern "C" fn cb_skipset_insert(s: *mut c_void, key: u64) -> bool {
    if s.is_null() {
        return false;
    }
    let set = unsafe { &*(s as *const SkipSet<u64>) };
    set.insert(key);
    true
}

/// # Safety
/// `s` must be a live SkipSet pointer.
#[no_mangle]
pub unsafe extern "C" fn cb_skipset_remove(s: *mut c_void, key: u64) -> bool {
    if s.is_null() {
        return false;
    }
    let set = unsafe { &*(s as *const SkipSet<u64>) };
    set.remove(&key).is_some()
}

/// # Safety
/// `s` must be a pointer returned by `cb_skipset_init`.
#[no_mangle]
pub unsafe extern "C" fn cb_skipset_destroy(s: *mut c_void) {
    if s.is_null() {
        return;
    }
    drop(unsafe { Box::from_raw(s as *mut SkipSet<u64>) });
}

// ============================================================
// Work-Stealing Deque: crossbeam_deque (Worker + Stealer)
// ============================================================

struct CbDequeCtx {
    worker: UnsafeCell<Worker<u64>>,
    stealer: Stealer<u64>,
    thief_locals: Vec<UnsafeCell<Worker<u64>>>,
}

unsafe impl Sync for CbDequeCtx {}
unsafe impl Send for CbDequeCtx {}

#[no_mangle]
pub extern "C" fn cb_deque_init(num_thieves: usize) -> *mut c_void {
    let worker = Worker::<u64>::new_lifo();
    let stealer = worker.stealer();
    let mut thief_locals = Vec::with_capacity(num_thieves.max(1));
    for _ in 0..num_thieves.max(1) {
        thief_locals.push(UnsafeCell::new(Worker::<u64>::new_lifo()));
    }
    let ctx = Box::new(CbDequeCtx {
        worker: UnsafeCell::new(worker),
        stealer,
        thief_locals,
    });
    Box::into_raw(ctx) as *mut c_void
}

/// # Safety
/// `d` must be a live CbDequeCtx pointer; only the single owner-worker thread may call push/pop.
#[no_mangle]
pub unsafe extern "C" fn cb_deque_push(d: *mut c_void, item: u64) {
    if d.is_null() {
        return;
    }
    let ctx = unsafe { &*(d as *const CbDequeCtx) };
    let w = unsafe { &*ctx.worker.get() };
    w.push(item);
}

/// # Safety
/// `d` must be a live CbDequeCtx pointer; `out` must be writable.
#[no_mangle]
pub unsafe extern "C" fn cb_deque_pop(d: *mut c_void, out: *mut u64) -> bool {
    if d.is_null() || out.is_null() {
        return false;
    }
    let ctx = unsafe { &*(d as *const CbDequeCtx) };
    let w = unsafe { &*ctx.worker.get() };
    match w.pop() {
        Some(v) => {
            unsafe {
                std::ptr::write(out, v);
            }
            true
        }
        None => false,
    }
}

/// # Safety
/// `d` must be a live CbDequeCtx pointer; `out` must be writable.
#[no_mangle]
pub unsafe extern "C" fn cb_deque_steal(d: *mut c_void, out: *mut u64) -> bool {
    if d.is_null() || out.is_null() {
        return false;
    }
    let ctx = unsafe { &*(d as *const CbDequeCtx) };
    loop {
        match ctx.stealer.steal() {
            Steal::Success(v) => {
                unsafe {
                    std::ptr::write(out, v);
                }
                return true;
            }
            Steal::Empty => return false,
            Steal::Retry => std::hint::spin_loop(),
        }
    }
}

/// # Safety
/// `d` must be a live CbDequeCtx pointer; `thief_idx` must be `< num_thieves` and unique per thief thread.
#[no_mangle]
pub unsafe extern "C" fn cb_deque_steal_batch(
    d: *mut c_void,
    thief_idx: usize,
    max_batch: usize,
) -> usize {
    if d.is_null() || max_batch == 0 {
        return 0;
    }
    let ctx = unsafe { &*(d as *const CbDequeCtx) };
    if thief_idx >= ctx.thief_locals.len() {
        return 0;
    }
    let local_w = unsafe { &*ctx.thief_locals[thief_idx].get() };
    loop {
        match ctx.stealer.steal_batch_with_limit(local_w, max_batch) {
            Steal::Success(()) => {
                let mut count = 0usize;
                while local_w.pop().is_some() {
                    count += 1;
                }
                return count;
            }
            Steal::Empty => return 0,
            Steal::Retry => std::hint::spin_loop(),
        }
    }
}

/// # Safety
/// `d` must be a live CbDequeCtx pointer.
#[no_mangle]
pub unsafe extern "C" fn cb_deque_is_empty(d: *mut c_void) -> bool {
    if d.is_null() {
        return true;
    }
    let ctx = unsafe { &*(d as *const CbDequeCtx) };
    ctx.stealer.is_empty()
}

/// # Safety
/// `d` must be a pointer returned by `cb_deque_init`.
#[no_mangle]
pub unsafe extern "C" fn cb_deque_destroy(d: *mut c_void) {
    if d.is_null() {
        return;
    }
    drop(unsafe { Box::from_raw(d as *mut CbDequeCtx) });
}

// ============================================================
// Broadcast & Pub-Sub: tokio::sync::broadcast & bus::Bus
// ============================================================

struct TokioBroadcastCtx {
    tx: tokio::sync::broadcast::Sender<u64>,
    rxs: Vec<UnsafeCell<tokio::sync::broadcast::Receiver<u64>>>,
}

unsafe impl Sync for TokioBroadcastCtx {}
unsafe impl Send for TokioBroadcastCtx {}

#[no_mangle]
pub extern "C" fn tokio_bcast_init(capacity: usize, num_subs: usize) -> *mut c_void {
    let cap = capacity.max(16);
    let (tx, rx0) = tokio::sync::broadcast::channel::<u64>(cap);
    let mut rxs = Vec::with_capacity(num_subs.max(1));
    if num_subs > 0 {
        rxs.push(UnsafeCell::new(rx0));
        for _ in 1..num_subs {
            rxs.push(UnsafeCell::new(tx.subscribe()));
        }
    } else {
        drop(rx0);
    }
    let ctx = Box::new(TokioBroadcastCtx { tx, rxs });
    Box::into_raw(ctx) as *mut c_void
}

/// # Safety
/// `b` must be a live TokioBroadcastCtx pointer.
#[no_mangle]
pub unsafe extern "C" fn tokio_bcast_send(b: *mut c_void, item: u64) -> bool {
    if b.is_null() {
        return false;
    }
    let ctx = unsafe { &*(b as *const TokioBroadcastCtx) };
    ctx.tx.send(item).is_ok()
}

/// Returns:
/// - `1` on `Ok(val)` (writes `val` to `*out`)
/// - `-1` on `Err(TryRecvError::Lagged)` (horizon advanced automatically; caller should retry immediately)
/// - `0` on `Err(TryRecvError::Empty | Closed)`
///
/// # Safety
/// `b` must be a live TokioBroadcastCtx pointer; `sub_idx` must be exclusive to the calling thread.
#[no_mangle]
pub unsafe extern "C" fn tokio_bcast_try_recv(
    b: *mut c_void,
    sub_idx: usize,
    out: *mut u64,
) -> i32 {
    if b.is_null() || out.is_null() {
        return 0;
    }
    let ctx = unsafe { &*(b as *const TokioBroadcastCtx) };
    if sub_idx >= ctx.rxs.len() {
        return 0;
    }
    let rx = unsafe { &mut *ctx.rxs[sub_idx].get() };
    match rx.try_recv() {
        Ok(v) => {
            unsafe {
                std::ptr::write(out, v);
            }
            1
        }
        Err(tokio::sync::broadcast::error::TryRecvError::Lagged(_)) => -1,
        Err(_) => 0,
    }
}

/// # Safety
/// `b` must be a pointer returned by `tokio_bcast_init`.
#[no_mangle]
pub unsafe extern "C" fn tokio_bcast_destroy(b: *mut c_void) {
    if b.is_null() {
        return;
    }
    drop(unsafe { Box::from_raw(b as *mut TokioBroadcastCtx) });
}

// ---------------- bus::Bus<u64> (SPMC bounded broadcast ring) ----------------

struct RustBusCtx {
    bus: UnsafeCell<bus::Bus<u64>>,
    rxs: Vec<UnsafeCell<bus::BusReader<u64>>>,
}

unsafe impl Sync for RustBusCtx {}
unsafe impl Send for RustBusCtx {}

#[no_mangle]
pub extern "C" fn rust_bus_init(capacity: usize, num_subs: usize) -> *mut c_void {
    let cap = capacity.max(16);
    let mut b = bus::Bus::<u64>::new(cap);
    let mut rxs = Vec::with_capacity(num_subs);
    for _ in 0..num_subs {
        rxs.push(UnsafeCell::new(b.add_rx()));
    }
    let ctx = Box::new(RustBusCtx {
        bus: UnsafeCell::new(b),
        rxs,
    });
    Box::into_raw(ctx) as *mut c_void
}

/// # Safety
/// `b` must be a live RustBusCtx pointer; only the single publisher thread may call `rust_bus_try_broadcast`.
#[no_mangle]
pub unsafe extern "C" fn rust_bus_try_broadcast(b: *mut c_void, item: u64) -> bool {
    if b.is_null() {
        return false;
    }
    let ctx = unsafe { &*(b as *const RustBusCtx) };
    let bus_ref = unsafe { &mut *ctx.bus.get() };
    bus_ref.try_broadcast(item).is_ok()
}

/// # Safety
/// `b` must be a live RustBusCtx pointer; `sub_idx` must be exclusive to the calling subscriber thread.
#[no_mangle]
pub unsafe extern "C" fn rust_bus_try_recv(b: *mut c_void, sub_idx: usize, out: *mut u64) -> bool {
    if b.is_null() || out.is_null() {
        return false;
    }
    let ctx = unsafe { &*(b as *const RustBusCtx) };
    if sub_idx >= ctx.rxs.len() {
        return false;
    }
    let rx = unsafe { &mut *ctx.rxs[sub_idx].get() };
    match rx.try_recv() {
        Ok(v) => {
            unsafe {
                std::ptr::write(out, v);
            }
            true
        }
        Err(_) => false,
    }
}

/// # Safety
/// `b` must be a pointer returned by `rust_bus_init`.
#[no_mangle]
pub unsafe extern "C" fn rust_bus_destroy(b: *mut c_void) {
    if b.is_null() {
        return;
    }
    drop(unsafe { Box::from_raw(b as *mut RustBusCtx) });
}

// ============================================================
// Rate Limiters & Stream Buffers: governor (GCRA) & rtrb (SPSC)
// ============================================================

type DirectLimiter = RateLimiter<
    governor::state::NotKeyed,
    governor::state::InMemoryState,
    governor::clock::DefaultClock,
    governor::middleware::NoOpMiddleware,
>;

#[no_mangle]
pub extern "C" fn governor_init(rate_per_sec: u32, burst: u32) -> *mut c_void {
    let r = NonZeroU32::new(rate_per_sec.max(1)).unwrap();
    let b = NonZeroU32::new(burst.max(1)).unwrap();
    let quota = Quota::per_second(r).allow_burst(b);
    let lim: DirectLimiter = RateLimiter::direct(quota);
    Box::into_raw(Box::new(lim)) as *mut c_void
}

/// # Safety
/// `g` must be a live DirectLimiter pointer returned by `governor_init`.
#[no_mangle]
pub unsafe extern "C" fn governor_check(g: *mut c_void) -> bool {
    if g.is_null() {
        return false;
    }
    let lim = unsafe { &*(g as *const DirectLimiter) };
    lim.check().is_ok()
}

/// # Safety
/// `g` must be a pointer returned by `governor_init`.
#[no_mangle]
pub unsafe extern "C" fn governor_destroy(g: *mut c_void) {
    if g.is_null() {
        return;
    }
    drop(unsafe { Box::from_raw(g as *mut DirectLimiter) });
}

// ---------------- rtrb::RingBuffer<u8> (wait-free SPSC byte stream) ----------------

#[repr(align(128))]
struct AlignedProducer(UnsafeCell<rtrb::Producer<u8>>);

#[repr(align(128))]
struct AlignedConsumer(UnsafeCell<rtrb::Consumer<u8>>);

struct RtrbStreamCtx {
    prod: AlignedProducer,
    cons: AlignedConsumer,
}

unsafe impl Sync for RtrbStreamCtx {}
unsafe impl Send for RtrbStreamCtx {}

#[no_mangle]
pub extern "C" fn rtrb_init(capacity: usize) -> *mut c_void {
    let (prod, cons) = rtrb::RingBuffer::<u8>::new(capacity.max(64));
    let ctx = Box::new(RtrbStreamCtx {
        prod: AlignedProducer(UnsafeCell::new(prod)),
        cons: AlignedConsumer(UnsafeCell::new(cons)),
    });
    Box::into_raw(ctx) as *mut c_void
}

/// # Safety
/// `r` must be a live RtrbStreamCtx pointer; only the single producer thread may call `rtrb_write`.
#[no_mangle]
pub unsafe extern "C" fn rtrb_write(r: *mut c_void, src: *const u8, len: usize) -> usize {
    if r.is_null() || src.is_null() || len == 0 {
        return 0;
    }
    let ctx = unsafe { &*(r as *const RtrbStreamCtx) };
    let prod = unsafe { &mut *ctx.prod.0.get() };
    let avail = prod.slots();
    if avail == 0 {
        return 0;
    }
    let to_write = len.min(avail);
    if let Ok(mut chunk) = prod.write_chunk_uninit(to_write) {
        let (first, second) = chunk.as_mut_slices();
        let first_len = first.len();
        unsafe {
            std::ptr::copy_nonoverlapping(src as *const std::mem::MaybeUninit<u8>, first.as_mut_ptr(), first_len);
            if !second.is_empty() {
                std::ptr::copy_nonoverlapping(
                    src.add(first_len) as *const std::mem::MaybeUninit<u8>,
                    second.as_mut_ptr(),
                    second.len(),
                );
            }
            chunk.commit_all();
        }
        to_write
    } else {
        0
    }
}

/// # Safety
/// `r` must be a live RtrbStreamCtx pointer; only the single consumer thread may call `rtrb_read`.
#[no_mangle]
pub unsafe extern "C" fn rtrb_read(r: *mut c_void, dst: *mut u8, len: usize) -> usize {
    if r.is_null() || dst.is_null() || len == 0 {
        return 0;
    }
    let ctx = unsafe { &*(r as *const RtrbStreamCtx) };
    let cons = unsafe { &mut *ctx.cons.0.get() };
    let avail = cons.slots();
    if avail == 0 {
        return 0;
    }
    let to_read = len.min(avail);
    if let Ok(chunk) = cons.read_chunk(to_read) {
        let (first, second) = chunk.as_slices();
        let first_len = first.len();
        unsafe {
            std::ptr::copy_nonoverlapping(first.as_ptr(), dst, first_len);
            if !second.is_empty() {
                std::ptr::copy_nonoverlapping(second.as_ptr(), dst.add(first_len), second.len());
            }
        }
        chunk.commit_all();
        to_read
    } else {
        0
    }
}

/// # Safety
/// `r` must be a pointer returned by `rtrb_init`.
#[no_mangle]
pub unsafe extern "C" fn rtrb_destroy(r: *mut c_void) {
    if r.is_null() {
        return;
    }
    drop(unsafe { Box::from_raw(r as *mut RtrbStreamCtx) });
}

// ============================================================
// Workstream B Support: rayon ThreadPool & crossbeam-epoch SMR
// ============================================================

#[inline(always)]
fn mix64(mut x: u64) -> u64 {
    x ^= x >> 30;
    x = x.wrapping_mul(0xbf58476d1ce4e5b9);
    x ^= x >> 27;
    x = x.wrapping_mul(0x94d049bb133111eb);
    x ^ (x >> 31)
}

#[no_mangle]
pub extern "C" fn rayon_pool_init(num_threads: usize) -> *mut c_void {
    let n = num_threads.max(1);
    match rayon::ThreadPoolBuilder::new().num_threads(n).build() {
        Ok(pool) => Box::into_raw(Box::new(pool)) as *mut c_void,
        Err(_) => std::ptr::null_mut(),
    }
}

/// # Safety
/// `p` must be a live `rayon::ThreadPool` pointer returned by `rayon_pool_init`, and `out_sum` may be null or a valid pointer.
#[no_mangle]
pub unsafe extern "C" fn rayon_pool_parfor(
    p: *mut c_void,
    count: usize,
    out_sum: *mut u64,
) -> bool {
    if p.is_null() || count == 0 {
        return false;
    }
    let pool = unsafe { &*(p as *const rayon::ThreadPool) };
    let sum = pool.install(|| {
        (0..count)
            .into_par_iter()
            .with_min_len(256)
            .map(|i| mix64(i as u64))
            .reduce(|| 0u64, |a, b| a.wrapping_add(b))
    });
    if !out_sum.is_null() {
        unsafe {
            std::ptr::write(out_sum, sum);
        }
    }
    true
}

fn rayon_forkjoin_rec(depth: usize, seed: u64) -> u64 {
    if depth == 0 {
        let mut acc = seed;
        for k in 0..16u64 {
            acc = mix64(acc.wrapping_add(k));
        }
        return acc;
    }
    let (a, b) = rayon::join(
        || rayon_forkjoin_rec(depth - 1, seed.wrapping_mul(2).wrapping_add(1)),
        || rayon_forkjoin_rec(depth - 1, seed.wrapping_mul(2).wrapping_add(2)),
    );
    a.wrapping_add(b)
}

/// # Safety
/// `p` must be a live `rayon::ThreadPool` pointer returned by `rayon_pool_init`, and `out_sum` may be null or a valid pointer.
#[no_mangle]
pub unsafe extern "C" fn rayon_pool_forkjoin(
    p: *mut c_void,
    depth: usize,
    out_sum: *mut u64,
) -> bool {
    if p.is_null() {
        return false;
    }
    let pool = unsafe { &*(p as *const rayon::ThreadPool) };
    let sum = pool.install(|| rayon_forkjoin_rec(depth.min(20), 1));
    if !out_sum.is_null() {
        unsafe {
            std::ptr::write(out_sum, sum);
        }
    }
    true
}

/// # Safety
/// `p` must be a pointer returned by `rayon_pool_init`.
#[no_mangle]
pub unsafe extern "C" fn rayon_pool_destroy(p: *mut c_void) {
    if p.is_null() {
        return;
    }
    drop(unsafe { Box::from_raw(p as *mut rayon::ThreadPool) });
}

// ---------------- crossbeam-epoch SMR ----------------

static CBE_SHARED_SLOT: AtomicU64 = AtomicU64::new(42);

#[no_mangle]
pub extern "C" fn cbe_pin_unpin_batch(iters: usize) -> u64 {
    let mut sum = 0u64;
    for _ in 0..iters {
        let guard = crossbeam_epoch::pin();
        let v = CBE_SHARED_SLOT.load(Ordering::Acquire);
        sum = sum.wrapping_add(v);
        std::hint::black_box(&guard);
        drop(guard);
    }
    sum
}

#[no_mangle]
pub extern "C" fn cbe_retire_reclaim_batch(iters: usize) -> u64 {
    let mut sum = 0u64;
    for i in 0..iters {
        let guard = crossbeam_epoch::pin();
        let owned = crossbeam_epoch::Owned::new(i as u64);
        let shared = owned.into_shared(&guard);
        let d = unsafe { shared.deref() };
        sum = sum.wrapping_add(*d);
        unsafe {
            guard.defer_destroy(shared);
        }
        if (i & 63) == 63 {
            guard.flush();
        }
    }
    let guard = crossbeam_epoch::pin();
    guard.flush();
    sum
}
