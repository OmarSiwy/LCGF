//! The Metal back end proper: draws a `DrawList` into the render command encoder the host
//! opened. Meets the contract in src/render/iface.zig, as the wgpu, Vulkan and GL ES back ends
//! do: `prepare`, `drawBatch`, `drawText`, `render`, one instanced draw (four-vertex strip, one
//! instance per quad) per command.
//!
//! WHO OWNS WHAT
//!   You:       device, queue, layer or target texture, command buffer, render pass and its
//!              encoder, synchronisation and presentation.
//!   Renderer:  the quad pipeline states, one shared instance buffer, the 1x1 white texture
//!              behind `Texture.white` and its sampler.
//!
//! The instance buffer is shared storage the CPU writes in `prepare` and the GPU reads when
//! the command buffer runs: the host must not call `prepare` again before the GPU has finished
//! the previous frame (wait on its command buffer). A draw that starts at quad `first` points
//! the vertex buffer `first * stride` bytes in, so no base instance is needed; the globals go in
//! with setVertexBytes / setFragmentBytes on every draw.

const std = @import("std");
const builtin = @import("builtin");
const lcgr = @import("lcgr");
const objc = @import("objc.zig");
const mtl = @import("mtl.zig");
const msl = @import("msl.zig");
const pipeline = @import("pipeline.zig");
const texture = @import("texture.zig");
const types = lcgr.types;
const draw_list = lcgr.draw_list;
const quad_shader = lcgr.quad_shader;
const iface = lcgr.render_iface;
const DrawList = draw_list.DrawList;
const Id = objc.Id;
const U = objc.NSUInteger;

pub const Globals = lcgr.render_null.Globals;
pub const Glyphs = iface.Glyphs;
pub const max_materials = quad_shader.max_materials;

