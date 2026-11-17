//! The WebGPU back end: the wgpu back end's renderer (src/render/wgpu/wgpu.zig `Renderer`) over
//! the browser's WebGPU, reached through imports that lcgf.js `webgpu` provides. Every GPU object
//! is a `u32` handle into a JS table; the WebGPU calls themselves are in JS, one line each.
//!
//!     const Gfx = webgpu.Renderer;
//!     var gfx = Gfx.init(device, .{ .format = .bgra8unorm }, white_view, sampler);
//!     gfx.prepare(queue, draw, glyphs, viewport, scale);   // before the pass
//!     gfx.render(pass, draw);                              // or iface.drawUntilCustom
//!
//! The host (JS, or wasm calling its own imports) owns the device, queue, encoder, pass and
//! target, as on every back end (src/render/iface.zig): it registers them with `ui.gpu.put` and
//! hands the handles in. wasm32-freestanding only.
const std = @import("std");
const lcgf = @import("lcgf");
const wgpu = lcgf.render_wgpu;

const imports = struct {
    extern "lcgf" fn gpu_create_buffer(device: u32, size: u32, use: u32) u32;
    extern "lcgf" fn gpu_release(handle: u32) void;
    extern "lcgf" fn gpu_write_buffer(queue: u32, buffer: u32, offset: u32, ptr: [*]const u8, len: usize) void;
    extern "lcgf" fn gpu_create_pipeline(device: u32, wgsl: [*]const u8, wgsl_len: usize, vs: [*]const u8, vs_len: usize, fs: [*]const u8, fs_len: usize, format: u32, samples: u32, stride: u32, attrs: [*]const [3]u32, attrs_len: usize) u32;
    extern "lcgf" fn gpu_globals_group(device: u32, buffer: u32) u32;
    extern "lcgf" fn gpu_texture_group(device: u32, view: u32, sampler: u32) u32;
    extern "lcgf" fn gpu_set_pipeline(pass: u32, pipeline: u32) void;
    extern "lcgf" fn gpu_set_bind_group(pass: u32, index: u32, group: u32) void;
    extern "lcgf" fn gpu_set_vertex_buffer(pass: u32, slot: u32, buffer: u32, offset: u32, size: u32) void;
    extern "lcgf" fn gpu_draw(pass: u32, vertices: u32, instances: u32, first_vertex: u32, first_instance: u32) void;
};

/// The binding `wgpu.Renderer` is generic over (src/render/wgpu/wgpu.zig `Binding`).
pub const Binding = struct {
    pub const Device = u32;
    pub const Queue = u32;
    pub const RenderPass = u32;
    pub const Buffer = u32;
    pub const Pipeline = u32;
    pub const BindGroup = u32;
    pub const TextureView = u32;
    pub const Sampler = u32;
    /// The JS side names them by `@tagName` order: lcgf.js `formats`.
    pub const TextureFormat = enum(u32) { rgba8unorm, bgra8unorm };

    pub fn createBuffer(d: Device, size: u64, use: wgpu.BufferUse) Buffer {
        return imports.gpu_create_buffer(d, @intCast(size), @backingInt(use));
    }
    pub fn destroyBuffer(b: Buffer) void {
        imports.gpu_release(b);
    }
    pub fn writeBuffer(q: Queue, b: Buffer, offset: u64, bytes: []const u8) void {
        imports.gpu_write_buffer(q, b, @intCast(offset), bytes.ptr, bytes.len);
    }
    pub fn createPipeline(d: Device, desc: *const wgpu.Renderer(Binding).PipelineDesc) Pipeline {
        // Attribute rows as (location, offset, format index into lcgf.js `attr_formats`).
        var attrs: [wgpu.quad_attrs.len][3]u32 = undefined;
        for (desc.attrs, attrs[0..desc.attrs.len]) |a, *row| row.* = .{ a.location, a.offset, @backingInt(a.format) };
        return imports.gpu_create_pipeline(d, desc.wgsl.ptr, desc.wgsl.len, desc.vertex_entry.ptr, desc.vertex_entry.len, desc.fragment_entry.ptr, desc.fragment_entry.len, @backingInt(desc.format), desc.sample_count, desc.instance_stride, &attrs, desc.attrs.len);
    }
    pub fn globalsBindGroup(d: Device, b: Buffer) BindGroup {
        return imports.gpu_globals_group(d, b);
    }
    pub fn textureBindGroup(d: Device, v: TextureView, s: Sampler) BindGroup {
        return imports.gpu_texture_group(d, v, s);
    }
    pub fn releaseBindGroup(g: BindGroup) void {
        imports.gpu_release(g);
    }
    pub fn setPipeline(p: RenderPass, pipe: Pipeline) void {
        imports.gpu_set_pipeline(p, pipe);
    }
    pub fn setBindGroup(p: RenderPass, index: u32, g: BindGroup) void {
        imports.gpu_set_bind_group(p, index, g);
    }
    pub fn setVertexBuffer(p: RenderPass, slot: u32, b: Buffer, offset: u64, size: u64) void {
        imports.gpu_set_vertex_buffer(p, slot, b, @intCast(offset), @intCast(size));
    }
    pub fn draw(p: RenderPass, vertices: u32, instances: u32, first_vertex: u32, first_instance: u32) void {
        imports.gpu_draw(p, vertices, instances, first_vertex, first_instance);
    }
};

pub const Renderer = wgpu.Renderer(Binding);

comptime {
    lcgf.render_iface.check(Renderer);
}
