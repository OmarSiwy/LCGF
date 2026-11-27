//! Long list: 100,000 rows of 24 px, virtualised (target E1): only the rows inside the 800 px
//! window are built, between two spacers that stand for the rest. The list scrolls 997 px a frame.
const std = @import("std");
const ui = @import("ui");
const Scene = @import("scenes.zig").Scene;

pub const scene: Scene = .{ .name = "list", .frames = 3000, .input = input, .build = build, .every = true };

const total = 100_000;
const row_h = 24;
const view: [2]f32 = .{ 1280, 800 };
/// Rows inside the window, plus one cut at each edge.
const visible = @as(u32, @intFromFloat(view[1])) / row_h + 2;
const names = [_][]const u8{ "alpha", "bravo", "charlie", "delta", "echo", "foxtrot", "golf" };

/// Pixels scrolled, set by `input` for the frame `build` makes.
var scroll: u32 = 0;

fn input(in: *ui.Input, k: u32) void {
    in.viewport = view;
    in.pointer = .{ 640, @floatFromInt(10 + (k * 13) % 780) };
    scroll = (k * 997) % (total * row_h - @as(u32, @intFromFloat(view[1])));
}

fn build(f: *ui.Frame, th: *const ui.Theme) void {
    const first = scroll / row_h;
    // u32 on purpose: `@min` against the constant would give a u17, and the spacer below
    // multiplies it by the row height.
    const end: u32 = @min(first + visible, total);
    _ = f.open(ui.Id.from("list"), .{ .size = .{ .fill, .fill }, .clip = true, .scroll = .{ 0, @floatFromInt(scroll) } });
    _ = f.leaf(.none, .{ .size = .{ .fill, .px(@floatFromInt(first * row_h)) } });
    const fills = [2]ui.Color{ th.panel, th.control };
    for (first..end) |r| {
        _ = f.open(.none, .{ .dir = .x, .size = .{ .fill, .px(row_h) }, .gap = th.gap, .pad = .{ 8, 0, 8, 0 }, .cross = .center, .fill = fills[r % 2] });
        var buf: [16]u8 = undefined;
        _ = ui.widgets.label(f, th, std.fmt.bufPrint(&buf, "Row {d}", .{r}) catch unreachable);
        _ = ui.widgets.label(f, th, names[r % names.len]);
        _ = f.leaf(.none, .{ .size = .{ .px(12), .px(12) }, .fill = th.accent });
        f.close();
    }
    _ = f.leaf(.none, .{ .size = .{ .fill, .px(@floatFromInt((total - end) * row_h)) } });
    f.close();
}
