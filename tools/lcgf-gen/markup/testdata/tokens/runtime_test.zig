//! T-RT: the runtime page reads its `--t-*` tokens from the caller's table while it builds.
//! A change of the table is seen (`themeChanged`) and gives the new geometry on the next frame.

const std = @import("std");
const lcgf = @import("lcgf");
const page = @import("page_rt");

var buffer: [lcgf.context.Context.requiredBytes(page.limits)]u8 align(lcgf.mem.column_align) = undefined;

test "a changed token table lays the page out again with the new values" {
    var ctx = try lcgf.context.Context.init(&buffer, page.limits);
    var tokens: page.ThemeTable = .{};
    var ui: page.Ui = .{ .tokens = &tokens };
    const in: lcgf.input.Input = .{};

    var f = ctx.begin(&in);
    ui.build(&f);
    var out = f.end(.{});
    // body, card, title, body text: the card is node 2, the title node 3.
    const card0 = out.tree.rect(2);
    const title0 = out.tree.rect(3);
    try std.testing.expectEqual(8, title0.y0 - card0.y0);
    try std.testing.expect(!ui.themeChanged());

    tokens.set(.space, 20);
    tokens.set(.big, 30);
    tokens.set(.panel, .rgb(1, 2, 3));
    try std.testing.expect(ui.themeChanged());

    f = ctx.begin(&in);
    ui.build(&f);
    out = f.end(.{});
    const card1 = out.tree.rect(2);
    const title1 = out.tree.rect(3);
    try std.testing.expect(!ui.themeChanged());
    // Padding and gap followed the table: the title starts 20 px in, the body 20 px below it.
    try std.testing.expectEqual(20, title1.y0 - card1.y0);
    try std.testing.expectEqual(4, title1.x0 - card1.x0);
    const body1 = out.tree.rect(4);
    try std.testing.expectEqual(20, body1.y0 - title1.y1);
    // The bigger title is taller; the panel colour is the new one.
    try std.testing.expect(title1.y1 - title1.y0 > title0.y1 - title0.y0);
    try std.testing.expectEqual(lcgf.types.Color.rgb(1, 2, 3).bitsOf(), out.tree.c.look[2].fill);
}
