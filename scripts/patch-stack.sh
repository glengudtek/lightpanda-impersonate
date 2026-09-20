#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SUBMODULE="$ROOT/lightpanda-browser"
SERIES="$ROOT/patches/series"
DEFAULT_BRANCH="local/patch-stack"

die() {
  echo "$*" >&2
  exit 1
}

load_series() {
  [[ -f "$SERIES" ]] || die "Missing patches/series"

  PATCHES=()
  declare -gA LISTED=()
  while IFS= read -r name || [[ -n "$name" ]]; do
    [[ -z "$name" || "$name" == \#* ]] && continue
    [[ "$name" != */* && "$name" == *.patch ]] || die "Invalid patches/series entry: $name"
    [[ -z "${LISTED[$name]:-}" ]] || die "Duplicate patches/series entry: $name"
    [[ -f "$ROOT/patches/$name" ]] || die "Missing patch listed in patches/series: $name"
    PATCHES+=("$name")
    LISTED["$name"]=1
  done < "$SERIES"

  shopt -s nullglob
  local path name
  for path in "$ROOT"/patches/*.patch; do
    name="${path##*/}"
    [[ -n "${LISTED[$name]:-}" ]] || die "Patch is not listed in patches/series: $name"
  done
}

ensure_submodule() {
  if [[ ! -e "$SUBMODULE/.git" ]]; then
    git -C "$ROOT" submodule update --init --recursive
  fi
}

base_commit() {
  if [[ -n "${PATCH_STACK_BASE:-}" ]]; then
    git -C "$SUBMODULE" rev-parse "${PATCH_STACK_BASE}^{commit}"
  else
    git -C "$ROOT" rev-parse HEAD:lightpanda-browser
  fi
}

require_clean_submodule() {
  if [[ -n "$(git -C "$SUBMODULE" status --porcelain --untracked-files=all)" ]]; then
    git -C "$SUBMODULE" status --short >&2
    die "lightpanda-browser has local changes; commit or discard them first"
  fi
}

branch_from_patches() {
  local branch="${1:-$DEFAULT_BRANCH}"
  local base patch

  git check-ref-format --branch "$branch" >/dev/null 2>&1 || die "Invalid branch name: $branch"
  if git -C "$SUBMODULE" show-ref --verify --quiet "refs/heads/$branch"; then
    die "Branch already exists in lightpanda-browser: $branch"
  fi

  require_clean_submodule
  base="$(base_commit)"
  git -C "$SUBMODULE" cat-file -e "$base^{commit}"
  git -C "$SUBMODULE" switch --create "$branch" "$base"

  for patch in "${PATCHES[@]}"; do
    echo "Importing patches/$patch"
    git -C "$SUBMODULE" apply --index --whitespace=nowarn "$ROOT/patches/$patch"
    git -C "$SUBMODULE" \
      -c user.name="Patch Stack" \
      -c user.email="patch-stack@local" \
      commit --quiet --message="patch: $patch"
  done

  echo "Created lightpanda-browser branch $branch with ${#PATCHES[@]} patch commits."
}

patches_from_branch() {
  local base subject expected commit patch
  local -a commits=()
  local temp_dir

  require_clean_submodule
  base="$(base_commit)"
  git -C "$SUBMODULE" merge-base --is-ancestor "$base" HEAD ||
    die "Current branch is not based on the submodule commit recorded by the root repository"

  mapfile -t commits < <(git -C "$SUBMODULE" rev-list --reverse "$base..HEAD")
  [[ ${#commits[@]} -eq ${#PATCHES[@]} ]] ||
    die "Expected ${#PATCHES[@]} patch commits after $base, found ${#commits[@]}"

  temp_dir="$(mktemp -d "${TMPDIR:-/tmp}/lightpanda-patches.XXXXXX")"
  cleanup_export() {
    rm -rf "$temp_dir"
  }
  trap cleanup_export EXIT

  for ((i = 0; i < ${#PATCHES[@]}; i++)); do
    commit="${commits[$i]}"
    patch="${PATCHES[$i]}"
    expected="patch: $patch"
    subject="$(git -C "$SUBMODULE" show -s --format=%s "$commit")"
    [[ "$subject" == "$expected" ]] ||
      die "Commit $commit must have subject '$expected', found '$subject'"
    git -C "$SUBMODULE" diff-tree --binary --no-commit-id --root -p "$commit" > "$temp_dir/$patch"
  done

  for patch in "${PATCHES[@]}"; do
    if ! cmp -s "$temp_dir/$patch" "$ROOT/patches/$patch"; then
      cp "$temp_dir/$patch" "$ROOT/patches/$patch"
      echo "Updated patches/$patch"
    fi
  done

  echo "Exported ${#PATCHES[@]} patch commits from lightpanda-browser."
  cleanup_export
  trap - EXIT
}

check_patches() {
  local base patch temp_dir worktree

  base="$(base_commit)"
  temp_dir="$(mktemp -d "${TMPDIR:-/tmp}/lightpanda-check.XXXXXX")"
  worktree="$temp_dir/worktree"
  cleanup_check() {
    if [[ -n "${worktree:-}" && -d "$worktree" ]]; then
      git -C "$SUBMODULE" worktree remove --force "$worktree" >/dev/null 2>&1 || true
    fi
    if [[ -n "${temp_dir:-}" ]]; then
      rm -rf "$temp_dir"
    fi
  }
  trap cleanup_check EXIT

  git -C "$SUBMODULE" worktree add --quiet --detach "$worktree" "$base"
  for patch in "${PATCHES[@]}"; do
    echo "Checking patches/$patch"
    git -C "$worktree" apply --check "$ROOT/patches/$patch"
    git -C "$worktree" apply "$ROOT/patches/$patch"
  done
  echo "All patches apply cleanly to $base."
  cleanup_check
  trap - EXIT
}

switch_to_upstream() {
  local base head patch reversed

  base="$(base_commit)"
  head="$(git -C "$SUBMODULE" rev-parse HEAD)"

  if [[ -n "$(git -C "$SUBMODULE" status --porcelain --untracked-files=all)" ]]; then
    [[ "$head" == "$base" ]] ||
      die "lightpanda-browser has local changes on a patch branch; commit or discard them first"
    reversed=0
    for ((i = ${#PATCHES[@]} - 1; i >= 0; i--)); do
      patch="${PATCHES[$i]}"
      if ! git -C "$SUBMODULE" apply --check --reverse "$ROOT/patches/$patch" >/dev/null 2>&1; then
        echo "Not applied patches/$patch"
        continue
      fi
      echo "Unapplying patches/$patch"
      git -C "$SUBMODULE" apply --reverse "$ROOT/patches/$patch"
      reversed=$((reversed + 1))
    done
    [[ "$reversed" -gt 0 ]] || die "local changes do not match any applied patch"
    require_clean_submodule
  fi

  git -C "$SUBMODULE" switch --detach "$base"
  echo "lightpanda-browser is now at the recorded upstream commit $base."
}

usage() {
  cat <<'EOF'
Usage:
  patch-stack.sh branch-from-patches [branch]
  patch-stack.sh patches-from-branch
  patch-stack.sh check
  patch-stack.sh upstream
EOF
}

ensure_submodule
load_series

case "${1:-}" in
  branch-from-patches)
    branch_from_patches "${2:-}"
    ;;
  patches-from-branch)
    [[ $# -eq 1 ]] || die "patches-from-branch takes no arguments"
    patches_from_branch
    ;;
  check)
    [[ $# -eq 1 ]] || die "check takes no arguments"
    check_patches
    ;;
  upstream)
    [[ $# -eq 1 ]] || die "upstream takes no arguments"
    switch_to_upstream
    ;;
  *)
    usage >&2
    exit 2
    ;;
esac
