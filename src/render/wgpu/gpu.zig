//! `lcgf_render.gpu` on wgpu-native: the projection is the identity. Every type is the
//! `webgpu.h` handle it names (`pass.pass` is the `WGPURenderPassEncoder`), every call one
//! `wgpu*` call. WGSL goes to wgpu as written; bind group layouts are the pipeline's own
//! (`layout = null`, WebGPU's "auto"), which is why `createBindGroup` takes the pipeline.
//!
//! The phases are WebGPU's own: `Upload` writes through the queue (`wgpuQueueWriteBuffer`,
//! ordered before the commands submitted after it), and wgpu tracks what each pass uses.
//! Here the projection only gives the same shape the native back ends have, so application
//! code written against `lcgf_render.gpu` runs on real WebGPU unchanged.

const std = @import("std");
const lcgf = @import("lcgf");
const native_mod = @import("native.zig");
const c = native_mod.c;
const sv = native_mod.host.sv;
const desc = lcgf.gpu_desc;
const reflect = lcgf.gpu_reflect;

pub const Error = error{ OutOfArena, IncompatibleMemory, UnsupportedFormat, PipelineFailed, MapFailed };

pub const BufferUsage = desc.BufferUsage;
pub const BufferDescriptor = desc.BufferDescriptor;
pub const TextureUsage = desc.TextureUsage;
pub const TextureFormat = desc.TextureFormat;
pub const TextureDescriptor = desc.TextureDescriptor;
pub const SamplerDescriptor = desc.SamplerDescriptor;
pub const VertexFormat = desc.VertexFormat;
pub const VertexBufferLayout = desc.VertexBufferLayout;
pub const VertexAttribute = desc.VertexAttribute;
pub const PrimitiveTopology = desc.PrimitiveTopology;
pub const IndexFormat = desc.IndexFormat;
pub const BlendState = desc.BlendState;
pub const ColorTargetState = desc.ColorTargetState;
pub const RenderPipelineDescriptor = desc.RenderPipelineDescriptor;
pub const ComputePipelineDescriptor = desc.ComputePipelineDescriptor;
pub const LoadOp = desc.LoadOp;
pub const StoreOp = desc.StoreOp;
pub const Color = desc.Color;
pub const Target = desc.Target;
pub const Rect = desc.Rect;
pub const scissor = desc.scissor;

pub const native = .wgpu;
/// webgpu.h, as this back end translated it.
pub const webgpu = c;

// No debug checks of its own: wgpu-native validates every call, in every build mode, which is
// the cost the native projections avoid.

pub const max_groups = 4;
pub const max_color_targets = 4;
pub const max_vertex_buffers = 8;
pub const max_vertex_attributes = 16;

// ---------------------------------------------------------------------------------------------
// Device and memory

