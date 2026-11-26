//! `lcgf_render.gpu` on Metal: WebGPU's object model projected onto Metal at compile time. Every
//! type is a plain struct of Metal objects with public fields (`pass.encoder` is the
//! `MTLRenderCommandEncoder`, `buffer.buffer` the `MTLBuffer`), sent messages through the
//! back end's Objective-C runtime (objc.zig).
//!
//! Bind groups are lists of objects bound at the slots naga's MSL declares, assigned at compile
//! time (src/render/gpu/naga.zig): buffers, textures and samplers flat per kind in (group,
//! binding) order, vertex buffers counted down from slot 30. `setBindGroup` binds a group's
//! objects to both stages, unrolled. Runtime-sized storage arrays get their lengths through
//! naga's `_buffer_sizes` slot before each draw or dispatch that needs them.
//!
//! Metal tracks hazards between encoders for the resources it creates, so the phases need no
//! barriers: `Upload` is a blit encoder copying from the device's staging ring (queue-ordered,
//! like WebGPU's `writeBuffer`), and each pass is its own encoder on the host's command buffer.
//!
//! Memory: each resource is its own allocation (`.device` arenas private storage, `.host`
//! arenas shared and mapped). The arena is the projection's uniform interface.

const std = @import("std");
const builtin = @import("builtin");
const lcgf = @import("lcgf");
const objc = @import("objc.zig");
const desc = lcgf.gpu_desc;
const reflect = lcgf.gpu_reflect;
const naga = lcgf.gpu_naga;
const Id = objc.Id;
const msg = objc.msg;
const U = objc.NSUInteger;

pub const Error = error{ ShaderCompile, MissingEntryPoint, PipelineFailed, ResourceFailed, OutOfArena, IncompatibleMemory, UnsupportedFormat, NoStaging };

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

pub const native = .metal;
/// The Objective-C runtime the back end talks to Metal through.
pub const runtime = objc;

const debug_checks = builtin.mode == .debug;

pub const max_groups = 4;
pub const max_color_targets = 4;
pub const max_vertex_buffers = 8;
pub const max_vertex_attributes = 16;
const max_sized = 8;

const storage_shared: U = 0;
const storage_private: U = 2 << 4;
const MTLViewport = extern struct { x: f64, y: f64, width: f64, height: f64, znear: f64, zfar: f64 };
const MTLScissorRect = extern struct { x: U, y: U, width: U, height: U };
const MTLSize = extern struct { width: U, height: U, depth: U };
const MTLOrigin = extern struct { x: U = 0, y: U = 0, z: U = 0 };
const MTLClearColor = extern struct { r: f64, g: f64, b: f64, a: f64 };

// ---------------------------------------------------------------------------------------------
// Device and memory

