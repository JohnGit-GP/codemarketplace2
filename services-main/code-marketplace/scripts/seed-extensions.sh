#!/usr/bin/env bash
# Bulk-upload every .vsix file in ./extensions/ to Artifactory.
# Required env: ARTIFACTORY_URL, ARTIFACTORY_TOKEN
set -euo pipefail

SVC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.."; pwd)"
cd "$SVC_DIR"

shopt -s nullglob
VSIXES=(extensions/*.vsix)
[[ ${#VSIXES[@]} -gt 0 ]] || { echo "No .vsix files in extensions/" >&2; exit 1; }

for v in "${VSIXES[@]}"; do
  ./scripts/update-extension.sh "$v"
done

echo "✓ Seeded ${#VSIXES[@]} extensions"