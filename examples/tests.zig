//! The examples' smoke tests, all in one test binary: `zig build examples`.

test {
    _ = @import("hello/app.zig");
    _ = @import("counter/app.zig");
    _ = @import("form/app.zig");
    _ = @import("list/app.zig");
    _ = @import("dashboard/app.zig");
    _ = @import("viewport/app.zig");
    _ = @import("texture/app.zig");
    _ = @import("mcu/app.zig");
    _ = @import("canvas_text.zig");
}
