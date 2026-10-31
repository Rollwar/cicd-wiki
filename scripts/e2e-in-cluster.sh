#!/usr/bin/env bash
# scripts/e2e-in-cluster.sh — запускает E2E тесты ИЗНУТРИ кластера,
# через временный debug-pod с curl+jq.

set -euo pipefail

NAMESPACE="${1:?usage: e2e-in-cluster.sh <namespace> <service-name> [report-dir]}"
SERVICE="${2:?usage: e2e-in-cluster.sh <namespace> <service-name> [report-dir]}"
REPORT_DIR="${3:-/tmp/e2e-report}"

# Полное DNS-имя сервиса внутри кластера
WIKI_URL="http://${SERVICE}.${NAMESPACE}.svc.cluster.local"

# Уникальное имя pod'а
POD_NAME="wiki-e2e-test-$(date +%s)-$RANDOM"

echo "[e2e-in-cluster] namespace=$NAMESPACE  service=$SERVICE"
echo "[e2e-in-cluster] WIKI_URL=$WIKI_URL"
echo "[e2e-in-cluster] pod=$POD_NAME"

# Используем образ с curl + jq. Альпиний легкий (5MB), jq добавляем через apk.
# curlimages/curl НЕ имеет jq, поэтому берём alpine + ставим curl jq.
IMAGE="alpine:3.20"

# 1. Создать pod с alpine, установить curl и jq
echo "[e2e-in-cluster] creating debug pod $POD_NAME ..."
kubectl --context k8s -n "$NAMESPACE" run "$POD_NAME" \
  --image="$IMAGE" \
  --restart=Never \
  --command -- sleep 600 \
  --limits=cpu=200m,memory=128Mi \
  --overrides='{
    "metadata": {
      "labels": {
        "app.kubernetes.io/name": "e2e-test",
        "app.kubernetes.io/managed-by": "ci-pipeline"
      }
    }
  }'

# Ждём, пока pod станет Ready
echo "[e2e-in-cluster] waiting for pod to be Ready..."
kubectl --context k8s -n "$NAMESPACE" wait --for=condition=Ready "pod/$POD_NAME" --timeout=120s

# Установить curl и jq
echo "[e2e-in-cluster] installing curl + jq in pod ..."
kubectl --context k8s -n "$NAMESPACE" exec "$POD_NAME" -- \
  sh -c 'apk add --no-cache curl jq bash 2>&1 | tail -1'

# 2. Копировать тестовый скрипт в pod
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEST_SCRIPT="$SCRIPT_DIR/../tests/e2e/run.sh"

if [ ! -f "$TEST_SCRIPT" ]; then
  echo "[e2e-in-cluster] ERROR: test script not found at $TEST_SCRIPT"
  kubectl --context k8s -n "$NAMESPACE" delete pod "$POD_NAME" --ignore-not-found
  exit 1
fi

echo "[e2e-in-cluster] copying test script to pod ..."
kubectl --context k8s -n "$NAMESPACE" cp "$TEST_SCRIPT" "${POD_NAME}:/tmp/run.sh"

# 3. Создать директорию для отчёта внутри pod
kubectl --context k8s -n "$NAMESPACE" exec "$POD_NAME" -- mkdir -p /tmp/report

# 4. Запустить тесты с правильным WIKI_URL
echo ""
echo "═══ E2E TEST (in-cluster, against $WIKI_URL) ═══"
kubectl --context k8s -n "$NAMESPACE" exec "$POD_NAME" -- \
  env WIKI_URL="$WIKI_URL" REPORT_DIR=/tmp/report bash /tmp/run.sh || TEST_EXIT=$?
TEST_EXIT=${TEST_EXIT:-0}

# 5. Скопировать отчёт обратно на runner
echo ""
echo "[e2e-in-cluster] copying report back to runner ..."
mkdir -p "$REPORT_DIR"
kubectl --context k8s -n "$NAMESPACE" cp "${POD_NAME}:/tmp/report/." "$REPORT_DIR" 2>/dev/null || true

# 6. Показать summary
if [ -f "$REPORT_DIR/summary.md" ]; then
  echo ""
  echo "─── Report ───"
  cat "$REPORT_DIR/summary.md"
fi

# 7. Удалить debug pod
echo ""
echo "[e2e-in-cluster] cleaning up pod $POD_NAME ..."
kubectl --context k8s -n "$NAMESPACE" delete pod "$POD_NAME" --ignore-not-found

echo "[e2e-in-cluster] ✓ Done. Test exit code: $TEST_EXIT"
exit $TEST_EXIT
