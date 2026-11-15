//! ui_wgpu.zig: draws a `ui.DrawList` with wgpu. Targets Zig 0.17.1.
//!
//! A separate file so the core never depends on a GPU API, and generic over
//! the wgpu binding so this file does not depend on one either:
//!
//!     const Gfx = @import("ui_wgpu.zig").Renderer(my_binding);
//!
//! `my_binding` is a namespace of about a dozen thin functions over whatever
//! you use (wgpu-native through translate-c, zgpu, ...). `Binding` below
//! lists them. Reasons for the indirection: bindings differ, `@cImport` is
//! gone in Zig 0.17, and the wgpu C API still changes between releases.
//!
//! WHO OWNS WHAT
//!   You:       device, queue, surface, encoder, render pass, render target.
//!   Renderer:  two instance buffers, one uniform buffer, pipelines and bind
//!              groups it created from your device.
//!
//! RAW GPU ACCESS, all of which follows from you owning the pass:
//!   under / over  draw before or after the UI commands
//!   inline        `Cmd.custom` in the command loop: issue your own draws there
//!   texture in    `addTexture(view)`, then `Style.texture`
//!   texture out   point the pass at any texture view
//!   materials     `addMaterial(shader(your_wgsl_fn))`, then `Style.material`
//!
//! `drawBatch` and `drawText` set every piece of pass state they depend on,
//! so a custom draw may leave the pass in any state.

const std = @import("std");
const ui = @import("ui.zig");

pub const BufferUse = enum { vertex, uniform };
pub const AttrFormat = enum { float32x2, float32x4, unorm8x4 };
pub const Attr = struct { location: u32, offset: u32, format: AttrFormat };

/// Per-instance vertex layout, derived from `ui.Quad` so the two cannot drift.
pub const quad_stride: u32 = @sizeOf(ui.Quad);
pub const quad_attrs = [_]Attr{
    .{ .location = 0, .offset = @offsetOf(ui.Quad, "rect"), .format = .float32x4 },
    .{ .location = 1, .offset = @offsetOf(ui.Quad, "clip"), .format = .float32x4 },
    .{ .location = 2, .offset = @offsetOf(ui.Quad, "params"), .format = .float32x4 },
    .{ .location = 3, .offset = @offsetOf(ui.Quad, "uv"), .format = .float32x4 },
    .{ .location = 4, .offset = @offsetOf(ui.Quad, "fill"), .format = .unorm8x4 },
    .{ .location = 5, .offset = @offsetOf(ui.Quad, "border_color"), .format = .unorm8x4 },
    // radius and border are adjacent floats, read as one vec2.
    .{ .location = 6, .offset = @offsetOf(ui.Quad, "radius"), .format = .float32x2 },
};

comptime {
    std.debug.assert(@offsetOf(ui.Quad, "border") == @offsetOf(ui.Quad, "radius") + 4);
}

/// Group 0, binding 0.
pub const Globals = extern struct {
    /// Logical pixels.
    viewport: [2]f32,
    /// Physical pixels per logical pixel.
    scale: f32,
    _pad: f32 = 0,
};

