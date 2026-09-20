#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="2.2.2"
ARCH="${ARCH:-$(uname -m)}"

case "$ARCH" in
  x86_64)
    SHA256="da09231c2809977266ddd00a0b60e638f8e67fc5dc97811065a185fa951a3275"
    ;;
  aarch64|arm64)
    ARCH="aarch64"
    SHA256="b3c1c4464100e050fab66314e84f3a776d5973172e6c63e2ad1d3dea6d4870ad"
    ;;
  *)
    echo "Unsupported curl-impersonate architecture: $ARCH" >&2
    exit 1
    ;;
esac

NAME="libcurl-impersonate-v${VERSION}.${ARCH}-linux-gnu.tar.gz"
URL="https://github.com/lexiforest/curl-impersonate/releases/download/v${VERSION}/${NAME}"
DEST="$ROOT/lightpanda-browser/.lp-cache/curl-impersonate/v${VERSION}/${ARCH}-linux-gnu"

if [[ -f "$DEST/libcurl-impersonate.a" && -f "$DEST/include/curl/curl.h" ]]; then
  echo "Using cached curl-impersonate v${VERSION}: $DEST"
  exit 0
fi

temp_dir="$(mktemp -d "${TMPDIR:-/tmp}/curl-impersonate.XXXXXX")"
cleanup() {
  rm -rf "$temp_dir"
}
trap cleanup EXIT

curl --fail --location --retry 3 --output "$temp_dir/$NAME" "$URL"
echo "$SHA256  $temp_dir/$NAME" | sha256sum --check --status
mkdir -p "$temp_dir/extract"
tar -xzf "$temp_dir/$NAME" -C "$temp_dir/extract"

[[ -f "$temp_dir/extract/libcurl-impersonate.a" ]] || {
  echo "Archive does not contain libcurl-impersonate.a" >&2
  exit 1
}
[[ -f "$temp_dir/extract/include/curl/curl.h" ]] || {
  echo "Archive does not contain include/curl/curl.h" >&2
  exit 1
}

mkdir -p "$DEST"
cp -R "$temp_dir/extract/." "$DEST/"
echo "Downloaded curl-impersonate v${VERSION}: $DEST"
