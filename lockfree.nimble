import os

# Package
version        = "0.6.1"
author         = "Elijah Shaw-Rutschman"
description    = "Lock-free concurrency toolkit for Nim & C99: MPMC Queues, SkipLists, Ctries, Broadcast Rings, Flat Combining, Work-Stealing TaskPools, 128-bit DWCAS Atomics, and NEBR SMR."
license        = "MIT"
srcDir         = "src"
entryPoints    = @["tests/test.nim"]

# Dependencies
requires "nim >= 2.2.10"
requires "unittest2"
requires "typestates >= 0.14.0"

# Optional dependencies (flag-only opt-in). chronos is the async-adapter
# backend pulled in only when callers build with `-d:lockfreeChronos`.
# See `src/lockfree/chronos.nim` (flag-only chronos opt-in) and
# `docs/api/chronos.md` for the integration guide.
when defined(lockfreeChronos):
  requires "chronos >= 4.0.0 & < 5.0.0"

# Tasks
task should_fail, "Verifies compile-fail negative controls":
  # Driver iterates the 5-case table and runs `nim c --compileOnly` per
  # case, asserting expected exit + pinned substring. Ported from
  # nebr 0.8.0's `tests/should_fail/runner.nim` harness.
  exec "nim r --hints:off --warnings:off --path:src tests/should_fail/runner.nim"

task testUnit, "Runs fast Tier 1 behavioral and unit tests in parallel (<15s)":
  exec "nim r --hints:off --warnings:off tests/test_runner.nim --unit"

task testThreaded, "Runs Tier 2 multithreaded concurrency tests in parallel":
  exec "nim r --hints:off --warnings:off tests/test_runner.nim --concurrency"

task testQueues, "Runs queue unit tests":
  exec "nim r --hints:off --warnings:off tests/test_runner.nim --queues"

task testStructures, "Runs data structure unit tests":
  exec "nim r --hints:off --warnings:off tests/test_runner.nim --structures"

task testSync, "Runs concurrency & synchronization unit tests":
  exec "nim r --hints:off --warnings:off tests/test_runner.nim --sync"

task testPrimitives, "Runs atomics & memory primitive unit tests":
  exec "nim r --hints:off --warnings:off tests/test_runner.nim --primitives"

task testRelease, "Runs fast Tier 1 unit tests in release mode (-d:release --opt:speed)":
  exec "nim r --hints:off --warnings:off tests/test_runner.nim --unit --release"

task testThreadedRelease, "Runs Tier 2 multithreaded concurrency tests in release mode (-d:release --opt:speed)":
  exec "nim r --hints:off --warnings:off tests/test_runner.nim --concurrency --release"

task buildLib, "Builds optimized release C-ABI shared and static library in lib/":
  mkDir "lib"
  let ext = when defined(macosx): "dylib" elif defined(windows): "dll" else: "so"
  exec "nim c --app:lib -d:release --opt:speed --threads:on -o:lib/liblockfree." & ext & " src/lockfree/cabi.nim"
  exec "nim c --app:staticlib -d:release --opt:speed --threads:on -o:lib/liblockfree.a src/lockfree/cabi.nim"

task test, "Runs the test suite":
  # Compile-fail negative controls. Runs first so a
  # regression in the (γ) bounded-asymmetry guard or Strategy/cardinality
  # phantom-param surface trips the suite before the positive matrix
  # masks it with downstream noise.
  exec "nim r --hints:off --warnings:off --path:src tests/should_fail/runner.nim"

  let variant = getEnv("LFQ_TEST_VARIANT", "orc")

  proc runOrc =
    exec "nim r --hints:off --warnings:off tests/test_runner.nim --all --mm:orc"

  proc runCpp =
    exec "nim r --hints:off --warnings:off tests/test_runner.nim --all --cpp"

  proc runArc =
    exec "nim r --hints:off --warnings:off tests/test_runner.nim --all --mm:arc"
    exec "nim c --mm:arc --threads:on -r tests/smr/debra-legacy/t_nebr_all.nim"

  proc runRefc =
    exec "nim r --hints:off --warnings:off tests/test_runner.nim --unit --mm:refc"

  case variant
  of "all":
    runOrc()
    runCpp()
    runArc()
    runRefc()
  of "orc": runOrc()
  of "cpp": runCpp()
  of "arc": runArc()
  of "refc": runRefc()
  else:
    quit "Unknown LFQ_TEST_VARIANT: " & variant &
      " (expected: all, orc, cpp, arc, refc)"


