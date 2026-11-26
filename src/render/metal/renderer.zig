//! The Metal back end proper: draws a `DrawList` into the render command encoder the host
//! opened. Meets the contract in src/render/iface.zig, as the wgpu, Vulkan and GL ES back ends
//! do: `prepare`, `drawBatch`, `drawText`, `render`, one instanced draw (four-vertex strip, one
//! instance per quad) per command.
//!
//! WHO OWNS WHAT
//!   You:       device, queue, layer or target texture, command buffer, render pass and its
//!              encoder, synchronisation and presentation.
//!   Renderer:  the quad pipeline states, one shared instance buffer, the 1x1 white texture
//!              behind `Texture.white` and the nearest sampler textures get by default. Every
//!              texture and sampler you register stays yours.
//!
//! The instance buffer is shared storage the CPU writes in `prepare` and the GPU reads when
//! the command buffer runs, so it holds `frames_in_flight` frames and each `prepare` writes the
//! next one. The host keeps at most that many frames in flight: `present.Frames` with the same
//! count waits for a slot's previous frame before it is reused (call `prepare` once per frame,
//! after `Frames.begin`). A draw that starts at quad `first` points
//! the vertex buffer `first * stride` bytes in, so no base instance is needed; the globals go in
//! with setVertexBytes / setFragmentBytes on every draw.

const std = @import("std");
const builtin = @import("builtin");
const lcgf = @import("lcgf");
const objc = @import("objc.zig");
const mtl = @import("mtl.zig");
const msl = @import("msl.zig");
const pipeline = @import("pipeline.zig");
const texture = @import("texture.zig");
const types = lcgf.types;
const draw_list = lcgf.draw_list;
const quad_shader = lcgf.quad_shader;
const iface = lcgf.render_iface;
const DrawList = draw_list.DrawList;
const Id = objc.Id;
const U = objc.NSUInteger;

pub const Globals = lcgf.render_null.Globals;
pub const Glyphs = iface.Glyphs;
pub const max_materials = quad_shader.max_materials;

pub const Desc = struct {
    /// Format of the targets the passes draw into.
    format: mtl.PixelFormat = .bgra8_unorm,
    sample_count: U = 1,
    max_quads: u32 = 16 * 1024,
    max_glyphs: u32 = 32 * 1024,
    /// Frames the GPU may still be reading while the CPU prepares the next (GPUI uses 3).
    frames_in_flight: u32 = 3,
};

pub const Error = pipeline.Error || texture.Error || error{BufferFailed};

/// The renderer over Metal's encoder.
pub const Renderer = RendererOver(mtl.RenderEncoder);

