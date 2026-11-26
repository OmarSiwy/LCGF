//! images, written by hand: local PNGs and an SVG through the asset table. `<img>` is
//! `image.ct.image` over the asset's picture (CSS fill by default, `object-fit: cover`, a
//! width alone keeping the shape, no corner radius unless set); `background-image: url()`
//! is the asset's texture over the box. The generated table holds the pixels lcgf-gen
//! decoded; the twin embeds those src/assets/testdata/make.py computed for the same file
//! (icon.png is icon16.png, icon.rgba its premultiplied pixels), and they must be equal.

const std = @import("std");
const lcgf = @import("lcgf");
const s = lcgf.spec;
const w = lcgf.widgets_base;
const image = lcgf.widgets_image;

pub const theme: w.Theme = .{};

pub const assets = [_]image.Asset{
    .{ .texture = @fromBackingInt(1), .image = .{ .w = 16, .h = 16, .pixels = @embedFile("icon.rgba") } },
    // badge.svg drawn by draw/svg.zig at its own size and at a width of 48: the pixels
    // lcgf-gen made when this fixture was written (a regression check of the SVG path).
    .{ .texture = @fromBackingInt(2), .image = .{ .w = 24, .h = 24, .pixels = @embedFile("badge24.rgba") } },
    .{ .texture = @fromBackingInt(3), .image = .{ .w = 48, .h = 48, .pixels = @embedFile("badge48.rgba") } },
};

pub const spec = s.col(.{ .size = .{ .fill, .fill }, .fill = theme.panel }, .{
    s.row(.{ .pad = @splat(8), .gap = 8 }, .{
        s.named(image.ct.image(theme, assets[0].picture(), .{ .fit = .stretch, .radius = 0 }), "Icon"),
        image.ct.image(theme, assets[0].picture(), .{ .box = .{ 32, 20 }, .fit = .cover, .radius = 4 }),
        s.named(image.ct.image(theme, assets[0].picture(), .{ .box = .{ 40, 0 }, .fit = .stretch, .radius = 0 }), "Wide"),
        s.named(image.ct.image(theme, assets[1].picture(), .{ .fit = .stretch, .radius = 0 }), "Badge"),
        image.ct.image(theme, assets[2].picture(), .{ .box = .{ 48, 0 }, .fit = .stretch, .radius = 0 }),
        s.col(.{ .size = .{ .px(48), .px(24) }, .texture = @fromBackingInt(1), .fill = .white }, .{}),
    }),
});

pub const names = .{ "Icon", "Wide", "Badge" };

pub fn Handlers(comptime Ui: type) type {
    _ = Ui;
    return struct {};
}

/// The generated table holds the pixels make.py computed for the file.
pub fn events(comptime page: type, p: anytype, h: anytype) !void {
    _ = p;
    _ = h;
    try std.testing.expectEqual(assets.len, page.assets.len);
    inline for (assets, page.assets) |a, b| {
        try std.testing.expectEqual(a.texture, b.texture);
        try std.testing.expectEqual(a.image.w, b.image.w);
        try std.testing.expectEqual(a.image.h, b.image.h);
        try std.testing.expectEqualSlices(u8, a.image.pixels, b.image.pixels);
    }
}
