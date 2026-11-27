//! Vulkan over an X window: the surface, and nothing about what is drawn on it. A module of its
//! own over `lcgf` and the Vulkan back end, for a program that links libc. The Vulkan loader
//! and libxcb are opened by name when a window asks for them, so the program links neither, and
//! where one is missing `Gpu.open` fails and the window keeps drawing in software
//! (`x11.Window.present`).
//!
//! The shell speaks the X protocol itself and has no `xcb_connection_t`, which
//! VK_KHR_xcb_surface wants. `Xcb` opens a second connection to the same display, used for
//! nothing but the surface: the window is the one the shell made (an id is the server's, good
//! on any connection), and the Vulkan implementation presents over the second.
//!
//!     var g: Gpu = undefined;
//!     try g.open(display, window.id, window.width, window.height);
//!     // g.setup: the device and renderer; g.target: the window's swapchain and frames
//!     g.close();
//!
//! This is the ground a GPU window stands on, not the window: which parts of a frame are drawn
//! again, and how an application draws its own widget, are the caller's to decide. The test
//! draws whole frames with `vk.setup.Window.draw`, which clears and redraws everything.

const std = @import("std");
const lcgf = @import("lcgf");
const vk = @import("vk");
const c = vk.c;

pub const Error = error{
    /// libxcb is not on this machine, or is not the library this file expects.
    NoXcb,
    /// The display's name is too long, or libxcb could not connect to it.
    NoDisplay,
};

/// libxcb, opened by name, and a connection of its own to the display.
pub const Xcb = struct {
    lib: *anyopaque,
    connection: *anyopaque,
    disconnect: Disconnect,

    const Connect = *const fn (?[*:0]const u8, ?*c_int) callconv(.c) ?*anyopaque;
    const HasError = *const fn (*anyopaque) callconv(.c) c_int;
    const Disconnect = *const fn (*anyopaque) callconv(.c) void;

    /// Connects to `display` (":0", as DISPLAY has it).
    pub fn open(display: []const u8) Error!Xcb {
        var name: [64]u8 = undefined;
        if (display.len >= name.len) return error.NoDisplay;
        @memcpy(name[0..display.len], display);
        name[display.len] = 0;
        const lib = std.c.dlopen("libxcb.so.1", .{ .NOW = true }) orelse return error.NoXcb;
        errdefer _ = std.c.dlclose(lib);
        const connect = symbol(Connect, lib, "xcb_connect") orelse return error.NoXcb;
        const failed = symbol(HasError, lib, "xcb_connection_has_error") orelse return error.NoXcb;
        const disconnect = symbol(Disconnect, lib, "xcb_disconnect") orelse return error.NoXcb;
        const connection = connect(@ptrCast(&name), null) orelse return error.NoDisplay;
        // A connection that failed is still an object, in an error state, to be let go of.
        if (failed(connection) != 0) {
            disconnect(connection);
            return error.NoDisplay;
        }
        return .{ .lib = lib, .connection = connection, .disconnect = disconnect };
    }

    pub fn close(x: *Xcb) void {
        x.disconnect(x.connection);
        _ = std.c.dlclose(x.lib);
    }

    fn symbol(comptime T: type, lib: *anyopaque, name: [:0]const u8) ?T {
        return @ptrCast(@alignCast(std.c.dlsym(lib, name) orelse return null));
    }
};

/// The instance extensions a window on X11 needs.
pub const instance_extensions = [_][*:0]const u8{ "VK_KHR_surface", "VK_KHR_xcb_surface" };

/// VK_KHR_xcb_surface (vulkan_xcb.h, not in vulkan_core.h).
const XcbSurfaceCreateInfo = extern struct {
    sType: c.VkStructureType = 1000005000,
    pNext: ?*const anyopaque = null,
    flags: u32 = 0,
    connection: *anyopaque,
    window: u32,
};
const CreateXcbSurface = ?*const fn (
    c.VkInstance,
    *const XcbSurfaceCreateInfo,
    ?*const anyopaque,
    *c.VkSurfaceKHR,
) callconv(.c) c.VkResult;

/// An X window as libxcb's connection names it.
const Target = struct { connection: *anyopaque, window: u32 };

fn createSurface(instance: *const vk.loader.Instance, target: Target) !c.VkSurfaceKHR {
    const create = instance.proc(CreateXcbSurface, "vkCreateXcbSurfaceKHR") orelse
        return error.MissingExtension;
    var surface: c.VkSurfaceKHR = null;
    const info: XcbSurfaceCreateInfo = .{
        .connection = target.connection,
        .window = target.window,
    };
    try vk.loader.check(create(instance.handle, &info, null, &surface));
    return surface;
}

