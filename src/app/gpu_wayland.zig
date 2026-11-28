//! The GPU window on native Wayland: Vulkan drawing into images it exports as dma-bufs
//! (`vk.setup.Exported`), which the Wayland shell shares with the compositor through
//! zwp_linux_dmabuf_v1 and attaches on its own connection (src/shell/wayland), as
//! src/app/gpu.zig's window contract asks. The shell speaks the protocol itself, so there is
//! no `wl_display*` to give VK_KHR_wayland_surface: the images go to the compositor as buffers
//! instead of through a swapchain. Frames are paced by the compositor's frame callbacks; a
//! window that sends none within `wait_ms` (hidden, minimised) takes no frame
//! (error.NotShown).
//!
//! Contents
//!   pub const Window = struct        the contract: Vulkan into shared buffers on Wayland
//!   pub const Loop = gpu_loop.Gpu(Window)
//!   pub fn runApp(comptime App: type, app: *App, want: Want, clock: anytype) !bool

const std = @import("std");
const lcgf = @import("lcgf");
const vk = @import("vk");
const wl = @import("wayland");
const gpu_loop = @import("gpu.zig");
const gpu_vk = @import("gpu_vk.zig");
const context = lcgf.context;
const scheduler = lcgf.scheduler;
const Events = lcgf.shell_iface.Events;
const DrawList = lcgf.draw_list.DrawList;
const Region = lcgf.damage.Region;
const Color = lcgf.types.Color;
const Exported = vk.setup.Exported;
const ImageKind = gpu_loop.ImageKind;
const Channel = gpu_loop.Channel;

/// lcgf_app's GPU loop on Vulkan over native Wayland.
pub const Loop = gpu_loop.Gpu(Window);

