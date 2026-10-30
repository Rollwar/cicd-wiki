#!/usr/bin/env bash
# scripts/bootstrap.sh — первичная установка wiki.js в namespace.
#
# Применяет все базовые манифесты + рендерит deployment-slot.yaml с указанным
# образом в качестве BLUE слота. После этого можно запускать CI/CD пайплайн —
# он будет создавать GREEN и переключать traffic.
#
# Usage:
#   bash scripts/bootstrap.sh <namespace> <image-ref> [istio-manifest]
#
# Examples:
#   bash scripts/bootstrap.sh wiki-staging ghcr.io/rollwar/wiki:latest
#   bash scripts/bootstrap.sh wiki-production ghcr.io/rollwar/wiki:v2.5.0 deploy/istio/wiki-prod.yaml
#
# Если третий аргумент не указан, istio-манифест выбирается по namespace:
#   wiki-production → deploy/istio/wiki-prod.yaml
#   wiki-staging    → deploy/istio/wiki-stage.yaml
set -euo pipefail

NAMESPACE="${1:?usage: bootstrap.sh <namespace> <image-ref> [istio-manifest]}"
IMAGE="${2:?usage: bootstrap.sh <namespace> <image-ref> [istio-manifest]}"
ISTIO="${3:-}"

# Resolve script directory (works regardless of CWD)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"

# Auto-detect istio manifest if not specified
# По умолчанию выбираем по имени namespace:
#   wiki-production → deploy/istio/wiki-prod.yaml (хост wiki.k8s-9.sa)
#   wiki-staging    → deploy/istio/wiki-stage.yaml (хост wiki-stage.k8s-9.sa)
# Для других namespace — пользователь должен передать файл третьим аргументом.
if [ -z "$ISTIO" ]; then
  case "$NAMESPACE" in
    wiki-production) ISTIO="deploy/istio/wiki-prod.yaml" ;;
    wiki-staging|*)  ISTIO="deploy/istio/wiki-stage.yaml" ;;
  esac
fi

# Проверяем, что istio-манифест существует
if [ ! -f "$ISTIO" ]; then
  echo "[bootstrap] ⚠️  Istio manifest $ISTIO не найден — пропускаю"
  ISTIO=""
fi

echo "┌────────────────────────────────────────────────────────────────┐"
echo "│  Bootstrap wiki.js                                            │"
echo "├────────────────────────────────────────────────────────────────┤"
echo "│  Namespace:  $NAMESPACE"
echo "│  Image:      $IMAGE"
echo "│  Istio:      $ISTIO"
echo "└────────────────────────────────────────────────────────────────┘"

# 1. Создать namespace (если ещё нет)
kubectl --context k8s apply -f deploy/k8s/namespace.yaml

# 2. Применить конфиг-манифесты (без плейсхолдеров — применяются как есть)
echo "[bootstrap] applying configmap, secret, pvc, postgres, services..."
kubectl --context k8s -n "$NAMESPACE" apply -f deploy/k8s/configmap.yaml
kubectl --context k8s -n "$NAMESPACE" apply -f deploy/k8s/secret.yaml
kubectl --context k8s -n "$NAMESPACE" apply -f deploy/k8s/pvc.yaml
kubectl --context k8s -n "$NAMESPACE" apply -f deploy/k8s/postgres.yaml
kubectl --context k8s -n "$NAMESPACE" apply -f deploy/k8s/service.yaml
kubectl --context k8s -n "$NAMESPACE" apply -f deploy/k8s/service-preview.yaml
# ingress.yaml удалён — вместо него используется Istio Gateway + VirtualService

# 3. Рендер deployment-slot.yaml → blue.yaml с подставленным образом
echo "[bootstrap] rendering wiki-blue deployment with image=$IMAGE..."
sed -e "s|__IMAGE__|$IMAGE|g" \
    -e "s|__SLOT__|blue|g" \
    deploy/k8s/deployment-slot.yaml > /tmp/wiki-blue.yaml

# 4. Применить отрендеренный blue deployment
kubectl --context k8s -n "$NAMESPACE" apply -f /tmp/wiki-blue.yaml
kubectl --context k8s -n "$NAMESPACE" rollout status deployment/wiki-blue --timeout=300s

# 5. Istio (опционально — если CRD есть в кластере и манифест существует)
if [ -z "$ISTIO" ]; then
  echo "[bootstrap] ⚠️  Istio manifest не указан — пропускаю"
elif ! kubectl --context k8s get crd gateways.networking.istio.io >/dev/null 2>&1; then
  echo "[bootstrap] ⚠️  Istio CRD не найден — пропускаю $ISTIO"
  echo "              Установите istio: https://istio.io/latest/docs/setup/install/"
else
  echo "[bootstrap] applying istio manifest $ISTIO..."
  # Istio-манифесты содержат metadata.namespace внутри, поэтому применяются без -n
  # Файл $ISTIO уже содержит правильный namespace (wiki-stage.yaml → wiki-staging, и т.д.)
  kubectl --context k8s apply -f "$ISTIO"
fi

# 6. Итоговая сводка
echo ""
echo "✅ Bootstrap завершён в namespace=$NAMESPACE"
echo ""
echo "Ресурсы:"
kubectl --context k8s -n "$NAMESPACE" get deploy,sts,svc,cm,secret,pvc 2>/dev/null
echo ""
echo "Istio ресурсы:"
kubectl --context k8s -n "$NAMESPACE" get gateway,virtualservice,destinationrule 2>/dev/null || echo "  (istio не установлен или манифест не применён)"
echo ""
echo "Дальнейшие релизы — через GitHub Actions (CI → CD blue-green)."
echo "Ручной blue-green: bash scripts/blue-green-deploy.sh $IMAGE $NAMESPACE"
echo "Откат:              bash scripts/rollback.sh $NAMESPACE"
