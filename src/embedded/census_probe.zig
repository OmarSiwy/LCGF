//! Branch-census probe for the embedded profile's per-pixel loops (docs/CHECKS.md section 2),
//! built into `zig build census-src-obj` through src/census_probes.zig. Not exported from
//! src/lcgr.zig.
const lcgr = @import("lcgr");
const fb = lcgr.embedded_framebuffer;

/// A row of sw pixels to RGB565.
export fn p_embedded_rgb565(dst: [*]u16, src: [*]const u32, n: u32) void {
    fb.convert(.rgb565, dst[0..n], src[0..n], n, .rgba8);
}
/// A row of sw pixels to 1-bit, eight a byte.
export fn p_embedded_mono(dst: [*]u8, src: [*]const u32, n: u32) void {
    fb.convert(.mono, dst[0..fb.units(.mono, n)], src[0..n], n, .rgba8);
}
