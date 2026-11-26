//! The Direct3D 12 back end proper: draws a `DrawList` into the host's command list. Meets the
//! contract in src/render/iface.zig, as the wgpu back end does (prototype/ui_wgpu.zig
//! `Renderer`): `prepare`, `drawBatch`, `drawText`, `render`.
//!
//! WHO OWNS WHAT
//!   You:       device, queue, swapchain, command allocators and lists, fences, every texture
//!              you draw into or sample, and the frame loop (frame.zig is one).
//!   Renderer:  the root signature, the quad pipelines, the upload ring and the texture
//!              descriptor heap below.

const std = @import("std");
const lcgf = @import("lcgf");
const com = @import("com.zig");
const device_mod = @import("device.zig");
const pipeline = @import("pipeline.zig");
const c = com.c;
const Error = com.Error;
const Device = device_mod.Device;
const types = lcgf.types;
const draw_list = lcgf.draw_list;
const quad_shader = lcgf.quad_shader;
const iface = lcgf.render_iface;
const DrawList = draw_list.DrawList;
const Quad = draw_list.Quad;

pub const Globals = lcgf.render_null.Globals;
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
    /// Shader-visible CBV/SRV/UAV heap: descriptor i is the SRV of `Texture` i. Set on the
    /// command list by every draw (a list can have one such heap bound at a time, so a host
    /// that binds its own heap at a custom draw loses nothing: the next UI draw sets this one).
    textures: *com.DescriptorHeap,
    srv_stride: u32,
    texture_count: u16 = 0,

    pub const max_textures = 64;

    /// `white` is a 1x1 opaque white RGBA8 texture in PIXEL_SHADER_RESOURCE; it becomes
    /// `Texture.white`.
    pub fn init(d: *const Device, desc: Desc, white: *com.Resource) Error!Renderer {
        const root = try pipeline.rootSignature(d.handle);
        errdefer com.release(root);
        const slot_bytes = std.mem.alignForward(u64, globals_slot + (@as(u64, desc.max_quads) + desc.max_glyphs) * quad_shader.stride, globals_slot);
        const ring = try d.createBuffer(slot_bytes * desc.frames, c.D3D12_HEAP_TYPE_UPLOAD);
        errdefer com.release(ring);
        const p = try ring.map(false);
        const heap = try d.handle.createDescriptorHeap(&.{ .Type = c.D3D12_DESCRIPTOR_HEAP_TYPE_CBV_SRV_UAV, .NumDescriptors = max_textures, .Flags = c.D3D12_DESCRIPTOR_HEAP_FLAG_SHADER_VISIBLE, .NodeMask = 0 });
        errdefer com.release(heap);
        var r: Renderer = .{
            .desc = desc,
            .root = root,
            .ring = ring,
            .mapped = p[0..@intCast(slot_bytes * desc.frames)],
            .ring_address = ring.getGPUVirtualAddress(),
            .slot_bytes = slot_bytes,
            .textures = heap,
            .srv_stride = d.handle.getDescriptorHandleIncrementSize(c.D3D12_DESCRIPTOR_HEAP_TYPE_CBV_SRV_UAV),
        };
        errdefer r.deinit();
        _ = try r.addMaterial(d, pipeline.stock_hlsl); // Material.solid
        _ = r.addTexture(d, white); // Texture.white
        return r;
    }

    /// The GPU must be done with every frame that used the renderer.
    pub fn deinit(r: *Renderer) void {
        for (r.pipelines[0..r.material_count]) |p| com.release(p);
        r.material_count = 0;
        com.release(r.textures);
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

    /// Texture in: makes a 2D texture (in PIXEL_SHADER_RESOURCE, one mip) usable as
    /// `Style.texture`. The texture stays yours, alive while a frame may sample it. Handles are
    /// indices in registration order; `Texture.white` is 0. Past `max_textures` the last entry
    /// is rewritten, as the prototype does; the GPU must be done with frames that sampled it
    /// (a descriptor in a shader-visible heap is read when the GPU executes, not when recorded).
    pub fn addTexture(r: *Renderer, d: *const Device, texture: *com.Resource) types.Texture {
        const i: u16 = @min(r.texture_count, max_textures - 1);
        writeTexture(r, d, i, texture);
        r.texture_count = i + 1;
        return @fromBackingInt(i);
    }

    /// Points an existing handle at another texture (a target recreated at a new size, an atlas
    /// that grew); nodes keep their `Style.texture`. Same rule as `addTexture`. A stale handle
    /// clamps to the last entry.
    pub fn setTexture(r: *Renderer, d: *const Device, texture: types.Texture, res: *com.Resource) void {
        writeTexture(r, d, @min(@backingInt(texture), r.texture_count - 1), res);
    }

    fn writeTexture(r: *const Renderer, d: *const Device, i: u16, res: *com.Resource) void {
        var srv: c.D3D12_SHADER_RESOURCE_VIEW_DESC = std.mem.zeroes(c.D3D12_SHADER_RESOURCE_VIEW_DESC);
        srv.Format = res.getDesc().Format;
        srv.ViewDimension = c.D3D12_SRV_DIMENSION_TEXTURE2D;
        srv.Shader4ComponentMapping = c.D3D12_DEFAULT_SHADER_4_COMPONENT_MAPPING;
        srv.unnamed_0.Texture2D = .{ .MostDetailedMip = 0, .MipLevels = 1, .PlaneSlice = 0, .ResourceMinLODClamp = 0 };
        d.handle.createShaderResourceView(res, &srv, device_mod.cpuAt(r.textures.cpuStart(), r.srv_stride, i));
    }

    /// Full state, every draw (iface.zig, "Full state rebinding"): root signature, descriptor
    /// heap, pipeline, globals, texture table, topology, the instance buffer at this frame's
    /// slot, viewport and scissor. The render target is the host's: it set it when it began
    /// the pass. Handles are clamped rather than checked: a stale handle draws with the last
    /// valid entry.
    fn bind(r: *const Renderer, l: *com.GraphicsCommandList, material: types.Material, texture: types.Texture, at: u64, count: u64) void {
        l.setGraphicsRootSignature(r.root);
        l.setDescriptorHeaps(&.{r.textures});
        l.setPipelineState(r.pipelines[@min(@backingInt(material), r.material_count - 1)]);
        l.setGraphicsRootConstantBufferView(pipeline.root_globals, r.ring_address + r.base);
        const t: u64 = @min(@backingInt(texture), r.texture_count - 1);
        l.setGraphicsRootDescriptorTable(pipeline.root_texture, .{ .ptr = r.textures.gpuStart().ptr + t * r.srv_stride });
        l.iaSetPrimitiveTopology(c.D3D_PRIMITIVE_TOPOLOGY_TRIANGLESTRIP);
        l.iaSetVertexBuffer(.{ .BufferLocation = r.ring_address + r.base + at, .SizeInBytes = @intCast(count * quad_shader.stride), .StrideInBytes = quad_shader.stride });
        l.rsSetViewport(.{ .TopLeftX = 0, .TopLeftY = 0, .Width = @floatFromInt(r.extent[0]), .Height = @floatFromInt(r.extent[1]), .MinDepth = 0, .MaxDepth = 1 });
        l.rsSetScissorRect(.{ .left = 0, .top = 0, .right = @intCast(r.extent[0]), .bottom = @intCast(r.extent[1]) });
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

    /// The host's command list, recording, with its render target set (and cleared, if it
    /// wants) for the pass. It is the raw ID3D12GraphicsCommandList, not a wrapper: at a custom
    /// command (`iface.drawUntilCustom` stops there) the host records its own calls into it,
    /// with its own root signature, pipeline, heaps and root arguments, then hands it back.
    /// Nothing needs restoring: the next UI draw rebinds every piece of state it uses
    /// (src/render/gpu/gradient.zig is such a host draw). `customScissor` gives the custom rect in pixels.
    /// `com.zig` declares the methods this back end calls; a host with its own D3D12 binding
    /// casts the pointer to its own ID3D12GraphicsCommandList type.
    pub const Pass = *com.GraphicsCommandList;

    /// One instanced draw for a run of quads.
    pub fn drawBatch(r: *const Renderer, l: Pass, batch: draw_list.Batch) void {
        r.bind(l, batch.material, batch.texture, r.quadsAt(), r.desc.max_quads);
        l.drawInstanced(4, batch.count, 0, batch.first);
    }

    /// One instanced draw for a text run's glyphs.
    pub fn drawText(r: *const Renderer, l: Pass, run: u32) void {
        r.bind(l, .solid, r.glyphs.texture, r.glyphsAt(), r.desc.max_glyphs);
        l.drawInstanced(4, r.glyphs.span(run)[1], 0, r.glyphs.span(run)[0]);
    }

    /// The scissor for an inline custom draw: `custom.rect` cut by `custom.clip`, in the
    /// physical pixels of the last `prepare`, inside the target. Pixels a quad would cover
    /// partly are included (floor the start, ceil the end); an empty result has zero area.
    pub fn customScissor(r: *const Renderer, custom: draw_list.CustomDraw) c.D3D12_RECT {
        const w: f32 = @floatFromInt(r.extent[0]);
        const h: f32 = @floatFromInt(r.extent[1]);
        const x0 = std.math.clamp(@floor(@max(custom.rect[0], custom.clip[0]) * r.scale), 0, w);
        const y0 = std.math.clamp(@floor(@max(custom.rect[1], custom.clip[1]) * r.scale), 0, h);
        const x1 = std.math.clamp(@ceil(@min(custom.rect[2], custom.clip[2]) * r.scale), x0, w);
        const y1 = std.math.clamp(@ceil(@min(custom.rect[3], custom.clip[3]) * r.scale), y0, h);
        return .{ .left = @intFromFloat(x0), .top = @intFromFloat(y0), .right = @intFromFloat(x1), .bottom = @intFromFloat(y1) };
    }

    /// Diagonal: the whole list, skipping custom draws. With custom draws, loop with
    /// `iface.drawUntilCustom` and draw each one yourself.
    pub fn render(r: *const Renderer, l: Pass, draw: *const DrawList) void {
        iface.render(r, l, draw);
    }
};

comptime {
    iface.check(Renderer);
}

const testing = std.testing;
const conformance = lcgf.render_conformance;
const host = @import("host.zig");

test "renderer: prepare writes each frame into its own slot of the mapped upload heap" {
    var d = try Device.init(.{ .adapter = .warp });
    defer d.deinit();
    var once = try host.Once.init(&d);
    defer once.deinit();
    const white = try host.sampled(&d, &once, 1, 1, &.{ 255, 255, 255, 255 });
    defer com.release(white);
    var r = try Renderer.init(&d, .{ .max_quads = 4, .max_glyphs = 4, .frames = 2 }, white);
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
    var once = try host.Once.init(&d);
    defer once.deinit();
    const white = try host.sampled(&d, &once, 1, 1, &.{ 255, 255, 255, 255 });
    defer com.release(white);
    var r = try Renderer.init(&d, .{ .max_quads = 4, .max_glyphs = 4 }, white);
    defer r.deinit();
    try testing.expectEqual(@as(u16, 1), r.material_count);
    const example = try r.addMaterial(&d, pipeline.example_hlsl);
    try testing.expectEqual(@as(u16, 1), @backingInt(example));
    for (0..max_materials + 1) |_| _ = try r.addMaterial(&d, pipeline.example_hlsl);
    try testing.expectEqual(@as(u16, max_materials), r.material_count);
}

test "renderer: texture handles are registration order, clamped past the cap" {
    var d = try Device.init(.{ .adapter = .warp });
    defer d.deinit();
    var once = try host.Once.init(&d);
    defer once.deinit();
    const white = try host.sampled(&d, &once, 1, 1, &.{ 255, 255, 255, 255 });
    defer com.release(white);
    var r = try Renderer.init(&d, .{ .max_quads = 4, .max_glyphs = 4 }, white);
    defer r.deinit();
    try testing.expectEqual(@as(u16, 1), r.texture_count);
    try testing.expectEqual(@as(u16, 1), @backingInt(r.addTexture(&d, white)));
    for (0..Renderer.max_textures + 2) |_| _ = r.addTexture(&d, white);
    try testing.expectEqual(@as(u16, Renderer.max_textures), r.texture_count);
    r.setTexture(&d, @fromBackingInt(200), white); // stale: rewrites the last entry, in bounds
}

test "renderer: the custom scissor is the rect cut by its clip, in pixels, inside the target" {
    var r: Renderer = undefined;
    r.extent = .{ 320, 240 };
    r.scale = 2;
    const open: [4]f32 = .{ -1e6, -1e6, 1e6, 1e6 };
    var sc = r.customScissor(.{ .rect = .{ 8, 8, 152, 112 }, .clip = open, .data = 0, .id = 0, .node = 0 });
    try testing.expectEqual(c.D3D12_RECT{ .left = 16, .top = 16, .right = 304, .bottom = 224 }, sc);
    sc = r.customScissor(.{ .rect = .{ -10, 100.25, 400, 300 }, .clip = .{ 0, 0, 150.2, 1e6 }, .data = 0, .id = 0, .node = 0 });
    try testing.expectEqual(c.D3D12_RECT{ .left = 0, .top = 200, .right = 301, .bottom = 240 }, sc);
    sc = r.customScissor(.{ .rect = .{ 50, 50, 60, 60 }, .clip = .{ 70, 70, 80, 80 }, .data = 0, .id = 0, .node = 0 });
    try testing.expectEqual(@as(c_long, 0), (sc.right - sc.left) * (sc.bottom - sc.top));
}