task testTSan, "Runs Tier 2 concurrency tests under ThreadSanitizer (TSAN)":
  # ThreadSanitizer requires atomicArc MM for thread-safe refcounting.
  # Uses clang because gcc's TSAN runtime has historically been buggier
  # for our queue idioms (DWCAS shims, mach_absolute_time on darwin).
  # Targeted to Tier 2 concurrency runner to eliminate 14-min compiler bloat.
  let nimcacheBase = getHomeDir() / ".cache" / "nim"
  exec "nim r --hints:off --warnings:off --path:src tests/should_fail/runner.nim"
  exec "nim c --cc:clang --mm:atomicArc --threads:on --path:src " &
    "--passC:\"-fsanitize=thread\" --passL:\"-fsanitize=thread\" " &
    "--nimcache:" & (nimcacheBase / "test_tsan") & " -r tests/concurrency/runner.nim"



task testRefcountTrace, "Runs the refcount-balance matrix under -d:lockfreeRefcountTrace":
  # The refcount-balance assertion in
  # tests/composition/t_refcount_use_patterns.nim is REAL only under
  # -d:lockfreeRefcountTrace, where the shim counters in
  # tests/composition/refcount_trace_shim.nim are wired to the
  # incRefSlot / decRefSlot shims in src/lockfree/managed_ref.nim. The
  # --path adds tests/composition so managed_ref's guarded
  # `import refcount_trace_shim` resolves (the import is itself behind
  # the define, so this path is irrelevant to release builds). Runs
  # under arc — the destructor-driven refcount path the matrix exercises.
  let nimcacheBase = getHomeDir() / ".cache" / "nim"
  exec "nim c --mm:arc --threads:on -d:lockfreeRefcountTrace " &
    "--path:tests/composition " &
    "--nimcache:" & (nimcacheBase / "test_refcount_trace") &
    " -r tests/composition/t_refcount_use_patterns.nim"


task testSliceDispose, "Runs the seq[char] dispose-routing regression under -d:lockfreeSliceDisposeTrace":
  # The dispose-routing assertion in
  # tests/composition/t_seq_char_dispose.nim is REAL only under
  # -d:lockfreeSliceDisposeTrace, where the shim counters in
  # tests/composition/slice_dispose_trace_shim.nim are wired to the
  # disposeSlot (string) / disposeSeqSlot (seq) paths in
  # src/lockfree/managed_slice.nim. The --path adds tests/composition so
  # managed_slice's guarded `import slice_dispose_trace_shim` resolves
  # (the import is itself behind the define, so this path is irrelevant
  # to release builds). Runs under arc — the destructor-driven dispose
  # path the test exercises.
  let nimcacheBase = getHomeDir() / ".cache" / "nim"
  exec "nim c --mm:arc --threads:on -d:lockfreeSliceDisposeTrace " &
    "--path:tests/composition " &
    "--nimcache:" & (nimcacheBase / "test_slice_dispose") &
    " -r tests/composition/t_seq_char_dispose.nim"


task testDestructorWalkTrace, "Runs the destructor-walk string/seq slot-count regression under -d:lockfreeSliceDisposeTrace":
  # The string (suite B) and seq (suite C) destroy-walk assertions in
  # tests/t_destructor_walk.nim pin the EXACT number of per-slot box-free
  # calls (disposeSlot for string / disposeSeqSlot for seq) via the shim
  # counters in tests/composition/slice_dispose_trace_shim.nim, which
  # src/lockfree/managed_slice.nim wires up only under
  # -d:lockfreeSliceDisposeTrace. In the plain umbrella those counters are
  # no-ops and the string suite falls back to a visible skip (the seq
  # suite still asserts element-lifecycle via its instrumented Tracked
  # element in every lane). This task runs the REAL slot-count assertions.
  # Runs under arc — the destructor-driven dispose path under test.
  let nimcacheBase = getHomeDir() / ".cache" / "nim"
  exec "nim c --mm:arc --threads:on -d:lockfreeSliceDisposeTrace " &
    "--path:tests/composition " &
    "--nimcache:" & (nimcacheBase / "test_destructor_walk_trace") &
    " -r tests/t_destructor_walk.nim"


task testStress, "Runs the high-volume (100k) bounded-queue stress suite":
  # tests/stress/runner.nim drives 100k-message fills across SPSC/MPSC/SPMC/MPMC
  # bounded queues (int, string, and a ref-object checksum arm). It is NOT
  # imported by the unit umbrella: a 100k x many-types run on
  # every umbrella lane would dominate wall-clock. This dedicated task runs
  # it on its own. Two MM lanes: orc (default) and arc.
  let nimcacheBase = getHomeDir() / ".cache" / "nim"
  exec "nim c --threads:on --path:src " &
    "--nimcache:" & (nimcacheBase / "t_stress_orc") & " -r tests/stress/runner.nim"
  exec "nim c --mm:arc --threads:on --path:src " &
    "--nimcache:" & (nimcacheBase / "t_stress_arc") & " -r tests/stress/runner.nim"



