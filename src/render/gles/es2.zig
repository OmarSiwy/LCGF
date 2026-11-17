//! The GL ES 2 path: the same contract as renderer.zig for drivers without instancing, vertex
//! array objects, uniform buffers or integer attributes (older Android, small Linux devices;
//! FemtoVG in Slint targets the same floor). `prepare` writes each quad four times, one copy per
//! corner, into caller-owned memory and uploads it; each command is one indexed triangle-list
//! draw over a static index buffer and a static corner stream (0,0 1,0 0,1 1,1 repeated).
//! Shaders: es2/quad.vert and es2/quad.frag, GLSL ES 1.00 written by hand because naga writes
//! no GLSL ES below 3.00; they keep the GLSL ES 3.0 formulas and leave out the `params`
//! features (see the note in quad.frag). One material: `Batch.material` is ignored.
//!
//! Needs 13 vertex attributes and 10 varying vectors, more than GL ES 2's minimum of 8 and 8
//! (most ES 2 GPUs have 16); `init` fails with `error.TooFewAttributes` below that.

const std = @import("std");
const lcgf = @import("lcgf");
const gl = @import("gl.zig");
const program = @import("program.zig");
const types = lcgf.types;
const draw_list = lcgf.draw_list;
const quad_shader = lcgf.quad_shader;
const iface = lcgf.render_iface;
const DrawList = draw_list.DrawList;

pub const vert = @embedFile("es2/quad.vert");
pub const frag = @embedFile("es2/quad.frag");

pub const Glyphs = iface.Glyphs;
pub const Error = program.Error || error{TooFewAttributes};

/// Attribute names by location: quad_shader.attrs' locations (2, `params`, is not read), then
/// the corner at 12.
const attrib_names = [_][:0]const u8{ "a_rect", "a_clip", "a_params", "a_uv", "a_fill", "a_border_color", "a_radii", "a_border", "a_opacity", "a_xform", "a_xform_t", "a_clip_radii", "a_corner" };
const corner_location = 12;
/// Quads per indexed draw: 16-bit indices reach 65536 vertices.
const chunk = 16384;

pub const Desc = struct {
    max_quads: u32 = 16 * 1024,
    max_glyphs: u32 = 32 * 1024,
};

/// Bytes of the scratch memory `init` takes: four copies of every quad and glyph.
pub fn scratchBytes(desc: Desc) usize {
    return (@as(usize, desc.max_quads) + desc.max_glyphs) * 4 * quad_shader.stride;
}

