//! The wgpu-native binding for `Renderer(gpu)` (src/render/wgpu/wgpu.zig `Binding`): thin
//! functions over wgpu-native's C API, whose headers build.zig translates (`wgpu_c`; Zig 0.17
//! removed @cImport). Outside the tiers and not exported from lcgf.zig: it links a C library,
//! so it is a module of its own over lcgf (`zig build wgpu`), never imported by it.
//!
//!     var ctx = native.Context.init(device);
//!     var gfx = native.Renderer.init(&ctx, .{ .format = ... }, white_view, sampler);
//!
//! `Context` keeps what the binding creates once per device: the two bind group layouts every
//! pipeline shares (group 0 globals, group 1 texture and sampler).

const std = @import("std");
const lcgf = @import("lcgf");
pub const c = @import("wgpu_c");
pub const host = @import("host.zig");
pub const surface = @import("surface.zig");
pub const glyphs = @import("glyphs.zig");
/// lcgf_render.gpu on wgpu-native: the identity projection (gpu.zig).
pub const gpu = @import("gpu.zig");
const wgpu = lcgf.render_wgpu;

/// The wgpu back end over wgpu-native.
pub const Renderer = wgpu.Renderer(@This());
/// With the canvas pipeline.
pub const CanvasRenderer = wgpu.CanvasRenderer(@This());

pub const Device = *const Context;
pub const Queue = c.WGPUQueue;
pub const RenderPass = c.WGPURenderPassEncoder;
pub const Buffer = c.WGPUBuffer;
pub const Pipeline = c.WGPURenderPipeline;
pub const BindGroup = c.WGPUBindGroup;
pub const TextureView = c.WGPUTextureView;
pub const Sampler = c.WGPUSampler;
pub const TextureFormat = c.WGPUTextureFormat;

/// lcgf_render.gpu over the same device, for the canvas pipeline (wgpu.zig `Binding`).
pub const canvas = struct {
    pub const projection = gpu;
    pub fn device(d: Device, q: ?Queue) gpu.Device {
        return .wrap(d.device, q orelse null);
    }
    pub fn format(f: TextureFormat) gpu.TextureFormat {
        return switch (f) {
            c.WGPUTextureFormat_BGRA8Unorm => .bgra8_unorm,
            c.WGPUTextureFormat_BGRA8UnormSrgb => .bgra8_unorm_srgb,
            c.WGPUTextureFormat_RGBA8UnormSrgb => .rgba8_unorm_srgb,
            c.WGPUTextureFormat_RGBA16Float => .rgba16_float,
            else => .rgba8_unorm,
        };
    }
    pub fn view(v: TextureView) gpu.TextureView {
        return .{ .view = v, .width = 0, .height = 0 };
    }
    pub fn upload(d: gpu.Device) gpu.Upload {
        return .begin(d, null);
    }
};

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