pub const Device = struct {
    device: c.WGPUDevice,
    queue: c.WGPUQueue,

    pub fn wrap(device: c.WGPUDevice, queue: c.WGPUQueue) Device {
        return .{ .device = device, .queue = queue };
    }

    pub fn createBuffer(device: Device, arena: *Arena, d: BufferDescriptor) Error!Buffer {
        _ = arena;
        const b = c.wgpuDeviceCreateBuffer(device.device, &.{ .usage = bufferUsage(d.usage), .size = d.size });
        return .{ .buffer = b, .size = d.size, .mapped = null };
    }

    pub fn destroyBuffer(_: Device, b: Buffer) void {
        c.wgpuBufferRelease(b.buffer);
    }

    pub fn createTexture(device: Device, arena: *Arena, d: TextureDescriptor) Error!Texture {
        _ = arena;
        const t = c.wgpuDeviceCreateTexture(device.device, &.{
            .usage = textureUsage(d.usage),
            .dimension = c.WGPUTextureDimension_2D,
            .size = .{ .width = d.size.width, .height = d.size.height, .depthOrArrayLayers = d.size.depth_or_array_layers },
            .format = try wgpuFormat(d.format),
            .mipLevelCount = d.mip_level_count,
            .sampleCount = d.sample_count,
        });
        return .{ .texture = t, .view = c.wgpuTextureCreateView(t, null), .format = d.format, .width = d.size.width, .height = d.size.height, .samples = d.sample_count };
    }

    pub fn destroyTexture(_: Device, t: Texture) void {
        c.wgpuTextureViewRelease(t.view);
        c.wgpuTextureRelease(t.texture);
    }

    pub fn createSampler(device: Device, d: SamplerDescriptor) Error!Sampler {
        return .{ .sampler = c.wgpuDeviceCreateSampler(device.device, &.{
            .addressModeU = addressMode(d.address_mode_u),
            .addressModeV = addressMode(d.address_mode_v),
            .addressModeW = addressMode(d.address_mode_w),
            .magFilter = if (d.mag_filter == .linear) c.WGPUFilterMode_Linear else c.WGPUFilterMode_Nearest,
            .minFilter = if (d.min_filter == .linear) c.WGPUFilterMode_Linear else c.WGPUFilterMode_Nearest,
            .mipmapFilter = if (d.mipmap_filter == .linear) c.WGPUMipmapFilterMode_Linear else c.WGPUMipmapFilterMode_Nearest,
            .lodMinClamp = d.lod_min_clamp,
            .lodMaxClamp = d.lod_max_clamp,
            .compare = if (d.compare) |f| compareFunction(f) else c.WGPUCompareFunction_Undefined,
            .maxAnisotropy = 1,
        }) };
    }

    pub fn destroySampler(_: Device, s: Sampler) void {
        c.wgpuSamplerRelease(s.sampler);
    }

    pub fn createRenderPipeline(device: Device, comptime S: type, d: RenderPipelineDescriptor) Error!RenderPipeline(S) {
        const module = shaderModule(device.device, S.wgsl);
        defer c.wgpuShaderModuleRelease(module);
        var buffers: [max_vertex_buffers]c.WGPUVertexBufferLayout = undefined;
        var attrs: [max_vertex_attributes]c.WGPUVertexAttribute = undefined;
        var na: usize = 0;
        for (d.vertex.buffers, 0..) |vb, i| {
            const first = na;
            for (vb.attributes) |a| {
                attrs[na] = .{ .format = vertexFormat(a.format), .offset = a.offset, .shaderLocation = a.shader_location };
                na += 1;
            }
            buffers[i] = .{
                .stepMode = if (vb.step_mode == .instance) c.WGPUVertexStepMode_Instance else c.WGPUVertexStepMode_Vertex,
                .arrayStride = vb.array_stride,
                .attributeCount = na - first,
                .attributes = &attrs[first],
            };
        }
        var blends: [max_color_targets]c.WGPUBlendState = undefined;
        var targets: [max_color_targets]c.WGPUColorTargetState = undefined;
        const frag = d.fragment orelse desc.FragmentState{ .targets = &.{} };
        for (frag.targets, 0..) |t, i| {
            const m = t.write_mask;
            targets[i] = .{
                .format = try wgpuFormat(t.format),
                .blend = null,
                .writeMask = (if (m.red) c.WGPUColorWriteMask_Red else 0) | (if (m.green) c.WGPUColorWriteMask_Green else 0) |
                    (if (m.blue) c.WGPUColorWriteMask_Blue else 0) | (if (m.alpha) c.WGPUColorWriteMask_Alpha else 0),
            };
            if (t.blend) |b| {
                blends[i] = .{ .color = blendComponent(b.color), .alpha = blendComponent(b.alpha) };
                targets[i].blend = &blends[i];
            }
        }
        const fragment: c.WGPUFragmentState = .{ .module = module, .entryPoint = sv(frag.entry_point), .targetCount = frag.targets.len, .targets = &targets };
        const p = c.wgpuDeviceCreateRenderPipeline(device.device, &.{
            .layout = null,
            .vertex = .{ .module = module, .entryPoint = sv(d.vertex.entry_point), .bufferCount = d.vertex.buffers.len, .buffers = &buffers },
            .primitive = .{
                .topology = topology(d.primitive.topology),
                .stripIndexFormat = if (d.primitive.strip_index_format) |f| indexFormat(f) else c.WGPUIndexFormat_Undefined,
                .frontFace = if (d.primitive.front_face == .ccw) c.WGPUFrontFace_CCW else c.WGPUFrontFace_CW,
                .cullMode = switch (d.primitive.cull_mode) {
                    .none => c.WGPUCullMode_None,
                    .front => c.WGPUCullMode_Front,
                    .back => c.WGPUCullMode_Back,
                },
            },
            .multisample = .{ .count = d.multisample.count, .mask = d.multisample.mask, .alphaToCoverageEnabled = @intFromBool(d.multisample.alpha_to_coverage_enabled) },
            .fragment = if (d.fragment != null) &fragment else null,
        }) orelse return error.PipelineFailed;
        return .{ .pipeline = p };
    }

    pub fn destroyRenderPipeline(_: Device, p: anytype) void {
        if (@hasField(@TypeOf(p), "compute")) c.wgpuComputePipelineRelease(p.compute) else c.wgpuRenderPipelineRelease(p.pipeline);
    }

    pub fn createComputePipeline(device: Device, comptime S: type, d: ComputePipelineDescriptor) Error!ComputePipeline(S) {
        const module = shaderModule(device.device, S.wgsl);
        defer c.wgpuShaderModuleRelease(module);
        const p = c.wgpuDeviceCreateComputePipeline(device.device, &.{
            .layout = null,
            .compute = .{ .module = module, .entryPoint = sv(d.entry_point) },
        }) orelse return error.PipelineFailed;
        return .{ .compute = p };
    }

    pub const destroyComputePipeline = destroyRenderPipeline;

    pub fn createBindGroup(device: Device, arena: *Arena, pipeline: anytype, comptime g: u32, entries: Deref(@TypeOf(pipeline)).Shader.Group(g)) Error!BindGroup(Deref(@TypeOf(pipeline)).Shader, g) {
        _ = arena;
        const P = Deref(@TypeOf(pipeline));
        const S = P.Shader;
        const layout = if (@hasField(P, "compute")) c.wgpuComputePipelineGetBindGroupLayout(pipeline.compute, g) else c.wgpuRenderPipelineGetBindGroupLayout(pipeline.pipeline, g);
        defer c.wgpuBindGroupLayoutRelease(layout);
        const bindings = comptime S.module.group(g);
        var es: [bindings.len]c.WGPUBindGroupEntry = undefined;
        inline for (bindings, 0..) |b, i| {
            const v = @field(entries, b.name);
            es[i] = .{ .binding = b.binding };
            switch (comptime b.kind) {
                .uniform, .storage_read, .storage_read_write => {
                    es[i].buffer = v.buffer;
                    es[i].size = c.WGPU_WHOLE_SIZE;
                },
                .texture, .storage_texture => es[i].textureView = v.view,
                .sampler, .comparison_sampler => es[i].sampler = v.sampler,
            }
        }
        return .{ .group = c.wgpuDeviceCreateBindGroup(device.device, &.{ .layout = layout, .entryCount = es.len, .entries = &es }) };
    }

    /// Copies `out.len` bytes of `b` from `offset` into `out`: a copy into a mappable buffer,
    /// mapped and waited for (WebGPU's `mapAsync`, made synchronous for a host that knows the
    /// writes are done). `b` needs `copy_src`.
    pub fn readBuffer(device: Device, instance: c.WGPUInstance, b: Buffer, offset: u64, out: []u8) Error!void {
        const size = std.mem.alignForward(u64, out.len, 4);
        const staging = c.wgpuDeviceCreateBuffer(device.device, &.{ .usage = c.WGPUBufferUsage_MapRead | c.WGPUBufferUsage_CopyDst, .size = size });
        defer c.wgpuBufferRelease(staging);
        const encoder = c.wgpuDeviceCreateCommandEncoder(device.device, null);
        c.wgpuCommandEncoderCopyBufferToBuffer(encoder, b.buffer, offset, staging, 0, size);
        const commands = c.wgpuCommandEncoderFinish(encoder, null);
        c.wgpuQueueSubmit(device.queue, 1, &commands);
        c.wgpuCommandBufferRelease(commands);
        c.wgpuCommandEncoderRelease(encoder);
        const Mapped = struct {
            done: bool = false,
            ok: bool = false,
            fn on(status: c.WGPUMapAsyncStatus, _: c.WGPUStringView, ud: ?*anyopaque, _: ?*anyopaque) callconv(.c) void {
                const m: *@This() = @ptrCast(@alignCast(ud));
                m.done = true;
                m.ok = status == c.WGPUMapAsyncStatus_Success;
            }
        };
        var mapped: Mapped = .{};
        _ = c.wgpuBufferMapAsync(staging, c.WGPUMapMode_Read, 0, @intCast(size), .{ .mode = c.WGPUCallbackMode_AllowProcessEvents, .callback = Mapped.on, .userdata1 = &mapped });
        var polls: u32 = 0;
        while (!mapped.done and polls < 1_000_000) : (polls += 1) {
            _ = c.wgpuDevicePoll(device.device, 1, null);
            c.wgpuInstanceProcessEvents(instance);
        }
        if (!mapped.ok) return error.MapFailed;
        const bytes: [*]const u8 = @ptrCast(c.wgpuBufferGetConstMappedRange(staging, 0, @intCast(size)));
        @memcpy(out, bytes[0..out.len]);
        c.wgpuBufferUnmap(staging);
    }
};

