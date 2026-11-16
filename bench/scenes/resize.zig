//! Resize storm: the text-heavy scene with the window resized every frame, 320 to 1,919 px wide
//! and 240 to 1,239 px tall, so every paragraph re-wraps.
const ui = @import("ui");
const Scene = @import("scenes.zig").Scene;

pub const scene: Scene = .{ .name = "resize", .frames = 3000, .input = input, .build = @import("text.zig").build };

fn input(in: *ui.Input, k: u32) void {
    in.viewport = .{ @floatFromInt(320 + (k * 37) % 1600), @floatFromInt(240 + (k * 53) % 1000) };
    in.pointer = .{ 100, 100 };
}
