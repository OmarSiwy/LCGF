//! Branch-census probe for the software renderer's per-pixel loops (docs/CHECKS.md section 2),
//! built into `zig build census-src-obj` through src/census_probes.zig. Not exported from
//! src/lcgr.zig.
const lcgr = @import("lcgr");
const sw = lcgr.render_sw;

/// Opaque spans use masked edge stores and whole-vector interior stores.
export fn p_sw_fill(fb: *sw.Framebuffer, box: *const [4]u32, c: u32) void {
    fb.fill(box.*, @bitCast(c));
}
/// The shading loop of each feature: the per-pixel work, with no branch on pixel data.
fn shade(comptime kind: lcgr.features.Kind, t: *const sw.Target, q: *const lcgr.draw_list.Quad, img: *const sw.Image, scale: f32) void {
    @call(.always_inline, sw.shade, .{ kind, t.*, q, img.*, scale });
}
export fn p_sw_solid(t: *const sw.Target, q: *const lcgr.draw_list.Quad, img: *const sw.Image, scale: f32) void {
    shade(.solid, t, q, img, scale);
}
export fn p_sw_linear(t: *const sw.Target, q: *const lcgr.draw_list.Quad, img: *const sw.Image, scale: f32) void {
    shade(.linear, t, q, img, scale);
}
export fn p_sw_radial(t: *const sw.Target, q: *const lcgr.draw_list.Quad, img: *const sw.Image, scale: f32) void {
    shade(.radial, t, q, img, scale);
}
export fn p_sw_shadow(t: *const sw.Target, q: *const lcgr.draw_list.Quad, img: *const sw.Image, scale: f32) void {
    shade(.shadow, t, q, img, scale);
}
export fn p_sw_nine_slice(t: *const sw.Target, q: *const lcgr.draw_list.Quad, img: *const sw.Image, scale: f32) void {
    shade(.nine_slice, t, q, img, scale);
}
export fn p_sw_dashed(t: *const sw.Target, q: *const lcgr.draw_list.Quad, img: *const sw.Image, scale: f32) void {
    shade(.dashed, t, q, img, scale);
}
export fn p_sw_dotted(t: *const sw.Target, q: *const lcgr.draw_list.Quad, img: *const sw.Image, scale: f32) void {
    shade(.dotted, t, q, img, scale);
}
