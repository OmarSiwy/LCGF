//! Text-heavy: 48 wrapped paragraphs under 12 headings beside a sidebar of 120 short labels,
//! 1,280 px wide, with the pointer moving across it.
const std = @import("std");
const ui = @import("ui");
const Scene = @import("scenes.zig").Scene;

pub const scene: Scene = .{ .name = "text", .frames = 3000, .input = input, .build = build };

const sections = 12;
const paragraphs = 4;
const labels = 120;
const prose = [_][]const u8{
    "Columns of rows replace trees of objects: every pass walks a few dense arrays from start to end, so the cache sees one stream per field and the vector units take eight rows at a time.",
    "A frame is rebuilt from scratch, laid out in a handful of passes and painted into a draw list that a renderer submits as it is. Nothing outlives the frame except what the caller keeps.",
    "Text is measured once per run and wrapped against the width the layout grants; lines break at spaces, and a word wider than the line is broken where it overflows.",
    "Idle costs nothing: when no input arrives and no spring moves, no frame is built, so the process sleeps until the next event and the battery is left alone.",
};

fn input(in: *ui.Input, k: u32) void {
    in.viewport = .{ 1280, 800 };
    in.pointer = .{ @floatFromInt(20 + (k * 7) % 1240), @floatFromInt(20 + (k * 13) % 760) };
}

/// Shared with the resize scene.
pub fn build(f: *ui.Frame, th: *const ui.Theme) void {
    _ = f.open(ui.Id.from("text"), .{ .dir = .x, .size = .{ .fill, .fill }, .gap = 16, .pad = @splat(12), .clip = true });
    _ = f.open(.none, .{ .size = .{ .px(160), .fill }, .gap = 2 });
    var buf: [16]u8 = undefined;
    for (0..labels) |i| _ = ui.widgets.label(f, th, std.fmt.bufPrint(&buf, "Chapter {d}", .{i + 1}) catch unreachable);
    f.close();
    _ = f.open(.none, .{ .size = .{ .grow(1), .fit }, .gap = 8, .shrink = true });
    for (0..sections) |s| {
        _ = f.text(std.fmt.bufPrint(&buf, "Section {d}", .{s + 1}) catch unreachable, .{ .px = 20, .color = th.text });
        for (0..paragraphs) |p| _ = f.text(prose[(s + p) % prose.len], .{ .px = th.text_px, .color = th.text, .wrap = true });
    }
    f.close();
    f.close();
}