/// The functions and types `Renderer(gpu)` uses. This struct is
/// documentation; `Renderer` checks the names at compile time.
///
///   Types (any representation: pointers, ids, structs)
///     Device, Queue, RenderPass, Buffer, Pipeline, BindGroup,
///     TextureView, Sampler, TextureFormat
///
///   fn createBuffer(Device, size: u64, BufferUse) Buffer
///        usage VERTEX|COPY_DST or UNIFORM|COPY_DST
///   fn destroyBuffer(Buffer) void
///   fn writeBuffer(Queue, Buffer, offset: u64, bytes: []const u8) void
///   fn createPipeline(Device, *const PipelineDesc) Pipeline
///        triangle strip, no depth, premultiplied-alpha blending (one,
///        one-minus-src-alpha), one vertex buffer stepped per instance with
///        `desc.attrs`. Bind group layouts must be the same objects for every
///        pipeline:  group 0 = uniform buffer (vertex + fragment),
///                   group 1 = texture_2d<f32> + filtering sampler (fragment).
///   fn globalsBindGroup(Device, Buffer) BindGroup
///   fn textureBindGroup(Device, TextureView, Sampler) BindGroup
///   fn setPipeline(RenderPass, Pipeline) void
///   fn setBindGroup(RenderPass, index: u32, BindGroup) void
///   fn setVertexBuffer(RenderPass, slot: u32, Buffer, offset: u64, size: u64) void
///   fn draw(RenderPass, vertices: u32, instances: u32, first_vertex: u32, first_instance: u32) void
pub const Binding = struct {
    pub const types = [_][]const u8{ "Device", "Queue", "RenderPass", "Buffer", "Pipeline", "BindGroup", "TextureView", "Sampler", "TextureFormat" };
    pub const functions = [_][]const u8{ "createBuffer", "destroyBuffer", "writeBuffer", "createPipeline", "globalsBindGroup", "textureBindGroup", "setPipeline", "setBindGroup", "setVertexBuffer", "draw" };
};

/// Glyph quads for the frame's text runs, produced by `ui.fonts.Mono.quads`
/// or by your own shaper. `first[k]`, `count[k]` locate run k in `quads`.
/// Must stay valid until the pass has been recorded.
pub const Glyphs = struct {
    quads: []const ui.Quad = &.{},
    first: []const u32 = &.{},
    count: []const u32 = &.{},
    /// The glyph atlas, as returned by `addTexture`.
    texture: ui.Texture = .white,
};

