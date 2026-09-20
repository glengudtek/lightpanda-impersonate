set shell := ["bash", "-c"]
set tempdir := "/tmp"

lp := "lightpanda-browser"

default: list

# Show available recipes.
list:
	@just --list

# Apply required 0000-series patches into lightpanda-browser.
apply-base:
	./scripts/apply-patches.sh --base-only

# Apply all root patches into lightpanda-browser.
apply:
	./scripts/apply-patches.sh

# Return to the recorded upstream commit, reversing any applied patch prefix.
unapply:
	./scripts/patch-stack.sh upstream

# Create an editable local branch with one commit per patch.
branch-from-patches branch="local/patch-stack":
	./scripts/patch-stack.sh branch-from-patches "{{branch}}"

# Export the current patch branch commits back to patches/.
patches-from-branch:
	./scripts/patch-stack.sh patches-from-branch

# Show root and submodule status.
status:
	git status --short
	git -C {{lp}} status --short

# Show root and submodule diffs.
diff:
	git diff -- . ':!{{lp}}'
	git -C {{lp}} diff --no-ext-diff

# Verify required patches apply first, then optional patches apply on top.
check-patches:
	./scripts/patch-stack.sh check

# Download Lightpanda's matching prebuilt V8 archive.
download-v8:
	cd {{lp}} && make download-v8

# Download the pinned static libcurl-impersonate archive for this host.
download-curl-impersonate:
	./scripts/download-curl-impersonate.sh

# Run a filtered Zig test without Makefile F=... MAKEFLAGS leakage.
test filter:
	#!/usr/bin/env bash
	set -euo pipefail
	./scripts/apply-patches.sh
	./scripts/download-curl-impersonate.sh
	cd lightpanda-browser
	v8_archive="$(find .lp-cache/prebuilt-v8 -name "libc_v8_*.a" -print | sort -V | tail -1)"
	if [[ -z "${v8_archive}" ]]; then
	  echo "Missing prebuilt V8. Run: just download-v8" >&2
	  exit 1
	fi
	TEST_FILTER="{{filter}}" zig build -Dprebuilt_v8_path="${v8_archive}" test -freference-trace

# Build a release binary using the patched tree and prebuilt V8.
build-release:
	#!/usr/bin/env bash
	set -euo pipefail
	./scripts/apply-patches.sh
	./scripts/download-curl-impersonate.sh
	cd lightpanda-browser
	make download-v8
	v8_archive="$(find .lp-cache/prebuilt-v8 -name "libc_v8_*.a" -print | sort -V | tail -1)"
	zig build -Dprebuilt_v8_path="${v8_archive}" -Doptimize=ReleaseFast snapshot_creator -- src/snapshot.bin
	zig build -Dsnapshot_path=../../snapshot.bin -Dprebuilt_v8_path="${v8_archive}" -Doptimize=ReleaseFast

# Verify the built binary's live TLS/HTTP2 and UA impersonation signals.
live-test binary="lightpanda-browser/zig-out/bin/lightpanda" profile="chrome146":
	python3 scripts/live-test.py --binary "{{binary}}" --curl-profile "{{profile}}" --ua-profile ua-profile.zon

# Remove normal build outputs while preserving slow dependency caches.
clean-build:
	rm -rf {{lp}}/zig-out {{lp}}/.zig-cache {{lp}}/src/snapshot.bin

# Remove interrupted V8 source-build caches, preserving prebuilt-v8.
clean-source-v8:
	rm -rf {{lp}}/.lp-cache/v8-* {{lp}}/.lp-cache/depot_tools-*
