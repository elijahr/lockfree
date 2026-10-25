#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"

mkdir -p .tmp

# Adapter flag resolution
mode="c"
flags=""

if [ "${FORCE_SKIP_LOONY:-}" != "1" ]; then
  flags="$flags -d:adapter_loony_available"
fi
if [ "${FORCE_SKIP_MOODYCAMEL:-}" != "1" ]; then
  flags="$flags -d:adapter_moodycamel_available"
  mode="cpp"
fi
if [ "${FORCE_SKIP_THREADING_CHANNELS:-}" != "1" ]; then
  flags="$flags -d:adapter_threading_channels_available"
fi
if [ "${FORCE_SKIP_NIM_CHANNEL:-}" != "1" ]; then
  flags="$flags -d:adapter_nim_channel_available"
fi

if [ -f "benchmarks/vendor/atomic_queue/include/atomic_queue/atomic_queue.h" ]; then
  flags="$flags -d:adapter_atomic_queue_available"
  mode="cpp"
fi

if [ -f "benchmarks/vendor/rigtorp_spsc/include/rigtorp/SPSCQueue.h" ]; then
  flags="$flags -d:adapter_rigtorp_spsc_available"
  mode="cpp"
fi

if [ -f "benchmarks/vendor/rigtorp_mpmc/include/rigtorp/MPMCQueue.h" ]; then
  flags="$flags -d:adapter_rigtorp_mpmc_available"
  mode="cpp"
fi

LIBLFDS_LIB_DIR="$REPO_ROOT/benchmarks/vendor/liblfds/liblfds711/bin"
if [ -f "$LIBLFDS_LIB_DIR/liblfds711.a" ]; then
  flags="$flags -d:adapter_liblfds_available --passL:-L${LIBLFDS_LIB_DIR} --passL:-llfds711"
fi

RUST_FFI_LIB_DIR="$REPO_ROOT/benchmarks/rust/bench-ffi-crossbeam/target/release"
if [ -f "$RUST_FFI_LIB_DIR/libbench_ffi_crossbeam.dylib" ] || [ -f "$RUST_FFI_LIB_DIR/libbench_ffi_crossbeam.so" ]; then
  flags="$flags -d:adapter_rust_ffi_available -d:adapter_crossbeam_array_queue_available -d:adapter_crossbeam_seg_queue_available -d:adapter_flume_available -d:adapter_kanal_available --passL:-Wl,-rpath,${RUST_FFI_LIB_DIR}"
fi

if [ "${FORCE_SKIP_BOOST:-}" != "1" ]; then
  flags="$flags -d:adapter_boost_lockfree_queue_available -d:adapter_boost_lockfree_spsc_available -d:adapter_boost_lockfree_available"
  mode="cpp"
fi

echo "=== Adapter flags: $flags ==="
echo "=== Nim mode:      $mode ==="

BINARIES=(
  bench_spsc
  bench_mpsc
  bench_mpmc_bounded
  bench_spmc_bounded
  bench_unbounded_spsc
  bench_unbounded_spmc
  bench_unbounded_mpsc
  bench_unbounded_mpmc
  bench_latency
  bench_maps
  bench_stacks_deques
  bench_broadcast
  bench_ratelimit_streaming
  bench_rendezvous
  bench_taskpool
  bench_smr_nebr
  bench_disjoint_set
)

