#!/usr/bin/env python3
"""Slug-set superset deletion-safety check.

Verifies the post-split BMF (the union of `bench_spsc / bench_mpsc /
bench_mpmc_bounded / bench_spmc_bounded / bench_unbounded_spsc /
bench_unbounded_spmc / bench_unbounded_mpsc /
bench_unbounded_mpmc` outputs merged via `merge_bmf.py`) is a strict
superset of the pre-split BMF captured from the legacy
`bench_throughput` binary. the `bench_mpmc` slot into
a per-family pair; fanned the `bench_unbounded` slot
into four per-family binaries. Each binary's slug subset is smaller;
the union is unchanged.

CONTRACT
    superset_check.py <pre.json> <post.json>

    Both arguments must be paths to JSON files emitted by the project's
    BMF emitter (`benchmarks/nim/bench_common.nim`). Top-level keys are
    slugs; values are dicts of measure names. Only the slug *keys* are
    compared by this check — measure values, bounds, and ordering are
    ignored. Slug-level deletion is what the topology split must avoid.

EXIT CODES
    0   set(pre) is a subset of set(post). Empty output on stdout.
    1   pre includes one or more slugs missing from post (deletion-
        safety failure). Stderr lists the missing slugs (one per line,
        alphabetically sorted) so CI log searches can grep them.
        Also returned for usage / IO errors (file missing, malformed
        JSON, top-level not an object) to match the exit-code contract
        used by `benchmarks/merge_bmf.py`. Stderr names the failure
        mode in either case.

DESIGN NOTE
    "Strict superset" in the impl plan means `set(pre) <= set(post)`
    AND no slug from pre is missing from post. This is identical to
    `set(pre) <= set(post)` for non-empty pre; we keep the
    `set.issubset` check explicit so the failure mode (which slugs
    are missing) can be enumerated for the operator.
"""

from __future__ import annotations

import json
import sys
from pathlib import Path


def _die_usage(msg: str) -> int:
    print(f"error: {msg}", file=sys.stderr)
    print(
        "usage: superset_check.py <pre.json> <post.json>",
        file=sys.stderr,
    )
    return 1


# Keys that the BMF emitter or the merge step may add at the top level
# but that are NOT benchmark slugs. The superset check must ignore
# them or it will report spurious missing-slug failures (e.g., if
# `pre.json` was emitted before `meta` was added and `post.json`
# carries it, the diff is harmless; the reverse — pre carrying a
# metadata key absent from post — is what previously raised a false
# positive). Match by exact name and by a leading `_` convention so
# any future internal/scratch keys are filtered without churn.
# Per gemini PR feat/v0.1.0 review, 2026-06-07.
_NON_SLUG_TOP_LEVEL_KEYS: frozenset[str] = frozenset(
    {
        # Live schema key (no underscore prefix). The emitter writes
        # `"meta"` at the top level of every BMF; the earlier draft of
        # this exclusion list used `"_meta"`, which never matched and
        # could trigger false-positive missing-slug failures.
        "meta",
        "_schema",
        "_generated_at",
        "_version",
        "_status",
        "_temp",
        "_internal",
    }
)


def _is_slug_key(key: str) -> bool:
    """True if `key` is a benchmark slug (not a metadata / temp key)."""
    if key in _NON_SLUG_TOP_LEVEL_KEYS:
        return False
    # Generic underscore-prefix convention for internal keys. Real
    # benchmark slugs follow `<family>_<config>` form and never start
    # with an underscore.
    if key.startswith("_"):
        return False
    return True


def _load_slugs(path: Path) -> set[str]:
    """Return the set of top-level slug keys in `path`. Raises ValueError
    on malformed JSON or non-object top-level values.

    Filters non-slug metadata / status keys (see
    `_NON_SLUG_TOP_LEVEL_KEYS` and `_is_slug_key`) so the superset
    check compares actual benchmark coverage, not emitter scaffolding.
    """
    try:
        text = path.read_text(encoding="utf-8")
    except OSError as exc:
        raise ValueError(f"cannot read {path}: {exc}") from exc
    try:
        parsed = json.loads(text)
    except json.JSONDecodeError as exc:
        raise ValueError(f"malformed JSON in {path}: {exc}") from exc
    if not isinstance(parsed, dict):
        raise ValueError(
            f"top-level value in {path} must be a JSON object; "
            f"got {type(parsed).__name__}"
        )
    return {key for key in parsed.keys() if _is_slug_key(key)}


def main(argv: list[str]) -> int:
    if len(argv) != 3:
        return _die_usage(
            f"expected 2 arguments (pre.json, post.json); got {len(argv) - 1}"
        )
    pre_path = Path(argv[1])
    post_path = Path(argv[2])
    try:
        pre_slugs = _load_slugs(pre_path)
        post_slugs = _load_slugs(post_path)
    except ValueError as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 1

    missing = pre_slugs - post_slugs
    if not missing:
        return 0

    # Failure mode: enumerate every missing slug so the operator can
    # see exactly which split-binary lost coverage. Sort for stable
    # diff output across runs.
    print(
        f"error: post-split BMF is missing {len(missing)} slug(s) "
        f"from pre-split fixture {pre_path}:",
        file=sys.stderr,
    )
    for slug in sorted(missing):
        print(f"  missing: {slug}", file=sys.stderr)
    return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv))
