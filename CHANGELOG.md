# Changelog


## Unreleased — comprehensive styling branch

- Add typed style resolution, semantic tokens, scoped recipes and parts, combined states,
  system/contrast/locale policies, authoring/import tools and computed-style diagnostics.
- Extend common geometry across transforms, clip chains, input, text, custom drawing,
  accessibility and damage; add explicit participation, device-grid rounding and caller-owned hit targets.
- Add portable composed decorations, brushes/image sampling, vector imports, masks,
  isolated groups, filters/backdrop operations, projective planes and managed color conversion.
- Extend measured text/layout with intrinsic sizes, rich shaping/fallback, font generations,
  advanced grids, typography/publication helpers and optional HarfBuzz variable/color-font consumers.
- Extend cursor/native-material presentation and make animation-capacity failure observable
  without replacing unrelated controls.
- Preserve the 136-byte GPU Quad and 32-byte Look. CPU TextRun/CustomDraw are now 96 bytes;
  recompile consumers and update raw CPU-row serialization. Runtime Context capacity is 1004 bytes/node.
- Add the executable styling gallery, five-workload CPU benchmark and inventory evidence check.

See [the implementation guide](docs/styling/README.md), [capability profiles](docs/styling/coverage.md)
and [validation report](docs/styling/validation.md). Native platform and standards-conformance
boundaries are explicit; this is a development branch, not a versioned upstream release.

## Unreleased

- The framework is now named LCGF. Downstream packages use `.lcgf` in their manifest, `@import("lcgf")` in Zig and `lcgf_render` for the selected renderer. The browser integration is `lcgf.js`.

- Comptime front ends support bounded dynamic regions, shared geometry and ordered paint. Applications can mix runtime and comptime regions in the same draw list. [Comptime guide](docs/guide/comptime.md)
- Embedded builds support Q12.4 geometry, RGB565 and monochrome panels, single-scanline rendering and a fixed-panel integer firmware profile. The SPI simulator replays the board's counter example and checks the displayed pixels. [Package options](docs/release/package.md)
- Dependency builds can import the core and selected renderer without configuring the repository's benchmarks, example programs or documentation tests. [Package options](docs/release/package.md)

## Maintaining the changelog

Add user-visible entries under **Unreleased** with the change that introduces them. Explain what a caller can do, which existing callers are affected and any migration needed. Link the guide, test or measured result that demonstrates it. Internal implementation changes need an entry when callers observe a behavior, performance, size, toolchain or compatibility difference.

Before a tag, compare the proposed revision to the previous release, review its dependency and compiler changes, and reconcile the entries with the actual diff. Rename the section to the released version and date, link the exact tag and comparison range, and start a new **Unreleased** section. The first release links the source tag directly. Publish the same notes with the tag, alongside the gate report for that revision. Mark unavailable or failing measurements explicitly. Apply the [compatibility policy](docs/release/compatibility.md) when classifying breaks or deprecations.
