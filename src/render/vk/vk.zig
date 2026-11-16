//! The Vulkan back end. Outside the tiers and not exported from lcgr.zig: it calls a platform
//! API through translated headers (`vk_c`), so it is a module of its own over lcgr
//! (`zig build vk`), never imported by it. The tests run on a real Vulkan implementation
//! (Mesa lavapipe in `nix develop .#golden`, ci/jobs/vk.sh).
//!
//! Why a thin back end: the overhead worth removing is the abstraction and validation layer
//! above the GPU API, not the API (docs/DESIGN.md). Zed measured an empty window at about 100 MB
//! through a portable layer against about 10 MB native.

const std = @import("std");
pub const loader = @import("loader.zig");
pub const c = loader.c;
pub const device = @import("device.zig");
pub const swapchain = @import("swapchain.zig");
pub const pass = @import("pass.zig");
pub const frame = @import("frame.zig");
pub const host = @import("host.zig");
pub const renderer = @import("renderer.zig");
pub const Renderer = renderer.Renderer;
pub const custom = @import("custom.zig");
pub const scenes = @import("scenes.zig");

test {
    std.testing.refAllDecls(@This());
    std.testing.refAllDecls(loader);
    std.testing.refAllDecls(device);
    std.testing.refAllDecls(swapchain);
    std.testing.refAllDecls(pass);
    std.testing.refAllDecls(frame);
    std.testing.refAllDecls(host);
    std.testing.refAllDecls(renderer);
    std.testing.refAllDecls(custom);
    std.testing.refAllDecls(scenes);
}
