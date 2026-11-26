//! `lcgf_render.gpu` on GL ES 3: WebGPU's object model projected onto GL ES at compile time.
//! Every type is a plain struct of GL names with public fields (`buffer.handle` is the buffer
//! name, `texture.handle` the texture name). GL ES has neither bind groups nor command buffers,
//! so a render pass is the current context, a pipeline is a program plus the fixed-function
//! state it sets, and `setBindGroup` replays a binding table the compiler built from the
//! shader's reflection: one `glBindBufferBase`, `glActiveTexture`/`glBindTexture`/`glBindSampler`
//! or `glBindImageTexture` per binding, unrolled.
//!
//! Binding points are flat per kind, in (group, binding) order: the k-th uniform buffer of the
//! shader is uniform block binding k, the k-th texture is texture unit k, and so on. naga's GLSL
//! declares storage blocks and images without a binding, which GL ES cannot assign at run time,
//! so `Shader` writes `binding = k` into those declarations at compile time.
//!
//! Samplers: GL samples a texture through a unit, and naga's GLSL fuses each texture with the
//! sampler that reads it. A group's sampler is bound to the units of that group's textures: the
//! group's only sampler to all of them, or the k-th sampler to the k-th texture.
//!
//! Y: naga flips clip-space y for GL, so a row's index in GL memory is its index from the top in
//! WebGPU. Scissor rects, viewports, texture uploads and readback use rows from the top unchanged.
//!
//! GL ES 2 has no uniform buffers; its path (`es2.zig`) keeps the hand-written custom draw.

const std = @import("std");
const builtin = @import("builtin");
const lcgf = @import("lcgf");
const gl = @import("gl.zig");
const desc = lcgf.gpu_desc;
const reflect = lcgf.gpu_reflect;

pub const Error = error{ CompileFailed, LinkFailed, UnsupportedFormat, IncompleteFramebuffer, NoCompute, OutOfArena, IncompatibleMemory };

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

pub const native = .gles;
/// The GL ES entry points, as this back end loads them.
pub const glapi = gl;

const debug_checks = builtin.mode == .debug;

pub const max_groups = 4;
pub const max_color_targets = 4;
pub const max_vertex_buffers = 8;
pub const max_vertex_attributes = 16;

// GL ES 3 / 3.1 enums the projection uses beyond gl.zig's.
const COPY_READ_BUFFER: gl.Enum = 0x8F36;
const COPY_WRITE_BUFFER: gl.Enum = 0x8F37;
const SHADER_STORAGE_BUFFER: gl.Enum = 0x90D2;
const DRAW_INDIRECT_BUFFER: gl.Enum = 0x8F3F;
const READ_FRAMEBUFFER: gl.Enum = 0x8CA8;
const DRAW_FRAMEBUFFER: gl.Enum = 0x8CA9;
const RENDERBUFFER: gl.Enum = 0x8D41;
const UNPACK_ROW_LENGTH: gl.Enum = 0x0CF2;
const MAP_READ_BIT: gl.Bitfield = 0x0001;
const ALL_BARRIER_BITS: gl.Bitfield = 0xFFFF_FFFF;
const TEXTURE_COMPARE_MODE: gl.Enum = 0x884C;
const TEXTURE_COMPARE_FUNC: gl.Enum = 0x884D;
const COMPARE_REF_TO_TEXTURE: gl.Int = 0x884E;
const TEXTURE_MIN_LOD: gl.Enum = 0x813A;
const TEXTURE_MAX_LOD: gl.Enum = 0x813B;
const TEXTURE_WRAP_R: gl.Enum = 0x8072;
const LINEAR: gl.Int = 0x2601;
const NEAREST_MIPMAP_NEAREST: gl.Int = 0x2700;
const LINEAR_MIPMAP_NEAREST: gl.Int = 0x2701;
const NEAREST_MIPMAP_LINEAR: gl.Int = 0x2702;
const LINEAR_MIPMAP_LINEAR: gl.Int = 0x2703;
const REPEAT: gl.Int = 0x2901;
const MIRRORED_REPEAT: gl.Int = 0x8370;
const READ_ONLY: gl.Enum = 0x88B8;
const WRITE_ONLY: gl.Enum = 0x88B9;
const READ_WRITE: gl.Enum = 0x88BA;
const COMPUTE_SHADER: gl.Enum = 0x91B9;
const POINTS: gl.Enum = 0x0000;
const LINES: gl.Enum = 0x0001;
const LINE_STRIP: gl.Enum = 0x0003;
const CW: gl.Enum = 0x0900;
const CCW: gl.Enum = 0x0901;
const FRONT: gl.Enum = 0x0404;
const BACK: gl.Enum = 0x0405;
const INT: gl.Enum = 0x1404;
const HALF_FLOAT: gl.Enum = 0x140B;
const PRIMITIVE_RESTART_FIXED_INDEX: gl.Enum = 0x8D69;
const SAMPLE_ALPHA_TO_COVERAGE: gl.Enum = 0x809E;

// ---------------------------------------------------------------------------------------------
// Device and memory

