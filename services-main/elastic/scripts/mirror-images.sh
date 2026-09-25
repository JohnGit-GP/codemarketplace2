#!/usr/bin/env bash
# Mirror images and upstream manifests across the air gap using Docker.
#
#   CONNECTED side:  ./mirror-images.sh pull   -> cache/<name>-<tag>.tar per images.txt
#                                                 e.g. cache/elasticsearch-9.5.4.tar
#                                                 cache/<file> per manifests.txt
#   AIR-GAP side:    ./mirror-images.sh push   -> docker load, tag, push into the Gov ACR
#
# Required env (push): ACR_NAME
# Requires: docker on both sides; az on the air-gap side.
set -euo pipefail

SVC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.."; pwd)"; cd "$SVC_DIR"
MODE="${1:?usage: $0 <pull|push>}"
CACHE="${CACHE_DIR:-./cache}"
PLATFORM="${PLATFORM:-linux/amd64}"

command -v docker >/dev/null || { echo "docker not on PATH" >&2; exit 1; }
mkdir -p "$CACHE"

entries() { grep -v '^[[:space:]]*#' "$1" | grep -v '^[[:space:]]*$'; }
# docker.elastic.co/beats/metricbeat:9.5.4 -> cache/metricbeat-9.5.4.tar
tarname() { local n="${1##*/}"; echo "$CACHE/${n/:/-}.tar"; }

case "$MODE" in
  pull)
    # --platform matters: pulling on an arm64 host without it yields an image the
    # AKS nodes cannot run, and you only find out after crossing the gap.
    while read -r img; do
      echo "  pull  $img  ($PLATFORM)"
      docker pull --platform "$PLATFORM" "$img"
      docker save -o "$(tarname "$img")" "$img"
    done < <(entries images.txt)

    if [[ -f manifests.txt ]]; then
      while read -r url file; do
        echo "  fetch $url"
        curl -fsSL -o "$CACHE/$file" "$url"
      done < <(entries manifests.txt)
    fi
    echo "✓ cached in $CACHE — transfer this directory"
    ;;

  push)
    : "${ACR_NAME:?Set ACR_NAME}"
    ACR_NAME="${ACR_NAME,,}"   # login servers are lowercase
    az acr login -n "$ACR_NAME"

    while read -r img; do
      src="$(tarname "$img")"
      [[ -f "$src" ]] || { echo "  MISSING $src (run pull on the connected side)" >&2; exit 1; }
      docker load -i "$src" >/dev/null

      arch="$(docker image inspect "$img" --format '{{.Architecture}}/{{.Os}}')"
      [[ "$arch" == "amd64/linux" ]] \
        || { echo "  WRONG ARCH $img is $arch — re-pull with --platform linux/amd64" >&2; exit 1; }

      # Keep the path after the registry — ECK's --container-registry depends on it.
      dst="$ACR_NAME.azurecr.us/${img#*/}"
      echo "  push  $dst  ($arch)"
      docker tag "$img" "$dst"
      docker push "$dst" >/dev/null
    done < <(entries images.txt)
    echo "✓ mirrored to $ACR_NAME.azurecr.us"
    ;;

  *) echo "usage: $0 <pull|push>" >&2; exit 1 ;;
esac
