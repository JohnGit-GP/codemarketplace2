#!/usr/bin/env bash
# Probe the elastic stack: workloads, storage, networking, and cluster health.
# Optional env: NAMESPACE (default from service.conf)
set -euo pipefail

SVC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.."; pwd)"; cd "$SVC_DIR"
source ./service.conf
NAMESPACE="${NAMESPACE:-elastic}"

echo "── Pods ──"
kubectl -n "$NAMESPACE" get pods -o wide

echo ""
echo "── StatefulSets / Deployments ──"
kubectl -n "$NAMESPACE" get statefulset,deployment

echo ""
echo "── Storage ──"
kubectl -n "$NAMESPACE" get pvc

echo ""
echo "── Services ──"
kubectl -n "$NAMESPACE" get svc

echo ""
echo "── Istio routing ──"
kubectl -n "$NAMESPACE" get gateway,virtualservice 2>/dev/null || echo "  (none)"

echo ""
echo "── Recent events ──"
kubectl -n "$NAMESPACE" get events --sort-by=.lastTimestamp | tail -15

echo ""
echo "── Cluster health ──"
# TODO: point at the real Elasticsearch service name once deployed.
# Credentials come from the elastic-credentials secret; read them inside the
# pod rather than passing them on a kubectl command line (that lands in logs).
echo "  (fill in once the ES service name is known: GET /_cluster/health)"
