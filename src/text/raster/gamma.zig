//! Gamma-correct blending tables for glyph coverage. Tier 0.
//!
//! The renderer blends a glyph as `out = a * text + (1 - a) * background` on gamma-encoded
//! (sRGB) values, because that is what a GPU blend unit or a plain software loop does. Coverage
//! is a fraction of area, so the correct blend is in linear light:
//! `out = enc(a * dec(text) + (1 - a) * dec(background))`. Blending encoded values instead
//! makes dark text on light too bold and light text on dark too thin.
//!
//! The fix that keeps the blend unit as it is (Skia's and WebRender's "preblend"): correct the
//! coverage before blending, so that the encoded blend lands where the linear one would. The
//! corrected coverage depends on the text and background luminance. The text's is known per
//! run; the background's is not, so the table assumes the contrasting extreme (white behind
//! dark text, black behind light text), which is where the error is largest and most visible.
//! For those two cases the result is exact up to rounding; between them it is a blend.
//!
//! A `Gamma` holds one row of 256 corrected coverages per luminance bucket (2 KB); `apply`
//! maps a coverage image through the row of a run's text luminance.

const std = @import("std");

pub const Gamma = struct {
    /// rows[b][a]: coverage `a` corrected for text luminance (b / (buckets - 1)).
    rows: [buckets][256]u8,

    /// Text luminances are quantised to this many buckets, black and white included.
    pub const buckets = 8;

    /// The tables for display gamma `gamma` (2.2 for sRGB; 1 gives the identity).
    pub fn init(gamma: f32) Gamma {
        var g: Gamma = undefined;
        for (&g.rows, 0..) |*row, b| {
            const l = @as(f32, @floatFromInt(b)) / (buckets - 1);
            // The background assumed behind text of luminance l.
            const bg = 1 - l;
            const dl = std.math.pow(f32, l, gamma);
            const dbg = std.math.pow(f32, bg, gamma);
            for (row, 0..) |*e, a| {
                const cov = @as(f32, @floatFromInt(a)) / 255;
                const target = std.math.pow(f32, cov * dl + (1 - cov) * dbg, 1 / gamma);
                // Solve a' * l + (1 - a') * bg = target for a'. Mid grey on mid grey has no
                // contrast to correct.
                const flat = @abs(l - bg) < 1e-3;
                const corrected = if (flat) cov else (target - bg) / (l - bg);
                e.* = @intFromFloat(std.math.clamp(corrected, 0, 1) * 255 + 0.5);
            }
        }
        return g;
    }

    /// The bucket of a text colour of luminance `lum` (0 black to 255 white, encoded).
    pub fn bucket(lum: u8) u32 {
        return (@as(u32, lum) * (buckets - 1) + 127) / 255;
    }

    /// `out[i] = corrected(cov[i])` for text of luminance `lum`. A table lookup per
    /// pixel: no branch, and `out` may be `cov`.
    pub fn apply(g: *const Gamma, lum: u8, cov: []const u8, out: []u8) void {
        std.debug.assert(out.len >= cov.len);
        const row = &g.rows[bucket(lum)];
        for (cov, out[0..cov.len]) |a, *o| o.* = row[a];
    }
};

/// Encoded luminance of an sRGB colour, Rec. 709 weights on the encoded channels (the
/// approximation preblend tables use; the bucket is coarse anyway).
pub fn luminance(r: u8, g: u8, b: u8) u8 {
    return @intCast((@as(u32, r) * 54 + @as(u32, g) * 183 + @as(u32, b) * 19 + 128) >> 8);
}

// ---------------------------------------------------------------------------------------------

const raster = @import("raster.zig");
const opentype = @import("../font/opentype.zig");

/// One blended pixel, on encoded values the way a blend unit does it.
fn blendEncoded(a: u8, text: u8, bg: u8) f32 {
    const af = @as(f32, @floatFromInt(a)) / 255;
    return af * @as(f32, @floatFromInt(text)) + (1 - af) * @as(f32, @floatFromInt(bg));
}

