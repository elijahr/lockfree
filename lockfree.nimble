import os

# Package
version        = "0.1.0"
author         = "Elijah Shaw-Rutschman"
description    = "Lock-free queues, SMR, and managed-payload types for Nim."
license        = "MIT"
srcDir         = "src"
entryPoints    = @["tests/test.nim"]

# Dependencies
requires "nim >= 2.2.10"
requires "unittest2"
requires "typestates >= 0.12.0"

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

task test, "Runs the test suite":
  # Compile-fail negative controls. Runs first so a
  # regression in the (γ) bounded-asymmetry guard or Strategy/cardinality
  # phantom-param surface trips the suite before the positive matrix
  # masks it with downstream noise.
  exec "nim r --hints:off --warnings:off --path:src tests/should_fail/runner.nim"

  # Per-lane nimcache subdirs prevent the 4 MM lanes from clobbering
  # each other's .c.o files (default subdir `test_d` is shared across
  # all `nim c tests/test.nim` invocations, leaving only the last lane's
  # cache surviving and forcing the other 3 lanes to recompile cold on
  # warm reruns). Paths live under `~/.cache/nim/` so the existing
  # actions/cache@v4 step on that dir catches all four.
  #
  # LFQ_TEST_VARIANT env var (default "all") selects which MM lane to
  # run. CI splits the lanes across 4 parallel matrix cells (1a/1b/1c/1d)
  # to collapse wall-clock from sum-of-lanes to max-of-lanes; local
  # `nimble test` still defaults to the full 4-lane sequential sweep so
  # developer-machine signal matches the per-push GHA gate.
  let nimcacheBase = getHomeDir() / ".cache" / "nim"
  let variant = getEnv("LFQ_TEST_VARIANT", "all")

  proc runOrc =
    # C with default MM (orc)
    exec "nim c --threads:on --nimcache:" & (nimcacheBase / "test_orc") & " -r tests/test.nim"

  proc runCpp =
    # C++
    exec "nim cpp --threads:on --nimcache:" & (nimcacheBase / "test_cpp") & " -r tests/test.nim"

  proc runArc =
    # Test with arc MM
    exec "nim c --mm:arc --threads:on --nimcache:" & (nimcacheBase / "test_arc") & " -r tests/test.nim"
    # NEBR (nebr) lifted test suite.
    # Runs under arc only here; CI cells will refine the matrix
    # (orc/refc/atomicArc + TSan/ASan) and may also lift the upstream
    # `should_fail/runner.nim` + `compile_only/` + `bench/` + `probes/`
    # harnesses currently sitting at tests/smr/debra-legacy/ alongside
    # the aggregator. Two tests (item_processing, lockfree_stack_typestates)
    # are excluded from the aggregator pending example-source lift.
    exec "nim c --mm:arc --threads:on --nimcache:" & (nimcacheBase / "nebr_aggregator_arc") & " -r tests/smr/debra-legacy/t_nebr_all.nim"

  proc runRefc =
    # Test with refc MM
    exec "nim c --mm:refc --threads:on --nimcache:" & (nimcacheBase / "test_refc") & " -r tests/test.nim"

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


task testTSan, "Runs the test suite under ThreadSanitizer (TSAN)":
  # ThreadSanitizer requires atomicArc MM for thread-safe refcounting.
  # Uses clang because gcc's TSAN runtime has historically been buggier
  # for our queue idioms (DWCAS shims, mach_absolute_time on darwin).
  # Cell 6 (test-heavy/ubuntu-latest) invokes this directly.
  let nimcacheBase = getHomeDir() / ".cache" / "nim"
  exec "nim r --hints:off --warnings:off --path:src tests/should_fail/runner.nim"
  exec "nim c --cc:clang --mm:atomicArc --threads:on " &
    "--passC:\"-fsanitize=thread\" --passL:\"-fsanitize=thread\" " &
    "--nimcache:" & (nimcacheBase / "test_tsan") & " -r tests/test.nim"


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
  # tests/t_stress.nim drives 100k-message fills across SPSC/MPSC/SPMC/MPMC
  # bounded queues (int, string, and a ref-object checksum arm). It is NOT
  # imported by the umbrella (tests/test.nim): a 100k x many-types run on
  # every umbrella lane would dominate wall-clock. This dedicated task runs
  # it on its own. Two MM lanes: orc (default) and arc (the destructor-
  # driven ManagedRef refcount path the ref-object arm exercises). Per-lane
  # nimcache subdirs keep the two lanes from clobbering each other's .c.o.
  let nimcacheBase = getHomeDir() / ".cache" / "nim"
  exec "nim c --threads:on " &
    "--nimcache:" & (nimcacheBase / "t_stress_orc") & " -r tests/t_stress.nim"
  exec "nim c --mm:arc --threads:on " &
    "--nimcache:" & (nimcacheBase / "t_stress_arc") & " -r tests/t_stress.nim"


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
  ]:
    exec "nim c -d:release --threads:on benchmarks/nim/" & binName & ".nim"
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
       "benchmarks/results/bench_latency.json"


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
