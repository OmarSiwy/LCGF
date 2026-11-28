//! Direct3D 12 over a Win32 shell window: the device, and a flip-model swapchain on the
//! shell's HWND, and nothing about what is drawn on it. A module of its own over `lcgf`, the
//! shell and the Direct3D 12 back end. Where D3D12 cannot be opened `Gpu.open` fails and the
//! window keeps drawing in software (`Win32.presentWith`).
//!
//!     var g: Gpu = undefined;
//!     try g.open(&shell, .{});
//!     // g.setup: the device and renderer; g.target: the window's swapchain, frames, picture
//!     g.close();
//!
//! This is the ground a GPU window stands on, as src/shell/x11/gpu.zig is for X11 with Vulkan:
//! which parts of a frame are drawn again, and how an application draws its own widget, are
//! the caller's (`d3d12.setup.Window.begin` and `present`). The tests draw through them into
//! a real shell window under Windows or Wine and read the picture back.
//!
//! Contents
//!   pub const Gpu = struct
//!     pub fn open(g: *Gpu, w: *const win32.Win32, canvas: d3d12.Setup.Canvas) !void
//!     pub fn close(g: *Gpu) void

const std = @import("std");
const lcgf = @import("lcgf");
const d3d12 = @import("d3d12");
const win32 = @import("win32");

/// One window's Direct3D 12: the device and renderer, and the window's swapchain, frames and
/// picture. Filled in place, and not moved after: the renderer keeps a pointer to its device.
pub const Gpu = struct {
    setup: d3d12.Setup,
    target: d3d12.setup.Window,

    /// D3D12 on the primary adapter for shell window `w`, at its client size. An error leaves
    /// nothing open: no adapter or no D3D12 (`Unsupported`, `D3D12Failed`), or the
    /// implementation's own. `canvas` sizes the canvas pipeline (none by default). Asserts
    /// that the window has a client area.
    pub fn open(g: *Gpu, w: *const win32.Win32, canvas: d3d12.Setup.Canvas) !void {
        const size = w.clientSize();
        std.debug.assert(size[0] > 0);
        std.debug.assert(size[1] > 0);
        try g.setup.init(.{}, canvas);
        errdefer g.setup.deinit();
        g.target = try .init(&g.setup, @ptrCast(@alignCast(w.hwnd)), size);
    }

    pub fn close(g: *Gpu) void {
        g.target.deinit(&g.setup);
        g.setup.deinit();
    }
};

const testing = std.testing;
const Color = lcgf.types.Color;
const Region = lcgf.damage.Region;
const Events = lcgf.shell_iface.Events;

/// A shell window with D3D12 over it, and a context to lay out its frames. Filled in place.
const Fixture = struct {
    w: win32.Win32,
    g: Gpu,
    ctx: Context,

    const Context = lcgf.context.Context;
    const DrawList = lcgf.draw_list.DrawList;
    const limits: lcgf.context.Limits = .{ .nodes = 16, .texts = 1, .damage = true };
    var ctx_buffer: [Context.requiredBytes(limits)]u8 align(lcgf.mem.column_align) = @splat(0);
    var text: [64]u8 = undefined;
    var events: [16]lcgf.input.Input.Event = undefined;
    var preedit: [64]u8 = undefined;
    var names: [64]u8 = undefined;
    var ends: [4]u32 = undefined;
    // The shell's software framebuffer, which these tests never draw into.
    var pixels: [lcgf.render_sw.Framebuffer.len(16, 16)]u32 = undefined;
    var glyphs: [16]lcgf.draw_list.Quad = undefined;
    var first: [limits.texts]u32 = undefined;
    var count: [limits.texts]u32 = undefined;

    fn open(fx: *Fixture) !void {
        const buffers: win32.Win32.Buffers = .{
            .text = &text,
            .events = &events,
            .preedit = &preedit,
            .names = &names,
            .ends = &ends,
            .pixels = &pixels,
            .glyphs = &glyphs,
            .first = &first,
            .count = &count,
        };
        try fx.w.init(.{ .size = .{ 256, 192 }, .show = true }, buffers);
        errdefer fx.w.deinit();
        try fx.g.open(&fx.w, .{});
        fx.ctx = try .init(&ctx_buffer, limits);
    }

    fn close(fx: *Fixture) void {
        fx.g.close();
        fx.w.deinit();
    }

    /// A frame of the shell's, and a list that is all `back` with a 100 x 80 square of
    /// `square` in the top left corner, laid out for it.
    fn list(fx: *Fixture, back: Color, square: Color) !*DrawList {
        var ev: Events = .{};
        try testing.expect(fx.w.poll(&ev));
        var f = fx.ctx.begin(&ev.in);
        _ = f.open(.none, .{ .size = .{ .fill, .fill }, .fill = back });
        _ = f.leaf(.none, .{ .size = .{ .px(100), .px(80) }, .fill = square });
        f.close();
        const out = f.end(.{});
        try testing.expect(out.status.ok());
        return &fx.ctx.draw;
    }

    /// One frame at the client size: `new` uploaded (or none), `damage` drawn again, cleared
    /// to blue, waited for.
    fn present(fx: *Fixture, new: ?*const DrawList, damage: Region) !void {
        const t = &fx.g.target;
        const f = try t.begin(&fx.g.setup, fx.w.clientSize());
        var rows: ?d3d12.setup.Window.Rows = null;
        const in = &fx.w.t.in;
        std.debug.assert(in.scale > 0);
        if (new) |l| rows = .{
            .list = l,
            .glyphs = .{},
            .viewport = in.viewport,
            .scale = in.scale,
        };
        const ui: d3d12.setup.Window.Ui = .{
            .rows = rows,
            .damage = damage,
            .clear = .{ 0, 0, 1, 1 },
        };
        try t.present(&fx.g.setup, &f, ui);
        try fx.g.setup.device.waitIdle();
    }

    /// Frames of `back` drawn whole until the window keeps its size across a poll: Wine sizes
    /// a new window again as its X server configures it, which redraws all of the next frame.
    fn settle(fx: *Fixture, back: Color) !void {
        for (0..50) |_| {
            try fx.present(try fx.list(back, back), .everything);
            fx.w.wait(0.01, .idle);
            var ev: Events = .{};
            try testing.expect(fx.w.poll(&ev));
            const size = fx.w.clientSize();
            if (size[0] == fx.g.target.chain.width and size[1] == fx.g.target.chain.height) return;
        }
        return error.NeverSettled;
    }

    /// Pixel (x, y) of the picture.
    fn pixel(fx: *Fixture, x: u32, y: u32) !Color {
        const d = &fx.g.setup.device;
        const picture = fx.g.target.picture;
        var rb = try d3d12.host.Readback.init(d, fx.g.target.chain.width, fx.g.target.chain.height);
        defer rb.deinit();
        const l = try fx.g.setup.once.begin();
        rb.copy(l, picture);
        try fx.g.setup.once.submit(d);
        const p = try rb.buffer.map(true);
        defer rb.buffer.unmap();
        const at = p[y * rb.pitch + x * 4 ..][0..4];
        return .{ .r = at[0], .g = at[1], .b = at[2], .a = at[3] };
    }
};