for bin in "${BINARIES[@]}"; do
  echo ""
  echo "================================================================="
  echo " Compiling and running: $bin"
  echo "================================================================="

  compile_cmd=()
  case "$bin" in
    bench_spsc)
      compile_cmd=(nim "$mode" -d:release -d:danger --threads:on \
        -d:BenchSpscMessageCount=1000000 -d:BenchSpscRuns=5 -d:BenchSpscWarmup=2 \
        $flags -o:".tmp/$bin" "benchmarks/nim/$bin.nim")
      ;;
    bench_mpsc)
      compile_cmd=(nim c -d:release -d:danger --threads:on \
        -d:BenchMpscMessageCount=1000000 -d:BenchMpscRuns=5 -d:BenchMpscWarmup=2 \
        $flags -o:".tmp/$bin" "benchmarks/nim/$bin.nim")
      ;;
    bench_mpmc_bounded)
      compile_cmd=(nim "$mode" -d:release -d:danger --threads:on \
        -d:BenchMpmcMessageCount=1000000 -d:BenchMpmcRuns=5 -d:BenchMpmcWarmup=2 \
        $flags -o:".tmp/$bin" "benchmarks/nim/$bin.nim")
      ;;
    bench_spmc_bounded)
      compile_cmd=(nim c -d:release -d:danger --threads:on \
        -d:BenchMpmcMessageCount=1000000 -d:BenchMpmcRuns=5 -d:BenchMpmcWarmup=2 \
        -o:".tmp/$bin" "benchmarks/nim/$bin.nim")
      ;;
    bench_unbounded_spsc)
      compile_cmd=(nim c -d:release -d:danger --threads:on \
        -d:UnboundedSpscMessageCount=200000 -d:UnboundedSpscRuns=3 -d:BenchUnboundedWarmup=1 \
        -d:benchProgress -o:".tmp/$bin" "benchmarks/nim/$bin.nim")
      ;;
    bench_unbounded_spmc)
      compile_cmd=(nim c -d:release -d:danger --threads:on \
        -d:UnboundedSpmcMessageCount=100000 -d:UnboundedSpmcRuns=2 -d:BenchUnboundedWarmup=1 \
        -d:BenchSkipOversubscribed -d:benchProgress -o:".tmp/$bin" "benchmarks/nim/$bin.nim")
      ;;
    bench_unbounded_mpsc)
      compile_cmd=(nim c -d:release -d:danger --threads:on \
        -d:UnboundedMpscMessageCount=100000 -d:UnboundedMpscRuns=2 -d:BenchUnboundedWarmup=1 \
        -d:benchProgress -o:".tmp/$bin" "benchmarks/nim/$bin.nim")
      ;;
    bench_unbounded_mpmc)
      compile_cmd=(nim "$mode" -d:release -d:danger --threads:on \
        -d:UnboundedMpmcMessageCount=50000 -d:UnboundedMpmcRuns=2 -d:BenchUnboundedWarmup=1 \
        -d:BenchSkipOversubscribed -d:benchProgress $flags -o:".tmp/$bin" "benchmarks/nim/$bin.nim")
      ;;
    bench_latency)
      compile_cmd=(nim c -d:release -d:danger --threads:on \
        -d:BenchLatencyMessageCount=50000 -d:BenchLatencyRuns=11 -d:BenchLatencyWarmupRuns=2 \
        -o:".tmp/$bin" "benchmarks/nim/$bin.nim")
      ;;
    bench_maps)
      compile_cmd=(nim cpp -d:release -d:danger --threads:on \
        -d:BenchMapRuns=3 -d:BenchMapWarmup=1 -d:BenchMapOpsPerThread=20000 \
        $flags -o:".tmp/$bin" "benchmarks/nim/$bin.nim")
      ;;
    bench_stacks_deques)
      compile_cmd=(nim cpp -d:release -d:danger --threads:on \
        -d:BenchStackRuns=3 -d:BenchStackWarmup=1 -d:BenchStackMsgCount=100000 \
        $flags -o:".tmp/$bin" "benchmarks/nim/$bin.nim")
      ;;
    bench_broadcast)
      compile_cmd=(nim cpp -d:release -d:danger --threads:on \
        -d:BenchBroadcastRuns=3 -d:BenchBroadcastWarmup=1 -d:BenchBroadcastMsgCount=50000 \
        $flags -o:".tmp/$bin" "benchmarks/nim/$bin.nim")
      ;;
    bench_ratelimit_streaming)
      compile_cmd=(nim cpp -d:release -d:danger --threads:on \
        -d:BenchRLRuns=3 -d:BenchRLWarmup=1 -d:BenchTokenCount=100000 -d:BenchStreamBytes=16777216 \
        $flags -o:".tmp/$bin" "benchmarks/nim/$bin.nim")
      ;;
    bench_rendezvous)
      compile_cmd=(nim cpp -d:release -d:danger --threads:on \
        -d:BenchRendezvousRuns=3 -d:BenchRendezvousWarmup=1 -d:BenchRendezvousMsgCount=20000 -d:BenchRendezvousRpcCount=10000 \
        $flags -o:".tmp/$bin" "benchmarks/nim/$bin.nim")
      ;;
    bench_taskpool)
      compile_cmd=(nim cpp -d:release -d:danger --threads:on \
        -d:BenchTaskPoolRuns=3 -d:BenchTaskPoolWarmup=1 -d:BenchParForCount=50000 -d:BenchForkJoinDepth=11 -d:BenchSpawnSyncCount=10000 \
        $flags -o:".tmp/$bin" "benchmarks/nim/$bin.nim")
      ;;
    bench_smr_nebr)
      compile_cmd=(nim cpp -d:release -d:danger --threads:on \
        -d:BenchSmrRuns=3 -d:BenchSmrWarmup=1 -d:BenchPinOpsPerThread=50000 -d:BenchRetireOpsPerThread=10000 \
        $flags -o:".tmp/$bin" "benchmarks/nim/$bin.nim")
      ;;
    bench_disjoint_set)
      compile_cmd=(nim cpp -d:release -d:danger --threads:on \
        -d:BenchDSRuns=3 -d:BenchDSWarmup=1 -d:BenchDSOpsCount=100000 \
        $flags -o:".tmp/$bin" "benchmarks/nim/$bin.nim")
      ;;
  esac

  echo "Compiling $bin..."
  "${compile_cmd[@]}"

  echo "Running $bin..."
  if ! ./.tmp/"$bin" --bmf-out=".tmp/$bin.json" | tee ".tmp/${bin}_output.txt"; then
    echo "::warning::$bin failed or flaked; continuing sequential run"
  fi
done

echo ""
echo "=== Sequential benchmark execution complete ==="
