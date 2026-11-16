//! Benchmark scenes for tools/bench: one harness, many scenes (`zig build bench -- --scene NAME`).
//! A scene sets each frame's input and builds the frame with the prototype core ("ui"); the
//! harness runs and times every pass the same way for each scene.
const ui = @import("ui");

pub const Scene = struct {
    name: []const u8,
    /// Frames the harness runs; at most tools/bench's `frames`.
    frames: u32,
    /// Sets the input of frame `k` (counted from 0).
    input: *const fn (in: *ui.Input, k: u32) void,
    build: *const fn (f: *ui.Frame, th: *const ui.Theme) void,
    /// Build only the frames `Context.needsFrame` asks for, as a host that sleeps when idle.
    idle: bool = false,
};

pub const list = [_]Scene{
    @import("form.zig").scene,
    @import("list.zig").scene,
    @import("text.zig").scene,
    @import("springs.zig").scene,
    @import("resize.zig").scene,
    @import("idle.zig").scene,
};