const red: Color = .rgb(255, 0, 0);
const blue: Color = .rgb(0, 0, 255);
const white: Color = .rgb(255, 255, 255);

test "win32 gpu: the swapchain is the client area's size, and a frame draws the list" {
    var fx: Fixture = undefined;
    try fx.open();
    defer fx.close();
    const size = fx.w.clientSize();
    try testing.expectEqual(size[0], fx.g.target.chain.width);
    try testing.expectEqual(size[1], fx.g.target.chain.height);
    try fx.present(try fx.list(white, red), .everything);
    const s = fx.w.t.in.scale;
    const edge: u32 = @intFromFloat(@round(100 * s));
    try testing.expectEqual(red, try fx.pixel(edge - 1, 10));
    try testing.expectEqual(white, try fx.pixel(edge, 10));
    try testing.expectEqual(white, try fx.pixel(size[0] - 1, size[1] - 1));
}

test "win32 gpu: T1, a red list damaged in a 32 x 32 rect shows red there and blue elsewhere" {
    var fx: Fixture = undefined;
    try fx.open();
    defer fx.close();
    try fx.settle(blue);
    const list = try fx.list(red, red);
    list.damage = .empty;
    list.damage.add(.{ 64, 64, 96, 96 });
    try fx.present(list, list.damage);
    const s = fx.w.t.in.scale;
    const lo: u32 = @intFromFloat(@round(64 * s));
    const hi: u32 = @intFromFloat(@round(96 * s));
    try testing.expectEqual(red, try fx.pixel(lo, lo));
    try testing.expectEqual(red, try fx.pixel(hi - 1, hi - 1));
    try testing.expectEqual(blue, try fx.pixel(lo - 1, lo));
    try testing.expectEqual(blue, try fx.pixel(hi, lo));
    try testing.expectEqual(blue, try fx.pixel(0, 0));
}

test "win32 gpu: a window that grows is drawn whole at its new size" {
    var fx: Fixture = undefined;
    try fx.open();
    defer fx.close();
    try fx.present(try fx.list(white, red), .everything);
    // The user drags the frame larger: WM_SIZE gives the new client size and viewport.
    const old = fx.w.clientSize();
    const grown: [2]i32 = .{ @intCast(old[0] + 80), @intCast(old[1] + 64) };
    const keep = 0x0016; // SWP_NOMOVE | SWP_NOZORDER | SWP_NOACTIVATE
    try testing.expect(SetWindowPos(fx.w.hwnd, null, 0, 0, grown[0], grown[1], keep) != 0);
    const list = try fx.list(white, red);
    list.damage = .empty;
    const now = fx.w.clientSize();
    try testing.expect(now[0] > old[0]);
    try fx.present(list, list.damage);
    try testing.expectEqual(now[0], fx.g.target.chain.width);
    try testing.expectEqual(white, try fx.pixel(now[0] - 1, now[1] - 1));
    try testing.expectEqual(red, try fx.pixel(1, 1));
}

test "win32 gpu: a WM_PAINT marks the window damaged, for the host to present again" {
    var fx: Fixture = undefined;
    try fx.open();
    defer fx.close();
    try fx.present(try fx.list(white, red), .everything);
    var ev: Events = .{};
    _ = fx.w.poll(&ev);
    fx.w.damaged = false;
    // Uncovered: Windows asks the window to paint the area again.
    try testing.expect(InvalidateRect(fx.w.hwnd, null, 0) != 0);
    try testing.expect(fx.w.poll(&ev));
    try testing.expect(fx.w.damaged);
}

const Hwnd = @FieldType(win32.Win32, "hwnd");
extern "user32" fn InvalidateRect(Hwnd, ?*const anyopaque, c_int) callconv(.winapi) c_int;
extern "user32" fn SetWindowPos(Hwnd, ?*anyopaque, i32, i32, i32, i32, u32) callconv(.winapi) c_int;
