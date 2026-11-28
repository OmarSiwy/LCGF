//! The examples' smoke tests, all in one test binary: `zig build examples`.

test {
    _ = @import("dashboard/app.zig");
    _ = @import("viewport/app.zig");
    _ = @import("texture/app.zig");
    _ = @import("mcu/app.zig");
    _ = @import("canvas_text.zig");
}
