//! The Direct3D 12 back end proper: draws a `DrawList` into the host's command list. Meets the
//! contract in src/render/iface.zig, as the wgpu back end does (prototype/ui_wgpu.zig
//! `Renderer`): `prepare`, `drawBatch`, `drawText`, `render`.
//!
//! WHO OWNS WHAT
//!   You:       device, queue, swapchain, command allocators and lists, fences, every texture
//!              you draw into or sample, and the frame loop (frame.zig is one).
//!   Renderer:  the root signature, the quad pipelines, and the upload ring below.

const std = @import("std");
const lcgr = @import("lcgr");
const com = @import("com.zig");
const device_mod = @import("device.zig");
const pipeline = @import("pipeline.zig");
const c = com.c;
const Error = com.Error;
const Device = device_mod.Device;
const types = lcgr.types;
const draw_list = lcgr.draw_list;
const quad_shader = lcgr.quad_shader;
const iface = lcgr.render_iface;
const DrawList = draw_list.DrawList;
const Quad = draw_list.Quad;

pub const Globals = lcgr.render_null.Globals;
pub const Glyphs = iface.Glyphs;

pub const Desc = struct {
    /// Format of the target the host's pass draws into (the swapchain's, or an offscreen one).
    format: c.DXGI_FORMAT = c.DXGI_FORMAT_R8G8B8A8_UNORM,
    max_quads: u32 = 16 * 1024,
    max_glyphs: u32 = 32 * 1024,
    /// Frames the host lets the GPU work on while it prepares the next: one ring slot each.
    frames: u32 = 2,
};

/// Bytes kept for the globals at the start of each slot: a root CBV's address must be
/// 256-byte aligned (D3D12_CONSTANT_BUFFER_DATA_PLACEMENT_ALIGNMENT).
const globals_slot = c.D3D12_CONSTANT_BUFFER_DATA_PLACEMENT_ALIGNMENT;

pub const max_materials = quad_shader.max_materials;

pub const Renderer = struct {
    desc: Desc,
    root: *com.RootSignature,
    pipelines: [max_materials]*com.PipelineState = undefined,
    material_count: u16 = 0,
    /// One buffer in an UPLOAD heap, mapped once for its whole life, cut into `desc.frames`
    /// slots of [globals | quads | glyph quads]. `prepare` writes slot `frame` with plain
    /// memcpy and the GPU reads it in place: no staging copy, no map per frame, no allocation.
    ring: *com.Resource,
    mapped: []u8,
    ring_address: u64,
    slot_bytes: u64,
    /// Offset of the slot the last `prepare` wrote.
    base: u64 = 0,
    /// Physical pixels: viewport * scale from the last `prepare`.
    extent: [2]u32 = .{ 0, 0 },
    scale: f32 = 1,
    glyphs: Glyphs = .{},

    pub fn init(d: *const Device, desc: Desc) Error!Renderer {
        const root = try pipeline.rootSignature(d.handle);
        errdefer com.release(root);
        const slot_bytes = std.mem.alignForward(u64, globals_slot + (@as(u64, desc.max_quads) + desc.max_glyphs) * quad_shader.stride, globals_slot);
        const ring = try d.createBuffer(slot_bytes * desc.frames, c.D3D12_HEAP_TYPE_UPLOAD);
        errdefer com.release(ring);
        const p = try ring.map(false);
        var r: Renderer = .{
            .desc = desc,
            .root = root,
            .ring = ring,
            .mapped = p[0..@intCast(slot_bytes * desc.frames)],
            .ring_address = ring.getGPUVirtualAddress(),
            .slot_bytes = slot_bytes,
        };
        errdefer r.deinit();
        _ = try r.addMaterial(d, pipeline.stock_hlsl); // Material.solid
        return r;
    }

    /// The GPU must be done with every frame that used the renderer.
    pub fn deinit(r: *Renderer) void {
        for (r.pipelines[0..r.material_count]) |p| com.release(p);
        r.material_count = 0;
        r.ring.unmap();
        com.release(r.ring);
        com.release(r.root);
    }

    /// A quad pipeline with your fragment logic: `quad_shader.shader(your_wgsl_fn)` translated
    /// to HLSL by naga and passed through `pipeline.naga` (src/render/shaders/translate.sh does
    /// it for the shipped variants). Past `max_materials` the last entry is replaced, as the
    /// prototype does; the replaced pipeline must not be in a pending frame.
    pub fn addMaterial(r: *Renderer, d: *const Device, hlsl: []const u8) Error!types.Material {
        const i: u16 = @min(r.material_count, max_materials - 1);
        const p = try pipeline.quad(d.handle, r.root, r.desc.format, hlsl);
        if (i < r.material_count) com.release(r.pipelines[i]);
        r.pipelines[i] = p;
        r.material_count = i + 1;
        return @fromBackingInt(i);
    }

    /// Offsets inside a slot.
    fn quadsAt(r: *const Renderer) u64 {
        _ = r;
        return globals_slot;
    }
    fn glyphsAt(r: *const Renderer) u64 {
        return globals_slot + @as(u64, r.desc.max_quads) * quad_shader.stride;
    }

    /// `prepare` takes the frame slot (0 to `desc.frames - 1`): the host's frame index, whose
    /// fence it waited on, so the GPU is done reading that slot.
    pub const Queue = u32;

    /// Uploads the frame into ring slot `frame`: three memcpy into the mapped upload heap.
    /// Quads past `max_quads` (glyphs past `max_glyphs`) are dropped, as the wgpu back end does.
    /// Call before recording the frame's draws.
    pub fn prepare(r: *Renderer, frame: Queue, draw: *const DrawList, glyphs: Glyphs, viewport: [2]f32, scale: f32) void {
        r.base = @as(u64, frame % r.desc.frames) * r.slot_bytes;
        const slot = r.mapped[@intCast(r.base)..][0..@intCast(r.slot_bytes)];
        const g: Globals = .{ .viewport = viewport, .scale = scale };
        @memcpy(slot[0..@sizeOf(Globals)], std.mem.asBytes(&g));
        const quad_bytes = draw.quadBytes();
        const qn = @min(quad_bytes.len, @as(usize, r.desc.max_quads) * quad_shader.stride);
        @memcpy(slot[@intCast(r.quadsAt())..][0..qn], quad_bytes[0..qn]);
        const glyph_bytes = std.mem.sliceAsBytes(glyphs.quads);
        const gn = @min(glyph_bytes.len, @as(usize, r.desc.max_glyphs) * quad_shader.stride);
        @memcpy(slot[@intCast(r.glyphsAt())..][0..gn], glyph_bytes[0..gn]);
        r.glyphs = glyphs;
        r.scale = scale;
        r.extent = .{ @intFromFloat(@round(viewport[0] * scale)), @intFromFloat(@round(viewport[1] * scale)) };
    }
};