/// The host's GL ES context: its function tables. 3.1's is optional (compute).
pub const Device = struct {
    f: *const gl.Fns,
    f3: *const gl.Fns3,
    f31: ?*const gl.Fns31 = null,

    pub fn wrap(f: *const gl.Fns, f3: *const gl.Fns3, f31: ?*const gl.Fns31) Device {
        return .{ .f = f, .f3 = f3, .f31 = f31 };
    }

    pub fn createBuffer(device: Device, arena: *Arena, d: BufferDescriptor) Error!Buffer {
        _ = arena;
        const f = device.f;
        var b: Buffer = .{ .handle = 0, .size = d.size, .mapped = null };
        f.glGenBuffers(1, @ptrCast(&b.handle));
        f.glBindBuffer(COPY_WRITE_BUFFER, b.handle);
        f.glBufferData(COPY_WRITE_BUFFER, @intCast(d.size), null, gl.DYNAMIC_DRAW);
        f.glBindBuffer(COPY_WRITE_BUFFER, 0);
        return b;
    }

    pub fn destroyBuffer(device: Device, b: Buffer) void {
        device.f.glDeleteBuffers(1, @ptrCast(&b.handle));
    }

    /// Copies `out.len` bytes of `b` from `offset` into `out`, waiting for the GPU (WebGPU's
    /// `mapAsync` + `getMappedRange`, synchronous: the caller knows the writes are done).
    pub fn readBuffer(device: Device, b: Buffer, offset: u64, out: []u8) void {
        const f3 = device.f3;
        device.f.glBindBuffer(COPY_READ_BUFFER, b.handle);
        const ptr = f3.glMapBufferRange(COPY_READ_BUFFER, @intCast(offset), @intCast(out.len), MAP_READ_BIT);
        if (ptr) |p| @memcpy(out, @as([*]const u8, @ptrCast(p))[0..out.len]);
        _ = f3.glUnmapBuffer(COPY_READ_BUFFER);
        device.f.glBindBuffer(COPY_READ_BUFFER, 0);
    }

    pub fn createTexture(device: Device, arena: *Arena, d: TextureDescriptor) Error!Texture {
        _ = arena;
        const f = device.f;
        const f3 = device.f3;
        const fmt = try glFormat(d.format);
        var t: Texture = .{ .handle = 0, .renderbuffer = 0, .fbo = 0, .format = d.format, .width = d.size.width, .height = d.size.height, .samples = d.sample_count };
        if (d.sample_count > 1) {
            // GL ES 3.0 multisamples only renderbuffers: a multisampled target is drawn and resolved.
            f3.glGenRenderbuffers(1, @ptrCast(&t.renderbuffer));
            f3.glBindRenderbuffer(RENDERBUFFER, t.renderbuffer);
            f3.glRenderbufferStorageMultisample(RENDERBUFFER, @intCast(d.sample_count), fmt.internal, @intCast(d.size.width), @intCast(d.size.height));
        } else {
            f.glGenTextures(1, @ptrCast(&t.handle));
            f.glBindTexture(gl.TEXTURE_2D, t.handle);
            f3.glTexStorage2D(gl.TEXTURE_2D, @intCast(d.mip_level_count), fmt.internal, @intCast(d.size.width), @intCast(d.size.height));
            // Complete without a sampler object; a bound sampler overrides these.
            f.glTexParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.NEAREST);
            f.glTexParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.NEAREST);
        }
        if (d.usage.render_attachment) {
            f.glGenFramebuffers(1, @ptrCast(&t.fbo));
            f.glBindFramebuffer(gl.FRAMEBUFFER, t.fbo);
            if (t.renderbuffer != 0)
                f3.glFramebufferRenderbuffer(gl.FRAMEBUFFER, gl.COLOR_ATTACHMENT0, RENDERBUFFER, t.renderbuffer)
            else
                f.glFramebufferTexture2D(gl.FRAMEBUFFER, gl.COLOR_ATTACHMENT0, gl.TEXTURE_2D, t.handle, 0);
            const status = f.glCheckFramebufferStatus(gl.FRAMEBUFFER);
            f.glBindFramebuffer(gl.FRAMEBUFFER, 0);
            if (status != gl.FRAMEBUFFER_COMPLETE) {
                device.destroyTexture(t);
                return error.IncompleteFramebuffer;
            }
        }
        return t;
    }

    pub fn destroyTexture(device: Device, t: Texture) void {
        if (t.fbo != 0) device.f.glDeleteFramebuffers(1, @ptrCast(&t.fbo));
        if (t.handle != 0) device.f.glDeleteTextures(1, @ptrCast(&t.handle));
        if (t.renderbuffer != 0) device.f3.glDeleteRenderbuffers(1, @ptrCast(&t.renderbuffer));
    }

    pub fn createSampler(device: Device, d: SamplerDescriptor) Error!Sampler {
        const f3 = device.f3;
        var s: Sampler = .{ .handle = 0 };
        f3.glGenSamplers(1, @ptrCast(&s.handle));
        const linear_min = d.min_filter == .linear;
        const min: gl.Int = if (d.mipmap_filter == .linear)
            (if (linear_min) LINEAR_MIPMAP_LINEAR else NEAREST_MIPMAP_LINEAR)
        else
            (if (linear_min) LINEAR_MIPMAP_NEAREST else NEAREST_MIPMAP_NEAREST);
        f3.glSamplerParameteri(s.handle, gl.TEXTURE_MIN_FILTER, min);
        f3.glSamplerParameteri(s.handle, gl.TEXTURE_MAG_FILTER, if (d.mag_filter == .linear) LINEAR else gl.NEAREST);
        f3.glSamplerParameteri(s.handle, gl.TEXTURE_WRAP_S, wrapMode(d.address_mode_u));
        f3.glSamplerParameteri(s.handle, gl.TEXTURE_WRAP_T, wrapMode(d.address_mode_v));
        f3.glSamplerParameteri(s.handle, TEXTURE_WRAP_R, wrapMode(d.address_mode_w));
        f3.glSamplerParameterf(s.handle, TEXTURE_MIN_LOD, d.lod_min_clamp);
        f3.glSamplerParameterf(s.handle, TEXTURE_MAX_LOD, d.lod_max_clamp);
        if (d.compare) |cmp| {
            f3.glSamplerParameteri(s.handle, TEXTURE_COMPARE_MODE, COMPARE_REF_TO_TEXTURE);
            f3.glSamplerParameteri(s.handle, TEXTURE_COMPARE_FUNC, @intCast(compareFunc(cmp)));
        }
        return s;
    }

    pub fn destroySampler(device: Device, s: Sampler) void {
        device.f3.glDeleteSamplers(1, @ptrCast(&s.handle));
    }

    pub fn createRenderPipeline(device: Device, comptime S: type, d: RenderPipelineDescriptor) Error!RenderPipeline(S) {
        const f = device.f;
        const frag = d.fragment orelse desc.FragmentState{ .targets = &.{} };
        const vs = S.glsl(d.vertex.entry_point) orelse return error.CompileFailed;
        const fs = S.glsl(frag.entry_point) orelse return error.CompileFailed;
        var p: RenderPipeline(S) = .{ .program = 0, .vao = 0, .mode = drawMode(d.primitive.topology) };
        p.program = try link(f, &.{ .{ gl.VERTEX_SHADER, vs }, .{ gl.FRAGMENT_SHADER, fs } });
        errdefer f.glDeleteProgram(p.program);
        bindNames(device, S, p.program);
        device.f3.glGenVertexArrays(1, @ptrCast(&p.vao));
        for (d.vertex.buffers, 0..) |vb, slot| {
            p.buffers[slot] = .{ .stride = @intCast(vb.array_stride), .instance = vb.step_mode == .instance, .first = p.attribute_count, .count = @intCast(vb.attributes.len) };
            for (vb.attributes) |a| {
                p.attributes[p.attribute_count] = .{ .location = a.shader_location, .format = a.format, .offset = @intCast(a.offset) };
                p.attribute_count += 1;
            }
        }
        p.buffer_count = @intCast(d.vertex.buffers.len);
        p.cull = d.primitive.cull_mode;
        p.front_ccw = d.primitive.front_face == .ccw;
        p.restart = d.primitive.strip_index_format != null;
        p.alpha_to_coverage = d.multisample.alpha_to_coverage_enabled;
        if (frag.targets.len > 0) {
            const t = frag.targets[0];
            p.blend = t.blend;
            p.write_mask = t.write_mask;
        }
        return p;
    }

    pub fn destroyRenderPipeline(device: Device, p: anytype) void {
        device.f.glDeleteProgram(p.program);
        if (@hasField(@TypeOf(p), "vao")) device.f3.glDeleteVertexArrays(1, @ptrCast(&p.vao));
    }

    pub fn createComputePipeline(device: Device, comptime S: type, d: ComputePipelineDescriptor) Error!ComputePipeline(S) {
        if (device.f31 == null) return error.NoCompute;
        const cs = S.glsl(d.entry_point) orelse return error.CompileFailed;
        const program = try link(device.f, &.{.{ COMPUTE_SHADER, cs }});
        bindNames(device, S, program);
        return .{ .program = program };
    }

    pub const destroyComputePipeline = destroyRenderPipeline;

    /// A bind group for group `g` of `pipeline`'s shader: the names of the resources, in the
    /// order the binding table replays them.
    pub fn createBindGroup(device: Device, arena: *Arena, pipeline: anytype, comptime g: u32, entries: Deref(@TypeOf(pipeline)).Shader.Group(g)) Error!BindGroup(Deref(@TypeOf(pipeline)).Shader, g) {
        _ = device;
        _ = arena;
        const S = Deref(@TypeOf(pipeline)).Shader;
        var bg: BindGroup(S, g) = undefined;
        inline for (comptime S.module.group(g), 0..) |b, i| {
            const v = @field(entries, b.name);
            bg.names[i] = switch (comptime b.kind) {
                .uniform, .storage_read, .storage_read_write => v.handle,
                .texture => v.texture,
                .storage_texture => v.texture,
                .sampler, .comparison_sampler => v.handle,
            };
            if (comptime b.kind.isBuffer()) bg.sizes[i] = v.size;
        }
        return bg;
    }
};

