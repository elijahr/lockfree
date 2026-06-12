#!/usr/bin/env bash
# tests/test_chronos_dep_error.sh
#
# C-CRITICAL-4 regression test (flag-only opt-in): building with
# `-d:lockfreeChronos` while chronos is NOT installed must fail with an
# actionable compile-time error referencing BOTH `docs/api/chronos.md`
# (the integration guide) AND the `nimble install chronos` command.
#
# Uses the dedicated probe at `tests/t_chronos_dep_error_probe.nim`,
# which (unlike `tests/t_chronos.nim`) imports `lockfree/chronos`
# unconditionally so the {.error.} arm is reached even from a build env
# where chronos is missing.
#
# This test assumes chronos is NOT installed in the current build env.
# In CI cells where chronos IS installed, this test is skipped at the
# orchestration layer (NOT here — running here would produce a green
# build and a wrong PASS).
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PROBE="$REPO_ROOT/tests/t_chronos_dep_error_probe.nim"
TMP_NIMCACHE="$(mktemp -d)"
trap 'rm -rf "$TMP_NIMCACHE"' EXIT

# Skip if chronos IS installed (the {.error.} arm wouldn't fire and the
# PASS would be misleading). Probe via a one-off `compiles do:` check.
PROBE_CHRONOS="$(mktemp -t chronos-probe-XXXXXX).nim"
cat > "$PROBE_CHRONOS" <<'EOF'
when compiles(import chronos/asyncsync):
  echo "chronos-installed"
else:
  echo "chronos-missing"
EOF
chronos_status="$(nim r --hints:off --warnings:off --nimcache:"$TMP_NIMCACHE/probe" "$PROBE_CHRONOS" 2>&1 | tail -1 || true)"
rm -f "$PROBE_CHRONOS"

if [ "$chronos_status" = "chronos-installed" ]; then
  echo "SKIP: chronos is installed in this build env; this test would not exercise the {.error.} path"
  exit 0
fi

# Build the probe with -d:lockfreeChronos. Expect non-zero exit + the
# two diagnostic anchors in the output.
set +e
out="$(nim c --hints:off --warnings:off \
  -d:lockfreeChronos \
  --nimcache:"$TMP_NIMCACHE/build" \
  --threads:on \
  "$PROBE" 2>&1)"
rc=$?
set -e

if [ "$rc" -eq 0 ]; then
  echo "FAIL: build with -d:lockfreeChronos and no chronos installed unexpectedly succeeded"
  echo "$out"
  exit 1
fi

if ! echo "$out" | grep -q "docs/api/chronos.md"; then
  echo "FAIL: expected error to reference docs/api/chronos.md. Got:"
  echo "$out"
  exit 1
fi

if ! echo "$out" | grep -qE "nimble install \"?chronos"; then
  echo "FAIL: expected error to reference 'nimble install chronos'. Got:"
  echo "$out"
  exit 1
fi

echo "PASS"
