//! Developer tools: the inspector and what it shows. Outside the tiers (docs/ARCHITECTURE.md,
//! "Adapters are the exception"): `timing` reads the host's clock through `std.Io`, so this is a
//! module of its own over `lcgr`, built by `zig build devtools`, and never exported from
//! src/lcgr.zig. An application adds this file as a module named "devtools" that imports the
//! `lcgr` module (as build.zig's `devtools` step does) and uses `@import("devtools")`.

const std = @import("std");

pub const inspector = @import("inspector.zig");
pub const timing = @import("timing.zig");
pub const log = @import("log.zig");
pub const batches = @import("batches.zig");
pub const changes = @import("changes.zig");
pub const record = @import("record.zig");

pub const Inspector = inspector.Inspector;

test {
    std.testing.refAllDecls(@This());
}