/// The renderer recording into `Encoder`: `mtl.RenderEncoder`, or a test's recorder with the
/// same methods (the tests below check the call stream without a device).
pub fn RendererOver(comptime Encoder: type) type {
    return struct {
        const Self = @This();

        device: Id,
        desc: Desc,
        pipelines: [max_materials]Id = undefined,
        material_count: u16 = 0,
        /// [quads | glyph quads], rewritten by every `prepare`; `contents` is its CPU mapping.
        instances: ?Id = null,
        contents: [*]u8 = undefined,
        white: ?Id = null,
        sampler: ?Id = null,
        /// Registered textures and the sampler each is drawn with; entry 0 is `white`.
        textures: [max_textures]Id = undefined,
        samplers: [max_textures]Id = undefined,
        texture_count: u16 = 0,
        /// Byte offset of the frame the last `prepare` wrote, and the slot the next one writes.
        base: usize = 0,
        next: u32 = 0,
        /// Physical pixels: viewport * scale from the last `prepare`.
        extent: [2]u32 = .{ 0, 0 },
        scale: f32 = 1,
        globals: Globals = .{ .viewport = .{ 0, 0 }, .scale = 1 },
        glyphs: Glyphs = .{},

        pub const max_textures = 64;
        /// Metal uploads by writing shared memory: nothing to pass.
        pub const Queue = void;
        /// The render command encoder of the host's pass (`mtl.RenderEncoder.id` is the raw
        /// MTLRenderCommandEncoder). At a custom command the host records its own draws into it
        /// (src/render/gpu/gradient.zig); the next UI draw rebinds every piece of state it uses.
        pub const Pass = Encoder;

        pub fn init(device: Id, desc: Desc) Error!Self {
            var r: Self = .{ .device = device, .desc = desc };
            errdefer r.deinit();
            _ = try r.addMaterial(msl.stock); // Material.solid
            const bytes: U = r.frameBytes() * desc.frames_in_flight;
            const buf = objc.msg(?Id, device, "newBufferWithLength:options:", .{ bytes, mtl.resource_shared_write_combined }) orelse return error.BufferFailed;
            r.instances = buf;
            r.contents = objc.msg([*]u8, buf, "contents", .{});
            r.white = try texture.rgba8(device, 1, 1, &.{ 255, 255, 255, 255 });
            r.sampler = try texture.sampler(device, .nearest);
            _ = r.addTexture(r.white.?, null); // Texture.white
            return r;
        }

        pub fn deinit(r: *Self) void {
            for (r.pipelines[0..r.material_count]) |p| objc.release(p);
            r.material_count = 0;
            r.texture_count = 0;
            inline for (.{ "instances", "white", "sampler" }) |name| {
                if (@field(r, name)) |o| objc.release(o);
                @field(r, name) = null;
            }
        }

        /// A quad pipeline with your fragment logic: `quad_shader.shader(your_wgsl_fn)`
        /// translated to MSL (src/render/shaders/translate.sh) and passed through `msl.bind`.
        /// Past `max_materials` the last entry is replaced, as the prototype does.
        pub fn addMaterial(r: *Self, source: [:0]const u8) Error!types.Material {
            const i: u16 = @min(r.material_count, max_materials - 1);
            const p = try pipeline.quad(r.device, source, .{ .format = r.desc.format, .sample_count = r.desc.sample_count });
            if (i < r.material_count) objc.release(r.pipelines[i]);
            r.pipelines[i] = p;
            r.material_count = i + 1;
            return @fromBackingInt(i);
        }

        /// Texture in: makes an MTLTexture usable as `Style.texture` (or as the glyph atlas,
        /// `Glyphs.texture`), drawn with `sampler`, or the renderer's nearest, clamped one when
        /// null. Both stay yours, alive while a frame may sample them. Handles are indices in
        /// registration order; `Texture.white` is 0. Past `max_textures` the last entry is
        /// rewritten, as the prototype does.
        pub fn addTexture(r: *Self, tex: Id, sampler: ?Id) types.Texture {
            const i: u16 = @min(r.texture_count, max_textures - 1);
            r.textures[i] = tex;
            r.samplers[i] = sampler orelse r.sampler.?;
            r.texture_count = i + 1;
            return @fromBackingInt(i);
        }

        /// Points an existing handle at another texture (a target recreated at a new size, an
        /// atlas that grew), keeping its sampler; nodes keep their `Style.texture`. A stale
        /// handle clamps to the last entry.
        pub fn setTexture(r: *Self, handle: types.Texture, tex: Id) void {
            r.textures[@min(@backingInt(handle), r.texture_count - 1)] = tex;
        }

        /// Uploads the frame: both instance arrays into the shared buffer, and the globals the
        /// draws will pass. Quads past `max_quads` (glyphs past `max_glyphs`) are dropped, as
        /// the other back ends do.
        pub fn prepare(r: *Self, _: Queue, draw: *const DrawList, glyphs: Glyphs, viewport: [2]f32, scale: f32) void {
            r.base = r.next * r.frameBytes();
            r.next = (r.next + 1) % r.desc.frames_in_flight;
            const quad_bytes = draw.quadBytes();
            const qn = @min(quad_bytes.len, @as(usize, r.desc.max_quads) * quad_shader.stride);
            @memcpy(r.contents[r.base..][0..qn], quad_bytes[0..qn]);
            const glyph_bytes = std.mem.sliceAsBytes(glyphs.quads);
            const gn = @min(glyph_bytes.len, @as(usize, r.desc.max_glyphs) * quad_shader.stride);
            @memcpy(r.contents[r.glyphsAt()..][0..gn], glyph_bytes[0..gn]);
            r.globals = .{ .viewport = viewport, .scale = scale };
            r.glyphs = glyphs;
            r.scale = scale;
            // The layer's own rounding (device.zig `Layer.resize`), so viewport and scissor match
            // the drawable after a resize or a scale change.
            r.extent = dev_mod.drawableSize(viewport, scale);
        }

        fn frameBytes(r: *const Self) usize {
            return (@as(usize, r.desc.max_quads) + r.desc.max_glyphs) * quad_shader.stride;
        }

        fn glyphsAt(r: *const Self) usize {
            return r.base + @as(usize, r.desc.max_quads) * quad_shader.stride;
        }

        /// Full state, every draw (iface.zig, "Full state rebinding"): pipeline, instances at
        /// `at` bytes, globals for both stages, texture, sampler, viewport, scissor, culling.
        /// Handles are clamped rather than checked: a stale handle draws with the last entry.
        fn bind(r: *const Self, pass: Pass, material: types.Material, tex: types.Texture, at: usize) void {
            const t = @min(@backingInt(tex), r.texture_count - 1);
            const g = std.mem.asBytes(&r.globals);
            pass.setPipeline(r.pipelines[@min(@backingInt(material), r.material_count - 1)]);
            pass.setVertexBuffer(r.instances.?, at, msl.instance_buffer);
            pass.setVertexBytes(g, msl.globals_buffer);
            pass.setFragmentBytes(g, msl.globals_buffer);
            pass.setFragmentTexture(r.textures[t], 0);
            pass.setFragmentSampler(r.samplers[t], 0);
            const w: f64 = @floatFromInt(r.extent[0]);
            const h: f64 = @floatFromInt(r.extent[1]);
            pass.setViewport(.{ .x = 0, .y = 0, .width = w, .height = h });
            pass.setScissor(.{ .x = 0, .y = 0, .width = r.extent[0], .height = r.extent[1] });
            pass.setRaster();
        }

        /// One instanced draw for a run of quads.
        pub fn drawBatch(r: *const Self, pass: Pass, batch: draw_list.Batch) void {
            r.bind(pass, batch.material, batch.texture, r.base + @as(usize, batch.first) * quad_shader.stride);
            pass.drawQuads(batch.count);
        }

        /// One instanced draw for a text run's glyphs.
        pub fn drawText(r: *const Self, pass: Pass, run: u32) void {
            r.drawGlyphSpan(pass, r.glyphs.span(run));
        }

        /// The `span[1]` glyph quads from `span[0]`: consecutive text runs in one
        /// draw (`iface.drawUntilCustom`).
        pub fn drawGlyphSpan(r: *const Self, pass: Pass, span: [2]u32) void {
            r.bind(pass, .solid, r.glyphs.texture, r.glyphsAt() + @as(usize, span[0]) * quad_shader.stride);
            pass.drawQuads(span[1]);
        }

        /// The scissor for an inline custom draw: `custom.rect` cut by `custom.clip`, in the
        /// physical pixels of the last `prepare`, inside the target (lcgf.gpu_desc.scissor, the
        /// arithmetic every back end shares).
        pub fn customScissor(r: *const Self, c: draw_list.CustomDraw) mtl.ScissorRect {
            const s = lcgf.gpu_desc.scissor(c.rect, c.clip, r.scale, r.extent[0], r.extent[1]);
            return .{ .x = s.x, .y = s.y, .width = s.width, .height = s.height };
        }

        /// Diagonal: the whole list, skipping custom draws.
        pub fn render(r: *const Self, pass: Pass, draw: *const DrawList) void {
            iface.render(r, pass, draw);
        }

        comptime {
            iface.check(Self);
        }
    };
}

