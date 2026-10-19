#!/usr/bin/env bash
# Deploy the elastic stack to aks-1 in two stages:
#
#   ./scripts/deploy.sh operator   ECK CRDs + operator (once per cluster)         — ticket 1
#   ./scripts/deploy.sh stack      STRICT mTLS, storage, Elasticsearch, Kibana,
#                                  Istio gateway exposure                          — ticket 3
#   ./scripts/deploy.sh all        both, in order (default)
#   ./scripts/deploy.sh heartbeat  uptime checks from manifests/heartbeat-monitors.yml — ticket 6
#                                  (re-run after editing the monitor list; see HEARTBEAT.md)
#   ./scripts/deploy.sh metricbeat node/pod/container metrics on aks-1 (DaemonSet)  — ticket 6
#   ./scripts/deploy.sh azure      Azure Monitor metrics (needs secret azure-metrics-sp) — ticket 6
#   ./scripts/deploy.sh spoke <kubectl-context> <cluster-name>
#                                  Metricbeat on a spoke (atl-aks, gl-aks), plain manifests
#   ./scripts/deploy.sh diff       read-only: show what `stack` and `heartbeat` would change
#
# TLS model: Elasticsearch serves ECK-managed HTTPS and runs outside the mesh (SAML needs
# HTTP TLS on). Kibana is in the mesh under STRICT mTLS and serves plain HTTP in the pod.
# The internal gateway terminates the Iguana certs and re-encrypts to ES with ECK's CA.
#
# Required env: ACR_NAME            (operator step)
# Optional env: LICENSE_FILE        Elastic Enterprise license JSON (ticket 7)
#               SAML_METADATA_FILE  Entra federation metadata XML — creates/updates the
#                                   entra-saml-metadata ConfigMap, which turns SAML on (ticket 7)
#               HEARTBEAT_CA_FILE   PEM bundle of every CA the uptime checks must trust; required
#                                   on the first `heartbeat` run, optional after (secret is kept)
#               SPOKE_API_KEY_FILE  file holding the spoke's "id:api_key"; first `spoke` run only
#               SPOKE_CA_FILE       PEM bundle with the Iguana CA; first `spoke` run only
set -euo pipefail

SVC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.."; pwd)"; cd "$SVC_DIR"
# shellcheck source=../service.conf
source ./service.conf

STEP="${1:-all}"
ISTIO_REV="$(jq -r '.istio.revision' service.json)"

render() {
  export ES_NAME KIBANA_NAME NAMESPACE STACK_VERSION ES_NODE_COUNT ES_DISK_SIZE ES_MEMORY \
         STORAGE_CLASS KIBANA_HOST ES_HOST ISTIO_INGRESS_SELECTOR SAML_ENABLED SAML_IDP_ENTITY_ID CLUSTER \
         SPOKE_NAMESPACE SPOKE_CLUSTER BEATS_IMAGE
  envsubst '${ES_NAME} ${KIBANA_NAME} ${NAMESPACE} ${STACK_VERSION} ${ES_NODE_COUNT} ${ES_DISK_SIZE} ${ES_MEMORY} ${STORAGE_CLASS} ${KIBANA_HOST} ${ES_HOST} ${ISTIO_INGRESS_SELECTOR} ${SAML_ENABLED} ${SAML_IDP_ENTITY_ID} ${CLUSTER} ${SPOKE_NAMESPACE} ${SPOKE_CLUSTER} ${BEATS_IMAGE}' < "$1"
}

# ECK can report Ready/green for a moment after accepting a new spec, before it restarts any
# pod. For Elasticsearch, also require every StatefulSet pod to be on the current template.
rollout_done() {
  [[ "$1" == elasticsearch ]] || return 0
  local bad
  bad="$(kubectl -n "$NAMESPACE" get statefulset -l "elasticsearch.k8s.elastic.co/cluster-name=$2" \
    -o jsonpath='{range .items[*]}{.spec.replicas}/{.status.updatedReplicas}/{.status.readyReplicas}{"\n"}{end}' \
    | awk -F/ '$1 != $2 || $1 != $3')"
  [[ -z "$bad" ]]
}

