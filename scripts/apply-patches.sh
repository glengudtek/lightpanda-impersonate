#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SUBMODULE="$ROOT/lightpanda-browser"

if [[ ! -e "$SUBMODULE/.git" ]]; then
  git -C "$ROOT" submodule update --init --recursive
fi

shopt -s nullglob
patches=()
while IFS= read -r name || [[ -n "$name" ]]; do
  [[ -z "$name" || "$name" == \#* ]] && continue
  if [ "${1:-}" = "--base-only" ] && [[ "$name" != 00*.patch ]]; then
    continue
  fi
  patches+=("$ROOT/patches/$name")
done < "$ROOT/patches/series"

if [ "${#patches[@]}" -eq 0 ]; then
  echo "No patches found under $ROOT/patches"
  exit 0
fi

declare -A committed_patches=()
base="$(git -C "$ROOT" rev-parse HEAD:lightpanda-browser)"
if git -C "$SUBMODULE" merge-base --is-ancestor "$base" HEAD 2>/dev/null; then
  while IFS= read -r subject; do
    if [[ "$subject" == "patch: "* ]]; then
      committed_patches["${subject#patch: }"]=1
    fi
  done < <(git -C "$SUBMODULE" log --format=%s "$base..HEAD")
fi

for patch in "${patches[@]}"; do
  name="${patch##*/}"
  echo "Applying ${patch#"$ROOT"/}"
  if [[ -n "${committed_patches[$name]:-}" ]]; then
    echo "Already committed patches/$name"
    continue
  fi
  if git -C "$SUBMODULE" apply --check --reverse "$patch" >/dev/null 2>&1; then
    echo "Already applied ${patch#"$ROOT"/}"
    continue
  fi
  git -C "$SUBMODULE" apply --check "$patch"
  git -C "$SUBMODULE" apply "$patch"
done
