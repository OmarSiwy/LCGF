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
//! again, and how an application draws its own widget, are the caller's to decide
//! (`vk.setup.Window.begin` and `present`). The tests draw through them and read the window
//! back: a whole frame, a frame damaged in one rect (T1 of docs/plans/window.md), a resize
//! and an out-of-date swapchain.

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
const Region = lcgf.damage.Region;
const Ui = vk.setup.Window.Ui;
const Rows = vk.setup.Window.Rows;

/// The colour of pixel (x, y) of X window `id`, read back from the server.
fn pixel(conn: *x11.Connection, id: u32, x: i16, y: i16) !Color {
    const r = try conn.reply(conn.send(wire.get_image_size, wire.getImage, .{ id, x, y, 1, 1 }));
    // bgra8 as the window's pixels; depth 24 keeps no alpha.
    return .{ .b = r[32], .g = r[33], .r = r[34], .a = 255 };
}

/// A window on the test's display with Vulkan over it, and a context to lay out its frames.
/// Filled in place: the renderer points at `g.setup`'s device.
const Fixture = struct {
    conn: x11.Connection,
    w: x11.Window,
    g: Gpu,
    ctx: Context,
    in: lcgf.input.Input,

    const Context = lcgf.context.Context;
    const DrawList = lcgf.draw_list.DrawList;
    const limits: lcgf.context.Limits = .{ .nodes = 1024, .texts = 4, .damage = true };
    var ctx_buffer: [Context.requiredBytes(limits)]u8 align(lcgf.mem.column_align) = @splat(0);
    // The shell's software framebuffer, which these tests never draw into.
    var pixels: [lcgf.render_sw.Framebuffer.len(16, 16)]u32 = undefined;
    var glyphs: [16]lcgf.draw_list.Quad = undefined;
    var first: [limits.texts]u32 = undefined;
    var count: [limits.texts]u32 = undefined;

    /// A `width` x `height` window, its viewport at scale 1.
    fn open(fx: *Fixture, display: []const u8, width: u16, height: u16) !void {
        std.debug.assert(width > 0);
        std.debug.assert(height > 0);
        fx.conn = .{};
        try fx.conn.open(display, "");
        errdefer fx.conn.close();
        const buffers: x11.Window.Buffers = .{
            .pixels = &pixels,
            .glyphs = &glyphs,
            .first = &first,
            .count = &count,
        };
        try fx.w.open(&fx.conn, width, height, "gpu", buffers);
        errdefer fx.w.close();
        // Mapped again as override-redirect, so a window manager on the display (a desktop's
        // Xwayland) neither resizes it nor answers its ConfigureWindow; Xvfb has none.
        _ = fx.conn.send(wire.window_size, wire.onWindow, .{ unmap_window, fx.w.id });
        _ = fx.conn.send(16, overrideRedirect, .{fx.w.id});
        _ = fx.conn.send(wire.window_size, wire.onWindow, .{ wire.op.map_window, fx.w.id });
        try fx.conn.sync();
        try fx.g.open(display, fx.w.id, fx.w.width, fx.w.height);
        fx.ctx = try .init(&ctx_buffer, limits);
        fx.in = .{ .viewport = .{ @floatFromInt(width), @floatFromInt(height) } };
    }

    fn close(fx: *Fixture) void {
        fx.g.close();
        fx.w.close();
        fx.conn.close();
    }

    /// A list that is all `back`, with a 100 x 80 square of `square` in the top left corner.
    fn list(fx: *Fixture, back: Color, square: Color) !*DrawList {
        var f = fx.ctx.begin(&fx.in);
        _ = f.open(.none, .{ .size = .{ .fill, .fill }, .fill = back });
        _ = f.leaf(.none, .{ .size = .{ .px(100), .px(80) }, .fill = square });
        f.close();
        const out = f.end(.{});
        try testing.expect(out.status.ok());
        return &fx.ctx.draw;
    }

    /// One frame at `size`: `new` uploaded (or none), `damage` drawn again, cleared to blue.
    fn present(fx: *Fixture, new: ?*const DrawList, damage: Region, size: c.VkExtent2D) !void {
        const f = try fx.g.target.begin(&fx.g.setup, size);
        const ui: Ui = .{ .rows = fx.rows(new), .damage = damage, .clear = .{ 0, 0, 1, 1 } };
        try fx.g.target.present(&fx.g.setup, &f, ui);
    }

    /// `new` as the rows of a frame at the fixture's viewport, or none.
    fn rows(fx: *const Fixture, new: ?*const DrawList) ?Rows {
        const l = new orelse return null;
        return .{ .list = l, .glyphs = .{}, .viewport = fx.in.viewport, .scale = 1 };
    }

    /// Presents frames with no new list and no damage until the window shows `want` at each
    /// of `at`: the implementation presents over its own connection, in its own time.
    fn waitShown(fx: *Fixture, size: c.VkExtent2D, at: []const [2]i16, want: []const Color) !void {
        for (0..400) |_| {
            try fx.present(null, .empty, size);
            for (at, want) |p, color| {
                if (!std.meta.eql(try pixel(&fx.conn, fx.w.id, p[0], p[1]), color)) break;
            } else return;
            fx.conn.waitReadable(0.005);
        }
        return error.NotShown;
    }
};

