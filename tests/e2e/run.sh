#!/usr/bin/env bash
# tests/e2e/run.sh — functional end-to-end test runner.
# Requires WIKI_URL env var pointing to a deployed wiki instance.
set -euo pipefail

WIKI_URL="${WIKI_URL:?WIKI_URL must be set, e.g. http://localhost:8080}"
REPORT_DIR="${REPORT_DIR:-tests/e2e/report}"
mkdir -p "$REPORT_DIR"

PASS=0
FAIL=0
RESULTS=()

record() {
  local name="$1" status="$2" detail="${3:-}"
  if [ "$status" = "PASS" ]; then
    PASS=$((PASS+1))
    RESULTS+=("  ✓ $name")
  else
    FAIL=$((FAIL+1))
    RESULTS+=("  ✗ $name — $detail")
  fi
}
# --- Test 1: liveness ---
STATUS=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "$WIKI_URL/health/live" || echo 000)
record "GET /health/live → 200" "$([ "$STATUS" = 200 ] && echo PASS || echo FAIL)" "status=$STATUS"

# --- Test 2: readiness (DB available) ---
STATUS=$(curl -s -o /tmp/e2e-ready.json -w '%{http_code}' --max-time 5 "$WIKI_URL/health/ready" || echo 000)
if [ "$STATUS" = "200" ]; then
  record "GET /health/ready → 200" "PASS"
else
  record "GET /health/ready → 200" "FAIL" "status=$STATUS — DB not ready?"
fi
# --- Output ---
echo
echo "═══ E2E TEST RESULTS ═══"
printf '%s\n' "${RESULTS[@]}"
echo "────────────────────────"
echo "Passed: $PASS"
echo "Failed: $FAIL"
echo "────────────────────────"

# Persist report
cat > "$REPORT_DIR/summary.md" <<EOF
# E2E Test Report

**Target:** \`${WIKI_URL}\`
**Date:** $(date -u +%FT%TZ)
**Total:** $((PASS+FAIL))  |  **Passed:** $PASS  |  **Failed:** $FAIL

## Results

$(printf -- '- %s\n' "${RESULTS[@]}")
EOF
cp /tmp/e2e-*.json "$REPORT_DIR/" 2>/dev/null || true

if [ "$FAIL" -gt 0 ]; then
  echo "[e2e] FAILURES DETECTED"
  exit 1
fi
echo "[e2e] All tests passed"