pub const Renderer = struct {
    f: *const gl.Fns,
    desc: Desc,
    scratch: []u8,
    program: gl.Uint = 0,
    globals_at: gl.Int = -1,
    texture_at: gl.Int = -1,
    texture_size_at: gl.Int = -1,
    max_attribs: u32 = 0,
    vertices: gl.Uint = 0,
    corners: gl.Uint = 0,
    indices: gl.Uint = 0,
    white: gl.Uint = 0,
    textures: [max_textures]gl.Uint = @splat(0),
    texture_sizes: [max_textures][2]f32 = @splat(.{ 1, 1 }),
    texture_count: u16 = 0,
    globals: [4]f32 = .{ 1, 1, 1, 0 },
    extent: [2]u32 = .{ 0, 0 },
    scale: f32 = 1,
    glyphs: Glyphs = .{},

    pub const max_textures = 64;
    pub const Queue = void;
    pub const Pass = void;

    /// Needs a current GL ES 2 (or later) context. `scratch` is at least `scratchBytes(desc)`
    /// and, like `f`, outlives the renderer.
    pub fn init(f: *const gl.Fns, desc: Desc, scratch: []u8) Error!Renderer {
        std.debug.assert(scratch.len >= scratchBytes(desc));
        var r: Renderer = .{ .f = f, .desc = desc, .scratch = scratch };
        var max: gl.Int = 0;
        f.glGetIntegerv(gl.MAX_VERTEX_ATTRIBS, &max);
        if (max < attrib_names.len) return error.TooFewAttributes;
        r.max_attribs = @intCast(max);
        r.program = try program.link(f, vert, frag, &attrib_names);
        errdefer r.deinit();
        r.globals_at = f.glGetUniformLocation(r.program, "u_globals");
        r.texture_at = f.glGetUniformLocation(r.program, "u_texture");
        r.texture_size_at = f.glGetUniformLocation(r.program, "u_texture_size");

        f.glGenBuffers(1, @ptrCast(&r.vertices));
        f.glBindBuffer(gl.ARRAY_BUFFER, r.vertices);
        f.glBufferData(gl.ARRAY_BUFFER, @intCast(scratchBytes(desc)), null, gl.DYNAMIC_DRAW);
        var corners: [chunk * 4][2]u8 = undefined;
        for (&corners, 0..) |*c, i| c.* = .{ @intCast(i & 1), @intCast((i >> 1) & 1) };
        f.glGenBuffers(1, @ptrCast(&r.corners));
        f.glBindBuffer(gl.ARRAY_BUFFER, r.corners);
        f.glBufferData(gl.ARRAY_BUFFER, @sizeOf(@TypeOf(corners)), &corners, gl.STATIC_DRAW);
        // Two triangles per quad, (0,1,2) and (2,1,3): the strip's split.
        var idx: [chunk * 6]u16 = undefined;
        for (0..chunk) |q| {
            const v: u16 = @intCast(q * 4);
            idx[q * 6 ..][0..6].* = .{ v, v + 1, v + 2, v + 2, v + 1, v + 3 };
        }
        f.glGenBuffers(1, @ptrCast(&r.indices));
        f.glBindBuffer(gl.ELEMENT_ARRAY_BUFFER, r.indices);
        f.glBufferData(gl.ELEMENT_ARRAY_BUFFER, @sizeOf(@TypeOf(idx)), &idx, gl.STATIC_DRAW);

        f.glGenTextures(1, @ptrCast(&r.white));
        f.glBindTexture(gl.TEXTURE_2D, r.white);
        f.glTexParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.NEAREST);
        f.glTexParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.NEAREST);
        const white_px = [4]u8{ 255, 255, 255, 255 };
        f.glTexImage2D(gl.TEXTURE_2D, 0, @intCast(gl.RGBA), 1, 1, 0, gl.RGBA, gl.UNSIGNED_BYTE, &white_px);
        _ = r.addTexture(r.white, 1, 1); // Texture.white
        return r;
    }

    pub fn deinit(r: *Renderer) void {
        const f = r.f;
        if (r.program != 0) f.glDeleteProgram(r.program);
        for ([_]gl.Uint{ r.vertices, r.corners, r.indices }) |b| if (b != 0) f.glDeleteBuffers(1, @ptrCast(&b));
        if (r.white != 0) f.glDeleteTextures(1, @ptrCast(&r.white));
        r.* = .{ .f = f, .desc = r.desc, .scratch = r.scratch };
    }

    /// As renderer.zig `addTexture`, plus the texture's size in texels: GLSL ES 1.00 has no
    /// `textureSize`, and nearest sampling picks texel centres from it.
    pub fn addTexture(r: *Renderer, texture: gl.Uint, w: u32, h: u32) types.Texture {
        const i: u16 = @min(r.texture_count, max_textures - 1);
        r.textures[i] = texture;
        r.texture_sizes[i] = .{ @floatFromInt(w), @floatFromInt(h) };
        r.texture_count = i + 1;
        return @fromBackingInt(i);
    }

    pub fn setTexture(r: *Renderer, handle: types.Texture, texture: gl.Uint, w: u32, h: u32) void {
        const i = @min(@backingInt(handle), r.texture_count - 1);
        r.textures[i] = texture;
        r.texture_sizes[i] = .{ @floatFromInt(w), @floatFromInt(h) };
    }

    /// Writes every quad and glyph four times (one copy per corner) into the scratch memory and
    /// uploads it. Quads past `max_quads` (glyphs past `max_glyphs`) are dropped.
    pub fn prepare(r: *Renderer, _: Queue, draw: *const DrawList, glyphs: Glyphs, viewport: [2]f32, scale: f32) void {
        const quads = draw.quads[0..@min(draw.quad_len, r.desc.max_quads)];
        const glyph_quads = glyphs.quads[0..@min(glyphs.quads.len, r.desc.max_glyphs)];
        const out: []draw_list.Quad = @alignCast(std.mem.bytesAsSlice(draw_list.Quad, r.scratch[0..scratchBytes(r.desc)]));
        for (quads, 0..) |q, i| out[i * 4 ..][0..4].* = @splat(q);
        const g0 = @as(usize, r.desc.max_quads) * 4;
        for (glyph_quads, 0..) |q, i| out[g0 + i * 4 ..][0..4].* = @splat(q);
        const f = r.f;
        f.glBindBuffer(gl.ARRAY_BUFFER, r.vertices);
        const qn = quads.len * 4 * quad_shader.stride;
        if (qn > 0) f.glBufferSubData(gl.ARRAY_BUFFER, 0, @intCast(qn), r.scratch.ptr);
        const gn = glyph_quads.len * 4 * quad_shader.stride;
        if (gn > 0) f.glBufferSubData(gl.ARRAY_BUFFER, @intCast(r.glyphsAt()), @intCast(gn), r.scratch[r.glyphsAt()..].ptr);
        r.globals = .{ viewport[0], viewport[1], scale, 0 };
        r.glyphs = glyphs;
        r.scale = scale;
        r.extent = .{ @intFromFloat(@round(viewport[0] * scale)), @intFromFloat(@round(viewport[1] * scale)) };
    }

    fn glyphsAt(r: *const Renderer) usize {
        return @as(usize, r.desc.max_quads) * 4 * quad_shader.stride;
    }

    /// Full state, every draw: program and its uniforms, texture, both vertex buffers and every
    /// attribute (the host's other attributes off), the index buffer, viewport, fixed function.
    fn bind(r: *const Renderer, texture: types.Texture, at: usize) void {
        const f = r.f;
        const t = @min(@backingInt(texture), r.texture_count - 1);
        f.glUseProgram(r.program);
        f.glUniform4f(r.globals_at, r.globals[0], r.globals[1], r.globals[2], r.globals[3]);
        f.glUniform1i(r.texture_at, 0);
        f.glUniform2f(r.texture_size_at, r.texture_sizes[t][0], r.texture_sizes[t][1]);
        f.glActiveTexture(gl.TEXTURE0);
        f.glBindTexture(gl.TEXTURE_2D, r.textures[t]);
        f.glBindBuffer(gl.ARRAY_BUFFER, r.vertices);
        inline for (quad_shader.attrs) |a| {
            const ptr: ?*const anyopaque = @ptrFromInt(at + a.offset);
            switch (comptime gl.attrFormat(a.format)) {
                .float => |n| {
                    f.glEnableVertexAttribArray(a.location);
                    f.glVertexAttribPointer(a.location, n, gl.FLOAT, 0, quad_shader.stride, ptr);
                },
                .unorm8 => |n| {
                    f.glEnableVertexAttribArray(a.location);
                    f.glVertexAttribPointer(a.location, n, gl.UNSIGNED_BYTE, 1, quad_shader.stride, ptr);
                },
                .uint => f.glDisableVertexAttribArray(a.location),
            }
        }
        f.glBindBuffer(gl.ARRAY_BUFFER, r.corners);
        f.glEnableVertexAttribArray(corner_location);
        f.glVertexAttribPointer(corner_location, 2, gl.UNSIGNED_BYTE, 0, 0, null);
        for (corner_location + 1..r.max_attribs) |i| f.glDisableVertexAttribArray(@intCast(i));
        f.glBindBuffer(gl.ELEMENT_ARRAY_BUFFER, r.indices);
        f.glViewport(0, 0, @intCast(r.extent[0]), @intCast(r.extent[1]));
        gl.quadState(f);
    }

    /// `count` quads from byte `at` of the vertex buffer, in chunks the 16-bit indices reach.
    fn drawQuads(r: *const Renderer, texture: types.Texture, at: usize, count: u32) void {
        var done: u32 = 0;
        while (done < count) : (done += chunk) {
            r.bind(texture, at + @as(usize, done) * 4 * quad_shader.stride);
            r.f.glDrawElements(gl.TRIANGLES, @intCast(@min(count - done, chunk) * 6), gl.UNSIGNED_SHORT, null);
        }
    }

    pub fn drawBatch(r: *const Renderer, _: Pass, batch: draw_list.Batch) void {
        r.drawQuads(batch.texture, @as(usize, batch.first) * 4 * quad_shader.stride, batch.count);
    }

    pub fn drawText(r: *const Renderer, _: Pass, run: u32) void {
        r.drawQuads(r.glyphs.texture, r.glyphsAt() + @as(usize, r.glyphs.span(run)[0]) * 4 * quad_shader.stride, r.glyphs.span(run)[1]);
    }

    pub fn customScissor(r: *const Renderer, custom: draw_list.CustomDraw) [4]i32 {
        return gl.scissor(r.extent, r.scale, custom);
    }

    pub fn render(r: *const Renderer, pass: Pass, draw: *const DrawList) void {
        iface.render(r, pass, draw);
    }
};

