//! The Metal back end, for macOS and iOS (docs/DEPENDENCIES.md). Outside the tiers and not
//! exported from lcgf.zig: it calls a platform API (Metal and QuartzCore through the
//! Objective-C runtime, opened at run time), so it is a module of its own over lcgf
//! (`zig build metal`), never imported by it. Tests that need a device skip off macOS;
//! ci/jobs/metal.sh runs the rest and cross-compiles everything for aarch64-macos.

const std = @import("std");
pub const objc = @import("objc.zig");
pub const mtl = @import("mtl.zig");
pub const device = @import("device.zig");
pub const msl = @import("msl.zig");
pub const pipeline = @import("pipeline.zig");
pub const texture = @import("texture.zig");
pub const present = @import("present.zig");
/// lcgf_render.gpu on Metal: WebGPU's object model projected onto this back end (gpu.zig).
pub const gpu = @import("gpu.zig");
pub const renderer = @import("renderer.zig");
pub const Renderer = renderer.Renderer;
pub const CanvasRenderer = renderer.CanvasRenderer;
pub const setup = @import("setup.zig");
pub const Setup = setup.Setup;

test {
    std.testing.refAllDecls(@This());
    std.testing.refAllDecls(objc);
    std.testing.refAllDecls(mtl);
    std.testing.refAllDecls(device);
    std.testing.refAllDecls(msl);
    std.testing.refAllDecls(pipeline);
    std.testing.refAllDecls(texture);
    std.testing.refAllDecls(present);
    std.testing.refAllDecls(present.Frames);
    std.testing.refAllDecls(present.DisplayLink);
    std.testing.refAllDecls(setup.Window);
    std.testing.refAllDecls(gpu);
    std.testing.refAllDecls(renderer);
    std.testing.refAllDecls(Renderer);
    std.testing.refAllDecls(mtl.RenderEncoder);
}
