//! The GPU window on macOS: Metal in an AppKit window (src/shell/macos/macos.zig and
//! `metal.setup.Window`), as src/app/gpu.zig's window contract asks, and lcgf_app's GPU loop over
//! it (`Loop`). The layer's drawables pace the frames: `begin` waits for one, as FIFO does on
//! Vulkan. A window AppKit does not show (`Macos.shown`) takes no frame: error.NotShown before
//! the layer is asked for a drawable.
//!
//! Contents
//!   pub const Window = struct        the contract: Metal in an AppKit window
//!   pub const Loop = gpu_loop.Gpu(Window)
//!   pub fn runApp(comptime App: type, app: *App, want: gpu_loop.Want, clock: anytype) !bool

const std = @import("std");
const lcgf = @import("lcgf");
const macos = @import("macos");
const gpu_loop = @import("gpu.zig");
const context = lcgf.context;
const scheduler = lcgf.scheduler;
const Events = lcgf.shell_iface.Events;
const DrawList = lcgf.draw_list.DrawList;
const Color = lcgf.types.Color;
const Macos = macos.Macos;
const metal = macos.metal;
const objc = metal.objc;
const mtl = metal.mtl;
const texture = metal.texture;
const Id = objc.Id;
const msg = objc.msg;
const ImageKind = gpu_loop.ImageKind;
const Channel = gpu_loop.Channel;
const slots = metal.present.max_in_flight;

/// lcgf_app's GPU loop on Metal in an AppKit window.
pub const Loop = gpu_loop.Gpu(Window);

