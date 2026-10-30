#!/usr/bin/env bash
# scripts/rollback.sh — local rollback helper.
set -euo pipefail

NAMESPACE="${1:-wiki-staging}"

if ! kubectl --context k8s -n "$NAMESPACE" get deploy wiki-blue >/dev/null 2>&1; then
  echo "[rollback] No wiki-blue deployment — nothing to roll back to"
  exit 1
fi

echo "[rollback] Scaling up BLUE..."
kubectl --context k8s -n "$NAMESPACE" scale deploy/wiki-blue --replicas=3
kubectl --context k8s -n "$NAMESPACE" rollout status deployment/wiki-blue --timeout=180s

echo "[rollback] Switching live service to BLUE..."
kubectl --context k8s -n "$NAMESPACE" patch svc wiki \
  -p '{"spec":{"selector":{"app.kubernetes.io/name":"wiki","app.kubernetes.io/slot":"blue"}}}'

echo "[rollback] Scaling down failed GREEN..."
kubectl --context k8s -n "$NAMESPACE" scale deploy/wiki-green --replicas=0 || true

echo "[rollback] Done. Live traffic reverted to BLUE."
