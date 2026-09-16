#!/usr/bin/env bash
# Restore a backup archive into the Artifactory vscode-extensions repo.
# Idempotent — overwrites existing entries with same name.
# Required env: ARTIFACTORY_URL, ARTIFACTORY_TOKEN
# Optional env: REPO (default: vscode-extensions)
set -euo pipefail

ARCHIVE="${1:?Usage: $0 <backup.tar.gz>}"
[[ -f "$ARCHIVE" ]] || { echo "Not a file: $ARCHIVE" >&2; exit 1; }

: "${ARTIFACTORY_URL:?}"
: "${ARTIFACTORY_TOKEN:?}"
REPO="${REPO:-vscode-extensions}"

TMP=$(mktemp -d)
trap "rm -rf $TMP" EXIT
tar -xzf "$ARCHIVE" -C "$TMP"

count=0
while IFS= read -r -d '' f; do
  REL="${f#$TMP/}"
  curl -fsS -H "Authorization: Bearer $ARTIFACTORY_TOKEN" \
    -X PUT -T "$f" \
    "$ARTIFACTORY_URL/$REPO/$REL" >/dev/null
  count=$((count + 1))
done < <(find "$TMP" -type f -print0)

echo "✓ Restored $count files from $(basename "$ARCHIVE") to $REPO"