const unmap_window = 10;

/// ChangeWindowAttributes setting override-redirect on `window`.
fn overrideRedirect(b: *wire.Buf, window: u32) void {
    b.head(wire.op.change_window_attributes, 0, 4);
    b.int(u32, window);
    b.int(u32, 0x200); // override-redirect
    b.int(u32, 1);
}

/// ConfigureWindow setting `window`'s width and height.
fn resizeWindow(b: *wire.Buf, window: u32, width: u32, height: u32) void {
    b.head(wire.op.configure_window, 0, 5);
    b.int(u32, window);
    b.int(u16, 0xc); // width, height
    b.zeros(2);
    b.int(u32, width);
    b.int(u32, height);
}

const red: Color = .rgb(255, 0, 0);
const blue: Color = .rgb(0, 0, 255);
const white: Color = .rgb(255, 255, 255);

test "x11 gpu: a frame drawn by Vulkan is what the X window shows" {
    const display = testing.environ.getPosix("LCGF_X11_TEST_DISPLAY") orelse
        return error.SkipZigTest;
    var fx: Fixture = undefined;
    try fx.open(display, 256, 256);
    defer fx.close();
    // A red square in the top left corner of a blue window, one call a frame.
    const list = try fx.list(blue, red);
    const size: c.VkExtent2D = .{ .width = fx.w.width, .height = fx.w.height };
    var shown = false;
    for (0..400) |_| {
        try fx.g.target.draw(&fx.g.setup, list, .{}, fx.in.viewport, 1, .{ 0, 0, 1, 1 }, size);
        const inside = try pixel(&fx.conn, fx.w.id, 50, 40);
        const outside = try pixel(&fx.conn, fx.w.id, 200, 200);
        shown = std.meta.eql(inside, red) and std.meta.eql(outside, blue);
        if (shown) break;
        fx.conn.waitReadable(0.005);
    }
    try testing.expect(shown);
    // The square's edges are where layout put them.
    try testing.expectEqual(red, try pixel(&fx.conn, fx.w.id, 99, 79));
    try testing.expectEqual(blue, try pixel(&fx.conn, fx.w.id, 100, 40));
    try testing.expectEqual(blue, try pixel(&fx.conn, fx.w.id, 50, 80));
}

test "x11 gpu: T1, a red list damaged in a 32 x 32 rect shows red there and blue elsewhere" {
    const display = testing.environ.getPosix("LCGF_X11_TEST_DISPLAY") orelse
        return error.SkipZigTest;
    var fx: Fixture = undefined;
    try fx.open(display, 256, 256);
    defer fx.close();
    const size: c.VkExtent2D = .{ .width = fx.w.width, .height = fx.w.height };
    try fx.present(try fx.list(blue, blue), .everything, size);
    try fx.waitShown(size, &.{ .{ 0, 0 }, .{ 255, 255 } }, &.{ blue, blue });
    // All red, damaged in (120, 120) to (152, 152) only.
    const list = try fx.list(red, red);
    list.damage = .empty;
    list.damage.add(.{ 120, 120, 152, 152 });
    try fx.present(list, list.damage, size);
    // Its corners inside, a pixel past each edge outside, and the window's corner.
    const at = [_][2]i16{
        .{ 120, 120 }, .{ 151, 151 },
        .{ 119, 130 }, .{ 152, 130 },
        .{ 130, 119 }, .{ 130, 152 },
        .{ 0, 0 },
    };
    try fx.waitShown(size, &at, &.{ red, red, blue, blue, blue, blue, blue });
}