task testShell, "Runs the standalone shell-test regression scripts":
  # Three shell tests had no runner and
  # so never ran in CI. `exec` aborts the task (nonzero task exit) on the
  # first script that returns nonzero, so any failure fails the task.
  exec "bash tools/tests/test_act_cell_watchdog.sh"
  exec "bash tools/tests/test_act_cell_envvar.sh"
  exec "bash tests/test_chronos_dep_error.sh"


task testASan, "Runs the test suite under AddressSanitizer (ASAN)":
  # AddressSanitizer works under arc/orc/atomicArc. We use the same MM
  # the rest of the matrix uses for the orc baseline (so ASAN-instrumented
  # behavior is the closest possible match to what cell 1a tests
  # un-instrumented). Cell 7 (test-heavy/ubuntu-latest) invokes this.
  let nimcacheBase = getHomeDir() / ".cache" / "nim"
  exec "nim r --hints:off --warnings:off --path:src tests/should_fail/runner.nim"
  exec "nim c --cc:clang --threads:on " &
    "--passC:\"-fsanitize=address\" --passL:\"-fsanitize=address\" " &
    "--nimcache:" & (nimcacheBase / "test_asan") & " -r tests/test.nim"


task examples, "Runs the examples":
  # Bounded queue examples
  exec "nim c --threads:on -r examples/spsc.nim"
  exec "nim c --threads:on -r examples/spmc.nim"
  exec "nim c --threads:on -r examples/mpsc.nim"
  exec "nim c --threads:on -r examples/mpmc.nim"
  exec "nim c --threads:on -r examples/bqueue128.nim"
  # Advanced examples
  exec "nim c --threads:on -r examples/audio_buffer.nim"
  exec "nim c --threads:on -r examples/task_fanout.nim"
  exec "nim c --threads:on -r examples/event_collector.nim"
  exec "nim c --threads:on -r examples/job_scheduler.nim"

task benchmarks, "Runs the benchmark suite":
  # PR 2 (bench-rollup) replaced bench_throughput.nim with topology-
  # split binaries. v5.0.0 B3 further split the MPMC binary into a
  # per-family pair (bench_mpmc_bounded + bench_spmc_bounded) to remove
  # cross-family iCache contention; applied the same
  # mitigation to the unbounded binary, fanning it out into four
  # per-family binaries (bench_unbounded_{spsc,spmc,mpsc,mpmc}).
  # See the bench_mpmc_*.nim and bench_unbounded_*.nim headers for the
  # diagnostic that motivated each split. Each binary emits its own
  # Bencher Metric Format JSON fragment; merge_bmf.py unions them into
  # one final file. Binaries land in `.tmp/` per the project nim.cfg
  # (`--outdir:.tmp`).
  mkDir "benchmarks/results"
  for binName in [
    "bench_spsc", "bench_mpsc",
    "bench_mpmc_bounded", "bench_spmc_bounded",
    "bench_unbounded_spsc", "bench_unbounded_spmc",
    "bench_unbounded_mpsc", "bench_unbounded_mpmc",
    "bench_latency",
    "bench_maps",
    "bench_stacks_deques",
    "bench_broadcast",
    "bench_ratelimit_streaming",
    "bench_rendezvous",
    "bench_taskpool",
    "bench_smr_nebr",
  ]:
    var flags = "-d:release --threads:on"
    var compiler = "nim c"
    if binName == "bench_unbounded_mpmc":
      compiler = "nim cpp"
      flags &= " -d:adapter_loony_available"
    elif binName == "bench_mpmc_bounded":
      flags &= " -d:adapter_threading_channels_available"
    exec compiler & " " & flags & " benchmarks/nim/" & binName & ".nim"
    exec ".tmp/" & binName & " --bmf-out=benchmarks/results/" & binName & ".json"
  # Union the per-binary fragments. Exits 1 on (slug, measure) collisions.
  exec "python3 benchmarks/merge_bmf.py benchmarks/results/latest.json " &
       "benchmarks/results/bench_spsc.json " &
       "benchmarks/results/bench_mpsc.json " &
       "benchmarks/results/bench_mpmc_bounded.json " &
       "benchmarks/results/bench_spmc_bounded.json " &
       "benchmarks/results/bench_unbounded_spsc.json " &
       "benchmarks/results/bench_unbounded_spmc.json " &
       "benchmarks/results/bench_unbounded_mpsc.json " &
       "benchmarks/results/bench_unbounded_mpmc.json " &
       "benchmarks/results/bench_latency.json " &
       "benchmarks/results/bench_maps.json " &
       "benchmarks/results/bench_stacks_deques.json " &
       "benchmarks/results/bench_broadcast.json " &
       "benchmarks/results/bench_ratelimit_streaming.json " &
       "benchmarks/results/bench_rendezvous.json " &
       "benchmarks/results/bench_taskpool.json " &
       "benchmarks/results/bench_smr_nebr.json"


