#!/usr/bin/env bash
# Mirror container images across the air gap using crane (no docker daemon required).
#
#   CONNECTED side:  ./mirror-images.sh pull    -> writes ./cache/*.tar from images.txt
#   AIR-GAP side:    ./mirror-images.sh push    -> pushes ./cache/*.tar into the Gov ACR
#
# Required env (push): ACR_NAME
# Requires: crane on both sides. Get it from github.com/google/go-containerregistry
#           releases and carry the Linux binary across with the bundle.
set -euo pipefail

SVC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.."; pwd)"; cd "$SVC_DIR"
MODE="${1:?usage: $0 <pull|push>}"
CACHE="${CACHE_DIR:-./cache}"
PLATFORM="${PLATFORM:-linux/amd64}"

command -v crane >/dev/null || { echo "crane not on PATH" >&2; exit 1; }
mkdir -p "$CACHE"

images() { grep -v '^[[:space:]]*#' images.txt | grep -v '^[[:space:]]*$'; }
tarname() { echo "$CACHE/$(echo "$1" | tr '/:' '__').tar"; }

case "$MODE" in
  pull)
    # --platform matters: pulling on an arm64 host without it yields an image the
    # AKS nodes cannot run, and you only find out after crossing the gap.
    while read -r img; do
      out="$(tarname "$img")"
      echo "  pull  $img  ($PLATFORM)"
      crane pull --platform "$PLATFORM" "$img" "$out"
    done < <(images)
    echo "✓ cached in $CACHE — transfer this directory plus the crane binary"
    ;;

  push)
    : "${ACR_NAME:?Set ACR_NAME}"
    # az acr login shells out to the docker CLI, which is not present on the
    # air-gapped host. --expose-token hands crane a bearer token instead.
    TOKEN="$(az acr login -n "$ACR_NAME" --expose-token --output tsv --query accessToken)"
    crane auth login "$ACR_NAME.azurecr.us" \
      -u 00000000-0000-0000-0000-000000000000 -p "$TOKEN"

    while read -r img; do
      src="$(tarname "$img")"
      [[ -f "$src" ]] || { echo "  MISSING $src (run pull on the connected side)" >&2; exit 1; }
      dst="$ACR_NAME.azurecr.us/${img#*/}"
      echo "  push  $dst"
      crane push "$src" "$dst"
      arch="$(crane config "$dst" | jq -r '.architecture + "/" + .os')"
      echo "        verified: $arch"
    done < <(images)
    echo "✓ mirrored to $ACR_NAME.azurecr.us"
    ;;

  *) echo "usage: $0 <pull|push>" >&2; exit 1 ;;
esac