test "x11 gpu: an out-of-date swapchain is made again and the window drawn whole" {
    const display = testing.environ.getPosix("LCGF_X11_TEST_DISPLAY") orelse
        return error.SkipZigTest;
    var fx: Fixture = undefined;
    try fx.open(display, 256, 256);
    defer fx.close();
    const old: c.VkExtent2D = .{ .width = fx.w.width, .height = fx.w.height };
    try fx.present(try fx.list(white, red), .everything, old);
    try fx.waitShown(old, &.{ .{ 50, 40 }, .{ 200, 200 } }, &.{ red, white });
    // The window grows behind the swapchain's back: the host still asks for the old size,
    // so only the implementation's out-of-date or suboptimal report can make it again.
    // Lavapipe reports out of date from vkQueuePresentKHR. Not every driver reports at all:
    // NVIDIA 595 on Xwayland keeps presenting the old size, which the spec allows, and there
    // is then nothing to recover from.
    _ = fx.conn.send(20, resizeWindow, .{ fx.w.id, 320, 288 });
    try fx.conn.sync();
    var frames: u32 = 0;
    while (fx.g.target.picture.extent.width != 320) : (frames += 1) {
        if (frames == 400) return error.SkipZigTest;
        try fx.present(null, .empty, old);
    }
    try testing.expectEqual(@as(u32, 288), fx.g.target.picture.extent.height);
    // The new picture is drawn whole from the rows kept, though nothing was damaged: the
    // list, laid out for the old size, inside it, and the clear colour past it.
    const now: c.VkExtent2D = .{ .width = 320, .height = 288 };
    const at = [_][2]i16{ .{ 50, 40 }, .{ 200, 200 }, .{ 300, 270 } };
    try fx.waitShown(now, &at, &.{ red, white, blue });
}

test "x11 gpu: a resize makes the picture again at the new size and draws it whole" {
    const display = testing.environ.getPosix("LCGF_X11_TEST_DISPLAY") orelse
        return error.SkipZigTest;
    var fx: Fixture = undefined;
    try fx.open(display, 256, 256);
    defer fx.close();
    const old: c.VkExtent2D = .{ .width = fx.w.width, .height = fx.w.height };
    try fx.present(try fx.list(white, red), .everything, old);
    try fx.waitShown(old, &.{ .{ 50, 40 }, .{ 200, 200 } }, &.{ red, white });
    _ = fx.conn.send(20, resizeWindow, .{ fx.w.id, 320, 288 });
    try fx.conn.sync();
    // The host learns the size and lays out for it; the list says nothing changed, and all of
    // the new picture is drawn anyway.
    fx.in.viewport = .{ 320, 288 };
    const list = try fx.list(white, red);
    list.damage = .empty;
    const now: c.VkExtent2D = .{ .width = 320, .height = 288 };
    try fx.present(list, list.damage, now);
    try testing.expectEqual(@as(u32, 320), fx.g.target.picture.extent.width);
    const at = [_][2]i16{ .{ 50, 40 }, .{ 200, 200 }, .{ 300, 270 } };
    try fx.waitShown(now, &at, &.{ red, white, white });
}

/// A 2560 x 1440 window of 32 x 24 rounded, bordered cells (793 nodes, 768 quads); cell
/// `hot` is red, the rest grey.
fn grid(fx: *Fixture, hot: u32) *const Fixture.DrawList {
    std.debug.assert(hot < 32 * 24);
    var f = fx.ctx.begin(&fx.in);
    for (0..24) |row| {
        _ = f.open(.none, .{ .dir = .x, .size = .{ .fill, .px(60) } });
        for (0..32) |col| {
            const fill: Color = if (row * 32 + col == hot) red else .rgb(60, 60, 70);
            _ = f.leaf(.none, .{
                .size = .{ .px(76), .px(56) },
                .radius = 6,
                .border = 1,
                .border_color = white,
                .fill = fill,
            });
        }
        f.close();
    }
    _ = f.end(.{});
    return &fx.ctx.draw;
}

/// Nanoseconds on `clock`.
fn clockNs(clock: std.os.linux.clockid_t) u64 {
    var ts: std.os.linux.timespec = undefined;
    _ = std.os.linux.clock_gettime(clock, &ts);
    return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
}

/// Wall and calling-thread CPU time, summed over a mode's frames.
const Timer = struct {
    wall: u64 = 0,
    cpu: u64 = 0,
    at: [2]u64 = .{ 0, 0 },

    fn start(t: *Timer) void {
        t.at = .{ clockNs(.MONOTONIC), clockNs(.THREAD_CPUTIME_ID) };
    }

    fn stop(t: *Timer) void {
        t.wall += clockNs(.MONOTONIC) - t.at[0];
        t.cpu += clockNs(.THREAD_CPUTIME_ID) - t.at[1];
    }

    fn report(t: *const Timer, fd: i32, name: []const u8) void {
        const n: f64 = bench_frames * 1000;
        const wall_us = @as(f64, @floatFromInt(t.wall)) / n;
        const cpu_us = @as(f64, @floatFromInt(t.cpu)) / n;
        line(fd, "{s}: wall {d:.1} us, thread cpu {d:.1} us a frame\n", .{ name, wall_us, cpu_us });
    }
};