pub const Desc = struct {
    /// Format of the targets the passes draw into.
    format: mtl.PixelFormat = .bgra8_unorm,
    sample_count: U = 1,
    max_quads: u32 = 16 * 1024,
    max_glyphs: u32 = 32 * 1024,
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
        /// Physical pixels: viewport * scale from the last `prepare`.
        extent: [2]u32 = .{ 0, 0 },
        scale: f32 = 1,
        globals: Globals = .{ .viewport = .{ 0, 0 }, .scale = 1 },
        glyphs: Glyphs = .{},

        /// Metal uploads by writing shared memory: nothing to pass.
        pub const Queue = void;
        /// The render command encoder of the host's pass. At a custom command the host records
        /// its own draws into it; the next UI draw rebinds every piece of state it uses.
        pub const Pass = Encoder;

        pub fn init(device: Id, desc: Desc) Error!Self {
            var r: Self = .{ .device = device, .desc = desc };
            errdefer r.deinit();
            _ = try r.addMaterial(msl.stock); // Material.solid
            const bytes: U = (@as(U, desc.max_quads) + desc.max_glyphs) * quad_shader.stride;
            const buf = objc.msg(?Id, device, "newBufferWithLength:options:", .{ bytes, mtl.resource_shared_write_combined }) orelse return error.BufferFailed;
            r.instances = buf;
            r.contents = objc.msg([*]u8, buf, "contents", .{});
            r.white = try texture.rgba8(device, 1, 1, &.{ 255, 255, 255, 255 });
            r.sampler = try texture.sampler(device, .nearest);
            return r;
        }

        pub fn deinit(r: *Self) void {
            for (r.pipelines[0..r.material_count]) |p| objc.release(p);
            r.material_count = 0;
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

        /// Uploads the frame: both instance arrays into the shared buffer, and the globals the
        /// draws will pass. Quads past `max_quads` (glyphs past `max_glyphs`) are dropped, as
        /// the other back ends do.
        pub fn prepare(r: *Self, _: Queue, draw: *const DrawList, glyphs: Glyphs, viewport: [2]f32, scale: f32) void {
            const quad_bytes = draw.quadBytes();
            const qn = @min(quad_bytes.len, @as(usize, r.desc.max_quads) * quad_shader.stride);
            @memcpy(r.contents[0..qn], quad_bytes[0..qn]);
            const glyph_bytes = std.mem.sliceAsBytes(glyphs.quads);
            const gn = @min(glyph_bytes.len, @as(usize, r.desc.max_glyphs) * quad_shader.stride);
            @memcpy(r.contents[r.glyphsAt()..][0..gn], glyph_bytes[0..gn]);
            r.globals = .{ .viewport = viewport, .scale = scale };
            r.glyphs = glyphs;
            r.scale = scale;
            r.extent = .{ @intFromFloat(@round(viewport[0] * scale)), @intFromFloat(@round(viewport[1] * scale)) };
        }

        fn glyphsAt(r: *const Self) usize {
            return @as(usize, r.desc.max_quads) * quad_shader.stride;
        }

        /// Full state, every draw (iface.zig, "Full state rebinding"): pipeline, instances at
        /// `at` bytes, globals for both stages, texture, sampler, viewport, scissor, culling.
        /// Handles are clamped rather than checked: a stale handle draws with the last entry.
        fn bind(r: *const Self, pass: Pass, material: types.Material, tex: types.Texture, at: usize) void {
            _ = tex; // ponytail: every texture is `white` until addTexture (next commit)
            const g = std.mem.asBytes(&r.globals);
            pass.setPipeline(r.pipelines[@min(@backingInt(material), r.material_count - 1)]);
            pass.setVertexBuffer(r.instances.?, at, msl.instance_buffer);
            pass.setVertexBytes(g, msl.globals_buffer);
            pass.setFragmentBytes(g, msl.globals_buffer);
            pass.setFragmentTexture(r.white.?, 0);
            pass.setFragmentSampler(r.sampler.?, 0);
            const w: f64 = @floatFromInt(r.extent[0]);
            const h: f64 = @floatFromInt(r.extent[1]);
            pass.setViewport(.{ .x = 0, .y = 0, .width = w, .height = h });
            pass.setScissor(.{ .x = 0, .y = 0, .width = r.extent[0], .height = r.extent[1] });
            pass.setRaster();
        }

        /// One instanced draw for a run of quads.
        pub fn drawBatch(r: *const Self, pass: Pass, batch: draw_list.Batch) void {
            r.bind(pass, batch.material, batch.texture, @as(usize, batch.first) * quad_shader.stride);
            pass.drawQuads(batch.count);
        }

        /// One instanced draw for a text run's glyphs.
        pub fn drawText(r: *const Self, pass: Pass, run: u32) void {
            r.bind(pass, .solid, r.glyphs.texture, r.glyphsAt() + @as(usize, r.glyphs.first[run]) * quad_shader.stride);
            pass.drawQuads(r.glyphs.count[run]);
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
const null_backend = lcgr.render_null;
const conformance = lcgr.render_conformance;

/// Stands in for the encoder off macOS: logs the calls a draw makes in the null back end's
/// terms (so conformance's checks apply) and notes a draw issued without the full state.
pub const Recorder = struct {
    log: *null_backend.Log,
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
        rec.first = @intCast((offset - if (glyphs) rec.glyphs_at else 0) / quad_shader.stride);
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
    return r;
}

test "renderer: every conformance scene issues its draws, each with the full state" {
    const desc: Desc = .{ .max_quads = conformance.max_quads, .max_glyphs = conformance.max_glyphs };
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
        var rec: Recorder = .{ .log = &log, .glyphs_at = r.glyphsAt() };
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

test "renderer: prepare drops quads past the capacity instead of writing past the buffer" {
    var st: conformance.Storage = .{};
    st.load(&conformance.scenes[0]); // rects: 3 quads
    var memory: [2 * quad_shader.stride + 4]u8 = @splat(0xaa);
    var r = recording(memory[0 .. 2 * quad_shader.stride], .{ .max_quads = 2, .max_glyphs = 0 });
    r.prepare({}, &st.draw, .{}, .{ 80, 60 }, 2);
    try testing.expectEqualSlices(u8, st.draw.quadBytes()[0 .. 2 * quad_shader.stride], memory[0 .. 2 * quad_shader.stride]);
    try testing.expectEqualSlices(u8, &.{ 0xaa, 0xaa, 0xaa, 0xaa }, memory[2 * quad_shader.stride ..]);
    try testing.expectEqual([2]u32{ 160, 120 }, r.extent);
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
}
