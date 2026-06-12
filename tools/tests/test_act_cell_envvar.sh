#!/usr/bin/env bash
# Test: LFQ_ACT_BIN env var is honored by tools/act-cell.
#
# Two tests, both locked against observable process behavior (no dependency
# on a dry-run flag, per F12 fix):
#
#   Test 4 (smoke):  Setting LFQ_ACT_BIN to a harmless binary (/bin/echo)
#                    does not break the --print-watchdog-config path. This
#                    path resolves ACT_BIN at the top of the script but
#                    exits before invoking it, so any value for LFQ_ACT_BIN
#                    should be tolerated.
#
#   Test 5 (stub):   When LFQ_ACT_BIN points at a recording stub, an
#                    actual cell invocation (--no-watchdog path, which uses
#                    `exec timeout ... "${CMD[@]}"`) executes the stub
#                    rather than real `act`. The stub records its invocation
#                    so the test can grep for proof of execution.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ACT_CELL="$SCRIPT_DIR/../act-cell"

# --------------------------------------------------------------------------
# Test 4: LFQ_ACT_BIN does not break --print-watchdog-config
# --------------------------------------------------------------------------
# The config-print path resolves ACT_BIN but never invokes it. Setting
# LFQ_ACT_BIN to /bin/echo (which exists everywhere) must not affect the
# config probe's output.
out=$(LFQ_ACT_BIN=/bin/echo "$ACT_CELL" --print-watchdog-config 2>&1)
if ! echo "$out" | grep -qE "^STALL_SECS=300$"; then
  echo "FAIL: --print-watchdog-config broke under LFQ_ACT_BIN=/bin/echo (got: $out)"
  exit 1
fi
if ! echo "$out" | grep -qE "^HARD_TIMEOUT_SECS=5400$"; then
  echo "FAIL: --print-watchdog-config broke under LFQ_ACT_BIN=/bin/echo (got: $out)"
  exit 1
fi
echo "Test 4 PASS (LFQ_ACT_BIN does not interfere with --print-watchdog-config)"

# --------------------------------------------------------------------------
# Test 5: LFQ_ACT_BIN stub is actually invoked
# --------------------------------------------------------------------------
# Stub a recording binary, point LFQ_ACT_BIN at it, and run a real cell
# under --no-watchdog (which uses `exec timeout ... "${CMD[@]}"` and runs
# CMD[0] == ACT_BIN). The stub captures its argv to a known file; the test
# verifies the file is present and non-empty, proving the stub (not real
# act) ran.
STUB_DIR="$(mktemp -d)"
trap 'rm -rf "$STUB_DIR"' EXIT

STUB_OUT="$STUB_DIR/invocation.log"
cat > "$STUB_DIR/fake-act" <<EOF
#!/usr/bin/env bash
# Record argv for the test to inspect.
{
  echo "INVOKED_FAKE_ACT"
  echo "argv: \$*"
} > "$STUB_OUT"
exit 0
EOF
chmod +x "$STUB_DIR/fake-act"

# Use cell 1a (Tier A test-fast); --no-watchdog ensures the script's
# `exec timeout ... "${CMD[@]}"` path runs the stub directly with no
# tee/setsid wrapping. A short hard timeout prevents the test from hanging
# if the stub somehow misbehaves.
export LFQ_ACT_HARD_TIMEOUT_SECS=30
set +e
LFQ_ACT_BIN="$STUB_DIR/fake-act" "$ACT_CELL" 1a --no-watchdog >/dev/null 2>&1
rc=$?
set -e

if [ ! -s "$STUB_OUT" ]; then
  echo "FAIL: LFQ_ACT_BIN stub was not invoked (no invocation log at $STUB_OUT, rc=$rc)"
  exit 1
fi
if ! grep -q "INVOKED_FAKE_ACT" "$STUB_OUT"; then
  echo "FAIL: invocation log missing INVOKED_FAKE_ACT marker (rc=$rc, contents: $(cat "$STUB_OUT"))"
  exit 1
fi
echo "Test 5 PASS (LFQ_ACT_BIN stub invoked under --no-watchdog path)"

echo "PASS"
