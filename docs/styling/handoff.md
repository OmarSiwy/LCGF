# Continue the styling branch

The source snapshot and full Git history are delivered together. The working branch is
`feat/comprehensive-styling`; the upstream baseline is
`ed94db3da27882ef1c87d0dd15a382b4df39e2c2` from
[OmarSiwy/LCGF](https://github.com/OmarSiwy/LCGF).

## Restore the exact branch

After extracting the delivery ZIP, use the included bundle:

```sh
git clone --branch feat/comprehensive-styling LCGF-styling.bundle LCGF-styling
cd LCGF-styling
git log --oneline -8
```

The `source/` directory is also a complete tracked-file snapshot for direct inspection.
The bundle retains the upstream ancestry and the implementation commits; it does not need
GitHub access to restore the project. The ZIP's delivery manifest records the exact commit
and SHA-256 of the bundled history. Build caches, untracked dependency downloads and toolchain binaries are excluded. The
upstream repository already tracks a `zig-pkg/` tree; those original tracked files are
preserved in both the source snapshot and Git history.

## Build and inspect

Use Zig `0.18.0-dev.1151+8dfb7a7cc`. The repository's dependency manifest pins the optional
packages; a fresh build may need network access to retrieve them. HarfBuzz is built from its
pinned source package and AccessKit uses its pinned native archive.

```sh
zig build test harfbuzz wayland gles accesskit docs styling-check -Drender=sw -j2 --summary all
zig build styling-gallery -Drender=sw -Dgallery-output=docs/styling/gallery.png
zig build styling-bench -Drender=sw -- docs/styling/benchmark.json
zig build fmt
```

The GL ES gate needs EGL/GL ES libraries with an offscreen context. See
[validation](validation.md) for the exact executed platform, driver, test counts and native
cross-compilation results. The benchmark uses Linux monotonic time and the stock CPU
renderer. [The implementation guide](README.md) explains the normal frame sequence,
prepared paint, ownership, compatibility and bounded profiles. [Coverage](coverage.md)
maps every research group to source and concrete evidence.

## Publish when a writable destination is available

Publication was attempted through the connected GitHub integration. The create-branch
request was rejected with HTTP 403, `Resource not accessible by integration`. No remote
fork, branch, push or pull request was created. The local code and bundle are complete;
remote publication is the remaining access-dependent action.

Choose a destination repository that your Git credentials can write. In a clone restored
from the bundle, the existing `origin` points to the local bundle file. Replace that URL
with the chosen destination, retain upstream separately, and push the branch:

```sh
git remote set-url origin YOUR_WRITABLE_REPOSITORY_URL
git remote add upstream https://github.com/OmarSiwy/LCGF.git
git push -u origin feat/comprehensive-styling
```

`YOUR_WRITABLE_REPOSITORY_URL` is a placeholder to replace with the actual repository URL.
Do not use a force push. The branch is based on the recorded upstream snapshot; review any
new upstream changes before merging it into another branch.
