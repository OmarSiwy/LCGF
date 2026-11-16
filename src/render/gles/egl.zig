//! EGL: the library, a display and an OpenGL ES context. libEGL (the platform's: libglvnd or the
//! vendor's own) is opened at run time and its few functions fetched by name; GL ES functions
//! come through `eglGetProcAddress` (gl.zig). No headers, no link-time dependency on EGL or GL.
//!
//!     var lib = try egl.Library.open();
//!     defer lib.close();
//!     var ctx = try egl.Context.init(&lib, .{ .major = 3 });
//!     defer ctx.deinit();
//!
//! `Context` is the headless one tests and tools use: Mesa's surfaceless platform when the
//! library has it (no window system, no GPU needed on llvmpipe), else the default display, made
//! current without a surface (EGL_KHR_surfaceless_context) or on a 1x1 pbuffer. Drawing goes into
//! framebuffer objects the host creates (host.zig). An application with a window makes its own
//! context and surface; the renderer only needs one current and the GL functions loaded.

const std = @import("std");
const builtin = @import("builtin");

pub const Display = ?*anyopaque;
pub const Config = ?*anyopaque;
pub const Ctx = ?*anyopaque;
pub const Surface = ?*anyopaque;
pub const Int = i32;
pub const Boolean = u32;
pub const Attrib = isize;

pub const NONE: Int = 0x3038;
pub const SUCCESS: Int = 0x3000;
pub const EXTENSIONS: Int = 0x3055;
pub const VERSION: Int = 0x3054;
pub const OPENGL_ES_API: u32 = 0x30A0;
pub const RENDERABLE_TYPE: Int = 0x3040;
pub const OPENGL_ES2_BIT: Int = 0x0004;
pub const OPENGL_ES3_BIT: Int = 0x0040;
pub const SURFACE_TYPE: Int = 0x3033;
pub const PBUFFER_BIT: Int = 0x0001;
pub const RED_SIZE: Int = 0x3024;
pub const GREEN_SIZE: Int = 0x3023;
pub const BLUE_SIZE: Int = 0x3022;
pub const ALPHA_SIZE: Int = 0x3021;
pub const CONTEXT_MAJOR_VERSION: Int = 0x3098;
pub const CONTEXT_MINOR_VERSION: Int = 0x30FB;
pub const WIDTH: Int = 0x3057;
pub const HEIGHT: Int = 0x3056;
pub const PLATFORM_SURFACELESS_MESA: u32 = 0x31DD;

pub const Error = error{ NoLibrary, MissingFunction, NoDisplay, InitializationFailed, NoConfig, ContextFailed, SurfaceFailed, MakeCurrentFailed };

/// The EGL functions this file calls, named as in EGL.
pub const Fns = struct {
    eglGetProcAddress: *const fn ([*:0]const u8) callconv(.c) ?*const anyopaque,
    eglGetError: *const fn () callconv(.c) Int,
    eglGetDisplay: *const fn (?*anyopaque) callconv(.c) Display,
    eglGetPlatformDisplay: *const fn (u32, ?*anyopaque, ?[*]const Attrib) callconv(.c) Display,
    eglInitialize: *const fn (Display, ?*Int, ?*Int) callconv(.c) Boolean,
    eglTerminate: *const fn (Display) callconv(.c) Boolean,
    eglQueryString: *const fn (Display, Int) callconv(.c) ?[*:0]const u8,
    eglBindAPI: *const fn (u32) callconv(.c) Boolean,
    eglChooseConfig: *const fn (Display, [*]const Int, ?[*]Config, Int, *Int) callconv(.c) Boolean,
    eglCreateContext: *const fn (Display, Config, Ctx, [*]const Int) callconv(.c) Ctx,
    eglDestroyContext: *const fn (Display, Ctx) callconv(.c) Boolean,
    eglCreatePbufferSurface: *const fn (Display, Config, [*]const Int) callconv(.c) Surface,
    eglDestroySurface: *const fn (Display, Surface) callconv(.c) Boolean,
    eglMakeCurrent: *const fn (Display, Surface, Surface, Ctx) callconv(.c) Boolean,
    eglReleaseThread: *const fn () callconv(.c) Boolean,
};

