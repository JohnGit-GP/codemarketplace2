#!/usr/bin/env bash
# Deploy the elastic stack to AKS.
# Required env: ACR_NAME, BASE_DOMAIN, ELASTIC_PASSWORD
set -euo pipefail

SVC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.."; pwd)"; cd "$SVC_DIR"
# shellcheck source=../service.conf
source ./service.conf

: "${ACR_NAME:?Set ACR_NAME}"
: "${BASE_DOMAIN:?Set BASE_DOMAIN (the Kibana hostname suffix)}"
: "${ELASTIC_PASSWORD:?Set ELASTIC_PASSWORD}"

ISTIO_REV="$(jq -r '.istio.revision' service.json)"
SECRET_NAME="$(jq -r '.secrets[0].name' service.json)"

echo "── Namespace ──"
kubectl get ns "$NAMESPACE" >/dev/null 2>&1 || kubectl create namespace "$NAMESPACE"
kubectl label namespace "$NAMESPACE" "istio.io/rev=$ISTIO_REV" --overwrite

echo "── Secret ──"
kubectl -n "$NAMESPACE" create secret generic "$SECRET_NAME" \
  --from-literal=username=elastic \
  --from-literal=password="$ELASTIC_PASSWORD" \
  --dry-run=client -o yaml | kubectl apply -f -

echo "── Render values ──"
[[ -f ./.env ]] && source ./.env
RENDERED="$(mktemp -t values-rendered.XXXXXX.yaml)"
trap 'rm -f "$RENDERED"' EXIT
export ACR_NAME BASE_DOMAIN
envsubst '${ACR_NAME} ${BASE_DOMAIN}' < values.yaml > "$RENDERED"

echo "── Install ──"
# TODO: fill in once the deployment method is decided.
#
#   ECK path:
#     kubectl apply -f manifests/eck-operator.yaml       # CRDs + operator
#     kubectl -n "$NAMESPACE" apply -f manifests/elasticsearch.yaml
#     kubectl -n "$NAMESPACE" apply -f manifests/kibana.yaml
#
#   Helm path:
#     helm upgrade --install "$ES_RELEASE_NAME" "$ES_CHART_REF" \
#       --version "$CHART_VERSION" -n "$NAMESPACE" -f "$RENDERED" --wait --timeout 10m
#     helm upgrade --install "$KIBANA_RELEASE_NAME" "$KIBANA_CHART_REF" \
#       --version "$CHART_VERSION" -n "$NAMESPACE" -f "$RENDERED" --wait --timeout 10m
#
# Elasticsearch is a StatefulSet with PVCs - a rolling restart is slow and a
# bad --wait timeout will abort mid-roll. Use 10m+, not the 5m used for
# stateless services.
echo "  NOT IMPLEMENTED - see TODO above"
exit 1

echo "── Rollout ──"
kubectl -n "$NAMESPACE" rollout status statefulset/"$ES_RELEASE_NAME"-es --timeout=10m
echo "✓ $SERVICE_NAME deployed to namespace=$NAMESPACE"
