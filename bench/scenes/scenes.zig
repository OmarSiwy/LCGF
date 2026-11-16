//! Benchmark scenes for tools/bench: one harness, many scenes (`zig build bench -- --scene NAME`).
//! A scene sets each frame's input and builds the frame through module "ui": lcgr's runtime front
//! end (tools/bench/src_ui.zig) or, under `--core=prototype`, the prototype core. The harness
//! runs and times every pass the same way for each scene.
const ui = @import("ui");

pub const Scene = struct {
    name: []const u8,
    /// Frames the harness runs; at most tools/bench's `frames`.
    frames: u32,
    /// Sets the input of frame `k` (counted from 0).
    input: *const fn (in: *ui.Input, k: u32) void,
    build: *const fn (f: *ui.Frame, th: *const ui.Theme) void,
    /// At most the first and the settle frame may be built (target D5).
    idle: bool = false,
    /// Build every poll. Otherwise only the frames `Context.needsFrame` asks for are built, as a
    /// host that sleeps between events does. Rows builds every poll so its per-pass numbers stay
    /// comparable; list and springs because their state changes outside `Input` (the scroll
    /// position, the spring targets), which a host learns from the app, not from needsFrame.
    every: bool = false,
};

pub const rows = @import("rows.zig");

/// The default scene first.
pub const all = [_]Scene{
    rows.scene,
    @import("form.zig").scene,
    @import("list.zig").scene,
    @import("text.zig").scene,
    @import("springs.zig").scene,
    @import("resize.zig").scene,
    @import("idle.zig").scene,
};

/// The scenes of the comparison (bench/vs/harness.h), in its order.
pub const vs = all[1..].*;
