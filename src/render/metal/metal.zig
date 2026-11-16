//! The Metal back end, for macOS and iOS (docs/DEPENDENCIES.md). Outside the tiers and not
//! exported from lcgr.zig: it calls a platform API (Metal and QuartzCore through the
//! Objective-C runtime, opened at run time), so it is a module of its own over lcgr
//! (`zig build metal`), never imported by it. Tests that need a device skip off macOS;
//! ci/jobs/metal.sh runs the rest and cross-compiles everything for aarch64-macos.

const std = @import("std");
pub const objc = @import("objc.zig");
pub const mtl = @import("mtl.zig");
pub const device = @import("device.zig");

test {
    std.testing.refAllDecls(@This());
    std.testing.refAllDecls(objc);
    std.testing.refAllDecls(mtl);
    std.testing.refAllDecls(device);
}