/// WebGPU allocates its own memory: an arena is only the projection's uniform interface.
pub const Arena = struct {
    pub const Kind = enum { device, host };
    pub const Options = struct { bytes: u64, memory: Kind = .device, bind_groups: u32 = 64 };
    pub fn init(_: Device, _: Options) Error!Arena {
        return .{};
    }
    pub fn deinit(_: *Arena) void {}
    pub fn reset(_: *Arena) void {}
};

/// WebGPU stages writes itself; staging exists for the uniform interface.
pub const Staging = struct {
    pub fn init(_: Device, _: *Arena, _: u64) Error!Staging {
        return .{};
    }
    pub fn deinit(_: Staging, _: Device) void {}
    pub fn rewind(_: *Staging) void {}
};

// ---------------------------------------------------------------------------------------------
// Objects

pub const Buffer = struct { buffer: c.WGPUBuffer, size: u64, mapped: ?[*]u8 };

pub const Texture = struct {
    texture: c.WGPUTexture,
    /// The default view, made with the texture.
    view: c.WGPUTextureView,
    format: TextureFormat,
    width: u32,
    height: u32,
    samples: u32,

    pub fn createView(t: Texture) TextureView {
        return .{ .view = t.view, .texture = t.texture, .width = t.width, .height = t.height, .samples = t.samples, .format = t.format };
    }
};

