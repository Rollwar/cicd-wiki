#!/usr/bin/env bash
# scripts/blue-green-deploy.sh — local helper to drive a blue-green deploy on k3s.
# Used by the demo / dry-run; the CD workflow in .github/workflows/cd.yml does
# the same thing in CI.
#
# Usage:
#   bash scripts/blue-green-deploy.sh <image-ref> [namespace]
#   bash scripts/blue-green-deploy.sh ghcr.io/rollwar/wiki:latest wiki-staging
set -euo pipefail

IMAGE="${1:?usage: blue-green-deploy.sh <image-ref> [namespace]}"
NAMESPACE="${2:-wiki-staging}"

# Путь к скрипту (для корректного запуска smoke-test.sh из любого CWD)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"

echo "[bg] Deploying image=$IMAGE to namespace=$NAMESPACE"

# 1. Render & apply green deployment
sed -e "s|__IMAGE__|$IMAGE|g" -e "s|__SLOT__|green|g" \
  deploy/k8s/deployment-slot.yaml > /tmp/deploy-green.yaml
kubectl --context k8s -n "$NAMESPACE" apply -f /tmp/deploy-green.yaml
kubectl --context k8s -n "$NAMESPACE" rollout status deployment/wiki-green --timeout=300s

# 2. Smoke test via preview service (port 80, не 3000 — Service сейчас на 80)
echo "[bg] Running smoke tests..."
kubectl --context k8s -n "$NAMESPACE" port-forward svc/wiki-preview 8080:80 >/tmp/bg-pf.log 2>&1 &
PF=$!
# trap с проверкой существования процесса (избегаем "kill: no such process")
trap 'if kill -0 '"$PF"' 2>/dev/null; then kill '"$PF"' 2>/dev/null || true; fi' EXIT

# Подождать port-forward
for i in {1..15}; do
  if curl -sf http://localhost:8080/health/live >/dev/null 2>&1; then
    break
  fi
  sleep 1
done

NAMESPACE="$NAMESPACE" bash scripts/smoke-test.sh

# 3. Promote green to live (switch Service selector → slot=green)
echo "[bg] Switching live traffic: BLUE → GREEN"
kubectl --context k8s -n "$NAMESPACE" patch svc wiki --type='json' \
  -p='[{"op":"replace","path":"/spec/selector/app.kubernetes.io~1slot","value":"green"}]'

# Verify endpoints updated
sleep 2
echo "[bg] Live endpoints:"
kubectl --context k8s -n "$NAMESPACE" get endpoints wiki -o jsonpath='{.subsets[0].addresses[*].ip}'; echo

# 4. Scale down previous blue (keep 1 replica for fast rollback)
if kubectl --context k8s -n "$NAMESPACE" get deploy wiki-blue >/dev/null 2>&1; then
  kubectl --context k8s -n "$NAMESPACE" scale deploy/wiki-blue --replicas=1
  echo "[bg] BLUE scaled to 1 (kept for rollback)"
fi

echo "[bg] ✓ Done. Live traffic now served by GREEN ($IMAGE)"
