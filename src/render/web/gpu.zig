//! `lcgf_render.gpu` in the browser: the identity projection onto the page's WebGPU. Every
//! object is a `u32` handle into lcgf.js's table (`ui.gpu`), every call one WebGPU call in JS
//! (lcgf.js `gpuProjection`). Descriptors cross as a few `u32` words, decoded by name tables that
//! follow the order of this file's enums (src/render/gpu/desc.zig). WGSL goes to the browser as
//! written; bind group layouts are the pipeline's own ("auto"), so `createBindGroup` takes the
//! pipeline. Writes go through the queue, as in WebGPU, so `Upload` is the projection's shape over
//! `GPUQueue.writeBuffer`. wasm32-freestanding only.

const std = @import("std");
const lcgf = @import("lcgf");
const desc = lcgf.gpu_desc;
const reflect = lcgf.gpu_reflect;

pub const Error = error{ OutOfArena, IncompatibleMemory, UnsupportedFormat, PipelineFailed };

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

pub const native = .web;
// No debug checks of its own: the browser's WebGPU validates every call.

pub const max_groups = 4;
pub const max_color_targets = 4;
pub const max_vertex_buffers = 8;
pub const max_vertex_attributes = 16;

const js = struct {
    extern "lcgf" fn gpu_release(handle: u32) void;
    extern "lcgf" fn gpu_write_buffer(queue: u32, buffer: u32, offset: u32, ptr: [*]const u8, len: usize) void;
    extern "lcgf" fn gpu_set_pipeline(pass: u32, pipeline: u32) void;
    extern "lcgf" fn gpu_set_bind_group(pass: u32, index: u32, group: u32) void;
    extern "lcgf" fn gpu_set_vertex_buffer(pass: u32, slot: u32, buffer: u32, offset: u32, size: u32) void;
    extern "lcgf" fn gpu_draw(pass: u32, vertices: u32, instances: u32, first_vertex: u32, first_instance: u32) void;
    extern "lcgf" fn gpup_create_buffer(device: u32, size: u32, usage: u32) u32;
    extern "lcgf" fn gpup_create_texture(device: u32, width: u32, height: u32, layers: u32, format: u32, usage: u32, mips: u32, samples: u32) u32;
    extern "lcgf" fn gpup_create_view(texture: u32) u32;
    extern "lcgf" fn gpup_create_sampler(device: u32, words: [*]const u32) u32;
    extern "lcgf" fn gpup_create_render_pipeline(device: u32, wgsl: [*]const u8, wgsl_len: usize, words: [*]const u32, words_len: usize) u32;
    extern "lcgf" fn gpup_create_compute_pipeline(device: u32, wgsl: [*]const u8, wgsl_len: usize, entry: [*]const u8, entry_len: usize) u32;
    extern "lcgf" fn gpup_create_bind_group(device: u32, pipeline: u32, group: u32, words: [*]const u32, count: usize) u32;
    extern "lcgf" fn gpup_write_texture(queue: u32, texture: u32, ptr: [*]const u8, len: usize, bytes_per_row: u32, width: u32, height: u32) void;
    extern "lcgf" fn gpup_begin_render_pass(encoder: u32, words: [*]const u32, count: usize) u32;
    extern "lcgf" fn gpup_end_pass(pass: u32) void;
    extern "lcgf" fn gpup_set_index_buffer(pass: u32, buffer: u32, format: u32, offset: u32) void;
    extern "lcgf" fn gpup_set_viewport(pass: u32, x: f32, y: f32, w: f32, h: f32, min_depth: f32, max_depth: f32) void;
    extern "lcgf" fn gpup_set_scissor(pass: u32, x: u32, y: u32, w: u32, h: u32) void;
    extern "lcgf" fn gpup_set_blend_constant(pass: u32, r: f64, g: f64, b: f64, a: f64) void;
    extern "lcgf" fn gpup_draw_indexed(pass: u32, count: u32, instances: u32, first: u32, base: i32, first_instance: u32) void;
    extern "lcgf" fn gpup_begin_compute_pass(encoder: u32) u32;
    extern "lcgf" fn gpup_dispatch(pass: u32, x: u32, y: u32, z: u32) void;
};

// ---------------------------------------------------------------------------------------------
// Device and memory

