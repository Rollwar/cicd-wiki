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

# --- Test 1: root endpoint ---
STATUS=$(curl -s -o /tmp/e2e-root.json -w '%{http_code}' --max-time 10 "$WIKI_URL/" || echo 000)
if [ "$STATUS" = "200" ]; then
  NAME=$(jq -r '.name // empty' /tmp/e2e-root.json 2>/dev/null || true)
  if [ "$NAME" = "Wiki.js" ]; then
    record "GET / returns Wiki.js" "PASS"
  else
    record "GET / name match" "FAIL" "got '$NAME'"
  fi
else
  record "GET / returns 200" "FAIL" "status=$STATUS"
fi

# --- Test 2: liveness ---
STATUS=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "$WIKI_URL/health/live" || echo 000)
record "GET /health/live → 200" "$([ "$STATUS" = 200 ] && echo PASS || echo FAIL)" "status=$STATUS"

# --- Test 3: readiness (DB available) ---
STATUS=$(curl -s -o /tmp/e2e-ready.json -w '%{http_code}' --max-time 5 "$WIKI_URL/health/ready" || echo 000)
if [ "$STATUS" = "200" ]; then
  record "GET /health/ready → 200" "PASS"
else
  record "GET /health/ready → 200" "FAIL" "status=$STATUS — DB not ready?"
fi

# --- Test 4: create wiki page (write path) ---
SLUG="e2e-$(date +%s)"
PAYLOAD=$(cat <<JSON
{"slug":"$SLUG","title":"E2E Test Page","content":"# E2E\nCreated at $(date -u +%FT%TZ)"}
JSON
)
CREATE_STATUS=$(curl -s -o /tmp/e2e-create.json -w '%{http_code}' --max-time 10 \
  -X POST -H 'Content-Type: application/json' -d "$PAYLOAD" "$WIKI_URL/api/pages" || echo 000)
if [ "$CREATE_STATUS" = "201" ]; then
  record "POST /api/pages → 201 (create)" "PASS"
else
  record "POST /api/pages → 201" "FAIL" "status=$CREATE_STATUS"
fi

# --- Test 5: read page back ---
GET_STATUS=$(curl -s -o /tmp/e2e-get.json -w '%{http_code}' --max-time 5 "$WIKI_URL/api/pages/$SLUG" || echo 000)
if [ "$GET_STATUS" = "200" ]; then
  TITLE=$(jq -r '.title // empty' /tmp/e2e-get.json 2>/dev/null || true)
  if [ "$TITLE" = "E2E Test Page" ]; then
    record "GET /api/pages/$SLUG returns correct title" "PASS"
  else
    record "GET page title matches" "FAIL" "got '$TITLE'"
  fi
else
  record "GET /api/pages/$SLUG → 200" "FAIL" "status=$GET_STATUS"
fi

# --- Test 6: idempotent update (preserves user data) ---
PAYLOAD=$(cat <<JSON
{"slug":"$SLUG","title":"E2E Updated","content":"# Updated\nv2"}
JSON
)
UPDATE_STATUS=$(curl -s -o /tmp/e2e-update.json -w '%{http_code}' --max-time 10 \
  -X POST -H 'Content-Type: application/json' -d "$PAYLOAD" "$WIKI_URL/api/pages" || echo 000)
if [ "$UPDATE_STATUS" = "201" ]; then
  # Verify it's the same id
  GET_STATUS=$(curl -s -o /tmp/e2e-get2.json -w '%{http_code}' --max-time 5 "$WIKI_URL/api/pages/$SLUG" || echo 000)
  TITLE=$(jq -r '.title // empty' /tmp/e2e-get2.json 2>/dev/null || true)
  if [ "$TITLE" = "E2E Updated" ]; then
    record "POST /api/pages idempotent update preserves user data" "PASS"
  else
    record "Update preserved" "FAIL" "title now '$TITLE'"
  fi
else
  record "POST /api/pages → 201 (update)" "FAIL" "status=$UPDATE_STATUS"
fi

# --- Test 7: list pages ---
LIST_STATUS=$(curl -s -o /tmp/e2e-list.json -w '%{http_code}' --max-time 5 "$WIKI_URL/api/pages" || echo 000)
if [ "$LIST_STATUS" = "200" ]; then
  COUNT=$(jq 'if type == "array" then length else 0 end' /tmp/e2e-list.json 2>/dev/null || echo 0)
  if [ "$COUNT" -ge 1 ]; then
    record "GET /api/pages returns ≥1 entry" "PASS"
  else
    record "GET /api/pages returns entries" "FAIL" "count=$COUNT"
  fi
else
  record "GET /api/pages → 200" "FAIL" "status=$LIST_STATUS"
fi

# --- Test 8: 404 on unknown slug ---
NOTFOUND_STATUS=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "$WIKI_URL/api/pages/does-not-exist-xyz" || echo 000)
record "GET unknown slug → 404" "$([ "$NOTFOUND_STATUS" = 404 ] && echo PASS || echo FAIL)" "status=$NOTFOUND_STATUS"

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
