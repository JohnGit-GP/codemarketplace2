#!/usr/bin/env bash
# Deploy the elastic stack to aks-1 in two stages:
#
#   ./scripts/deploy.sh operator   ECK CRDs + operator (once per cluster)         — ticket 1
#   ./scripts/deploy.sh stack      STRICT mTLS, storage, Elasticsearch, Kibana,
#                                  Istio gateway exposure                          — ticket 3
#   ./scripts/deploy.sh all        both, in order (default)
#   ./scripts/deploy.sh diff       read-only: show what `stack` would change (kubectl diff)
#
# TLS model: Elasticsearch serves ECK-managed HTTPS and runs outside the mesh (SAML needs
# HTTP TLS on). Kibana is in the mesh under STRICT mTLS and serves plain HTTP in the pod.
# The internal gateway terminates the Iguana certs and re-encrypts to ES with ECK's CA.
#
# Required env: ACR_NAME            (operator step)
# Optional env: LICENSE_FILE        Elastic Enterprise license JSON (ticket 7)
#               SAML_METADATA_FILE  Entra federation metadata XML — creates/updates the
#                                   entra-saml-metadata ConfigMap, which turns SAML on (ticket 7)
set -euo pipefail

SVC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.."; pwd)"; cd "$SVC_DIR"
# shellcheck source=../service.conf
source ./service.conf

STEP="${1:-all}"
ISTIO_REV="$(jq -r '.istio.revision' service.json)"

render() {
  export ES_NAME KIBANA_NAME NAMESPACE STACK_VERSION ES_NODE_COUNT ES_DISK_SIZE ES_MEMORY \
         STORAGE_CLASS KIBANA_HOST ES_HOST ISTIO_INGRESS_SELECTOR SAML_ENABLED SAML_IDP_ENTITY_ID
  envsubst '${ES_NAME} ${KIBANA_NAME} ${NAMESPACE} ${STACK_VERSION} ${ES_NODE_COUNT} ${ES_DISK_SIZE} ${ES_MEMORY} ${STORAGE_CLASS} ${KIBANA_HOST} ${ES_HOST} ${ISTIO_INGRESS_SELECTOR} ${SAML_ENABLED} ${SAML_IDP_ENTITY_ID}' < "$1"
}

