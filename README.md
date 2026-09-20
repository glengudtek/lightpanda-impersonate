# lightpanda-impersonate

Patch-managed Lightpanda Browser builds for UA profile impersonation.

This is a hobby project. It only changes surface-level UA and client-hint signals
such as User-Agent and UA Client Hints; it does not make Lightpanda equivalent
to a real browser. Partial impersonation can also make a client easier to
fingerprint when its claimed signals do not match its actual behavior. Use these
builds at your own risk and responsibility.

This repository keeps `lightpanda-browser` as an upstream submodule and stores
local modifications as root-level patch files under `patches/`.

## Requirements

- `just`
- Zig `0.16.0` or newer
- `git`, `make`, `curl`
- Rust/C toolchain required by `lightpanda-browser/src/html5ever`

Prebuilt Linux release binaries require glibc 2.38 or newer on `x86_64` or
`aarch64`. musl-based distributions are not supported.

The build downloads the pinned curl-impersonate `v2.2.2` static archive for
Linux `x86_64` or `aarch64` and verifies its SHA-256 checksum. Override the
default cache location with `-Dcurl_impersonate_root=/path/to/prefix`; the
prefix must contain `libcurl-impersonate.a` and `include/curl/curl.h`.

## Build Workflow

The high-level `just test` and `just build-release` recipes apply patches and
download curl-impersonate automatically. To prepare the submodule for direct
build or development commands, run:

```bash
just apply
just download-curl-impersonate
```

Use `just apply-base` to apply only required `0000`-series patches. Optional
patches such as `0101-*` are maintained on top of that base.

UA profile values used by the optional impersonation patch live in
`ua-profile.zon` at the repository root. The patched Lightpanda build
reads this file by default when commands run from `lightpanda-browser/`; pass
`-Dua_profile_config=../path/to/file.zon` only when testing another config.
Changing this file requires rebuilding the binary. Set `full_version` and
`include_google_chrome_brand` to auto-generate low/high entropy client-hint
brands. Set `user_agent` to override the generated UA. `additional_brands` and
`manual_brands` use high-entropy versions as input; low-entropy output drops
minor version components, while dotless versions are emitted unchanged in both
outputs. `curl_impersonate` selects the default curl-impersonate TLS/HTTP
profile. Override it for one process with, for example,
`lightpanda fetch --curl-impersonate chrome145 https://example.com`.

Run a focused test after applying the patches:

```bash
just download-v8
just test cdp.Emulation
```

After building, run the generated binary against the live fingerprint service:

```bash
just live-test
```

The live test checks the stable Chrome 146 JA4, PeetPrint and HTTP/2
fingerprints, then verifies that the User-Agent and UA Client Hints observed on
the wire agree with `ua-profile.zon` and the browser's Navigator APIs. It makes
two requests to `https://tls.peet.ws/api/all` and retries transient failures up
to three times. The Linux release workflow runs this check before uploading
each binary artifact.

## Patch Development

Patch order is defined by `patches/series`. Create the editable local branch
after cloning the repository:

```bash
just branch-from-patches
```

This creates `local/patch-stack` from the submodule commit recorded by the root
repository, with one commit per patch. The generated commit subjects identify
the corresponding patch files. Edit the appropriate commit with `git commit
--amend` or interactive rebase; do not add extra commits to the stack.

`branch-from-patches` requires a new branch name and fails if the branch already
exists. To resume work on the default branch after `just unapply`, run:

```bash
git -C lightpanda-browser switch local/patch-stack
```

Export all commits back to the checked-in patch files and verify them in a
temporary worktree:

```bash
just patches-from-branch
just check-patches
```

`patches-from-branch` requires a clean submodule and an exact one-to-one match
between the commits and `patches/series`, preventing changes from one patch from
being silently written into another. To leave the local branch and return the
submodule checkout to the recorded upstream commit, run `just unapply`. The
local branch remains available for later use. In the build workflow, the same
command also reverses a full or base-only prefix of patches previously applied
as uncommitted changes by `just apply` or `just apply-base`.

## Useful Commands

- `just status`: show root and submodule status.
- `just diff`: show root and submodule diffs.
- `just list`: show all available recipes.
- `just apply`: apply the complete patch series to the submodule as uncommitted
  changes.
- `just apply-base`: apply only required `0000`-series patches.
- `just unapply`: return the submodule to the recorded upstream commit from a
  clean patch branch or a tree changed by `just apply` or `just apply-base`.
- `just branch-from-patches [branch]`: create an editable commit stack from the
  checked-in patches; the default branch is `local/patch-stack`.
- `just patches-from-branch`: regenerate the checked-in patches from the current
  commit stack.
- `just check-patches`: test the complete series against the recorded upstream
  commit without changing the current submodule checkout.
- `just download-v8`: download Lightpanda's matching prebuilt V8 archive.
- `just download-curl-impersonate`: download and verify the pinned static
  curl-impersonate archive for the current host architecture.
- `just test <filter>`: apply patches, ensure curl-impersonate is available, and
  run a filtered Zig test using the downloaded prebuilt V8 archive.
- `just build-release`: apply patches, download prebuilt V8, create the V8
  snapshot, and build a release binary.
- `just live-test [binary] [profile]`: verify a built binary's live network and
  Navigator impersonation; defaults to the local release binary and
  `chrome146`.
- `just clean-build`: remove normal build outputs.
- `just clean-source-v8`: remove interrupted V8 source-build caches while
  preserving `.lp-cache/prebuilt-v8`.

## Notes

Use `just test <filter>` instead of `make test F=<filter>`. The Makefile filter
can leak into nested Rust dependency builds through `MAKEFLAGS`.

Patch files are the portable source of truth. The branch inside
`lightpanda-browser/` is a local editing representation and is intentionally not
recorded as the root repository's submodule pointer. Keep the submodule worktree
clean before exporting or committing root changes.