pub const Device = struct {
    device: u32,
    queue: u32,

    pub fn wrap(device: u32, queue: u32) Device {
        return .{ .device = device, .queue = queue };
    }

    pub fn createBuffer(device: Device, arena: *Arena, d: BufferDescriptor) Error!Buffer {
        _ = arena;
        return .{ .buffer = js.gpup_create_buffer(device.device, @intCast(d.size), @bitCast(d.usage)), .size = d.size, .mapped = null };
    }

    pub fn destroyBuffer(_: Device, b: Buffer) void {
        js.gpu_release(b.buffer);
    }

    pub fn createTexture(device: Device, arena: *Arena, d: TextureDescriptor) Error!Texture {
        _ = arena;
        const t = js.gpup_create_texture(device.device, d.size.width, d.size.height, d.size.depth_or_array_layers, @backingInt(d.format), @bitCast(d.usage), d.mip_level_count, d.sample_count);
        return .{ .texture = t, .view = js.gpup_create_view(t), .format = d.format, .width = d.size.width, .height = d.size.height, .samples = d.sample_count };
    }

    pub fn destroyTexture(_: Device, t: Texture) void {
        js.gpu_release(t.view);
        js.gpu_release(t.texture);
    }

    pub fn createSampler(device: Device, d: SamplerDescriptor) Error!Sampler {
        const words = [_]u32{
            @backingInt(d.address_mode_u), @backingInt(d.address_mode_v), @backingInt(d.address_mode_w),
            @backingInt(d.mag_filter),     @backingInt(d.min_filter),     @backingInt(d.mipmap_filter),
            @bitCast(d.lod_min_clamp),     @bitCast(d.lod_max_clamp),     if (d.compare) |f| 1 + @as(u32, @backingInt(f)) else 0,
        };
        return .{ .sampler = js.gpup_create_sampler(device.device, &words) };
    }

    pub fn destroySampler(_: Device, s: Sampler) void {
        js.gpu_release(s.sampler);
    }

    /// The descriptor as words lcgf.js `gpup_create_render_pipeline` reads, in this order:
    /// vertex entry (ptr, len), fragment entry (ptr, len; 0 when absent), topology, strip
    /// index format (0 none, 1 + IndexFormat), front face, cull mode, sample count, mask,
    /// alpha to coverage, buffer count, per buffer (stride, step mode, attribute count, per
    /// attribute (format, offset, location)), target count, per target (format, blended, colour
    /// operation, source, destination, alpha operation, source, destination, write mask).
    pub fn createRenderPipeline(device: Device, comptime S: type, d: RenderPipelineDescriptor) Error!RenderPipeline(S) {
        var w: [16 + max_vertex_buffers * 3 + max_vertex_attributes * 3 + 1 + max_color_targets * 9]u32 = undefined;
        var n: usize = 0;
        const frag = d.fragment orelse desc.FragmentState{ .entry_point = "", .targets = &.{} };
        const head = [_]u32{
            @intFromPtr(d.vertex.entry_point.ptr),                 @intCast(d.vertex.entry_point.len),
            @intFromPtr(frag.entry_point.ptr),                     @intCast(frag.entry_point.len),
            @backingInt(d.primitive.topology),                     if (d.primitive.strip_index_format) |f| 1 + @as(u32, @backingInt(f)) else 0,
            @backingInt(d.primitive.front_face),                   @backingInt(d.primitive.cull_mode),
            d.multisample.count,                                   d.multisample.mask,
            @intFromBool(d.multisample.alpha_to_coverage_enabled), @intCast(d.vertex.buffers.len),
        };
        @memcpy(w[0..head.len], &head);
        n = head.len;
        for (d.vertex.buffers) |vb| {
            w[n..][0..3].* = .{ @intCast(vb.array_stride), @backingInt(vb.step_mode), @intCast(vb.attributes.len) };
            n += 3;
            for (vb.attributes) |a| {
                w[n..][0..3].* = .{ @backingInt(a.format), @intCast(a.offset), a.shader_location };
                n += 3;
            }
        }
        w[n] = @intCast(frag.targets.len);
        n += 1;
        for (frag.targets) |t| {
            const b = t.blend orelse BlendState.premultiplied;
            w[n..][0..9].* = .{
                @backingInt(t.format),           @intFromBool(t.blend != null),
                @backingInt(b.color.operation),  @backingInt(b.color.src_factor),
                @backingInt(b.color.dst_factor), @backingInt(b.alpha.operation),
                @backingInt(b.alpha.src_factor), @backingInt(b.alpha.dst_factor),
                @as(u4, @bitCast(t.write_mask)),
            };
            n += 9;
        }
        const p = js.gpup_create_render_pipeline(device.device, S.wgsl.ptr, S.wgsl.len, &w, n);
        if (p == 0) return error.PipelineFailed;
        return .{ .pipeline = p };
    }

    pub fn destroyRenderPipeline(_: Device, p: anytype) void {
        js.gpu_release(if (@hasField(@TypeOf(p), "compute")) p.compute else p.pipeline);
    }

    pub fn createComputePipeline(device: Device, comptime S: type, d: ComputePipelineDescriptor) Error!ComputePipeline(S) {
        const p = js.gpup_create_compute_pipeline(device.device, S.wgsl.ptr, S.wgsl.len, d.entry_point.ptr, d.entry_point.len);
        if (p == 0) return error.PipelineFailed;
        return .{ .compute = p };
    }

    pub const destroyComputePipeline = destroyRenderPipeline;

    /// One (binding, kind, handle) triple per binding: kind 0 a buffer, 1 a texture view, 2 a
    /// sampler.
    pub fn createBindGroup(device: Device, arena: *Arena, pipeline: anytype, comptime g: u32, entries: Deref(@TypeOf(pipeline)).Shader.Group(g)) Error!BindGroup(Deref(@TypeOf(pipeline)).Shader, g) {
        _ = arena;
        const P = Deref(@TypeOf(pipeline));
        const bindings = comptime P.Shader.module.group(g);
        var words: [bindings.len * 3]u32 = undefined;
        inline for (bindings, 0..) |b, i| {
            const v = @field(entries, b.name);
            words[i * 3 ..][0..3].* = switch (comptime b.kind) {
                .uniform, .storage_read, .storage_read_write => .{ b.binding, 0, v.buffer },
                .texture, .storage_texture => .{ b.binding, 1, v.view },
                .sampler, .comparison_sampler => .{ b.binding, 2, v.sampler },
            };
        }
        const handle = if (@hasField(P, "compute")) pipeline.compute else pipeline.pipeline;
        return .{ .group = js.gpup_create_bind_group(device.device, handle, g, &words, bindings.len) };
    }
};