# Wait until ECK has acted on the latest spec (not just the old, still-green state) and the
# resource is green. A spec change to ES triggers a rolling restart, one node at a time.
wait_ready() {
  local kind="$1" name="$2" timeout_s="$3" gen og phase health
  gen="$(kubectl -n "$NAMESPACE" get "$kind/$name" -o jsonpath='{.metadata.generation}')"
  for (( t = 0; t < timeout_s; t += 10 )); do
    IFS='|' read -r og health phase < <(kubectl -n "$NAMESPACE" get "$kind/$name" \
      -o jsonpath='{.status.observedGeneration}|{.status.health}|{.status.phase}{"\n"}')
    if [[ "${og:-$gen}" == "$gen" && "$health" == green && "${phase:-Ready}" == Ready ]]; then
      echo "  $kind/$name green"; return 0
    fi
    sleep 10
  done
  echo "$kind/$name not green after ${timeout_s}s — run ./scripts/check-status.sh" >&2; exit 1
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

# Sets SAML_IDP_ENTITY_ID / SAML_ENABLED. The entity ID is read from the stored metadata, so
# re-runs need no extra input; `diff` reads SAML_METADATA_FILE directly instead (no writes).
saml_inputs() {
  local src
  if [[ "$STEP" == diff && -n "${SAML_METADATA_FILE:-}" ]]; then
    src="$(cat "$SAML_METADATA_FILE")"
  else
    src="$(kubectl -n "$NAMESPACE" get configmap entra-saml-metadata \
      -o jsonpath='{.data.entra-metadata\.xml}' 2>/dev/null || true)"
  fi
  SAML_IDP_ENTITY_ID="$(grep -o 'entityID="[^"]*"' <<<"$src" | head -1 | cut -d'"' -f2 || true)"
  if [[ -n "$SAML_IDP_ENTITY_ID" ]]; then
    SAML_ENABLED=true;  echo "  SAML enabled — IdP $SAML_IDP_ENTITY_ID"
  else
    SAML_ENABLED=false; echo "  SAML disabled — no entra-saml-metadata ConfigMap (set SAML_METADATA_FILE)"
  fi
}

# Read-only preview of `stack`. Unchanged objects print nothing. A diff under spec.nodeSets or
# spec.http means an Elasticsearch rolling restart; under spec.config/podTemplate on Kibana, a
# Kibana restart (seconds of UI downtime with one replica).
show_diff() {
  command -v envsubst >/dev/null || { echo "envsubst not found — install the gettext package" >&2; exit 1; }
  saml_inputs
  if [[ -n "${SAML_METADATA_FILE:-}" ]]; then
    echo "── entra-saml-metadata ConfigMap ──"
    kubectl -n "$NAMESPACE" create configmap entra-saml-metadata \
      --from-file=entra-metadata.xml="$SAML_METADATA_FILE" --dry-run=client -o yaml | kubectl diff -f - || true
  fi
  for f in peerauthentication elasticsearch kibana istio; do
    echo "── $f ──"
    render "manifests/$f.yaml" | kubectl diff -f - || true
  done
}

install_stack() {
  echo "── Preflight ──"
  command -v envsubst >/dev/null \
    || { echo "envsubst not found — install the gettext package" >&2; exit 1; }
  kubectl get crd elasticsearches.elasticsearch.k8s.elastic.co >/dev/null 2>&1 \
    || { echo "ECK CRDs not installed — run: ./scripts/deploy.sh operator" >&2; exit 1; }
  kubectl -n "$OPERATOR_NAMESPACE" rollout status statefulset/elastic-operator --timeout=2m >/dev/null \
    || { echo "ECK operator not ready — run: ./scripts/deploy.sh operator" >&2; exit 1; }

  echo "── Namespace + STRICT mTLS ──"
  kubectl get ns "$NAMESPACE" >/dev/null 2>&1 || kubectl create namespace "$NAMESPACE"
  kubectl label namespace "$NAMESPACE" "istio.io/rev=$ISTIO_REV" --overwrite
  # Before any workload: Kibana serves plain HTTP in its pod, so STRICT must already be in force.
  render manifests/peerauthentication.yaml | kubectl apply -f -

  echo "── StorageClass ──"
  kubectl apply -f manifests/storageclass.yaml
  kubectl get storageclass "$STORAGE_CLASS" >/dev/null \
    || { echo "StorageClass $STORAGE_CLASS not found" >&2; exit 1; }

  echo "── SAML (Entra ID) ──"
  if [[ -n "${SAML_METADATA_FILE:-}" ]]; then
    grep -q 'entityID=' "$SAML_METADATA_FILE" \
      || { echo "$SAML_METADATA_FILE is not SAML federation metadata" >&2; exit 1; }
    kubectl -n "$NAMESPACE" create configmap entra-saml-metadata \
      --from-file=entra-metadata.xml="$SAML_METADATA_FILE" --dry-run=client -o yaml | kubectl apply -f -
  fi
  saml_inputs

  echo "── Elasticsearch ──"
  render manifests/elasticsearch.yaml | kubectl apply -f -
  # StatefulSet with PVCs: first rollout and rolling restarts are slow.
  wait_ready elasticsearch "$ES_NAME" 1800

  echo "── Kibana ──"
  render manifests/kibana.yaml | kubectl apply -f -
  wait_ready kibana "$KIBANA_NAME" 600

  echo "── Istio exposure ──"
  # The internal gateway is shared with other services. Don't hand it a Gateway whose
  # certificates don't exist yet — apply only once both secrets are present, then re-run.
  local missing=()
  for s in kibana-tls elasticsearch-tls; do
    kubectl -n aks-istio-ingress get secret "$s" >/dev/null 2>&1 || missing+=("$s")
  done
  if (( ${#missing[@]} )); then
    echo "  skipped — missing in aks-istio-ingress: ${missing[*]}"
    echo "  create the TLS secrets (ticket 4), then re-run: ./scripts/deploy.sh stack"
  else
    # The gateway re-encrypts to ES and verifies it against ECK's HTTP CA. ECK rotates that
    # CA (1-year validity), so refresh the copy on every run.
    local ca
    ca="$(kubectl -n "$NAMESPACE" get secret "${ES_NAME}-es-http-certs-public" -o jsonpath='{.data.ca\.crt}')"
    [[ -n "$ca" ]] || { echo "ECK HTTP CA not found (${ES_NAME}-es-http-certs-public)" >&2; exit 1; }
    kubectl -n aks-istio-ingress create secret generic elasticsearch-es-ca \
      --from-literal=ca.crt="$(base64 -d <<<"$ca")" --dry-run=client -o yaml | kubectl apply -f -
    render manifests/istio.yaml | kubectl apply -f -
  fi

  echo "✓ Elasticsearch + Kibana deployed to $CLUSTER namespace=$NAMESPACE"
}

case "$STEP" in
  operator) install_operator ;;
  stack)    install_stack ;;
  diff)     show_diff ;;
  all)      install_operator; install_stack ;;
  *) echo "usage: $0 [operator|stack|all|diff]" >&2; exit 1 ;;
esac
