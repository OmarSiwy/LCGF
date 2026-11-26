//! The GL ES 3 back end proper: draws a `DrawList` into whatever framebuffer the host has bound.
//! Meets the contract in src/render/iface.zig, as the wgpu and Vulkan back ends do: `prepare`,
//! `drawBatch`, `drawText`, `render`. One instanced draw (four-vertex strip, one instance per
//! quad) per command.
//!
//! WHO OWNS WHAT
//!   You:       the context (current on the drawing thread), the framebuffer and its clear, every
//!              texture you register, synchronisation and presentation.
//!   Renderer:  the quad programs, one vertex array, one instance buffer, one uniform buffer and
//!              the 1x1 white texture behind `Texture.white`.
//!
//! The shaders are the committed GLSL ES 3.0 that naga translated from quad.wgsl
//! (src/render/shaders/gen/stock.vert, .frag). GL ES 3.0 has no base instance, so a draw that
//! starts at quad `first` points the attributes `first * stride` bytes into the buffer; the
//! rebinding the contract requires for every draw does that for free. After each draw the
//! renderer's vertex array is unbound again: its attributes carry instance divisors, and a host
//! drawing next with the default vertex array must not edit (or draw through) it.

const std = @import("std");
const lcgf = @import("lcgf");
const gl = @import("gl.zig");
const program = @import("program.zig");
const gpu = @import("gpu.zig");
const types = lcgf.types;
const draw_list = lcgf.draw_list;
const quad_shader = lcgf.quad_shader;
const iface = lcgf.render_iface;
const DrawList = draw_list.DrawList;

pub const Globals = lcgf.render_null.Globals;
pub const Glyphs = iface.Glyphs;
pub const max_materials = quad_shader.max_materials;

pub const Desc = struct {
    max_quads: u32 = 16 * 1024,
    max_glyphs: u32 = 32 * 1024,
    /// Canvas instance rows and polygon vertices kept on the GPU (32 and 8 bytes each); 0
    /// rows: no canvas pipeline, and canvases draw nothing.
    canvas_rows: u32 = 0,
    canvas_verts: u32 = 0,
};

pub const Error = program.Error || gpu.Error;

/// canvas.wgsl as GLSL ES 3.0, vertices from a texture (src/render/gpu/canvas.zig).
pub const Canvas = lcgf.gpu_canvas.Canvas(gpu, struct {
    pub const wgsl = lcgf.canvas_shader.wgsl_es;
    pub const glsl_vs = @embedFile("canvas_vert");
    pub const glsl_fs = @embedFile("canvas_frag");
});