pub fn Renderer(comptime gpu: type) type {
    comptime {
        for (Binding.types ++ Binding.functions) |name| {
            if (!@hasDecl(gpu, name)) @compileError("wgpu binding is missing `" ++ name ++ "`; see ui_wgpu.Binding");
        }
    }

    return struct {
        const Self = @This();

        pub const max_textures = 64;
        pub const max_materials = 16;

        pub const Desc = struct {
            /// Format of the target the render pass draws into.
            format: gpu.TextureFormat,
            sample_count: u32 = 1,
            max_quads: u32 = 16 * 1024,
            max_glyphs: u32 = 32 * 1024,
        };

        /// Plain description the binding turns into a wgpu pipeline.
        pub const PipelineDesc = struct {
            wgsl: [:0]const u8,
            vertex_entry: [:0]const u8 = "vs",
            fragment_entry: [:0]const u8 = "fs",
            format: gpu.TextureFormat,
            sample_count: u32,
            instance_stride: u32 = quad_stride,
            attrs: []const Attr = &quad_attrs,
        };

        desc: Desc,
        quads: gpu.Buffer,
        glyph_quads: gpu.Buffer,
        globals: gpu.Buffer,
        globals_group: gpu.BindGroup,
        pipelines: [max_materials]gpu.Pipeline = undefined,
        material_count: u16 = 0,
        textures: [max_textures]gpu.BindGroup = undefined,
        texture_count: u16 = 0,
        glyphs: Glyphs = .{},

        /// `white` is a 1x1 opaque white texture; it becomes `ui.Texture.white`.
        pub fn init(device: gpu.Device, desc: Desc, white: gpu.TextureView, sampler: gpu.Sampler) Self {
            const globals = gpu.createBuffer(device, @sizeOf(Globals), .uniform);
            var self: Self = .{
                .desc = desc,
                .quads = gpu.createBuffer(device, @as(u64, desc.max_quads) * quad_stride, .vertex),
                .glyph_quads = gpu.createBuffer(device, @as(u64, desc.max_glyphs) * quad_stride, .vertex),
                .globals = globals,
                .globals_group = gpu.globalsBindGroup(device, globals),
            };
            _ = self.addMaterial(device, comptime shader(default_material)); // ui.Material.solid
            _ = self.addTexture(device, white, sampler); // ui.Texture.white
            return self;
        }

        pub fn deinit(self: *Self) void {
            gpu.destroyBuffer(self.quads);
            gpu.destroyBuffer(self.glyph_quads);
            gpu.destroyBuffer(self.globals);
        }

        /// Texture in: makes a view usable as `Style.texture`. The view can be
        /// anything you rendered or loaded; the renderer only samples it.
        pub fn addTexture(self: *Self, device: gpu.Device, view: gpu.TextureView, sampler: gpu.Sampler) ui.Texture {
            const i = @min(self.texture_count, max_textures - 1);
            self.textures[i] = gpu.textureBindGroup(device, view, sampler);
            self.texture_count = i + 1;
            return @fromBackingInt(i);
        }

        /// A quad pipeline with your fragment logic. Build `wgsl` with `shader`.
        pub fn addMaterial(self: *Self, device: gpu.Device, wgsl: [:0]const u8) ui.Material {
            const i = @min(self.material_count, max_materials - 1);
            self.pipelines[i] = gpu.createPipeline(device, &.{
                .wgsl = wgsl,
                .format = self.desc.format,
                .sample_count = self.desc.sample_count,
            });
            self.material_count = i + 1;
            return @fromBackingInt(i);
        }

        /// Uploads the frame: one write per buffer. Call before the render
        /// pass begins; the encoder is locked while a pass is open.
        pub fn prepare(self: *Self, queue: gpu.Queue, draw: *const ui.DrawList, glyphs: Glyphs, viewport: [2]f32, scale: f32) void {
            const quad_bytes = draw.quadBytes();
            const glyph_bytes = std.mem.sliceAsBytes(glyphs.quads);
            gpu.writeBuffer(queue, self.quads, 0, quad_bytes[0..@min(quad_bytes.len, @as(usize, self.desc.max_quads) * quad_stride)]);
            gpu.writeBuffer(queue, self.glyph_quads, 0, glyph_bytes[0..@min(glyph_bytes.len, @as(usize, self.desc.max_glyphs) * quad_stride)]);
            gpu.writeBuffer(queue, self.globals, 0, std.mem.asBytes(&Globals{ .viewport = viewport, .scale = scale }));
            self.glyphs = glyphs;
        }

        fn bind(self: *const Self, pass: gpu.RenderPass, material: ui.Material, texture: ui.Texture, instances: gpu.Buffer, size: u64) void {
            // Handles are clamped rather than checked: a stale handle draws
            // with the last valid entry instead of indexing out of bounds.
            gpu.setPipeline(pass, self.pipelines[@min(@backingInt(material), self.material_count - 1)]);
            gpu.setBindGroup(pass, 0, self.globals_group);
            gpu.setBindGroup(pass, 1, self.textures[@min(@backingInt(texture), self.texture_count - 1)]);
            gpu.setVertexBuffer(pass, 0, instances, 0, size);
        }

        /// One instanced draw call for a run of quads.
        pub fn drawBatch(self: *const Self, pass: gpu.RenderPass, batch: ui.Batch) void {
            self.bind(pass, batch.material, batch.texture, self.quads, @as(u64, self.desc.max_quads) * quad_stride);
            gpu.draw(pass, 4, batch.count, 0, batch.first);
        }

        /// One instanced draw call for a text run's glyphs.
        pub fn drawText(self: *const Self, pass: gpu.RenderPass, run: u32) void {
            const count = self.glyphs.count[run];
            self.bind(pass, .solid, self.glyphs.texture, self.glyph_quads, @as(u64, self.desc.max_glyphs) * quad_stride);
            gpu.draw(pass, 4, count, 0, self.glyphs.first[run]);
        }

        /// Diagonal: the whole list, skipping custom draws. If you have custom
        /// draws, write this loop yourself and add your own case:
        ///
        ///     .custom => |k| scene.draw(pass, draw.customs[k].rect, draw.customs[k].clip),
        pub fn render(self: *const Self, pass: gpu.RenderPass, draw: *const ui.DrawList) void {
            for (0..draw.cmd_len) |i| switch (draw.command(@intCast(i))) {
                .quads => |batch| self.drawBatch(pass, batch),
                .text => |run| self.drawText(pass, run),
                .custom => {},
            };
        }
    };
}