pub const TextureView = struct {
    view: c.WGPUTextureView,
    texture: c.WGPUTexture = null,
    width: u32,
    height: u32,
    samples: u32 = 1,
    format: TextureFormat = .rgba8_unorm,
};

pub const Sampler = struct { sampler: c.WGPUSampler };

/// A shader: `source` is a namespace with `wgsl`. WebGPU takes it as it is.
pub fn Shader(comptime source: type) type {
    return struct {
        pub const module = reflect.parse(source.wgsl);
        pub const wgsl: []const u8 = source.wgsl;
        pub fn Group(comptime g: u32) type {
            return module.Group(g, Buffer, TextureView, Sampler);
        }
    };
}

pub fn RenderPipeline(comptime S: type) type {
    return struct {
        pipeline: c.WGPURenderPipeline,
        pub const Shader = S;
    };
}

pub fn ComputePipeline(comptime S: type) type {
    return struct {
        compute: c.WGPUComputePipeline,
        pub const Shader = S;
    };
}

pub fn BindGroup(comptime S: type, comptime g: u32) type {
    return struct {
        group: c.WGPUBindGroup,
        pub const Shader = S;
        pub const index = g;
    };
}

// ---------------------------------------------------------------------------------------------
// Frame phases

/// The write phase: WebGPU's queue writes, ordered before the commands submitted after them.
pub const Upload = struct {
    queue: c.WGPUQueue,
    encoder: c.WGPUCommandEncoder,

    pub fn begin(device: Device, encoder: c.WGPUCommandEncoder) Upload {
        return .{ .queue = device.queue, .encoder = encoder };
    }

    pub fn beginStaged(device: Device, encoder: c.WGPUCommandEncoder, _: *Staging) Upload {
        return begin(device, encoder);
    }

    pub fn writeBuffer(up: *Upload, buffer: Buffer, offset: u64, bytes: []const u8) void {
        c.wgpuQueueWriteBuffer(up.queue, buffer.buffer, offset, bytes.ptr, bytes.len);
    }

    pub fn writeTexture(up: *Upload, t: Texture, bytes: []const u8, bytes_per_row: u32) Error!void {
        c.wgpuQueueWriteTexture(up.queue, &.{ .texture = t.texture, .aspect = c.WGPUTextureAspect_All }, bytes.ptr, bytes.len, &.{
            .bytesPerRow = bytes_per_row,
            .rowsPerImage = t.height,
        }, &.{ .width = t.width, .height = t.height, .depthOrArrayLayers = 1 });
    }

    pub fn prepare(_: *Upload, _: Texture) void {}

    pub fn finish(up: *Upload) Encoder {
        return .{ .encoder = up.encoder };
    }
};

