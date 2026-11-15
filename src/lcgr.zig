//! LCGR: Lightweight Comptime Graphics Renderer. The package root.
//!
//! Each file under src/ is exported here as `pub const name = @import("dir/name.zig");`.
//! A file that is not exported is not compiled and its tests do not run.

const std = @import("std");

pub const types = @import("core/types.zig");

test {
    std.testing.refAllDecls(@This());
}
