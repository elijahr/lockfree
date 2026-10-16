//! Integration test for the C-ABI surface. Calls the public extern "C"
//! functions directly through the rlib so the same code path the cdylib
//! exports is exercised end-to-end (init -> N pushes -> N pops -> destroy)
//! with count + set assertions matching the Nim adapter's smoke test.

use std::collections::HashSet;
use std::os::raw::c_void;

use bench_ffi_crossbeam::{
    bench_ffi_crossbeam_queue_version, bench_ffi_flume_version,
    bench_ffi_kanal_version, cb_array_destroy, cb_array_init, cb_array_pop,
    cb_array_push, cb_seg_destroy, cb_seg_init, cb_seg_pop, cb_seg_push,
};

// Bind the local names the tests use so the rest of the file (which
// passes raw `*mut c_void`) reads identically to the cdylib consumer.
// Each call site below uses the imported function directly.
#[allow(dead_code)]
fn _shape_check() -> *mut c_void {
    std::ptr::null_mut()
}

const N: u64 = 1000;

#[test]
fn array_queue_round_trip_preserves_set() {
    unsafe {
        let q = cb_array_init(N as usize);
        assert!(!q.is_null());

        let mut pushed: HashSet<u64> = HashSet::new();
        for i in 0..N {
            assert!(cb_array_push(q, i), "array push failed at i={i}");
            pushed.insert(i);
        }

        let mut popped: HashSet<u64> = HashSet::new();
        let mut out: u64 = 0;
        while cb_array_pop(q, &mut out) {
            popped.insert(out);
        }

        assert_eq!(popped.len() as u64, N);
        assert_eq!(pushed, popped);

        cb_array_destroy(q);
    }
}

#[test]
fn array_queue_full_returns_false() {
    unsafe {
        let q = cb_array_init(2);
        assert!(cb_array_push(q, 10));
        assert!(cb_array_push(q, 20));
        assert!(!cb_array_push(q, 30), "expected push to fail at capacity");
        cb_array_destroy(q);
    }
}

#[test]
fn array_queue_zero_capacity_returns_null() {
    // `cb_array_init` is not `unsafe` (it has no preconditions on a
    // 0-arg path), so the test body intentionally does not wrap it.
    // Guard against the upstream panic on ArrayQueue::new(0); we
    // return null instead so the FFI never unwinds.
    let q = cb_array_init(0);
    assert!(q.is_null());
}

#[test]
fn seg_queue_round_trip_preserves_set() {
    unsafe {
        let q = cb_seg_init();
        assert!(!q.is_null());

        let mut pushed: HashSet<u64> = HashSet::new();
        for i in 0..N {
            assert!(cb_seg_push(q, i));
            pushed.insert(i);
        }

        let mut popped: HashSet<u64> = HashSet::new();
        let mut out: u64 = 0;
        while cb_seg_pop(q, &mut out) {
            popped.insert(out);
        }

        assert_eq!(popped.len() as u64, N);
        assert_eq!(pushed, popped);

        cb_seg_destroy(q);
    }
}

#[test]
fn pop_empty_returns_false() {
    unsafe {
        let q = cb_array_init(4);
        let mut out: u64 = 999;
        assert!(!cb_array_pop(q, &mut out));
        assert_eq!(out, 999, "out unchanged on empty pop");
        cb_array_destroy(q);

        let q = cb_seg_init();
        assert!(!cb_seg_pop(q, &mut out));
        cb_seg_destroy(q);
    }
}

#[test]
fn null_pointer_safe() {
    unsafe {
        let mut out: u64 = 0;
        assert!(!cb_array_push(std::ptr::null_mut(), 1));
        assert!(!cb_array_pop(std::ptr::null_mut(), &mut out));
        assert!(!cb_seg_push(std::ptr::null_mut(), 1));
        assert!(!cb_seg_pop(std::ptr::null_mut(), &mut out));
        cb_array_destroy(std::ptr::null_mut());
        cb_seg_destroy(std::ptr::null_mut());
    }
}