/// One window's Vulkan: the device and renderer, and the window's surface, swapchain and
/// frames. Filled in place, and not moved after: the renderer keeps a pointer to its device.
pub const Gpu = struct {
    xcb: Xcb,
    setup: vk.Setup,
    target: vk.setup.Window,

    /// Vulkan for X window `window` of `display`, `width` x `height` physical pixels. An error
    /// leaves nothing open: no libxcb (`NoXcb`), no Vulkan loader (`NoLoader`), no device that
    /// can present to the window (`NoDevice`), or the implementation's own.
    pub fn open(g: *Gpu, display: []const u8, window: u32, width: u32, height: u32) !void {
        std.debug.assert(width > 0);
        std.debug.assert(height > 0);
        g.xcb = try .open(display);
        errdefer g.xcb.close();
        const target: Target = .{ .connection = g.xcb.connection, .window = window };
        const surface = try g.setup.init("lcgf", &instance_extensions, target, createSurface);
        errdefer g.setup.deinit();
        errdefer vk.swapchain.destroySurface(&g.setup.instance, surface);
        g.target = try .init(&g.setup, surface, .{ .width = width, .height = height });
    }

    pub fn close(g: *Gpu) void {
        g.target.deinit(&g.setup);
        g.setup.deinit();
        g.xcb.close();
    }
};

const testing = std.testing;
const x11 = @import("x11");
const wire = lcgf.shell_x11_wire;
const Color = lcgf.types.Color;

/// The colour of pixel (x, y) of X window `id`, read back from the server.
fn pixel(conn: *x11.Connection, id: u32, x: i16, y: i16) !Color {
    const r = try conn.reply(conn.send(wire.get_image_size, wire.getImage, .{ id, x, y, 1, 1 }));
    // bgra8 as the window's pixels; depth 24 keeps no alpha.
    return .{ .b = r[32], .g = r[33], .r = r[34], .a = 255 };
}

test "x11 gpu: a frame drawn by Vulkan is what the X window shows" {
    const display = testing.environ.getPosix("LCGF_X11_TEST_DISPLAY") orelse
        return error.SkipZigTest;
    const limits: lcgf.context.Limits = .{ .nodes = 16, .texts = 4 };
    const side = 256;
    const Context = lcgf.context.Context;
    const Static = struct {
        var ctx_buffer: [Context.requiredBytes(limits)]u8 align(lcgf.mem.column_align) = undefined;
        var pixels: [lcgf.render_sw.Framebuffer.len(side, side)]u32 = undefined;
        var glyphs: [16]lcgf.draw_list.Quad = undefined;
        var first: [limits.texts]u32 = undefined;
        var count: [limits.texts]u32 = undefined;
    };
    var conn: x11.Connection = .{};
    try conn.open(display, "");
    defer conn.close();
    var w: x11.Window = undefined;
    const buffers: x11.Window.Buffers = .{
        .pixels = &Static.pixels,
        .glyphs = &Static.glyphs,
        .first = &Static.first,
        .count = &Static.count,
    };
    try w.open(&conn, side, side, "gpu", buffers);
    defer w.close();
    try conn.sync();

    var g: Gpu = undefined;
    try g.open(display, w.id, w.width, w.height);
    defer g.close();

    // A red square in the top left corner of a blue window.
    var ctx = try Context.init(&Static.ctx_buffer, limits);
    var in: lcgf.input.Input = .{ .viewport = .{ side, side } };
    const red: Color = .rgb(255, 0, 0);
    const blue: Color = .rgb(0, 0, 255);
    var f = ctx.begin(&in);
    _ = f.open(.none, .{ .size = .{ .fill, .fill } });
    _ = f.leaf(.none, .{ .size = .{ .px(100), .px(80) }, .fill = red });
    f.close();
    const out = f.end(.{});
    try testing.expect(out.status.ok());

    // The implementation presents over its own connection, in its own time: a second frame
    // is drawn while the first is on its way, and the window is read until it shows them.
    var shown = false;
    for (0..400) |_| {
        const size: c.VkExtent2D = .{ .width = w.width, .height = w.height };
        try g.target.draw(&g.setup, out.draw, .{}, in.viewport, 1, .{ 0, 0, 1, 1 }, size);
        const inside = try pixel(&conn, w.id, 50, 40);
        const outside = try pixel(&conn, w.id, 200, 200);
        shown = std.meta.eql(inside, red) and std.meta.eql(outside, blue);
        if (shown) break;
        conn.waitReadable(0.005);
    }
    try testing.expect(shown);
    // The square's edges are where layout put them.
    try testing.expectEqual(red, try pixel(&conn, w.id, 99, 79));
    try testing.expectEqual(blue, try pixel(&conn, w.id, 100, 40));
    try testing.expectEqual(blue, try pixel(&conn, w.id, 50, 80));
}
