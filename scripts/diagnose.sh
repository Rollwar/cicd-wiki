#!/usr/bin/env bash
# scripts/diagnose.sh — диагностика зависшего Deployment (wiki-blue / wiki-green).
# Показывает состояние pods, events, последние логи и describe.
#
# Usage:
#   bash scripts/diagnose.sh <namespace> [deployment-name]
#   bash scripts/diagnose.sh wiki-staging
#   bash scripts/diagnose.sh wiki-staging wiki-blue
set -euo pipefail

NAMESPACE="${1:?usage: diagnose.sh <namespace> [deployment-name]}"
DEPLOY="${2:-wiki-blue}"

echo "═══════════════════════════════════════════════════════════════════════"
echo "  Diagnosing: $DEPLOY in namespace=$NAMESPACE"
echo "═══════════════════════════════════════════════════════════════════════"

# 1. Deployment status
echo ""
echo "── 1. Deployment $DEPLOY status ──"
kubectl --context k8s -n "$NAMESPACE" get deploy "$DEPLOY" -o wide || true
echo ""
echo "    Conditions:"
kubectl --context k8s -n "$NAMESPACE" get deploy "$DEPLOY" -o jsonpath='{range .status.conditions[*]}{.type}{"="}{.status}{" ("}{.reason}{": "}{.message}{")\n"}{end}' 2>/dev/null || true

# 2. Pods
echo ""
echo "── 2. Pods (with STATUS, RESTARTS, NODE) ──"
kubectl --context k8s -n "$NAMESPACE" get pods -l app.kubernetes.io/name=wiki --show-labels 2>/dev/null || \
  kubectl --context k8s -n "$NAMESPACE" get pods | head -20

# 3. Pod details — ready condition, container statuses, last state
echo ""
echo "── 3. Pod readiness + restart count ──"
kubectl --context k8s -n "$NAMESPACE" get pods -l app.kubernetes.io/name=wiki -o jsonpath='{range .items[*]}{.metadata.name}{"\tready="}{.status.containerStatuses[0].ready}{"\trestarts="}{.status.containerStatuses[0].restartCount}{"\tstate="}{.status.containerStatuses[0].state}{"\n"}{end}' 2>/dev/null

# 4. Events (sorted by time)
echo ""
echo "── 4. Recent events in namespace (last 20) ──"
kubectl --context k8s -n "$NAMESPACE" get events --sort-by='.lastTimestamp' 2>/dev/null | tail -20

# 5. Describe each wiki pod — pulls, probes, last state
echo ""
echo "── 5. Pod describe (warning + events sections) ──"
PODS=$(kubectl --context k8s -n "$NAMESPACE" get pods -l app.kubernetes.io/name=wiki -o name 2>/dev/null | head -3)
if [ -z "$PODS" ]; then
  echo "  (no wiki pods found — fetching first 3 pods in namespace)"
  PODS=$(kubectl --context k8s -n "$NAMESPACE" get pods -o name 2>/dev/null | head -3)
fi
for pod in $PODS; do
  echo ""
  echo "── $pod ──"
  kubectl --context k8s -n "$NAMESPACE" describe "$pod" 2>/dev/null | sed -n '/Conditions:/,/Events:/p' | head -25
  kubectl --context k8s -n "$NAMESPACE" describe "$pod" 2>/dev/null | sed -n '/Events:/,$p' | tail -20
done

# 6. Last 50 lines of logs from first wiki pod
echo ""
echo "── 6. Last 50 lines of container logs ──"
FIRST_POD=$(kubectl --context k8s -n "$NAMESPACE" get pods -l app.kubernetes.io/name=wiki -o name 2>/dev/null | head -1)
if [ -n "$FIRST_POD" ]; then
  kubectl --context k8s -n "$NAMESPACE" logs "$FIRST_POD" --tail=50 2>&1 || \
    echo "  (container might not have started yet — try previous logs:)"
  echo ""
  echo "── 7. Previous container logs (if crashed) ──"
  kubectl --context k8s -n "$NAMESPACE" logs "$FIRST_POD" --previous --tail=30 2>&1 || true
else
  echo "  (no wiki pods found — Deployment might have failed to schedule)"
fi

# 8. Cluster-wide checks
echo ""
echo "── 8. Cluster-wide sanity checks ──"
echo "  Nodes:"
kubectl --context k8s get nodes -o wide 2>/dev/null | head -5
echo ""
echo "  PVCs in $NAMESPACE:"
kubectl --context k8s -n "$NAMESPACE" get pvc 2>/dev/null || true
echo ""
echo "  StorageClasses available:"
kubectl --context k8s get storageclass 2>/dev/null || true
echo ""
echo "  Top events cluster-wide (last 10):"
kubectl --context k8s get events --all-namespaces --sort-by='.lastTimestamp' 2>/dev/null | tail -10

echo ""
echo "═══════════════════════════════════════════════════════════════════════"
echo "  Диагностика завершена. Пришлите вывод этого скрипта — определим причину."
echo "═══════════════════════════════════════════════════════════════════════"