// ---------------- Version-getter tests (v5.0.0-wave Item 1) ----------------
//
// `build.rs` reads `Cargo.lock` and bakes the resolved versions of
// `crossbeam-queue`, `flume`, and `kanal` into env vars; the three
// exported version getters return those strings as C cstrings. These
// tests catch a "build.rs didn't fire" silent failure: an empty string
// or a non-semver-looking value means the version-capture chain is
// broken, and the bench JSON would silently lie about which versions
// were linked in.

/// Convert an FFI version-getter return value into a Rust `&str`,
/// asserting the pointer is non-null and the string has no embedded
/// NULs.
unsafe fn fetch_version(ptr: *const std::os::raw::c_char) -> &'static str {
    assert!(!ptr.is_null(), "version getter returned null pointer");
    std::ffi::CStr::from_ptr(ptr)
        .to_str()
        .expect("version string is not valid UTF-8")
}

/// Minimal semver-shape check: at least `MAJOR.MINOR.PATCH` with all
/// three parts numeric. We do not require strict semver (pre-release /
/// build metadata is rare here) — the goal is to catch "got an empty
/// string" or "got the env var literal" silent failures.
fn looks_semver_ish(s: &str) -> bool {
    let parts: Vec<&str> = s.split('.').collect();
    if parts.len() < 3 {
        return false;
    }
    // First three components must parse as u32.
    parts[..3].iter().all(|p| {
        // Strip optional `-suffix` / `+build` from the patch component.
        let stem = p
            .split(|c: char| c == '-' || c == '+')
            .next()
            .unwrap_or("");
        !stem.is_empty() && stem.chars().all(|c| c.is_ascii_digit())
    })
}

#[test]
fn crossbeam_queue_version_baked_in() {
    let v = unsafe { fetch_version(bench_ffi_crossbeam_queue_version()) };
    assert!(!v.is_empty(), "crossbeam-queue version string is empty");
    assert!(
        looks_semver_ish(v),
        "crossbeam-queue version {:?} does not look like semver",
        v,
    );
}

#[test]
fn flume_version_baked_in() {
    let v = unsafe { fetch_version(bench_ffi_flume_version()) };
    assert!(!v.is_empty(), "flume version string is empty");
    assert!(
        looks_semver_ish(v),
        "flume version {:?} does not look like semver",
        v,
    );
}

#[test]
fn kanal_version_baked_in() {
    let v = unsafe { fetch_version(bench_ffi_kanal_version()) };
    assert!(!v.is_empty(), "kanal version string is empty");
    assert!(
        looks_semver_ish(v),
        "kanal version {:?} does not look like semver",
        v,
    );
}

#[test]
fn extended_crate_versions_baked_in() {
    use bench_ffi_crossbeam::*;
    let getters: &[(&str, unsafe extern "C" fn() -> *const std::os::raw::c_char)] = &[
        ("dashmap", bench_ffi_dashmap_version),
        ("flurry", bench_ffi_flurry_version),
        ("crossbeam-skiplist", bench_ffi_crossbeam_skiplist_version),
        ("crossbeam-deque", bench_ffi_crossbeam_deque_version),
        ("tokio", bench_ffi_tokio_version),
        ("bus", bench_ffi_bus_version),
        ("governor", bench_ffi_governor_version),
        ("rtrb", bench_ffi_rtrb_version),
        ("crossbeam-channel", bench_ffi_crossbeam_channel_version),
        ("crossbeam-epoch", bench_ffi_crossbeam_epoch_version),
        ("rayon", bench_ffi_rayon_version),
    ];
    for (name, getter) in getters {
        let v = unsafe { fetch_version(getter()) };
        assert!(!v.is_empty(), "{name} version string is empty");
        assert!(
            looks_semver_ish(v),
            "{name} version {:?} does not look like semver",
            v
        );
    }
}

