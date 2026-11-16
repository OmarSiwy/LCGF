//! Branch-census probe for the software renderer's per-pixel loops (docs/CHECKS.md section 2),
//! built into `zig build census-src-obj` through src/census_probes.zig. Not exported from
//! src/lcgr.zig.
const lcgr = @import("lcgr");
const sw = lcgr.render_sw;

/// Opaque spans: masked whole-vector stores.
export fn p_sw_fill(fb: *sw.Framebuffer, box: *const [4]u32, c: u32) void {
    fb.fill(box.*, @bitCast(c));
}
/// The shading loop of each feature: the per-pixel work, with no branch on pixel data.
fn shade(comptime kind: lcgr.features.Kind, t: *const sw.Target, q: *const lcgr.draw_list.Quad, scale: f32) void {
    @call(.always_inline, sw.shade, .{ kind, t.*, q, scale });
}
export fn p_sw_solid(t: *const sw.Target, q: *const lcgr.draw_list.Quad, scale: f32) void {
    shade(.solid, t, q, scale);
}
export fn p_sw_dashed(t: *const sw.Target, q: *const lcgr.draw_list.Quad, scale: f32) void {
    shade(.dashed, t, q, scale);
}
export fn p_sw_dotted(t: *const sw.Target, q: *const lcgr.draw_list.Quad, scale: f32) void {
    shade(.dotted, t, q, scale);
}