// ============================================================================
// Shader
// ============================================================================

/// The stock material: fill colour times the bound texture.
pub const default_material =
    \\fn material(in: Frag) -> vec4f {
    \\    return in.fill * textureSample(tex, samp, in.uv);
    \\}
    \\
;

/// Full quad shader around your `fn material(in: Frag) -> vec4f`.
/// `in.params` carries `Style.params`; `in.local` is the pixel offset from the
/// quad's centre and `in.half` its half size, both in logical pixels.
pub fn shader(comptime material_fn: []const u8) [:0]const u8 {
    return shader_head ++ material_fn ++ shader_tail;
}

const shader_head =
    \\struct Globals { viewport: vec2f, scale: f32, pad: f32 }
    \\@group(0) @binding(0) var<uniform> globals: Globals;
    \\@group(1) @binding(0) var tex: texture_2d<f32>;
    \\@group(1) @binding(1) var samp: sampler;
    \\
    \\struct Instance {
    \\    @location(0) rect: vec4f,
    \\    @location(1) clip: vec4f,
    \\    @location(2) params: vec4f,
    \\    @location(3) uv: vec4f,
    \\    @location(4) fill: vec4f,
    \\    @location(5) border_color: vec4f,
    \\    @location(6) radius_border: vec2f,
    \\}
    \\
    \\struct Frag {
    \\    @builtin(position) position: vec4f,
    \\    @location(0) local: vec2f,
    \\    @location(1) uv: vec2f,
    \\    @location(2) pixel: vec2f,
    \\    @location(3) @interpolate(flat) half: vec2f,
    \\    @location(4) @interpolate(flat) radius_border: vec2f,
    \\    @location(5) @interpolate(flat) fill: vec4f,
    \\    @location(6) @interpolate(flat) border_color: vec4f,
    \\    @location(7) @interpolate(flat) clip: vec4f,
    \\    @location(8) @interpolate(flat) params: vec4f,
    \\}
    \\
    \\@vertex
    \\fn vs(@builtin(vertex_index) vi: u32, inst: Instance) -> Frag {
    \\    // Triangle strip: (0,0) (1,0) (0,1) (1,1).
    \\    let corner = vec2f(f32(vi & 1u), f32(vi >> 1u));
    \\    let p = mix(inst.rect.xy, inst.rect.zw, corner);
    \\    var out: Frag;
    \\    out.position = vec4f(p / globals.viewport * vec2f(2.0, -2.0) + vec2f(-1.0, 1.0), 0.0, 1.0);
    \\    out.local = p - (inst.rect.xy + inst.rect.zw) * 0.5;
    \\    out.uv = mix(inst.uv.xy, inst.uv.zw, corner);
    \\    out.pixel = p;
    \\    out.half = (inst.rect.zw - inst.rect.xy) * 0.5;
    \\    out.radius_border = inst.radius_border;
    \\    out.fill = inst.fill;
    \\    out.border_color = inst.border_color;
    \\    out.clip = inst.clip;
    \\    out.params = inst.params;
    \\    return out;
    \\}
    \\
    \\fn rounded_box(p: vec2f, half: vec2f, r: f32) -> f32 {
    \\    let q = abs(p) - half + vec2f(r);
    \\    return length(max(q, vec2f(0.0))) + min(max(q.x, q.y), 0.0) - r;
    \\}
    \\
    \\
;