pub const Device = struct {
    device: Id,
    /// Where uploads copy from. Set it before the first `Upload.begin`.
    staging: ?*Staging = null,

    pub fn wrap(device: Id) Device {
        return .{ .device = device };
    }

    pub fn createBuffer(device: Device, arena: *Arena, d: BufferDescriptor) Error!Buffer {
        const shared = arena.kind == .host;
        const b = msg(?Id, device.device, "newBufferWithLength:options:", .{ @as(U, @max(d.size, 4)), if (shared) storage_shared else storage_private }) orelse return error.ResourceFailed;
        return .{ .buffer = b, .size = d.size, .mapped = if (shared) msg([*]u8, b, "contents", .{}) else null };
    }

    pub fn destroyBuffer(_: Device, b: Buffer) void {
        objc.release(b.buffer);
    }

    pub fn createTexture(device: Device, arena: *Arena, d: TextureDescriptor) Error!Texture {
        _ = arena;
        const format = try pixelFormat(d.format);
        const td = msg(Id, objc.class("MTLTextureDescriptor"), "texture2DDescriptorWithPixelFormat:width:height:mipmapped:", .{ format, @as(U, d.size.width), @as(U, d.size.height), @as(objc.BOOL, d.mip_level_count > 1) });
        var usage: U = 0;
        if (d.usage.texture_binding) usage |= 1;
        if (d.usage.storage_binding) usage |= 1 | 2;
        if (d.usage.render_attachment) usage |= 4;
        msg(void, td, "setUsage:", .{usage});
        msg(void, td, "setStorageMode:", .{@as(U, 2)}); // private: the GPU's alone
        if (d.sample_count > 1) {
            msg(void, td, "setTextureType:", .{@as(U, 4)}); // MTLTextureType2DMultisample
            msg(void, td, "setSampleCount:", .{@as(U, d.sample_count)});
        }
        const t = msg(?Id, device.device, "newTextureWithDescriptor:", .{td}) orelse return error.ResourceFailed;
        return .{ .texture = t, .format = d.format, .width = d.size.width, .height = d.size.height, .samples = d.sample_count };
    }

    pub fn destroyTexture(_: Device, t: Texture) void {
        objc.release(t.texture);
    }

    pub fn createSampler(device: Device, d: SamplerDescriptor) Error!Sampler {
        const sd = msg(Id, objc.class("MTLSamplerDescriptor"), "new", .{});
        defer objc.release(sd);
        msg(void, sd, "setMinFilter:", .{@as(U, @intFromBool(d.min_filter == .linear))});
        msg(void, sd, "setMagFilter:", .{@as(U, @intFromBool(d.mag_filter == .linear))});
        msg(void, sd, "setMipFilter:", .{@as(U, if (d.mipmap_filter == .linear) 2 else 1)});
        msg(void, sd, "setSAddressMode:", .{addressMode(d.address_mode_u)});
        msg(void, sd, "setTAddressMode:", .{addressMode(d.address_mode_v)});
        msg(void, sd, "setRAddressMode:", .{addressMode(d.address_mode_w)});
        msg(void, sd, "setLodMinClamp:", .{d.lod_min_clamp});
        msg(void, sd, "setLodMaxClamp:", .{d.lod_max_clamp});
        if (d.compare) |f| msg(void, sd, "setCompareFunction:", .{@as(U, @backingInt(f))}); // same order as WebGPU
        const s = msg(?Id, device.device, "newSamplerStateWithDescriptor:", .{sd}) orelse return error.ResourceFailed;
        return .{ .sampler = s };
    }

    pub fn destroySampler(_: Device, s: Sampler) void {
        objc.release(s.sampler);
    }

    pub fn createRenderPipeline(device: Device, comptime S: type, d: RenderPipelineDescriptor) Error!RenderPipeline(S) {
        const pool = objc.Pool.push();
        defer pool.pop();
        const library = try compile(device.device, S.msl);
        defer objc.release(library);
        const frag = d.fragment orelse desc.FragmentState{ .targets = &.{} };
        const vs = try function(library, d.vertex.entry_point);
        defer objc.release(vs);
        const pd = msg(Id, objc.class("MTLRenderPipelineDescriptor"), "new", .{});
        defer objc.release(pd);
        msg(void, pd, "setVertexFunction:", .{vs});
        if (d.fragment != null) {
            const fs = try function(library, frag.entry_point);
            defer objc.release(fs);
            msg(void, pd, "setFragmentFunction:", .{fs});
        }
        msg(void, pd, "setRasterSampleCount:", .{@as(U, d.multisample.count)});
        msg(void, pd, "setAlphaToCoverageEnabled:", .{@as(objc.BOOL, d.multisample.alpha_to_coverage_enabled)});
        const vd = msg(Id, objc.class("MTLVertexDescriptor"), "vertexDescriptor", .{});
        const attributes = msg(Id, vd, "attributes", .{});
        const layouts = msg(Id, vd, "layouts", .{});
        for (d.vertex.buffers, 0..) |vb, slot| {
            const index: U = naga.mslVertexBuffer(@intCast(slot));
            for (vb.attributes) |a| {
                const at = msg(Id, attributes, "objectAtIndexedSubscript:", .{@as(U, a.shader_location)});
                msg(void, at, "setFormat:", .{vertexFormat(a.format)});
                msg(void, at, "setOffset:", .{@as(U, a.offset)});
                msg(void, at, "setBufferIndex:", .{index});
            }
            const layout = msg(Id, layouts, "objectAtIndexedSubscript:", .{index});
            msg(void, layout, "setStride:", .{@as(U, vb.array_stride)});
            msg(void, layout, "setStepFunction:", .{@as(U, if (vb.step_mode == .instance) 2 else 1)});
            msg(void, layout, "setStepRate:", .{@as(U, 1)});
        }
        msg(void, pd, "setVertexDescriptor:", .{vd});
        const colors = msg(Id, pd, "colorAttachments", .{});
        for (frag.targets, 0..) |t, i| {
            const color = msg(Id, colors, "objectAtIndexedSubscript:", .{@as(U, i)});
            msg(void, color, "setPixelFormat:", .{try pixelFormat(t.format)});
            const m = t.write_mask;
            msg(void, color, "setWriteMask:", .{@as(U, @intFromBool(m.alpha)) | (@as(U, @intFromBool(m.blue)) << 1) | (@as(U, @intFromBool(m.green)) << 2) | (@as(U, @intFromBool(m.red)) << 3)});
            if (t.blend) |b| {
                msg(void, color, "setBlendingEnabled:", .{@as(objc.BOOL, true)});
                msg(void, color, "setSourceRGBBlendFactor:", .{blendFactor(b.color.src_factor)});
                msg(void, color, "setDestinationRGBBlendFactor:", .{blendFactor(b.color.dst_factor)});
                msg(void, color, "setRgbBlendOperation:", .{@as(U, @backingInt(b.color.operation))}); // same order as WebGPU
                msg(void, color, "setSourceAlphaBlendFactor:", .{blendFactor(b.alpha.src_factor)});
                msg(void, color, "setDestinationAlphaBlendFactor:", .{blendFactor(b.alpha.dst_factor)});
                msg(void, color, "setAlphaBlendOperation:", .{@as(U, @backingInt(b.alpha.operation))});
            }
        }
        var err: ?Id = null;
        const state = msg(?Id, device.device, "newRenderPipelineStateWithDescriptor:error:", .{ pd, &err }) orelse {
            std.log.err("lcgf_render.gpu (Metal): creating a pipeline: {s}", .{errorText(err)});
            return error.PipelineFailed;
        };
        return .{
            .state = state,
            .primitive = primitiveType(d.primitive.topology),
            .cull = @backingInt(d.primitive.cull_mode),
            .winding = @intFromBool(d.primitive.front_face == .ccw), // MTLWindingCounterClockwise = 1
        };
    }

    pub fn destroyRenderPipeline(_: Device, p: anytype) void {
        objc.release(p.state);
    }

    pub fn createComputePipeline(device: Device, comptime S: type, d: ComputePipelineDescriptor) Error!ComputePipeline(S) {
        const pool = objc.Pool.push();
        defer pool.pop();
        const library = try compile(device.device, S.msl);
        defer objc.release(library);
        const cs = try function(library, d.entry_point);
        defer objc.release(cs);
        var err: ?Id = null;
        const state = msg(?Id, device.device, "newComputePipelineStateWithFunction:error:", .{ cs, &err }) orelse {
            std.log.err("lcgf_render.gpu (Metal): creating a compute pipeline: {s}", .{errorText(err)});
            return error.PipelineFailed;
        };
        const size = S.module.entryPoint(comptime computeEntry(S.module)).workgroup_size;
        return .{ .state = state, .threads = .{ size[0], size[1], size[2] } };
    }

    pub const destroyComputePipeline = destroyRenderPipeline;

    pub fn createBindGroup(device: Device, arena: *Arena, pipeline: anytype, comptime g: u32, entries: Deref(@TypeOf(pipeline)).Shader.Group(g)) Error!BindGroup(Deref(@TypeOf(pipeline)).Shader, g) {
        _ = device;
        _ = arena;
        const S = Deref(@TypeOf(pipeline)).Shader;
        var bg: BindGroup(S, g) = undefined;
        inline for (comptime S.module.group(g), 0..) |b, i| {
            const v = @field(entries, b.name);
            bg.objects[i] = switch (comptime b.kind) {
                .uniform, .storage_read, .storage_read_write => v.buffer,
                .texture, .storage_texture => v.texture,
                .sampler, .comparison_sampler => v.sampler,
            };
            bg.sizes[i] = if (comptime b.kind.isBuffer()) v.size else 0;
        }
        return bg;
    }
};

