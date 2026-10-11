"""Unit tests for generate_readme_benchmarks.py."""

import json
import os
import sys
import tempfile
import unittest
import xml.etree.ElementTree as ET

# Ensure benchmarks/scripts is on sys.path
SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
REPO_ROOT = os.path.dirname(os.path.dirname(SCRIPT_DIR))
SCRIPTS_DIR = os.path.join(REPO_ROOT, "benchmarks", "scripts")
if SCRIPTS_DIR not in sys.path:
    sys.path.insert(0, SCRIPTS_DIR)

import generate_readme_benchmarks as gen  # noqa: E402


class TestGenerateReadmeBenchmarks(unittest.TestCase):
    def setUp(self):
        # Minimal mock BMF data
        self.mock_bmf = {
            "lockfreequeues_mpmc/mpmc/4p4c": {
                "throughput_ops_ms": {"value": 16188.0, "lower_value": 15900.0, "upper_value": 16400.0}
            },
            "nim_channels/mpmc/4p4c": {
                "throughput_ops_ms": {"value": 1802.0}
            },
            "crossbeam_array_queue/mpmc/4p4c": {
                "throughput_ops_ms": {"value": 14200.0}
            },
            "lockfreequeues_spmc/mpmc/1p2c": {
                "throughput_ops_ms": {"value": 14123.0}
            },
            "lockfreequeues_mpsc/mpsc/4p1c": {
                "throughput_ops_ms": {"value": 8719.0}
            },
            "nim_channels/mpsc/4p1c": {
                "throughput_ops_ms": {"value": 4788.0}
            },
            "lockfreequeues_unbounded_spsc/spsc_unbounded/1p1c": {
                "throughput_ops_ms": {"value": 29399.0}
            },
            "lockfreequeues_spsc/spsc/1p1c": {
                "throughput_ops_ms": {"value": 7600.0},
                "latency_p50_ns": {"value": 260.0},
                "latency_p95_ns": {"value": 300.0},
                "latency_p99_ns": {"value": 326.0},
                "latency_p999_ns": {"value": 410.0},
            }
        }

    def test_generate_hero_svg_validity(self):
        items = [
            {"name": "lockfree (BQueue)", "value": 16188.0, "is_lfq": True, "speedup": 9.0},
            {"name": "crossbeam", "value": 14200.0, "is_lfq": False},
            {"name": "nim_channels", "value": 1802.0, "is_lfq": False, "is_blocking": True},
        ]
        svg = gen.generate_hero_svg(items)
        self.assertIn("<svg", svg)
        self.assertIn("</svg>", svg)
        self.assertIn("@media (prefers-color-scheme: dark)", svg)
        self.assertIn("lockfree", svg)
        self.assertIn("16,188.0 ops/ms", svg)
        # Verify it parses as valid XML
        tree = ET.fromstring(svg)
        self.assertEqual(tree.tag, "{http://www.w3.org/2000/svg}svg" if "}" in tree.tag else "svg")

    def test_generate_latency_svg_validity(self):
        metrics = {"p50": 260.0, "p95": 300.0, "p99": 326.0, "p999": 410.0}
        svg = gen.generate_latency_svg(metrics)
        self.assertIn("<svg", svg)
        self.assertIn("</svg>", svg)
        self.assertIn("p50", svg)
        self.assertIn("260", svg)
        self.assertIn("ns</tspan>", svg)
        # Verify it parses as valid XML
        tree = ET.fromstring(svg)
        self.assertEqual(tree.tag, "{http://www.w3.org/2000/svg}svg" if "}" in tree.tag else "svg")

    def test_generate_readme_section(self):
        section = gen.build_markdown_section(
            self.mock_bmf,
            "docs/assets/bench-results/hero-throughput.svg",
            "docs/assets/bench-results/latency-ladder.svg",
        )
        self.assertIn("<!-- BENCHMARK_METRICS_START -->", section)
        self.assertIn("<!-- BENCHMARK_METRICS_END -->", section)
        self.assertIn("| Topology | Engine | Shape |", section)
        self.assertIn("16,188 ops/ms", section)
        self.assertIn("9.0x faster", section)
        self.assertIn("1.8x faster", section)

    def test_update_readme_in_place(self):
        original = (
            "# Intro\n\n"
            "<!-- BENCHMARK_METRICS_START -->\n"
            "old table\n"
            "<!-- BENCHMARK_METRICS_END -->\n\n"
            "# Outro\n"
        )
        with tempfile.NamedTemporaryFile("w+", delete=False) as f:
            f.write(original)
            f.flush()
            temp_path = f.name

        try:
            new_section = "<!-- BENCHMARK_METRICS_START -->\nnew table\n<!-- BENCHMARK_METRICS_END -->"
            ok = gen.update_readme(temp_path, new_section)
            self.assertTrue(ok)
            with open(temp_path, "r") as f:
                content = f.read()
            self.assertIn("new table", content)
            self.assertNotIn("old table", content)
            self.assertTrue(content.startswith("# Intro\n\n"))
            self.assertTrue(content.endswith("\n\n# Outro\n"))
        finally:
            if os.path.exists(temp_path):
                os.remove(temp_path)


if __name__ == "__main__":
    unittest.main()
