#!/usr/bin/env bash
# Ingest a single .vsix into Artifactory via code-marketplace's `add` command.
# A raw PUT is NOT enough — the gallery only indexes extensions added this way
# (add extracts the .vsix and writes the publisher/name/version layout + metadata).
#
# Runs `add` inside the deployed pod, reusing its binary, ARTIFACTORY_TOKEN,
# and the exact --artifactory URL the server was started with.
#
# Optional env: NAMESPACE (default code-marketplace), REPO (default vscode-extensions)
set -euo pipefail
 
VSIX="${1:?Usage: $0 <path-to-vsix>}"
[[ -f "$VSIX" ]] || { echo "Not a file: $VSIX" >&2; exit 1; }
 
NAMESPACE="${NAMESPACE:-code-marketplace}"
REPO="${REPO:-vscode-extensions}"
BASENAME="$(basename "$VSIX")"
 
POD=$(kubectl -n "$NAMESPACE" get pod -l app=code-marketplace \
  -o jsonpath='{.items[0].metadata.name}')
[[ -n "$POD" ]] || { echo "No code-marketplace pod in ns/$NAMESPACE" >&2; exit 1; }
 
# Reuse the exact --artifactory URL the server is running with
ART_URL=$(kubectl -n "$NAMESPACE" get deploy code-marketplace \
  -o jsonpath='{range .spec.template.spec.containers[0].args[*]}{@}{"\n"}{end}' \
  | sed -n 's/^--artifactory=//p')
[[ -n "$ART_URL" ]] || { echo "Could not read --artifactory from deployment" >&2; exit 1; }
 
kubectl -n "$NAMESPACE" cp "$VSIX" "$POD":/tmp/"$BASENAME"
kubectl -n "$NAMESPACE" exec "$POD" -- \
  code-marketplace add /tmp/"$BASENAME" --artifactory "$ART_URL" --repo "$REPO"
kubectl -n "$NAMESPACE" exec "$POD" -- rm -f /tmp/"$BASENAME"
 
echo "✓ Added $BASENAME via code-marketplace (repo=$REPO)"