#[test]
fn maps_and_sets_ffi_round_trip() {
    use bench_ffi_crossbeam::*;
    unsafe {
        let dm = dm_init();
        assert!(!dm.is_null());
        assert!(dm_put(dm, 10, 100));
        let mut out = 0u64;
        assert!(dm_get(dm, 10, &mut out));
        assert_eq!(out, 100);
        assert_eq!(dm_iter_sum(dm), 100);
        assert!(dm_remove(dm, 10));
        assert!(!dm_get(dm, 10, &mut out));
        dm_destroy(dm);

        let fl = flurry_init();
        assert!(!fl.is_null());
        assert!(flurry_put(fl, 20, 200));
        assert!(flurry_get(fl, 20, &mut out));
        assert_eq!(out, 200);
        assert!(flurry_remove(fl, 20));
        assert!(!flurry_get(fl, 20, &mut out));
        flurry_destroy(fl);

        let sm = cb_skipmap_init();
        assert!(!sm.is_null());
        assert!(cb_skipmap_put(sm, 30, 300));
        assert!(cb_skipmap_get(sm, 30, &mut out));
        assert_eq!(out, 300);
        assert!(cb_skipmap_remove(sm, 30));
        assert!(!cb_skipmap_get(sm, 30, &mut out));
        cb_skipmap_destroy(sm);

        let ss = cb_skipset_init();
        assert!(!ss.is_null());
        assert!(cb_skipset_insert(ss, 42));
        assert!(cb_skipset_contains(ss, 42));
        assert!(cb_skipset_remove(ss, 42));
        assert!(!cb_skipset_contains(ss, 42));
        cb_skipset_destroy(ss);
    }
}

#[test]
fn deque_broadcast_ratelimit_rtrb_ffi_round_trip() {
    use bench_ffi_crossbeam::*;
    unsafe {
        // Deque single + batch steal
        let dq = cb_deque_init(1);
        assert!(!dq.is_null());
        for i in 1..=10u64 {
            cb_deque_push(dq, i);
        }
        let mut stolen = 0u64;
        assert!(cb_deque_steal(dq, &mut stolen));
        assert_eq!(stolen, 1);
        let mut batch_buf = [0u64; 4];
        let n = cb_deque_steal_batch(dq, 0, batch_buf.as_mut_ptr(), 4);
        assert!(n >= 1 && n <= 4);
        for item in &batch_buf[..n] {
            assert!(*item >= 2 && *item <= 10);
        }
        cb_deque_destroy(dq);

        // Tokio broadcast (including lagged -1 return)
        let tb = tokio_bcast_init(16, 1);
        for i in 1..=20u64 {
            assert!(tokio_bcast_send(tb, i));
        }
        let mut val = 0u64;
        let code = tokio_bcast_try_recv(tb, 0, &mut val);
        assert_eq!(code, -1, "expected Lagged (-1) after ring overwrite");
        assert_eq!(tokio_bcast_try_recv(tb, 0, &mut val), 1);
        tokio_bcast_destroy(tb);

        // Bus
        let b = rust_bus_init(16, 1);
        assert!(rust_bus_try_broadcast(b, 77));
        assert!(rust_bus_try_recv(b, 0, &mut val));
        assert_eq!(val, 77);
        rust_bus_destroy(b);

        // Governor GCRA
        let gov = governor_init(1_000_000, 100);
        assert!(governor_check(gov));
        governor_destroy(gov);

        // RTRB stream
        let ring = rtrb_init(1024);
        let payload = [1u8, 2, 3, 4, 5, 6, 7, 8];
        assert_eq!(rtrb_write(ring, payload.as_ptr(), payload.len()), 8);
        let mut read_buf = [0u8; 8];
        assert_eq!(rtrb_read(ring, read_buf.as_mut_ptr(), read_buf.len()), 8);
        assert_eq!(payload, read_buf);
        rtrb_destroy(ring);

        // Workstream B: Rayon pool + crossbeam-epoch SMR
        let rp = rayon_pool_init(2);
        assert!(!rp.is_null());
        let mut out_sum = 0u64;
        assert!(rayon_pool_parfor(rp, 1024, &mut out_sum));
        assert!(out_sum != 0);
        let mut fj_sum = 0u64;
        assert!(rayon_pool_forkjoin(rp, 4, &mut fj_sum));
        assert!(fj_sum != 0);
        rayon_pool_destroy(rp);

        assert_eq!(cbe_pin_unpin_batch(100), 4200);
        assert!(cbe_retire_reclaim_batch(100) > 0);
    }
}