pub const Arena = struct {
    kind: Kind,
    pub const Kind = enum { device, host };
    pub const Options = struct { bytes: u64, memory: Kind = .device, bind_groups: u32 = 64 };
    pub fn init(_: Device, o: Options) Error!Arena {
        return .{ .kind = o.memory };
    }
    pub fn deinit(_: *Arena) void {}
    pub fn reset(_: *Arena) void {}
};

/// A shared buffer the frame's writes copy from, on the queue. One per frame in flight;
/// `rewind` it when that frame's previous use has completed.
pub const Staging = struct {
    buffer: Buffer,
    used: u64 = 0,

    pub fn init(device: Device, arena: *Arena, bytes: u64) Error!Staging {
        if (arena.kind != .host) return error.IncompatibleMemory;
        return .{ .buffer = try device.createBuffer(arena, .{ .size = bytes, .usage = .{ .copy_src = true } }) };
    }
    pub fn deinit(s: Staging, device: Device) void {
        device.destroyBuffer(s.buffer);
    }
    pub fn rewind(s: *Staging) void {
        s.used = 0;
    }
    fn push(s: *Staging, bytes: []const u8, alignment: u64) Error!u64 {
        const at = std.mem.alignForward(u64, s.used, alignment);
        if (at + bytes.len > s.buffer.size) return error.OutOfArena;
        @memcpy(s.buffer.mapped.?[@intCast(at)..][0..bytes.len], bytes);
        s.used = at + bytes.len;
        return at;
    }
};

