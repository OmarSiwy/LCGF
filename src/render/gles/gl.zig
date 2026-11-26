//! The OpenGL ES functions and constants this back end calls, written by hand (no headers):
//! the subset of GL ES 3.0 the renderer and the test host use, fetched once through
//! `eglGetProcAddress` into a table. GL calls act on the context current on the calling thread.

const std = @import("std");
const lcgf = @import("lcgf");
const draw_list = lcgf.draw_list;
const egl = @import("egl.zig");

pub const Enum = u32;
pub const Uint = u32;
pub const Int = i32;
pub const Sizei = i32;
pub const Bitfield = u32;
pub const Float = f32;
pub const Boolean = u8;
pub const Intptr = isize;
pub const Sizeiptr = isize;

pub const NO_ERROR: Enum = 0;
pub const VENDOR: Enum = 0x1F00;
pub const RENDERER: Enum = 0x1F01;
pub const VERSION: Enum = 0x1F02;
pub const COLOR_BUFFER_BIT: Bitfield = 0x4000;
pub const TEXTURE_2D: Enum = 0x0DE1;
pub const TEXTURE0: Enum = 0x84C0;
pub const TEXTURE_MIN_FILTER: Enum = 0x2801;
pub const TEXTURE_MAG_FILTER: Enum = 0x2800;
pub const TEXTURE_WRAP_S: Enum = 0x2802;
pub const TEXTURE_WRAP_T: Enum = 0x2803;
pub const NEAREST: Int = 0x2600;
pub const CLAMP_TO_EDGE: Int = 0x812F;
pub const RGBA: Enum = 0x1908;
pub const UNSIGNED_BYTE: Enum = 0x1401;
pub const UNPACK_ALIGNMENT: Enum = 0x0CF5;
pub const PACK_ALIGNMENT: Enum = 0x0D05;
pub const FRAMEBUFFER: Enum = 0x8D40;
pub const COLOR_ATTACHMENT0: Enum = 0x8CE0;
pub const FRAMEBUFFER_COMPLETE: Enum = 0x8CD5;
pub const VERTEX_SHADER: Enum = 0x8B31;
pub const FRAGMENT_SHADER: Enum = 0x8B30;
pub const COMPILE_STATUS: Enum = 0x8B81;
pub const LINK_STATUS: Enum = 0x8B82;
pub const ACTIVE_UNIFORM_BLOCKS: Enum = 0x8A36;
pub const INVALID_INDEX: Uint = 0xffff_ffff;
pub const ARRAY_BUFFER: Enum = 0x8892;
pub const ELEMENT_ARRAY_BUFFER: Enum = 0x8893;
pub const UNIFORM_BUFFER: Enum = 0x8A11;
pub const DYNAMIC_DRAW: Enum = 0x88E8;
pub const STREAM_DRAW: Enum = 0x88E0;
pub const STATIC_DRAW: Enum = 0x88E4;
pub const FLOAT: Enum = 0x1406;
pub const UNSIGNED_INT: Enum = 0x1405;
pub const UNSIGNED_SHORT: Enum = 0x1403;
pub const TRIANGLES: Enum = 0x0004;
pub const TRIANGLE_STRIP: Enum = 0x0005;
pub const BLEND: Enum = 0x0BE2;
pub const SCISSOR_TEST: Enum = 0x0C11;
pub const DEPTH_TEST: Enum = 0x0B71;
pub const STENCIL_TEST: Enum = 0x0B90;
pub const CULL_FACE: Enum = 0x0B44;
pub const DITHER: Enum = 0x0BD0;
pub const ONE: Enum = 1;
pub const ONE_MINUS_SRC_ALPHA: Enum = 0x0303;
pub const FUNC_ADD: Enum = 0x8006;
pub const MAX_VERTEX_ATTRIBS: Enum = 0x8869;

