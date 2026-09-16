#!/usr/bin/env bash
# Deploy code-marketplace to AKS.
# Required env: ACR_NAME, BASE_DOMAIN, ARTIFACTORY_TOKEN
set -euo pipefail

SVC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.."; pwd)"
cd "$SVC_DIR"

# shellcheck source=../service.conf
source ./service.conf

: "${ACR_NAME:?Set ACR_NAME (e.g. govacrcompany)}"
: "${BASE_DOMAIN:?Set BASE_DOMAIN (e.g. apps.example.gov)}"
: "${ARTIFACTORY_TOKEN:?Set ARTIFACTORY_TOKEN}"

ISTIO_REV="$(jq -r '.istio.revision' service.json)"
SECRET_NAME="$(jq -r '.secrets[0].name' service.json)"

echo "── Namespace ──"
kubectl get ns "$NAMESPACE" >/dev/null 2>&1 \
  || kubectl create namespace "$NAMESPACE"
kubectl label namespace "$NAMESPACE" "istio.io/rev=$ISTIO_REV" --overwrite

echo "── Secret ──"
kubectl -n "$NAMESPACE" create secret generic "$SECRET_NAME" \
  --from-literal=token="$ARTIFACTORY_TOKEN" \
  --dry-run=client -o yaml | kubectl apply -f -

echo "── Render values.yaml ──"
# Pull in the exported vars (ACR_NAME, BASE_DOMAIN, ARTIFACTORY_SERVICENAME, etc.)
[[ -f ./.env ]] && source ./.env
RENDERED="$(mktemp -t values-rendered.XXXXXX.yaml)"
trap 'rm -f "$RENDERED"' EXIT
export ACR_NAME BASE_DOMAIN ARTIFACTORY_SERVICENAME HOST_PREFIX
envsubst '${ACR_NAME} ${BASE_DOMAIN} ${ARTIFACTORY_SERVICENAME} ${HOST_PREFIX}' < values.yaml > "$RENDERED"

echo "── Helm upgrade ──"
helm upgrade --install "$RELEASE_NAME" "$HELM_CHART_PATH" \
  -n "$NAMESPACE" \
  -f "$RENDERED" \
  --wait --timeout 5m

echo "── Rollout ──"
kubectl -n "$NAMESPACE" rollout status deployment/"$RELEASE_NAME" --timeout=5m

echo "✓ $SERVICE_NAME deployed to namespace=$NAMESPACE"
