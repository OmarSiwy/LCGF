//! The wgpu back end: draws a `DrawList` with wgpu. Ported from prototype/ui_wgpu.zig
//! `Renderer(gpu)`.
//!
//! Generic over the wgpu binding so this file depends on none:
//!
//!     const Gfx = @import("wgpu.zig").Renderer(my_binding);
//!
//! `my_binding` is a namespace of about a dozen thin functions over whatever you use
//! (wgpu-native through translated C headers, zgpu, ...); `Binding` lists them. The indirection
//! exists because bindings differ and the wgpu C API still changes between releases.
//!
//! WHO OWNS WHAT
//!   You:       device, queue, surface, encoder, render pass, render target.
//!   Renderer:  two instance buffers, one uniform buffer, pipelines and bind groups it created
//!              from your device.
//!
//! RAW GPU ACCESS, all of which follows from you owning the pass:
//!   under / over  draw before or after the UI commands
//!   inline        `Cmd.custom` in the command loop (`iface.drawUntilCustom`): your own draws
//!   texture in    `addTexture(view)`, then `Style.texture`
//!   texture out   point the pass at any texture view
//!   materials     `addMaterial(quad_shader.shader(your_wgsl_fn))`, then `Style.material`
//!
//! `drawBatch` and `drawText` set every piece of pass state they depend on, so a custom draw may
//! leave the pass in any state (src/render/iface.zig, "Full state rebinding").

const std = @import("std");
const types = @import("../../core/types.zig");
const draw_list = @import("../../draw/draw_list.zig");
const quad_shader = @import("../shaders/quad.zig");
const canvas_shader = @import("../shaders/canvas.zig");
const canvas_pipeline = @import("../gpu/canvas.zig");
const iface = @import("../iface.zig");
const DrawList = draw_list.DrawList;
const Quad = draw_list.Quad;

pub const BufferUse = enum { vertex, uniform };
pub const AttrFormat = enum { float32, float32x2, float32x4, uint32x4, unorm8x4 };
pub const Attr = struct { location: u32, offset: u32, format: AttrFormat };

/// Per-instance vertex layout of `Quad`, from src/render/shaders/quad.zig `attrs` so the shader,
/// the dumpers and this back end cannot drift.
pub const quad_stride: u32 = quad_shader.stride;
pub const quad_attrs: [quad_shader.attrs.len]Attr = blk: {
    @setEvalBranchQuota(10_000);
    var out: [quad_shader.attrs.len]Attr = undefined;
    for (quad_shader.attrs, &out) |a, *o| o.* = .{
        .location = a.location,
        .offset = a.offset,
        .format = std.meta.stringToEnum(AttrFormat, a.format) orelse @compileError("unknown vertex format " ++ a.format),
    };
    break :blk out;
};

/// Group 0, binding 0.
pub const Globals = @import("../null.zig").Globals;

pub const Glyphs = iface.Glyphs;

/// The functions and types `Renderer(gpu)` uses. This struct is documentation; `Renderer`
/// checks the names at compile time.
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
///        triangle strip, no depth, premultiplied-alpha blending (one, one-minus-src-alpha), one
///        vertex buffer stepped per instance with `desc.attrs`. Bind group layouts must be the
///        same objects for every pipeline:  group 0 = uniform buffer (vertex + fragment),
///                                          group 1 = texture_2d<f32> + filtering sampler (fragment).
///   fn globalsBindGroup(Device, Buffer) BindGroup
///   fn textureBindGroup(Device, TextureView, Sampler) BindGroup
///   fn releaseBindGroup(BindGroup) void
///   fn setPipeline(RenderPass, Pipeline) void
///   fn setBindGroup(RenderPass, index: u32, BindGroup) void
///   fn setVertexBuffer(RenderPass, slot: u32, Buffer, offset: u64, size: u64) void
///   fn draw(RenderPass, vertices: u32, instances: u32, first_vertex: u32, first_instance: u32) void
///
///   Optional, for canvases: `canvas`, a namespace with `projection` (this binding's
///   lcgf_render.gpu, P) and `fn device(Device, ?Queue) P.Device`, `fn format(TextureFormat)
///   P.TextureFormat`, `fn view(TextureView) P.TextureView`, `fn upload(P.Device) P.Upload`.
pub const Binding = struct {
    pub const types = [_][]const u8{ "Device", "Queue", "RenderPass", "Buffer", "Pipeline", "BindGroup", "TextureView", "Sampler", "TextureFormat" };
    pub const functions = [_][]const u8{ "createBuffer", "destroyBuffer", "writeBuffer", "createPipeline", "globalsBindGroup", "textureBindGroup", "releaseBindGroup", "setPipeline", "setBindGroup", "setVertexBuffer", "draw" };
};