# Wait until ECK has acted on the latest spec (not just the old, still-green state) and the
# resource is green. A spec change to ES triggers a rolling restart, one node at a time.
wait_ready() {
  local kind="$1" name="$2" timeout_s="$3" gen og phase health
  gen="$(kubectl -n "$NAMESPACE" get "$kind/$name" -o jsonpath='{.metadata.generation}')"
  for (( t = 0; t < timeout_s; t += 10 )); do
    IFS='|' read -r og health phase < <(kubectl -n "$NAMESPACE" get "$kind/$name" \
      -o jsonpath='{.status.observedGeneration}|{.status.health}|{.status.phase}{"\n"}')
    if [[ "${og:-$gen}" == "$gen" && "$health" == green && "${phase:-Ready}" == Ready ]] \
       && rollout_done "$kind" "$name"; then
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
  echo "── heartbeat monitors ──"
  monitors_configmap | kubectl diff -f - || true
  echo "── heartbeat ──"
  render manifests/heartbeat.yaml | kubectl diff -f - || true
  echo "── metricbeat ──"
  render manifests/metricbeat.yaml | kubectl diff -f - || true
  echo "── metricbeat-azure ──"
  render manifests/metricbeat-azure.yaml | kubectl diff -f - || true
}

monitors_configmap() {
  kubectl -n "$NAMESPACE" create configmap heartbeat-monitors \
    --from-file=monitors.yml=manifests/heartbeat-monitors.yml --dry-run=client -o yaml
}

# Catch the mistakes Heartbeat would otherwise only report in its own log: bad YAML,
# duplicate or missing ids, an entry without a schedule or target.
check_monitors() {
  command -v python3 >/dev/null || { echo "  (python3 not found — skipping monitor file check)"; return 0; }
  python3 -I - manifests/heartbeat-monitors.yml <<'PY'
import sys, yaml
mons = yaml.safe_load(open(sys.argv[1])) or []
errs, seen = [], set()
for i, m in enumerate(mons, 1):
    mid = (m or {}).get("id")
    if not mid: errs.append(f"entry {i}: no id")
    elif mid in seen: errs.append(f"duplicate id: {mid}")
    seen.add(mid)
    for key in ("type", "schedule"):
        if key not in (m or {}): errs.append(f"{mid or i}: no {key}")
    if not ((m or {}).get("urls") or (m or {}).get("hosts")): errs.append(f"{mid or i}: no urls/hosts")
if errs: sys.exit("monitor file errors:\n  " + "\n  ".join(errs))
print(f"  {len(mons)} monitors OK")
PY
}

