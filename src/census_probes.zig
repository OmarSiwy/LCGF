//! Root of the census object (`zig build census-src-obj`): one import line per probe file. Each
//! area keeps its exports in its own `census_probe*.zig`, so lanes add a file and one line here
//! (this file merges by union) instead of editing a shared probe. Not exported from lcgr.zig.
comptime {
    _ = @import("layout/census_probe.zig");
    _ = @import("draw/census_probe.zig");
    _ = @import("draw/census_probe_paths.zig");
    _ = @import("interact/census_probe.zig");
    _ = @import("text/census_probe.zig");
    _ = @import("a11y/census_probe.zig");
    _ = @import("render/sw/census_probe.zig");
}