/// The browser allocates its own memory: an arena is only the projection's uniform interface.
pub const Arena = struct {
    pub const Kind = enum { device, host };
    pub const Options = struct { bytes: u64, memory: Kind = .device, bind_groups: u32 = 64 };
    pub fn init(_: Device, _: Options) Error!Arena {
        return .{};
    }
    pub fn deinit(_: *Arena) void {}
    pub fn reset(_: *Arena) void {}
};

pub const Staging = struct {
    pub fn init(_: Device, _: *Arena, _: u64) Error!Staging {
        return .{};
    }
    pub fn deinit(_: Staging, _: Device) void {}
    pub fn rewind(_: *Staging) void {}
};

// ---------------------------------------------------------------------------------------------
// Objects

pub const Buffer = struct { buffer: u32, size: u64, mapped: ?[*]u8 };

pub const Texture = struct {
    texture: u32,
    view: u32,
    format: TextureFormat,
    width: u32,
    height: u32,
    samples: u32,

    pub fn createView(t: Texture) TextureView {
        return .{ .view = t.view, .texture = t.texture, .width = t.width, .height = t.height, .samples = t.samples, .format = t.format };
    }
};

pub const TextureView = struct {
    view: u32,
    texture: u32 = 0,
    width: u32,
    height: u32,
    samples: u32 = 1,
    format: TextureFormat = .rgba8_unorm,
};

pub const Sampler = struct { sampler: u32 };

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
        pipeline: u32,
        pub const Shader = S;
    };
}

pub fn ComputePipeline(comptime S: type) type {
    return struct {
        compute: u32,
        pub const Shader = S;
    };
}

pub fn BindGroup(comptime S: type, comptime g: u32) type {
    return struct {
        group: u32,
        pub const Shader = S;
        pub const index = g;
    };
}

// ---------------------------------------------------------------------------------------------
// Frame phases