/// The multisampled colour texture a pass draws into when `Renderer.Desc.sample_count` is
/// above 1: begin the pass on `view` with the real target (a surface frame, an offscreen
/// texture) as its resolve target. Same size and format as that target; recreate it when the
/// target is resized. Off by default (count 1): the quad shader antialiases every edge with
/// its distance field, so multisampling only helps host draws and transformed edges.
pub const Multisample = struct {
    texture: c.WGPUTexture,
    view: c.WGPUTextureView,

    pub fn init(device: c.WGPUDevice, width: u32, height: u32, format: TextureFormat, count: u32) Multisample {
        const texture = c.wgpuDeviceCreateTexture(device, &.{
            .usage = c.WGPUTextureUsage_RenderAttachment,
            .dimension = c.WGPUTextureDimension_2D,
            .size = .{ .width = width, .height = height, .depthOrArrayLayers = 1 },
            .format = format,
            .mipLevelCount = 1,
            .sampleCount = count,
        });
        return .{ .texture = texture, .view = c.wgpuTextureCreateView(texture, null) };
    }

    pub fn deinit(m: *Multisample) void {
        c.wgpuTextureViewRelease(m.view);
        c.wgpuTextureRelease(m.texture);
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

pub fn releaseBindGroup(g: BindGroup) void {
    c.wgpuBindGroupRelease(g);
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

test {
    testing.refAllDecls(@This());
    testing.refAllDecls(gpu);
}

/// Draws `scene` into a fresh `width` x `height` target (viewport the same, scale 1) and reads
/// it back; the caller frees the pixels.
fn drawScene(h: *const host.Host, gfx: *Renderer, scene: *const lcgf.render_conformance.Scene, width: u32, height: u32) ![]u8 {
    var st: lcgf.render_conformance.Storage = .{};
    st.load(scene);
    var target = host.Target.init(h, width, height, c.WGPUTextureFormat_RGBA8Unorm);
    defer target.deinit();
    gfx.prepare(h.queue, &st.draw, st.glyphs(), .{ @floatFromInt(width), @floatFromInt(height) }, 1);
    const encoder = c.wgpuDeviceCreateCommandEncoder(h.device, null);
    const pass = host.beginPass(encoder, target.view, null, .{ 0, 0, 0, 1 });
    gfx.render(pass, &st.draw);
    host.endPass(pass);
    h.submit(encoder);
    const px = try testing.allocator.alloc(u8, @as(usize, width) * height * 4);
    errdefer testing.allocator.free(px);
    try h.readback(&target, px);
    return px;
}

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
    host.endPass(host.beginPass(encoder, target.view, null, .{ 0.25, 0.5, 0.75, 1 }));
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
    for (lcgf.quad_shader.variants) |v| {
        const pipe = createPipeline(&ctx, &.{ .wgsl = v.wgsl, .format = c.WGPUTextureFormat_BGRA8Unorm, .sample_count = 1 });
        defer c.wgpuRenderPipelineRelease(pipe);
        try testing.expect(pipe != null);
    }
}

test "native: a resize changes only the viewport; the same renderer draws every size" {
    var h = try host.Host.init();
    defer h.deinit();
    var ctx = Context.init(h.device);
    defer ctx.deinit();
    const sampler = host.nearestSampler(&h);
    defer c.wgpuSamplerRelease(sampler);
    var white = host.Image.init(&h, 1, 1, &.{ 0xff, 0xff, 0xff, 0xff });
    defer white.deinit();
    var gfx = Renderer.init(&ctx, .{ .format = c.WGPUTextureFormat_RGBA8Unorm }, white.view, sampler);
    defer gfx.deinit();
    const scene = &lcgf.render_conformance.scenes[0]; // rects, 160 x 120, drawn from (0, 0)

    const before = try drawScene(&h, &gfx, scene, 160, 120);
    defer testing.allocator.free(before);
    // Larger: the scene's pixels are unchanged, the new area is the clear colour.
    const grown = try drawScene(&h, &gfx, scene, 200, 150);
    defer testing.allocator.free(grown);
    for (0..150) |y| for (0..200) |x| {
        const got = grown[(y * 200 + x) * 4 ..][0..4];
        const want: []const u8 = if (x < 160 and y < 120) before[(y * 160 + x) * 4 ..][0..4] else &.{ 0, 0, 0, 255 };
        try testing.expectEqualSlices(u8, want, got);
    };
    // Back to the first size: the same picture again.
    const after = try drawScene(&h, &gfx, scene, 160, 120);
    defer testing.allocator.free(after);
    try testing.expectEqualSlices(u8, before, after);
}

/// A draw list of one quad batch holding `q`, in its own memory (must not move after `init`).
const OneQuad = struct {
    const bytes = blk: {
        var counter: lcgf.mem.Carver = .{ .buf = null };
        _ = lcgf.draw_list.DrawList.init(&counter, 1, 1, 1);
        break :blk counter.off;
    };
    buf: [bytes]u8 align(lcgf.mem.column_align),
    draw: lcgf.draw_list.DrawList,

    fn init(one: *OneQuad, q: lcgf.draw_list.Quad, texture: lcgf.types.Texture) void {
        var carver: lcgf.mem.Carver = .{ .buf = &one.buf };
        one.draw = lcgf.draw_list.DrawList.init(&carver, 1, 1, 1);
        const d = &one.draw;
        d.quads[0] = q;
        d.quad_len = 1;
        d.cmd.kind[0] = @backingInt(lcgf.draw_list.DrawList.Kind.quads);
        d.cmd.first[0] = 0;
        d.cmd.count[0] = 1;
        d.cmd.key[0] = @as(u32, @backingInt(texture)) << 16;
        d.cmd_len = 1;
    }
};

test "native: registered textures are sampled by handle, and setTexture swaps one in place" {
    var h = try host.Host.init();
    defer h.deinit();
    var ctx = Context.init(h.device);
    defer ctx.deinit();
    const sampler = host.nearestSampler(&h);
    defer c.wgpuSamplerRelease(sampler);
    var white = host.Image.init(&h, 1, 1, &.{ 0xff, 0xff, 0xff, 0xff });
    defer white.deinit();
    var gfx = Renderer.init(&ctx, .{ .format = c.WGPUTextureFormat_RGBA8Unorm }, white.view, sampler);
    defer gfx.deinit();
    // 2x2 texels: red, green / blue, grey.
    const checker_px = [_]u8{ 255, 0, 0, 255, 0, 255, 0, 255, 0, 0, 255, 255, 128, 128, 128, 255 };
    var checker = host.Image.init(&h, 2, 2, &checker_px);
    defer checker.deinit();
    var flipped_px: [16]u8 = undefined;
    for (0..4) |i| @memcpy(flipped_px[i * 4 ..][0..4], checker_px[(3 - i) * 4 ..][0..4]);
    var flipped = host.Image.init(&h, 2, 2, &flipped_px);
    defer flipped.deinit();
    const t = gfx.addTexture(&ctx, checker.view, sampler);
    try testing.expectEqual(@as(u16, 1), @backingInt(t));

    // One 4x4 quad, white fill, showing texture t: each texel covers 2x2 pixels.
    var one: OneQuad = undefined;
    one.init(.{ .rect = .{ 0, 0, 4, 4 }, .clip = .{ -1e6, -1e6, 1e6, 1e6 }, .params = @splat(0), .uv = .{ 0, 0, 1, 1 }, .radii = @splat(0), .fill = lcgf.types.Color.white.bitsOf(), .border_color = 0, .border = 0, .opacity = 1 }, t);
    const d = &one.draw;

    for ([_]*const [16]u8{ &checker_px, &flipped_px }, 0..) |want, round| {
        if (round == 1) gfx.setTexture(&ctx, t, flipped.view, sampler);
        var target = host.Target.init(&h, 4, 4, c.WGPUTextureFormat_RGBA8Unorm);
        defer target.deinit();
        gfx.prepare(h.queue, d, .{}, .{ 4, 4 }, 1);
        const encoder = c.wgpuDeviceCreateCommandEncoder(h.device, null);
        const pass = host.beginPass(encoder, target.view, null, .{ 0, 0, 0, 1 });
        gfx.render(pass, d);
        host.endPass(pass);
        h.submit(encoder);
        var px: [4 * 4 * 4]u8 = undefined;
        try h.readback(&target, &px);
        for (0..4) |y| for (0..4) |x| {
            try testing.expectEqualSlices(u8, want[((y / 2) * 2 + x / 2) * 4 ..][0..4], px[(y * 4 + x) * 4 ..][0..4]);
        };
    }
}

test "native: the glyph texture uploads only what the atlas changed" {
    var h = try host.Host.init();
    defer h.deinit();
    var px: [32 * 16]u8 = undefined;
    var sky: [3][32]u32 = undefined;
    var atlas = lcgf.raster_atlas.Atlas.init(32, 16, &px, .{ .x = &sky[0], .y = &sky[1], .w = &sky[2] });
    var tex = glyphs.GlyphTexture.init(h.device, 32, 16);
    defer tex.deinit();
    try testing.expectEqual(@as(u32, 32 * 16), tex.upload(h.queue, &atlas)); // cleared: all of it
    try testing.expectEqual(@as(u32, 0), tex.upload(h.queue, &atlas));
    const r = atlas.pack(5, 7).?;
    atlas.put(r, &@as([35]u8, @splat(200)));
    try testing.expectEqual(@as(u32, 5 * 7), tex.upload(h.queue, &atlas));
}

test "native: multisampling resolves into the target and changes only edge pixels" {
    var h = try host.Host.init();
    defer h.deinit();
    var ctx = Context.init(h.device);
    defer ctx.deinit();
    const sampler = host.nearestSampler(&h);
    defer c.wgpuSamplerRelease(sampler);
    var white = host.Image.init(&h, 1, 1, &.{ 0xff, 0xff, 0xff, 0xff });
    defer white.deinit();
    // A square turned 45 degrees about (16, 16): its edges cross pixels, where the triangle
    // rasteriser (not the shader's distance field) decides coverage.
    const k = std.math.sqrt1_2;
    var one: OneQuad = undefined;
    one.init(.{
        .rect = .{ 8, 8, 24, 24 },
        .clip = .{ -1e6, -1e6, 1e6, 1e6 },
        .params = @splat(0),
        .uv = .{ 0, 0, 1, 1 },
        .radii = @splat(0),
        .fill = lcgf.types.Color.white.bitsOf(),
        .border_color = 0,
        .border = 0,
        .opacity = 1,
        .xform = .{ k, k, -k, k, 16, 16 - 16 * std.math.sqrt2 },
    }, .white);

    var images: [2][32 * 32 * 4]u8 = undefined;
    for ([_]u32{ 1, 4 }, &images) |samples, *px| {
        var gfx = Renderer.init(&ctx, .{ .format = c.WGPUTextureFormat_RGBA8Unorm, .sample_count = samples }, white.view, sampler);
        defer gfx.deinit();
        var target = host.Target.init(&h, 32, 32, c.WGPUTextureFormat_RGBA8Unorm);
        defer target.deinit();
        var msaa = Multisample.init(h.device, 32, 32, c.WGPUTextureFormat_RGBA8Unorm, 4);
        defer msaa.deinit();
        gfx.prepare(h.queue, &one.draw, .{}, .{ 32, 32 }, 1);
        const encoder = c.wgpuDeviceCreateCommandEncoder(h.device, null);
        const pass = if (samples > 1)
            host.beginPass(encoder, msaa.view, target.view, .{ 0, 0, 0, 1 })
        else
            host.beginPass(encoder, target.view, null, .{ 0, 0, 0, 1 });
        gfx.render(pass, &one.draw);
        host.endPass(pass);
        h.submit(encoder);
        try h.readback(&target, px);
    }
    // The centre is solid white either way; some edge pixels differ.
    const centre = (16 * 32 + 16) * 4;
    for (images) |px| try testing.expectEqualSlices(u8, &.{ 255, 255, 255, 255 }, px[centre..][0..4]);
    var differ: u32 = 0;
    for (0..32 * 32) |i| differ += @intFromBool(!std.mem.eql(u8, images[0][i * 4 ..][0..4], images[1][i * 4 ..][0..4]));
    std.debug.print("multisampling: {d} of 1024 pixels differ from 1x\n", .{differ});
    try testing.expect(differ > 0 and differ < 200);
}
