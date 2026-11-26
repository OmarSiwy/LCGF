//! images, written by hand: local PNGs through the asset table. `<img>` is
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
};

pub const spec = s.col(.{ .size = .{ .fill, .fill }, .fill = theme.panel }, .{
    s.row(.{ .pad = @splat(8), .gap = 8 }, .{
        s.named(image.ct.image(theme, assets[0].picture(), .{ .fit = .stretch, .radius = 0 }), "Icon"),
        image.ct.image(theme, assets[0].picture(), .{ .box = .{ 32, 20 }, .fit = .cover, .radius = 4 }),
        s.named(image.ct.image(theme, assets[0].picture(), .{ .box = .{ 40, 0 }, .fit = .stretch, .radius = 0 }), "Wide"),
        s.col(.{ .size = .{ .px(48), .px(24) }, .texture = @fromBackingInt(1), .fill = .white }, .{}),
    }),
});

pub const names = .{ "Icon", "Wide" };

pub fn Handlers(comptime Ui: type) type {
    _ = Ui;
    return struct {};
}

/// The generated table holds the pixels make.py computed for the file.
pub fn events(comptime page: type, p: anytype, h: anytype) !void {
    _ = p;
    _ = h;
    try std.testing.expectEqual(assets.len, page.assets.len);
    try std.testing.expectEqual(assets[0].texture, page.assets[0].texture);
    try std.testing.expectEqual(assets[0].image.w, page.assets[0].image.w);
    try std.testing.expectEqualSlices(u8, assets[0].image.pixels, page.assets[0].image.pixels);
}
