//! The GPU window on Linux: Vulkan over an X11 window (src/shell/x11/gpu.zig and
//! `vk.setup.Window`), as src/app/gpu.zig's window contract asks, and lcgf_app's GPU loop over
//! it (`Loop`). Under Wayland it runs through XWayland when `DISPLAY` is set.
//!
//! Contents
//!   pub const Window = struct        the contract: Vulkan over an X window
//!   pub const Loop = gpu_loop.Gpu(Window)

const std = @import("std");
const lcgf = @import("lcgf");
const vk = @import("vk");
const x11 = @import("x11");
const x11_gpu = @import("x11_gpu");
const gpu_loop = @import("gpu.zig");
const text = @import("text.zig");
const page = @import("page.zig");
const app_mod = @import("app.zig");
const context = lcgf.context;
const scheduler = lcgf.scheduler;
const Events = lcgf.shell_iface.Events;
const DrawList = lcgf.draw_list.DrawList;
const Quad = lcgf.draw_list.Quad;
const Color = lcgf.types.Color;
const c = vk.c;
const Device = vk.device.Device;
const ImageKind = gpu_loop.ImageKind;
const Channel = gpu_loop.Channel;

/// lcgf_app's GPU loop on Vulkan over X11.
pub const Loop = gpu_loop.Gpu(Window);

