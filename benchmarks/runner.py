#!/usr/bin/env python3
"""Benchmark runner for lockfree.

Orchestrates multi-language benchmark compilation and execution across
Nim, C++, and Rust.

Topology-split binaries:
- bench_spsc
- bench_mpsc
- bench_mpmc_bounded
- bench_spmc_bounded
- bench_unbounded_spsc
- bench_unbounded_spmc
- bench_unbounded_mpsc
- bench_unbounded_mpmc
- bench_latency

Each binary is compiled with relevant C++ and Rust comparison adapters enabled,
executed independently, and merged into a single Bencher Metric Format (BMF) JSON
document via `merge_bmf.py`.
"""

from __future__ import annotations

import argparse
import json
import shutil
import subprocess
import sys
from datetime import datetime
from pathlib import Path

BENCHMARK_DIR = Path(__file__).resolve().parent
PROJECT_ROOT = BENCHMARK_DIR.parent
RESULTS_DIR = BENCHMARK_DIR / "results"

NIM_BINARIES = (
    "bench_spsc",
    "bench_mpsc",
    "bench_mpmc_bounded",
    "bench_spmc_bounded",
    "bench_unbounded_spsc",
    "bench_unbounded_spmc",
    "bench_unbounded_mpsc",
    "bench_unbounded_mpmc",
    "bench_latency",
    "bench_maps",
    "bench_stacks_deques",
    "bench_broadcast",
    "bench_ratelimit_streaming",
    "bench_rendezvous",
    "bench_taskpool",
    "bench_smr_nebr",
)


def find_nimble_pkgs() -> tuple[list[str], dict[str, bool]]:
    """Detect available packages in ~/.nimble/pkgs2 (latest version per package)."""
    home = Path.home()
    pkgs2 = home / ".nimble" / "pkgs2"
    latest_dirs: dict[str, Path] = {}
    available: dict[str, bool] = {}
    if pkgs2.exists():
        for d in sorted(pkgs2.iterdir()):
            if not d.is_dir():
                continue
            name = d.name.lower()
            for pkg in ("threading", "loony", "arc", "typestates"):
                if name.startswith(f"{pkg}-"):
                    latest_dirs[pkg] = d
                    available[pkg] = True
    paths: list[str] = []
    for pkg, d in latest_dirs.items():
        paths.append(str(d))
        if pkg == "typestates" and (d / "src").is_dir():
            paths.append(str(d / "src"))
    return paths, available


def build_rust() -> bool:
    """Build the Rust bench-ffi-crossbeam crate if cargo is present."""
    rust_dir = BENCHMARK_DIR / "rust" / "bench-ffi-crossbeam"
    if not rust_dir.exists():
        return False
    cargo = shutil.which("cargo")
    if not cargo:
        print("cargo not found; skipping Rust adapter build.")
        return False

    print("Building Rust bench-ffi-crossbeam crate...")
    subprocess.run(["cargo", "build", "--release"], cwd=rust_dir, check=True)
    return True


def has_rust_lib() -> bool:
    """Check if the compiled Rust shared library exists."""
    rust_target = BENCHMARK_DIR / "rust" / "bench-ffi-crossbeam" / "target" / "release"
    for name in ("libbench_ffi_crossbeam.dylib", "libbench_ffi_crossbeam.so", "bench_ffi_crossbeam.dll"):
        if (rust_target / name).exists():
            return True
    return False


def build_liblfds() -> bool:
    """Build the vendored liblfds 7.1.1 static archive if not already built."""
    liblfds_root = BENCHMARK_DIR / "vendor" / "liblfds" / "liblfds711"
    archive = liblfds_root / "bin" / "liblfds711.a"
    if archive.exists():
        return True
    src_dir = liblfds_root / "src"
    if not src_dir.exists():
        return False
    cc = shutil.which("cc") or shutil.which("clang") or shutil.which("gcc")
    ar = shutil.which("ar")
    if not cc or not ar:
        return False
    c_files = sorted(src_dir.glob("*/*.c"))
    if not c_files:
        return False
    obj_dir = liblfds_root / "obj"
    bin_dir = liblfds_root / "bin"
    obj_dir.mkdir(parents=True, exist_ok=True)
    bin_dir.mkdir(parents=True, exist_ok=True)
    print("Building vendored liblfds711.a...")
    objs: list[str] = []
    inc_flag = f"-I{liblfds_root / 'inc'}"
    for src_file in c_files:
        obj_file = obj_dir / f"{src_file.stem}.o"
        subprocess.run(
            [cc, "-O3", "-fPIC", "-D__linux__", inc_flag, "-c", str(src_file), "-o", str(obj_file)],
            check=True,
        )
        objs.append(str(obj_file))
    subprocess.run([ar, "rcs", str(archive)] + objs, check=True)
    return archive.exists()