const bench_frames = 300;

/// Appends a formatted line to `fd`: the test runner fails a test that writes to stderr.
fn line(fd: i32, comptime format: []const u8, args: anytype) void {
    var buf: [256]u8 = undefined;
    const text = std.fmt.bufPrint(&buf, format, args) catch return;
    _ = std.os.linux.write(fd, text.ptr, text.len);
}

// Measures what a frame costs the CPU from the upload of the rows through vkQueueSubmit and
// vkQueuePresentKHR (`present`, or the same span of the whole redraw this window replaced),
// with the build of the list timed apart, and appends the numbers to the file
// LCGF_X11_GPU_BENCH names. The device is whatever VK_ICD_FILENAMES leaves presenting to the
// display.
test "x11 gpu: frame cost at 2560 x 1440 (LCGF_X11_GPU_BENCH)" {
    const display = testing.environ.getPosix("LCGF_X11_TEST_DISPLAY") orelse
        return error.SkipZigTest;
    const path = testing.environ.getPosix("LCGF_X11_GPU_BENCH") orelse
        return error.SkipZigTest;
    const flags: std.os.linux.O = .{ .ACCMODE = .WRONLY, .CREAT = true, .APPEND = true };
    const opened = std.os.linux.open(path, flags, 0o644);
    if (std.os.linux.errno(opened) != .SUCCESS) return error.BenchFile;
    const fd: i32 = @intCast(opened);
    defer _ = std.os.linux.close(fd);
    const frames = bench_frames;
    var fx: Fixture = undefined;
    try fx.open(display, 2560, 1440);
    defer fx.close();
    fx.ctx.trackDamageWhole();
    const t = &fx.g.target;
    const g = &fx.g.setup;
    const d = &g.device;
    const size: c.VkExtent2D = .{ .width = 2560, .height = 1440 };
    const clear: [4]f32 = .{ 0, 0, 0, 1 };
    const list = grid(&fx, 0);
    try fx.present(list, .everything, size);
    line(fd, "device {s}, {d} frames a mode, {d} quads\n", .{ d.name(), frames, list.quad_len });

    // The whole redraw this window replaced (the old `Window.draw`): every frame uploads the
    // rows, clears the swapchain image and draws the whole list into it.
    var old: Timer = .{};
    for (0..frames) |_| {
        const fr = try t.frames.begin(d, &t.chain);
        old.start();
        g.gfx.prepare(fr.slot, list, .{}, fx.in.viewport, 1);
        const target: vk.pass.Begin = .{
            .image = fr.image,
            .view = fr.view,
            .extent = t.chain.extent,
            .clear = clear,
        };
        vk.pass.begin(d, fr.cmd, target);
        g.gfx.render(fr.cmd, list);
        const shown = c.VK_IMAGE_LAYOUT_PRESENT_SRC_KHR;
        vk.pass.end(d, fr.cmd, .{ .image = fr.image, .layout = shown });
        _ = try t.frames.present(d, &t.chain, fr);
        old.stop();
    }
    try t.frames.wait(d);
    old.report(fd, "old whole redraw (into the swapchain image)");

    const modes = [_]struct { name: []const u8, rows: bool, damage: Region }{
        .{ .name = "whole redraw into the picture", .rows = true, .damage = .everything },
        .{ .name = "no new list, nothing damaged", .rows = false, .damage = .empty },
        .{ .name = "no new list, a 400 x 300 rect damaged", .rows = false, .damage = blk: {
            var r: Region = .empty;
            r.add(.{ 800, 400, 1200, 700 });
            break :blk r;
        } },
    };
    for (modes) |m| {
        var tm: Timer = .{};
        for (0..frames) |_| {
            const f = try t.begin(g, size);
            tm.start();
            const rows = fx.rows(if (m.rows) list else null);
            try t.present(g, &f, .{ .rows = rows, .damage = m.damage, .clear = clear });
            tm.stop();
        }
        try t.frames.wait(d);
        tm.report(fd, m.name);
    }

    // One cell changes each frame (a hover moving between two): a new list, damaged in the
    // two cells, 156 x 56.
    var build: Timer = .{};
    var draw: Timer = .{};
    for (0..frames) |n| {
        build.start();
        const l = grid(&fx, @intCast(n % 2));
        build.stop();
        try testing.expect(l.damage.pixels() < 2 * 80 * 60);
        const f = try t.begin(g, size);
        draw.start();
        try t.present(g, &f, .{ .rows = fx.rows(l), .damage = l.damage, .clear = clear });
        draw.stop();
    }
    try t.frames.wait(d);
    draw.report(fd, "one small damage rect, new list");
    build.report(fd, "  (its build, layout and paint)");
}