// ---------------------------------------------------------------------------------------------
// Objects

pub const Buffer = struct {
    buffer: Id,
    size: u64,
    /// Set in a `.host` arena (shared storage).
    mapped: ?[*]u8,
};

pub const Texture = struct {
    texture: Id,
    format: TextureFormat,
    width: u32,
    height: u32,
    samples: u32,

    pub fn createView(t: Texture) TextureView {
        return .{ .texture = t.texture, .width = t.width, .height = t.height, .samples = t.samples, .format = t.format };
    }
};

pub const TextureView = struct {
    texture: Id,
    width: u32,
    height: u32,
    samples: u32 = 1,
    format: TextureFormat = .rgba8_unorm,
};

pub const Sampler = struct { sampler: Id };

/// A shader: `source` is a namespace with `wgsl` and naga's MSL of it (`msl`), as
/// `addGpuShaders` makes for metal. Its resources get their slots here.
pub fn Shader(comptime source: type) type {
    if (!@hasDecl(source, "msl")) @compileError("shader has no MSL: build it with addGpuShaders for the metal back end");
    return struct {
        pub const module = reflect.parse(source.wgsl);
        pub const msl: [:0]const u8 = naga.msl(module, source.msl);
        pub fn Group(comptime g: u32) type {
            return module.Group(g, Buffer, TextureView, Sampler);
        }
    };
}

pub fn RenderPipeline(comptime S: type) type {
    return struct {
        state: Id,
        primitive: U,
        cull: U,
        winding: U,
        pub const Shader = S;
    };
}

pub fn ComputePipeline(comptime S: type) type {
    return struct {
        state: Id,
        threads: [3]u32,
        pub const Shader = S;
    };
}

/// The Metal objects of a group's bindings, in binding order, and its buffers' sizes.
pub fn BindGroup(comptime S: type, comptime g: u32) type {
    const n = S.module.group(g).len;
    return struct {
        objects: [n]Id,
        sizes: [n]u64,
        pub const Shader = S;
        pub const index = g;
    };
}

// ---------------------------------------------------------------------------------------------
// Frame phases