/// GL allocates its own memory: an arena is only the projection's uniform interface.
pub const Arena = struct {
    pub const Kind = enum { device, host };
    pub const Options = struct { bytes: u64, memory: Kind = .device, bind_groups: u32 = 64 };
    pub fn init(_: Device, _: Options) Error!Arena {
        return .{};
    }
    pub fn deinit(_: *Arena) void {}
    pub fn reset(_: *Arena) void {}
};

/// GL uploads through the driver; staging exists for the uniform interface.
pub const Staging = struct {
    pub fn init(_: Device, _: *Arena, _: u64) Error!Staging {
        return .{};
    }
    pub fn deinit(_: Staging, _: Device) void {}
    pub fn rewind(_: *Staging) void {}
};

// ---------------------------------------------------------------------------------------------
// Objects

pub const Buffer = extern struct {
    handle: gl.Uint,
    size: u64,
    /// Always null on GL ES: read results back with `Device.readBuffer`.
    mapped: ?[*]u8,
};

pub const Texture = struct {
    handle: gl.Uint,
    renderbuffer: gl.Uint,
    fbo: gl.Uint,
    format: TextureFormat,
    width: u32,
    height: u32,
    samples: u32,

    pub fn createView(t: Texture) TextureView {
        return .{ .texture = t.handle, .fbo = t.fbo, .width = t.width, .height = t.height, .samples = t.samples, .format = t.format };
    }
};

