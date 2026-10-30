#!/usr/bin/env bash
# scripts/blue-green-deploy.sh — local helper to drive a blue-green deploy on k3s.
# Used by the demo / dry-run; the CD workflow in .github/workflows/cd.yml does
# the same thing in CI.
set -euo pipefail

IMAGE="${1:?usage: blue-green-deploy.sh <image-ref> [namespace]}"
NAMESPACE="${2:-wiki-staging}"

echo "[bg] Deploying image=$IMAGE to namespace=$NAMESPACE"

# 1. Render & apply green deployment
sed -e "s|__IMAGE__|$IMAGE|g" -e "s|__SLOT__|green|g" \
  deploy/k8s/deployment-slot.yaml > /tmp/deploy-green.yaml
kubectl -n "$NAMESPACE" apply -f /tmp/deploy-green.yaml
kubectl -n "$NAMESPACE" rollout status deployment/wiki-green --timeout=300s

# 2. Smoke test via preview service
echo "[bg] Running smoke tests..."
kubectl -n "$NAMESPACE" port-forward svc/wiki-preview 8080:3000 &
PF=$!
trap "kill $PF" EXIT
sleep 5
NAMESPACE="$NAMESPACE" bash scripts/smoke-test.sh

# 3. Promote green to live
kubectl -n "$NAMESPACE" patch svc wiki \
  -p '{"spec":{"selector":{"app.kubernetes.io/name":"wiki","app.kubernetes.io/slot":"green"}}}'

# 4. Scale down previous blue (keep 1 replica for rollback)
if kubectl -n "$NAMESPACE" get deploy wiki-blue >/dev/null 2>&1; then
  kubectl -n "$NAMESPACE" scale deploy/wiki-blue --replicas=1
fi

echo "[bg] Done. Live traffic now served by GREEN ($IMAGE)"
