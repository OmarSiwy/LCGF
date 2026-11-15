//! LCGR: Lightweight Comptime Graphics Renderer. The package root.
//!
//! Each file under src/ is exported here as `pub const name = @import("dir/name.zig");`.
//! A file that is not exported is not compiled and its tests do not run.

const std = @import("std");

pub const simd = @import("core/simd.zig");
pub const input = @import("core/input.zig");
pub const types = @import("core/types.zig");
pub const mem = @import("core/mem.zig");
pub const tree = @import("core/tree.zig");
pub const strings = @import("core/strings.zig");
pub const texts = @import("core/texts.zig");
pub const customs = @import("core/customs.zig");
pub const spec = @import("comptime/spec.zig");
pub const protocol = @import("text/protocol.zig");

test {
    std.testing.refAllDecls(@This());
}