/// The reference: the same pixel blended in linear light, encoded back.
fn blendLinear(a: u8, text: u8, bg: u8, gamma: f32) f32 {
    const af = @as(f32, @floatFromInt(a)) / 255;
    const t = std.math.pow(f32, @as(f32, @floatFromInt(text)) / 255, gamma);
    const b = std.math.pow(f32, @as(f32, @floatFromInt(bg)) / 255, gamma);
    return std.math.pow(f32, af * t + (1 - af) * b, 1 / gamma) * 255;
}

test "blended glyph images match linear-light references" {
    // References: the FreeType coverage of testdata/ref.bin blended in linear light (gamma 2.2),
    // black on white and white on black. Checked twice: the table alone (FreeType's coverage,
    // corrected, blended on encoded values), and the whole stack (this rasteriser's coverage,
    // corrected, blended on encoded values).
    const gamma = 2.2;
    const g: Gamma = .init(gamma);
    const face = try opentype.Face.parse(raster.test_font, 0);
    var cols: raster.TestOutline = .{};
    var o = cols.outline();
    var acc: [64 * 64]f32 = undefined;
    var cov: [64 * 64]u8 = undefined;
    var it: raster.RefIter = .{};
    var table_max: f32 = 0;
    var plain_max: f32 = 0;
    var stack_sum: f64 = 0;
    var pixels: f64 = 0;
    while (it.next()) |r| {
        if (r.offset != 0) continue;
        const b, const img = raster.render(face, r, &o, &acc, &cov);
        for ([_][2]u8{ .{ 0, 255 }, .{ 255, 0 } }) |c| {
            var ours: [64 * 64]u8 = undefined;
            var theirs: [64 * 64]u8 = undefined;
            g.apply(c[0], img, &ours);
            g.apply(c[0], r.pixels, &theirs);
            var y = r.b.top;
            while (y > r.b.top - @as(i32, @intCast(r.b.h))) : (y -= 1) {
                var x = r.b.left;
                while (x < r.b.left + @as(i32, @intCast(r.b.w))) : (x += 1) {
                    const ref = raster.pixel(r.b, r.pixels, x, y);
                    const want = blendLinear(ref, c[0], c[1], gamma);
                    table_max = @max(table_max, @abs(blendEncoded(raster.pixel(r.b, &theirs, x, y), c[0], c[1]) - want));
                    plain_max = @max(plain_max, @abs(blendEncoded(ref, c[0], c[1]) - want));
                    stack_sum += @abs(blendEncoded(raster.pixel(b, &ours, x, y), c[0], c[1]) - want);
                    pixels += 1;
                }
            }
        }
    }
    // The table reproduces the linear blend to rounding (measured: 0.49 levels of 255).
    try std.testing.expect(table_max <= 1);
    // Without it the encoded blend is off by up to 72 levels: what the table fixes.
    try std.testing.expect(plain_max > 60);
    // The whole stack, on average within a level (measured: 0.63). Per pixel the rasteriser's
    // own difference from FreeType (14 levels of coverage) is stretched where gamma is steep,
    // near zero coverage of light text: up to 39 levels there.
    try std.testing.expect(stack_sum / pixels < 1);
}

test "the tables are the identity at gamma 1 and for mid grey" {
    const g: Gamma = .init(1);
    for (0..Gamma.buckets) |b| {
        for (0..256) |a| try std.testing.expectEqual(@as(u8, @intCast(a)), g.rows[b][a]);
    }
    const g22: Gamma = .init(2.2);
    // Full and no coverage stay as they are; black text on white gets lighter, white text on
    // black heavier.
    try std.testing.expectEqual(0, g22.rows[0][0]);
    try std.testing.expectEqual(255, g22.rows[0][255]);
    try std.testing.expect(g22.rows[0][128] < 128);
    try std.testing.expect(g22.rows[Gamma.buckets - 1][128] > 128);
    try std.testing.expectEqual(0, Gamma.bucket(0));
    try std.testing.expectEqual(Gamma.buckets - 1, Gamma.bucket(255));
    try std.testing.expectEqual(255, luminance(255, 255, 255));
    try std.testing.expectEqual(0, luminance(0, 0, 0));
}
