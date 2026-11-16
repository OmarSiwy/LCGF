//! The default scene: 330 rows of label, two buttons, checkbox, slider and accent leaf, 3,961
//! nodes and 1,320 text runs (the scene of docs/CHECKS.md section 3, so the numbers compare),
//! with the pointer moving across it.
const ui = @import("ui");
const Scene = @import("scenes.zig").Scene;

pub const scene: Scene = .{ .name = "rows", .frames = 3000, .input = input, .build = build, .every = true };

pub const count = 330;
var values: [count]f32 = @splat(0.5);
var checks: [count]bool = @splat(false);

fn input(in: *ui.Input, k: u32) void {
    in.viewport = .{ 1280, 8000 };
    in.pointer = .{ @floatFromInt(100 + (k * 7) % 900), @floatFromInt(50 + (k * 13) % 7000) };
}

fn build(f: *ui.Frame, th: *const ui.Theme) void {
    const base = ui.Id.from("row");
    for (0..count) |r| {
        const id = base.with(@intCast(r));
        _ = f.open(id, .{ .dir = .x, .size = .{ .fill, .fit }, .gap = 6, .pad = @splat(2), .cross = .center });
        _ = ui.widgets.label(f, th, "Row label");
        _ = ui.widgets.button(f, th, id.with(1), "Apply");
        _ = ui.widgets.button(f, th, id.with(2), "Revert");
        _ = ui.widgets.checkbox(f, th, id.with(3), &checks[r], "Enabled");
        _ = ui.widgets.slider(f, th, id.with(4), &values[r], 0, 1);
        _ = f.leaf(.none, .{ .size = .{ .px(12), .px(12) }, .fill = th.accent });
        f.close();
    }
}