comptime {
    iface.check(Renderer);
}

const testing = std.testing;
const host = @import("host.zig");

test "es2: the GLSL ES 1.00 program links on a real driver and draws past the host's state" {
    var h: host.Host = undefined;
    try h.init(.{ .major = 2 });
    defer h.deinit();
    const scratch = try testing.allocator.alignedAlloc(u8, .of(draw_list.Quad), scratchBytes(.{ .max_quads = 4, .max_glyphs = 4 }));
    defer testing.allocator.free(scratch);
    var r = try Renderer.init(&h.gl, .{ .max_quads = 4, .max_glyphs = 4 }, scratch);
    defer r.deinit();
    var st: lcgf.render_conformance.Storage = .{};
    st.load(&lcgf.render_conformance.scenes[0]); // rects: a full-target panel first
    var t = try host.Target.init(&h, 160, 120);
    defer t.deinit(&h);
    r.prepare({}, &st.draw, st.glyphs(), .{ 160, 120 }, 1);
    t.begin(&h, .{ 0, 0, 0, 1 });
    h.gl.glEnable(gl.SCISSOR_TEST);
    h.gl.glScissor(0, 0, 1, 1);
    h.gl.glDisable(gl.BLEND);
    h.gl.glUseProgram(0);
    r.drawBatch({}, .{ .first = 0, .count = 1, .texture = .white, .material = .solid });
    var px: [160 * 120 * 4]u8 = undefined;
    h.readback(160, 120, &px);
    try h.check();
    try testing.expectEqualSlices(u8, &.{ 30, 31, 36, 255 }, px[(60 * 160 + 80) * 4 ..][0..4]);
}

/// Wyhash of quad.wgsl's stock shader (quad.wgsl + material.wgsl) that es2/quad.vert and
/// es2/quad.frag were last ported from.
const ported_from: u64 = 0x94a966e5a06ac89b;

test "es2: the hand-written GLSL ES 1.00 shaders were ported from the current quad.wgsl" {
    // Fails when quad.wgsl or material.wgsl change: port the change into es2/quad.vert and
    // es2/quad.frag (naga cannot write GLSL ES 1.00), check `ci/run.sh gles`, then set
    // `ported_from` to the hash this prints.
    const now = std.hash.Wyhash.hash(0, quad_shader.wgsl);
    if (now != ported_from) std.debug.print("quad.wgsl hash: 0x{x}\n", .{now});
    try testing.expectEqual(ported_from, now);
}
