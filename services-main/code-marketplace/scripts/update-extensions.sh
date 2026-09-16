#!/usr/bin/env bash
# Upload a single .vsix to the Artifactory generic repo backing code-marketplace.
# Required env: ARTIFACTORY_URL, ARTIFACTORY_TOKEN
# Optional env: REPO (default: vscode-extensions)
set -euo pipefail

VSIX="${1:?Usage: $0 <path-to-vsix>}"
[[ -f "$VSIX" ]] || { echo "Not a file: $VSIX" >&2; exit 1; }

: "${ARTIFACTORY_URL:?Set ARTIFACTORY_URL (e.g. https://artifactory.example.gov)}"
: "${ARTIFACTORY_TOKEN:?}"
REPO="${REPO:-vscode-extensions}"

curl -fsS -H "Authorization: Bearer $ARTIFACTORY_TOKEN" \
  -X PUT -T "$VSIX" \
  "$ARTIFACTORY_URL/$REPO/$(basename "$VSIX")"

echo "✓ Uploaded $(basename "$VSIX") to $REPO"