pub const ColorAttachment = struct {
    view: TextureView,
    resolve_target: ?TextureView = null,
    load_op: LoadOp = .clear,
    store_op: StoreOp = .store,
    clear_value: Color = .{},
};

pub const RenderPassDescriptor = struct {
    color_attachments: []const ColorAttachment,
};

pub const Encoder = struct {
    encoder: c.WGPUCommandEncoder,

    pub fn beginRenderPass(e: Encoder, d: RenderPassDescriptor) RenderPass {
        var attachments: [max_color_targets]c.WGPURenderPassColorAttachment = undefined;
        var p: RenderPass = .{ .pass = undefined, .width = 0, .height = 0, .owned = true };
        for (d.color_attachments, 0..) |a, i| {
            const cv = a.clear_value;
            attachments[i] = .{
                .view = a.view.view,
                .depthSlice = c.WGPU_DEPTH_SLICE_UNDEFINED,
                .resolveTarget = if (a.resolve_target) |r| r.view else null,
                .loadOp = if (a.load_op == .clear) c.WGPULoadOp_Clear else c.WGPULoadOp_Load,
                .storeOp = if (a.store_op == .store) c.WGPUStoreOp_Store else c.WGPUStoreOp_Discard,
                .clearValue = .{ .r = cv.r, .g = cv.g, .b = cv.b, .a = cv.a },
            };
            p.width = a.view.width;
            p.height = a.view.height;
        }
        p.pass = c.wgpuCommandEncoderBeginRenderPass(e.encoder, &.{ .colorAttachmentCount = d.color_attachments.len, .colorAttachments = &attachments });
        return p;
    }

    pub fn beginComputePass(e: Encoder) ComputePass {
        return .{ .pass = c.wgpuCommandEncoderBeginComputePass(e.encoder, null) };
    }
};