const testing = std.testing;
const dev_mod = @import("device.zig");
const null_backend = lcgf.render_null;
const conformance = lcgf.render_conformance;

/// Stands in for the encoder off macOS: logs the calls a draw makes in the null back end's
/// terms (so conformance's checks apply) and notes a draw issued without the full state.
pub const Recorder = struct {
    log: *null_backend.Log,
    /// The frame's quads and glyphs in the instance buffer.
    base: usize = 0,
    glyphs_at: usize,
    /// Bits of the state set since the host last drew; a draw needs all of them.
    set: u16 = all,
    first: u32 = 0,
    partial: bool = false,

    const all: u16 = 0x1ff;
    const pipeline_base = 0x100;
    const texture_base = 0x10000;

    fn fake(addr: usize) Id {
        return @ptrFromInt(addr);
    }

    /// The host's own draws ran: no state can be assumed.
    pub fn host(rec: *Recorder) void {
        rec.log.push(.host);
        rec.set = 0;
    }

    pub fn setPipeline(rec: *Recorder, p: Id) void {
        rec.set |= 1;
        rec.log.push(.{ .pipeline = @fromBackingInt(@intCast(@intFromPtr(p) / pipeline_base - 1)) });
    }
    pub fn setVertexBuffer(rec: *Recorder, _: Id, offset: U, index: U) void {
        std.debug.assert(index == msl.instance_buffer);
        rec.set |= 2;
        const glyphs = offset >= rec.glyphs_at;
        rec.first = @intCast((offset - if (glyphs) rec.glyphs_at else rec.base) / quad_shader.stride);
        rec.log.push(.{ .vertex_buffer = if (glyphs) .glyphs else .quads });
    }
    pub fn setVertexBytes(rec: *Recorder, bytes: []const u8, _: U) void {
        std.debug.assert(bytes.len == @sizeOf(Globals));
        rec.set |= 4;
        rec.log.push(.{ .group = .{ .index = 0, .texture = .white } });
    }
    pub fn setFragmentBytes(rec: *Recorder, _: []const u8, _: U) void {
        rec.set |= 8;
    }
    pub fn setFragmentTexture(rec: *Recorder, t: Id, _: U) void {
        rec.set |= 16;
        rec.log.push(.{ .group = .{ .index = 1, .texture = @fromBackingInt(@intCast(@intFromPtr(t) / texture_base - 1)) } });
    }
    pub fn setFragmentSampler(rec: *Recorder, _: Id, _: U) void {
        rec.set |= 32;
    }
    pub fn setViewport(rec: *Recorder, _: mtl.Viewport) void {
        rec.set |= 64;
    }
    pub fn setScissor(rec: *Recorder, _: mtl.ScissorRect) void {
        rec.set |= 128;
    }
    pub fn setRaster(rec: *Recorder) void {
        rec.set |= 256;
    }
    pub fn drawQuads(rec: *Recorder, instances: U) void {
        if (rec.set != all) rec.partial = true;
        rec.log.push(.{ .draw = .{ .vertices = 4, .instances = @intCast(instances), .first_instance = rec.first } });
    }
};

