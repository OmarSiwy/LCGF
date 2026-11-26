//! The markup compiler's unit tests, one binary: `zig build markup`.

test {
    _ = @import("diag.zig");
    _ = @import("html.zig");
    _ = @import("css.zig");
}