pub const RenderPass = struct {
    pass: c.WGPURenderPassEncoder,
    width: u32,
    height: u32,
    owned: bool = false,

    /// The pass the host is recording (the UI's, for an inline custom draw).
    pub fn wrap(_: Device, pass: c.WGPURenderPassEncoder, width: u32, height: u32) RenderPass {
        return .{ .pass = pass, .width = width, .height = height };
    }

    pub inline fn setPipeline(p: *RenderPass, pipeline: anytype) void {
        c.wgpuRenderPassEncoderSetPipeline(p.pass, pipeline.pipeline);
    }

    pub inline fn setBindGroup(p: *RenderPass, comptime index: u32, group: anytype) void {
        comptime checkIndex(Deref(@TypeOf(group)), index);
        c.wgpuRenderPassEncoderSetBindGroup(p.pass, index, group.group, 0, null);
    }

    pub inline fn setVertexBuffer(p: *RenderPass, slot: u32, buffer: Buffer, offset: u64) void {
        c.wgpuRenderPassEncoderSetVertexBuffer(p.pass, slot, buffer.buffer, offset, c.WGPU_WHOLE_SIZE);
    }

    pub inline fn setIndexBuffer(p: *RenderPass, buffer: Buffer, format: IndexFormat, offset: u64) void {
        c.wgpuRenderPassEncoderSetIndexBuffer(p.pass, buffer.buffer, indexFormat(format), offset, c.WGPU_WHOLE_SIZE);
    }

    pub inline fn setViewport(p: *RenderPass, x: f32, y: f32, w: f32, h: f32, min_depth: f32, max_depth: f32) void {
        c.wgpuRenderPassEncoderSetViewport(p.pass, x, y, w, h, min_depth, max_depth);
    }

    pub inline fn setScissorRect(p: *RenderPass, x: u32, y: u32, w: u32, h: u32) void {
        c.wgpuRenderPassEncoderSetScissorRect(p.pass, x, y, w, h);
    }

    pub inline fn setBlendConstant(p: *RenderPass, color: Color) void {
        c.wgpuRenderPassEncoderSetBlendConstant(p.pass, &.{ .r = color.r, .g = color.g, .b = color.b, .a = color.a });
    }

    pub inline fn draw(p: *RenderPass, vertex_count: u32, instance_count: u32, first_vertex: u32, first_instance: u32) void {
        c.wgpuRenderPassEncoderDraw(p.pass, vertex_count, instance_count, first_vertex, first_instance);
    }

    pub inline fn drawIndexed(p: *RenderPass, index_count: u32, instance_count: u32, first_index: u32, base_vertex: i32, first_instance: u32) void {
        c.wgpuRenderPassEncoderDrawIndexed(p.pass, index_count, instance_count, first_index, base_vertex, first_instance);
    }

    /// Ends and releases a pass the projection began. A wrapped pass is the host's.
    pub fn end(p: *RenderPass) void {
        if (!p.owned) return;
        c.wgpuRenderPassEncoderEnd(p.pass);
        c.wgpuRenderPassEncoderRelease(p.pass);
        p.owned = false;
    }
};

pub const ComputePass = struct {
    pass: c.WGPUComputePassEncoder,

    pub inline fn setPipeline(p: *ComputePass, pipeline: anytype) void {
        c.wgpuComputePassEncoderSetPipeline(p.pass, pipeline.compute);
    }

    pub inline fn setBindGroup(p: *ComputePass, comptime index: u32, group: anytype) void {
        comptime checkIndex(Deref(@TypeOf(group)), index);
        c.wgpuComputePassEncoderSetBindGroup(p.pass, index, group.group, 0, null);
    }

    pub inline fn dispatchWorkgroups(p: *ComputePass, x: u32, y: u32, z: u32) void {
        c.wgpuComputePassEncoderDispatchWorkgroups(p.pass, x, y, z);
    }

    pub fn end(p: *ComputePass) void {
        c.wgpuComputePassEncoderEnd(p.pass);
        c.wgpuComputePassEncoderRelease(p.pass);
    }
};

fn Deref(comptime T: type) type {
    return switch (@typeInfo(T)) {
        .pointer => |ptr| ptr.child,
        else => T,
    };
}

fn checkIndex(comptime G: type, comptime index: u32) void {
    if (!@hasDecl(G, "index")) @compileError("setBindGroup takes a BindGroup made by createBindGroup");
    if (G.index != index) @compileError(std.fmt.comptimePrint("bind group made for @group({d}) set at index {d}", .{ G.index, index }));
}

// ---------------------------------------------------------------------------------------------
// Conversions

fn shaderModule(device: c.WGPUDevice, wgsl: []const u8) c.WGPUShaderModule {
    const source: c.WGPUShaderSourceWGSL = .{ .chain = .{ .sType = c.WGPUSType_ShaderSourceWGSL }, .code = sv(wgsl) };
    return c.wgpuDeviceCreateShaderModule(device, &.{ .nextInChain = @constCast(&source.chain) });
}

