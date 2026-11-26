//! The Direct3D 12 back end. Outside the tiers and not exported from lcgf.zig: it calls a
//! platform API, so it is a module of its own over lcgf, built for x86_64-windows
//! (`zig build d3d12`), never imported by it. COM through hand-written vtables (com.zig).
//!
//! The tests need Windows, or Wine with a Vulkan driver for its vkd3d (ci/jobs/d3d12.sh: Mesa
//! lavapipe). They ask for the WARP software rasteriser; Wine has none and gives its first
//! adapter, vkd3d over lavapipe, which is also a software rasteriser.

const std = @import("std");
pub const com = @import("com.zig");
pub const c = com.c;
pub const device = @import("device.zig");
pub const host = @import("host.zig");
pub const pipeline = @import("pipeline.zig");
pub const renderer = @import("renderer.zig");
pub const Renderer = renderer.Renderer;
pub const CanvasRenderer = renderer.CanvasRenderer;
pub const frame = @import("frame.zig");
/// lcgf_render.gpu on Direct3D 12: WebGPU's object model projected onto this back end (gpu.zig).
pub const gpu = @import("gpu.zig");
pub const scenes = @import("scenes.zig");

test {
    std.testing.refAllDecls(@This());
    std.testing.refAllDecls(com);
    std.testing.refAllDecls(device);
    std.testing.refAllDecls(host);
    std.testing.refAllDecls(pipeline);
    std.testing.refAllDecls(renderer);
    std.testing.refAllDecls(frame);
    std.testing.refAllDecls(gpu);
    std.testing.refAllDecls(scenes);
}
