//! The examples' smoke tests, all in one test binary: `zig build examples`.

test {
    _ = @import("hello.zig");
    _ = @import("counter.zig");
    _ = @import("form.zig");
    _ = @import("list.zig");
}
