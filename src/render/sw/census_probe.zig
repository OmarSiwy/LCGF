//! Branch-census probe for the software renderer's per-pixel loops (docs/CHECKS.md section 2),
//! built into `zig build census-src-obj` through src/census_probes.zig. Not exported from
//! src/lcgr.zig.
const lcgr = @import("lcgr");
const sw = lcgr.render_sw;

/// Opaque spans: masked whole-vector stores.
export fn p_sw_fill(fb: *sw.Framebuffer, box: *const [4]u32, c: u32) void {
    fb.fill(box.*, @bitCast(c));
}
