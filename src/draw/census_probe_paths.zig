//! Branch-census probe for src/draw/paths.zig (docs/CHECKS.md section 2): one exported function
//! per pass, built into `zig build census-src-obj` through src/census_probes.zig. Not exported
//! from src/lcgr.zig.
const lcgr = @import("lcgr");
const paths = lcgr.paths;

export fn p_path_flatten(p: *const paths.Path, out: *paths.Polyline) void {
    paths.flatten(p, 0.25, out);
}
export fn p_path_stroke(l: *const paths.Polyline, out: *paths.Polyline) void {
    paths.stroke(l, .{ .width = 2 }, 0.25, out);
}
export fn p_path_fill(l: *const paths.Polyline, b: *const paths.Box, s: *const paths.Scratch, acc: [*]f32, n: usize) void {
    paths.fill(l, b.*, .nonzero, s.*, acc[0..n]);
}