/// A renderer over `Recorder` with fake handles and `memory` as its instance buffer: what
/// `init` would build, without a device.
pub fn recording(memory: []u8, desc: Desc) RendererOver(*Recorder) {
    var r: RendererOver(*Recorder) = .{ .device = Recorder.fake(1), .desc = desc, .contents = memory.ptr };
    for (0..max_materials) |i| r.pipelines[i] = Recorder.fake(Recorder.pipeline_base * (i + 1));
    r.material_count = 1;
    r.instances = Recorder.fake(2);
    r.white = Recorder.fake(Recorder.texture_base);
    r.sampler = Recorder.fake(3);
    _ = r.addTexture(r.white.?, null);
    return r;
}

test "renderer: every conformance scene issues its draws, each with the full state" {
    const desc: Desc = .{ .max_quads = conformance.max_quads, .max_glyphs = conformance.max_glyphs, .frames_in_flight = 1 };
    var memory: [(conformance.max_quads + conformance.max_glyphs) * quad_shader.stride]u8 = undefined;
    for (&conformance.scenes) |*s| {
        var st: conformance.Storage = .{};
        st.load(s);
        var r = recording(&memory, desc);
        r.prepare({}, &st.draw, st.glyphs(), s.viewport, 1);
        try testing.expectEqualSlices(u8, st.draw.quadBytes(), memory[0..st.draw.quadBytes().len]);
        try testing.expectEqualSlices(u8, std.mem.sliceAsBytes(st.glyph_quads[0..st.glyph_len]), memory[r.glyphsAt()..][0 .. st.glyph_len * quad_shader.stride]);
        try testing.expectEqual([2]u32{ 160, 120 }, r.extent);

        var calls: [96]null_backend.Call = undefined;
        var log: null_backend.Log = .{ .calls = &calls };
        var rec: Recorder = .{ .log = &log, .base = r.base, .glyphs_at = r.glyphsAt() };
        var i = iface.drawUntilCustom(&r, &rec, &st.draw, 0);
        while (i < st.draw.cmd_len) : (i = iface.drawUntilCustom(&r, &rec, &st.draw, i + 1)) rec.host();
        try testing.expect(log.len <= calls.len);
        try testing.expect(!rec.partial);
        try testing.expect(null_backend.rebindsAfterHost(log.recorded()));
        var got: [16]conformance.Draw = undefined;
        var n: usize = 0;
        var source: conformance.Source = .quads;
        for (log.recorded()) |call| switch (call) {
            .vertex_buffer => |buf| source = if (buf == .glyphs) .glyphs else .quads,
            .draw => |dr| {
                got[n] = .{ .source = source, .first = dr.first_instance, .count = dr.instances };
                n += 1;
            },
            else => {},
        };
        try testing.expectEqualSlices(conformance.Draw, s.draws, got[0..n]);
    }
}

