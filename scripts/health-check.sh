#!/usr/bin/env bash
# scripts/health-check.sh — quick verification of wiki endpoints.
set -euo pipefail

URL="${1:-http://localhost:3000}"

check() {
  local name="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then
    echo "  ✓ $name"
  else
    echo "  ✗ $name (expected=$expected, actual=$actual)"
    exit 1
  fi
}

STATUS=$(curl -s -o /dev/null -w '%{http_code}' "$URL/health/live")
check "live" "200" "$STATUS"

STATUS=$(curl -s -o /dev/null -w '%{http_code}' "$URL/health/ready")
check "ready" "200" "$STATUS"

echo "All health checks passed"