fn bufferUsage(u: BufferUsage) c.WGPUBufferUsage {
    var f: c.WGPUBufferUsage = 0;
    if (u.map_read) f |= c.WGPUBufferUsage_MapRead;
    if (u.map_write) f |= c.WGPUBufferUsage_MapWrite;
    if (u.copy_src) f |= c.WGPUBufferUsage_CopySrc;
    if (u.copy_dst) f |= c.WGPUBufferUsage_CopyDst;
    if (u.index) f |= c.WGPUBufferUsage_Index;
    if (u.vertex) f |= c.WGPUBufferUsage_Vertex;
    if (u.uniform) f |= c.WGPUBufferUsage_Uniform;
    if (u.storage) f |= c.WGPUBufferUsage_Storage;
    if (u.indirect) f |= c.WGPUBufferUsage_Indirect;
    return f;
}

fn textureUsage(u: TextureUsage) c.WGPUTextureUsage {
    var f: c.WGPUTextureUsage = 0;
    if (u.copy_src) f |= c.WGPUTextureUsage_CopySrc;
    if (u.copy_dst) f |= c.WGPUTextureUsage_CopyDst;
    if (u.texture_binding) f |= c.WGPUTextureUsage_TextureBinding;
    if (u.storage_binding) f |= c.WGPUTextureUsage_StorageBinding;
    if (u.render_attachment) f |= c.WGPUTextureUsage_RenderAttachment;
    return f;
}

pub fn wgpuFormat(f: TextureFormat) Error!c.WGPUTextureFormat {
    return switch (f) {
        .r8_unorm => c.WGPUTextureFormat_R8Unorm,
        .rg8_unorm => c.WGPUTextureFormat_RG8Unorm,
        .rgba8_unorm => c.WGPUTextureFormat_RGBA8Unorm,
        .rgba8_unorm_srgb => c.WGPUTextureFormat_RGBA8UnormSrgb,
        .bgra8_unorm => c.WGPUTextureFormat_BGRA8Unorm,
        .bgra8_unorm_srgb => c.WGPUTextureFormat_BGRA8UnormSrgb,
        .r16_float => c.WGPUTextureFormat_R16Float,
        .rgba16_float => c.WGPUTextureFormat_RGBA16Float,
        .r32_float => c.WGPUTextureFormat_R32Float,
        .rg32_float => c.WGPUTextureFormat_RG32Float,
        .rgba32_float => c.WGPUTextureFormat_RGBA32Float,
        .r32_uint => c.WGPUTextureFormat_R32Uint,
        .depth32_float => c.WGPUTextureFormat_Depth32Float,
    };
}

fn vertexFormat(f: VertexFormat) c.WGPUVertexFormat {
    return switch (f) {
        .float32 => c.WGPUVertexFormat_Float32,
        .float32x2 => c.WGPUVertexFormat_Float32x2,
        .float32x3 => c.WGPUVertexFormat_Float32x3,
        .float32x4 => c.WGPUVertexFormat_Float32x4,
        .uint32 => c.WGPUVertexFormat_Uint32,
        .uint32x2 => c.WGPUVertexFormat_Uint32x2,
        .uint32x4 => c.WGPUVertexFormat_Uint32x4,
        .sint32 => c.WGPUVertexFormat_Sint32,
        .sint32x2 => c.WGPUVertexFormat_Sint32x2,
        .sint32x4 => c.WGPUVertexFormat_Sint32x4,
        .unorm8x4 => c.WGPUVertexFormat_Unorm8x4,
    };
}

fn topology(t: PrimitiveTopology) c.WGPUPrimitiveTopology {
    return switch (t) {
        .point_list => c.WGPUPrimitiveTopology_PointList,
        .line_list => c.WGPUPrimitiveTopology_LineList,
        .line_strip => c.WGPUPrimitiveTopology_LineStrip,
        .triangle_list => c.WGPUPrimitiveTopology_TriangleList,
        .triangle_strip => c.WGPUPrimitiveTopology_TriangleStrip,
    };
}

fn indexFormat(f: IndexFormat) c.WGPUIndexFormat {
    return if (f == .uint16) c.WGPUIndexFormat_Uint16 else c.WGPUIndexFormat_Uint32;
}

fn addressMode(a: desc.AddressMode) c.WGPUAddressMode {
    return switch (a) {
        .clamp_to_edge => c.WGPUAddressMode_ClampToEdge,
        .repeat => c.WGPUAddressMode_Repeat,
        .mirror_repeat => c.WGPUAddressMode_MirrorRepeat,
    };
}

