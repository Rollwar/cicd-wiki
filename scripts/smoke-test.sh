#!/usr/bin/env bash
# scripts/smoke-test.sh — basic smoke checks against the wiki-preview service.
# Runs inside a runner that has kubectl + cluster access.
set -euo pipefail

NAMESPACE="${NAMESPACE:?NAMESPACE must be set}"

echo "[smoke] namespace=$NAMESPACE"

# Use kubectl port-forward to reach the preview service
kubectl --context k8s -n "$NAMESPACE" port-forward svc/wiki-preview 8080:3000 >/tmp/smoke-pf.log 2>&1 &
PF_PID=$!
trap "kill $PF_PID 2>/dev/null || true" EXIT

echo "[smoke] waiting for port-forward..."
for i in {1..15}; do
  if curl -sf http://localhost:8080/health/live >/dev/null 2>&1; then
    break
  fi
  sleep 1
done

BASE=http://localhost:8080
PASS=0
FAIL=0

check() {
  local name="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then
    echo "  ✓ $name"
    PASS=$((PASS+1))
  else
    echo "  ✗ $name (expected=$expected, actual=$actual)"
    FAIL=$((FAIL+1))
  fi
}

echo "[smoke] /health/live"
STATUS=$(curl -s -o /dev/null -w '%{http_code}' "$BASE/health/live")
check "live-returns-200" "200" "$STATUS"

echo "[smoke] /health/ready"
STATUS=$(curl -s -o /dev/null -w '%{http_code}' "$BASE/health/ready")
check "ready-returns-200" "200" "$STATUS"

echo "[smoke] /health (full)"
STATUS=$(curl -s -o /dev/null -w '%{http_code}' "$BASE/health")
check "health-returns-200" "200" "$STATUS"

echo "[smoke] GET /api/pages"
STATUS=$(curl -s -o /dev/null -w '%{http_code}' "$BASE/api/pages")
check "list-pages-200" "200" "$STATUS"

echo "[smoke] POST /api/pages (write + read back)"
PAYLOAD=$(cat <<JSON
{ "slug": "smoke-test-$(date +%s)", "title": "Smoke Test Page", "content": "# Smoke\nCreated by smoke test" }
JSON
)
STATUS=$(curl -s -o /tmp/smoke-create.json -w '%{http_code}' -X POST -H 'Content-Type: application/json' -d "$PAYLOAD" "$BASE/api/pages")
check "create-page-201" "201" "$STATUS"

echo "[smoke] Summary: pass=$PASS fail=$FAIL"
if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
echo "[smoke] All smoke tests passed"
