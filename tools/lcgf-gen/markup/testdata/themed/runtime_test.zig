//! The themed page in the runtime frontend: its card is the component's runtime form, which
//! gets the token's value, so a changed table lays the card out again on the next frame.

const std = @import("std");
const lcgf = @import("lcgf");
const page = @import("page_rt");

var buffer: [lcgf.context.Context.requiredBytes(page.limits)]u8 align(lcgf.mem.column_align) = undefined;

fn runOf(d: *const lcgf.draw_list.DrawList, text: []const u8) ?[4]f32 {
    for (d.runs[0..d.run_len]) |r| if (std.mem.eql(u8, d.strings[r.start..][0..r.bytes], text)) return r.rect;
    return null;
}

test "the card's padding follows the token table" {
    var ctx = try lcgf.context.Context.init(&buffer, page.limits);
    var tokens: page.ThemeTable = .{};
    var ui: page.Ui = .{ .tokens = &tokens };
    const in: lcgf.input.Input = .{};

    var f = ctx.begin(&in);
    ui.build(&f);
    const before = runOf(f.end(.{}).draw, "Inside").?;

    tokens.set(.space, 20);
    try std.testing.expect(ui.themeChanged());
    f = ctx.begin(&in);
    ui.build(&f);
    const after = runOf(f.end(.{}).draw, "Inside").?;
    try std.testing.expectEqual(before[0] + 14, after[0]);
    try std.testing.expectEqual(before[1] + 14, after[1]);
}