fn compareFunction(f: desc.CompareFunction) c.WGPUCompareFunction {
    return switch (f) {
        .never => c.WGPUCompareFunction_Never,
        .less => c.WGPUCompareFunction_Less,
        .equal => c.WGPUCompareFunction_Equal,
        .less_equal => c.WGPUCompareFunction_LessEqual,
        .greater => c.WGPUCompareFunction_Greater,
        .not_equal => c.WGPUCompareFunction_NotEqual,
        .greater_equal => c.WGPUCompareFunction_GreaterEqual,
        .always => c.WGPUCompareFunction_Always,
    };
}

fn blendComponent(b: desc.BlendComponent) c.WGPUBlendComponent {
    const factor = struct {
        fn f(x: desc.BlendFactor) c.WGPUBlendFactor {
            return switch (x) {
                .zero => c.WGPUBlendFactor_Zero,
                .one => c.WGPUBlendFactor_One,
                .src => c.WGPUBlendFactor_Src,
                .one_minus_src => c.WGPUBlendFactor_OneMinusSrc,
                .src_alpha => c.WGPUBlendFactor_SrcAlpha,
                .one_minus_src_alpha => c.WGPUBlendFactor_OneMinusSrcAlpha,
                .dst => c.WGPUBlendFactor_Dst,
                .one_minus_dst => c.WGPUBlendFactor_OneMinusDst,
                .dst_alpha => c.WGPUBlendFactor_DstAlpha,
                .one_minus_dst_alpha => c.WGPUBlendFactor_OneMinusDstAlpha,
                .constant => c.WGPUBlendFactor_Constant,
                .one_minus_constant => c.WGPUBlendFactor_OneMinusConstant,
            };
        }
    }.f;
    return .{
        .operation = switch (b.operation) {
            .add => c.WGPUBlendOperation_Add,
            .subtract => c.WGPUBlendOperation_Subtract,
            .reverse_subtract => c.WGPUBlendOperation_ReverseSubtract,
            .min => c.WGPUBlendOperation_Min,
            .max => c.WGPUBlendOperation_Max,
        },
        .srcFactor = factor(b.src_factor),
        .dstFactor = factor(b.dst_factor),
    };
}

const testing = std.testing;
const host = native_mod.host;
const shaders = @import("gpu_shaders");

/// The host side of lcgf.gpu_check on wgpu-native: one encoder per upload, submitted whole.
const Check = struct {
    h: *host.Host,
    encoder: c.WGPUCommandEncoder = null,

    fn device(k: *Check) Device {
        return .wrap(k.h.device, k.h.queue);
    }
    pub fn upload(k: *Check, staging: *Staging) !Upload {
        k.encoder = c.wgpuDeviceCreateCommandEncoder(k.h.device, null);
        return .beginStaged(k.device(), k.encoder, staging);
    }
    pub fn submit(k: *Check) !void {
        k.h.submit(k.encoder);
    }
    pub fn readTexture(k: *Check, t: Texture, out: []u8) !void {
        const target: host.Target = .{ .texture = t.texture, .view = t.view, .width = t.width, .height = t.height };
        try k.h.readback(&target, out);
    }
    pub fn readBuffer(k: *Check, b: Buffer, out: []u8) !void {
        try k.device().readBuffer(k.h.instance, b, 0, out);
    }
};

test "gpu: upload, render to a texture, sample it in a second pass, on a real adapter" {
    var h = try host.Host.init();
    defer h.deinit();
    var k: Check = .{ .h = &h };
    try lcgf.gpu_check.renderToTexture(@This(), shaders, k.device(), &k);
}

test "gpu: instanced draws from a first instance, integer attributes, an offset buffer" {
    var h = try host.Host.init();
    defer h.deinit();
    var k: Check = .{ .h = &h };
    try lcgf.gpu_check.instancing(@This(), shaders, k.device(), &k);
}

test "gpu: a compute pass writes a storage buffer the host reads" {
    var h = try host.Host.init();
    defer h.deinit();
    var k: Check = .{ .h = &h };
    try lcgf.gpu_check.compute(@This(), shaders, k.device(), &k);
}