pub const Upload = struct {
    queue: u32,
    encoder: u32,

    pub fn begin(device: Device, encoder: u32) Upload {
        return .{ .queue = device.queue, .encoder = encoder };
    }
    pub fn beginStaged(device: Device, encoder: u32, _: *Staging) Upload {
        return begin(device, encoder);
    }
    pub fn writeBuffer(up: *Upload, buffer: Buffer, offset: u64, bytes: []const u8) void {
        js.gpu_write_buffer(up.queue, buffer.buffer, @intCast(offset), bytes.ptr, bytes.len);
    }
    pub fn writeTexture(up: *Upload, t: Texture, bytes: []const u8, bytes_per_row: u32) Error!void {
        js.gpup_write_texture(up.queue, t.texture, bytes.ptr, bytes.len, bytes_per_row, t.width, t.height);
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
    encoder: u32,

    /// Per attachment: view, resolve target (0 none), load op, store op, clear colour as four
    /// f32 bit patterns.
    pub fn beginRenderPass(e: Encoder, d: RenderPassDescriptor) RenderPass {
        var words: [max_color_targets * 8]u32 = undefined;
        var p: RenderPass = .{ .pass = 0, .width = 0, .height = 0, .owned = true };
        for (d.color_attachments, 0..) |a, i| {
            const cv = a.clear_value;
            words[i * 8 ..][0..8].* = .{
                a.view.view,                          if (a.resolve_target) |r| r.view else 0,
                @backingInt(a.load_op),               @backingInt(a.store_op),
                @bitCast(@as(f32, @floatCast(cv.r))), @bitCast(@as(f32, @floatCast(cv.g))),
                @bitCast(@as(f32, @floatCast(cv.b))), @bitCast(@as(f32, @floatCast(cv.a))),
            };
            p.width = a.view.width;
            p.height = a.view.height;
        }
        p.pass = js.gpup_begin_render_pass(e.encoder, &words, d.color_attachments.len);
        return p;
    }

    pub fn beginComputePass(e: Encoder) ComputePass {
        return .{ .pass = js.gpup_begin_compute_pass(e.encoder) };
    }
};

pub const RenderPass = struct {
    pass: u32,
    width: u32,
    height: u32,
    owned: bool = false,

    pub fn wrap(_: Device, pass: u32, width: u32, height: u32) RenderPass {
        return .{ .pass = pass, .width = width, .height = height };
    }
    pub fn setPipeline(p: *RenderPass, pipeline: anytype) void {
        js.gpu_set_pipeline(p.pass, pipeline.pipeline);
    }
    pub fn setBindGroup(p: *RenderPass, comptime index: u32, group: anytype) void {
        comptime checkIndex(Deref(@TypeOf(group)), index);
        js.gpu_set_bind_group(p.pass, index, group.group);
    }
    pub fn setVertexBuffer(p: *RenderPass, slot: u32, buffer: Buffer, offset: u64) void {
        js.gpu_set_vertex_buffer(p.pass, slot, buffer.buffer, @intCast(offset), @intCast(buffer.size - offset));
    }
    pub fn setIndexBuffer(p: *RenderPass, buffer: Buffer, format: IndexFormat, offset: u64) void {
        js.gpup_set_index_buffer(p.pass, buffer.buffer, @backingInt(format), @intCast(offset));
    }
    pub fn setViewport(p: *RenderPass, x: f32, y: f32, w: f32, h: f32, min_depth: f32, max_depth: f32) void {
        js.gpup_set_viewport(p.pass, x, y, w, h, min_depth, max_depth);
    }
    pub fn setScissorRect(p: *RenderPass, x: u32, y: u32, w: u32, h: u32) void {
        js.gpup_set_scissor(p.pass, x, y, w, h);
    }
    pub fn setBlendConstant(p: *RenderPass, color: Color) void {
        js.gpup_set_blend_constant(p.pass, color.r, color.g, color.b, color.a);
    }
    pub fn draw(p: *RenderPass, vertex_count: u32, instance_count: u32, first_vertex: u32, first_instance: u32) void {
        js.gpu_draw(p.pass, vertex_count, instance_count, first_vertex, first_instance);
    }
    pub fn drawIndexed(p: *RenderPass, index_count: u32, instance_count: u32, first_index: u32, base_vertex: i32, first_instance: u32) void {
        js.gpup_draw_indexed(p.pass, index_count, instance_count, first_index, base_vertex, first_instance);
    }
    /// Ends and releases a pass the projection began. A wrapped pass is the host's.
    pub fn end(p: *RenderPass) void {
        if (!p.owned) return;
        js.gpup_end_pass(p.pass);
        p.owned = false;
    }
};

pub const ComputePass = struct {
    pass: u32,

    pub fn setPipeline(p: *ComputePass, pipeline: anytype) void {
        js.gpu_set_pipeline(p.pass, pipeline.compute);
    }
    pub fn setBindGroup(p: *ComputePass, comptime index: u32, group: anytype) void {
        comptime checkIndex(Deref(@TypeOf(group)), index);
        js.gpu_set_bind_group(p.pass, index, group.group);
    }
    pub fn dispatchWorkgroups(p: *ComputePass, x: u32, y: u32, z: u32) void {
        js.gpup_dispatch(p.pass, x, y, z);
    }
    pub fn end(p: *ComputePass) void {
        js.gpup_end_pass(p.pass);
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