test "renderer: textures register in order with their samplers, clamp past the cap, re-point" {
    var memory: [quad_shader.stride]u8 = undefined;
    var r = recording(&memory, .{ .max_quads = 1, .max_glyphs = 0, .frames_in_flight = 1 });
    const linear = Recorder.fake(4);
    const atlas = r.addTexture(Recorder.fake(2 * Recorder.texture_base), linear);
    try testing.expectEqual(@as(u16, 1), @backingInt(atlas));
    try testing.expectEqual(linear, r.samplers[1]);
    try testing.expectEqual(r.sampler.?, r.samplers[0]);
    r.setTexture(atlas, Recorder.fake(3 * Recorder.texture_base));
    try testing.expectEqual(Recorder.fake(3 * Recorder.texture_base), r.textures[1]);
    try testing.expectEqual(linear, r.samplers[1]);
    for (0..RendererOver(*Recorder).max_textures + 3) |_| _ = r.addTexture(Recorder.fake(5 * Recorder.texture_base), null);
    try testing.expectEqual(@as(u16, RendererOver(*Recorder).max_textures), r.texture_count);
    r.setTexture(@fromBackingInt(0xffff), Recorder.fake(6 * Recorder.texture_base)); // stale: the last entry
    try testing.expectEqual(Recorder.fake(6 * Recorder.texture_base), r.textures[RendererOver(*Recorder).max_textures - 1]);
    try testing.expectEqual(r.white.?, r.textures[0]);
}

test "renderer: a text run samples the glyph atlas, a quad batch its own texture" {
    var st: conformance.Storage = .{};
    st.load(&conformance.scenes[2]); // text: batch | text | text | batch
    var memory: [(conformance.max_quads + conformance.max_glyphs) * quad_shader.stride]u8 = undefined;
    var r = recording(&memory, .{ .max_quads = conformance.max_quads, .max_glyphs = conformance.max_glyphs, .frames_in_flight = 1 });
    var glyphs = st.glyphs();
    glyphs.texture = r.addTexture(Recorder.fake(2 * Recorder.texture_base), null);
    r.prepare({}, &st.draw, glyphs, .{ 160, 120 }, 1);
    var calls: [64]null_backend.Call = undefined;
    var log: null_backend.Log = .{ .calls = &calls };
    var rec: Recorder = .{ .log = &log, .base = r.base, .glyphs_at = r.glyphsAt() };
    r.render(&rec, &st.draw);
    var bound: [4]u16 = undefined;
    var n: usize = 0;
    for (log.recorded()) |call| switch (call) {
        .group => |g| if (g.index == 1) {
            bound[n] = @backingInt(g.texture);
            n += 1;
        },
        else => {},
    };
    try testing.expectEqualSlices(u16, &.{ 0, 1, 1, 0 }, bound[0..n]);
}

test "renderer: the custom scene's host draw gets its rect as a scissor in the pass's pixels" {
    var st: conformance.Storage = .{};
    const scene = &conformance.scenes[3];
    try testing.expectEqualStrings("custom", scene.name);
    st.load(scene);
    var memory: [(conformance.max_quads + conformance.max_glyphs) * quad_shader.stride]u8 = undefined;
    var r = recording(&memory, .{ .max_quads = conformance.max_quads, .max_glyphs = conformance.max_glyphs, .frames_in_flight = 1 });
    r.prepare({}, &st.draw, st.glyphs(), scene.viewport, 2);
    const i = iface.drawUntilCustom(&r, undefined, &st.draw, 1); // command 1 is the custom one
    try testing.expectEqual(1, i);
    try testing.expectEqual(mtl.ScissorRect{ .x = 16, .y = 16, .width = 288, .height = 208 }, r.customScissor(st.draw.customs[st.draw.command(i).custom]));
}