const shader_tail =
    \\
    \\@fragment
    \\fn fs(in: Frag) -> @location(0) vec4f {
    \\    let r = min(in.radius_border.x, min(in.half.x, in.half.y));
    \\    let d = rounded_box(in.local, in.half, r) * globals.scale;
    \\    // Coverage instead of discard: one physical pixel of antialiasing, no branch.
    \\    let shape = clamp(0.5 - d, 0.0, 1.0);
    \\    let inner = clamp(0.5 - (d + in.radius_border.y * globals.scale), 0.0, 1.0);
    \\    let has_border = step(0.001, in.radius_border.y);
    \\    let color = mix(in.border_color, material(in), mix(1.0, inner, has_border));
    \\    // Per-instance clip, also as coverage.
    \\    let inside = step(in.clip.xy, in.pixel) * step(in.pixel, in.clip.zw);
    \\    let alpha = shape * inside.x * inside.y;
    \\    return vec4f(color.rgb * color.a, color.a) * alpha;
    \\}
    \\
;

// ============================================================================
// Tests: a recording binding stands in for wgpu
// ============================================================================

const Mock = struct {
    pub const Device = *Log;
    pub const Queue = *Log;
    pub const RenderPass = *Log;
    pub const Buffer = u32;
    pub const Pipeline = u32;
    pub const BindGroup = u32;
    pub const TextureView = u32;
    pub const Sampler = u32;
    pub const TextureFormat = enum { bgra8unorm };

    const Call = union(enum) {
        pipeline: u32,
        group: struct { index: u32, group: u32 },
        vertex_buffer: struct { buffer: u32, size: u64 },
        draw: struct { vertices: u32, instances: u32, first_instance: u32 },
        write: struct { buffer: u32, bytes: usize },
    };
    const Log = struct {
        calls: [256]Call = undefined,
        len: usize = 0,
        next_handle: u32 = 100,
        fn push(l: *Log, c: Call) void {
            l.calls[l.len] = c;
            l.len += 1;
        }
        fn handle(l: *Log) u32 {
            l.next_handle += 1;
            return l.next_handle;
        }
    };

    pub fn createBuffer(d: Device, size: u64, use: BufferUse) Buffer {
        _ = size;
        _ = use;
        return d.handle();
    }
    pub fn destroyBuffer(b: Buffer) void {
        _ = b;
    }
    pub fn writeBuffer(q: Queue, b: Buffer, offset: u64, bytes: []const u8) void {
        _ = offset;
        q.push(.{ .write = .{ .buffer = b, .bytes = bytes.len } });
    }
    pub fn createPipeline(d: Device, desc: *const Renderer(Mock).PipelineDesc) Pipeline {
        std.debug.assert(desc.instance_stride == 80 and desc.attrs.len == 7);
        return d.handle();
    }
    pub fn globalsBindGroup(d: Device, b: Buffer) BindGroup {
        _ = b;
        return d.handle();
    }
    pub fn textureBindGroup(d: Device, v: TextureView, s: Sampler) BindGroup {
        _ = v;
        _ = s;
        return d.handle();
    }
    pub fn setPipeline(p: RenderPass, pipe: Pipeline) void {
        p.push(.{ .pipeline = pipe });
    }
    pub fn setBindGroup(p: RenderPass, index: u32, g: BindGroup) void {
        p.push(.{ .group = .{ .index = index, .group = g } });
    }
    pub fn setVertexBuffer(p: RenderPass, slot: u32, b: Buffer, offset: u64, size: u64) void {
        _ = slot;
        _ = offset;
        p.push(.{ .vertex_buffer = .{ .buffer = b, .size = size } });
    }
    pub fn draw(p: RenderPass, vertices: u32, instances: u32, first_vertex: u32, first_instance: u32) void {
        _ = first_vertex;
        p.push(.{ .draw = .{ .vertices = vertices, .instances = instances, .first_instance = first_instance } });
    }
};

const test_limits: ui.Limits = .{ .nodes = 64, .texts = 16 };
var test_buffer: [ui.Context.requiredBytes(test_limits)]u8 align(ui.mem.column_align) = undefined;