def has_boost_lockfree() -> bool:
    """Check if Boost.LockFree headers are installed in standard include paths."""
    candidates = (
        Path("/opt/homebrew/opt/boost/include"),
        Path("/usr/local/include"),
        Path("/usr/include"),
    )
    for base in candidates:
        if (base / "boost" / "lockfree" / "queue.hpp").exists():
            return True
    return False


def build_nim(quick: bool = False):
    """Build all Nim topology-split benchmark binaries with comparison adapters."""
    # Ensure rust crate and liblfds archive are built if possible
    build_rust()
    has_liblfds = build_liblfds()

    rust_available = has_rust_lib()
    rust_target = BENCHMARK_DIR / "rust" / "bench-ffi-crossbeam" / "target" / "release"
    liblfds_bin = BENCHMARK_DIR / "vendor" / "liblfds" / "liblfds711" / "bin"
    nimble_paths, nimble_pkgs = find_nimble_pkgs()

    vendor_dir = BENCHMARK_DIR / "vendor"
    has_atomic_queue = (vendor_dir / "atomic_queue" / "include" / "atomic_queue" / "atomic_queue.h").exists()
    has_rigtorp_spsc = (vendor_dir / "rigtorp_spsc" / "include" / "rigtorp" / "SPSCQueue.h").exists()
    has_rigtorp_mpmc = (vendor_dir / "rigtorp_mpmc" / "include" / "rigtorp" / "MPMCQueue.h").exists()
    has_moodycamel = (vendor_dir / "concurrentqueue" / "concurrentqueue.h").exists()
    has_boost = has_boost_lockfree()

    print("Building Nim topology-split benchmarks with multi-language adapters...")
    print(
        f"  Adapters: Rust={rust_available}, Boost={has_boost}, liblfds={has_liblfds}, "
        f"atomic_queue={has_atomic_queue}, rigtorp_spsc={has_rigtorp_spsc}, "
        f"rigtorp_mpmc={has_rigtorp_mpmc}, moodycamel={has_moodycamel}, "
        f"loony={nimble_pkgs.get('loony', False)}, threading={nimble_pkgs.get('threading', False)}"
    )

    for bin_name in NIM_BINARIES:
        src = BENCHMARK_DIR / "nim" / f"{bin_name}.nim"
        if not src.exists():
            continue
        cmd = ["nim", "cpp", "-d:release", "-d:danger", "--threads:on"]

        for p in nimble_paths:
            cmd.append(f"--path:{p}")

        if rust_available:
            cmd.append(f"--passL:-L{rust_target} -lbench_ffi_crossbeam")
            cmd.append("-d:adapter_rust_ffi_available")
        if has_boost:
            cmd.append("-d:adapter_boost_lockfree_available")

        # Adapter defines per binary
        if bin_name == "bench_spsc":
            if has_boost:
                cmd.append("-d:adapter_boost_lockfree_spsc_available")
            if has_atomic_queue:
                cmd.append("-d:adapter_atomic_queue_available")
            if has_rigtorp_spsc:
                cmd.append("-d:adapter_rigtorp_spsc_available")
            if rust_available:
                cmd.append("-d:adapter_kanal_available")
            if has_liblfds:
                cmd.append("-d:adapter_liblfds_available")
                cmd.append(f"--passL:-L{liblfds_bin} -llfds711")
            if quick:
                cmd.extend(["-d:BenchSpscRuns=5", "-d:BenchSpscMessageCount=200000", "-d:BenchSpscWarmup=1"])

        elif bin_name == "bench_mpsc":
            cmd.append("-d:adapter_nim_channel_available")
            if quick:
                cmd.extend(["-d:BenchMpscRuns=5", "-d:BenchMpscMessageCount=200000", "-d:BenchMpscWarmup=1"])

        elif bin_name == "bench_mpmc_bounded":
            if has_boost:
                cmd.append("-d:adapter_boost_lockfree_queue_available")
            if has_atomic_queue:
                cmd.append("-d:adapter_atomic_queue_available")
            if has_rigtorp_mpmc:
                cmd.append("-d:adapter_rigtorp_mpmc_available")
            if rust_available:
                cmd.extend([
                    "-d:adapter_crossbeam_array_queue_available",
                    "-d:adapter_flume_available",
                    "-d:adapter_kanal_available",
                ])
            if has_liblfds:
                cmd.append("-d:adapter_liblfds_available")
                cmd.append(f"--passL:-L{liblfds_bin} -llfds711")
            if nimble_pkgs.get("threading"):
                cmd.append("-d:adapter_threading_channels_available")
            if quick:
                cmd.extend(["-d:BenchMpmcRuns=5", "-d:BenchMpmcMessageCount=200000", "-d:BenchMpmcWarmup=1"])

        elif bin_name == "bench_spmc_bounded":
            if quick:
                cmd.extend(["-d:BenchSpmcRuns=5", "-d:BenchSpmcMessageCount=200000", "-d:BenchSpmcWarmup=1"])

        elif bin_name == "bench_unbounded_spsc":
            if quick:
                cmd.extend(["-d:UnboundedSpscRuns=3", "-d:UnboundedSpscMessageCount=100000", "-d:BenchUnboundedWarmup=1"])

        elif bin_name == "bench_unbounded_spmc":
            if quick:
                cmd.extend(["-d:UnboundedSpmcRuns=3", "-d:UnboundedSpmcMessageCount=100000"])

        elif bin_name == "bench_unbounded_mpsc":
            if quick:
                cmd.extend(["-d:UnboundedMpscRuns=3", "-d:UnboundedMpscMessageCount=100000"])

        elif bin_name == "bench_unbounded_mpmc":
            if has_moodycamel:
                cmd.append("-d:adapter_moodycamel_available")
            if nimble_pkgs.get("loony") and nimble_pkgs.get("arc"):
                cmd.append("-d:adapter_loony_available")
            if rust_available:
                cmd.extend([
                    "-d:adapter_crossbeam_seg_queue_available",
                    "-d:adapter_flume_available",
                    "-d:adapter_kanal_available",
                ])
            if quick:
                cmd.extend(["-d:UnboundedMpmcRuns=2", "-d:UnboundedMpmcMessageCount=50000"])

        elif bin_name == "bench_latency":
            if quick:
                cmd.extend(["-d:BenchLatencyRuns=5", "-d:BenchLatencyIterations=50000"])

        elif bin_name == "bench_maps":
            if quick:
                cmd.extend(["-d:BenchMapRuns=1", "-d:BenchMapWarmup=1", "-d:BenchMapOpsPerThread=10000"])

        elif bin_name == "bench_stacks_deques":
            if quick:
                cmd.extend(["-d:BenchStackRuns=1", "-d:BenchStackWarmup=1", "-d:BenchStackMsgCount=50000"])

        elif bin_name == "bench_broadcast":
            if quick:
                cmd.extend(["-d:BenchBroadcastRuns=1", "-d:BenchBroadcastWarmup=1", "-d:BenchBroadcastMsgCount=20000"])

        elif bin_name == "bench_ratelimit_streaming":
            if quick:
                cmd.extend(["-d:BenchRLRuns=1", "-d:BenchRLWarmup=1", "-d:BenchTokenCount=50000", "-d:BenchStreamBytes=10000000"])

        elif bin_name == "bench_rendezvous":
            if rust_available:
                cmd.append("-d:adapter_crossbeam_array_queue_available")
            if quick:
                cmd.extend(["-d:BenchRendezvousRuns=1", "-d:BenchRendezvousWarmup=1", "-d:BenchRendezvousMsgCount=10000", "-d:BenchRendezvousRpcCount=5000"])

        elif bin_name == "bench_taskpool":
            if rust_available:
                cmd.append("-d:adapter_crossbeam_array_queue_available")
            if quick:
                cmd.extend(["-d:BenchTaskPoolRuns=1", "-d:BenchTaskPoolWarmup=1", "-d:BenchParForCount=50000", "-d:BenchForkJoinDepth=10", "-d:BenchSpawnSyncCount=5000"])

        elif bin_name == "bench_smr_nebr":
            if rust_available:
                cmd.append("-d:adapter_crossbeam_array_queue_available")
            if quick:
                cmd.extend(["-d:BenchSmrRuns=1", "-d:BenchSmrWarmup=1", "-d:BenchPinOpsPerThread=50000", "-d:BenchRetireOpsPerThread=10000"])

        cmd.append(str(src))
        print(f"  -> {bin_name}")
        subprocess.run(cmd, check=True)

    print("All benchmark binaries built.")


