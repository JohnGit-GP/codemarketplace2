#!/usr/bin/env bash
# Deploy the elastic stack to aks-1 in two stages:
#
#   ./scripts/deploy.sh operator   ECK CRDs + operator (once per cluster)         — ticket 1
#   ./scripts/deploy.sh stack      STRICT mTLS, storage, Elasticsearch, Kibana,
#                                  Istio gateway exposure                          — ticket 3
#   ./scripts/deploy.sh all        both, in order (default)
#
# TLS model: ECK HTTP TLS is OFF. Istio mTLS (STRICT in the elastic namespace) encrypts
# everything in the mesh; the internal gateway terminates TLS at the edge. The operator must
# therefore be in the mesh too, or STRICT would lock it out of Elasticsearch.
#
# Required env: ACR_NAME            (operator step)
# Optional env: LICENSE_FILE        Elastic Enterprise license JSON — required before SAML
set -euo pipefail

SVC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.."; pwd)"; cd "$SVC_DIR"
# shellcheck source=../service.conf
source ./service.conf

STEP="${1:-all}"
ISTIO_REV="$(jq -r '.istio.revision' service.json)"

render() {
  export ES_NAME KIBANA_NAME NAMESPACE STACK_VERSION ES_NODE_COUNT ES_DISK_SIZE ES_MEMORY \
         STORAGE_CLASS KIBANA_HOST ES_HOST ISTIO_INGRESS_SELECTOR
  envsubst '${ES_NAME} ${KIBANA_NAME} ${NAMESPACE} ${STACK_VERSION} ${ES_NODE_COUNT} ${ES_DISK_SIZE} ${ES_MEMORY} ${STORAGE_CLASS} ${KIBANA_HOST} ${ES_HOST} ${ISTIO_INGRESS_SELECTOR}' < "$1"
}

install_operator() {
  : "${ACR_NAME:?Set ACR_NAME (no .azurecr.us)}"
  ACR_NAME="${ACR_NAME,,}"   # login servers are lowercase; mixed case breaks image refs
  local registry="$ACR_NAME.azurecr.us"

  for f in cache/eck-crds.yaml cache/eck-operator.yaml; do
    [[ -f "$f" ]] || { echo "Missing $f — run mirror-images.sh pull on the connected side" >&2; exit 1; }
  done

  echo "── ECK CRDs ──"
  # Server-side apply: the CRDs exceed the size limit of client-side apply's annotation.
  kubectl apply --server-side -f cache/eck-crds.yaml

  echo "── ECK operator ($ECK_VERSION) ──"
  # Rewriting docker.elastic.co covers both the operator image and its container-registry
  # setting, so every stack image resolves to the Gov ACR.
  sed "s#docker\.elastic\.co#${registry}#g" cache/eck-operator.yaml | kubectl apply -f -
  kubectl -n "$OPERATOR_NAMESPACE" get cm elastic-operator -o yaml | grep -q "container-registry: ${registry}" \
    || { echo "Operator container-registry is not ${registry}" >&2; exit 1; }

  echo "── Operator into the mesh ──"
  # STRICT mTLS on the elastic namespace rejects plaintext, so the operator needs a sidecar
  # to reach Elasticsearch. Its admission webhook (9443) is called by the Kubernetes API
  # server, which is NOT in the mesh — exclude that port or every ECK apply is rejected.
  kubectl label namespace "$OPERATOR_NAMESPACE" "istio.io/rev=$ISTIO_REV" --overwrite
  kubectl -n "$OPERATOR_NAMESPACE" patch statefulset elastic-operator --type merge -p \
    '{"spec":{"template":{"metadata":{"annotations":{"traffic.sidecar.istio.io/excludeInboundPorts":"9443"}}}}}'
  kubectl -n "$OPERATOR_NAMESPACE" rollout status statefulset/elastic-operator --timeout=5m

  if [[ -n "${LICENSE_FILE:-}" ]]; then
    echo "── License ──"
    kubectl -n "$OPERATOR_NAMESPACE" create secret generic eck-license \
      --from-file=license="$LICENSE_FILE" --dry-run=client -o yaml | kubectl apply -f -
    kubectl -n "$OPERATOR_NAMESPACE" label secret eck-license \
      license.k8s.elastic.co/scope=operator --overwrite
  fi

  echo "✓ ECK operator ready in $OPERATOR_NAMESPACE"
}

install_stack() {
  echo "── Preflight: operator present ──"
  kubectl get crd elasticsearches.elasticsearch.k8s.elastic.co >/dev/null 2>&1 \
    || { echo "ECK CRDs not installed — run: ./scripts/deploy.sh operator" >&2; exit 1; }
  kubectl -n "$OPERATOR_NAMESPACE" rollout status statefulset/elastic-operator --timeout=2m >/dev/null \
    || { echo "ECK operator not ready — run: ./scripts/deploy.sh operator" >&2; exit 1; }

  echo "── Namespace + STRICT mTLS ──"
  kubectl get ns "$NAMESPACE" >/dev/null 2>&1 || kubectl create namespace "$NAMESPACE"
  kubectl label namespace "$NAMESPACE" "istio.io/rev=$ISTIO_REV" --overwrite
  # Before any workload: ES and Kibana serve plain HTTP, so STRICT must already be in force.
  render manifests/peerauthentication.yaml | kubectl apply -f -

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

  echo "── Istio exposure ──"
  for s in kibana-tls elasticsearch-tls; do
    kubectl -n aks-istio-ingress get secret "$s" >/dev/null 2>&1 \
      || echo "  ⚠ secret $s missing in aks-istio-ingress — gateway will fail TLS for that host (ticket 2)"
  done
  render manifests/istio.yaml | kubectl apply -f -

  echo "✓ Elasticsearch + Kibana deployed to $CLUSTER namespace=$NAMESPACE"
}

case "$STEP" in
  operator) install_operator ;;
  stack)    install_stack ;;
  all)      install_operator; install_stack ;;
  *) echo "usage: $0 [operator|stack|all]" >&2; exit 1 ;;
esac