test "renderer: one upload per buffer, one draw per command, state rebound every time" {
    const Gfx = Renderer(Mock);
    var log: Mock.Log = .{};
    var gfx = Gfx.init(&log, .{ .format = .bgra8unorm }, 1, 2);
    defer gfx.deinit();
    const checker = gfx.addTexture(&log, 7, 2);
    const atlas = gfx.addTexture(&log, 8, 2);

    // A frame: panel, textured quad, a label, a custom draw, another quad.
    var ctx = try ui.Context.init(&test_buffer, test_limits);
    const in: ui.Input = .{ .viewport = .{ 200, 100 } };
    var f = ctx.begin(&in);
    _ = f.open(.none, .{ .pad = @splat(4), .gap = 4, .fill = ui.Color.rgb(20, 20, 20) });
    _ = f.leaf(.none, .{ .size = .{ .px(16), .px(16) }, .fill = .white, .texture = checker });
    _ = f.text("hi", .{});
    _ = f.custom(ui.Id.from("scene"), .{ .size = .{ .px(32), .px(32) } }, 42);
    _ = f.leaf(.none, .{ .size = .{ .px(8), .px(8) }, .fill = .white });
    f.close();
    const out = f.end(.{});

    var glyph_quads: [16]ui.Quad = undefined;
    var first: [16]u32 = undefined;
    var count: [16]u32 = undefined;
    const font: ui.fonts.Mono = .{};
    const n = font.quads(out.draw, &glyph_quads, .{ .first = &first, .count = &count });
    try std.testing.expectEqual(@as(u32, 2), n);

    gfx.prepare(&log, out.draw, .{ .quads = glyph_quads[0..n], .first = &first, .count = &count, .texture = atlas }, in.viewport, in.scale);
    try std.testing.expectEqual(@as(usize, 3), log.len);
    try std.testing.expectEqual(@as(usize, 3 * @sizeOf(ui.Quad)), log.calls[0].write.bytes);
    try std.testing.expectEqual(@as(usize, 2 * @sizeOf(ui.Quad)), log.calls[1].write.bytes);
    try std.testing.expectEqual(@as(usize, @sizeOf(Globals)), log.calls[2].write.bytes);

    // The host's command loop, with its own case for the custom draw.
    log.len = 0;
    var customs: u32 = 0;
    for (0..out.draw.cmd_len) |i| switch (out.draw.command(@intCast(i))) {
        .quads => |batch| gfx.drawBatch(&log, batch),
        .text => |run| gfx.drawText(&log, run),
        .custom => |k| {
            customs += 1;
            try std.testing.expectEqual(@as(u64, 42), out.draw.customs[k].data);
        },
    };
    try std.testing.expectEqual(@as(u32, 1), customs);

    // panel | textured quad | text | (custom) | quad  =>  4 draws, 5 calls each.
    var draws: [8]Mock.Call = undefined;
    var draw_count: usize = 0;
    for (log.calls[0..log.len]) |call| switch (call) {
        .draw => {
            draws[draw_count] = call;
            draw_count += 1;
        },
        else => {},
    };
    try std.testing.expectEqual(@as(usize, 4), draw_count);
    try std.testing.expectEqual(@as(usize, 4 * 5), log.len);
    try std.testing.expectEqual(@as(u32, 4), draws[0].draw.vertices);
    try std.testing.expectEqual(@as(u32, 1), draws[0].draw.instances); // panel
    try std.testing.expectEqual(@as(u32, 1), draws[1].draw.first_instance); // textured quad
    try std.testing.expectEqual(@as(u32, 2), draws[2].draw.instances); // "hi"
    try std.testing.expectEqual(@as(u32, 2), draws[3].draw.first_instance); // quad after the custom draw

    // The diagonal issues the same draws and skips the custom one.
    log.len = 0;
    gfx.render(&log, out.draw);
    try std.testing.expectEqual(@as(usize, 4 * 5), log.len);
}

test "shader source is assembled at comptime" {
    const src = comptime shader(default_material);
    try std.testing.expect(std.mem.indexOf(u8, src, "fn material(in: Frag)") != null);
    try std.testing.expect(std.mem.indexOf(u8, src, "@fragment") != null);
}