/// Vulkan over an X window of the shell's: the device, the swapchain and the picture
/// (`x11_gpu.Gpu`), the application's memory and staging, and the loop's mapped write buffers.
pub const Window = struct {
    x: x11_gpu.Gpu,
    /// The shell's window the GPU draws in: its events, size and background.
    w: *x11.Window,
    arena: gpu.Arena,
    staging_arena: gpu.Arena,
    /// The application's staging, a frame slot each.
    staging: [2]gpu.Staging,
    /// Mapped buffers the loop's own texture writes go through, per channel and frame slot.
    writes: [3][2]vk.device.Buffer,

    pub const gpu = vk.gpu;
    pub const Image = vk.device.Image;
    pub const Frame = vk.setup.Window.Frame;
    pub const max_textures = vk.renderer.CanvasRenderer.max_textures;
    /// The X window, and the display it is on (libxcb opens its own connection to it).
    pub const Shell = struct { w: *x11.Window, display: []const u8 };

    pub fn open(p: *Window, shell: Shell, o: gpu_loop.Open, handles: u16) !void {
        const w = shell.w;
        std.debug.assert(w.width > 0);
        const canvas: vk.Setup.Canvas = .{ .rows = o.canvas_rows, .verts = o.canvas_verts };
        try p.x.open(shell.display, w.id, w.width, w.height, canvas);
        errdefer p.x.close();
        p.w = w;
        const g = &p.x.setup;
        const d = &g.device;
        const dev: gpu.Device = .wrap(d);
        p.arena = try .init(dev, .{ .bytes = o.gpu_bytes });
        errdefer p.arena.deinit();
        const staging_bytes = 2 * o.staging_bytes + (1 << 16);
        p.staging_arena = try .init(dev, .{ .bytes = staging_bytes, .memory = .host });
        errdefer p.staging_arena.deinit();
        for (&p.staging) |*s| s.* = try .init(dev, &p.staging_arena, o.staging_bytes);
        while (g.gfx.texture_count < handles) _ = try g.gfx.addTexture(d, g.white.view, g.sampler);
        p.writes = @splat(.{ .{ .size = 0 }, .{ .size = 0 } });
    }

    pub fn close(p: *Window) void {
        const d = &p.x.setup.device;
        for (&p.writes) |*ch| for (ch) |*b| if (b.handle != null) d.destroyBuffer(b);
        for (p.staging) |s| s.deinit(.wrap(d));
        p.staging_arena.deinit();
        p.arena.deinit();
        p.x.close();
    }

    pub fn waitIdle(p: *Window) void {
        const d = &p.x.setup.device;
        _ = d.fns.vkDeviceWaitIdle.?(d.handle);
    }

    pub fn createImage(p: *Window, kind: ImageKind, size: [2]u32) !Image {
        std.debug.assert(size[0] > 0);
        std.debug.assert(size[1] > 0);
        const d = &p.x.setup.device;
        const sampled = c.VK_IMAGE_USAGE_SAMPLED_BIT;
        return switch (kind) {
            // Read as white with its byte as alpha, as `sw.Image.alpha8` is.
            .coverage => d.createImage(.{
                .width = size[0],
                .height = size[1],
                .format = c.VK_FORMAT_R8_UNORM,
                .usage = sampled | c.VK_IMAGE_USAGE_TRANSFER_DST_BIT,
                .components = .{
                    .r = c.VK_COMPONENT_SWIZZLE_ONE,
                    .g = c.VK_COMPONENT_SWIZZLE_ONE,
                    .b = c.VK_COMPONENT_SWIZZLE_ONE,
                    .a = c.VK_COMPONENT_SWIZZLE_R,
                },
            }),
            .rgba => d.createImage(.{
                .width = size[0],
                .height = size[1],
                .usage = sampled | c.VK_IMAGE_USAGE_TRANSFER_DST_BIT,
            }),
            .target => d.createImage(.{
                .width = size[0],
                .height = size[1],
                .usage = c.VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT | sampled,
            }),
        };
    }

    pub fn destroyImage(p: *Window, img: *Image) void {
        p.x.setup.device.destroyImage(img);
    }

    pub fn extent(img: *const Image) [2]u32 {
        return .{ img.extent.width, img.extent.height };
    }

    pub fn bind(p: *Window, handle: u16, img: *const Image) void {
        const g = &p.x.setup;
        g.gfx.setTexture(&g.device, @fromBackingInt(handle), img.view, g.sampler);
    }

    /// All of `img` from `bytes` in a submission of its own: for what `open` makes once.
    pub fn writeNow(p: *Window, img: *Image, bytes: []const u8) !void {
        const g = &p.x.setup;
        const d = &g.device;
        std.debug.assert(bytes.len > 0);
        var staging = try d.createBuffer(bytes.len, c.VK_BUFFER_USAGE_TRANSFER_SRC_BIT, true);
        defer d.destroyBuffer(&staging);
        @memcpy(staging.mapped[0..bytes.len], bytes);
        const cmd = try g.once.begin(d);
        const region: vk.host.Rect = .{ .w = img.extent.width, .h = img.extent.height };
        const from = c.VK_IMAGE_LAYOUT_UNDEFINED;
        vk.host.uploadRegion(d, cmd, img.handle, staging.handle, 0, from, region);
        try g.once.submit(d);
    }

    pub fn targetTexture(img: *const Image) gpu.Texture {
        return .{
            .image = img.handle,
            .view = img.view,
            .format = Loop.Surface.format,
            .width = img.extent.width,
            .height = img.extent.height,
            .samples = 1,
            .resting = c.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
        };
    }

    pub fn begin(p: *Window) !Frame {
        std.debug.assert(p.w.width > 0);
        return p.x.target.begin(&p.x.setup, .{ .width = p.w.width, .height = p.w.height });
    }

    /// Room for `bytes` in the frame slot's buffer of `ch`: made again larger when short (its
    /// frame slot's last frame is done: `begin` waited for it).
    pub fn stage(p: *Window, f: *Frame, ch: Channel, bytes: u64) ![]u8 {
        const b = &p.writes[@backingInt(ch)][f.acquired.slot];
        if (b.size < bytes) {
            const d = &p.x.setup.device;
            if (b.handle != null) d.destroyBuffer(b);
            const source = c.VK_BUFFER_USAGE_TRANSFER_SRC_BIT;
            b.* = try d.createBuffer(@max(bytes, 1 << 20), source, true);
        }
        return b.mapped[0..@intCast(bytes)];
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
        const d = &p.x.setup.device;
        const b = &p.writes[@backingInt(ch)][f.acquired.slot];
        const sampled = c.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL;
        const from: c.VkImageLayout = if (fresh) c.VK_IMAGE_LAYOUT_UNDEFINED else sampled;
        const x: i32 = @intCast(r.x);
        const y: i32 = @intCast(r.y);
        const region: vk.host.Rect = .{ .x = x, .y = y, .w = r.w, .h = r.h };
        vk.host.uploadRegion(d, f.cmd, img.handle, b.handle, at, from, region);
    }

    pub fn gpuFrame(p: *Window, f: *Frame) gpu_loop.GpuParts(gpu) {
        const d = &p.x.setup.device;
        const slot = f.acquired.slot;
        p.staging[slot].rewind();
        return .{
            .device = .wrap(d),
            .arena = &p.arena,
            .upload = .beginStaged(.wrap(d), f.cmd, &p.staging[slot]),
        };
    }

    pub fn present(p: *Window, f: *Frame, ui: gpu_loop.Ui) !void {
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
        try p.x.target.present(&p.x.setup, f, v);
    }

    pub fn kept(p: *const Window) ?*const DrawList {
        return p.x.setup.gfx.list;
    }

    pub fn canvasUploaded(p: *const Window) ?usize {
        const cv = p.x.setup.gfx.canvas orelse return null;
        return cv.uploaded;
    }

    /// An Expose: the server lost the window's pixels, which the picture still has.
    pub fn poll(p: *Window, ev: *Events) gpu_loop.Polled {
        p.w.conn.pump() catch return .closed;
        const exposed = p.w.damaged;
        if (!p.w.poll(ev)) return .closed;
        return if (exposed) .exposed else .ready;
    }

    pub fn apply(p: *Window, platform: *const context.Platform) void {
        p.w.apply(platform);
    }

    pub fn wait(p: *Window, seconds_: f32, pace: scheduler.Pace) void {
        p.w.wait(seconds_, pace);
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
};

/// Opens an X window on `want.display` and Vulkan over it, and runs the loop there until the
/// window closes. False, nothing left open, when there is no server there (a stale `DISPLAY`)
/// or no Vulkan device: the software path, which may find a compositor.
// tidy: allow-fn(large-generic-function) one instance per App
pub fn runApp(comptime App: type, app: *App, want: gpu_loop.Want, clock: anytype) !bool {
    std.debug.assert(want.size[0] > 0);
    std.debug.assert(want.size[1] > 0);
    // ponytail: static, as app.zig's buffers are: one window a program.
    const S = struct {
        var conn: x11.Connection = .{};
        var gw: Loop.Window = undefined;
    };
    S.conn.open(want.display, want.auth) catch return false;
    defer S.conn.close();
    var w: x11.Window = undefined;
    const bufs: x11.Window.Buffers = .{
        .pixels = &.{},
        .glyphs = want.quads,
        .first = want.first,
        .count = want.count,
    };
    const width: u16 = @intCast(want.size[0]);
    const height: u16 = @intCast(want.size[1]);
    try w.open(&S.conn, width, height, want.title, bufs);
    defer w.close();
    S.gw.open(.{ .w = &w, .display = want.display }, want.room) catch return false;
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

const Surface = Loop.Surface;
const GpuFrame = Loop.GpuFrame;
const Run = Loop.Run;
const loop = Loop.loop;
const retry_seconds = gpu_loop.retry_seconds;
const GpuWindow = Loop.Window;

const testing = std.testing;

/// A window on the test's server with Vulkan over it and a context, the text in the bundled
/// font. Filled in place; its buffers are static, one fixture at a time.
const Fixture = struct {
    conn: x11.Connection,
    w: x11.Window,
    /// The window size the test asked for.
    size: [2]u32,
    gw: GpuWindow,
    ctx: context.Context,
    tw: text.Window,

    const limits: context.Limits = .{ .nodes = 1024, .texts = 8, .customs = 4, .damage = true };
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
    const face = [_]text.File{.{ .bytes = @embedFile("layout.ttf") }};
    /// A label atlas, as `lcgf_app.run` gives an App with labels.
    const label_options: text.labels.Options = .{
        .atlas = .{ 256, 128 },
        .images = 64,
        .label_glyphs = 32,
    };
    const label_n = text.labels.Labels.requiredBytes(label_options);
    var label_bytes: [label_n]u8 align(lcgf.mem.column_align) = undefined;
    var label_atlas: text.labels.Labels = undefined;

    fn open(fx: *Fixture, display: []const u8, width: u16, height: u16) !void {
        try fx.openWith(display, width, height, &.{});
    }

    /// With the text service over `files` (none: the bundled font).
    fn openWith(fx: *Fixture, display: []const u8, w: u16, h: u16, files: []const text.File) !void {
        const room: gpu_loop.Open = .{ .gpu_bytes = 8 << 20, .staging_bytes = 1 << 20 };
        try fx.openRoom(display, .{ w, h }, files, room);
    }

    /// With the GPU window's room `o` (what app.zig makes of `Options.canvas`).
    // tidy: allow(too-many-parameters) the window's display, size, faces and room
    fn openRoom(
        fx: *Fixture,
        display: []const u8,
        size: [2]u16,
        files: []const text.File,
        o: gpu_loop.Open,
    ) !void {
        const w, const h = size;
        std.debug.assert(w > 0);
        fx.conn = .{};
        try fx.conn.open(display, "");
        errdefer fx.conn.close();
        fx.conn.overrideScale(1);
        const bufs: x11.Window.Buffers = .{
            .pixels = &.{},
            .glyphs = &quads,
            .first = &first,
            .count = &count,
        };
        try page.openTestWindow(&fx.w, &fx.conn, w, h, "lcgf app gpu", bufs);
        errdefer fx.w.close();
        fx.size = .{ w, h };
        try fx.gw.open(.{ .w = &fx.w, .display = display }, o);
        errdefer fx.gw.close();
        fx.ctx = try .init(&ctx_buffer, limits);
        fx.ctx.trackDamageWhole();
        fx.ctx.enableCanvas(&canvas_rows);
        const gpa = testing.allocator;
        fx.tw = try text.Window.open(&service, text_options, files, false, gpa, testing.io);
    }

    fn close(fx: *Fixture) void {
        fx.tw.close();
        fx.gw.close();
        fx.w.close();
        fx.conn.close();
    }

    /// Runs `app` until `clock` says stop.
    fn run(fx: *Fixture, app: anytype, clock: anytype) !void {
        const r: Run = .{
            .ctx = &fx.ctx,
            .tw = &fx.tw,
            .quads = &quads,
            .first = &first,
            .count = &count,
        };
        try loop(@TypeOf(app.*), app, &fx.gw, r, clock);
        // What the tests then read is drawn for the size they asked for.
        try page.skipResized(&fx.w, fx.size, true);
    }
};

/// Stops after `seconds`, or once `done` says so.
fn Clock(comptime Done: type) type {
    return struct {
        t0: std.Io.Timestamp,
        seconds: f32,
        done: Done,

        pub fn left(k: @This()) f32 {
            if (k.done.stop()) return 0;
            const ns = k.t0.durationTo(std.Io.Timestamp.now(testing.io, .awake)).toNanoseconds();
            return k.seconds - @as(f32, @floatFromInt(ns)) / std.time.ns_per_s;
        }
    };
}

const Never = struct {
    fn stop(_: Never) bool {
        return false;
    }
};

fn seconds(s: f32) Clock(Never) {
    return .{ .t0 = .now(testing.io, .awake), .seconds = s, .done = .{} };
}

/// A button-like box beside a surface the application paints one colour at a time: `paints`
/// more frames of it, each a new colour, while `hot` toggling makes widget frames.
const SurfaceApp = struct {
    plot: Surface = .{},
    builds: u32 = 0,
    draws: u32 = 0,
    /// Surface frames still to make, and widget frames still to make.
    paints: u32 = 0,
    toggles: u32 = 0,
    hot: bool = false,
    shade: u8 = 0,

    const ground: Color = .rgb(30, 30, 30);
    const plot_rect: [4]f32 = .{ 100, 20, 180, 80 };

    pub fn build(a: *SurfaceApp, f: *lcgf.frame.Frame, _: *const Events) void {
        a.builds += 1;
        // Toggled before it is drawn: the frame that toggles shows it.
        if (a.toggles > 0) {
            a.toggles -= 1;
            a.hot = !a.hot;
            f.ctx.waker.post();
        }
        _ = f.open(.none, .{ .size = .{ .fill, .fill }, .fill = ground });
        const box: Color = if (a.hot) .rgb(250, 250, 250) else .rgb(0, 0, 200);
        const button: [2]lcgf.types.Size = .{ .px(60), .px(30) };
        _ = f.leaf(.none, .{ .float = true, .offset = .{ 10, 20 }, .size = button, .fill = box });
        const plot: [2]lcgf.types.Size = .{ .px(80), .px(60) };
        _ = a.plot.node(f, .from("plot"), .{ .float = true, .offset = .{ 100, 20 }, .size = plot });
        f.close();
    }

    pub fn draw(a: *SurfaceApp, g: *GpuFrame) !void {
        a.draws += 1;
        const v: f64 = @as(f64, @floatFromInt(a.shade)) / 255;
        const enc = g.encoder();
        var pass = enc.beginRenderPass(.{ .color_attachments = &.{.{
            .view = a.plot.texture.createView(),
            .clear_value = .{ .r = v, .g = 1 - v, .b = 0, .a = 1 },
        }} });
        pass.end();
        if (a.paints > 0) {
            a.paints -= 1;
            a.shade +%= 2;
            a.plot.redraw();
        }
    }
};

/// Pixel (x, y) of the window once it is `want`, or as it is after a second: the Vulkan
/// implementation presents over its own connection, in its own time.
fn shown(w: *x11.Window, x: i16, y: i16, want: Color) !Color {
    var got = try x11.pixel(w, x, y);
    for (0..200) |_| {
        if (std.meta.eql(got, want)) break;
        w.conn.waitReadable(0.005);
        got = try x11.pixel(w, x, y);
    }
    return got;
}

fn displayOrSkip() ![]const u8 {
    return testing.environ.getPosix("LCGF_X11_TEST_DISPLAY") orelse error.SkipZigTest;
}

/// The window's pixels in `box` (x0, y0, x1, y1), row by row, into `out`.
fn readPixels(w: *x11.Window, box: [4]i16, out: []Color) !void {
    var k: usize = 0;
    var y = box[1];
    while (y < box[3]) : (y += 1) {
        var x = box[0];
        while (x < box[2]) : (x += 1) {
            out[k] = try x11.pixel(w, x, y);
            k += 1;
        }
    }
}

test "T2: surface frames under an idle UI build nothing, upload no rows, redraw only the surface" {
    var fx: Fixture = undefined;
    try fx.open(try displayOrSkip(), 200, 100);
    defer fx.close();
    var app: SurfaceApp = .{};
    try fx.run(&app, seconds(0.3));
    try testing.expect(app.draws >= 1);
    const builds = app.builds;
    const rows = fx.gw.stats.row_bytes;
    var before: [200 * 20]Color = undefined;
    try readPixels(&fx.w, .{ 0, 0, 200, 20 }, &before);
    const outside = try x11.pixel(&fx.w, 30, 30);

    const Done = struct {
        a: *const SurfaceApp,
        fn stop(d: @This()) bool {
            return d.a.paints == 0;
        }
    };
    const draws = app.draws;
    app.paints = 100;
    app.plot.redraw();
    try fx.run(&app, Clock(Done){ .t0 = .now(testing.io, .awake), .seconds = 30, .done = .{
        .a = &app,
    } });
    try testing.expect(app.draws - draws >= 100);
    try testing.expectEqual(builds, app.builds);
    try testing.expectEqual(rows, fx.gw.stats.row_bytes);
    // The picture's pass was scissored to the surface's rectangle, and only it.
    try testing.expectEqual(SurfaceApp.plot_rect, fx.gw.stats.damage.bounds());
    try testing.expectEqual(@as(u32, 1), fx.gw.stats.damage.count());
    // Shown: outside the same bytes, inside the last colour.
    try fx.run(&app, seconds(0.2));
    var after: [200 * 20]Color = undefined;
    try readPixels(&fx.w, .{ 0, 0, 200, 20 }, &after);
    try testing.expectEqualSlices(Color, &before, &after);
    try testing.expectEqual(outside, try x11.pixel(&fx.w, 30, 30));
    const inside = try x11.pixel(&fx.w, 140, 50);
    try testing.expectEqual(@as(u8, app.shade), inside.r);
    try testing.expectEqual(@as(u8, 255 - app.shade), inside.g);
}

test "T3: widget frames beside a surface never call draw" {
    var fx: Fixture = undefined;
    try fx.open(try displayOrSkip(), 200, 100);
    defer fx.close();
    var app: SurfaceApp = .{};
    try fx.run(&app, seconds(0.3));
    const draws = app.draws;
    const builds = app.builds;
    const Done = struct {
        a: *const SurfaceApp,
        fn stop(d: @This()) bool {
            return d.a.toggles == 0;
        }
    };
    app.toggles = 100;
    fx.ctx.waker.post();
    try fx.run(&app, Clock(Done){ .t0 = .now(testing.io, .awake), .seconds = 30, .done = .{
        .a = &app,
    } });
    try testing.expect(app.builds - builds >= 100);
    try testing.expectEqual(draws, app.draws);
}

test "T4: an idle second presents nothing" {
    var fx: Fixture = undefined;
    try fx.open(try displayOrSkip(), 200, 100);
    defer fx.close();
    var app: SurfaceApp = .{};
    try fx.run(&app, seconds(0.3));
    const presents = fx.gw.stats.presents;
    const builds = app.builds;
    try fx.run(&app, seconds(1));
    try testing.expectEqual(presents, fx.gw.stats.presents);
    try testing.expectEqual(builds, app.builds);
}

test "not shown: a frame the window does not take owes the whole window, drawn when it is" {
    var fx: Fixture = undefined;
    try fx.open(try displayOrSkip(), 200, 100);
    defer fx.close();
    var app: SurfaceApp = .{};
    try fx.run(&app, seconds(0.3));
    const presents = fx.gw.stats.presents;
    const builds = app.builds;
    const whole = fx.gw.stats.whole;
    // A widget changes while the window is hidden for two attempts.
    fx.gw.refuse = 2;
    app.toggles = 1;
    fx.ctx.waker.post();
    try fx.run(&app, seconds(2 * retry_seconds + 0.5));
    try testing.expectEqual(@as(u32, 2), fx.gw.stats.not_shown);
    // Built once (the toggle) and once more (its settle), drawn whole once shown.
    try testing.expect(app.builds - builds <= 2);
    try testing.expect(fx.gw.stats.presents > presents);
    try testing.expect(fx.gw.stats.whole > whole);
    const lit: Color = .rgb(250, 250, 250);
    try testing.expectEqual(lit, try shown(&fx.w, 30, 30, lit));
}

test "not shown: widget frames with every other one refused never call draw, then sleep" {
    var fx: Fixture = undefined;
    try fx.open(try displayOrSkip(), 200, 100);
    defer fx.close();
    var app: SurfaceApp = .{ .shade = 100 };
    try fx.run(&app, seconds(0.3));
    const draws = app.draws;
    const surface = try x11.pixel(&fx.w, 140, 50);
    const Presented = struct {
        a: *const SurfaceApp,
        gw: *const GpuWindow,
        fn stop(d: @This()) bool {
            return d.a.toggles == 0 and d.gw.rows == null;
        }
    };
    const frames = 8;
    for (0..frames) |k| {
        fx.gw.refuse = @intFromBool(k % 2 == 0);
        app.toggles = 1;
        fx.ctx.waker.post();
        const done: Presented = .{ .a = &app, .gw = &fx.gw };
        const t0: std.Io.Timestamp = .now(testing.io, .awake);
        const clock: Clock(Presented) = .{ .t0 = t0, .seconds = 3, .done = done };
        try fx.run(&app, clock);
        try testing.expect(done.stop());
        const want: Color = if (app.hot) .rgb(250, 250, 250) else .rgb(0, 0, 200);
        try testing.expectEqual(want, try shown(&fx.w, 30, 30, want));
    }
    try testing.expectEqual(@as(u32, frames / 2), fx.gw.stats.not_shown);
    // Each refused frame came back whole from the rows and the surface's texture on the GPU.
    try testing.expectEqual(draws, app.draws);
    const off: Color = .rgb(0, 0, 200);
    try testing.expectEqual(off, try shown(&fx.w, 30, 30, off));
    try testing.expectEqual(surface, try x11.pixel(&fx.w, 140, 50));

    // Hidden with a frame owed: the loop sleeps between `retry_seconds` attempts, no spin.
    fx.gw.refuse = 1000;
    app.toggles = 1;
    fx.ctx.waker.post();
    const presents = fx.gw.stats.presents;
    const refused = fx.gw.stats.not_shown;
    try fx.run(&app, seconds(1.2));
    try testing.expectEqual(presents, fx.gw.stats.presents);
    try testing.expectEqual(draws, app.draws);
    // The toggle and its settle, a retry each `retry_seconds`, and the one the clock's end woke.
    try testing.expect(fx.gw.stats.not_shown - refused <= 2 + 2 + 1);
    fx.gw.refuse = 0;
}

/// The application's image on a node, a line of text in the test face, and a box.
const PictureApp = struct {
    const green: Color = .rgb(0, 200, 0);
    const ground: Color = .rgb(30, 30, 30);
    const blue: Color = .rgb(0, 0, 220);
    const Picture = struct { pixels: []const u32, size: [2]u32, generation: u32 = 0 };
    /// Where image 0 and image 1 are shown.
    const first_rect = [4]f32{ 10, 10, 30, 30 };
    const second_at = [2]f32{ 50, 10 };
    texels: [4]u32 = @splat(green.bitsOf()),
    second: [4]u32 = @splat(blue.bitsOf()),
    list: [2]Picture = undefined,
    generation: u32 = 0,

    pub fn images(a: *PictureApp) []const Picture {
        a.list = .{
            .{ .pixels = &a.texels, .size = .{ 2, 2 }, .generation = a.generation },
            .{ .pixels = &a.second, .size = .{ 2, 2 } },
        };
        return &a.list;
    }

    pub fn build(_: *PictureApp, f: *lcgf.frame.Frame, _: *const Events) void {
        std.debug.assert(first_rect[0] < second_at[0]);
        _ = f.open(.none, .{ .size = .{ .fill, .fill }, .fill = ground });
        const at: [2]f32 = .{ first_rect[0], first_rect[1] };
        _ = f.leaf(.none, .{
            .float = true,
            .offset = at,
            .size = .{ .px(20), .px(20) },
            .fill = .white,
            .texture = @fromBackingInt(1),
        });
        _ = f.leaf(.none, .{
            .float = true,
            .offset = second_at,
            .size = .{ .px(20), .px(20) },
            .fill = .white,
            .texture = @fromBackingInt(2),
        });
        const line: lcgf.types.Style = .{ .float = true, .offset = .{ 100, 10 } };
        _ = f.textStyled("W", .{ .px = 20, .color = .white }, line);
        f.close();
    }
};

test "gpu images and text: an image and the service's glyphs draw; a new generation, its nodes" {
    var fx: Fixture = undefined;
    try fx.openWith(try displayOrSkip(), 200, 100, &Fixture.face);
    defer fx.close();
    try testing.expect(fx.tw.on());
    var app: PictureApp = .{};
    try fx.run(&app, seconds(0.3));
    try testing.expectEqual(PictureApp.green, try shown(&fx.w, 20, 20, PictureApp.green));
    try testing.expectEqual(PictureApp.ground, try x11.pixel(&fx.w, 50, 50));
    // The glyph covers part of its box, smoothly: some pixels lit, most of the box not.
    var lit: u32 = 0;
    for (10..35) |y| for (100..115) |x| {
        lit += @intFromBool((try x11.pixel(&fx.w, @intCast(x), @intCast(y))).r > 128);
    };
    try testing.expect(lit > 12);
    try testing.expect(lit < 15 * 25 / 2);

    // New pixels in image 0, under a new generation: only its node is drawn, from them; image 1
    // is not drawn again, and an idle second after presents nothing.
    const whole = fx.gw.stats.whole;
    const red: Color = .rgb(220, 0, 0);
    app.texels = @splat(red.bitsOf());
    app.generation += 1;
    fx.ctx.waker.post();
    try fx.run(&app, seconds(0.3));
    try testing.expectEqual(red, try shown(&fx.w, 20, 20, red));
    try testing.expectEqual(PictureApp.first_rect, fx.gw.stats.damage.bounds());
    try testing.expectEqual(@as(u32, 1), fx.gw.stats.damage.count());
    try testing.expectEqual(whole, fx.gw.stats.whole);
    try testing.expectEqual(PictureApp.blue, try x11.pixel(&fx.w, 60, 20));
    const presents = fx.gw.stats.presents;
    try fx.run(&app, seconds(1));
    try testing.expectEqual(presents, fx.gw.stats.presents);
}

test "gpu page: a composed page draws both sides; a pan scissors the canvas; idle presents none" {
    var fx: Fixture = undefined;
    try fx.openWith(try displayOrSkip(), 300, 200, &Fixture.face);
    defer fx.close();
    try testing.expect(fx.tw.on());
    const T = page.TestApp;
    var app: T = .{};
    try fx.run(&app, seconds(0.3));
    const plot = app.canvas_rect;
    try testing.expectEqual(T.tint, try shown(&fx.w, 258, 16, T.tint));
    try testing.expectEqual(T.page_fill, try x11.pixel(&fx.w, 200, 4));
    try testing.expectEqual(T.region_fill, try x11.pixel(&fx.w, 290, 190));
    try testing.expectEqual(T.red, try page.pixelIn(&fx.w, plot, 15, 15));
    try page.expectPageText(&fx.w, &app, &fx.tw.text.?);

    // A pan: one frame built, its pass scissored to the canvas node's rect; no `draw` (none).
    const builds = fx.gw.stats.builds;
    app.view.camera.offset = .{ 50, 30 };
    fx.ctx.waker.post();
    try fx.run(&app, seconds(0.3));
    try testing.expectEqual(plot, fx.gw.stats.damage.bounds());
    try testing.expectEqual(@as(u32, 1), fx.gw.stats.damage.count());
    try testing.expectEqual(T.red, try page.pixelIn(&fx.w, plot, 55, 35));
    try testing.expectEqual(T.canvas_fill, try page.pixelIn(&fx.w, plot, 15, 15));
    try testing.expect(fx.gw.stats.builds > builds);
    try testing.expectEqual(@as(u32, 0), fx.gw.stats.draws);

    // The compiled checkbox: within its rect.
    const widget = app.widgetRect();
    app.ui.signals.state.grid = false;
    fx.ctx.waker.post();
    try fx.run(&app, seconds(0.3));
    const d = fx.gw.stats.damage.bounds();
    try testing.expect(d[0] >= widget[0] and d[1] >= widget[1]);
    try testing.expect(d[2] <= widget[2] and d[3] <= widget[3]);

    // The page's icon gets new pixels: its node is the scissor, and nothing else.
    app.clearIcon();
    fx.ctx.waker.post();
    try fx.run(&app, seconds(0.3));
    try testing.expectEqual(T.icon_rect, fx.gw.stats.damage.bounds());
    try testing.expectEqual(T.page_fill, try shown(&fx.w, 258, 16, T.page_fill));

    // Idle: nothing presented.
    const presents = fx.gw.stats.presents;
    try fx.run(&app, seconds(1));
    try testing.expectEqual(presents, fx.gw.stats.presents);
}

test "gpu page: a canvas label in a composed page's region draws as the reference" {
    var fx: Fixture = undefined;
    try fx.openWith(try displayOrSkip(), 300, 200, &Fixture.face);
    defer fx.close();
    Fixture.label_atlas = .init(&Fixture.label_bytes, Fixture.label_options);
    fx.tw.labels = &Fixture.label_atlas;
    const handle: text.labels.Handle = .{ .text = &fx.tw.text.?, .labels = &Fixture.label_atlas };
    var app: page.TestApp = .{ .labels = handle };
    try fx.run(&app, seconds(0.3));
    try testing.expect(app.labelled);
    _ = try shown(&fx.w, 258, 16, page.TestApp.tint);
    try page.expectCanvas(&fx.w, &app);
    try page.expectPageText(&fx.w, &app, &fx.tw.text.?);
    // A pan by `redraw`: no frame built, the label and the square where the reference puts them.
    const builds = fx.gw.stats.builds;
    app.view.camera.offset = .{ 30, 20 };
    app.view.redraw();
    try runPanned(&fx, &app);
    try testing.expectEqual(builds, fx.gw.stats.builds);
    try page.expectCanvas(&fx.w, &app);
}

test "gpu canvas: bitmap canvas glyphs sample the bundled font beside the service's text" {
    for ([_][]const text.File{ &Fixture.face, &.{} }) |files| {
        var fx: Fixture = undefined;
        try fx.openWith(try displayOrSkip(), 300, 200, files);
        defer fx.close();
        try testing.expectEqual(files.len != 0, fx.tw.on());
        const Shapes = lcgf.canvas.Instances;
        const Rows = struct {
            const n = Shapes.requiredBytes(64, 1, 1, .{});
            var bytes: [n]u8 align(lcgf.mem.column_align) = undefined;
            var reference: [lcgf.render_sw.Framebuffer.len(300, 200)]u32 = undefined;
        };
        var carver: lcgf.mem.Carver = .{ .buf = &Rows.bytes };
        var shapes = Shapes.init(&carver, 64, 1, 1, .{});
        var app: text.labels.BitmapApp = .{ .shapes = &shapes };
        for ([_]f32{ 1, 2 }) |s| {
            fx.conn.overrideScale(s);
            fx.ctx.waker.post();
            try fx.run(&app, seconds(0.3));
            try app.expectWindow(&fx.w, x11.pixel, s, &Rows.reference);
        }
    }
}

/// 100,000 filled squares `cell` logical pixels a side, `across` to a line, in their own grey,
/// the first, the middle and the last red, green and blue; the camera `pan` pixels right.
/// `moves` more frames each move it a pixel.
const RowsApp = struct {
    const n = 100_000;
    const Instances = lcgf.canvas.Instances;
    const Storage = struct {
        const len = Instances.requiredBytes(n, 0, 1, .{});
        var bytes: [len]u8 align(lcgf.mem.column_align) = undefined;
    };
    const grey: Color = .rgb(64, 64, 64);
    const picked = [3]u32{ 0, n / 2, n - 1 };
    const colors = [3]Color{ .rgb(255, 0, 0), .rgb(0, 255, 0), .rgb(0, 0, 255) };
    shapes: Instances,
    cell: u32,
    across: u32,
    pan: i32 = 0,
    moves: u32 = 0,
    builds: u32 = 0,
    ranges: [1]lcgf.canvas.Range = undefined,

    fn init(cell: u32, across: u32) RowsApp {
        std.debug.assert(cell > 0);
        var carver: lcgf.mem.Carver = .{ .buf = &Storage.bytes };
        const shapes: Instances = .init(&carver, n, 0, 1, .{});
        var a: RowsApp = .{ .shapes = shapes, .cell = cell, .across = across };
        for (0..n) |k| {
            const p = a.at(@intCast(k));
            const q = [2]i32{ p[0] + @as(i32, @intCast(cell)), p[1] + @as(i32, @intCast(cell)) };
            _ = a.shapes.rect(p, q, .{ .color = grey, .stroke = false });
        }
        for (picked, colors) |k, color| a.shapes.setColor(k, color);
        return a;
    }

    /// Row `k`'s top-left corner, logical pixels at camera scale 1 and no pan.
    fn at(a: *const RowsApp, k: u32) [2]i32 {
        return .{ @intCast((k % a.across) * a.cell), @intCast((k / a.across) * a.cell) };
    }

    pub fn build(a: *RowsApp, f: *lcgf.frame.Frame, _: *const Events) void {
        a.builds += 1;
        if (a.moves > 0) {
            a.moves -= 1;
            a.pan += 1;
            f.ctx.waker.post();
        }
        a.ranges = .{a.shapes.since(0)};
        _ = f.open(.none, .{ .size = .{ .fill, .fill }, .fill = .black });
        const cam: lcgf.canvas.Camera = .{ .scale = 1, .offset = .{ @floatFromInt(a.pan), 0 } };
        const o: lcgf.frame.CanvasOptions = .{ .camera = cam, .ranges = &a.ranges };
        _ = f.canvas(.from("rows"), .{ .size = .{ .fill, .fill } }, &a.shapes, o);
        f.close();
    }
};

/// The GPU window's room for `RowsApp`: `Options.canvas = .{ .rows = 100_000 }`.
const rows_room: gpu_loop.Open = .{ .staging_bytes = 8 << 20, .canvas_rows = RowsApp.n };

test "gpu canvas: 100,000 rows draw to the last one, and a pan uploads none of them" {
    var fx: Fixture = undefined;
    try fx.openRoom(try displayOrSkip(), .{ 808, 500 }, &.{}, rows_room);
    defer fx.close();
    var app: RowsApp = .init(2, 400);
    try fx.run(&app, seconds(0.5));
    try testing.expectEqual(null, fx.gw.p.x.setup.gfx.canvas.?.err);
    try expectRows(&fx, &app);
    // Four frames, the camera a pixel further each: the rows stay where they were uploaded.
    const bytes = fx.gw.stats.canvas_bytes;
    const presents = fx.gw.stats.presents;
    app.moves = 4;
    fx.ctx.waker.post();
    try fx.run(&app, seconds(0.5));
    try testing.expectEqual(4, app.pan);
    try testing.expect(fx.gw.stats.presents - presents >= 4);
    const uniforms = lcgf.canvas_shader.Uniforms.headBytes(0);
    try testing.expect(fx.gw.stats.canvas_bytes - bytes <= 8 * uniforms);
    try expectRows(&fx, &app);
}

/// The first, the middle and the last row of `app` in their colours, and the row before the
/// last grey: a canvas that drew short leaves the ground there.
fn expectRows(fx: *Fixture, app: *const RowsApp) !void {
    std.debug.assert(app.cell >= 2);
    for (RowsApp.picked, RowsApp.colors) |k, want| {
        const p = app.at(k);
        const got = try shown(&fx.w, @intCast(p[0] + app.pan + 1), @intCast(p[1] + 1), want);
        try testing.expectEqual(want, got);
    }
    const p = app.at(RowsApp.n - 2);
    const got = try shown(&fx.w, @intCast(p[0] + app.pan + 1), @intCast(p[1] + 1), RowsApp.grey);
    try testing.expectEqual(RowsApp.grey, got);
}

/// A canvas with a half-transparent line, and a box beside it that `lit` turns white.
const CanvasApp = struct {
    shapes: *const lcgf.canvas.Instances,
    palette: *const lcgf.canvas.Palette,
    /// Read when the frame is drawn, after `build`: kept here, not on its stack.
    ranges: [1]lcgf.canvas.Range,
    lit: bool = false,

    pub fn build(a: *CanvasApp, f: *lcgf.frame.Frame, _: *const Events) void {
        _ = f.open(.none, .{ .size = .{ .fill, .fill }, .fill = .rgb(30, 30, 30) });
        const side: [2]lcgf.types.Size = .{ .px(80), .px(80) };
        const view: lcgf.types.Style = .{ .float = true, .offset = .{ 10, 10 }, .size = side };
        const o: lcgf.frame.CanvasOptions = .{ .palette = a.palette, .ranges = &a.ranges };
        _ = f.canvas(.from("canvas"), view, a.shapes, o);
        const box: Color = if (a.lit) .white else .rgb(0, 0, 200);
        const square: [2]lcgf.types.Size = .{ .px(30), .px(30) };
        _ = f.leaf(.none, .{ .float = true, .offset = .{ 120, 10 }, .size = square, .fill = box });
        f.close();
    }
};

test "gpu labels: labels draw as the reference at camera and window scales; a pan uploads none" {
    var fx: Fixture = undefined;
    try fx.openWith(try displayOrSkip(), 200, 100, &Fixture.face);
    defer fx.close();
    Fixture.label_atlas = .init(&Fixture.label_bytes, Fixture.label_options);
    fx.tw.labels = &Fixture.label_atlas;
    const Shapes = lcgf.canvas.Instances;
    const Rows = struct {
        var bytes: [Shapes.requiredBytes(64, 1, 1, .{})]u8 align(lcgf.mem.column_align) = undefined;
        var reference: [lcgf.render_sw.Framebuffer.len(200, 100)]u32 = undefined;
    };
    var carver: lcgf.mem.Carver = .{ .buf = &Rows.bytes };
    var shapes = Shapes.init(&carver, 64, 1, 1, .{});
    var app: text.labels.TestApp = .{
        .shapes = &shapes,
        .words = &.{ "R1 10k Vout", "GND" },
        .labels = .{ .text = &fx.tw.text.?, .labels = &Fixture.label_atlas },
    };
    for ([_]f32{ 1, 2 }) |s| {
        fx.conn.overrideScale(s);
        for ([_]f32{ 1, 4 }) |zoom| {
            app.zoom = zoom;
            fx.ctx.waker.post();
            try fx.run(&app, seconds(0.3));
            try app.expectWindow(&fx.w, x11.pixel, s, &Rows.reference);
        }
    }
    try testing.expectEqual(1, app.remakes);
    try testing.expect(fx.gw.stats.label_bytes > 0);
    // A pan: no label made again, no byte of the label atlas uploaded.
    const bytes = fx.gw.stats.label_bytes;
    app.pan = 30;
    fx.ctx.waker.post();
    try fx.run(&app, seconds(0.3));
    try app.expectWindow(&fx.w, x11.pixel, 2, &Rows.reference);
    try testing.expectEqual(1, app.remakes);
    try testing.expectEqual(bytes, fx.gw.stats.label_bytes);
}

test "gpu canvas: a canvas beside a damaged rect is not drawn again over itself" {
    var fx: Fixture = undefined;
    try fx.open(try displayOrSkip(), 200, 100);
    defer fx.close();
    const Shapes = lcgf.canvas.Instances;
    var buf: [Shapes.requiredBytes(4, 0, 1, .{})]u8 align(lcgf.mem.column_align) = undefined;
    var carver: lcgf.mem.Carver = .{ .buf = &buf };
    var shapes: Shapes = .init(&carver, 4, 0, 1, .{});
    _ = shapes.segment(.{ 5, 40 }, .{ 75, 40 }, .{});
    const layers = [_]lcgf.canvas.Layer{.of(.{ .stroke = .{ .r = 255, .a = 128 }, .width = 8 })};
    const palette: lcgf.canvas.Palette = .{ .layers = &layers };
    var app: CanvasApp = .{ .shapes = &shapes, .palette = &palette, .ranges = .{shapes.since(0)} };
    try fx.run(&app, seconds(0.3));
    _ = try shown(&fx.w, 130, 20, .rgb(0, 0, 200));
    const line = try x11.pixel(&fx.w, 50, 50);
    try testing.expect(line.r > 100);
    try testing.expect(line.r < 250);
    // The box changes five times: each frame's damage is the box, and the canvas, outside it,
    // keeps its pixels (drawn again over itself, its half-transparent line would darken).
    for (0..5) |_| {
        app.lit = !app.lit;
        fx.ctx.waker.post();
        try fx.run(&app, seconds(0.1));
    }
    try testing.expectEqual(Color.white, try shown(&fx.w, 130, 20, .white));
    try testing.expectEqual(line, try x11.pixel(&fx.w, 50, 50));
}

/// A canvas (an `lcgf_app.Canvas`) holding a red square at the world's origin, and a box
/// beside it that `lit` turns white.
const PanApp = struct {
    const ground: Color = .rgb(30, 30, 30);
    const fill: Color = .rgb(10, 20, 30);
    const red: Color = .rgb(220, 0, 0);
    const rect: [4]f32 = .{ 10, 10, 90, 90 };
    shapes: *const lcgf.canvas.Instances,
    view: app_mod.Canvas = .{ .camera = .{ .offset = .{ 10, 10 } } },
    ranges: [1]lcgf.canvas.Range,
    lit: bool = false,
    builds: u32 = 0,

    pub fn build(a: *PanApp, f: *lcgf.frame.Frame, _: *const Events) void {
        a.builds += 1;
        _ = f.open(.none, .{ .size = .{ .fill, .fill }, .fill = ground });
        const side: [2]lcgf.types.Size = .{ .px(80), .px(80) };
        const at: [2]f32 = .{ rect[0], rect[1] };
        const style: lcgf.types.Style = .{
            .float = true,
            .offset = at,
            .size = side,
            .fill = fill,
        };
        _ = a.view.node(f, .from("canvas"), style, a.shapes, .{ .ranges = &a.ranges });
        const box: Color = if (a.lit) .white else .rgb(0, 0, 200);
        const square: [2]lcgf.types.Size = .{ .px(30), .px(30) };
        _ = f.leaf(.none, .{ .float = true, .offset = .{ 120, 10 }, .size = square, .fill = box });
        f.close();
    }
};

/// Runs `app` until no `Canvas` asks for a redraw and the frame built, if any, is presented.
fn runPanned(fx: *Fixture, app: anytype) !void {
    const Drawn = struct {
        gw: *const GpuWindow,
        fn stop(d: @This()) bool {
            return !app_mod.canvases.owed() and d.gw.rows == null;
        }
    };
    const t0: std.Io.Timestamp = .now(testing.io, .awake);
    const clock: Clock(Drawn) = .{ .t0 = t0, .seconds = 3, .done = .{ .gw = &fx.gw } };
    try fx.run(app, clock);
    try testing.expect(clock.done.stop());
}

/// The window's pixels outside `box` (x0, y0, x1, y1) of a `w` x `h` window, into `out`.
fn readAround(win: *x11.Window, w: i16, h: i16, box: [4]i16, out: []Color) !usize {
    var k: usize = 0;
    var y: i16 = 0;
    while (y < h) : (y += 1) {
        var x: i16 = 0;
        while (x < w) : (x += 1) {
            if (x >= box[0] and x < box[2] and y >= box[1] and y < box[3]) continue;
            out[k] = try x11.pixel(win, x, y);
            k += 1;
        }
    }
    return k;
}

/// A red filled square 10 world units wide at the origin, and the palette it is drawn in.
const PanShapes = struct {
    const Shapes = lcgf.canvas.Instances;
    var bytes: [Shapes.requiredBytes(4, 0, 1, .{})]u8 align(lcgf.mem.column_align) = undefined;
    var shapes: Shapes = undefined;
    const layers = [_]lcgf.canvas.Layer{.of(.{ .stroke = PanApp.red, .fill = PanApp.red })};

    fn app() PanApp {
        var carver: lcgf.mem.Carver = .{ .buf = &bytes };
        shapes = .init(&carver, 4, 0, 1, .{});
        _ = shapes.rect(.{ 0, 0 }, .{ 10, 10 }, .{ .fill = true });
        var a: PanApp = .{ .shapes = &shapes, .ranges = .{shapes.since(0)} };
        a.view.palette = .{ .layers = &layers };
        return a;
    }
};

test "gpu canvas: 100 pans under an idle UI build nothing, upload no rows, redraw the canvas" {
    var fx: Fixture = undefined;
    try fx.open(try displayOrSkip(), 200, 100);
    defer fx.close();
    var app = PanShapes.app();
    try fx.run(&app, seconds(0.3));
    try testing.expectEqual(PanApp.red, try shown(&fx.w, 25, 25, PanApp.red));
    const box: [4]i16 = .{ 10, 10, 90, 90 };
    var before: [200 * 100]Color = undefined;
    const n = try readAround(&fx.w, 200, 100, box, &before);
    const builds = fx.gw.stats.builds;
    const rows = fx.gw.stats.row_bytes;
    const redraws = fx.gw.stats.canvas_redraws;
    const canvas_bytes = fx.gw.stats.canvas_bytes;
    for (1..101) |k| {
        const step: f32 = @floatFromInt(k);
        app.view.camera.offset = .{ 10 + 0.4 * step, 10 + 0.3 * step };
        app.view.redraw();
        try runPanned(&fx, &app);
    }
    try testing.expectEqual(builds, fx.gw.stats.builds);
    try testing.expectEqual(rows, fx.gw.stats.row_bytes);
    try testing.expectEqual(redraws + 100, fx.gw.stats.canvas_redraws);
    // Each pan wrote the canvas's uniforms, no instance row: well under a row a pan.
    try testing.expect(fx.gw.stats.canvas_bytes - canvas_bytes > 0);
    // The pass was scissored to the canvas node, and only it.
    try testing.expectEqual(PanApp.rect, fx.gw.stats.damage.bounds());
    try testing.expectEqual(@as(u32, 1), fx.gw.stats.damage.count());
    // Inside: the square at the new camera, the node's fill where it was. Outside: the same.
    try testing.expectEqual(PanApp.red, try shown(&fx.w, 10 + 50 + 5, 10 + 40 + 5, PanApp.red));
    try testing.expectEqual(PanApp.fill, try x11.pixel(&fx.w, 25, 25));
    var after: [200 * 100]Color = undefined;
    _ = try readAround(&fx.w, 200, 100, box, &after);
    try testing.expectEqualSlices(Color, before[0..n], after[0..n]);
}

test "gpu canvas: a pan and a widget in the same frame draw both" {
    var fx: Fixture = undefined;
    try fx.open(try displayOrSkip(), 200, 100);
    defer fx.close();
    var app = PanShapes.app();
    try fx.run(&app, seconds(0.3));
    const builds = app.builds;
    app.lit = true;
    fx.ctx.waker.post();
    app.view.camera.offset = .{ 50, 40 };
    app.view.redraw();
    try runPanned(&fx, &app);
    try testing.expect(app.builds > builds);
    try testing.expectEqual(Color.white, try shown(&fx.w, 130, 20, .white));
    try testing.expectEqual(PanApp.red, try shown(&fx.w, 65, 55, PanApp.red));
    try testing.expectEqual(PanApp.fill, try x11.pixel(&fx.w, 25, 25));
    // Then a pan alone, back: no build.
    const built = app.builds;
    app.view.camera.offset = .{ 10, 10 };
    app.view.redraw();
    try runPanned(&fx, &app);
    try testing.expectEqual(built, app.builds);
    try testing.expectEqual(PanApp.red, try shown(&fx.w, 25, 25, PanApp.red));
    try testing.expectEqual(PanApp.fill, try x11.pixel(&fx.w, 65, 55));
    try testing.expectEqual(Color.white, try x11.pixel(&fx.w, 130, 20));
}

test "gpu page: 100 pans of the region's canvas build nothing and redraw only the canvas" {
    var fx: Fixture = undefined;
    try fx.openWith(try displayOrSkip(), 300, 200, &Fixture.face);
    defer fx.close();
    const T = page.TestApp;
    var app: T = .{};
    try fx.run(&app, seconds(0.3));
    const plot = app.canvas_rect;
    try testing.expectEqual(T.red, try page.pixelIn(&fx.w, plot, 15, 15));
    const builds = fx.gw.stats.builds;
    const rows = fx.gw.stats.row_bytes;
    const header = try x11.pixel(&fx.w, 200, 4);
    for (1..101) |k| {
        const step: f32 = @floatFromInt(k);
        app.view.camera.offset = .{ 10 + 0.4 * step, 10 + 0.2 * step };
        app.view.redraw();
        try runPanned(&fx, &app);
    }
    try testing.expectEqual(builds, fx.gw.stats.builds);
    try testing.expectEqual(rows, fx.gw.stats.row_bytes);
    try testing.expectEqual(plot, fx.gw.stats.damage.bounds());
    try testing.expectEqual(@as(u32, 1), fx.gw.stats.damage.count());
    try testing.expectEqual(T.red, try page.pixelIn(&fx.w, plot, 55, 35));
    try testing.expectEqual(T.canvas_fill, try page.pixelIn(&fx.w, plot, 15, 15));
    try testing.expectEqual(header, try x11.pixel(&fx.w, 200, 4));
    try testing.expectEqual(T.region_fill, try x11.pixel(&fx.w, 290, 190));
}

/// 32 x 24 bordered cells over a 2560 x 1440 window, the plot surface over the middle of
/// them: `toggles` widget frames (cell 0 changes colour), `paints` surface frames.
const GridApp = struct {
    plot: Surface = .{},
    hot: bool = false,
    toggles: u32 = 0,
    paints: u32 = 0,
    builds: u32 = 0,
    draws: u32 = 0,

    pub fn build(a: *GridApp, f: *lcgf.frame.Frame, _: *const Events) void {
        std.debug.assert(f.ctx.limits.nodes >= 32 * 24 + 26);
        a.builds += 1;
        _ = f.open(.none, .{ .size = .{ .fill, .fill }, .fill = .rgb(30, 30, 30) });
        for (0..24) |row| {
            _ = f.open(.none, .{ .dir = .x, .size = .{ .fill, .px(60) } });
            for (0..32) |col| {
                const on = row == 0 and col == 0 and a.hot;
                _ = f.leaf(.none, .{
                    .size = .{ .px(76), .px(56) },
                    .radius = 6,
                    .border = 1,
                    .border_color = .white,
                    .fill = if (on) .rgb(220, 60, 60) else .rgb(60, 60, 70),
                });
            }
            f.close();
        }
        const plot: [2]lcgf.types.Size = .{ .px(800), .px(600) };
        const at: [2]f32 = .{ 880, 420 };
        _ = a.plot.node(f, .from("plot"), .{ .float = true, .offset = at, .size = plot });
        f.close();
        if (a.toggles > 0) {
            a.toggles -= 1;
            a.hot = !a.hot;
            f.ctx.waker.post();
        }
    }

    pub fn draw(a: *GridApp, g: *GpuFrame) !void {
        a.draws += 1;
        const v: f64 = @as(f64, @floatFromInt(a.draws % 256)) / 255;
        var pass = g.encoder().beginRenderPass(.{ .color_attachments = &.{.{
            .view = a.plot.texture.createView(),
            .clear_value = .{ .r = v, .g = 0.3, .b = 0.5, .a = 1 },
        }} });
        pass.end();
        a.paints -|= 1;
        if (a.paints > 0) a.plot.redraw();
    }
};

/// 32 x 24 bordered cells over a 2560 x 1440 window and an 800 x 600 canvas of
/// `PanGrid.rows` segments over the middle of them, through an `lcgf_app.Canvas`.
const PanGridApp = struct {
    view: app_mod.Canvas = .{},
    shapes: *const lcgf.canvas.Instances,
    ranges: [1]lcgf.canvas.Range,
    builds: u32 = 0,

    pub fn build(a: *PanGridApp, f: *lcgf.frame.Frame, _: *const Events) void {
        std.debug.assert(f.ctx.limits.nodes >= 32 * 24 + 26);
        a.builds += 1;
        _ = f.open(.none, .{ .size = .{ .fill, .fill }, .fill = .rgb(30, 30, 30) });
        for (0..24) |_| {
            _ = f.open(.none, .{ .dir = .x, .size = .{ .fill, .px(60) } });
            for (0..32) |_| _ = f.leaf(.none, .{
                .size = .{ .px(76), .px(56) },
                .radius = 6,
                .border = 1,
                .border_color = .white,
                .fill = .rgb(60, 60, 70),
            });
            f.close();
        }
        const plot: [2]lcgf.types.Size = .{ .px(800), .px(600) };
        const style: lcgf.types.Style = .{ .float = true, .offset = .{ 880, 420 }, .size = plot };
        _ = a.view.node(f, .from("plot"), style, a.shapes, .{ .ranges = &a.ranges });
        f.close();
    }
};

/// The pan mode's canvas rows: 2-pixel squares, 400 to a line, made once.
const PanGrid = struct {
    const rows = RowsApp.n; // as many as the 100,000-row mode, in `rows_room`
    const Shapes = lcgf.canvas.Instances;
    var bytes: [Shapes.requiredBytes(rows, 0, 1, .{})]u8 align(lcgf.mem.column_align) = undefined;
    var shapes: Shapes = undefined;

    fn app() PanGridApp {
        var carver: lcgf.mem.Carver = .{ .buf = &bytes };
        shapes = .init(&carver, rows, 0, 1, .{});
        for (0..rows) |k| {
            const p: [2]i32 = .{ @intCast((k % 400) * 2), @intCast((k / 400) * 2) };
            const look: Shapes.Box = .{ .color = .rgb(64, 64, 64), .stroke = false };
            _ = shapes.rect(p, .{ p[0] + 2, p[1] + 2 }, look);
        }
        return .{ .shapes = &shapes, .ranges = .{shapes.since(0)} };
    }
};

/// A clock that pans: each time the loop asks it, the canvas moves a pixel and asks for a
/// redraw, until `pans` are made. The loop asks once a frame, so it drives one pan a frame
/// with no `fx.run` between them.
const Panner = struct {
    app: *PanGridApp,
    pans: u32,
    t0: std.Io.Timestamp,

    pub fn left(p: *Panner) f32 {
        std.debug.assert(p.pans <= 1 << 20);
        if (p.pans == 0) return 0;
        const ns = p.t0.durationTo(std.Io.Timestamp.now(testing.io, .awake)).toNanoseconds();
        if (ns > 120 * std.time.ns_per_s) return 0;
        p.pans -= 1;
        p.app.view.camera.offset[0] += 1;
        p.app.view.redraw();
        return 1;
    }
};

// What a canvas pan costs through `lcgf_app`'s loop at 2560 x 1440, under the grid of the
// frame cost benchmark: per pan, wall and calling-thread CPU, bytes written to the GPU (UI rows
// and the canvas's), frames built; appended to the file LCGF_APP_GPU_BENCH names. Its own
// mode beside the 100,000-row one, whose camera moves in `build`: here `Canvas.redraw` moves it.
test "gpu canvas pan cost at 2560 x 1440 (LCGF_APP_GPU_BENCH)" {
    const display = try displayOrSkip();
    const path = testing.environ.getPosix("LCGF_APP_GPU_BENCH") orelse return error.SkipZigTest;
    const flags: std.os.linux.O = .{ .ACCMODE = .WRONLY, .CREAT = true, .APPEND = true };
    const opened = std.os.linux.open(path, flags, 0o644);
    if (std.os.linux.errno(opened) != .SUCCESS) return error.BenchFile;
    const fd: i32 = @intCast(opened);
    defer _ = std.os.linux.close(fd);
    var fx: Fixture = undefined;
    try fx.openRoom(display, .{ 2560, 1440 }, &.{}, rows_room);
    defer fx.close();
    var app = PanGrid.app();
    try fx.run(&app, seconds(0.5));
    try fx.run(&app, seconds(0.3)); // until the first frames, and their uploads, are done
    const pans = 300;
    const builds = app.builds;
    const refused = fx.gw.stats.not_shown;
    const redraws = fx.gw.stats.canvas_redraws;
    const bytes = fx.gw.stats.row_bytes + fx.gw.stats.canvas_bytes;
    var panner: Panner = .{ .app = &app, .pans = pans, .t0 = .now(testing.io, .awake) };
    const t = Spent.start();
    try fx.run(&app, &panner);
    const made = fx.gw.stats.canvas_redraws - redraws;
    const us = t.per(made);
    const sent = fx.gw.stats.row_bytes + fx.gw.stats.canvas_bytes - bytes;
    const line = "canvas pan (800 x 600, {d} rows): wall {d:.1} us, thread cpu {d:.1} us, " ++
        "{d} bytes; builds {d}; unfinished {d}, not shown {d}\n";
    note(fd, line, .{
        PanGrid.rows,
        us[0],
        us[1],
        sent / @max(made, 1),
        app.builds - builds,
        pans - made,
        fx.gw.stats.not_shown - refused,
    });
}

/// Wall and calling-thread CPU time of what runs between `start` and `stop`.
const Spent = struct {
    at: [2]u64,

    fn start() Spent {
        std.debug.assert(clockNs(.MONOTONIC) > 0);
        return .{ .at = .{ clockNs(.MONOTONIC), clockNs(.THREAD_CPUTIME_ID) } };
    }

    /// Microseconds of wall and thread CPU time per frame, over `frames`.
    fn per(s: Spent, frames: u32) [2]f64 {
        const n: f64 = @floatFromInt(@max(frames, 1));
        const wall: f64 = @floatFromInt(clockNs(.MONOTONIC) - s.at[0]);
        const cpu: f64 = @floatFromInt(clockNs(.THREAD_CPUTIME_ID) - s.at[1]);
        return .{ wall / n / 1000, cpu / n / 1000 };
    }
};

fn clockNs(clock: std.os.linux.clockid_t) u64 {
    var ts: std.os.linux.timespec = undefined;
    _ = std.os.linux.clock_gettime(clock, &ts);
    return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
}

/// Appends a formatted line to `fd`: the test runner fails a test that writes to stderr.
fn note(fd: i32, comptime format: []const u8, args: anytype) void {
    var buf: [256]u8 = undefined;
    const t = std.fmt.bufPrint(&buf, format, args) catch return;
    _ = std.os.linux.write(fd, t.ptr, t.len);
}

// What a surface frame, a widget frame and an idle second cost through `lcgf_app`'s loop at
// 2560 x 1440: calling-thread CPU and wall time per frame, from the loop's first call to its
// return (build, layout, paint, `draw`, uploads, the UI's pass, submit and present), appended
// to the file LCGF_APP_GPU_BENCH names. The device is the one VK_ICD_FILENAMES leaves.
test "gpu frame cost at 2560 x 1440 (LCGF_APP_GPU_BENCH)" {
    const display = try displayOrSkip();
    const path = testing.environ.getPosix("LCGF_APP_GPU_BENCH") orelse return error.SkipZigTest;
    const flags: std.os.linux.O = .{ .ACCMODE = .WRONLY, .CREAT = true, .APPEND = true };
    const opened = std.os.linux.open(path, flags, 0o644);
    if (std.os.linux.errno(opened) != .SUCCESS) return error.BenchFile;
    const fd: i32 = @intCast(opened);
    defer _ = std.os.linux.close(fd);
    var fx: Fixture = undefined;
    try fx.open(display, 2560, 1440);
    defer fx.close();
    var app: GridApp = .{};
    try fx.run(&app, seconds(0.5));
    const frames = 300;
    const Done = struct {
        a: *const GridApp,
        fn stop(d: @This()) bool {
            return d.a.paints == 0 and d.a.toggles == 0;
        }
    };
    const done: Done = .{ .a = &app };
    const unfinished = "; unfinished {d}, not shown {d}\n";
    const device = .{ fx.gw.p.x.setup.device.name(), fx.w.width, fx.w.height, frames };
    note(fd, "device {s}, window {d} x {d}, {d} frames a mode\n", device);

    var builds = app.builds;
    var draws = app.draws;
    var refused = fx.gw.stats.not_shown;
    app.paints = frames;
    app.plot.redraw();
    var t = Spent.start();
    try fx.run(&app, Clock(Done){ .t0 = .now(testing.io, .awake), .seconds = 120, .done = done });
    var us = t.per(app.draws - draws);
    const surface = "surface frame (800 x 600): wall {d:.1} us, thread cpu {d:.1} us; builds {d}";
    refused = fx.gw.stats.not_shown - refused;
    note(fd, surface ++ unfinished, .{ us[0], us[1], app.builds - builds, app.paints, refused });
    // A mode the window did not finish (not shown) must not run into the next one.
    app.paints = 0;
    try fx.run(&app, seconds(0.3));

    builds = app.builds;
    draws = app.draws;
    refused = fx.gw.stats.not_shown;
    app.toggles = frames;
    fx.ctx.waker.post();
    t = Spent.start();
    try fx.run(&app, Clock(Done){ .t0 = .now(testing.io, .awake), .seconds = 120, .done = done });
    us = t.per(app.builds - builds);
    const widget = "widget frame (one cell): wall {d:.1} us, thread cpu {d:.1} us; draws {d}";
    refused = fx.gw.stats.not_shown - refused;
    note(fd, widget ++ unfinished, .{ us[0], us[1], app.draws - draws, app.toggles, refused });
    app.toggles = 0;

    try fx.run(&app, seconds(0.3));
    const presents = fx.gw.stats.presents;
    t = Spent.start();
    try fx.run(&app, seconds(1));
    us = t.per(1);
    const idle = "idle second: {d} frames, thread cpu {d:.1} us\n";
    note(fd, idle, .{ fx.gw.stats.presents - presents, us[1] });
}

// The canvas of 100,000 rows (`RowsApp`, 6-pixel squares over the window) at 2560 x 1440, the
// camera moving a pixel a frame, through `lcgf_app`'s loop: calling-thread CPU and wall time
// per frame, canvas bytes uploaded per frame, builds, and frames unfinished and not shown,
// appended to the file LCGF_APP_GPU_BENCH names.
test "gpu canvas of 100,000 rows at 2560 x 1440, the camera moving (LCGF_APP_GPU_BENCH)" {
    const display = try displayOrSkip();
    const path = testing.environ.getPosix("LCGF_APP_GPU_BENCH") orelse return error.SkipZigTest;
    const flags: std.os.linux.O = .{ .ACCMODE = .WRONLY, .CREAT = true, .APPEND = true };
    const opened = std.os.linux.open(path, flags, 0o644);
    if (std.os.linux.errno(opened) != .SUCCESS) return error.BenchFile;
    const fd: i32 = @intCast(opened);
    defer _ = std.os.linux.close(fd);
    var fx: Fixture = undefined;
    try fx.openRoom(display, .{ 2560, 1440 }, &.{}, rows_room);
    defer fx.close();
    var app: RowsApp = .init(6, 426);
    try fx.run(&app, seconds(0.5));
    const frames = 300;
    const Done = struct {
        a: *const RowsApp,
        fn stop(d: @This()) bool {
            return d.a.moves == 0;
        }
    };
    const builds = app.builds;
    const presents = fx.gw.stats.presents;
    const bytes = fx.gw.stats.canvas_bytes;
    const refused = fx.gw.stats.not_shown;
    app.moves = frames;
    fx.ctx.waker.post();
    const t = Spent.start();
    const t0: std.Io.Timestamp = .now(testing.io, .awake);
    const clock = Clock(Done){ .t0 = t0, .seconds = 120, .done = .{ .a = &app } };
    try fx.run(&app, clock);
    const shown_n = fx.gw.stats.presents - presents;
    const us = t.per(shown_n);
    const per_frame = (fx.gw.stats.canvas_bytes - bytes) / @max(shown_n, 1);
    const device = .{ fx.gw.p.x.setup.device.name(), fx.w.width, fx.w.height };
    note(fd, "device {s}, window {d} x {d}\n", device);
    const line = "canvas 100k rows, camera moving: {d} frames, wall {d:.1} us, " ++
        "thread cpu {d:.1} us, {d} canvas bytes uploaded a frame; builds {d}; " ++
        "unfinished {d}, not shown {d}\n";
    const refusals = fx.gw.stats.not_shown - refused;
    note(fd, line, .{ shown_n, us[0], us[1], per_frame, app.builds - builds, app.moves, refusals });
}