def run_nim(runs: int, output_file: Path):
    """Run every Nim topology-split binary and merge their BMF outputs."""
    print(f"Running Nim topology-split benchmarks ({runs} runs)...")
    fragments: list[Path] = []
    try:
        for bin_name in NIM_BINARIES:
            bin_path = PROJECT_ROOT / ".tmp" / bin_name
            if not bin_path.exists():
                continue
            out = output_file.parent / f"{output_file.stem}-{bin_name}.json"
            print(f"  -> {bin_name} -> {out.name}")
            subprocess.run(
                [str(bin_path), f"--bmf-out={out}"],
                check=True,
            )
            fragments.append(out)

        print(f"Merging {len(fragments)} fragments -> {output_file}")
        subprocess.run(
            [
                sys.executable,
                str(BENCHMARK_DIR / "merge_bmf.py"),
                str(output_file),
                *[str(p) for p in fragments],
            ],
            check=True,
        )
        print(f"Combined results written to {output_file}")
    finally:
        for f in fragments:
            f.unlink(missing_ok=True)


def build(args):
    """Build benchmark binaries."""
    build_nim(quick=getattr(args, "quick", False))


def run(args):
    """Run benchmarks."""
    RESULTS_DIR.mkdir(exist_ok=True)
    timestamp = datetime.now().strftime("%Y%m%d-%H%M%S")
    output_file = RESULTS_DIR / f"nim-{timestamp}.json"

    # Always ensure binaries are built if missing
    first_bin = PROJECT_ROOT / ".tmp" / NIM_BINARIES[0]
    if not first_bin.exists():
        build_nim(quick=getattr(args, "quick", False))

    run_nim(args.runs, output_file)

    if args.output:
        dest = Path(args.output)
        dest.parent.mkdir(parents=True, exist_ok=True)
        with open(output_file, "r", encoding="utf-8") as f:
            data = json.load(f)
        with open(dest, "w", encoding="utf-8") as f:
            json.dump(data, f, indent=2)
        print(f"Combined results written to {dest}")


def main():
    parser = argparse.ArgumentParser(description="Benchmark runner for lockfree")
    subparsers = parser.add_subparsers(dest="command", required=True)

    build_parser = subparsers.add_parser("build", help="Build benchmark binaries")
    build_parser.add_argument("--language", default="all", choices=["nim", "cpp", "rust", "all"])
    build_parser.add_argument("--quick", action="store_true", help="Compile with smaller test sizes for rapid validation")

    run_parser = subparsers.add_parser("run", help="Run benchmarks")
    run_parser.add_argument("--language", default="all", choices=["nim", "cpp", "rust", "all"])
    run_parser.add_argument("--runs", type=int, default=33, help="Number of benchmark runs")
    run_parser.add_argument("--quick", action="store_true", help="Run with quick test parameters")
    run_parser.add_argument("--output", "-o", help="Output file for combined results")

    args = parser.parse_args()

    if args.command == "build":
        build(args)
    elif args.command == "run":
        run(args)


if __name__ == "__main__":
    main()
