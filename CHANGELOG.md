# Changelog

## Unreleased

- The framework is now named LCGF. Downstream packages use `.lcgf` in their manifest, `@import("lcgf")` in Zig and `lcgf_render` for the selected renderer. The browser integration is `lcgf.js`.

- Comptime front ends support bounded dynamic regions, shared geometry and ordered paint. Applications can mix runtime and comptime regions in the same draw list. [Comptime guide](docs/guide/comptime.md)
- Embedded builds support Q12.4 geometry, RGB565 and monochrome panels, single-scanline rendering and a fixed-panel integer firmware profile. The SPI simulator replays the board's counter example and checks the displayed pixels. [Package options](docs/release/package.md)
- Dependency builds can import the core and selected renderer without configuring the repository's benchmarks, example programs or documentation tests. [Package options](docs/release/package.md)

## Maintaining the changelog

Add user-visible entries under **Unreleased** with the change that introduces them. Explain what a caller can do, which existing callers are affected and any migration needed. Link the guide, test or measured result that demonstrates it. Internal implementation changes need an entry when callers observe a behavior, performance, size, toolchain or compatibility difference.

Before a tag, compare the proposed revision to the previous release, review its dependency and compiler changes, and reconcile the entries with the actual diff. Rename the section to the released version and date, link the exact tag and comparison range, and start a new **Unreleased** section. The first release links the source tag directly. Publish the same notes with the tag, alongside the gate report for that revision. Mark unavailable or failing measurements explicitly. Apply the [compatibility policy](docs/release/compatibility.md) when classifying breaks or deprecations.