pub const TextureView = struct {
    texture: gl.Uint,
    /// The framebuffer that draws into it, if it is a render attachment.
    fbo: gl.Uint = 0,
    width: u32,
    height: u32,
    samples: u32 = 1,
    format: TextureFormat = .rgba8_unorm,
};

pub const Sampler = extern struct { handle: gl.Uint };

/// A shader: `source` is a namespace with `wgsl` and naga's GLSL ES of each entry point,
/// `glsl_<entry>`, as `addGpuShaders` makes for gles. Binding qualifiers are added here.
pub fn Shader(comptime source: type) type {
    return struct {
        pub const module = reflect.parse(source.wgsl);

        /// The GLSL of entry point `entry` (a runtime name compared at comptime against the
        /// reflected entry points), with storage blocks and images given their bindings.
        pub fn glsl(entry: []const u8) ?[:0]const u8 {
            inline for (module.entry_points) |e| {
                const decl = "glsl_" ++ e.name;
                if (!@hasDecl(source, decl)) @compileError("no GLSL for entry point `" ++ e.name ++ "`: build the shader with addGpuShaders for gles");
                if (std.mem.eql(u8, entry, e.name)) return comptime naga.glsl(module, @field(source, decl));
            }
            return null;
        }

        pub fn Group(comptime g: u32) type {
            return module.Group(g, Buffer, TextureView, Sampler);
        }
    };
}

pub fn RenderPipeline(comptime S: type) type {
    return struct {
        program: gl.Uint,
        vao: gl.Uint,
        mode: gl.Enum,
        buffers: [max_vertex_buffers]VertexBuffer = undefined,
        buffer_count: u8 = 0,
        attributes: [max_vertex_attributes]Attribute = undefined,
        attribute_count: u8 = 0,
        cull: desc.CullMode = .none,
        front_ccw: bool = true,
        restart: bool = false,
        alpha_to_coverage: bool = false,
        blend: ?BlendState = null,
        write_mask: desc.ColorWriteMask = .all,
        pub const Shader = S;
    };
}

const VertexBuffer = struct { stride: u32, instance: bool, first: u8, count: u8 };
const Attribute = struct { location: u32, format: VertexFormat, offset: u32 };

pub fn ComputePipeline(comptime S: type) type {
    return struct {
        program: gl.Uint,
        pub const Shader = S;
    };
}

/// The GL names of a group's resources, in binding order, and the sizes of its buffers.
pub fn BindGroup(comptime S: type, comptime g: u32) type {
    const n = S.module.group(g).len;
    return struct {
        names: [n]gl.Uint,
        sizes: [n]u64,
        pub const Shader = S;
        pub const index = g;
    };
}

// ---------------------------------------------------------------------------------------------
// Binding table, from the reflection (src/render/gpu/naga.zig numbers the slots)

const naga = lcgf.gpu_naga;

fn unitOf(comptime m: reflect.Module, comptime group: u32, comptime binding: u32) u32 {
    return naga.slotOf(naga.glslSlots(m), group, binding);
}

/// After linking: uniform blocks to their binding points, sampler uniforms to their units.
/// naga names a resource `_group_G_binding_B_<stage>` in every stage that uses it; its uniform
/// block is the `uniform <Block> {` enclosing that name.
fn bindNames(device: Device, comptime S: type, program: gl.Uint) void {
    const f = device.f;
    f.glUseProgram(program);
    inline for (comptime naga.glslSlots(S.module)) |u| {
        const b = comptime blk: {
            for (S.module.bindings) |x| if (x.group == u.group and x.binding == u.binding) break :blk x;
            unreachable;
        };
        inline for (.{ "vs", "fs", "cs" }) |stage| {
            const name = std.fmt.comptimePrint("_group_{d}_binding_{d}_{s}", .{ u.group, u.binding, stage });
            switch (comptime b.kind) {
                .uniform => inline for (comptime blockNames(S, name)) |block| {
                    const index = device.f3.glGetUniformBlockIndex(program, block.ptr);
                    if (index != gl.INVALID_INDEX) device.f3.glUniformBlockBinding(program, index, u.slot);
                },
                .texture => {
                    const loc = f.glGetUniformLocation(program, name.ptr);
                    if (loc >= 0) f.glUniform1i(loc, @intCast(u.slot));
                },
                else => {},
            }
        }
    }
    f.glUseProgram(0);
}

/// The uniform block names naga gave `name` in any of the shader's GLSL texts.
fn blockNames(comptime S: type, comptime name: []const u8) []const [:0]const u8 {
    comptime {
        var out: []const [:0]const u8 = &.{};
        for (S.module.entry_points) |e| out = out ++ naga.glslBlocks(S.glsl(e.name).?, name);
        return out;
    }
}

// ---------------------------------------------------------------------------------------------
// Frame phases

