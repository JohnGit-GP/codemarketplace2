#!/usr/bin/env bash
# Deploy the ECK operator, license, Elasticsearch, and Kibana to aks-1.
# Required env: ACR_NAME   (STORAGE_CLASS defaults from service.conf)
# Optional env: LICENSE_FILE (Elastic Enterprise license JSON — required before SAML)
set -euo pipefail

SVC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.."; pwd)"; cd "$SVC_DIR"
# shellcheck source=../service.conf
source ./service.conf

: "${ACR_NAME:?Set ACR_NAME (no .azurecr.us)}"
REGISTRY="$ACR_NAME.azurecr.us"
ISTIO_REV="$(jq -r '.istio.revision' service.json)"

for f in cache/eck-crds.yaml cache/eck-operator.yaml; do
  [[ -f "$f" ]] || { echo "Missing $f — run mirror-images.sh pull on the connected side" >&2; exit 1; }
done

echo "── ECK CRDs ──"
# Server-side apply: the CRDs exceed the size limit of client-side apply's annotation.
kubectl apply --server-side -f cache/eck-crds.yaml

echo "── ECK operator ($ECK_VERSION) ──"
# Rewriting docker.elastic.co covers both the operator image and the operator's
# container-registry setting, so every stack image resolves to the Gov ACR.
# The operator namespace is NOT mesh-injected (PERMISSIVE mTLS; see README decision 1).
sed "s#docker\.elastic\.co#${REGISTRY}#g" cache/eck-operator.yaml | kubectl apply -f -
grep -q "container-registry: ${REGISTRY}" <(kubectl -n "$OPERATOR_NAMESPACE" get cm elastic-operator -o yaml) \
  || { echo "Operator container-registry is not ${REGISTRY}" >&2; exit 1; }
kubectl -n "$OPERATOR_NAMESPACE" rollout status statefulset/elastic-operator --timeout=5m

if [[ -n "${LICENSE_FILE:-}" ]]; then
  echo "── License ──"
  kubectl -n "$OPERATOR_NAMESPACE" create secret generic eck-license \
    --from-file=license="$LICENSE_FILE" --dry-run=client -o yaml | kubectl apply -f -
  kubectl -n "$OPERATOR_NAMESPACE" label secret eck-license \
    license.k8s.elastic.co/scope=operator --overwrite
fi

echo "── Namespace ──"
kubectl get ns "$NAMESPACE" >/dev/null 2>&1 || kubectl create namespace "$NAMESPACE"
kubectl label namespace "$NAMESPACE" "istio.io/rev=$ISTIO_REV" --overwrite

render() {
  export ES_NAME KIBANA_NAME NAMESPACE STACK_VERSION ES_NODE_COUNT ES_DISK_SIZE \
         ES_MEMORY STORAGE_CLASS KIBANA_HOST ES_INGEST_HOST
  envsubst '${ES_NAME} ${KIBANA_NAME} ${NAMESPACE} ${STACK_VERSION} ${ES_NODE_COUNT} ${ES_DISK_SIZE} ${ES_MEMORY} ${STORAGE_CLASS} ${KIBANA_HOST} ${ES_INGEST_HOST}' < "$1"
}

echo "── StorageClass ──"
kubectl apply -f manifests/storageclass.yaml
kubectl get storageclass "$STORAGE_CLASS" >/dev/null \
  || { echo "StorageClass $STORAGE_CLASS not found" >&2; exit 1; }

echo "── Elasticsearch ──"
render manifests/elasticsearch.yaml | kubectl apply -f -
# StatefulSet with PVCs: first rollout and rolling restarts are slow.
kubectl -n "$NAMESPACE" wait --for=jsonpath='{.status.health}'=green \
  "elasticsearch/$ES_NAME" --timeout=20m

echo "── Kibana ──"
render manifests/kibana.yaml | kubectl apply -f -
kubectl -n "$NAMESPACE" wait --for=jsonpath='{.status.health}'=green \
  "kibana/$KIBANA_NAME" --timeout=10m

if [[ -f manifests/istio.yaml ]]; then
  echo "── Istio exposure ──"
  render manifests/istio.yaml | kubectl apply -f -
else
  echo "── Istio exposure: skipped (manifests/istio.yaml pending README decision 1) ──"
fi

echo "✓ $SERVICE_NAME deployed to $CLUSTER namespace=$NAMESPACE"