pub const Renderer = struct {
    f: *const gl.Fns,
    f3: *const gl.Fns3,
    desc: Desc,
    programs: [max_materials]gl.Uint = @splat(0),
    material_count: u16 = 0,
    vao: gl.Uint = 0,
    /// [quads | glyph quads], rewritten by every `prepare`.
    instances: gl.Uint = 0,
    globals: gl.Uint = 0,
    white: gl.Uint = 0,
    textures: [max_textures]gl.Uint = @splat(0),
    texture_count: u16 = 0,
    /// Physical pixels: viewport * scale from the last `prepare`.
    extent: [2]u32 = .{ 0, 0 },
    scale: f32 = 1,
    glyphs: Glyphs = .{},
    canvas: ?Canvas = null,
    list: ?*const DrawList = null,

    pub const max_textures = 64;
    /// GL uploads through the current context: nothing to pass.
    pub const Queue = void;
    /// Draws go to the framebuffer bound in the current context. At a custom command the host
    /// makes its own GL calls (programs, buffers, scissor, blending); the next UI draw rebinds
    /// every piece of state it uses. `customScissor` gives the custom rect in pixels.
    pub const Pass = void;

    /// Needs a current GL ES 3 context; `f` and `f3` must outlive the renderer.
    pub fn init(f: *const gl.Fns, f3: *const gl.Fns3, desc: Desc) Error!Renderer {
        var r: Renderer = .{ .f = f, .f3 = f3, .desc = desc };
        errdefer r.deinit();
        _ = try r.addMaterial(program.stock_vert, program.stock_frag); // Material.solid
        f3.glGenVertexArrays(1, @ptrCast(&r.vao));
        f.glGenBuffers(1, @ptrCast(&r.instances));
        f.glBindBuffer(gl.ARRAY_BUFFER, r.instances);
        f.glBufferData(gl.ARRAY_BUFFER, @intCast(r.instanceBytes()), null, gl.STREAM_DRAW);
        // The vertex array's own state, which no host call reaches unless it binds this array:
        // every attribute on, one step per instance. Draws set only the pointers.
        f3.glBindVertexArray(r.vao);
        inline for (quad_shader.attrs) |a| {
            f.glEnableVertexAttribArray(a.location);
            f3.glVertexAttribDivisor(a.location, 1);
        }
        f3.glBindVertexArray(0);
        f.glGenBuffers(1, @ptrCast(&r.globals));
        f.glBindBuffer(gl.UNIFORM_BUFFER, r.globals);
        f.glBufferData(gl.UNIFORM_BUFFER, @sizeOf(Globals), null, gl.DYNAMIC_DRAW);
        f.glGenTextures(1, @ptrCast(&r.white));
        f.glBindTexture(gl.TEXTURE_2D, r.white);
        f.glTexParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.NEAREST);
        f.glTexParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.NEAREST);
        const white_px = [4]u8{ 255, 255, 255, 255 };
        f.glTexImage2D(gl.TEXTURE_2D, 0, @intCast(gl.RGBA), 1, 1, 0, gl.RGBA, gl.UNSIGNED_BYTE, &white_px);
        r.textures[0] = r.white; // Texture.white
        r.texture_count = 1;
        if (desc.canvas_rows > 0) {
            r.canvas = @as(Canvas, undefined);
            try r.canvas.?.init(r.device(), .{ .format = .rgba8_unorm }, .{ .rows = desc.canvas_rows, .verts = desc.canvas_verts });
        }
        return r;
    }

    pub fn deinit(r: *Renderer) void {
        const f = r.f;
        if (r.canvas) |*cv| cv.deinit(r.device());
        for (r.programs[0..r.material_count]) |p| f.glDeleteProgram(p);
        if (r.vao != 0) r.f3.glDeleteVertexArrays(1, @ptrCast(&r.vao));
        if (r.instances != 0) f.glDeleteBuffers(1, @ptrCast(&r.instances));
        if (r.globals != 0) f.glDeleteBuffers(1, @ptrCast(&r.globals));
        if (r.white != 0) f.glDeleteTextures(1, @ptrCast(&r.white));
        r.* = .{ .f = f, .f3 = r.f3, .desc = r.desc };
    }

    /// A quad program with your fragment logic: `quad_shader.shader(your_wgsl_fn)` translated to
    /// GLSL ES 3.0 (src/render/shaders/translate.sh does it for the shipped variants). Past
    /// `max_materials` the last entry is replaced, as the prototype does.
    pub fn addMaterial(r: *Renderer, vert: []const u8, frag: []const u8) Error!types.Material {
        const i: u16 = @min(r.material_count, max_materials - 1);
        const p = try program.quad(r.f, r.f3, vert, frag);
        if (i < r.material_count) r.f.glDeleteProgram(r.programs[i]);
        r.programs[i] = p;
        r.material_count = i + 1;
        return @fromBackingInt(i);
    }

    /// Texture in: makes a GL ES texture usable as `Style.texture`. The texture and its
    /// filtering (texture parameters; the renderer binds no sampler object) stay yours, alive
    /// while a frame may sample it. Handles are indices in registration order; `Texture.white`
    /// is 0. Past `max_textures` the last entry is rewritten, as the prototype does.
    pub fn addTexture(r: *Renderer, texture: gl.Uint) types.Texture {
        const i: u16 = @min(r.texture_count, max_textures - 1);
        r.textures[i] = texture;
        r.texture_count = i + 1;
        return @fromBackingInt(i);
    }

    /// Points an existing handle at another texture (a target recreated at a new size, an atlas
    /// that grew); nodes keep their `Style.texture`. A stale handle clamps to the last entry.
    pub fn setTexture(r: *Renderer, handle: types.Texture, texture: gl.Uint) void {
        r.textures[@min(@backingInt(handle), r.texture_count - 1)] = texture;
    }

    /// Uploads the frame: the globals and both instance arrays. Quads past `max_quads` (glyphs
    /// past `max_glyphs`) are dropped, as the other back ends do.
    pub fn prepare(r: *Renderer, _: Queue, draw: *const DrawList, glyphs: Glyphs, viewport: [2]f32, scale: f32) void {
        const f = r.f;
        const g: Globals = .{ .viewport = viewport, .scale = scale };
        // Fresh storage for both buffers each frame (orphaning): a write into storage the last
        // frame's draws may still read would wait for the GPU to finish them.
        f.glBindBuffer(gl.UNIFORM_BUFFER, r.globals);
        f.glBufferData(gl.UNIFORM_BUFFER, @sizeOf(Globals), &g, gl.STREAM_DRAW);
        f.glBindBuffer(gl.ARRAY_BUFFER, r.instances);
        f.glBufferData(gl.ARRAY_BUFFER, @intCast(r.instanceBytes()), null, gl.STREAM_DRAW);
        const quad_bytes = draw.quadBytes();
        const qn = @min(quad_bytes.len, @as(usize, r.desc.max_quads) * quad_shader.stride);
        if (qn > 0) f.glBufferSubData(gl.ARRAY_BUFFER, 0, @intCast(qn), quad_bytes.ptr);
        const glyph_bytes = std.mem.sliceAsBytes(glyphs.quads);
        const gn = @min(glyph_bytes.len, @as(usize, r.desc.max_glyphs) * quad_shader.stride);
        if (gn > 0) f.glBufferSubData(gl.ARRAY_BUFFER, @intCast(r.glyphsAt()), @intCast(gn), glyph_bytes.ptr);
        r.glyphs = glyphs;
        r.scale = scale;
        r.extent = .{ @intFromFloat(@round(viewport[0] * scale)), @intFromFloat(@round(viewport[1] * scale)) };
        r.list = draw;
        if (r.canvas) |*cv| {
            var up: gpu.Upload = .begin(r.device(), {});
            const atlas = @min(@backingInt(glyphs.texture), r.texture_count - 1);
            cv.prepare(r.device(), &up, draw, 0, scale, r.extent, .{ .texture = r.textures[atlas], .width = 0, .height = 0 }, atlas);
        }
    }

    fn device(r: *const Renderer) gpu.Device {
        return .wrap(r.f, r.f3, null);
    }

    /// Canvas command `k` (`iface.drawsCanvas`): one instanced draw per range, with the canvas
    /// program, scissored to the node. Needs `Desc.canvas_rows`; the host calls
    /// `Instances.clearDirty` after `prepare` (src/render/gpu/canvas.zig).
    pub fn drawCanvas(r: *const Renderer, _: Pass, k: u32) void {
        const cv = if (r.canvas) |*cv| cv else return;
        var pass: gpu.RenderPass = .wrap(r.device(), {}, r.extent[0], r.extent[1]);
        cv.draw(&pass, r.list.?, k);
    }

    fn instanceBytes(r: *const Renderer) usize {
        return (@as(usize, r.desc.max_quads) + r.desc.max_glyphs) * quad_shader.stride;
    }

    fn glyphsAt(r: *const Renderer) usize {
        return @as(usize, r.desc.max_quads) * quad_shader.stride;
    }

    /// Full state, every draw (iface.zig, "Full state rebinding"): program, globals, texture,
    /// vertex array and every attribute pointer at `at` bytes, viewport, blending and the tests a
    /// host may have turned on. The attributes' enables and divisors live in the vertex array,
    /// set once by `init`. Handles are clamped rather than checked: a stale handle draws with
    /// the last valid entry.
    fn bind(r: *const Renderer, material: types.Material, texture: types.Texture, at: usize) void {
        const f = r.f;
        const f3 = r.f3;
        f.glUseProgram(r.programs[@min(@backingInt(material), r.material_count - 1)]);
        f3.glBindBufferBase(gl.UNIFORM_BUFFER, 0, r.globals);
        f.glActiveTexture(gl.TEXTURE0);
        f.glBindTexture(gl.TEXTURE_2D, r.textures[@min(@backingInt(texture), r.texture_count - 1)]);
        f3.glBindSampler(0, 0);
        f3.glBindVertexArray(r.vao);
        f.glBindBuffer(gl.ARRAY_BUFFER, r.instances);
        inline for (quad_shader.attrs) |a| {
            const ptr: ?*const anyopaque = @ptrFromInt(at + a.offset);
            switch (comptime gl.attrFormat(a.format)) {
                .float => |n| f.glVertexAttribPointer(a.location, n, gl.FLOAT, 0, quad_shader.stride, ptr),
                .uint => |n| f3.glVertexAttribIPointer(a.location, n, gl.UNSIGNED_INT, quad_shader.stride, ptr),
                .unorm8 => |n| f.glVertexAttribPointer(a.location, n, gl.UNSIGNED_BYTE, 1, quad_shader.stride, ptr),
            }
        }
        f.glViewport(0, 0, @intCast(r.extent[0]), @intCast(r.extent[1]));
        gl.quadState(f);
    }

    /// One instanced draw for a run of quads.
    pub fn drawBatch(r: *const Renderer, _: Pass, batch: draw_list.Batch) void {
        r.bind(batch.material, batch.texture, @as(usize, batch.first) * quad_shader.stride);
        r.f3.glDrawArraysInstanced(gl.TRIANGLE_STRIP, 0, 4, @intCast(batch.count));
        r.f3.glBindVertexArray(0);
    }

    /// One instanced draw for a text run's glyphs.
    pub fn drawText(r: *const Renderer, pass: Pass, run: u32) void {
        r.drawGlyphSpan(pass, r.glyphs.span(run));
    }

    /// The `span[1]` glyph quads from `span[0]`: consecutive text runs in one
    /// draw (`iface.drawUntilCustom`).
    pub fn drawGlyphSpan(r: *const Renderer, _: Pass, span: [2]u32) void {
        r.bind(.solid, r.glyphs.texture, r.glyphsAt() + @as(usize, span[0]) * quad_shader.stride);
        r.f3.glDrawArraysInstanced(gl.TRIANGLE_STRIP, 0, 4, @intCast(span[1]));
        r.f3.glBindVertexArray(0);
    }

    /// The scissor for an inline custom draw (x, y, width, height): `custom.rect` cut by
    /// `custom.clip`, in the physical pixels of the last `prepare`, inside the target. Rows
    /// count from the top, which with the translated shaders' flipped y is GL's own scissor
    /// space (host.zig `readback`), so it goes to glScissor as is.
    pub fn customScissor(r: *const Renderer, custom: draw_list.CustomDraw) [4]i32 {
        return gl.scissor(r.extent, r.scale, custom);
    }

    /// Diagonal: the whole list, skipping custom draws.
    pub fn render(r: *const Renderer, pass: Pass, draw: *const DrawList) void {
        iface.render(r, pass, draw);
    }
};

