//! Branch-census probe for the software renderer's per-pixel loops (docs/CHECKS.md section 2),
//! built into `zig build census-src-obj` through src/census_probes.zig. Not exported from
//! src/lcgf.zig. Alpha8 probes live in a separate object so LLVM cannot merge
//! equivalent cross-format bodies and leave an exported wrapper hiding a loop.
const lcgf = @import("lcgf");
const sw = lcgf.render_sw;

/// Opaque spans use masked edge stores and whole-vector interior stores.
export fn p_sw_fill(fb: *sw.Framebuffer, box: *const [4]u32, c: u32) void {
    fb.fill(box.*, @bitCast(c));
}
/// Census each actual format's pixel loop separately. Public shade chooses the
/// format once per call; counting both alternatives together doubles the loop
/// controls without identifying a branch on pixel data. The legacy names keep
/// their RGBA input contract and existing branch ceilings.
fn shadeRgba(comptime kind: lcgf.features.Kind, t: *const sw.Target, q: *const lcgf.draw_list.Quad, img: *const sw.Image, scale: f32) void {
    const rgba: sw.Image = .{ .pixels = img.pixels, .width = img.width, .height = img.height };
    @call(.always_inline, sw.shade, .{ kind, t.*, q, rgba, scale });
}

export fn p_sw_solid(t: *const sw.Target, q: *const lcgf.draw_list.Quad, img: *const sw.Image, scale: f32) void {
    shadeRgba(.solid, t, q, img, scale);
}
export fn p_sw_linear(t: *const sw.Target, q: *const lcgf.draw_list.Quad, img: *const sw.Image, scale: f32) void {
    shadeRgba(.linear, t, q, img, scale);
}
export fn p_sw_radial(t: *const sw.Target, q: *const lcgf.draw_list.Quad, img: *const sw.Image, scale: f32) void {
    shadeRgba(.radial, t, q, img, scale);
}
export fn p_sw_shadow(t: *const sw.Target, q: *const lcgf.draw_list.Quad, img: *const sw.Image, scale: f32) void {
    shadeRgba(.shadow, t, q, img, scale);
}
export fn p_sw_nine_slice(t: *const sw.Target, q: *const lcgf.draw_list.Quad, img: *const sw.Image, scale: f32) void {
    shadeRgba(.nine_slice, t, q, img, scale);
}
export fn p_sw_dashed(t: *const sw.Target, q: *const lcgf.draw_list.Quad, img: *const sw.Image, scale: f32) void {
    shadeRgba(.dashed, t, q, img, scale);
}
export fn p_sw_dotted(t: *const sw.Target, q: *const lcgf.draw_list.Quad, img: *const sw.Image, scale: f32) void {
    shadeRgba(.dotted, t, q, img, scale);
}
