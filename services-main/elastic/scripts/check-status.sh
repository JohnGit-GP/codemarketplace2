#!/usr/bin/env bash
# Health of the elastic stack on aks-1.
set -euo pipefail
SVC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.."; pwd)"; cd "$SVC_DIR"
source ./service.conf

echo "── Operator ──"
kubectl -n "$OPERATOR_NAMESPACE" get pods
echo; echo "── License ──"
kubectl -n "$NAMESPACE" get elasticsearch "$ES_NAME" -o jsonpath='{.metadata.annotations.elasticsearch\.k8s\.elastic\.co/license}{"\n"}' 2>/dev/null || true
echo; echo "── ECK resources (HEALTH should be green) ──"
kubectl -n "$NAMESPACE" get elasticsearch,kibana,beat 2>/dev/null || kubectl -n "$NAMESPACE" get elasticsearch,kibana
echo; echo "── Pods ──"
kubectl -n "$NAMESPACE" get pods -o wide
echo; echo "── Storage ──"
kubectl -n "$NAMESPACE" get pvc
echo; echo "── Istio routing ──"
kubectl -n "$NAMESPACE" get gateway,virtualservice,destinationrule 2>/dev/null || echo "  (none)"
echo; echo "── Recent events ──"
kubectl -n "$NAMESPACE" get events --sort-by=.lastTimestamp | tail -15