test "renderer: after a resize or scale change the viewport and scissor match the new drawable" {
    var st: conformance.Storage = .{};
    st.load(&conformance.scenes[0]);
    var memory: [(conformance.max_quads + conformance.max_glyphs) * quad_shader.stride]u8 = undefined;
    var r = recording(&memory, .{ .max_quads = conformance.max_quads, .max_glyphs = conformance.max_glyphs, .frames_in_flight = 1 });
    for ([_][2]f32{ .{ 160, 120 }, .{ 333.3, 77.7 }, .{ 333.3, 77.7 }, .{ 0, 10 } }, [_]f32{ 1, 1, 1.5, 2 }) |size, scale| {
        r.prepare({}, &st.draw, .{}, size, scale);
        try testing.expectEqual(dev_mod.drawableSize(size, scale), r.extent);
        try testing.expectEqual(scale, r.globals.scale);
        try testing.expectEqual(size, r.globals.viewport);
    }
}

test "renderer: prepare drops quads past the capacity instead of writing past the buffer" {
    var st: conformance.Storage = .{};
    st.load(&conformance.scenes[0]); // rects: 3 quads
    var memory: [2 * quad_shader.stride + 4]u8 = @splat(0xaa);
    var r = recording(memory[0 .. 2 * quad_shader.stride], .{ .max_quads = 2, .max_glyphs = 0, .frames_in_flight = 1 });
    r.prepare({}, &st.draw, .{}, .{ 80, 60 }, 2);
    try testing.expectEqualSlices(u8, st.draw.quadBytes()[0 .. 2 * quad_shader.stride], memory[0 .. 2 * quad_shader.stride]);
    try testing.expectEqualSlices(u8, &.{ 0xaa, 0xaa, 0xaa, 0xaa }, memory[2 * quad_shader.stride ..]);
    try testing.expectEqual([2]u32{ 160, 120 }, r.extent);
}

test "renderer: each prepare writes the next frame slot, and draws read the slot just written" {
    var st: conformance.Storage = .{};
    st.load(&conformance.scenes[2]); // text
    const desc: Desc = .{ .max_quads = conformance.max_quads, .max_glyphs = conformance.max_glyphs, .frames_in_flight = 3 };
    var memory: [3 * (conformance.max_quads + conformance.max_glyphs) * quad_shader.stride]u8 = undefined;
    var r = recording(&memory, desc);
    const frame = r.frameBytes();
    for ([_]usize{ 0, 1, 2, 0 }) |slot| {
        r.prepare({}, &st.draw, st.glyphs(), .{ 160, 120 }, 1);
        try testing.expectEqual(slot * frame, r.base);
        try testing.expectEqualSlices(u8, st.draw.quadBytes(), memory[slot * frame ..][0..st.draw.quadBytes().len]);
        var calls: [64]null_backend.Call = undefined;
        var log: null_backend.Log = .{ .calls = &calls };
        var rec: Recorder = .{ .log = &log, .base = slot * frame, .glyphs_at = r.glyphsAt() };
        r.render(&rec, &st.draw);
        var n: usize = 0;
        for (log.recorded()) |call| if (call == .draw) {
            try testing.expectEqual(conformance.scenes[2].draws[n].first, call.draw.first_instance);
            n += 1;
        };
        try testing.expectEqual(3, n);
    }
}

test "renderer: quad pipelines compile from the committed MSL on a real device" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    try objc.load();
    const pool = objc.Pool.push();
    defer pool.pop();
    var dev = try dev_mod.Device.init();
    defer dev.deinit();
    var r = try Renderer.init(dev.device, .{ .format = .rgba8_unorm });
    defer r.deinit();
    try testing.expectEqual(@as(u16, 1), r.material_count);
    try testing.expectEqual(@as(u16, 1), @backingInt(try r.addMaterial(msl.example)));
    for (0..max_materials + 2) |_| _ = try r.addMaterial(msl.example);
    try testing.expectEqual(@as(u16, max_materials), r.material_count);
    try testing.expectError(error.ShaderCompile, r.addMaterial("not msl"));
    const px: [2 * 2 * 4]u8 = @splat(0x80);
    const t = try texture.rgba8(dev.device, 2, 2, &px);
    defer objc.release(t);
    const s = try texture.sampler(dev.device, .linear);
    defer objc.release(s);
    try testing.expectEqual(@as(u16, 1), @backingInt(r.addTexture(t, s)));
    try testing.expectEqual(@as(U, 2), objc.msg(U, t, "width", .{}));
}