/// Vulkan with no surface (`vk.Setup.initOffscreen`), its frames copied into `Exported`'s
/// shared images, each a wl_buffer of the shell's main window.
pub const Window = struct {
    g: vk.Setup,
    target: Exported,
    vk: gpu_vk.Kit,
    /// The shell: its connection, the main window's events, size and scale.
    w: *wl.Wayland,
    /// The wl_buffer over each of `target.images`, for its size.
    buffers: [Exported.count]u32,
    /// The image the frame between `begin` and `present` goes to.
    current: u32,

    pub const gpu = vk.gpu;
    pub const Image = vk.device.Image;
    pub const Frame = Exported.Frame;
    pub const max_textures = vk.renderer.CanvasRenderer.max_textures;
    /// The connected shell, its main window configured.
    pub const Shell = struct { w: *wl.Wayland };
    /// How long `begin` waits for the last frame's callback and for a free buffer.
    pub const wait_ms = 100;

    /// error.NoDmabuf: the compositor takes no LINEAR XRGB8888 dma-buf; error.NoDevice: no
    /// Vulkan device exports dma-bufs; either way nothing is left open.
    pub fn open(p: *Window, shell: Shell, o: gpu_loop.Open, handles: u16) !void {
        const w = shell.w;
        if (!w.dmabuf_linear) return error.NoDmabuf;
        const canvas: vk.Setup.Canvas = .{ .rows = o.canvas_rows, .verts = o.canvas_verts };
        try p.g.initOffscreen("lcgf", &Exported.device_extensions, Exported.format, canvas);
        errdefer p.g.deinit();
        p.w = w;
        const px = w.pixels(0);
        p.target = try .init(&p.g, .{ .width = px[0], .height = px[1] });
        errdefer p.target.deinit(&p.g);
        p.share();
        errdefer p.unshare();
        try p.vk.open(&p.g, o, handles);
        p.current = 0;
    }

    pub fn close(p: *Window) void {
        p.vk.close();
        p.unshare();
        p.target.deinit(&p.g);
        p.g.deinit();
    }

    pub fn waitIdle(p: *Window) void {
        p.vk.waitIdle();
    }

    pub fn createImage(p: *Window, kind: ImageKind, size: [2]u32) !Image {
        return p.vk.createImage(kind, size);
    }

    pub fn destroyImage(p: *Window, img: *Image) void {
        p.vk.destroyImage(img);
    }

    pub const extent = gpu_vk.Kit.extent;

    pub fn bind(p: *Window, handle: u16, img: *const Image) void {
        p.vk.bind(handle, img);
    }

    pub fn writeNow(p: *Window, img: *Image, bytes: []const u8) !void {
        try p.vk.writeNow(img, bytes);
    }

    pub fn targetTexture(img: *const Image) gpu.Texture {
        return gpu_vk.Kit.targetTexture(img, Loop.Surface.format);
    }

    /// The next frame at the window's size (the images made again first when it changed),
    /// once the last frame's callback came and an image is free. error.NotShown: neither
    /// within `wait_ms`.
    pub fn begin(p: *Window) !Frame {
        const w = p.w;
        std.debug.assert(p.buffers[p.current] != 0);
        const px = w.pixels(0);
        const e = p.target.extent;
        if (px[0] != e.width or px[1] != e.height) {
            p.unshare();
            try p.target.resize(&p.g, .{ .width = px[0], .height = px[1] });
            p.share();
        }
        const t0 = w.clock();
        // tidy: allow(unbounded-loop) bounded by `wait_ms` of the shell's clock
        const free = while (true) {
            if (!w.framePending()) if (p.freeImage()) |k| break k;
            const left = wait_ms - (w.clock() - t0) * 1000;
            if (!(left > 0) or w.closed) return error.NotShown;
            w.settle(@intFromFloat(@ceil(left)));
        };
        const f = try p.target.begin(&p.g);
        p.current = free;
        return f;
    }

    pub fn stage(p: *Window, f: *Frame, ch: Channel, bytes: u64) ![]u8 {
        return p.vk.stage(f.slot, ch, bytes);
    }

    // tidy: allow(too-many-parameters) the contract's copy: frame, channel, offset, image, rect
    pub fn copy(
        p: *Window,
        f: *Frame,
        ch: Channel,
        at: u64,
        img: *Image,
        r: gpu_loop.Rect,
        fresh: bool,
    ) void {
        p.vk.copy(f.cmd, f.slot, ch, at, img, r, fresh);
    }

    pub fn gpuFrame(p: *Window, f: *Frame) gpu_loop.GpuParts(gpu) {
        return p.vk.gpuFrame(f.cmd, f.slot);
    }

    /// Draws into the picture, copies it to the frame's image and commits that image's
    /// buffer, damaged where the frame drew (all of it when the picture was made again).
    pub fn present(p: *Window, f: *Frame, ui: gpu_loop.Ui) !void {
        std.debug.assert(f.slot < 2);
        const rows: ?vk.setup.Window.Rows = if (ui.rows) |r| .{
            .list = r.list,
            .glyphs = r.glyphs,
            .viewport = r.viewport,
            .scale = r.scale,
        } else null;
        const v: vk.setup.Window.Ui = .{
            .rows = rows,
            .damage = ui.damage,
            .clear = ui.clear,
            .canvases = ui.canvases,
        };
        const whole = p.target.lost;
        try p.target.present(&p.g, f, v, p.current);
        const e = p.target.extent;
        const px: [2]u32 = .{ e.width, e.height };
        var rects: [lcgf.damage.max_rects][4]u32 = undefined;
        var n: usize = 0;
        if (whole) {
            rects[0] = .{ 0, 0, px[0], px[1] };
            n = 1;
        } else for (0..lcgf.damage.max_rects) |k| {
            const r = Region.scissor(ui.damage.rect(@intCast(k)), px, p.g.gfx.scale);
            if (r[2] == 0 or r[3] == 0) continue;
            rects[n] = r;
            n += 1;
        }
        // The image is whole: one damaged rect still has the compositor read the new frame.
        if (n == 0) {
            rects[0] = .{ 0, 0, 1, 1 };
            n = 1;
        }
        p.w.commitBuffer(0, p.buffers[p.current], px, rects[0..n]);
    }

    pub fn kept(p: *const Window) ?*const DrawList {
        return p.vk.kept();
    }

    pub fn canvasUploaded(p: *const Window) ?usize {
        return p.vk.canvasUploaded();
    }

    pub fn poll(p: *Window, ev: *Events) gpu_loop.Polled {
        return if (p.w.poll(ev)) .ready else .closed;
    }

    pub fn apply(p: *Window, platform: *const context.Platform) void {
        p.w.apply(platform);
    }

    pub fn wait(p: *Window, s: f32, pace: scheduler.Pace) void {
        p.w.wait(s, pace);
    }

    pub fn wake(p: *Window) void {
        p.w.wake();
    }

    pub fn setBackground(p: *Window, color: Color) void {
        p.w.background = color;
    }

    pub fn background(p: *const Window) Color {
        return p.w.background;
    }

    /// An image the compositor does not hold, the one after the last committed first.
    fn freeImage(p: *const Window) ?u32 {
        for (1..Exported.count + 1) |step| {
            const k: u32 = @intCast((p.current + step) % Exported.count);
            if (!p.w.holds(p.buffers[k])) return k;
        }
        return null;
    }

    /// A wl_buffer over each shared image.
    fn share(p: *Window) void {
        const e = p.target.extent;
        for (&p.buffers, p.target.images) |*b, s| {
            const plane: wl.Wayland.Plane = .{
                .fd = s.fd,
                .offset = @intCast(s.offset),
                .stride = @intCast(s.stride),
            };
            b.* = p.w.shareDmabuf(plane, .{ e.width, e.height });
        }
    }

    fn unshare(p: *Window) void {
        for (&p.buffers) |*b| {
            if (b.* != 0) p.w.dropBuffer(b.*);
            b.* = 0;
        }
    }
};

