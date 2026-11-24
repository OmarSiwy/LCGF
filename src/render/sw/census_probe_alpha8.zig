//! Alpha8 pixel-loop census, compiled as its own object by census-src-obj.
//! Keep RGBA probes in census_src.o: putting equivalent format specializations
//! in one object lets LLVM merge them into shared bodies behind tiny wrappers.
const lcgf = @import("lcgf");
const sw = lcgf.render_sw;

/// A valid Alpha8 binding has nonempty coverage storage. The precondition lets
/// ReleaseFast specialize the public shader's once-per-call format dispatch.
/// Preserve the real pointer and length; geometry, dimensions, coverage,
/// clipping, blending, and every pixel/row iteration remain runtime inputs.
fn shadeAlpha8(comptime kind: lcgf.features.Kind, t: *const sw.Target, q: *const lcgf.draw_list.Quad, img: *const sw.Image, scale: f32) void {
    if (img.alpha8.len == 0) unreachable;
    @call(.always_inline, sw.shade, .{ kind, t.*, q, img.*, scale });
}

export fn p_sw_alpha8_solid(t: *const sw.Target, q: *const lcgf.draw_list.Quad, img: *const sw.Image, scale: f32) void {
    shadeAlpha8(.solid, t, q, img, scale);
}
export fn p_sw_alpha8_linear(t: *const sw.Target, q: *const lcgf.draw_list.Quad, img: *const sw.Image, scale: f32) void {
    shadeAlpha8(.linear, t, q, img, scale);
}
export fn p_sw_alpha8_radial(t: *const sw.Target, q: *const lcgf.draw_list.Quad, img: *const sw.Image, scale: f32) void {
    shadeAlpha8(.radial, t, q, img, scale);
}
export fn p_sw_alpha8_shadow(t: *const sw.Target, q: *const lcgf.draw_list.Quad, img: *const sw.Image, scale: f32) void {
    shadeAlpha8(.shadow, t, q, img, scale);
}
export fn p_sw_alpha8_nine_slice(t: *const sw.Target, q: *const lcgf.draw_list.Quad, img: *const sw.Image, scale: f32) void {
    shadeAlpha8(.nine_slice, t, q, img, scale);
}
export fn p_sw_alpha8_dashed(t: *const sw.Target, q: *const lcgf.draw_list.Quad, img: *const sw.Image, scale: f32) void {
    shadeAlpha8(.dashed, t, q, img, scale);
}
export fn p_sw_alpha8_dotted(t: *const sw.Target, q: *const lcgf.draw_list.Quad, img: *const sw.Image, scale: f32) void {
    shadeAlpha8(.dotted, t, q, img, scale);
}