install_heartbeat() {
  echo "── Preflight ──"
  command -v envsubst >/dev/null || { echo "envsubst not found — install the gettext package" >&2; exit 1; }
  kubectl get crd beats.beat.k8s.elastic.co >/dev/null 2>&1 \
    || { echo "ECK Beat CRD missing — run: ./scripts/deploy.sh operator" >&2; exit 1; }
  kubectl -n "$NAMESPACE" get elasticsearch "$ES_NAME" >/dev/null 2>&1 \
    || { echo "Elasticsearch not deployed — run: ./scripts/deploy.sh stack" >&2; exit 1; }
  check_monitors

  echo "── CA bundle ──"
  if [[ -n "${HEARTBEAT_CA_FILE:-}" ]]; then
    grep -q 'BEGIN CERTIFICATE' "$HEARTBEAT_CA_FILE" \
      || { echo "$HEARTBEAT_CA_FILE has no PEM certificates" >&2; exit 1; }
    kubectl -n "$NAMESPACE" create secret generic heartbeat-ca \
      --from-file=ca-bundle.pem="$HEARTBEAT_CA_FILE" --dry-run=client -o yaml | kubectl apply -f -
  elif kubectl -n "$NAMESPACE" get secret heartbeat-ca >/dev/null 2>&1; then
    echo "  keeping existing heartbeat-ca (set HEARTBEAT_CA_FILE to replace it)"
  else
    echo "First run: set HEARTBEAT_CA_FILE to a PEM bundle with the Iguana CA (see HEARTBEAT.md)" >&2; exit 1
  fi

  echo "── Monitors ──"
  monitors_configmap | kubectl apply -f -

  echo "── Heartbeat ──"
  render manifests/heartbeat.yaml | kubectl apply -f -
  wait_ready beat heartbeat 300

  echo "✓ Heartbeat running on $CLUSTER — monitor changes are picked up within ~2 minutes"
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

install_metricbeat() {
  echo "── Preflight ──"
  command -v envsubst >/dev/null || { echo "envsubst not found — install the gettext package" >&2; exit 1; }
  kubectl get crd beats.beat.k8s.elastic.co >/dev/null 2>&1 \
    || { echo "ECK Beat CRD missing — run: ./scripts/deploy.sh operator" >&2; exit 1; }
  kubectl -n "$NAMESPACE" get elasticsearch "$ES_NAME" >/dev/null 2>&1 \
    || { echo "Elasticsearch not deployed — run: ./scripts/deploy.sh stack" >&2; exit 1; }

  echo "── Metricbeat ──"
  render manifests/metricbeat.yaml | kubectl apply -f -

  # Not wait_ready: on a node with no free pod slot the DaemonSet pod stays Pending until a
  # slot is freed by hand, so "green" may never come on its own. Report instead.
  echo "  waiting 90s for pods to schedule..."
  sleep 90
  kubectl -n "$NAMESPACE" get beat metricbeat
  local pending
  pending="$(kubectl -n "$NAMESPACE" get pods -l beat.k8s.elastic.co/name=metricbeat \
    --field-selector=status.phase=Pending -o jsonpath='{range .items[*]}{.metadata.name}{" -> "}{.spec.affinity.nodeAffinity.requiredDuringSchedulingIgnoredDuringExecution.nodeSelectorTerms[0].matchFields[0].values[0]}{"\n"}{end}')"
  if [[ -n "$pending" ]]; then
    echo "  Pending (node has no free pod slot) — free one slot per node, elastic.md \"Ticket 6 — Metricbeat\":"
    sed 's/^/    /' <<<"$pending"
  else
    echo "✓ Metricbeat running on every node of $CLUSTER"
  fi
}

install_azure() {
  echo "── Preflight ──"
  command -v envsubst >/dev/null || { echo "envsubst not found — install the gettext package" >&2; exit 1; }
  kubectl -n "$NAMESPACE" get elasticsearch "$ES_NAME" >/dev/null 2>&1 \
    || { echo "Elasticsearch not deployed — run: ./scripts/deploy.sh stack" >&2; exit 1; }
  local keys
  keys="$(kubectl -n "$NAMESPACE" get secret azure-metrics-sp -o jsonpath='{.data}' 2>/dev/null | jq -r 'keys | sort | join(",")')" \
    || true
  [[ "$keys" == "client_id,client_secret,subscription_id,tenant_id" ]] \
    || { echo "secret azure-metrics-sp missing or incomplete (have: ${keys:-none}) — see elastic.md 'Ticket 6 — Azure'" >&2; exit 1; }

  echo "── Metricbeat (Azure) ──"
  render manifests/metricbeat-azure.yaml | kubectl apply -f -
  wait_ready beat metricbeat-azure 300
  echo "✓ Azure Monitor metrics: first data after ~5–10 minutes (5-minute period)"
}

install_spoke() {
  local ctx="${SPOKE_CONTEXT:?usage: $0 spoke <kubectl-context> <cluster-name>}"
  SPOKE_CLUSTER="${SPOKE_NAME:?usage: $0 spoke <kubectl-context> <cluster-name>}"
  : "${ACR_NAME:?Set ACR_NAME (no .azurecr.us)}"
  SPOKE_NAMESPACE=elastic-beats
  BEATS_IMAGE="${ACR_NAME,,}.azurecr.us/beats/metricbeat:${STACK_VERSION}"
  local k=(kubectl --context "$ctx")

  echo "── Preflight ($ctx = $SPOKE_CLUSTER) ──"
  command -v envsubst >/dev/null || { echo "envsubst not found — install the gettext package" >&2; exit 1; }
  "${k[@]}" get nodes >/dev/null || { echo "cannot reach cluster with context $ctx" >&2; exit 1; }
  # Guard against a context/name mix-up: AKS labels nodes with the cluster's node resource group.
  local rg
  rg="$("${k[@]}" get nodes -o jsonpath='{.items[0].metadata.labels.kubernetes\.azure\.com/cluster}')"
  [[ "$rg" == *"-$SPOKE_CLUSTER-"* ]] \
    || { echo "context $ctx is node RG '$rg', which doesn't look like $SPOKE_CLUSTER" >&2; exit 1; }
  "${k[@]}" create namespace "$SPOKE_NAMESPACE" --dry-run=client -o yaml | "${k[@]}" apply -f - >/dev/null

  echo "── Credentials ──"
  if [[ -n "${SPOKE_API_KEY_FILE:-}" ]]; then
    grep -qE '^[^:[:space:]]+:[^:[:space:]]+$' "$SPOKE_API_KEY_FILE" \
      || { echo "$SPOKE_API_KEY_FILE must contain one line: <id>:<api_key>" >&2; exit 1; }
    "${k[@]}" -n "$SPOKE_NAMESPACE" create secret generic metricbeat-es \
      --from-file=api_key="$SPOKE_API_KEY_FILE" --dry-run=client -o yaml | "${k[@]}" apply -f -
  elif "${k[@]}" -n "$SPOKE_NAMESPACE" get secret metricbeat-es >/dev/null 2>&1; then
    echo "  keeping existing metricbeat-es API key"
  else
    echo "First run: set SPOKE_API_KEY_FILE (see elastic.md 'Ticket 6 — spokes')" >&2; exit 1
  fi
  if [[ -n "${SPOKE_CA_FILE:-}" ]]; then
    grep -q 'BEGIN CERTIFICATE' "$SPOKE_CA_FILE" || { echo "$SPOKE_CA_FILE has no PEM certificates" >&2; exit 1; }
    "${k[@]}" -n "$SPOKE_NAMESPACE" create configmap metricbeat-ca \
      --from-file=ca-bundle.pem="$SPOKE_CA_FILE" --dry-run=client -o yaml | "${k[@]}" apply -f -
  elif "${k[@]}" -n "$SPOKE_NAMESPACE" get configmap metricbeat-ca >/dev/null 2>&1; then
    echo "  keeping existing metricbeat-ca"
  else
    echo "First run: set SPOKE_CA_FILE to the Iguana CA bundle" >&2; exit 1
  fi

  echo "── Metricbeat ──"
  render manifests/spoke-metricbeat.yaml | "${k[@]}" apply -f -
  # The config lives in a ConfigMap the pods only read at start — restart so edits take effect.
  "${k[@]}" -n "$SPOKE_NAMESPACE" rollout restart daemonset/metricbeat >/dev/null
  echo "  waiting 90s for pods to schedule..."
  sleep 90
  "${k[@]}" -n "$SPOKE_NAMESPACE" get daemonset metricbeat
  local pending
  pending="$("${k[@]}" -n "$SPOKE_NAMESPACE" get pods -l app=metricbeat --field-selector=status.phase=Pending \
    -o jsonpath='{range .items[*]}{.metadata.name}{" -> "}{.spec.affinity.nodeAffinity.requiredDuringSchedulingIgnoredDuringExecution.nodeSelectorTerms[0].matchFields[0].values[0]}{"\n"}{end}')"
  if [[ -n "$pending" ]]; then
    echo "  Pending (node has no free pod slot) — free one slot per node, elastic.md \"Ticket 6 — Beats on aks-1\" step 3:"
    sed 's/^/    /' <<<"$pending"
  else
    echo "✓ Metricbeat scheduled on every node of $SPOKE_CLUSTER — check logs for output errors"
  fi
}

case "$STEP" in
  operator) install_operator ;;
  stack)    install_stack ;;
  heartbeat) install_heartbeat ;;
  metricbeat) install_metricbeat ;;
  azure)    install_azure ;;
  spoke)    SPOKE_CONTEXT="${2:-}" SPOKE_NAME="${3:-}" install_spoke ;;
  diff)     show_diff ;;
  all)      install_operator; install_stack ;;
  *) echo "usage: $0 [operator|stack|all|heartbeat|metricbeat|azure|spoke <ctx> <name>|diff]" >&2; exit 1 ;;
esac