/// Connects to the compositor `want.wayland` names, opens a toplevel and Vulkan into shared
/// buffers for it, and runs the loop there until the window closes. False, nothing left
/// open, when there is no compositor there, it takes no dma-buf, or no device exports one:
/// `run` then tries X11.
// tidy: allow-fn(large-generic-function) one instance per App
pub fn runApp(comptime App: type, app: *App, want: gpu_loop.Want, clock: anytype) !bool {
    std.debug.assert(want.size[0] > 0);
    std.debug.assert(want.size[1] > 0);
    if (want.wayland.len == 0) return false;
    // ponytail: static, as app.zig's buffers are: one window a program.
    const S = struct {
        var shell: wl.Wayland = undefined;
        var gw: Loop.Window = undefined;
    };
    const fd = wl.wire.connect(want.runtime_dir, want.wayland) catch return false;
    const size: [2]f32 = .{ @floatFromInt(want.size[0]), @floatFromInt(want.size[1]) };
    const bufs: wl.Wayland.Buffers = .{
        .glyphs = want.quads,
        .first = want.first,
        .count = want.count,
    };
    const options: wl.Wayland.Options = .{ .title = want.title, .size = size };
    S.shell = wl.Wayland.connect(fd, options, bufs) catch return false;
    defer S.shell.deinit();
    S.gw.open(.{ .w = &S.shell }, want.room) catch return false;
    defer S.gw.close();
    want.ctx.trackDamageWhole();
    const run: Loop.Run = .{
        .ctx = want.ctx,
        .tw = want.tw,
        .quads = want.quads,
        .first = want.first,
        .count = want.count,
    };
    try Loop.loop(App, app, &S.gw, run, clock);
    return true;
}

const testing = std.testing;
const text = @import("text.zig");
const x11_tests = @import("gpu_x11.zig");
const SurfaceApp = x11_tests.SurfaceApp;
const Clock = x11_tests.Clock;
const seconds = x11_tests.seconds;
const retry_seconds = gpu_loop.retry_seconds;
const Quad = lcgf.draw_list.Quad;