/// GL ES functions, named as in GL.
pub const Fns = struct {
    glGetError: *const fn () callconv(.c) Enum,
    glGetString: *const fn (Enum) callconv(.c) ?[*:0]const u8,
    glFinish: *const fn () callconv(.c) void,
    glViewport: *const fn (Int, Int, Sizei, Sizei) callconv(.c) void,
    glClearColor: *const fn (Float, Float, Float, Float) callconv(.c) void,
    glClear: *const fn (Bitfield) callconv(.c) void,
    glPixelStorei: *const fn (Enum, Int) callconv(.c) void,
    glReadPixels: *const fn (Int, Int, Sizei, Sizei, Enum, Enum, ?*anyopaque) callconv(.c) void,
    glGenTextures: *const fn (Sizei, [*]Uint) callconv(.c) void,
    glDeleteTextures: *const fn (Sizei, [*]const Uint) callconv(.c) void,
    glBindTexture: *const fn (Enum, Uint) callconv(.c) void,
    glActiveTexture: *const fn (Enum) callconv(.c) void,
    glTexParameteri: *const fn (Enum, Enum, Int) callconv(.c) void,
    glTexImage2D: *const fn (Enum, Int, Int, Sizei, Sizei, Int, Enum, Enum, ?*const anyopaque) callconv(.c) void,
    glGenFramebuffers: *const fn (Sizei, [*]Uint) callconv(.c) void,
    glDeleteFramebuffers: *const fn (Sizei, [*]const Uint) callconv(.c) void,
    glBindFramebuffer: *const fn (Enum, Uint) callconv(.c) void,
    glFramebufferTexture2D: *const fn (Enum, Enum, Enum, Uint, Int) callconv(.c) void,
    glCheckFramebufferStatus: *const fn (Enum) callconv(.c) Enum,
    glCreateShader: *const fn (Enum) callconv(.c) Uint,
    glShaderSource: *const fn (Uint, Sizei, [*]const [*]const u8, ?[*]const Int) callconv(.c) void,
    glCompileShader: *const fn (Uint) callconv(.c) void,
    glGetShaderiv: *const fn (Uint, Enum, *Int) callconv(.c) void,
    glGetShaderInfoLog: *const fn (Uint, Sizei, *Sizei, [*]u8) callconv(.c) void,
    glDeleteShader: *const fn (Uint) callconv(.c) void,
    glCreateProgram: *const fn () callconv(.c) Uint,
    glAttachShader: *const fn (Uint, Uint) callconv(.c) void,
    glBindAttribLocation: *const fn (Uint, Uint, [*:0]const u8) callconv(.c) void,
    glLinkProgram: *const fn (Uint) callconv(.c) void,
    glGetProgramiv: *const fn (Uint, Enum, *Int) callconv(.c) void,
    glGetProgramInfoLog: *const fn (Uint, Sizei, *Sizei, [*]u8) callconv(.c) void,
    glDeleteProgram: *const fn (Uint) callconv(.c) void,
    glUseProgram: *const fn (Uint) callconv(.c) void,
    glGetUniformLocation: *const fn (Uint, [*:0]const u8) callconv(.c) Int,
    glUniform1i: *const fn (Int, Int) callconv(.c) void,
    glUniform4f: *const fn (Int, Float, Float, Float, Float) callconv(.c) void,
    glUniform2f: *const fn (Int, Float, Float) callconv(.c) void,
    glGetIntegerv: *const fn (Enum, *Int) callconv(.c) void,
    glGenBuffers: *const fn (Sizei, [*]Uint) callconv(.c) void,
    glDeleteBuffers: *const fn (Sizei, [*]const Uint) callconv(.c) void,
    glBindBuffer: *const fn (Enum, Uint) callconv(.c) void,
    glBufferData: *const fn (Enum, Sizeiptr, ?*const anyopaque, Enum) callconv(.c) void,
    glBufferSubData: *const fn (Enum, Intptr, Sizeiptr, *const anyopaque) callconv(.c) void,
    glEnableVertexAttribArray: *const fn (Uint) callconv(.c) void,
    glDisableVertexAttribArray: *const fn (Uint) callconv(.c) void,
    glVertexAttribPointer: *const fn (Uint, Int, Enum, Boolean, Sizei, ?*const anyopaque) callconv(.c) void,
    glDrawArrays: *const fn (Enum, Int, Sizei) callconv(.c) void,
    glDrawElements: *const fn (Enum, Sizei, Enum, ?*const anyopaque) callconv(.c) void,
    glEnable: *const fn (Enum) callconv(.c) void,
    glDisable: *const fn (Enum) callconv(.c) void,
    glBlendFuncSeparate: *const fn (Enum, Enum, Enum, Enum) callconv(.c) void,
    glBlendEquation: *const fn (Enum) callconv(.c) void,
    glColorMask: *const fn (Boolean, Boolean, Boolean, Boolean) callconv(.c) void,
    glScissor: *const fn (Int, Int, Sizei, Sizei) callconv(.c) void,
    // lcgf_render.gpu (gpu.zig): fixed-function state a pipeline sets, partial texture writes.
    glTexSubImage2D: *const fn (Enum, Int, Int, Int, Sizei, Sizei, Enum, Enum, ?*const anyopaque) callconv(.c) void,
    glBlendColor: *const fn (Float, Float, Float, Float) callconv(.c) void,
    glBlendEquationSeparate: *const fn (Enum, Enum) callconv(.c) void,
    glCullFace: *const fn (Enum) callconv(.c) void,
    glFrontFace: *const fn (Enum) callconv(.c) void,
};