pub const Library = struct {
    handle: *anyopaque,
    fns: Fns,

    const names: []const [:0]const u8 = switch (builtin.os.tag) {
        .windows => &.{"libEGL.dll"},
        .macos, .ios => &.{"libEGL.dylib"},
        else => &.{ "libEGL.so.1", "libEGL.so" },
    };

    pub fn open() Error!Library {
        const handle = for (names) |name| {
            if (std.c.dlopen(name, .{ .NOW = true })) |h| break h;
        } else return error.NoLibrary;
        errdefer _ = std.c.dlclose(handle);
        var fns: Fns = undefined;
        const info = @typeInfo(Fns).@"struct";
        inline for (info.field_names) |name| {
            @field(fns, name) = @ptrCast(std.c.dlsym(handle, name.ptr) orelse return error.MissingFunction);
        }
        return .{ .handle = handle, .fns = fns };
    }

    pub fn close(lib: *Library) void {
        _ = std.c.dlclose(lib.handle);
    }

    /// A GL ES (or EGL extension) function by name, or null.
    pub fn proc(lib: *const Library, name: [*:0]const u8) ?*const anyopaque {
        return lib.fns.eglGetProcAddress(name);
    }
};

/// Whether `name` is a whole word of the space-separated extension list `list`.
pub fn hasExtension(list: []const u8, name: []const u8) bool {
    var it = std.mem.tokenizeScalar(u8, list, ' ');
    while (it.next()) |word| if (std.mem.eql(u8, word, name)) return true;
    return false;
}

pub const Desc = struct {
    /// GL ES major version: 3 for the instanced path, 2 for the path without instancing.
    major: Int = 3,
    minor: Int = 0,
};

/// A headless display and a GL ES context current on the calling thread.
pub const Context = struct {
    lib: *const Library,
    display: Display,
    config: Config = null,
    context: Ctx = null,
    /// A 1x1 pbuffer when the display cannot make a context current without a surface.
    surface: Surface = null,

    pub fn init(lib: *const Library, desc: Desc) Error!Context {
        const f = &lib.fns;
        const client = std.mem.span(f.eglQueryString(null, EXTENSIONS) orelse "");
        var display: Display = null;
        if (hasExtension(client, "EGL_MESA_platform_surfaceless")) display = f.eglGetPlatformDisplay(PLATFORM_SURFACELESS_MESA, null, null);
        if (display == null) display = f.eglGetDisplay(null);
        if (display == null) return error.NoDisplay;
        if (f.eglInitialize(display, null, null) == 0) return error.InitializationFailed;
        var c: Context = .{ .lib = lib, .display = display };
        errdefer c.deinit();
        if (f.eglBindAPI(OPENGL_ES_API) == 0) return error.InitializationFailed;
        const config_attrs = [_]Int{
            RENDERABLE_TYPE, if (desc.major >= 3) OPENGL_ES3_BIT else OPENGL_ES2_BIT,
            SURFACE_TYPE,    PBUFFER_BIT,
            RED_SIZE,        8,
            GREEN_SIZE,      8,
            BLUE_SIZE,       8,
            ALPHA_SIZE,      8,
            NONE,
        };
        var n: Int = 0;
        if (f.eglChooseConfig(display, &config_attrs, @ptrCast(&c.config), 1, &n) == 0 or n < 1) return error.NoConfig;
        const context_attrs = [_]Int{ CONTEXT_MAJOR_VERSION, desc.major, CONTEXT_MINOR_VERSION, desc.minor, NONE };
        c.context = f.eglCreateContext(display, c.config, null, &context_attrs);
        if (c.context == null) return error.ContextFailed;
        const exts = std.mem.span(f.eglQueryString(display, EXTENSIONS) orelse "");
        if (!hasExtension(exts, "EGL_KHR_surfaceless_context")) {
            const pbuffer_attrs = [_]Int{ WIDTH, 1, HEIGHT, 1, NONE };
            c.surface = f.eglCreatePbufferSurface(display, c.config, &pbuffer_attrs);
            if (c.surface == null) return error.SurfaceFailed;
        }
        if (f.eglMakeCurrent(display, c.surface, c.surface, c.context) == 0) return error.MakeCurrentFailed;
        return c;
    }

    pub fn deinit(c: *Context) void {
        const f = &c.lib.fns;
        _ = f.eglMakeCurrent(c.display, null, null, null);
        if (c.surface != null) _ = f.eglDestroySurface(c.display, c.surface);
        if (c.context != null) _ = f.eglDestroyContext(c.display, c.context);
        _ = f.eglTerminate(c.display);
        _ = f.eglReleaseThread();
        c.surface = null;
        c.context = null;
    }
};

test "hasExtension matches whole words only" {
    try std.testing.expect(hasExtension("EGL_KHR_a EGL_KHR_surfaceless_context EGL_b", "EGL_KHR_surfaceless_context"));
    try std.testing.expect(!hasExtension("EGL_KHR_surfaceless_context_x", "EGL_KHR_surfaceless_context"));
    try std.testing.expect(!hasExtension("", "EGL_KHR_surfaceless_context"));
}