/// A toplevel on the test's compositor (LCGF_WAYLAND_TEST_DISPLAY, a socket in
/// XDG_RUNTIME_DIR) with Vulkan into shared buffers, and a context, the text in the bundled
/// font. Filled in place; its buffers are static, one fixture at a time.
const Fixture = struct {
    shell: wl.Wayland,
    gw: Loop.Window,
    ctx: context.Context,
    tw: text.Window,

    const limits: context.Limits = .{ .nodes = 64, .texts = 8, .customs = 4, .damage = true };
    const ctx_bytes = context.Context.requiredBytes(limits);
    var ctx_buffer: [ctx_bytes]u8 align(lcgf.mem.column_align) = @splat(0);
    var quads: [256]Quad = undefined;
    var first: [limits.texts]u32 = undefined;
    var count: [limits.texts]u32 = undefined;
    var canvas_rows: [2 * limits.customs]lcgf.draw_list.CanvasDraw = undefined;
    const text_options: text.Options = .{
        .atlas = .{ 256, 256 },
        .images = 256,
        .quads = 256,
        .texts = limits.texts,
        .run_glyphs = 64,
        .run_lines = 4,
        .shape_slots = 16,
    };
    var service: [text.Text.requiredBytes(text_options)]u8 align(lcgf.mem.column_align) = undefined;

    /// error.SkipZigTest: no test compositor named, or no dma-buf path to it (the compositor
    /// takes none, or no Vulkan device here exports one).
    fn open(fx: *Fixture, size: [2]f32) !void {
        std.debug.assert(size[0] > 0);
        const name = testing.environ.getPosix("LCGF_WAYLAND_TEST_DISPLAY") orelse
            return error.SkipZigTest;
        const dir = testing.environ.getPosix("XDG_RUNTIME_DIR") orelse "/tmp";
        const fd = try wl.wire.connect(dir, name);
        const bufs: wl.Wayland.Buffers = .{ .glyphs = &quads, .first = &first, .count = &count };
        const options: wl.Wayland.Options = .{ .title = "lcgf app gpu wayland", .size = size };
        fx.shell = try wl.Wayland.connect(fd, options, bufs);
        errdefer fx.shell.deinit();
        const room: gpu_loop.Open = .{ .gpu_bytes = 8 << 20, .staging_bytes = 1 << 20 };
        fx.gw.open(.{ .w = &fx.shell }, room) catch |e| switch (e) {
            error.NoDmabuf, error.NoDevice, error.InitializationFailed, error.OutOfMemory => {
                return error.SkipZigTest;
            },
            else => return e,
        };
        errdefer fx.gw.close();
        fx.ctx = try .init(&ctx_buffer, limits);
        fx.ctx.trackDamageWhole();
        fx.ctx.enableCanvas(&canvas_rows);
        const gpa = testing.allocator;
        fx.tw = try text.Window.open(&service, text_options, &.{}, false, gpa, testing.io);
    }

    fn close(fx: *Fixture) void {
        fx.tw.close();
        fx.gw.close();
        fx.shell.deinit();
    }

    fn run(fx: *Fixture, app: anytype, clock: anytype) !void {
        const r: Loop.Run = .{
            .ctx = &fx.ctx,
            .tw = &fx.tw,
            .quads = &quads,
            .first = &first,
            .count = &count,
        };
        try Loop.loop(@TypeOf(app.*), app, &fx.gw, r, clock);
    }

    /// Pixel (x, y) of the window's picture, which every frame copies whole into the buffer
    /// it commits (the vk test "exported" reads that copy back from the dma-buf itself).
    fn pixel(fx: *Fixture, x: u32, y: u32) !Color {
        const p = &fx.gw.p;
        const g = &p.g;
        const e = p.target.extent;
        std.debug.assert(x < e.width);
        std.debug.assert(y < e.height);
        const out = try testing.allocator.alloc(u8, @as(usize, e.width) * e.height * 4);
        defer testing.allocator.free(out);
        var h: vk.host.Host = .{
            .lib = g.lib,
            .instance = g.instance,
            .device = g.device,
            .once = g.once,
        };
        try h.readback(p.target.picture.handle, e, out);
        const at = (@as(usize, y) * e.width + x) * 4;
        // B8G8R8A8.
        return .rgb(out[at + 2], out[at + 1], out[at]);
    }

    /// The compositor took every frame: a locked session or a hidden workspace sends no frame
    /// callbacks, and a test that counts frames or reads pixels cannot run there.
    fn expectShown(fx: *Fixture) !void {
        if (fx.gw.stats.not_shown > 0) return error.SkipZigTest;
    }

    /// The window holds the test's content at scale 1 (a tiling compositor may make it
    /// larger: the content stays at the top left), or the test cannot read it.
    fn expectSize(fx: *Fixture, size: [2]u32) !void {
        const e = fx.gw.p.target.extent;
        if (fx.gw.p.g.gfx.scale != 1) return error.SkipZigTest;
        if (e.width < size[0] or e.height < size[1]) return error.SkipZigTest;
    }
};