/// GL ES 3.0 functions on top of `Fns`; a GL ES 2 driver need not have them.
pub const Fns3 = struct {
    glGetUniformBlockIndex: *const fn (Uint, [*:0]const u8) callconv(.c) Uint,
    glUniformBlockBinding: *const fn (Uint, Uint, Uint) callconv(.c) void,
    glBindBufferBase: *const fn (Enum, Uint, Uint) callconv(.c) void,
    glBindSampler: *const fn (Uint, Uint) callconv(.c) void,
    glGenVertexArrays: *const fn (Sizei, [*]Uint) callconv(.c) void,
    glDeleteVertexArrays: *const fn (Sizei, [*]const Uint) callconv(.c) void,
    glBindVertexArray: *const fn (Uint) callconv(.c) void,
    glVertexAttribIPointer: *const fn (Uint, Int, Enum, Sizei, ?*const anyopaque) callconv(.c) void,
    glVertexAttribDivisor: *const fn (Uint, Uint) callconv(.c) void,
    glDrawArraysInstanced: *const fn (Enum, Int, Sizei, Sizei) callconv(.c) void,
    // lcgf_render.gpu (gpu.zig): samplers, storage, multisampling, resolves, readback.
    glDrawElementsInstanced: *const fn (Enum, Sizei, Enum, ?*const anyopaque, Sizei) callconv(.c) void,
    glBindBufferRange: *const fn (Enum, Uint, Uint, Intptr, Sizeiptr) callconv(.c) void,
    glGenSamplers: *const fn (Sizei, [*]Uint) callconv(.c) void,
    glDeleteSamplers: *const fn (Sizei, [*]const Uint) callconv(.c) void,
    glSamplerParameteri: *const fn (Uint, Enum, Int) callconv(.c) void,
    glSamplerParameterf: *const fn (Uint, Enum, Float) callconv(.c) void,
    glTexStorage2D: *const fn (Enum, Sizei, Enum, Sizei, Sizei) callconv(.c) void,
    glGenRenderbuffers: *const fn (Sizei, [*]Uint) callconv(.c) void,
    glDeleteRenderbuffers: *const fn (Sizei, [*]const Uint) callconv(.c) void,
    glBindRenderbuffer: *const fn (Enum, Uint) callconv(.c) void,
    glRenderbufferStorageMultisample: *const fn (Enum, Sizei, Enum, Sizei, Sizei) callconv(.c) void,
    glFramebufferRenderbuffer: *const fn (Enum, Enum, Enum, Uint) callconv(.c) void,
    glBlitFramebuffer: *const fn (Int, Int, Int, Int, Int, Int, Int, Int, Bitfield, Enum) callconv(.c) void,
    glDrawBuffers: *const fn (Sizei, [*]const Enum) callconv(.c) void,
    glMapBufferRange: *const fn (Enum, Intptr, Sizeiptr, Bitfield) callconv(.c) ?*anyopaque,
    glUnmapBuffer: *const fn (Enum) callconv(.c) Boolean,
};

/// GL ES 3.1: compute and storage images, for lcgf_render.gpu's compute passes. Optional: a
/// 3.0 driver has none, and the projection's compute calls are then unavailable.
pub const Fns31 = struct {
    glDispatchCompute: *const fn (Uint, Uint, Uint) callconv(.c) void,
    glMemoryBarrier: *const fn (Bitfield) callconv(.c) void,
    glBindImageTexture: *const fn (Uint, Uint, Int, Boolean, Int, Enum, Enum) callconv(.c) void,
};

