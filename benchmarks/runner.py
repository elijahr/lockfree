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
)


def find_nimble_pkgs() -> tuple[list[str], dict[str, bool]]:
    """Detect available packages in ~/.nimble/pkgs2."""
    home = Path.home()
    pkgs2 = home / ".nimble" / "pkgs2"
    paths: list[str] = []
    available: dict[str, bool] = {}
    if pkgs2.exists():
        for d in pkgs2.iterdir():
            if not d.is_dir():
                continue
            name = d.name.lower()
            if name.startswith("threading-"):
                paths.append(str(d))
                available["threading"] = True
            elif name.startswith("loony-"):
                paths.append(str(d))
                available["loony"] = True
            elif name.startswith("arc-"):
                paths.append(str(d))
                available["arc"] = True
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


def build_nim(quick: bool = False):
    """Build all Nim topology-split benchmark binaries with comparison adapters."""
    # Ensure rust crate is built if possible
    build_rust()

    rust_available = has_rust_lib()
    rust_target = BENCHMARK_DIR / "rust" / "bench-ffi-crossbeam" / "target" / "release"
    nimble_paths, nimble_pkgs = find_nimble_pkgs()

    vendor_dir = BENCHMARK_DIR / "vendor"
    has_atomic_queue = (vendor_dir / "atomic_queue" / "atomic_queue.h").exists()
    has_rigtorp_spsc = (vendor_dir / "rigtorp" / "SPSCQueue.h").exists()
    has_rigtorp_mpmc = (vendor_dir / "rigtorp" / "MPMCQueue.h").exists()
    has_moodycamel = (vendor_dir / "concurrentqueue" / "concurrentqueue.h").exists()

    print("Building Nim topology-split benchmarks with multi-language adapters...")
    print(f"  Adapters: Rust={rust_available}, atomic_queue={has_atomic_queue}, rigtorp={has_rigtorp_mpmc}, moodycamel={has_moodycamel}, loony={nimble_pkgs.get('loony', False)}, threading={nimble_pkgs.get('threading', False)}")

    for bin_name in NIM_BINARIES:
        src = BENCHMARK_DIR / "nim" / f"{bin_name}.nim"
        cmd = ["nim", "cpp", "-d:release", "-d:danger", "--threads:on"]

        for p in nimble_paths:
            cmd.append(f"--path:{p}")

        if rust_available:
            cmd.append(f"--passL:-L{rust_target} -lbench_ffi_crossbeam")

        # Adapter defines per binary
        if bin_name == "bench_spsc":
            if has_atomic_queue:
                cmd.append("-d:adapter_atomic_queue_available")
            if has_rigtorp_spsc:
                cmd.append("-d:adapter_rigtorp_spsc_available")
            if rust_available:
                cmd.append("-d:adapter_kanal_available")
            if quick:
                cmd.extend(["-d:BenchSpscRuns=5", "-d:BenchSpscMessageCount=200000", "-d:BenchSpscWarmup=1"])

        elif bin_name == "bench_mpsc":
            cmd.append("-d:adapter_nim_channel_available")
            if quick:
                cmd.extend(["-d:BenchMpscRuns=5", "-d:BenchMpscMessageCount=200000", "-d:BenchMpscWarmup=1"])

        elif bin_name == "bench_mpmc_bounded":
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
