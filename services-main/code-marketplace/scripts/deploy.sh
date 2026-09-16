#!/usr/bin/env bash
# Probe code-marketplace deployment health and gallery API.
# Optional env: NAMESPACE (default: code-marketplace)
set -euo pipefail

NAMESPACE="${NAMESPACE:-code-marketplace}"

echo "── Pods ──"
kubectl -n "$NAMESPACE" get pods -o wide

echo ""
echo "── Service ──"
kubectl -n "$NAMESPACE" get svc

echo ""
echo "── Ingress ──"
kubectl -n "$NAMESPACE" get ingress 2>/dev/null || echo "(none)"

echo ""
echo "── Gallery probe (port-forward) ──"
kubectl -n "$NAMESPACE" port-forward svc/code-marketplace 13001:3001 >/dev/null 2>&1 &
PF=$!
trap "kill $PF 2>/dev/null || true" EXIT
sleep 2

if curl -fsS http://localhost:13001/healthz >/dev/null 2>&1; then
  echo "  ✓ healthz OK"
else
  echo "  ✗ healthz FAILED"
fi

EXT_COUNT=$(curl -fsS -X POST http://localhost:13001/_apis/public/gallery/extensionquery \
  -H 'Content-Type: application/json' \
  -d '{"filters":[{"criteria":[{"filterType":7,"value":""}]}],"flags":914}' \
  2>/dev/null | jq '.results[0].extensions | length' 2>/dev/null || echo "?")

echo "  Extensions visible: $EXT_COUNT"