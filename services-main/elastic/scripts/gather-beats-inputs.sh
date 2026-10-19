#!/usr/bin/env bash
# Ticket 6, phase 1: collect the facts needed to size and place the Beats.
#
#   ACR_NAME=<acr> ./scripts/gather-beats-inputs.sh <aks-1-context> [<spoke-context> ...]
#
# Read-only, except one short-lived namespace (es-reach-test) per spoke for a reachability
# probe, deleted at the end. Optional: AKS_RG and AKS_NAME (aks-1's resource group and cluster
# name) add the node pool / autoscaler settings via az.
#
# Output is also written to phase1-inputs-<date>.txt. It contains node names and the gateway
# IP the spokes resolve — mask those before pasting it anywhere outside the enclave.
set -uo pipefail

SVC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.."; pwd)"; cd "$SVC_DIR"
# shellcheck source=../service.conf
source ./service.conf

HUB="${1:?usage: ACR_NAME=<acr> $0 <aks-1-context> [<spoke-context> ...]}"; shift
: "${ACR_NAME:?Set ACR_NAME (no .azurecr.us)}"
PROBE_IMAGE="${ACR_NAME,,}.azurecr.us/elasticsearch/elasticsearch:${STACK_VERSION}"
OUT="phase1-inputs-$(date +%Y%m%d-%H%M).txt"

capacity() {
  local ctx="$1"
  echo "-- pod limit and allocatable resources per node"
  kubectl --context "$ctx" get nodes \
    -o custom-columns=NODE:.metadata.name,MAXPODS:.status.allocatable.pods,CPU:.status.allocatable.cpu,MEM:.status.allocatable.memory
  echo "-- running pods per node"
  kubectl --context "$ctx" get pods -A --field-selector=status.phase!=Succeeded,status.phase!=Failed \
    -o custom-columns=NODE:.spec.nodeName --no-headers | sort | uniq -c
}

# Candidate Heartbeat targets: every hostname already published through Istio or Ingress.
hostnames() {
  local ctx="$1"
  echo "-- Istio VirtualService hosts"
  kubectl --context "$ctx" get virtualservice -A --no-headers \
    -o custom-columns=NS:.metadata.namespace,NAME:.metadata.name,HOSTS:.spec.hosts 2>/dev/null || echo "  (no VirtualService CRD)"
  echo "-- Ingress hosts"
  kubectl --context "$ctx" get ingress -A --no-headers \
    -o custom-columns=NS:.metadata.namespace,NAME:.metadata.name,HOSTS:.spec.rules[*].host 2>/dev/null || echo "  (none)"
}

# From inside the spoke: does the ACR pull work, does ES_HOST resolve, does 443 answer?
probe() {
  local ctx="$1" ns=es-reach-test phase
  kubectl --context "$ctx" create namespace "$ns" >/dev/null
  kubectl --context "$ctx" -n "$ns" run probe --restart=Never --image="$PROBE_IMAGE" --command -- \
    bash -c "echo \"dns: \$(getent hosts $ES_HOST || echo NOT RESOLVED)\";
             echo \"https: \$(curl -sk -m 10 -o /dev/null -w 'HTTP %{http_code}' https://$ES_HOST/)\"" >/dev/null
  for _ in $(seq 1 24); do
    phase="$(kubectl --context "$ctx" -n "$ns" get pod probe -o jsonpath='{.status.phase}' 2>/dev/null)"
    [[ "$phase" == Succeeded || "$phase" == Failed ]] && break
    sleep 5
  done
  echo "-- probe pod phase: ${phase:-unknown}"
  if [[ "$phase" == Succeeded || "$phase" == Failed ]]; then
    kubectl --context "$ctx" -n "$ns" logs probe
  else
    echo "-- probe did not finish in 2 min; last events:"
    kubectl --context "$ctx" -n "$ns" get events --sort-by=.lastTimestamp | tail -5
  fi
  kubectl --context "$ctx" delete namespace "$ns" --wait=false >/dev/null
}

{
  echo "# Phase 1 inputs — $(date -u +%FT%TZ)"
  echo; echo "## kubectl contexts available"
  kubectl config get-contexts -o name

  echo; echo "## Hub: $HUB"
  capacity "$HUB"
  if [[ -n "${AKS_RG:-}" && -n "${AKS_NAME:-}" ]]; then
    echo "-- node pools (az)"
    az aks nodepool list -g "$AKS_RG" --cluster-name "$AKS_NAME" -o table \
      --query "[].{pool:name,count:count,auto:enableAutoScaling,min:minCount,max:maxCount,maxPods:maxPods,vm:vmSize}"
  else
    echo "-- node pools: skipped (set AKS_RG and AKS_NAME to include)"
  fi
  hostnames "$HUB"

  for ctx in "$@"; do
    echo; echo "## Spoke: $ctx"
    if ! kubectl --context "$ctx" get nodes >/dev/null 2>&1; then
      echo "-- cannot reach this cluster with context $ctx"; continue
    fi
    capacity "$ctx"
    hostnames "$ctx"
    probe "$ctx"
  done
} 2>&1 | tee "$OUT"

echo; echo "Saved to $SVC_DIR/$OUT"
