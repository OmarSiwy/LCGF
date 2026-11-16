//! The wgpu-native binding for `Renderer(gpu)` (src/render/wgpu/wgpu.zig `Binding`): thin
//! functions over wgpu-native's C API, whose headers build.zig translates (`wgpu_c`; Zig 0.17
//! removed @cImport). Outside the tiers and not exported from lcgr.zig: it links a C library,
//! so it is a module of its own over lcgr (`zig build wgpu`), never imported by it.
//!
//!     var ctx = native.Context.init(device);
//!     var gfx = native.Renderer.init(&ctx, .{ .format = ... }, white_view, sampler);
//!
//! `Context` keeps what the binding creates once per device: the two bind group layouts every
//! pipeline shares (group 0 globals, group 1 texture and sampler).

const std = @import("std");
const lcgr = @import("lcgr");
pub const c = @import("wgpu_c");
pub const host = @import("host.zig");
const wgpu = lcgr.render_wgpu;

/// The wgpu back end over wgpu-native.
pub const Renderer = wgpu.Renderer(@This());

pub const Device = *const Context;
pub const Queue = c.WGPUQueue;
pub const RenderPass = c.WGPURenderPassEncoder;
pub const Buffer = c.WGPUBuffer;
pub const Pipeline = c.WGPURenderPipeline;
pub const BindGroup = c.WGPUBindGroup;
pub const TextureView = c.WGPUTextureView;
pub const Sampler = c.WGPUSampler;
pub const TextureFormat = c.WGPUTextureFormat;

pub const Context = struct {
    device: c.WGPUDevice,
    globals_layout: c.WGPUBindGroupLayout,
    texture_layout: c.WGPUBindGroupLayout,
    pipeline_layout: c.WGPUPipelineLayout,

    pub fn init(device: c.WGPUDevice) Context {
        const globals_entry: c.WGPUBindGroupLayoutEntry = .{
            .binding = 0,
            .visibility = c.WGPUShaderStage_Vertex | c.WGPUShaderStage_Fragment,
            .buffer = .{ .type = c.WGPUBufferBindingType_Uniform, .minBindingSize = @sizeOf(wgpu.Globals) },
        };
        const texture_entries = [_]c.WGPUBindGroupLayoutEntry{
            .{
                .binding = 0,
                .visibility = c.WGPUShaderStage_Fragment,
                .texture = .{ .sampleType = c.WGPUTextureSampleType_Float, .viewDimension = c.WGPUTextureViewDimension_2D },
            },
            .{
                .binding = 1,
                .visibility = c.WGPUShaderStage_Fragment,
                .sampler = .{ .type = c.WGPUSamplerBindingType_Filtering },
            },
        };
        const groups = [_]c.WGPUBindGroupLayout{
            c.wgpuDeviceCreateBindGroupLayout(device, &.{ .entryCount = 1, .entries = &globals_entry }),
            c.wgpuDeviceCreateBindGroupLayout(device, &.{ .entryCount = texture_entries.len, .entries = &texture_entries }),
        };
        return .{
            .device = device,
            .globals_layout = groups[0],
            .texture_layout = groups[1],
            .pipeline_layout = c.wgpuDeviceCreatePipelineLayout(device, &.{ .bindGroupLayoutCount = groups.len, .bindGroupLayouts = &groups }),
        };
    }

    pub fn deinit(ctx: *Context) void {
        c.wgpuPipelineLayoutRelease(ctx.pipeline_layout);
        c.wgpuBindGroupLayoutRelease(ctx.globals_layout);
        c.wgpuBindGroupLayoutRelease(ctx.texture_layout);
    }
};

pub fn createBuffer(d: Device, size: u64, use: wgpu.BufferUse) Buffer {
    const usage: c.WGPUBufferUsage = switch (use) {
        .vertex => c.WGPUBufferUsage_Vertex,
        .uniform => c.WGPUBufferUsage_Uniform,
    };
    return c.wgpuDeviceCreateBuffer(d.device, &.{ .usage = usage | c.WGPUBufferUsage_CopyDst, .size = size });
}

pub fn destroyBuffer(b: Buffer) void {
    c.wgpuBufferDestroy(b);
    c.wgpuBufferRelease(b);
}

pub fn writeBuffer(q: Queue, b: Buffer, offset: u64, bytes: []const u8) void {
    // An empty write is a no-op that wgpu still validates; skip it (an empty frame, no text).
    if (bytes.len == 0) return;
    c.wgpuQueueWriteBuffer(q, b, offset, bytes.ptr, bytes.len);
}

