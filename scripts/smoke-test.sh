#!/usr/bin/env bash
# scripts/smoke-test.sh — basic smoke checks against the wiki-preview service.
# Runs inside a runner that has kubectl + cluster access.
#
# Service wiki-preview сейчас на порту 80 (targetPort 3000 в контейнере).
# Поэтому port-forward делаем на 80, а не на 3000.
set -euo pipefail

NAMESPACE="${NAMESPACE:?NAMESPACE must be set}"

echo "[smoke] namespace=$NAMESPACE"

# Использовать существующий port-forward, если уже открыт (blue-green-deploy.sh)
# или открыть свой собственный
if ! curl -sf http://localhost:8080/health/live >/dev/null 2>&1; then
  echo "[smoke] opening port-forward svc/wiki-preview 8080:80 ..."
  kubectl --context k8s -n "$NAMESPACE" port-forward svc/wiki-preview 8080:80 >/tmp/smoke-pf.log 2>&1 &
  PF_PID=$!
  trap 'if kill -0 '"$PF_PID"' 2>/dev/null; then kill '"$PF_PID"' 2>/dev/null || true; fi' EXIT
else
  echo "[smoke] using existing port-forward on 8080"
fi

echo "[smoke] waiting for port-forward to be ready..."
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
STATUS=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "$BASE/health/live")
check "live-returns-200" "200" "$STATUS"

echo "[smoke] /health/ready"
STATUS=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "$BASE/health/ready")
check "ready-returns-200" "200" "$STATUS"

echo "[smoke] /health (full)"
STATUS=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "$BASE/health")
check "health-returns-200" "200" "$STATUS"

echo "[smoke] GET /api/pages"
STATUS=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "$BASE/api/pages")
check "list-pages-200" "200" "$STATUS"

echo "[smoke] Summary: pass=$PASS fail=$FAIL"
if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
echo "[smoke] All smoke tests passed"