/// How a quad_shader.attrs format reaches GL: component kind and count.
pub const AttrFormat = union(enum) { float: Int, uint: Int, unorm8: Int };

pub fn attrFormat(comptime name: []const u8) AttrFormat {
    const table = .{
        .{ "float32", AttrFormat{ .float = 1 } },
        .{ "float32x2", AttrFormat{ .float = 2 } },
        .{ "float32x4", AttrFormat{ .float = 4 } },
        .{ "uint32x4", AttrFormat{ .uint = 4 } },
        .{ "unorm8x4", AttrFormat{ .unorm8 = 4 } },
    };
    inline for (table) |row| if (comptime std.mem.eql(u8, row[0], name)) return row[1];
    @compileError("unknown vertex format " ++ name);
}

/// The fixed-function state every quad draw sets: premultiplied-alpha blending (one,
/// one-minus-src-alpha), all channels written, and no scissor, depth, stencil, culling or
/// dithering, whatever the host left on.
pub fn quadState(f: *const Fns) void {
    f.glEnable(BLEND);
    f.glBlendFuncSeparate(ONE, ONE_MINUS_SRC_ALPHA, ONE, ONE_MINUS_SRC_ALPHA);
    f.glBlendEquation(FUNC_ADD);
    f.glColorMask(1, 1, 1, 1);
    f.glDisable(SCISSOR_TEST);
    f.glDisable(DEPTH_TEST);
    f.glDisable(STENCIL_TEST);
    f.glDisable(CULL_FACE);
    f.glDisable(DITHER);
}

/// `custom.rect` cut by `custom.clip` as (x, y, width, height) physical pixels inside a target
/// of `extent`, rows from the top. Pixels a quad would cover partly are included (floor the
/// start, ceil the end); an empty result has zero size. The Vulkan back end's `customScissor`.
pub fn scissor(extent: [2]u32, scale: f32, custom: draw_list.CustomDraw) [4]i32 {
    const w: f32 = @floatFromInt(extent[0]);
    const h: f32 = @floatFromInt(extent[1]);
    const x0 = std.math.clamp(@floor(@max(custom.rect[0], custom.clip[0]) * scale), 0, w);
    const y0 = std.math.clamp(@floor(@max(custom.rect[1], custom.clip[1]) * scale), 0, h);
    const x1 = std.math.clamp(@ceil(@min(custom.rect[2], custom.clip[2]) * scale), x0, w);
    const y1 = std.math.clamp(@ceil(@min(custom.rect[3], custom.clip[3]) * scale), y0, h);
    return .{ @intFromFloat(x0), @intFromFloat(y0), @intFromFloat(x1 - x0), @intFromFloat(y1 - y0) };
}

test "scissor is the rect cut by its clip, in pixels, inside the target" {
    const open: [4]f32 = .{ -1e6, -1e6, 1e6, 1e6 };
    try std.testing.expectEqual([4]i32{ 16, 16, 288, 208 }, scissor(.{ 320, 240 }, 2, .{ .rect = .{ 8, 8, 152, 112 }, .clip = open, .data = 0, .id = 0, .node = 0 }));
    try std.testing.expectEqual([4]i32{ 0, 200, 301, 40 }, scissor(.{ 320, 240 }, 2, .{ .rect = .{ -10, 100.25, 400, 300 }, .clip = .{ 0, 0, 150.2, 1e6 }, .data = 0, .id = 0, .node = 0 }));
    const empty = scissor(.{ 320, 240 }, 2, .{ .rect = .{ 50, 50, 60, 60 }, .clip = .{ 70, 70, 80, 80 }, .data = 0, .id = 0, .node = 0 });
    try std.testing.expectEqual(0, empty[2] * empty[3]);
}

/// Fetches every function of `T` (fields named as the GL function) through EGL. A function the
/// implementation does not return is an error: the table lists only what is called.
pub fn load(comptime T: type, lib: *const egl.Library) egl.Error!T {
    var t: T = undefined;
    inline for (@typeInfo(T).@"struct".field_names) |name| {
        @field(t, name) = @ptrCast(lib.proc(name.ptr) orelse return error.MissingFunction);
    }
    return t;
}
