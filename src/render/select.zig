//! The render back end chosen at compile time: `zig build -Drender=auto|sw|vk|metal|d3d12|gles|web|wgpu`,
//! module `lcgf_render` (build.zig). `auto` is the target's own API: Metal on macOS and iOS,
//! Direct3D 12 on Windows, Vulkan on Linux and Android, WebGPU on wasm32, software on
//! freestanding. Only the chosen back end is compiled and nothing dispatches: `Renderer` is
//! that back end's type, so a call through it is the same machine code as one through a direct
//! import (ci/jobs/render-select.sh compares the .text of both).
//!
//! The host still owns the device, queue and pass (src/render/iface.zig). What the host passes
//! differs per back end and must: `Pass` is a VkCommandBuffer, an MTLRenderCommandEncoder, a
//! command list, `void` for GL ES, a framebuffer target for software. Code that records its own
//! draws (custom commands) is written against one back end, or switches on `kind` at comptime.

const lcgf = @import("lcgf");
const options = @import("render_options");

pub const Kind = @TypeOf(options.render);
/// The back end this build selected (`auto` already resolved).
pub const kind: Kind = options.render;

/// The back end's module: src/render/vk/vk.zig, metal/metal.zig, d3d12/d3d12.zig,
/// gles/gles.zig, web/web.zig, wgpu/native.zig, or `lcgf.render_sw`.
pub const backend = switch (kind) {
    .sw => lcgf.render_sw,
    else => @import("render_backend"),
};

/// The renderer: it meets src/render/iface.zig (`prepare`, `drawBatch`, `drawText`, `render`).
pub const Renderer = switch (kind) {
    .sw => backend.Software,
    .web => backend.webgpu.Renderer,
    else => backend.Renderer,
};
/// What draws are recorded into: the host's pass.
pub const Pass = Renderer.Pass;
/// What `prepare` uploads through: a frame slot, a queue, or `void`.
pub const Queue = Renderer.Queue;
/// Device, renderer and per-window swapchain for an application that brings none: sw, vk
/// and metal have one (moved from the shells that use them); naming it for another back end is
/// a compile error.
pub const Setup = backend.Setup;
/// WebGPU's object model projected onto the selected back end at compile time
/// (src/render/<back end>/gpu.zig, docs/guide/gpu.md). Software has none: naming it there is a
/// compile error.
pub const gpu = if (kind == .sw) @compileError("lcgf_render.gpu needs a GPU back end; -Drender=sw has none") else backend.gpu;

comptime {
    lcgf.render_iface.check(Renderer);
}