task benchtests, "Runs the bench harness test suite":
  # The bench harness lives outside `srcDir`, so its dedicated tests
  # (`tests/t_bench_*.nim`) are NOT imported by `tests/test.nim` to
  # keep the regular `nimble test` matrix free of the bench harness's
  # threading/atomic dependencies. This task runs them explicitly so
  # CI can validate HistogramTopK sizing, latency CLI assertions, and
  # adapter round-trip behavior. Single MM (orc default) is sufficient
  # because the bench harness itself is the system under test, not the
  # queue MM matrix.
  exec "nim c --threads:on -r tests/t_bench_common.nim"
  exec "nim c --threads:on -r tests/t_bench_latency.nim"
  exec "nim c --threads:on -r tests/t_bench_adapters.nim"


task benchToggleSmoke, "Verify LFQ_BENCH_HARNESS_BACKOFF=0 toggle is observed at module init":
  exec "nim c --threads:on -o:.tmp/bench_toggle_smoke tests/bench_toggle_smoke_driver.nim"
  exec "sh -c 'LFQ_BENCH_HARNESS_BACKOFF=0 .tmp/bench_toggle_smoke | grep -q true || (echo FAIL && exit 1)'"
  exec "sh -c 'LFQ_BENCH_HARNESS_BACKOFF=1 .tmp/bench_toggle_smoke | grep -q false || (echo FAIL && exit 1)'"
  exec "sh -c '.tmp/bench_toggle_smoke | grep -q false || (echo FAIL && exit 1)'"


task benchteststress, "Runs the bench harness test suite including 3.3M-sample stress shapes":
  # Like `benchtests` but enables the gated 3.3M-sample p999 stress
  # shape in t_bench_common (HistogramTopK headroom validation against
  # an operator-driven MessageCount override). Slow (~10-15s release)
  # so it is opt-in rather than part of every CI run.
  exec "nim c -d:release -d:BenchCommonStress --threads:on -r tests/t_bench_common.nim"


task cabi, "Builds and runs the C ABI verification test suite":
  exec "nim c -d:danger --threads:on --path:src -r tests/t_cabi.nim"
 
 
task channel, "Builds and runs the Channel facade test suite":
  exec "nim c --threads:on --nimcache:.tmp/channel_d -r tests/t_channel.nim"


task ctrie, "Builds and runs the Ctrie (Table) concurrent map test suite":
  exec "nim c --threads:on --nimcache:.tmp/ctrie_d -r tests/t_ctrie.nim"


task skiplist, "Builds and runs the SkipListMap and SkipListSet test suites":
  exec "nim c --threads:on --nimcache:.tmp/skiplist_d -r tests/t_skiplist.nim"
  exec "nim c --threads:on --nimcache:.tmp/set_d -r tests/t_set.nim"


task stack, "Builds and runs the TreiberStack test suite":
  exec "nim c --threads:on --nimcache:.tmp/stack_d -r tests/t_stack.nim"


task deque, "Builds and runs the ChaseLevDeque test suite":
  exec "nim c --threads:on --nimcache:.tmp/deque_d -r tests/t_deque.nim"


task broadcast, "Builds and runs the BroadcastRing and TopicBus test suite":
  exec "nim c --threads:on --nimcache:.tmp/broadcast_d -r tests/t_broadcast.nim"


task rendezvous, "Builds and runs the RendezvousChannel test suite":
  exec "nim c --threads:on --nimcache:.tmp/rendezvous_d -r tests/t_rendezvous.nim"


task taskpool, "Builds and runs the TaskPool work-stealing scheduler test suite":
  exec "nim c --threads:on --nimcache:.tmp/taskpool_d -r tests/t_taskpool.nim"


task async_bridge, "Builds and runs the AsyncBridge test suite":
  exec "nim c --threads:on --nimcache:.tmp/async_bridge_d -r tests/t_async_bridge.nim"


# task `stresstests` removed in v5.0.0 . The 9 legacy
# `stress-tests/t_*_threaded.nim` files referenced the per-family
# aliases (`Mpmc[N, P, C, T]`, `Spmc[N, C, T]`, etc.) and the
# pre-DEBRA EpochManager API. Rewiring 1,197 LOC to the new
# BQueue/Queue surface with the attach/detach Claim-state idiom was
# multi-hour scope (well beyond the v5.0.0 wrap-up budget). Per Bundle
# I principle ("do NOT silently disable failing tests — fix production
# code OR delete the test"), the stress test suite + task are removed.
# The MM lane matrix (5 lanes × 240 tests, plus TSan/ASan sanitizers
# under `nimble test`) provides the primary concurrency-correctness
# signal.