comptime {
    iface.check(Renderer);
}

const testing = std.testing;
const host = @import("host.zig");

test "renderer: quad programs build from the committed GLSL ES on a real driver" {
    var h: host.Host = undefined;
    try h.init(.{ .major = 3 });
    defer h.deinit();
    var r = try Renderer.init(&h.gl, &h.gl3, .{});
    defer r.deinit();
    try testing.expectEqual(@as(u16, 1), r.material_count);
    const example = try r.addMaterial(program.example_vert, program.example_frag);
    try testing.expectEqual(@as(u16, 1), @backingInt(example));
    // Past the cap the last entry is replaced, not written past.
    for (0..max_materials + 2) |_| _ = try r.addMaterial(program.example_vert, program.example_frag);
    try testing.expectEqual(@as(u16, max_materials), r.material_count);
    try h.check();
}

test "renderer: a draw after the host's own state still lands where it should" {
    var h: host.Host = undefined;
    try h.init(.{ .major = 3 });
    defer h.deinit();
    var r = try Renderer.init(&h.gl, &h.gl3, .{ .max_quads = 4, .max_glyphs = 4 });
    defer r.deinit();
    var st: lcgf.render_conformance.Storage = .{};
    st.load(&lcgf.render_conformance.scenes[0]); // rects: a full-target panel first
    var t = try host.Target.init(&h, 160, 120);
    defer t.deinit(&h);
    r.prepare({}, &st.draw, st.glyphs(), .{ 160, 120 }, 1);
    t.begin(&h, .{ 0, 0, 0, 1 });
    // What a host might leave behind: a scissor, a viewport, no blending, its own program.
    h.gl.glEnable(gl.SCISSOR_TEST);
    h.gl.glScissor(0, 0, 1, 1);
    h.gl.glViewport(0, 0, 1, 1);
    h.gl.glDisable(gl.BLEND);
    h.gl.glUseProgram(0);
    r.drawBatch({}, .{ .first = 0, .count = 1, .texture = .white, .material = .solid });
    var px: [160 * 120 * 4]u8 = undefined;
    h.readback(160, 120, &px);
    try h.check();
    try testing.expectEqualSlices(u8, &.{ 30, 31, 36, 255 }, px[(60 * 160 + 80) * 4 ..][0..4]);
}