pub fn Renderer(comptime gpu: type) type {
    comptime {
        for (Binding.types ++ Binding.functions) |name| {
            if (!@hasDecl(gpu, name)) @compileError("wgpu binding is missing `" ++ name ++ "`; see render/wgpu/wgpu.zig Binding");
        }
    }

    return struct {
        const Self = @This();
        /// The canvas pipeline, through the binding's lcgf_render.gpu (src/render/gpu/canvas.zig).
        const cb = if (@hasDecl(gpu, "canvas")) gpu.canvas else null;
        pub const Canvas = if (@TypeOf(cb) == @TypeOf(null)) void else canvas_pipeline.Canvas(cb.projection, struct {
            pub const wgsl = canvas_shader.wgsl;
        });

        pub const Queue = gpu.Queue;
        pub const Pass = gpu.RenderPass;

        pub const max_textures = 64;
        pub const max_materials = quad_shader.max_materials;

        pub const Desc = struct {
            /// Format of the target the render pass draws into.
            format: gpu.TextureFormat,
            sample_count: u32 = 1,
            max_quads: u32 = 16 * 1024,
            max_glyphs: u32 = 32 * 1024,
            /// Canvas instance rows and polygon vertices kept on the GPU (32 and 8 bytes each);
            /// 0 rows: no canvas pipeline, and canvases draw nothing. Needs a binding with
            /// `canvas` (see `Binding`).
            canvas_rows: u32 = 0,
            canvas_verts: u32 = 0,
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
        /// The views behind `textures`, for the canvas pipeline's glyph atlas.
        views: [max_textures]gpu.TextureView = undefined,
        texture_count: u16 = 0,
        glyphs: Glyphs = .{},
        canvas: if (Canvas == void) void else ?Canvas = if (Canvas == void) {} else null,
        device: gpu.Device,
        list: ?*const DrawList = null,
        /// Physical pixels: viewport * scale from the last `prepare`.
        extent: [2]u32 = .{ 0, 0 },

        /// `white` is a 1x1 opaque white texture; it becomes `Texture.white`.
        pub fn init(device: gpu.Device, desc: Desc, white: gpu.TextureView, sampler: gpu.Sampler) Self {
            return initFor(.all, device, desc, white, sampler);
        }

        pub fn initFor(comptime use: @import("../../draw/features.zig").Usage, device: gpu.Device, desc: Desc, white: gpu.TextureView, sampler: gpu.Sampler) Self {
            const globals = gpu.createBuffer(device, @sizeOf(Globals), .uniform);
            var self: Self = .{
                .desc = desc,
                .quads = gpu.createBuffer(device, @as(u64, desc.max_quads) * quad_stride, .vertex),
                .glyph_quads = gpu.createBuffer(device, @as(u64, desc.max_glyphs) * quad_stride, .vertex),
                .globals = globals,
                .globals_group = gpu.globalsBindGroup(device, globals),
                .device = device,
            };
            _ = self.addMaterial(device, quad_shader.stockFor(use)); // Material.solid
            _ = self.addTexture(device, white, sampler); // Texture.white
            if (Canvas != void and desc.canvas_rows > 0) {
                // ponytail: a canvas pipeline that fails to build leaves canvases undrawn, as
                // init has no error to return.
                var cv: Canvas = undefined;
                if (cv.init(cb.device(device, null), .{ .format = cb.format(desc.format), .samples = desc.sample_count }, .{ .rows = desc.canvas_rows, .verts = desc.canvas_verts })) |_| {
                    self.canvas = cv;
                } else |_| {}
            }
            return self;
        }

        pub fn deinit(self: *Self) void {
            if (Canvas != void) if (self.canvas) |*cv| cv.deinit(cb.device(self.device, null));
            gpu.destroyBuffer(self.quads);
            gpu.destroyBuffer(self.glyph_quads);
            gpu.destroyBuffer(self.globals);
            gpu.releaseBindGroup(self.globals_group);
            for (self.textures[0..self.texture_count]) |g| gpu.releaseBindGroup(g);
        }

        /// Texture in: makes a view usable as `Style.texture`. The view can be anything you
        /// rendered or loaded; the renderer only samples it, and keeps only a bind group: the
        /// texture and view stay yours, alive while a frame may sample them. Handles are
        /// indices in registration order; `Texture.white` is 0. Past `max_textures` the last
        /// entry is replaced, as the prototype does.
        pub fn addTexture(self: *Self, device: gpu.Device, view: gpu.TextureView, sampler: gpu.Sampler) types.Texture {
            const i: u16 = @min(self.texture_count, max_textures - 1);
            if (i < self.texture_count) gpu.releaseBindGroup(self.textures[i]);
            self.textures[i] = gpu.textureBindGroup(device, view, sampler);
            self.views[i] = view;
            self.texture_count = i + 1;
            return @fromBackingInt(i);
        }

        /// Points an existing handle at another view: a render target recreated at a new size,
        /// an atlas that grew. Nodes keep their `Style.texture`. A stale handle clamps to the
        /// last entry, as in `bind`.
        pub fn setTexture(self: *Self, device: gpu.Device, texture: types.Texture, view: gpu.TextureView, sampler: gpu.Sampler) void {
            const i = @min(@backingInt(texture), self.texture_count - 1);
            gpu.releaseBindGroup(self.textures[i]);
            self.textures[i] = gpu.textureBindGroup(device, view, sampler);
            self.views[i] = view;
        }

        /// A quad pipeline with your fragment logic. Build `wgsl` with `quad_shader.shader`.
        pub fn addMaterial(self: *Self, device: gpu.Device, wgsl: [:0]const u8) types.Material {
            const i: u16 = @min(self.material_count, max_materials - 1);
            self.pipelines[i] = gpu.createPipeline(device, &.{
                .wgsl = wgsl,
                .format = self.desc.format,
                .sample_count = self.desc.sample_count,
            });
            self.material_count = i + 1;
            return @fromBackingInt(i);
        }

        /// Uploads the frame: one write per buffer. Call before the render pass begins; the
        /// encoder is locked while a pass is open.
        pub fn prepare(self: *Self, queue: gpu.Queue, draw: *const DrawList, glyphs: Glyphs, viewport: [2]f32, scale: f32) void {
            const quad_bytes = draw.quadBytes();
            gpu.writeBuffer(queue, self.quads, 0, quad_bytes[0..@min(quad_bytes.len, @as(usize, self.desc.max_quads) * quad_stride)]);
            self.prepareFrame(queue, glyphs, viewport, scale);
            self.prepareCanvas(queue, draw, scale);
        }

        /// Upload the rows touched since the last frame on this buffer. Pass the full dirty
        /// mask from Patches.rebuild after layout, or when this buffer first receives the UI.
        /// The caller clears the mask after all consumers have uploaded it.
        pub fn preparePatched(self: *Self, queue: gpu.Queue, draw: *const DrawList, glyphs: Glyphs, viewport: [2]f32, scale: f32, dirty: anytype) void {
            const limit = @min(draw.quad_len, self.desc.max_quads);
            var it = dirty.iterator(.{});
            var next = it.next();
            while (next) |first| {
                if (first >= limit) break;
                var end = first + 1;
                next = it.next();
                while (next == end and end < limit) : (next = it.next()) end += 1;
                gpu.writeBuffer(queue, self.quads, first * quad_stride, std.mem.sliceAsBytes(draw.quads[first..end]));
            }
            self.prepareFrame(queue, glyphs, viewport, scale);
            self.prepareCanvas(queue, draw, scale);
        }

        fn prepareFrame(self: *Self, queue: gpu.Queue, glyphs: Glyphs, viewport: [2]f32, scale: f32) void {
            const glyph_bytes = std.mem.sliceAsBytes(glyphs.quads);
            gpu.writeBuffer(queue, self.glyph_quads, 0, glyph_bytes[0..@min(glyph_bytes.len, @as(usize, self.desc.max_glyphs) * quad_stride)]);
            gpu.writeBuffer(queue, self.globals, 0, std.mem.asBytes(&Globals{ .viewport = viewport, .scale = scale }));
            self.glyphs = glyphs;
            self.extent = .{ @intFromFloat(@round(viewport[0] * scale)), @intFromFloat(@round(viewport[1] * scale)) };
        }

        fn prepareCanvas(self: *Self, queue: gpu.Queue, draw: *const DrawList, scale: f32) void {
            self.list = draw;
            if (Canvas == void) return;
            const cv = if (self.canvas) |*cv| cv else return;
            const dev = cb.device(self.device, queue);
            var up = cb.upload(dev);
            const atlas = @min(@backingInt(self.glyphs.texture), self.texture_count - 1);
            cv.prepare(dev, &up, draw, 0, scale, self.extent, cb.view(self.views[atlas]), atlas);
        }

        /// Canvas command `k` (`iface.drawsCanvas`): one instanced draw per range, with the
        /// canvas pipeline, scissored to the node. Needs `Desc.canvas_rows`; the host calls
        /// `Instances.clearDirty` after `prepare` (src/render/gpu/canvas.zig).
        pub fn drawCanvas(self: *const Self, pass: gpu.RenderPass, k: u32) void {
            if (Canvas == void) return;
            const cv = if (self.canvas) |*cv| cv else return;
            var p = cb.projection.RenderPass.wrap(cb.device(self.device, null), pass, self.extent[0], self.extent[1]);
            cv.draw(&p, self.list.?, k);
        }

        fn bind(self: *const Self, pass: gpu.RenderPass, material: types.Material, texture: types.Texture, instances: gpu.Buffer, size: u64) void {
            // Handles are clamped rather than checked: a stale handle draws with the last valid
            // entry instead of indexing out of bounds.
            gpu.setPipeline(pass, self.pipelines[@min(@backingInt(material), self.material_count - 1)]);
            gpu.setBindGroup(pass, 0, self.globals_group);
            gpu.setBindGroup(pass, 1, self.textures[@min(@backingInt(texture), self.texture_count - 1)]);
            gpu.setVertexBuffer(pass, 0, instances, 0, size);
        }

        /// One instanced draw call for a run of quads.
        pub fn drawBatch(self: *const Self, pass: gpu.RenderPass, batch: draw_list.Batch) void {
            self.bind(pass, batch.material, batch.texture, self.quads, @as(u64, self.desc.max_quads) * quad_stride);
            gpu.draw(pass, 4, batch.count, 0, batch.first);
        }

        /// One instanced draw call for a text run's glyphs.
        pub fn drawText(self: *const Self, pass: gpu.RenderPass, run: u32) void {
            self.drawGlyphSpan(pass, self.glyphs.span(run));
        }

        /// The `span[1]` glyph quads from `span[0]`: consecutive text runs in one
        /// draw (`iface.drawUntilCustom`).
        pub fn drawGlyphSpan(self: *const Self, pass: gpu.RenderPass, span: [2]u32) void {
            self.bind(pass, .solid, self.glyphs.texture, self.glyph_quads, @as(u64, self.desc.max_glyphs) * quad_stride);
            gpu.draw(pass, 4, span[1], 0, span[0]);
        }

        /// Diagonal: the whole list, skipping custom draws. With custom draws, loop with
        /// `iface.drawUntilCustom` and draw each one yourself.
        pub fn render(self: *const Self, pass: gpu.RenderPass, draw: *const DrawList) void {
            iface.render(self, pass, draw);
        }
    };
}

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
        write: struct { buffer: u32, offset: u64, bytes: usize },
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
        q.push(.{ .write = .{ .buffer = b, .offset = offset, .bytes = bytes.len } });
    }
    pub fn createPipeline(d: Device, desc: *const Renderer(Mock).PipelineDesc) Pipeline {
        std.debug.assert(desc.instance_stride == 136 and desc.attrs.len == 12);
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
    pub fn releaseBindGroup(g: BindGroup) void {
        _ = g;
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

const testing = std.testing;
const conformance = @import("../conformance.zig");

comptime {
    iface.check(Renderer(Mock));
}

test "renderer: one upload per buffer, one draw per command, state rebound every time" {
    const Gfx = Renderer(Mock);
    var log: Mock.Log = .{};
    var gfx = Gfx.init(&log, .{ .format = .bgra8unorm }, 1, 2);
    defer gfx.deinit();
    const checker = gfx.addTexture(&log, 7, 2);
    const atlas = gfx.addTexture(&log, 8, 2);
    try testing.expectEqual(@as(u16, 1), @backingInt(checker));
    try testing.expectEqual(@as(u16, 2), @backingInt(atlas));

    // The conformance frame with text: quad | "UI!" | "Hello" | quad.
    var st: conformance.Storage = .{};
    const scene = &conformance.scenes[2];
    try testing.expectEqualStrings("text", scene.name);
    st.load(scene);
    var glyphs = st.glyphs();
    glyphs.texture = atlas;

    gfx.prepare(&log, &st.draw, glyphs, scene.viewport, 1);
    try testing.expectEqual(@as(usize, 3), log.len);
    try testing.expectEqual(@as(usize, 2 * @sizeOf(Quad)), log.calls[0].write.bytes);
    try testing.expectEqual(@as(usize, 8 * @sizeOf(Quad)), log.calls[1].write.bytes);
    try testing.expectEqual(@as(usize, @sizeOf(Globals)), log.calls[2].write.bytes);

    // 3 draws (the two text runs are adjacent: one), 5 calls each: pipeline, group 0, group 1,
    // vertex buffer, draw.
    log.len = 0;
    gfx.render(&log, &st.draw);
    try testing.expectEqual(@as(usize, 3 * 5), log.len);
    var draws: [8]Mock.Call = undefined;
    var draw_count: usize = 0;
    for (log.calls[0..log.len]) |call| switch (call) {
        .draw => {
            draws[draw_count] = call;
            draw_count += 1;
        },
        else => {},
    };
    try testing.expectEqual(@as(usize, 3), draw_count);
    for (draws[0..3]) |d| try testing.expectEqual(@as(u32, 4), d.draw.vertices);
    try testing.expectEqual(@as(u32, 1), draws[0].draw.instances); // panel
    try testing.expectEqual(@as(u32, 8), draws[1].draw.instances); // "UI!" and "Hello"
    try testing.expectEqual(@as(u32, 0), draws[1].draw.first_instance);
    try testing.expectEqual(@as(u32, 1), draws[2].draw.first_instance); // the bar after the text
    // Text binds the atlas (group 1) and the glyph buffer; quads bind white and the quad buffer.
    try testing.expectEqual(gfx.textures[2], log.calls[5 + 2].group.group);
    try testing.expectEqual(gfx.glyph_quads, log.calls[5 + 3].vertex_buffer.buffer);
    try testing.expectEqual(gfx.textures[0], log.calls[10 + 2].group.group);
    try testing.expectEqual(gfx.quads, log.calls[10 + 3].vertex_buffer.buffer);

    // The host's loop stops at the custom draw and the renderer rebinds everything after it.
    const custom = &conformance.scenes[3];
    try testing.expectEqualStrings("custom", custom.name);
    st.load(custom);
    gfx.prepare(&log, &st.draw, st.glyphs(), custom.viewport, 1);
    log.len = 0;
    var customs: u32 = 0;
    var i = iface.drawUntilCustom(&gfx, &log, &st.draw, 0);
    while (i < st.draw.cmd_len) : (i = iface.drawUntilCustom(&gfx, &log, &st.draw, i + 1)) {
        try testing.expectEqual(@as(u64, 7), st.draw.customs[st.draw.command(i).custom].data);
        try testing.expectEqual(@as(usize, 5), log.len);
        customs += 1;
    }
    try testing.expectEqual(@as(u32, 1), customs);
    try testing.expectEqual(@as(usize, 2 * 5), log.len);
    try testing.expectEqual(gfx.pipelines[0], log.calls[5].pipeline);
}

test "renderer: stale handles clamp to the last registered entry" {
    var log: Mock.Log = .{};
    var gfx = Renderer(Mock).init(&log, .{ .format = .bgra8unorm }, 1, 2);
    defer gfx.deinit();
    log.len = 0;
    gfx.drawBatch(&log, .{ .first = 0, .count = 1, .texture = @fromBackingInt(9), .material = @fromBackingInt(9) });
    try testing.expectEqual(gfx.pipelines[0], log.calls[0].pipeline);
    try testing.expectEqual(gfx.textures[0], log.calls[2].group.group);
    for (0..Renderer(Mock).max_textures + 2) |_| _ = gfx.addTexture(&log, 3, 2);
    try testing.expectEqual(@as(u16, Renderer(Mock).max_textures), gfx.texture_count);
}

test "renderer: setTexture keeps the handle and rebinds it to the new view" {
    var log: Mock.Log = .{};
    var gfx = Renderer(Mock).init(&log, .{ .format = .bgra8unorm }, 1, 2);
    defer gfx.deinit();
    const t = gfx.addTexture(&log, 7, 2);
    const old = gfx.textures[1];
    gfx.setTexture(&log, t, 8, 2);
    try testing.expectEqual(@as(u16, 2), gfx.texture_count);
    try testing.expect(gfx.textures[1] != old);
    log.len = 0;
    gfx.drawBatch(&log, .{ .first = 0, .count = 1, .texture = t, .material = .solid });
    try testing.expectEqual(gfx.textures[1], log.calls[2].group.group);
}

test "quad_attrs follow the shader's layout of Quad" {
    try testing.expectEqual(@as(u32, @sizeOf(Quad)), quad_stride);
    for (quad_shader.attrs, quad_attrs) |a, b| {
        try testing.expectEqual(a.location, b.location);
        try testing.expectEqual(a.offset, b.offset);
        try testing.expectEqualStrings(a.format, @tagName(b.format));
    }
}

test "renderer: patched uploads coalesce adjacent rows, cap ranges and skip clean frames" {
    var log: Mock.Log = .{};
    var gfx = Renderer(Mock).init(&log, .{ .format = .bgra8unorm, .max_quads = 5 }, 1, 2);
    defer gfx.deinit();
    var rows: [8]Quad = undefined;
    var draw: DrawList = undefined;
    draw.quads = &rows;
    draw.quad_len = rows.len;
    const Dirty = std.bit_set.Static(8);
    var dirty: Dirty = .empty;
    for ([_]usize{ 1, 2, 4, 5, 6 }) |i| dirty.set(i);
    gfx.preparePatched(&log, &draw, .{}, .{ 100, 100 }, 1, &dirty);
    try testing.expectEqual(4, log.len);
    try testing.expectEqual(gfx.quads, log.calls[0].write.buffer);
    try testing.expectEqual(quad_stride, log.calls[0].write.offset);
    try testing.expectEqual(2 * quad_stride, log.calls[0].write.bytes);
    try testing.expectEqual(4 * quad_stride, log.calls[1].write.offset);
    try testing.expectEqual(quad_stride, log.calls[1].write.bytes);
    log.len = 0;
    dirty = .full;
    draw.quad_len = 3;
    gfx.preparePatched(&log, &draw, .{}, .{ 100, 100 }, 1, &dirty);
    try testing.expectEqual(3, log.len);
    try testing.expectEqual(3 * quad_stride, log.calls[0].write.bytes);
    log.len = 0;
    dirty = .empty;
    gfx.preparePatched(&log, &draw, .{}, .{ 100, 100 }, 1, &dirty);
    try testing.expectEqual(2, log.len);
    try testing.expectEqual(gfx.glyph_quads, log.calls[0].write.buffer);
    try testing.expectEqual(gfx.globals, log.calls[1].write.buffer);
}
