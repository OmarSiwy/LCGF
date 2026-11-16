//! The examples' smoke tests, all in one test binary: `zig build examples`.

test {
    _ = @import("hello.zig");
}
