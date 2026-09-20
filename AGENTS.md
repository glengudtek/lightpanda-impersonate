# Repository Guidelines

## Project Shape

This repository wraps the upstream `lightpanda-browser` submodule. Treat
`lightpanda-browser/` as imported source and keep persistent local changes in
root-level patch files.

- `lightpanda-browser/`: upstream Zig/Rust/C browser source.
- `patches/00*.patch`: required local patches applied before all other work.
- `patches/0101-ua-profile.patch`: optional UA profile impersonation patch.
- `ua-profile.zon`: root config consumed by the optional UA profile patch.
- `scripts/apply-patches.sh`: applies base-only or full patch sets.
- `justfile`: primary local workflow commands.
- `.github/workflows/release-linux.yml`: Linux release build workflow.

## Local Workflow

Run commands from the repository root unless a recipe changes directory for
you.

- `just apply`: apply all patches into `lightpanda-browser/`.
- `just apply-base`: apply only required `0000`-series patches.
- `just unapply`: reverse applied patches and return the submodule to upstream.
- `just check-patches`: verify base patches apply first, then optional patches
  apply on top.
- `just download-v8`: fetch Lightpanda's matching prebuilt V8 archive.
- `just test <filter>`: run a focused Zig test with prebuilt V8.
- `just build-release`: apply patches, download V8, create the snapshot, and
  build a release binary.

Use Zig `0.16.0`, matching `lightpanda-browser/build.zig.zon`.

## Patch Maintenance

Edit files under `lightpanda-browser/` only as working state. Refresh the
intended patch with:

```bash
just refresh 0101-ua-profile.patch
```

Keep patch names ordered by dependency. Required patches use the `0000` range;
optional feature patches are checked after those. Before committing, run
`just check-patches` and leave `lightpanda-browser/` clean with
`just unapply`.

Minimize patch context and avoid unrelated formatting or line movement. Add
changes to the latest suitable patch in the series when that keeps earlier
patches independent, and split hunks by concern so upstream changes are less
likely to make a patch fail or cause merge conflicts.

## UA Profile Config

The UA profile patch reads `../ua-profile.zon` by default when building from
`lightpanda-browser/`. Use `-Dua_profile_config=../path/to/file.zon` only for
alternate configs. `manual_brands` and `additional_brands` are high-entropy
inputs; low-entropy output drops dotted minor version components.

## Style & Testing

Follow upstream style in touched files. For Zig, run formatting from the
submodule when needed:

```bash
zig fmt --check ./*.zig ./**/*.zig
```

Prefer focused tests while editing, for example `just test Navigator`, then
broaden only when the change affects shared browser, network, or build logic.
Use `just test <filter>` instead of `make test F=...`; Makefile filters can leak
through `MAKEFLAGS` into nested dependency builds.

## Commits

Commit root patch/config/workflow changes, not direct submodule edits. Keep
subjects short and imperative, mention the affected area when useful, and
include relevant verification output in PR descriptions.
