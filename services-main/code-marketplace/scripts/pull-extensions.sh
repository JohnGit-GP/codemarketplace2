#!/usr/bin/env bash
# CONNECTED SIDE — Pull approved .vsix files from marketplace.visualstudio.com.
# Reads extensions.txt, downloads each to ./extensions/.
# Idempotent: skips files already present.
#
# After running, transfer the extensions/ directory to the Gov side and
# upload via scripts/seed-extensions.sh (which talks to Artifactory).
set -euo pipefail

SVC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.."; pwd)"
cd "$SVC_DIR"

[[ -f extensions.txt ]] || { echo "extensions.txt not found in $SVC_DIR" >&2; exit 1; }

mkdir -p extensions
pulled=0
skipped=0
failed=0

while IFS= read -r raw; do
  line="${raw%%#*}"            # strip comments
  line="$(echo "$line" | xargs)"  # trim whitespace
  [[ -z "$line" ]] && continue

  if [[ ! "$line" =~ ^([^.]+)\.([^@]+)@(.+)$ ]]; then
    echo "  SKIP (malformed): $raw" >&2
    continue
  fi
  PUB="${BASH_REMATCH[1]}"
  EXT="${BASH_REMATCH[2]}"
  VER="${BASH_REMATCH[3]}"
  OUT="extensions/${PUB}.${EXT}-${VER}.vsix"

  if [[ -f "$OUT" ]]; then
    echo "  exists  ${PUB}.${EXT}@${VER}"
    skipped=$((skipped + 1))
    continue
  fi

  URL="https://marketplace.visualstudio.com/_apis/public/gallery/publishers/${PUB}/vsextensions/${EXT}/${VER}/vspackage"
  echo "  pulling ${PUB}.${EXT}@${VER}"
  if curl -fsSL --compressed \
       -H "User-Agent: VSCode/1.85.0" \
       -A "VSCode 1.85.0" \
       -o "$OUT" "$URL"; then
    pulled=$((pulled + 1))
  else
    echo "  FAILED  ${PUB}.${EXT}@${VER}" >&2
    rm -f "$OUT"
    failed=$((failed + 1))
  fi
done < extensions.txt

echo ""
echo "Summary: pulled=$pulled  skipped=$skipped  failed=$failed"
echo ""
echo "Files in extensions/:"
ls -lh extensions/*.vsix 2>/dev/null || echo "  (none)"

[[ $failed -eq 0 ]] || exit 1