test "wayland gpu T1: the frame is in the buffer the compositor shows" {
    var fx: Fixture = undefined;
    try fx.open(.{ 200, 100 });
    defer fx.close();
    var app: SurfaceApp = .{};
    try fx.run(&app, seconds(0.3));
    try fx.expectSize(.{ 200, 100 });
    try fx.expectShown();
    try testing.expect(fx.gw.stats.presents > 0);
    try testing.expectEqual(Color.rgb(0, 0, 200), try fx.pixel(30, 30));
    try testing.expectEqual(SurfaceApp.ground, try fx.pixel(90, 90));
    // The surface, drawn by `draw` with shade 0: green.
    try testing.expectEqual(Color.rgb(0, 255, 0), try fx.pixel(140, 50));
}

test "wayland gpu T2: surface frames build nothing, upload no rows, redraw only the surface" {
    var fx: Fixture = undefined;
    try fx.open(.{ 200, 100 });
    defer fx.close();
    var app: SurfaceApp = .{};
    try fx.run(&app, seconds(0.3));
    try fx.expectSize(.{ 200, 100 });
    const builds = app.builds;
    const rows = fx.gw.stats.row_bytes;
    const outside = try fx.pixel(30, 30);
    const Done = struct {
        a: *const SurfaceApp,
        pub fn stop(d: @This()) bool {
            return d.a.paints == 0;
        }
    };
    const draws = app.draws;
    app.paints = 100;
    app.plot.redraw();
    const t0: std.Io.Timestamp = .now(testing.io, .awake);
    try fx.run(&app, Clock(Done){ .t0 = t0, .seconds = 30, .done = .{ .a = &app } });
    try fx.expectShown();
    try testing.expect(app.draws - draws >= 100);
    try testing.expectEqual(builds, app.builds);
    try testing.expectEqual(rows, fx.gw.stats.row_bytes);
    try testing.expectEqual(SurfaceApp.plot_rect, fx.gw.stats.damage.bounds());
    try testing.expectEqual(@as(u32, 1), fx.gw.stats.damage.count());
    // The last paint's redraw, then nothing: what is shown.
    try fx.run(&app, seconds(0.2));
    try testing.expectEqual(outside, try fx.pixel(30, 30));
    const inside = try fx.pixel(140, 50);
    try testing.expectEqual(app.shade, inside.r);
    try testing.expectEqual(255 - app.shade, inside.g);
}

