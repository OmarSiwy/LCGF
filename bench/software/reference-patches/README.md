# Reconstruct the measured reference

The `baseline` fields in the archived stage-2 JSON mean the **previously
optimized** framework: commit
`ed94db3da27882ef1c87d0dd15a382b4df39e2c2` plus these three original patches,
in order. They do not mean pristine upstream LCGF.

| Patch | Change |
|---|---|
| [01-skip-empty-input-identities.patch](01-skip-empty-input-identities.patch) | Skip zero active/focus identity searches; preserve live identity resolution. |
| [02-skip-unneeded-mono-wrap.patch](02-skip-unneeded-mono-wrap.patch) | Avoid rewriting text extents when no Mono run requests wrapping. |
| [03-specialize-software-rasterization.patch](03-specialize-software-rasterization.patch) | Initial white-binding/textured-rectangle specialization and restricted opaque interiors. |

The files are byte-identical to the original patch series. Their SHA-256 values
are in [provenance.json](../provenance.json). From the containing repository
root, choose an unused sibling worktree path:

```sh
lcgf_review_root="$(git rev-parse --show-toplevel)"
git worktree add --detach ../lcgf-software-reference \
  ed94db3da27882ef1c87d0dd15a382b4df39e2c2 || exit 1
for patch in "$lcgf_review_root"/bench/software/reference-patches/0[1-3]-*.patch; do
  git -C ../lcgf-software-reference apply --check "$patch" || exit 1
  git -C ../lcgf-software-reference apply "$patch" || exit 1
done
git -C ../lcgf-software-reference diff --check
```

Use the same version of the
architecture lab (`examples/architecture-lab/README.md` at `e0ad0404`) in an external
copy, selecting that worktree with `zig fetch --save=lcgf PATH_TO_CHECKOUT` as
the example guide describes. Build `bench-build reuse_bench-build` for the
reference; `incremental_bench-build` requires the current retained host. Build
the candidate separately and compare executable paths using the
benchmark runners (`examples/architecture-lab/docs/BENCHMARKS.md` at `e0ad0404`).
Use Zig `0.18.0-dev.1151+8dfb7a7cc`, the same target/vector width, and the same
application sources and limits on both sides. Reconstructed binaries constitute
a new run; their packaging and hashes can differ from the archived executables.

## Borderless-interior ablation

[ablation-borderless-interior.patch](ablation-borderless-interior.patch) is a
separate source difference from the renderer immediately before the
zero/subthreshold-border extension to the measured final renderer. It includes
the eligibility change, helper rename, comments, and regression tests. It does
not belong to the three-patch reference above.

Reverse-apply this patch in a separate copy of the measured candidate to
reconstruct the ablation's `before` renderer; leave the `after` renderer
unchanged. Both copies use the current retained/Alpha8 implementation. Keep
other sources and build settings identical. The exact historical paired
commands, binary hashes, and output hashes are preserved with the
[ablation results](../results/borderless-ablation/summary.json).
