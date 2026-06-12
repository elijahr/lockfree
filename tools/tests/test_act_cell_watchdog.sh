#!/usr/bin/env bash
# Test: act-cell watchdog kills a stalled child within 5 minutes (compressed
# to 10 seconds for test) and respects --no-watchdog.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ACT_CELL="$SCRIPT_DIR/../act-cell"

# Stub act binary: blocks indefinitely with no stdout (simulates stall).
STUB_DIR="$(mktemp -d)"
trap 'rm -rf "$STUB_DIR"' EXIT
cat > "$STUB_DIR/act" <<'EOF'
#!/usr/bin/env bash
sleep 600
EOF
chmod +x "$STUB_DIR/act"

# Test 1: with watchdog (compressed thresholds via env), expect kill within ~15s.
export LFQ_ACT_STALL_SECS=5
export LFQ_ACT_HARD_TIMEOUT_SECS=30
export PATH="$STUB_DIR:$PATH"

start=$(date +%s)
set +e
LFQ_ACT_BIN="$STUB_DIR/act" "$ACT_CELL" 6 --push-devel >/dev/null 2>&1
rc=$?
set -e
elapsed=$(( $(date +%s) - start ))

if [ "$elapsed" -ge 25 ]; then
  echo "FAIL: watchdog did not fire within 25s (elapsed=${elapsed}s, rc=${rc})"
  exit 1
fi
if [ "$rc" -eq 0 ]; then
  echo "FAIL: stalled child returned rc=0; watchdog should non-zero"
  exit 1
fi
echo "Test 1 PASS (stall watchdog fired at elapsed=${elapsed}s, rc=${rc})"

# Test 2: with --no-watchdog, the script must NOT kill the child before the hard
# timeout. Use a short hard timeout (30s) so the test finishes; assert elapsed
# is at least the hard timeout (i.e., watchdog was NOT active and hard timeout
# was what stopped it).
start=$(date +%s)
set +e
LFQ_ACT_BIN="$STUB_DIR/act" "$ACT_CELL" --no-watchdog 6 --push-devel >/dev/null 2>&1
rc=$?
set -e
elapsed=$(( $(date +%s) - start ))

if [ "$elapsed" -lt 25 ]; then
  echo "FAIL: --no-watchdog flag did not disable stall watchdog (elapsed=${elapsed}s)"
  exit 1
fi
echo "Test 2 PASS (--no-watchdog disables stall layer; elapsed=${elapsed}s)"

# Test 3: default thresholds (no env vars set) must report 300/5400. Probe via
# --print-watchdog-config.
unset LFQ_ACT_STALL_SECS
unset LFQ_ACT_HARD_TIMEOUT_SECS
out=$("$ACT_CELL" --print-watchdog-config 2>&1)
if ! echo "$out" | grep -qE "^STALL_SECS=300$"; then
  echo "FAIL: default LFQ_ACT_STALL_SECS is not 300 (got: $out)"
  exit 1
fi
if ! echo "$out" | grep -qE "^HARD_TIMEOUT_SECS=5400$"; then
  echo "FAIL: default LFQ_ACT_HARD_TIMEOUT_SECS is not 5400 (got: $out)"
  exit 1
fi
echo "Test 3 PASS (defaults are STALL_SECS=300 HARD_TIMEOUT_SECS=5400)"

echo "PASS"