/// Metal in the macOS shell's window: the shell holds the device, layer, renderer and picture
/// (`Macos.gpu`); this holds the application's memory and staging and the loop's mapped write
/// buffers, a frame slot each.
pub const Window = struct {
    m: *Macos,
    arena: gpu.Arena,
    staging_arena: gpu.Arena,
    /// The application's staging, a frame slot each.
    staging: [slots]gpu.Staging,
    /// Shared buffers the loop's own texture writes copy from, per channel and frame slot.
    writes: [3][slots]?gpu.Buffer,

    pub const gpu = metal.gpu;
    /// A texture of the window's, its size, and the bytes of one of its texels.
    pub const Image = struct { texture: Id, size: [2]u32, texel: u32 };
    /// The frame, and the autorelease pool its objects live in until `present`.
    pub const Frame = struct { f: metal.setup.Window.Frame, pool: objc.Pool };
    pub const max_textures = metal.CanvasRenderer.max_textures;
    /// The shell's window, opened: its Metal is made with it (`Macos.init`).
    pub const Shell = *Macos;

    pub fn open(p: *Window, shell: Shell, o: gpu_loop.Open, handles: u16) !void {
        std.debug.assert(handles <= max_textures);
        p.m = shell;
        const mg = &shell.gpu;
        std.debug.assert(mg.frames.count <= slots);
        const dev: gpu.Device = .wrap(mg.dev.device);
        p.arena = try .init(dev, .{ .bytes = o.gpu_bytes });
        p.staging_arena = try .init(dev, .{ .bytes = slots * o.staging_bytes, .memory = .host });
        var made: usize = 0;
        errdefer for (p.staging[0..made]) |s| s.deinit(dev);
        for (&p.staging) |*s| {
            s.* = try .init(dev, &p.staging_arena, o.staging_bytes);
            made += 1;
        }
        while (mg.gfx.texture_count < handles) _ = mg.gfx.addTexture(mg.gfx.white.?, null);
        p.writes = @splat(@splat(null));
    }

    pub fn close(p: *Window) void {
        const dev: gpu.Device = .wrap(p.m.gpu.dev.device);
        for (&p.writes) |*ch| for (ch) |*b| if (b.*) |buf| dev.destroyBuffer(buf);
        for (p.staging) |s| s.deinit(dev);
    }

    pub fn waitIdle(p: *Window) void {
        for (p.m.gpu.frames.in_flight) |c| if (c) |cmd| msg(void, cmd, "waitUntilCompleted", .{});
    }

    pub fn createImage(p: *Window, kind: ImageKind, size: [2]u32) !Image {
        std.debug.assert(size[0] > 0);
        std.debug.assert(size[1] > 0);
        const d = p.m.gpu.dev.device;
        return switch (kind) {
            .coverage => .{
                .texture = try texture.coverage(d, size[0], size[1]),
                .size = size,
                .texel = 1,
            },
            .rgba => .{
                .texture = try texture.rgba8(d, size[0], size[1], null),
                .size = size,
                .texel = 4,
            },
            .target => {
                const t = try gpu.Device.wrap(d).createTexture(&p.arena, .{
                    .size = .{ .width = size[0], .height = size[1] },
                    .format = Loop.Surface.format,
                    .usage = .{ .render_attachment = true, .texture_binding = true },
                });
                return .{ .texture = t.texture, .size = size, .texel = 4 };
            },
        };
    }

    /// Metal keeps a texture a committed frame samples until that frame completes.
    pub fn destroyImage(_: *Window, img: *Image) void {
        objc.release(img.texture);
    }

    pub fn extent(img: *const Image) [2]u32 {
        return img.size;
    }

    pub fn bind(p: *Window, handle: u16, img: *const Image) void {
        p.m.gpu.gfx.setTexture(@fromBackingInt(handle), img.texture);
    }

    /// All of `img` from `bytes` in a command buffer of its own, waited for: for what `open`
    /// makes once.
    pub fn writeNow(p: *Window, img: *Image, bytes: []const u8) !void {
        std.debug.assert(bytes.len == @as(usize, img.size[0]) * img.size[1] * img.texel);
        const pool = objc.Pool.push();
        defer pool.pop();
        const mg = &p.m.gpu;
        const options: objc.NSUInteger = mtl.resource_shared_write_combined;
        const len: objc.NSUInteger = bytes.len;
        const args = .{ bytes.ptr, len, options };
        const sel = "newBufferWithBytes:length:options:";
        const buf = msg(?Id, mg.dev.device, sel, args) orelse return error.TextureFailed;
        defer objc.release(buf);
        const cmd = msg(Id, mg.dev.queue, "commandBuffer", .{});
        const blit = msg(Id, cmd, "blitCommandEncoder", .{});
        const whole: mtl.Region = .{ .size = .{ .width = img.size[0], .height = img.size[1] } };
        texture.writeRegion(blit, buf, 0, img.size[0] * img.texel, img.texture, whole);
        msg(void, blit, "endEncoding", .{});
        msg(void, cmd, "commit", .{});
        msg(void, cmd, "waitUntilCompleted", .{});
    }

    pub fn targetTexture(img: *const Image) gpu.Texture {
        return .{
            .texture = img.texture,
            .format = Loop.Surface.format,
            .width = img.size[0],
            .height = img.size[1],
            .samples = 1,
        };
    }

    /// error.NotShown for a window AppKit does not show, or when the layer gave no drawable.
    pub fn begin(p: *Window) !Frame {
        const in = &p.m.t.in;
        std.debug.assert(in.scale > 0);
        if (!p.m.shown()) return error.NotShown;
        const pool = objc.Pool.push();
        errdefer pool.pop();
        return .{ .f = try p.m.gpu.begin(in.viewport, in.scale), .pool = pool };
    }

    /// Room for `bytes` in the frame slot's buffer of `ch`: made again larger when short (its
    /// slot's last frame is done: `begin` waited for it).
    pub fn stage(p: *Window, f: *Frame, ch: Channel, bytes: u64) ![]u8 {
        _ = f;
        const b = &p.writes[@backingInt(ch)][p.m.gpu.frames.slot];
        if (b.* == null or b.*.?.size < bytes) {
            const dev: gpu.Device = .wrap(p.m.gpu.dev.device);
            if (b.*) |old| dev.destroyBuffer(old);
            b.* = null;
            b.* = try dev.createBuffer(&p.staging_arena, .{
                .size = @max(bytes, 1 << 20),
                .usage = .{ .copy_src = true },
            });
        }
        return b.*.?.mapped.?[0..@intCast(bytes)];
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
        _ = fresh; // Metal has no layouts to drop
        const b = p.writes[@backingInt(ch)][p.m.gpu.frames.slot].?;
        const blit = msg(Id, f.f.cmd, "blitCommandEncoder", .{});
        const region: mtl.Region = .{
            .origin = .{ .x = r.x, .y = r.y },
            .size = .{ .width = r.w, .height = r.h },
        };
        texture.writeRegion(blit, b.buffer, @intCast(at), r.w * img.texel, img.texture, region);
        msg(void, blit, "endEncoding", .{});
    }

    pub fn gpuFrame(p: *Window, f: *Frame) gpu_loop.GpuParts(gpu) {
        const slot = p.m.gpu.frames.slot;
        const dev: gpu.Device = .wrap(p.m.gpu.dev.device);
        p.staging[slot].rewind();
        return .{
            .device = dev,
            .arena = &p.arena,
            .upload = .beginStaged(dev, f.f.cmd, &p.staging[slot]),
        };
    }

    pub fn present(p: *Window, f: *Frame, ui: gpu_loop.Ui) !void {
        defer f.pool.pop();
        const rows: ?metal.setup.Window.Rows = if (ui.rows) |r| .{
            .list = r.list,
            .glyphs = r.glyphs,
            .viewport = r.viewport,
            .scale = r.scale,
        } else null;
        p.m.gpu.present(&f.f, .{
            .rows = rows,
            .damage = ui.damage,
            .clear = ui.clear,
            .canvases = ui.canvases,
        });
    }

    pub fn kept(p: *const Window) ?*const DrawList {
        return p.m.gpu.gfx.list;
    }

    pub fn canvasUploaded(p: *const Window) ?usize {
        const cv = p.m.gpu.gfx.canvas orelse return null;
        return cv.uploaded;
    }

    /// AppKit keeps the layer's contents: nothing is ever exposed.
    pub fn poll(p: *Window, ev: *Events) gpu_loop.Polled {
        return if (p.m.poll(ev)) .ready else .closed;
    }

    pub fn apply(p: *Window, platform: *const context.Platform) void {
        p.m.apply(platform);
    }

    pub fn wait(p: *Window, seconds_: f32, pace: scheduler.Pace) void {
        p.m.wait(seconds_, pace);
    }

    pub fn wake(p: *Window) void {
        p.m.wake();
    }

    pub fn setBackground(p: *Window, color: Color) void {
        p.m.background = color;
    }

    pub fn background(p: *const Window) Color {
        return p.m.background;
    }
};

