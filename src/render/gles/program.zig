//! Shader programs from GLSL ES source: compile both stages, link, report the driver's log on
//! failure. The sources are the committed translations of quad.wgsl
//! (src/render/shaders/gen/<variant>.vert and .frag, GLSL ES 3.0 from naga), so every back end
//! draws from the same shader.

const std = @import("std");
const gl = @import("gl.zig");

pub const Error = error{ CompileFailed, LinkFailed };

/// GLSL ES 3.0 of the shipped variants (quad_shader.variants).
pub const stock_vert = @embedFile("stock_vert");
pub const stock_frag = @embedFile("stock_frag");
pub const example_vert = @embedFile("example_vert");
pub const example_frag = @embedFile("example_frag");

/// Uniform block names naga gives quad.wgsl's globals (group 0, binding 0) in each stage.
pub const globals_blocks = [_][:0]const u8{ "Globals_block_0Vertex", "Globals_block_0Fragment" };
/// The sampled texture (group 1, binding 0).
pub const texture_uniform = "_group_1_binding_0_fs";

/// Compiles and links `vert` and `frag`. `attribs` names attribute locations to bind before
/// linking (GLSL ES 1.00 has no `layout(location)`); empty for GLSL ES 3.0. A failure logs the
/// driver's message.
pub fn link(f: *const gl.Fns, vert: []const u8, frag: []const u8, attribs: []const [:0]const u8) Error!gl.Uint {
    const vs = try compile(f, gl.VERTEX_SHADER, vert);
    defer f.glDeleteShader(vs);
    const fs = try compile(f, gl.FRAGMENT_SHADER, frag);
    defer f.glDeleteShader(fs);
    const p = f.glCreateProgram();
    f.glAttachShader(p, vs);
    f.glAttachShader(p, fs);
    for (attribs, 0..) |name, i| f.glBindAttribLocation(p, @intCast(i), name.ptr);
    f.glLinkProgram(p);
    var ok: gl.Int = 0;
    f.glGetProgramiv(p, gl.LINK_STATUS, &ok);
    if (ok == 0) {
        var log: [2048]u8 = undefined;
        var n: gl.Sizei = 0;
        f.glGetProgramInfoLog(p, log.len, &n, &log);
        std.log.warn("GL ES link failed: {s}", .{log[0..@intCast(n)]});
        f.glDeleteProgram(p);
        return error.LinkFailed;
    }
    return p;
}

fn compile(f: *const gl.Fns, stage: gl.Enum, src: []const u8) Error!gl.Uint {
    const s = f.glCreateShader(stage);
    const ptr: [*]const u8 = src.ptr;
    const len: gl.Int = @intCast(src.len);
    f.glShaderSource(s, 1, @ptrCast(&ptr), @ptrCast(&len));
    f.glCompileShader(s);
    var ok: gl.Int = 0;
    f.glGetShaderiv(s, gl.COMPILE_STATUS, &ok);
    if (ok == 0) {
        var log: [2048]u8 = undefined;
        var n: gl.Sizei = 0;
        f.glGetShaderInfoLog(s, log.len, &n, &log);
        std.log.warn("GL ES compile failed: {s}", .{log[0..@intCast(n)]});
        f.glDeleteShader(s);
        return error.CompileFailed;
    }
    return s;
}

/// Links a quad.wgsl variant from its GLSL ES 3.0 translation and points its globals blocks at
/// uniform buffer binding 0 and its texture at unit 0, where the renderer binds them.
pub fn quad(f: *const gl.Fns, f3: *const gl.Fns3, vert: []const u8, frag: []const u8) Error!gl.Uint {
    const p = try link(f, vert, frag, &.{});
    for (globals_blocks) |name| {
        const index = f3.glGetUniformBlockIndex(p, name.ptr);
        if (index != gl.INVALID_INDEX) f3.glUniformBlockBinding(p, index, 0);
    }
    f.glUseProgram(p);
    f.glUniform1i(f.glGetUniformLocation(p, texture_uniform), 0); // -1 (no texture) is ignored
    f.glUseProgram(0);
    return p;
}

const testing = std.testing;
const host = @import("host.zig");

test "program: every shipped variant compiles and links on a real driver" {
    var h: host.Host = undefined;
    try h.init(.{ .major = 3 });
    defer h.deinit();
    for ([_][2][]const u8{ .{ stock_vert, stock_frag }, .{ example_vert, example_frag } }) |v| {
        const p = try quad(&h.gl, &h.gl3, v[0], v[1]);
        defer h.gl.glDeleteProgram(p);
        var blocks: gl.Int = 0;
        h.gl.glGetProgramiv(p, gl.ACTIVE_UNIFORM_BLOCKS, &blocks);
        try testing.expect(blocks >= 1);
        if (v[0].ptr == stock_vert.ptr) try testing.expect(h.gl.glGetUniformLocation(p, texture_uniform) >= 0);
    }
    try h.check();
}

test "program: a broken shader is an error, not a crash" {
    var h: host.Host = undefined;
    try h.init(.{ .major = 3 });
    defer h.deinit();
    try testing.expectError(error.CompileFailed, link(&h.gl, "#version 300 es\nvoid main() { nope; }", stock_frag, &.{}));
}