test "renderer: a canvas re-sends only appended rows, and appended vertices by texture row" {
    var h: host.Host = undefined;
    try h.init(.{ .major = 3 });
    defer h.deinit();
    const conformance = lcgf.render_conformance;
    const sc = conformance.canvas_scene;
    var r = try Renderer.init(&h.gl, &h.gl3, .{ .canvas_rows = sc.rows, .canvas_verts = sc.verts });
    defer r.deinit();
    const st = try testing.allocator.create(conformance.CanvasStorage);
    defer testing.allocator.destroy(st);
    st.load();
    const s = &st.shapes;
    const uniforms = 2 * lcgf.canvas_shader.Uniforms.headBytes(sc.palette.layers.len) + 16;
    const row_bytes = lcgf.canvas_shader.verts_width * 4;
    r.prepare({}, &st.draw, .{}, sc.viewport, 1);
    s.clearDirty();
    // Every row, the vertex texture's one row and the row-index buffer.
    try testing.expectEqual(32 * s.len + row_bytes + uniforms + 4 * sc.rows, r.canvas.?.uploaded);
    r.prepare({}, &st.draw, .{}, sc.viewport, 1);
    try testing.expectEqual(uniforms, r.canvas.?.uploaded);
    _ = s.polygon(&.{ .{ 0, 0 }, .{ 10, 0 }, .{ 0, 10 } }, .{});
    r.prepare({}, &st.draw, .{}, sc.viewport, 1);
    try testing.expectEqual(32 + row_bytes + uniforms, r.canvas.?.uploaded);
    try h.check();
}

test "renderer: textures register in order, clamp past the cap and can be re-pointed" {
    var r: Renderer = .{ .f = undefined, .f3 = undefined, .desc = .{} };
    r.textures[0] = 7;
    r.texture_count = 1;
    try testing.expectEqual(@as(u16, 1), @backingInt(r.addTexture(11)));
    r.setTexture(@fromBackingInt(1), 12);
    try testing.expectEqual(@as(gl.Uint, 12), r.textures[1]);
    for (0..Renderer.max_textures + 3) |_| _ = r.addTexture(13);
    try testing.expectEqual(@as(u16, Renderer.max_textures), r.texture_count);
    r.setTexture(@fromBackingInt(0xffff), 14); // stale: the last entry
    try testing.expectEqual(@as(gl.Uint, 14), r.textures[Renderer.max_textures - 1]);
    try testing.expectEqual(@as(gl.Uint, 7), r.textures[0]);
}
