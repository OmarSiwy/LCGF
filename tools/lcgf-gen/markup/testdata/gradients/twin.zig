//! gradients, written by hand: CSS gradients of more than two colours, or with stops away from
//! the ends, as ramp rows (`features.rampPixels`) in the asset table drawn by
//! `features.linearRamp` / `radialRamp`; two-colour gradients keep `features.linear` and
//! `radial`. A radial gradient without a radius takes CSS's farthest corner of its px box.

const std = @import("std");
const lcgf = @import("lcgf");
const s = lcgf.spec;
const w = lcgf.widgets_base;
const image = lcgf.widgets_image;
const features = lcgf.features;
const Stop = features.Stop;

pub const theme: w.Theme = .{};

/// The ramp row lcgf-gen makes: 256 texels of `stops`.
fn ramp(comptime stops: []const Stop) image.Asset {
    const px = comptime blk: {
        @setEvalBranchQuota(200_000);
        var row: [256]u32 = undefined;
        features.rampPixels(stops, &row);
        break :blk row;
    };
    return .{ .texture = undefined, .image = .{ .w = 256, .h = 1, .pixels = std.mem.sliceAsBytes(&px) } };
}

fn at(comptime a: image.Asset, comptime k: u16) image.Asset {
    var out = a;
    out.texture = @fromBackingInt(k);
    return out;
}

pub const assets = [_]image.Asset{
    at(ramp(&.{ .{ .color = .rgb(255, 0, 0), .at = 0 }, .{ .color = .rgb(255, 255, 0), .at = 0.5 }, .{ .color = .rgb(0, 0, 255), .at = 1 } }), 1),
    at(ramp(&.{ .{ .color = .rgb(0x10, 0x20, 0x30), .at = 0 }, .{ .color = .rgb(0x40, 0xc0, 0x80), .at = 0.3 }, .{ .color = .white, .at = 0.6 }, .{ .color = .rgb(0xa0, 0x30, 0xc0), .at = 1 } }), 2),
    at(ramp(&.{ .{ .color = .white, .at = 0 }, .{ .color = .rgb(255, 165, 0), .at = 0.4 }, .{ .color = .rgba(60, 20, 90, 0), .at = 1 } }), 3),
    at(ramp(&.{ .{ .color = .rgb(255, 0, 0), .at = 0.25 }, .{ .color = .rgb(0, 128, 0), .at = 0.25 }, .{ .color = .rgb(0, 128, 0), .at = 0.75 }, .{ .color = .rgb(0, 0, 255), .at = 0.75 } }), 4),
    at(ramp(&.{ .{ .color = .black, .at = 0.2 }, .{ .color = .white, .at = 0.8 } }), 5),
};

const box: lcgf.types.Style = .{ .size = .{ .px(80), .px(60) } };

fn with(comptime st: lcgf.types.Style) lcgf.types.Style {
    var out = box;
    inline for (.{ "fill", "radius", "texture", "params" }) |f| @field(out, f) = @field(st, f);
    return out;
}

pub const spec = s.col(.{ .size = .{ .fill, .fill }, .fill = theme.panel }, .{
    s.row(.{ .pad = @splat(8), .gap = 8 }, .{
        s.col(with(.{ .fill = .white, .texture = @fromBackingInt(1), .params = features.linearRamp(0) }), .{}),
        s.col(with(.{ .fill = .white, .radius = 8, .texture = @fromBackingInt(2), .params = features.linearRamp(-std.math.pi / 4.0) }), .{}),
        s.col(with(.{ .fill = .white, .texture = @fromBackingInt(3), .params = features.radialRamp(.{ 0.5, 0.5 }, 40) }), .{}),
        s.col(with(.{ .fill = .white, .texture = @fromBackingInt(4), .params = features.linearRamp(std.math.pi / 2.0) }), .{}),
        s.col(with(.{ .fill = .rgb(255, 150, 32), .params = features.radial(.rgb(60, 20, 90), .{ 0.25, 0.25 }, 75) }), .{}),
        s.col(with(.{ .fill = .white, .texture = @fromBackingInt(5), .params = features.linearRamp(0) }), .{}),
    }),
});

pub fn Handlers(comptime Ui: type) type {
    _ = Ui;
    return struct {};
}

/// The generated ramps are the rows `features.rampPixels` makes of the same stops.
pub fn events(comptime page: type, p: anytype, h: anytype) !void {
    _ = p;
    _ = h;
    try std.testing.expectEqual(assets.len, page.assets.len);
    inline for (assets, page.assets) |a, b| {
        try std.testing.expectEqual(a.texture, b.texture);
        try std.testing.expectEqualSlices(u8, a.image.pixels, b.image.pixels);
    }
}