const testing = std.testing;
const conformance = lcgr.render_conformance;

test "renderer: prepare writes each frame into its own slot of the mapped upload heap" {
    var d = try Device.init(.{ .adapter = .warp });
    defer d.deinit();
    var r = try Renderer.init(&d, .{ .max_quads = 4, .max_glyphs = 4, .frames = 2 });
    defer r.deinit();
    try testing.expectEqual(@as(u64, 0), r.slot_bytes % globals_slot);
    try testing.expectEqual(r.slot_bytes * 2, r.mapped.len);
    try testing.expectEqual(@as(u64, 0), r.ring_address % globals_slot);

    var st: conformance.Storage = .{};
    st.load(&conformance.scenes[2]); // text: 2 quads, 8 glyphs (4 kept)
    r.prepare(0, &st.draw, st.glyphs(), .{ 160, 120 }, 2);
    try testing.expectEqual([2]u32{ 320, 240 }, r.extent);
    const s0 = r.mapped[0..@intCast(r.slot_bytes)];
    try testing.expectEqualSlices(u8, std.mem.asBytes(&Globals{ .viewport = .{ 160, 120 }, .scale = 2 }), s0[0..@sizeOf(Globals)]);
    try testing.expectEqualSlices(u8, st.draw.quadBytes(), s0[globals_slot..][0 .. 2 * @sizeOf(Quad)]);
    const glyphs_at: usize = @intCast(r.glyphsAt());
    try testing.expectEqualSlices(u8, std.mem.sliceAsBytes(st.glyph_quads[0..4]), s0[glyphs_at..][0 .. 4 * @sizeOf(Quad)]);

    // The next frame goes to slot 1 and leaves slot 0, which the GPU may still read, alone.
    const before = s0[globals_slot..][0..@sizeOf(Quad)].*;
    st.load(&conformance.scenes[0]);
    r.prepare(1, &st.draw, st.glyphs(), .{ 160, 120 }, 1);
    try testing.expectEqual(r.slot_bytes, r.base);
    try testing.expectEqualSlices(u8, &before, s0[globals_slot..][0..@sizeOf(Quad)]);
    try testing.expectEqualSlices(u8, st.draw.quadBytes(), r.mapped[@intCast(r.base + globals_slot)..][0 .. 3 * @sizeOf(Quad)]);
    r.prepare(2, &st.draw, st.glyphs(), .{ 160, 120 }, 1); // wraps to slot 0
    try testing.expectEqual(@as(u64, 0), r.base);
}

test "renderer: materials build, and past the cap the last entry is replaced" {
    var d = try Device.init(.{ .adapter = .warp });
    defer d.deinit();
    var r = try Renderer.init(&d, .{ .max_quads = 4, .max_glyphs = 4 });
    defer r.deinit();
    try testing.expectEqual(@as(u16, 1), r.material_count);
    const example = try r.addMaterial(&d, pipeline.example_hlsl);
    try testing.expectEqual(@as(u16, 1), @backingInt(example));
    for (0..max_materials + 1) |_| _ = try r.addMaterial(&d, pipeline.example_hlsl);
    try testing.expectEqual(@as(u16, max_materials), r.material_count);
}