test "wayland gpu T3: widget frames beside a surface never call draw" {
    var fx: Fixture = undefined;
    try fx.open(.{ 200, 100 });
    defer fx.close();
    var app: SurfaceApp = .{};
    try fx.run(&app, seconds(0.3));
    const draws = app.draws;
    const builds = app.builds;
    const Done = struct {
        a: *const SurfaceApp,
        pub fn stop(d: @This()) bool {
            return d.a.toggles == 0;
        }
    };
    app.toggles = 100;
    fx.ctx.waker.post();
    const t0: std.Io.Timestamp = .now(testing.io, .awake);
    try fx.run(&app, Clock(Done){ .t0 = t0, .seconds = 30, .done = .{ .a = &app } });
    try testing.expect(app.builds - builds >= 100);
    try testing.expectEqual(draws, app.draws);
}

test "wayland gpu T4: an idle second presents nothing" {
    var fx: Fixture = undefined;
    try fx.open(.{ 200, 100 });
    defer fx.close();
    var app: SurfaceApp = .{};
    try fx.run(&app, seconds(0.3));
    const presents = fx.gw.stats.presents;
    const builds = app.builds;
    try fx.run(&app, seconds(1));
    try fx.expectShown();
    try testing.expectEqual(presents, fx.gw.stats.presents);
    try testing.expectEqual(builds, app.builds);
}

test "wayland gpu not shown: refused frames call no draw, then the window is drawn whole" {
    var fx: Fixture = undefined;
    try fx.open(.{ 200, 100 });
    defer fx.close();
    var app: SurfaceApp = .{};
    try fx.run(&app, seconds(0.3));
    try fx.expectSize(.{ 200, 100 });
    try fx.expectShown();
    const draws = app.draws;
    const whole = fx.gw.stats.whole;
    for (0..4) |k| {
        fx.gw.refuse = @intFromBool(k % 2 == 0);
        app.toggles = 1;
        fx.ctx.waker.post();
        try fx.run(&app, seconds(2 * retry_seconds + 0.2));
    }
    // Two refused here; more when the compositor itself takes no frames.
    if (fx.gw.stats.not_shown != 2) return error.SkipZigTest;
    try testing.expect(fx.gw.stats.whole > whole);
    try testing.expectEqual(draws, app.draws);
    // Four toggles: off again.
    try testing.expectEqual(Color.rgb(0, 0, 200), try fx.pixel(30, 30));
}

test "wayland gpu: runApp opens a toplevel on the compositor and draws a surface App there" {
    const name = testing.environ.getPosix("LCGF_WAYLAND_TEST_DISPLAY") orelse
        return error.SkipZigTest;
    const dir = testing.environ.getPosix("XDG_RUNTIME_DIR") orelse "/tmp";
    var ctx = try context.Context.init(&Fixture.ctx_buffer, Fixture.limits);
    ctx.enableCanvas(&Fixture.canvas_rows);
    const gpa = testing.allocator;
    const options = Fixture.text_options;
    var tw = try text.Window.open(&Fixture.service, options, &.{}, false, gpa, testing.io);
    defer tw.close();
    var app: SurfaceApp = .{};
    const want: gpu_loop.Want = .{
        .title = "lcgf runApp wayland",
        .size = .{ 200, 100 },
        .room = .{ .gpu_bytes = 8 << 20, .staging_bytes = 1 << 20 },
        .wayland = name,
        .runtime_dir = dir,
        .ctx = &ctx,
        .tw = &tw,
        .quads = &Fixture.quads,
        .first = &Fixture.first,
        .count = &Fixture.count,
    };
    // False: no dma-buf path here, the case the other tests skip.
    if (!try runApp(SurfaceApp, &app, want, seconds(0.3))) return error.SkipZigTest;
    try testing.expect(app.builds > 0);
    try testing.expect(app.draws > 0);
    // No compositor there: false, nothing opened.
    var none = want;
    none.wayland = "lcgf-no-such-socket";
    try testing.expect(!try runApp(SurfaceApp, &app, none, seconds(0.1)));
}
