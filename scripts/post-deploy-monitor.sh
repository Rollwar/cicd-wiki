#!/usr/bin/env bash
# scripts/post-deploy-monitor.sh — observes live traffic for N minutes.
# If health checks fail repeatedly, triggers automatic rollback workflow.
set -euo pipefail

NAMESPACE="${NAMESPACE:?NAMESPACE must be set}"
MONITOR_MINUTES="${MONITOR_MINUTES:-2}"
FAILURE_THRESHOLD="${FAILURE_THRESHOLD:-3}"
ROLLBACK_WORKFLOW="${ROLLBACK_WORKFLOW:-rollback.yml}"

echo "[monitor] watching namespace=$NAMESPACE for ${MONITOR_MINUTES}m, threshold=$FAILURE_THRESHOLD"

kubectl --context k8s -n "$NAMESPACE" port-forward svc/wiki 8090:80 >/tmp/monitor-pf.log 2>&1 &
PF_PID=$!
trap "kill $PF_PID 2>/dev/null || true" EXIT

# Wait for port-forward to be ready
for i in {1..15}; do
  curl -sf http://localhost:8090/health/live >/dev/null 2>&1 && break
  sleep 1
done

END=$((SECONDS + MONITOR_MINUTES * 60))
FAILS=0
CHECKS=0

while [ $SECONDS -lt $END ]; do
  CHECKS=$((CHECKS+1))
  if STATUS=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 http://localhost:8090/health 2>/dev/null) && [ "$STATUS" = "200" ]; then
    echo "[monitor] check #${CHECKS}: 200 OK"
    FAILS=0
  else
    FAILS=$((FAILS+1))
    echo "[monitor] check #${CHECKS}: FAIL (status=${STATUS:-no-response}, consecutive=$FAILS)"
    if [ "$FAILS" -ge "$FAILURE_THRESHOLD" ]; then
      echo "[monitor] threshold exceeded — triggering rollback"

      # Trigger rollback workflow via gh CLI
      if command -v gh >/dev/null 2>&1; then
        gh workflow run "$ROLLBACK_WORKFLOW" \
          -R "${GITHUB_REPOSITORY:-Rollwar/cicd-wikijs}" \
          -f environment=production \
          -f reason="auto-rollback: post-deploy health check failed ${FAILS}x"
      fi
      exit 1
    fi
  fi
  sleep 10
done

echo "[monitor] monitoring complete — no rollback needed (checks=$CHECKS, fails=$FAILS)"