/// The write phase: GL orders writes itself, so this is the projection's uniform interface
/// with direct calls.
pub const Upload = struct {
    f: *const gl.Fns,
    f3: *const gl.Fns3,
    f31: ?*const gl.Fns31,

    pub fn begin(device: Device, _: void) Upload {
        return .{ .f = device.f, .f3 = device.f3, .f31 = device.f31 };
    }

    pub fn beginStaged(device: Device, cmd: void, _: *Staging) Upload {
        return begin(device, cmd);
    }

    pub fn writeBuffer(up: *Upload, buffer: Buffer, offset: u64, bytes: []const u8) void {
        if (debug_checks) std.debug.assert(offset % 4 == 0 and bytes.len % 4 == 0 and offset + bytes.len <= buffer.size);
        up.f.glBindBuffer(COPY_WRITE_BUFFER, buffer.handle);
        up.f.glBufferSubData(COPY_WRITE_BUFFER, @intCast(offset), @intCast(bytes.len), bytes.ptr);
        up.f.glBindBuffer(COPY_WRITE_BUFFER, 0);
    }

    pub fn writeTexture(up: *Upload, t: Texture, bytes: []const u8, bytes_per_row: u32) Error!void {
        const fmt = try glFormat(t.format);
        up.f.glBindTexture(gl.TEXTURE_2D, t.handle);
        up.f.glPixelStorei(gl.UNPACK_ALIGNMENT, 1);
        up.f.glPixelStorei(UNPACK_ROW_LENGTH, @intCast(bytes_per_row / t.format.bytesPerPixel()));
        up.f.glTexSubImage2D(gl.TEXTURE_2D, 0, 0, 0, @intCast(t.width), @intCast(t.height), fmt.format, fmt.type, bytes.ptr);
        up.f.glPixelStorei(UNPACK_ROW_LENGTH, 0);
    }

    pub fn prepare(_: *Upload, _: Texture) void {}

    pub fn finish(up: *Upload) Encoder {
        return .{ .f = up.f, .f3 = up.f3, .f31 = up.f31 };
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
    f: *const gl.Fns,
    f3: *const gl.Fns3,
    f31: ?*const gl.Fns31,

    /// Draws into the first attachment's framebuffer (GL ES draws one colour target per
    /// framebuffer here); clears it when asked; viewport and scissor cover it.
    pub fn beginRenderPass(e: Encoder, d: RenderPassDescriptor) RenderPass {
        const a = d.color_attachments[0];
        var p: RenderPass = .{ .f = e.f, .f3 = e.f3, .width = a.view.width, .height = a.view.height, .owned = true };
        e.f.glBindFramebuffer(gl.FRAMEBUFFER, a.view.fbo);
        if (a.resolve_target) |r| p.resolve = .{ .from = a.view.fbo, .to = r.fbo };
        e.f.glEnable(gl.SCISSOR_TEST);
        p.setViewport(0, 0, @floatFromInt(p.width), @floatFromInt(p.height), 0, 1);
        p.setScissorRect(0, 0, p.width, p.height);
        if (a.load_op == .clear) {
            const cv = a.clear_value;
            e.f.glColorMask(1, 1, 1, 1);
            e.f.glClearColor(@floatCast(cv.r), @floatCast(cv.g), @floatCast(cv.b), @floatCast(cv.a));
            e.f.glClear(gl.COLOR_BUFFER_BIT);
        }
        return p;
    }

    pub fn beginComputePass(e: Encoder) ComputePass {
        return .{ .f = e.f, .f3 = e.f3, .f31 = e.f31.? };
    }
};

/// A render pass: the current GL context, and the vertex layout of the bound pipeline (GL ES
/// 3.0 binds attribute formats together with buffers).
pub const RenderPass = struct {
    f: *const gl.Fns,
    f3: *const gl.Fns3,
    width: u32,
    height: u32,
    owned: bool = false,
    resolve: ?struct { from: gl.Uint, to: gl.Uint } = null,
    mode: gl.Enum = gl.TRIANGLES,
    buffers: [max_vertex_buffers]VertexBuffer = undefined,
    attributes: [max_vertex_attributes]Attribute = undefined,
    index_type: gl.Enum = gl.UNSIGNED_SHORT,
    index_offset: u64 = 0,
    debug: if (debug_checks) struct { pipeline: bool = false } else void = if (debug_checks) .{} else {},

    /// The pass the host is drawing in (the UI's, for an inline custom draw).
    pub fn wrap(device: Device, _: void, width: u32, height: u32) RenderPass {
        return .{ .f = device.f, .f3 = device.f3, .width = width, .height = height };
    }

    /// Program, vertex array, and the fixed-function state the pipeline describes.
    pub fn setPipeline(p: *RenderPass, pipeline: anytype) void {
        const f = p.f;
        if (debug_checks) p.debug.pipeline = true;
        f.glUseProgram(pipeline.program);
        p.f3.glBindVertexArray(pipeline.vao);
        p.mode = pipeline.mode;
        p.buffers = pipeline.buffers;
        p.attributes = pipeline.attributes;
        if (pipeline.blend) |b| {
            f.glEnable(gl.BLEND);
            f.glBlendFuncSeparate(blendFactor(b.color.src_factor), blendFactor(b.color.dst_factor), blendFactor(b.alpha.src_factor), blendFactor(b.alpha.dst_factor));
            f.glBlendEquationSeparate(blendOp(b.color.operation), blendOp(b.alpha.operation));
        } else f.glDisable(gl.BLEND);
        const m = pipeline.write_mask;
        f.glColorMask(@intFromBool(m.red), @intFromBool(m.green), @intFromBool(m.blue), @intFromBool(m.alpha));
        if (pipeline.cull == .none) f.glDisable(gl.CULL_FACE) else {
            f.glEnable(gl.CULL_FACE);
            f.glCullFace(if (pipeline.cull == .front) FRONT else BACK);
        }
        // naga's y flip mirrors the image in GL's clip space, which reverses the winding GL sees.
        f.glFrontFace(if (pipeline.front_ccw) CW else CCW);
        if (pipeline.restart) f.glEnable(PRIMITIVE_RESTART_FIXED_INDEX) else f.glDisable(PRIMITIVE_RESTART_FIXED_INDEX);
        if (pipeline.alpha_to_coverage) f.glEnable(SAMPLE_ALPHA_TO_COVERAGE) else f.glDisable(SAMPLE_ALPHA_TO_COVERAGE);
        f.glDisable(gl.DEPTH_TEST);
        f.glDisable(gl.STENCIL_TEST);
        f.glDisable(gl.DITHER);
        f.glEnable(gl.SCISSOR_TEST);
    }

    pub fn setBindGroup(p: *RenderPass, comptime index: u32, group: anytype) void {
        replay(p.f, p.f3, null, index, group);
    }

    pub fn setVertexBuffer(p: *RenderPass, slot: u32, buffer: Buffer, offset: u64) void {
        const f = p.f;
        const vb = p.buffers[slot];
        f.glBindBuffer(gl.ARRAY_BUFFER, buffer.handle);
        for (p.attributes[vb.first..][0..vb.count]) |a| {
            const n: gl.Int, const ty: gl.Enum, const kind: enum { float, int, norm } = switch (a.format) {
                .float32 => .{ 1, gl.FLOAT, .float },
                .float32x2 => .{ 2, gl.FLOAT, .float },
                .float32x3 => .{ 3, gl.FLOAT, .float },
                .float32x4 => .{ 4, gl.FLOAT, .float },
                .uint32 => .{ 1, gl.UNSIGNED_INT, .int },
                .uint32x2 => .{ 2, gl.UNSIGNED_INT, .int },
                .uint32x4 => .{ 4, gl.UNSIGNED_INT, .int },
                .sint32 => .{ 1, INT, .int },
                .unorm8x4 => .{ 4, gl.UNSIGNED_BYTE, .norm },
            };
            const at: ?*const anyopaque = @ptrFromInt(@as(usize, @intCast(offset)) + a.offset);
            f.glEnableVertexAttribArray(a.location);
            if (kind == .int)
                p.f3.glVertexAttribIPointer(a.location, n, ty, @intCast(vb.stride), at)
            else
                f.glVertexAttribPointer(a.location, n, ty, @intFromBool(kind == .norm), @intCast(vb.stride), at);
            p.f3.glVertexAttribDivisor(a.location, @intFromBool(vb.instance));
        }
    }

    pub fn setIndexBuffer(p: *RenderPass, buffer: Buffer, format: IndexFormat, offset: u64) void {
        p.f.glBindBuffer(gl.ELEMENT_ARRAY_BUFFER, buffer.handle);
        p.index_type = if (format == .uint16) gl.UNSIGNED_SHORT else gl.UNSIGNED_INT;
        p.index_offset = offset;
    }

    pub fn setViewport(p: *RenderPass, x: f32, y: f32, w: f32, h: f32, min_depth: f32, max_depth: f32) void {
        _ = min_depth;
        _ = max_depth;
        p.f.glViewport(@intFromFloat(x), @intFromFloat(y), @intFromFloat(w), @intFromFloat(h));
    }

    pub fn setScissorRect(p: *RenderPass, x: u32, y: u32, w: u32, h: u32) void {
        if (debug_checks) std.debug.assert(x + w <= p.width and y + h <= p.height);
        p.f.glEnable(gl.SCISSOR_TEST);
        p.f.glScissor(@intCast(x), @intCast(y), @intCast(w), @intCast(h));
    }

    pub fn setBlendConstant(p: *RenderPass, color: Color) void {
        p.f.glBlendColor(@floatCast(color.r), @floatCast(color.g), @floatCast(color.b), @floatCast(color.a));
    }

    pub fn draw(p: *RenderPass, vertex_count: u32, instance_count: u32, first_vertex: u32, first_instance: u32) void {
        if (debug_checks) std.debug.assert(p.debug.pipeline and first_instance == 0);
        p.f3.glDrawArraysInstanced(p.mode, @intCast(first_vertex), @intCast(vertex_count), @intCast(instance_count));
    }

    pub fn drawIndexed(p: *RenderPass, index_count: u32, instance_count: u32, first_index: u32, base_vertex: i32, first_instance: u32) void {
        if (debug_checks) std.debug.assert(p.debug.pipeline and base_vertex == 0 and first_instance == 0);
        const size: u64 = if (p.index_type == gl.UNSIGNED_SHORT) 2 else 4;
        p.f3.glDrawElementsInstanced(p.mode, @intCast(index_count), p.index_type, @ptrFromInt(@as(usize, @intCast(p.index_offset + first_index * size))), @intCast(instance_count));
    }

    /// Ends a pass the projection began: resolves a multisampled target, unbinds the
    /// framebuffer. A wrapped pass is the host's.
    pub fn end(p: *RenderPass) void {
        if (!p.owned) return;
        if (p.resolve) |r| {
            p.f.glBindFramebuffer(READ_FRAMEBUFFER, r.from);
            p.f.glBindFramebuffer(DRAW_FRAMEBUFFER, r.to);
            p.f3.glBlitFramebuffer(0, 0, @intCast(p.width), @intCast(p.height), 0, 0, @intCast(p.width), @intCast(p.height), gl.COLOR_BUFFER_BIT, gl.NEAREST);
        }
        p.f.glBindFramebuffer(gl.FRAMEBUFFER, 0);
        p.owned = false;
    }
};

pub const ComputePass = struct {
    f: *const gl.Fns,
    f3: *const gl.Fns3,
    f31: *const gl.Fns31,

    pub fn setPipeline(p: *ComputePass, pipeline: anytype) void {
        p.f.glUseProgram(pipeline.program);
    }

    pub fn setBindGroup(p: *ComputePass, comptime index: u32, group: anytype) void {
        replay(p.f, p.f3, p.f31, index, group);
    }

    pub fn dispatchWorkgroups(p: *ComputePass, x: u32, y: u32, z: u32) void {
        p.f31.glDispatchCompute(x, y, z);
    }

    /// One barrier over every kind of access after the dispatches.
    pub fn end(p: *ComputePass) void {
        p.f31.glMemoryBarrier(ALL_BARRIER_BITS);
    }
};

/// The bind calls of `group`, unrolled from the shader's binding table.
inline fn replay(f: *const gl.Fns, f3: *const gl.Fns3, f31: ?*const gl.Fns31, comptime index: u32, group: anytype) void {
    const G = Deref(@TypeOf(group));
    comptime checkIndex(G, index);
    const m = G.Shader.module;
    const bindings = comptime m.group(index);
    const samplers = comptime blk: {
        var n: u32 = 0;
        for (bindings) |b| if (b.kind == .sampler or b.kind == .comparison_sampler) {
            n += 1;
        };
        break :blk n;
    };
    comptime var texture_k: u32 = 0;
    inline for (bindings, 0..) |b, i| {
        const unit = comptime unitOf(m, index, b.binding);
        switch (comptime b.kind) {
            .uniform => f3.glBindBufferRange(gl.UNIFORM_BUFFER, unit, group.names[i], 0, @intCast(group.sizes[i])),
            .storage_read, .storage_read_write => f3.glBindBufferRange(SHADER_STORAGE_BUFFER, unit, group.names[i], 0, @intCast(group.sizes[i])),
            .texture => {
                f.glActiveTexture(gl.TEXTURE0 + unit);
                f.glBindTexture(gl.TEXTURE_2D, group.names[i]);
                // This group's samplers on this texture's unit (see the file comment).
                inline for (bindings, 0..) |s, j| if (comptime (s.kind == .sampler or s.kind == .comparison_sampler)) {
                    const k = comptime blk: {
                        var n: u32 = 0;
                        for (bindings[0..j]) |x| if (x.kind == .sampler or x.kind == .comparison_sampler) {
                            n += 1;
                        };
                        break :blk n;
                    };
                    if (comptime samplers == 1 or k == texture_k) f3.glBindSampler(unit, group.names[j]);
                };
                texture_k += 1;
            },
            .storage_texture => {
                const fmt = comptime storageFormat(b.storage_format);
                const access: gl.Enum = switch (comptime b.access) {
                    .read => READ_ONLY,
                    .write => WRITE_ONLY,
                    .read_write => READ_WRITE,
                };
                f31.?.glBindImageTexture(unit, group.names[i], 0, 0, 0, access, fmt);
            },
            .sampler, .comparison_sampler => {}, // bound with their textures
        }
    }
}

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

fn link(f: *const gl.Fns, stages: []const struct { gl.Enum, [:0]const u8 }) Error!gl.Uint {
    const program = f.glCreateProgram();
    var objects: [2]gl.Uint = .{ 0, 0 };
    defer for (objects[0..stages.len]) |s| if (s != 0) f.glDeleteShader(s);
    for (stages, 0..) |st, i| {
        const s = f.glCreateShader(st[0]);
        objects[i] = s;
        const ptr: [*]const u8 = st[1].ptr;
        const len: gl.Int = @intCast(st[1].len);
        f.glShaderSource(s, 1, @ptrCast(&ptr), @ptrCast(&len));
        f.glCompileShader(s);
        var ok: gl.Int = 0;
        f.glGetShaderiv(s, gl.COMPILE_STATUS, &ok);
        if (ok == 0) {
            var log: [2048]u8 = undefined;
            var n: gl.Sizei = 0;
            f.glGetShaderInfoLog(s, log.len, &n, &log);
            std.log.warn("lcgf_render.gpu (GL ES): compile failed: {s}", .{log[0..@intCast(n)]});
            f.glDeleteProgram(program);
            return error.CompileFailed;
        }
        f.glAttachShader(program, s);
    }
    f.glLinkProgram(program);
    var ok: gl.Int = 0;
    f.glGetProgramiv(program, gl.LINK_STATUS, &ok);
    if (ok == 0) {
        var log: [2048]u8 = undefined;
        var n: gl.Sizei = 0;
        f.glGetProgramInfoLog(program, log.len, &n, &log);
        std.log.warn("lcgf_render.gpu (GL ES): link failed: {s}", .{log[0..@intCast(n)]});
        f.glDeleteProgram(program);
        return error.LinkFailed;
    }
    return program;
}

const Format = struct { internal: gl.Enum, format: gl.Enum, type: gl.Enum };

pub fn glFormat(f: TextureFormat) Error!Format {
    return switch (f) {
        .r8_unorm => .{ .internal = 0x8229, .format = 0x1903, .type = gl.UNSIGNED_BYTE }, // R8, RED
        .rg8_unorm => .{ .internal = 0x822B, .format = 0x8227, .type = gl.UNSIGNED_BYTE }, // RG8, RG
        .rgba8_unorm => .{ .internal = 0x8058, .format = gl.RGBA, .type = gl.UNSIGNED_BYTE }, // RGBA8
        .rgba8_unorm_srgb => .{ .internal = 0x8C43, .format = gl.RGBA, .type = gl.UNSIGNED_BYTE }, // SRGB8_ALPHA8
        .bgra8_unorm, .bgra8_unorm_srgb => error.UnsupportedFormat, // GL ES has no BGRA storage
        .r16_float => .{ .internal = 0x822D, .format = 0x1903, .type = HALF_FLOAT }, // R16F
        .rgba16_float => .{ .internal = 0x881A, .format = gl.RGBA, .type = HALF_FLOAT }, // RGBA16F
        .r32_float => .{ .internal = 0x822E, .format = 0x1903, .type = gl.FLOAT }, // R32F
        .rg32_float => .{ .internal = 0x8230, .format = 0x8227, .type = gl.FLOAT }, // RG32F
        .rgba32_float => .{ .internal = 0x8814, .format = gl.RGBA, .type = gl.FLOAT }, // RGBA32F
        .r32_uint => .{ .internal = 0x8236, .format = 0x8D94, .type = gl.UNSIGNED_INT }, // R32UI, RED_INTEGER
        .depth32_float => .{ .internal = 0x8CAC, .format = 0x1902, .type = gl.FLOAT }, // DEPTH_COMPONENT32F
    };
}

fn storageFormat(comptime wgsl: []const u8) gl.Enum {
    const table = .{
        .{ "rgba8unorm", 0x8058 }, .{ "rgba16float", 0x881A }, .{ "rgba32float", 0x8814 },
        .{ "r32float", 0x822E },   .{ "r32uint", 0x8236 },     .{ "r32sint", 0x8235 },
        .{ "rgba32uint", 0x8D70 }, .{ "rgba8snorm", 0x8F97 },
    };
    inline for (table) |row| if (std.mem.eql(u8, wgsl, row[0])) return row[1];
    @compileError("GL ES has no storage image format for `" ++ wgsl ++ "`");
}

fn drawMode(t: PrimitiveTopology) gl.Enum {
    return switch (t) {
        .point_list => POINTS,
        .line_list => LINES,
        .line_strip => LINE_STRIP,
        .triangle_list => gl.TRIANGLES,
        .triangle_strip => gl.TRIANGLE_STRIP,
    };
}

fn wrapMode(a: desc.AddressMode) gl.Int {
    return switch (a) {
        .clamp_to_edge => gl.CLAMP_TO_EDGE,
        .repeat => REPEAT,
        .mirror_repeat => MIRRORED_REPEAT,
    };
}

fn compareFunc(f: desc.CompareFunction) gl.Enum {
    return 0x0200 + @as(gl.Enum, @backingInt(f)); // NEVER .. ALWAYS are 0x0200 .. 0x0207 in WebGPU's order
}

fn blendFactor(f: desc.BlendFactor) gl.Enum {
    return switch (f) {
        .zero => 0,
        .one => 1,
        .src => 0x0300,
        .one_minus_src => 0x0301,
        .src_alpha => 0x0302,
        .one_minus_src_alpha => 0x0303,
        .dst => 0x0306,
        .one_minus_dst => 0x0307,
        .dst_alpha => 0x0304,
        .one_minus_dst_alpha => 0x0305,
        .constant => 0x8001,
        .one_minus_constant => 0x8002,
    };
}

fn blendOp(o: desc.BlendOperation) gl.Enum {
    return switch (o) {
        .add => gl.FUNC_ADD,
        .subtract => 0x800A,
        .reverse_subtract => 0x800B,
        .min => 0x8007,
        .max => 0x8008,
    };
}

const testing = std.testing;
const host = @import("host.zig");
const shaders = @import("gpu_shaders");

/// The host side of lcgf.gpu_check on GL ES: the current context, readback through a
/// framebuffer.
const Check = struct {
    h: *host.Host,

    fn device(k: *Check) Device {
        return .wrap(&k.h.gl, &k.h.gl3, if (k.h.gl31) |*f| f else null);
    }
    pub fn upload(k: *Check, staging: *Staging) !Upload {
        return .beginStaged(k.device(), {}, staging);
    }
    pub fn submit(k: *Check) !void {
        k.h.gl.glFinish();
        try k.h.check();
    }
    pub fn readTexture(k: *Check, t: Texture, out: []u8) !void {
        const f = &k.h.gl;
        f.glBindFramebuffer(gl.FRAMEBUFFER, t.fbo);
        k.h.readback(t.width, t.height, out);
        f.glBindFramebuffer(gl.FRAMEBUFFER, 0);
        try k.h.check();
    }
    pub fn readBuffer(k: *Check, b: Buffer, out: []u8) !void {
        k.device().readBuffer(b, 0, out);
        try k.h.check();
    }
};

test "gpu: upload, render to a texture, sample it in a second pass, on a real driver" {
    var h: host.Host = undefined;
    try h.init(.{ .major = 3 });
    defer h.deinit();
    var k: Check = .{ .h = &h };
    try lcgf.gpu_check.renderToTexture(@This(), shaders, k.device(), &k);
}

test "gpu: a compute pass writes a storage buffer the host reads (GL ES 3.1)" {
    var h: host.Host = undefined;
    try h.init(.{ .major = 3 });
    defer h.deinit();
    if (h.gl31 == null) return error.SkipZigTest;
    var k: Check = .{ .h = &h };
    try lcgf.gpu_check.compute(@This(), shaders, k.device(), &k);
}

test "gpu: storage blocks get their binding written into the GLSL" {
    const S = Shader(shaders.fill);
    const text = comptime S.glsl("main").?;
    try testing.expect(std.mem.indexOf(u8, text, "layout(std430, binding = 0) buffer") != null);
}
