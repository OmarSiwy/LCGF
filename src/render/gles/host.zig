//! An offscreen GL ES host for tests and tools: what an application owns (the context, render
//! targets, textures) and pixel read-back. Not part of the back end: the renderer creates or
//! keeps none of these.

const std = @import("std");
const egl = @import("egl.zig");
const gl = @import("gl.zig");

pub const Error = egl.Error || error{ IncompleteFramebuffer, GlError };

/// The library, a headless context and the GL function table, set up in place (`ctx` points at
/// `lib`, so a Host must not move after `init`).
pub const Host = struct {
    lib: egl.Library,
    ctx: egl.Context,
    gl: gl.Fns,
    /// Loaded when the context is GL ES 3 or later; undefined otherwise.
    gl3: gl.Fns3,
    /// GL ES 3.1 (compute), when the driver has it.
    gl31: ?gl.Fns31,

    pub fn init(h: *Host, desc: egl.Desc) Error!void {
        h.lib = try egl.Library.open();
        errdefer h.lib.close();
        h.ctx = try egl.Context.init(&h.lib, desc);
        errdefer h.ctx.deinit();
        h.gl = try gl.load(gl.Fns, &h.lib);
        h.gl31 = null;
        if (desc.major >= 3) {
            h.gl3 = try gl.load(gl.Fns3, &h.lib);
            h.gl31 = gl.load(gl.Fns31, &h.lib) catch null;
        }
    }

    pub fn deinit(h: *Host) void {
        h.ctx.deinit();
        h.lib.close();
    }

    /// Fails on any GL error raised since the last check.
    pub fn check(h: *const Host) Error!void {
        var failed = false;
        while (h.gl.glGetError() != gl.NO_ERROR) failed = true;
        if (failed) return error.GlError;
    }

    /// An RGBA8 texture of `w` x `h` texels from tightly packed rows (null: undefined contents),
    /// nearest filtering, clamped.
    pub fn texture(h: *const Host, w: u32, ht: u32, rgba: ?[]const u8) gl.Uint {
        const f = &h.gl;
        var t: gl.Uint = 0;
        f.glGenTextures(1, @ptrCast(&t));
        f.glBindTexture(gl.TEXTURE_2D, t);
        f.glTexParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.NEAREST);
        f.glTexParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.NEAREST);
        f.glTexParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE);
        f.glTexParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE);
        f.glPixelStorei(gl.UNPACK_ALIGNMENT, 1);
        f.glTexImage2D(gl.TEXTURE_2D, 0, @intCast(gl.RGBA), @intCast(w), @intCast(ht), 0, gl.RGBA, gl.UNSIGNED_BYTE, if (rgba) |p| p.ptr else null);
        return t;
    }

    pub fn deleteTexture(h: *const Host, t: gl.Uint) void {
        h.gl.glDeleteTextures(1, @ptrCast(&t));
    }

    /// Reads the bound framebuffer's `w` x `h` pixels as RGBA rows. Row 0 is GL's bottom row,
    /// which is the image's top row for the translated shaders: naga's GLSL output flips y in
    /// the vertex stage, so `gl_FragCoord` and the scissor count rows from the top as WGSL does.
    pub fn readback(h: *const Host, w: u32, ht: u32, out: []u8) void {
        std.debug.assert(out.len == @as(usize, w) * ht * 4);
        h.gl.glPixelStorei(gl.PACK_ALIGNMENT, 1);
        h.gl.glReadPixels(0, 0, @intCast(w), @intCast(ht), gl.RGBA, gl.UNSIGNED_BYTE, out.ptr);
    }
};

/// A framebuffer over an RGBA8 texture: what the pass draws into offscreen.
pub const Target = struct {
    fbo: gl.Uint = 0,
    color: gl.Uint = 0,
    w: u32,
    h: u32,

    pub fn init(h: *const Host, w: u32, ht: u32) Error!Target {
        const f = &h.gl;
        var t: Target = .{ .w = w, .h = ht, .color = h.texture(w, ht, null) };
        errdefer t.deinit(h);
        f.glGenFramebuffers(1, @ptrCast(&t.fbo));
        f.glBindFramebuffer(gl.FRAMEBUFFER, t.fbo);
        f.glFramebufferTexture2D(gl.FRAMEBUFFER, gl.COLOR_ATTACHMENT0, gl.TEXTURE_2D, t.color, 0);
        if (f.glCheckFramebufferStatus(gl.FRAMEBUFFER) != gl.FRAMEBUFFER_COMPLETE) return error.IncompleteFramebuffer;
        return t;
    }

    pub fn deinit(t: *Target, h: *const Host) void {
        if (t.fbo != 0) h.gl.glDeleteFramebuffers(1, @ptrCast(&t.fbo));
        if (t.color != 0) h.deleteTexture(t.color);
        t.fbo = 0;
        t.color = 0;
    }

    /// Binds the target and clears it to `rgba`: the start of a pass.
    pub fn begin(t: *const Target, h: *const Host, rgba: [4]f32) void {
        const f = &h.gl;
        f.glBindFramebuffer(gl.FRAMEBUFFER, t.fbo);
        f.glViewport(0, 0, @intCast(t.w), @intCast(t.h));
        f.glClearColor(rgba[0], rgba[1], rgba[2], rgba[3]);
        f.glClear(gl.COLOR_BUFFER_BIT);
    }
};

const testing = std.testing;

test "host: an ES 3 context on a real driver clears a target and reads it back" {
    var h: Host = undefined;
    try h.init(.{ .major = 3 });
    defer h.deinit();
    const version = std.mem.span(h.gl.glGetString(gl.VERSION).?);
    try testing.expect(std.mem.startsWith(u8, version, "OpenGL ES 3."));
    var t = try Target.init(&h, 4, 3);
    defer t.deinit(&h);
    t.begin(&h, .{ 1, 0.5, 0, 1 });
    var px: [4 * 3 * 4]u8 = undefined;
    h.readback(4, 3, &px);
    try h.check();
    for (0..12) |i| try testing.expectEqualSlices(u8, &.{ 255, 128, 0, 255 }, px[i * 4 ..][0..4]);
}

test "host: an ES 2 context comes up too" {
    var h: Host = undefined;
    try h.init(.{ .major = 2 });
    defer h.deinit();
    try testing.expect(std.mem.startsWith(u8, std.mem.span(h.gl.glGetString(gl.VERSION).?), "OpenGL ES "));
}