/// The write phase: a blit encoder on the host's command buffer, copying from the device's
/// staging ring. Made on the first write; `finish` ends it.
pub const Upload = struct {
    cmd: Id,
    staging: *Staging,
    blit: ?Id = null,

    pub fn begin(device: Device, cmd: Id) Upload {
        return .{ .cmd = cmd, .staging = device.staging.? };
    }

    pub fn beginStaged(_: Device, cmd: Id, staging: *Staging) Upload {
        return .{ .cmd = cmd, .staging = staging };
    }

    fn encoder(up: *Upload) Id {
        if (up.blit == null) up.blit = msg(Id, up.cmd, "blitCommandEncoder", .{});
        return up.blit.?;
    }

    pub fn writeBuffer(up: *Upload, buffer: Buffer, offset: u64, bytes: []const u8) void {
        if (debug_checks) std.debug.assert(offset % 4 == 0 and bytes.len % 4 == 0 and offset + bytes.len <= buffer.size);
        const at = up.staging.push(bytes, 4) catch @panic("lcgf_render.gpu: the staging ring is full");
        msg(void, up.encoder(), "copyFromBuffer:sourceOffset:toBuffer:destinationOffset:size:", .{ up.staging.buffer.buffer, @as(U, at), buffer.buffer, @as(U, offset), @as(U, bytes.len) });
    }

    pub fn writeTexture(up: *Upload, t: Texture, bytes: []const u8, bytes_per_row: u32) Error!void {
        const at = try up.staging.push(bytes, 256);
        msg(void, up.encoder(), "copyFromBuffer:sourceOffset:sourceBytesPerRow:sourceBytesPerImage:sourceSize:toTexture:destinationSlice:destinationLevel:destinationOrigin:", .{
            up.staging.buffer.buffer,                                    @as(U, at), @as(U, bytes_per_row), @as(U, bytes.len),
            MTLSize{ .width = t.width, .height = t.height, .depth = 1 }, t.texture,  @as(U, 0),             @as(U, 0),
            MTLOrigin{},
        });
    }

    pub fn prepare(_: *Upload, _: Texture) void {}

    pub fn finish(up: *Upload) Encoder {
        if (up.blit) |b| msg(void, b, "endEncoding", .{});
        return .{ .cmd = up.cmd };
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
    cmd: Id,

    pub fn beginRenderPass(e: Encoder, d: RenderPassDescriptor) RenderPass {
        const rp = msg(Id, objc.class("MTLRenderPassDescriptor"), "renderPassDescriptor", .{});
        const colors = msg(Id, rp, "colorAttachments", .{});
        var p: RenderPass = .{ .encoder = undefined, .width = 0, .height = 0, .owned = true };
        for (d.color_attachments, 0..) |a, i| {
            const color = msg(Id, colors, "objectAtIndexedSubscript:", .{@as(U, i)});
            msg(void, color, "setTexture:", .{a.view.texture});
            msg(void, color, "setLoadAction:", .{@as(U, if (a.load_op == .clear) 2 else 1)});
            const store: U = if (a.resolve_target != null) (if (a.store_op == .store) 3 else 2) else @intFromBool(a.store_op == .store);
            msg(void, color, "setStoreAction:", .{store});
            if (a.resolve_target) |r| msg(void, color, "setResolveTexture:", .{r.texture});
            const cv = a.clear_value;
            msg(void, color, "setClearColor:", .{MTLClearColor{ .r = cv.r, .g = cv.g, .b = cv.b, .a = cv.a }});
            p.width = a.view.width;
            p.height = a.view.height;
        }
        p.encoder = msg(Id, e.cmd, "renderCommandEncoderWithDescriptor:", .{rp});
        return p;
    }

    pub fn beginComputePass(e: Encoder) ComputePass {
        return .{ .encoder = msg(Id, e.cmd, "computeCommandEncoder", .{}) };
    }
};

pub const RenderPass = struct {
    encoder: Id,
    width: u32,
    height: u32,
    owned: bool = false,
    primitive: U = 3,
    index: ?struct { buffer: Id, type: U, offset: u64, size: u64 } = null,
    sizes: [max_sized]u32 = @splat(0),
    sized: u32 = 0,
    sizes_slot: U = 0,
    debug: if (debug_checks) struct { pipeline: bool = false } else void = if (debug_checks) .{} else {},

    /// The pass the host is encoding (the UI's, for an inline custom draw).
    pub fn wrap(_: Device, encoder: Id, width: u32, height: u32) RenderPass {
        return .{ .encoder = encoder, .width = width, .height = height };
    }

    pub fn setPipeline(p: *RenderPass, pipeline: anytype) void {
        if (debug_checks) p.debug.pipeline = true;
        msg(void, p.encoder, "setRenderPipelineState:", .{pipeline.state});
        msg(void, p.encoder, "setCullMode:", .{pipeline.cull});
        msg(void, p.encoder, "setFrontFacingWinding:", .{pipeline.winding});
        msg(void, p.encoder, "setTriangleFillMode:", .{@as(U, 0)});
        p.primitive = pipeline.primitive;
        const m = Deref(@TypeOf(pipeline)).Shader.module;
        p.sized = comptime naga.mslSized(m).len;
        p.sizes_slot = comptime naga.mslSizesSlot(m);
    }

    pub fn setBindGroup(p: *RenderPass, comptime index: u32, group: anytype) void {
        const G = Deref(@TypeOf(group));
        comptime checkIndex(G, index);
        const m = G.Shader.module;
        const table = comptime naga.mslSlots(m);
        inline for (comptime m.group(index), 0..) |b, i| {
            const slot: U = comptime naga.slotOf(table, index, b.binding);
            switch (comptime b.kind) {
                .uniform, .storage_read, .storage_read_write => {
                    msg(void, p.encoder, "setVertexBuffer:offset:atIndex:", .{ group.objects[i], @as(U, 0), slot });
                    msg(void, p.encoder, "setFragmentBuffer:offset:atIndex:", .{ group.objects[i], @as(U, 0), slot });
                },
                .texture, .storage_texture => {
                    msg(void, p.encoder, "setVertexTexture:atIndex:", .{ group.objects[i], slot });
                    msg(void, p.encoder, "setFragmentTexture:atIndex:", .{ group.objects[i], slot });
                },
                .sampler, .comparison_sampler => {
                    msg(void, p.encoder, "setVertexSamplerState:atIndex:", .{ group.objects[i], slot });
                    msg(void, p.encoder, "setFragmentSamplerState:atIndex:", .{ group.objects[i], slot });
                },
            }
            inline for (comptime naga.mslSized(m), 0..) |s, k| if (comptime s.group == index and s.binding == b.binding) {
                p.sizes[k] = @intCast(group.sizes[i]);
            };
        }
    }

    /// The lengths of the bound runtime-sized arrays, for naga's `_buffer_sizes`.
    fn pushSizes(p: *RenderPass) void {
        if (p.sized == 0) return;
        const bytes = std.mem.sliceAsBytes(p.sizes[0..p.sized]);
        msg(void, p.encoder, "setVertexBytes:length:atIndex:", .{ bytes.ptr, @as(U, bytes.len), p.sizes_slot });
        msg(void, p.encoder, "setFragmentBytes:length:atIndex:", .{ bytes.ptr, @as(U, bytes.len), p.sizes_slot });
    }

    pub fn setVertexBuffer(p: *RenderPass, slot: u32, buffer: Buffer, offset: u64) void {
        msg(void, p.encoder, "setVertexBuffer:offset:atIndex:", .{ buffer.buffer, @as(U, offset), @as(U, naga.mslVertexBuffer(slot)) });
    }

    pub fn setIndexBuffer(p: *RenderPass, buffer: Buffer, format: IndexFormat, offset: u64) void {
        p.index = .{ .buffer = buffer.buffer, .type = @intFromBool(format == .uint32), .offset = offset, .size = if (format == .uint16) 2 else 4 };
    }

    pub fn setViewport(p: *RenderPass, x: f32, y: f32, w: f32, h: f32, min_depth: f32, max_depth: f32) void {
        msg(void, p.encoder, "setViewport:", .{MTLViewport{ .x = x, .y = y, .width = w, .height = h, .znear = min_depth, .zfar = max_depth }});
    }

    pub fn setScissorRect(p: *RenderPass, x: u32, y: u32, w: u32, h: u32) void {
        if (debug_checks) std.debug.assert(x + w <= p.width and y + h <= p.height);
        msg(void, p.encoder, "setScissorRect:", .{MTLScissorRect{ .x = x, .y = y, .width = w, .height = h }});
    }

    pub fn setBlendConstant(p: *RenderPass, color: Color) void {
        msg(void, p.encoder, "setBlendColorRed:green:blue:alpha:", .{ @as(f32, @floatCast(color.r)), @as(f32, @floatCast(color.g)), @as(f32, @floatCast(color.b)), @as(f32, @floatCast(color.a)) });
    }

    pub fn draw(p: *RenderPass, vertex_count: u32, instance_count: u32, first_vertex: u32, first_instance: u32) void {
        if (debug_checks) std.debug.assert(p.debug.pipeline);
        p.pushSizes();
        msg(void, p.encoder, "drawPrimitives:vertexStart:vertexCount:instanceCount:baseInstance:", .{ p.primitive, @as(U, first_vertex), @as(U, vertex_count), @as(U, instance_count), @as(U, first_instance) });
    }

    pub fn drawIndexed(p: *RenderPass, index_count: u32, instance_count: u32, first_index: u32, base_vertex: i32, first_instance: u32) void {
        if (debug_checks) std.debug.assert(p.debug.pipeline);
        const ib = p.index.?;
        p.pushSizes();
        msg(void, p.encoder, "drawIndexedPrimitives:indexCount:indexType:indexBuffer:indexBufferOffset:instanceCount:baseVertex:baseInstance:", .{
            p.primitive, @as(U, index_count), ib.type, ib.buffer, @as(U, ib.offset + first_index * ib.size), @as(U, instance_count), @as(objc.NSInteger, base_vertex), @as(U, first_instance),
        });
    }

    /// Ends an encoder the projection began. A wrapped pass is the host's.
    pub fn end(p: *RenderPass) void {
        if (!p.owned) return;
        msg(void, p.encoder, "endEncoding", .{});
        p.owned = false;
    }
};

pub const ComputePass = struct {
    encoder: Id,
    threads: [3]u32 = .{ 1, 1, 1 },
    sizes: [max_sized]u32 = @splat(0),
    sized: u32 = 0,
    sizes_slot: U = 0,

    pub fn setPipeline(p: *ComputePass, pipeline: anytype) void {
        const m = Deref(@TypeOf(pipeline)).Shader.module;
        msg(void, p.encoder, "setComputePipelineState:", .{pipeline.state});
        p.threads = pipeline.threads;
        p.sized = comptime naga.mslSized(m).len;
        p.sizes_slot = comptime naga.mslSizesSlot(m);
    }

    pub fn setBindGroup(p: *ComputePass, comptime index: u32, group: anytype) void {
        const G = Deref(@TypeOf(group));
        comptime checkIndex(G, index);
        const m = G.Shader.module;
        const table = comptime naga.mslSlots(m);
        inline for (comptime m.group(index), 0..) |b, i| {
            const slot: U = comptime naga.slotOf(table, index, b.binding);
            switch (comptime b.kind) {
                .uniform, .storage_read, .storage_read_write => msg(void, p.encoder, "setBuffer:offset:atIndex:", .{ group.objects[i], @as(U, 0), slot }),
                .texture, .storage_texture => msg(void, p.encoder, "setTexture:atIndex:", .{ group.objects[i], slot }),
                .sampler, .comparison_sampler => msg(void, p.encoder, "setSamplerState:atIndex:", .{ group.objects[i], slot }),
            }
            inline for (comptime naga.mslSized(m), 0..) |s, k| if (comptime s.group == index and s.binding == b.binding) {
                p.sizes[k] = @intCast(group.sizes[i]);
            };
        }
    }

    pub fn dispatchWorkgroups(p: *ComputePass, x: u32, y: u32, z: u32) void {
        if (p.sized > 0) {
            const bytes = std.mem.sliceAsBytes(p.sizes[0..p.sized]);
            msg(void, p.encoder, "setBytes:length:atIndex:", .{ bytes.ptr, @as(U, bytes.len), p.sizes_slot });
        }
        msg(void, p.encoder, "dispatchThreadgroups:threadsPerThreadgroup:", .{ MTLSize{ .width = x, .height = y, .depth = z }, MTLSize{ .width = p.threads[0], .height = p.threads[1], .depth = p.threads[2] } });
    }

    pub fn end(p: *ComputePass) void {
        msg(void, p.encoder, "endEncoding", .{});
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

fn computeEntry(comptime m: reflect.Module) []const u8 {
    for (m.entry_points) |e| if (e.stage == .compute) return e.name;
    @compileError("the shader has no compute entry point");
}

// ---------------------------------------------------------------------------------------------
// Conversions

fn compile(device: Id, source: [:0]const u8) Error!Id {
    var err: ?Id = null;
    return msg(?Id, device, "newLibraryWithSource:options:error:", .{ objc.string(source), @as(?Id, null), &err }) orelse {
        std.log.warn("lcgf_render.gpu (Metal): compiling MSL: {s}", .{errorText(err)});
        return error.ShaderCompile;
    };
}

/// An entry point by its WGSL name, or by naga's rename of it (`main` is `main_` in MSL).
fn function(library: Id, name: [:0]const u8) Error!Id {
    if (msg(?Id, library, "newFunctionWithName:", .{objc.string(name)})) |f| return f;
    var buf: [128]u8 = undefined;
    if (name.len + 2 > buf.len) return error.MissingEntryPoint;
    @memcpy(buf[0..name.len], name);
    buf[name.len] = '_';
    buf[name.len + 1] = 0;
    return msg(?Id, library, "newFunctionWithName:", .{objc.string(buf[0 .. name.len + 1 :0])}) orelse error.MissingEntryPoint;
}

fn errorText(err: ?Id) [*:0]const u8 {
    return if (err) |e| msg([*:0]const u8, msg(Id, e, "localizedDescription", .{}), "UTF8String", .{}) else "no error object";
}

pub fn pixelFormat(f: TextureFormat) Error!U {
    return switch (f) {
        .r8_unorm => 10,
        .rg8_unorm => 30,
        .rgba8_unorm => 70,
        .rgba8_unorm_srgb => 71,
        .bgra8_unorm => 80,
        .bgra8_unorm_srgb => 81,
        .r16_float => 25,
        .rgba16_float => 115,
        .r32_float => 55,
        .rg32_float => 105,
        .rgba32_float => 125,
        .r32_uint => 53,
        .depth32_float => 252,
    };
}

fn vertexFormat(f: VertexFormat) U {
    return switch (f) {
        .float32 => 28,
        .float32x2 => 29,
        .float32x3 => 30,
        .float32x4 => 31,
        .uint32 => 36,
        .uint32x2 => 37,
        .uint32x4 => 39,
        .sint32 => 32,
        .sint32x2 => 33,
        .sint32x4 => 35,
        .unorm8x4 => 9,
    };
}

fn primitiveType(t: PrimitiveTopology) U {
    return switch (t) {
        .point_list => 0,
        .line_list => 1,
        .line_strip => 2,
        .triangle_list => 3,
        .triangle_strip => 4,
    };
}

fn addressMode(a: desc.AddressMode) U {
    return switch (a) {
        .clamp_to_edge => 0,
        .repeat => 2,
        .mirror_repeat => 3,
    };
}

fn blendFactor(f: desc.BlendFactor) U {
    return switch (f) {
        .zero => 0,
        .one => 1,
        .src => 2,
        .one_minus_src => 3,
        .src_alpha => 4,
        .one_minus_src_alpha => 5,
        .dst => 6,
        .one_minus_dst => 7,
        .dst_alpha => 8,
        .one_minus_dst_alpha => 9,
        .constant => 11,
        .one_minus_constant => 12,
    };
}

const testing = std.testing;
const shaders = @import("gpu_shaders");
const device_mod = @import("device.zig");

test "gpu: naga's MSL gets every resource slot at compile time" {
    const T = Shader(shaders.textured);
    try testing.expect(std.mem.indexOf(u8, T.msl, "fake") == null);
    try testing.expect(std.mem.indexOf(u8, T.msl, "params [[buffer(0)]]") != null);
    try testing.expect(std.mem.indexOf(u8, T.msl, "tex [[texture(0)]]") != null);
    try testing.expect(std.mem.indexOf(u8, T.msl, "smp [[sampler(0)]]") != null);
    const F = Shader(shaders.fill);
    try testing.expect(std.mem.indexOf(u8, F.msl, "_buffer_sizes [[buffer(2)]]") != null);
    const G = Shader(shaders.gradient);
    try testing.expect(std.mem.indexOf(u8, G.msl, "screen [[buffer(0)]]") != null);
}

/// The host side of lcgf.gpu_check on Metal: one command buffer per submission, readback
/// through a blit into shared memory (the projection's device textures and buffers are private).
const Check = struct {
    dev: Device,
    queue: Id,
    cmd: ?Id = null,

    pub fn upload(k: *Check, staging: *Staging) !Upload {
        k.cmd = msg(Id, k.queue, "commandBuffer", .{});
        return .beginStaged(k.dev, k.cmd.?, staging);
    }
    pub fn submit(k: *Check) !void {
        msg(void, k.cmd.?, "commit", .{});
        msg(void, k.cmd.?, "waitUntilCompleted", .{});
        k.cmd = null;
    }
    /// Copies into a shared buffer with `copy(blit, shared, what)`, then into `out`.
    fn readback(k: *Check, out: []u8, what: anytype, comptime copy: fn (Id, Id, @TypeOf(what), usize) void) void {
        const shared = msg(Id, k.dev.device, "newBufferWithLength:options:", .{ @as(U, out.len), storage_shared });
        defer objc.release(shared);
        const cmd = msg(Id, k.queue, "commandBuffer", .{});
        const blit = msg(Id, cmd, "blitCommandEncoder", .{});
        copy(blit, shared, what, out.len);
        msg(void, blit, "endEncoding", .{});
        msg(void, cmd, "commit", .{});
        msg(void, cmd, "waitUntilCompleted", .{});
        @memcpy(out, msg([*]u8, shared, "contents", .{})[0..out.len]);
    }
    fn copyTexture(blit: Id, to: Id, t: Texture, _: usize) void {
        msg(void, blit, "copyFromTexture:sourceSlice:sourceLevel:sourceOrigin:sourceSize:toBuffer:destinationOffset:destinationBytesPerRow:destinationBytesPerImage:", .{
            t.texture, @as(U, 0), @as(U, 0), MTLOrigin{}, MTLSize{ .width = t.width, .height = t.height, .depth = 1 }, to, @as(U, 0), @as(U, t.width * 4), @as(U, t.width * t.height * 4),
        });
    }
    fn copyBuffer(blit: Id, to: Id, b: Buffer, len: usize) void {
        msg(void, blit, "copyFromBuffer:sourceOffset:toBuffer:destinationOffset:size:", .{ b.buffer, @as(U, 0), to, @as(U, 0), @as(U, len) });
    }
    pub fn readTexture(k: *Check, t: Texture, out: []u8) !void {
        k.readback(out, t, copyTexture);
    }
    pub fn readBuffer(k: *Check, b: Buffer, out: []u8) !void {
        k.readback(out, b, copyBuffer);
    }
};

test "gpu: upload, render to a texture, sample it in a second pass, on a real device" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    try objc.load();
    const pool = objc.Pool.push();
    defer pool.pop();
    var d = try device_mod.Device.init();
    defer d.deinit();
    var k: Check = .{ .dev = .wrap(d.device), .queue = d.queue };
    try lcgf.gpu_check.renderToTexture(@This(), shaders, k.dev, &k);
}

test "gpu: a compute pass writes a storage buffer the host reads" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    try objc.load();
    const pool = objc.Pool.push();
    defer pool.pop();
    var d = try device_mod.Device.init();
    defer d.deinit();
    var k: Check = .{ .dev = .wrap(d.device), .queue = d.queue };
    try lcgf.gpu_check.compute(@This(), shaders, k.dev, &k);
}
