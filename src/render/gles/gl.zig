//! The OpenGL ES functions and constants this back end calls, written by hand (no headers):
//! the subset of GL ES 3.0 the renderer and the test host use, fetched once through
//! `eglGetProcAddress` into a table. GL calls act on the context current on the calling thread.

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
};

/// GL ES 3.0 functions on top of `Fns`; a GL ES 2 driver need not have them.
pub const Fns3 = struct {
    glGetUniformBlockIndex: *const fn (Uint, [*:0]const u8) callconv(.c) Uint,
    glUniformBlockBinding: *const fn (Uint, Uint, Uint) callconv(.c) void,
};

/// Fetches every function of `T` (fields named as the GL function) through EGL. A function the
/// implementation does not return is an error: the table lists only what is called.
pub fn load(comptime T: type, lib: *const egl.Library) egl.Error!T {
    var t: T = undefined;
    inline for (@typeInfo(T).@"struct".field_names) |name| {
        @field(t, name) = @ptrCast(lib.proc(name.ptr) orelse return error.MissingFunction);
    }
    return t;
}
