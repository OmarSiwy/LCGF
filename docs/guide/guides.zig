//! The guides' examples (docs/guide/*.zig), compiled and run by `zig build docs`.

test {
    _ = @import("comptime.zig");
    _ = @import("runtime.zig");
    _ = @import("custom.zig");
    _ = @import("text.zig");
    _ = @import("porting.zig");
    _ = @import("perf.zig");
    _ = @import("backends.zig");
    _ = @import("gpu.zig");
}