/// The quad pipeline of wgpu.zig `Binding`: triangle strip, no depth, premultiplied-alpha
/// blending, one vertex buffer stepped per instance with `desc.attrs`, and the shared layouts.
pub fn createPipeline(d: Device, desc: *const Renderer.PipelineDesc) Pipeline {
    const source: c.WGPUShaderSourceWGSL = .{ .chain = .{ .sType = c.WGPUSType_ShaderSourceWGSL }, .code = host.sv(desc.wgsl) };
    const module = c.wgpuDeviceCreateShaderModule(d.device, &.{ .nextInChain = @constCast(&source.chain) });
    defer c.wgpuShaderModuleRelease(module);

    var attrs: [16]c.WGPUVertexAttribute = undefined;
    std.debug.assert(desc.attrs.len <= attrs.len);
    for (desc.attrs, attrs[0..desc.attrs.len]) |a, *o| o.* = .{
        .format = switch (a.format) {
            .float32 => c.WGPUVertexFormat_Float32,
            .float32x2 => c.WGPUVertexFormat_Float32x2,
            .float32x4 => c.WGPUVertexFormat_Float32x4,
            .uint32x4 => c.WGPUVertexFormat_Uint32x4,
            .unorm8x4 => c.WGPUVertexFormat_Unorm8x4,
        },
        .offset = a.offset,
        .shaderLocation = a.location,
    };
    const instances: c.WGPUVertexBufferLayout = .{
        .stepMode = c.WGPUVertexStepMode_Instance,
        .arrayStride = desc.instance_stride,
        .attributeCount = desc.attrs.len,
        .attributes = &attrs,
    };
    const premultiplied: c.WGPUBlendComponent = .{
        .operation = c.WGPUBlendOperation_Add,
        .srcFactor = c.WGPUBlendFactor_One,
        .dstFactor = c.WGPUBlendFactor_OneMinusSrcAlpha,
    };
    const blend: c.WGPUBlendState = .{ .color = premultiplied, .alpha = premultiplied };
    const color: c.WGPUColorTargetState = .{ .format = desc.format, .blend = &blend, .writeMask = c.WGPUColorWriteMask_All };
    const fragment: c.WGPUFragmentState = .{ .module = module, .entryPoint = host.sv(desc.fragment_entry), .targetCount = 1, .targets = &color };
    return c.wgpuDeviceCreateRenderPipeline(d.device, &.{
        .layout = d.pipeline_layout,
        .vertex = .{ .module = module, .entryPoint = host.sv(desc.vertex_entry), .bufferCount = 1, .buffers = &instances },
        .primitive = .{ .topology = c.WGPUPrimitiveTopology_TriangleStrip },
        .multisample = .{ .count = desc.sample_count, .mask = 0xffff_ffff },
        .fragment = &fragment,
    });
}

pub fn globalsBindGroup(d: Device, b: Buffer) BindGroup {
    const entry: c.WGPUBindGroupEntry = .{ .binding = 0, .buffer = b, .size = @sizeOf(wgpu.Globals) };
    return c.wgpuDeviceCreateBindGroup(d.device, &.{ .layout = d.globals_layout, .entryCount = 1, .entries = &entry });
}

pub fn textureBindGroup(d: Device, v: TextureView, s: Sampler) BindGroup {
    const entries = [_]c.WGPUBindGroupEntry{ .{ .binding = 0, .textureView = v }, .{ .binding = 1, .sampler = s } };
    return c.wgpuDeviceCreateBindGroup(d.device, &.{ .layout = d.texture_layout, .entryCount = entries.len, .entries = &entries });
}

pub fn setPipeline(p: RenderPass, pipe: Pipeline) void {
    c.wgpuRenderPassEncoderSetPipeline(p, pipe);
}

pub fn setBindGroup(p: RenderPass, index: u32, g: BindGroup) void {
    c.wgpuRenderPassEncoderSetBindGroup(p, index, g, 0, null);
}

pub fn setVertexBuffer(p: RenderPass, slot: u32, b: Buffer, offset: u64, size: u64) void {
    c.wgpuRenderPassEncoderSetVertexBuffer(p, slot, b, offset, size);
}

pub fn draw(p: RenderPass, vertices: u32, instances: u32, first_vertex: u32, first_instance: u32) void {
    c.wgpuRenderPassEncoderDraw(p, vertices, instances, first_vertex, first_instance);
}

// ============================================================================
// Tests on a real adapter (Mesa lavapipe in ci/run.sh wgpu)
// ============================================================================

const testing = std.testing;

test "native: a pass clears the target and the pixels read back" {
    var h = try host.Host.init();
    defer h.deinit();
    var name: [128]u8 = undefined;
    std.debug.print("wgpu adapter: {s}\n", .{h.adapterName(&name)});
    var ctx = Context.init(h.device);
    defer ctx.deinit();

    var target = host.Target.init(&h, 8, 4, c.WGPUTextureFormat_RGBA8Unorm);
    defer target.deinit();
    const encoder = c.wgpuDeviceCreateCommandEncoder(h.device, null);
    host.endPass(host.beginPass(encoder, target.view, .{ 0.25, 0.5, 0.75, 1 }));
    h.submit(encoder);

    var px: [8 * 4 * 4]u8 = undefined;
    try h.readback(&target, &px);
    for (0..8 * 4) |i| try testing.expectEqualSlices(u8, &.{ 64, 128, 191, 255 }, px[i * 4 ..][0..4]);
}

test "native: buffers and bind groups are created against the shared layouts" {
    var h = try host.Host.init();
    defer h.deinit();
    var ctx = Context.init(h.device);
    defer ctx.deinit();
    const globals = createBuffer(&ctx, @sizeOf(wgpu.Globals), .uniform);
    defer destroyBuffer(globals);
    writeBuffer(h.queue, globals, 0, std.mem.asBytes(&wgpu.Globals{ .viewport = .{ 8, 4 }, .scale = 1 }));
    const group = globalsBindGroup(&ctx, globals);
    defer c.wgpuBindGroupRelease(group);
    try testing.expect(group != null);
    const vertices = createBuffer(&ctx, 4 * wgpu.quad_stride, .vertex);
    defer destroyBuffer(vertices);
    writeBuffer(h.queue, vertices, 0, &.{});
}

test "native: every shader variant builds a quad pipeline with the documented layouts" {
    var h = try host.Host.init();
    defer h.deinit();
    var ctx = Context.init(h.device);
    defer ctx.deinit();
    // A validation error panics through the host's uncaptured-error callback.
    for (lcgr.quad_shader.variants) |v| {
        const pipe = createPipeline(&ctx, &.{ .wgsl = v.wgsl, .format = c.WGPUTextureFormat_BGRA8Unorm, .sample_count = 1 });
        defer c.wgpuRenderPipelineRelease(pipe);
        try testing.expect(pipe != null);
    }
}
