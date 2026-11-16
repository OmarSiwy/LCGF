//! The OpenGL ES back end, for small Linux devices and older Android (docs/DEPENDENCIES.md).
//! Outside the tiers and not exported from lcgr.zig: it calls a platform API (EGL and GL ES,
//! opened at run time), so it is a module of its own over lcgr (`zig build gles`), never
//! imported by it. The tests run on a real driver (Mesa llvmpipe in `nix develop .#golden`,
//! ci/jobs/gles.sh).

const std = @import("std");
pub const egl = @import("egl.zig");
pub const gl = @import("gl.zig");
pub const host = @import("host.zig");
pub const program = @import("program.zig");

test {
    std.testing.refAllDecls(@This());
    std.testing.refAllDecls(egl);
    std.testing.refAllDecls(gl);
    std.testing.refAllDecls(host);
    std.testing.refAllDecls(program);
}
