//! Printable ASCII coverage for Mono's fixed 0.6 em by 1.25 em cells. The
//! example package carries the rasterized font for use without a system font.
const lcgf = @import("lcgf");
const width = 16 * 9;
const height = 6 * 18;
const alpha: *const [width * height]u8 = @embedFile("font/mono.a8");
// The renderer samples coverage directly; white RGB is part of the Alpha8 contract.
// Keep the embedded atlas at one byte per texel instead of expanding it fourfold.
pub const image: lcgf.render_sw.Image = .{ .alpha8 = alpha, .width = width, .height = height };

/// The atlas has six rows of sixteen cells, printable ASCII from space. Other bytes
/// select the question-mark cell. Pass it as a canvas label's `atlas` (`Instances.glyphs`).
pub const cells: lcgf.protocol.Atlas = .grid(16, 6, ' ', '~');

/// `cells`' UV rect of `byte`, as `Mono.quadsFor` takes a grid.
pub fn uv(byte: u8) error{}![4]f32 {
    return cells.uv(byte);
}
