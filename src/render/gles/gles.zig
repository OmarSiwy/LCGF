//! The OpenGL ES back end, for small Linux devices and older Android (docs/DEPENDENCIES.md).
//! Outside the tiers and not exported from lcgf.zig: it calls a platform API (EGL and GL ES,
//! opened at run time), so it is a module of its own over lcgf (`zig build gles`), never
//! imported by it. The tests run on a real driver (Mesa llvmpipe in `nix develop .#golden`,
//! ci/jobs/gles.sh).

const std = @import("std");
pub const egl = @import("egl.zig");
pub const gl = @import("gl.zig");
pub const host = @import("host.zig");
pub const program = @import("program.zig");
pub const renderer = @import("renderer.zig");
pub const Renderer = renderer.Renderer;
pub const es2 = @import("es2.zig");
pub const custom = @import("custom.zig");
/// lcgf_render.gpu on GL ES 3: WebGPU's object model projected onto this back end (gpu.zig).
pub const gpu = @import("gpu.zig");
const styling = @import("styling.zig");

test {
    std.testing.refAllDecls(@This());
    std.testing.refAllDecls(egl);
    std.testing.refAllDecls(gl);
    std.testing.refAllDecls(host);
    std.testing.refAllDecls(program);
    std.testing.refAllDecls(renderer);
    std.testing.refAllDecls(es2);
    std.testing.refAllDecls(custom);
    std.testing.refAllDecls(gpu);
    std.testing.refAllDecls(styling);
}
