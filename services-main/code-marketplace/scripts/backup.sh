#!/usr/bin/env bash
# Snapshot the Artifactory vscode-extensions repo to a local tar.gz archive.
# Long-term: wrap this in a K8s CronJob writing to Azure Files or blob via azcopy.
# Required env: ARTIFACTORY_URL, ARTIFACTORY_TOKEN
# Optional env: REPO (default: vscode-extensions), BACKUP_DIR (default: ./backups)
set -euo pipefail

: "${ARTIFACTORY_URL:?}"
: "${ARTIFACTORY_TOKEN:?}"
REPO="${REPO:-vscode-extensions}"
BACKUP_DIR="${BACKUP_DIR:-./backups}"

TS=$(date +%Y%m%d-%H%M%S)
OUT="$BACKUP_DIR/vscode-extensions-$TS.tar.gz"
mkdir -p "$BACKUP_DIR"

TMP=$(mktemp -d)
trap "rm -rf $TMP" EXIT

# List all files in the repo (recursive)
mapfile -t FILES < <(curl -fsS \
  -H "Authorization: Bearer $ARTIFACTORY_TOKEN" \
  "$ARTIFACTORY_URL/api/storage/$REPO?list&deep=1&listFolders=0" \
  | jq -r '.files[].uri')

[[ ${#FILES[@]} -gt 0 ]] || { echo "Repo $REPO is empty — nothing to back up" >&2; exit 1; }

for f in "${FILES[@]}"; do
  curl -fsS -H "Authorization: Bearer $ARTIFACTORY_TOKEN" \
    "$ARTIFACTORY_URL/$REPO$f" \
    --create-dirs -o "$TMP$f"
done

tar -czf "$OUT" -C "$TMP" .
echo "✓ Backup written: $OUT ($(du -h "$OUT" | cut -f1))"