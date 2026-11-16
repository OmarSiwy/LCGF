//! Idle (target D5): the static form polled 3,000 times with input that never changes. As in every
//! scene but rows, a frame is built only when `Context.needsFrame` asks for one, so `frames=`
//! counts the work done while idle: the first frame and the one settle frame after it, then none.
const ui = @import("ui");
const Scene = @import("scenes.zig").Scene;

pub const scene: Scene = .{ .name = "idle", .frames = 3000, .input = input, .build = @import("form.zig").build, .idle = true };

fn input(in: *ui.Input, k: u32) void {
    _ = k;
    in.viewport = .{ 800, 600 };
    in.pointer = .{ 400, 300 };
}