/// Opens the macOS window with Metal in it and runs the loop there until the window closes.
/// False, nothing left open, when Metal cannot be opened (no Objective-C runtime, no device):
/// `run` then opens the shell's own window, which needs Metal too, so it fails the same way.
// tidy: allow-fn(large-generic-function) one instance per App
pub fn runApp(comptime App: type, app: *App, want: gpu_loop.Want, clock: anytype) !bool {
    std.debug.assert(want.size[0] > 0);
    std.debug.assert(want.size[1] > 0);
    // ponytail: static, as app.zig's buffers are: one window a program. The shell's input
    // buffers at app.zig's sizes (`Buffers`), which `Want` does not carry.
    const S = struct {
        var m: Macos = undefined;
        var gw: Loop.Window = undefined;
        var title: [256:0]u8 = undefined;
        var text: [512]u8 = undefined;
        var events: [128]lcgf.input.Input.Event = undefined;
        var preedit: [256]u8 = undefined;
        var names: [8192]u8 = undefined;
        var ends: [64]u32 = undefined;
    };
    const n = @min(want.title.len, S.title.len);
    @memcpy(S.title[0..n], want.title[0..n]);
    S.title[n] = 0;
    const room = want.room;
    const options: Macos.Options = .{
        .title = S.title[0..n :0],
        .size = want.size,
        .canvas = .{ .rows = room.canvas_rows, .verts = room.canvas_verts },
    };
    const bufs: Macos.Buffers = .{
        .text = &S.text,
        .events = &S.events,
        .preedit = &S.preedit,
        .names = &S.names,
        .ends = &S.ends,
        .glyphs = want.quads,
        .first = want.first,
        .count = want.count,
    };
    S.m.init(options, bufs) catch return false;
    defer S.m.deinit();
    S.gw.open(&S.m, room) catch return false;
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

// ---- Tests: on macOS only (`zig build app-test` there; `app-test-build` compiles them) -------

const text = @import("text.zig");
const Quad = lcgf.draw_list.Quad;
const Surface = Loop.Surface;
const GpuFrame = Loop.GpuFrame;
const testing = std.testing;

/// A shown window with Metal in it and a context, the text in the bundled font. Filled in
/// place; its buffers are static, one fixture at a time.
const Fixture = struct {
    m: Macos,
    gw: Loop.Window,
    ctx: context.Context,
    tw: text.Window,

    const limits: context.Limits = .{ .nodes = 1024, .texts = 8, .customs = 4, .damage = true };
    const ctx_bytes = context.Context.requiredBytes(limits);
    var ctx_buffer: [ctx_bytes]u8 align(lcgf.mem.column_align) = @splat(0);
    var quads: [256]Quad = undefined;
    var first: [limits.texts]u32 = undefined;
    var count: [limits.texts]u32 = undefined;
    var canvas_rows: [2 * limits.customs]lcgf.draw_list.CanvasDraw = undefined;
    var input_text: [64]u8 = undefined;
    var events: [16]lcgf.input.Input.Event = undefined;
    var preedit: [64]u8 = undefined;
    var names: [512]u8 = undefined;
    var ends: [16]u32 = undefined;
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

    fn open(fx: *Fixture) !void {
        comptime std.debug.assert(limits.damage);
        const bufs: Macos.Buffers = .{
            .text = &input_text,
            .events = &events,
            .preedit = &preedit,
            .names = &names,
            .ends = &ends,
            .glyphs = &quads,
            .first = &first,
            .count = &count,
        };
        try fx.m.init(.{ .title = "lcgf app gpu", .size = .{ 200, 100 } }, bufs);
        errdefer fx.m.deinit();
        try fx.gw.open(&fx.m, .{ .gpu_bytes = 8 << 20, .staging_bytes = 1 << 20 });
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
        fx.m.deinit();
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

/// Runs until `app.<field>` is 0, or 30 seconds.
fn until(comptime field: []const u8, app: *const SurfaceApp) Clock(Until(field)) {
    return .{ .t0 = .now(testing.io, .awake), .seconds = 30, .done = .{ .a = app } };
}

fn Until(comptime field: []const u8) type {
    return struct {
        a: *const SurfaceApp,
        fn stop(d: @This()) bool {
            return @field(d.a, field) == 0;
        }
    };
}

/// A box beside a surface the application paints one colour at a time: `paints` more frames
/// of it, while `toggles` more widget frames flip the box.
const SurfaceApp = struct {
    plot: Surface = .{},
    builds: u32 = 0,
    draws: u32 = 0,
    paints: u32 = 0,
    toggles: u32 = 0,
    hot: bool = false,
    shade: u8 = 0,

    pub fn build(a: *SurfaceApp, f: *lcgf.frame.Frame, _: *const Events) void {
        a.builds += 1;
        if (a.toggles > 0) {
            a.toggles -= 1;
            a.hot = !a.hot;
            f.ctx.waker.post();
        }
        _ = f.open(.none, .{ .size = .{ .fill, .fill }, .fill = .rgb(30, 30, 30) });
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
        var pass = g.encoder().beginRenderPass(.{ .color_attachments = &.{.{
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

test "metal T2: surface frames under an idle UI build nothing, upload no rows, redraw only it" {
    var fx: Fixture = undefined;
    try fx.open();
    defer fx.close();
    var app: SurfaceApp = .{};
    try fx.run(&app, seconds(0.3));
    if (fx.gw.stats.presents == 0) return error.SkipZigTest; // AppKit never showed the window
    try testing.expect(app.draws >= 1);
    const builds = app.builds;
    const rows = fx.gw.stats.row_bytes;
    const draws = app.draws;
    app.paints = 100;
    app.plot.redraw();
    try fx.run(&app, until("paints", &app));
    try testing.expect(app.draws - draws >= 100);
    try testing.expectEqual(builds, app.builds);
    try testing.expectEqual(rows, fx.gw.stats.row_bytes);
    try testing.expectEqual([4]f32{ 100, 20, 180, 80 }, fx.gw.stats.damage.bounds());
    try testing.expectEqual(@as(u32, 1), fx.gw.stats.damage.count());
}

test "metal T3 and T4: widget frames never call draw; an idle second presents nothing" {
    var fx: Fixture = undefined;
    try fx.open();
    defer fx.close();
    var app: SurfaceApp = .{};
    try fx.run(&app, seconds(0.3));
    if (fx.gw.stats.presents == 0) return error.SkipZigTest;
    const draws = app.draws;
    const builds = app.builds;
    app.toggles = 100;
    fx.ctx.waker.post();
    try fx.run(&app, until("toggles", &app));
    try testing.expect(app.builds - builds >= 100);
    try testing.expectEqual(draws, app.draws);
    try fx.run(&app, seconds(0.3));
    const presents = fx.gw.stats.presents;
    try fx.run(&app, seconds(1));
    try testing.expectEqual(presents, fx.gw.stats.presents);
}

test "metal not shown: a refused frame owes the whole window, drawn when it is shown" {
    var fx: Fixture = undefined;
    try fx.open();
    defer fx.close();
    var app: SurfaceApp = .{};
    try fx.run(&app, seconds(0.3));
    if (fx.gw.stats.presents == 0) return error.SkipZigTest;
    const whole = fx.gw.stats.whole;
    fx.gw.refuse = 2;
    app.toggles = 1;
    fx.ctx.waker.post();
    try fx.run(&app, seconds(2 * gpu_loop.retry_seconds + 0.5));
    try testing.expectEqual(@as(u32, 2), fx.gw.stats.not_shown);
    try testing.expect(fx.gw.stats.whole > whole);
}
