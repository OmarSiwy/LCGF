//! Printable ASCII coverage for Mono's fixed 0.6 em by 1.25 em cells. The
//! example package carries the rasterized font for use without a system font.
const lcgf = @import("lcgf");
const width = 16 * 9;
const height = 6 * 18;
const alpha: *const [width * height]u8 = @embedFile("font/mono.a8");
const pixels: [alpha.len]u32 = blk: {
    @setEvalBranchQuota(4 * alpha.len);
    var out: [alpha.len]u32 = undefined;
    for (alpha, &out) |a, *pixel| pixel.* = lcgf.types.Color.rgba(255, 255, 255, a).bitsOf();
    break :blk out;
};
pub const image: lcgf.render_sw.Image = .{ .pixels = &pixels, .width = width, .height = height };

/// The atlas has six rows of sixteen cells, starting at space. Other bytes
/// select the question-mark cell.
pub fn uv(byte: u8) error{}![4]f32 {
    const index = (if (byte >= 32 and byte <= 126) byte else @as(u8, '?')) - 32;
    const x: f32 = @floatFromInt(index % 16);
    const y: f32 = @floatFromInt(index / 16);
    return .{ x / 16, y / 6, (x + 1) / 16, (y + 1) / 6 };
}
