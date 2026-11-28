//! The GPU window on Windows: Direct3D 12 over a Win32 shell window (src/shell/win32/gpu.zig
//! and `d3d12.setup.Window`), as src/app/gpu.zig's window contract asks, and lcgf_app's GPU
//! loop over it (`Loop`).
//!
//! D3D12 copies a texture from rows 256-byte aligned at 512-byte aligned offsets, and the loop
//! stages tight rows (`P.stage`): each channel stages into memory of its own, and `copy` lays
//! the rows out again in the frame slot's upload buffer before recording the copy.
//!
//! Contents
//!   pub const Window = struct        the contract: Direct3D 12 over a Win32 window
//!   pub const Loop = gpu_loop.Gpu(Window)
//!   pub fn runApp(comptime App: type, app: *App, want: gpu_loop.Want, clock: anytype) !bool

const std = @import("std");
const lcgf = @import("lcgf");
const d3d12 = @import("d3d12");
const win32 = @import("win32");
const win32_gpu = @import("win32_gpu");
const gpu_loop = @import("gpu.zig");
const text = @import("text.zig");
const context = lcgf.context;
const scheduler = lcgf.scheduler;
const Events = lcgf.shell_iface.Events;
const DrawList = lcgf.draw_list.DrawList;
const Quad = lcgf.draw_list.Quad;
const Color = lcgf.types.Color;
const com = d3d12.com;
const c = d3d12.c;
const ImageKind = gpu_loop.ImageKind;
const Channel = gpu_loop.Channel;
const Win32 = win32.Win32;

/// lcgf_app's GPU loop on Direct3D 12 over Win32.
pub const Loop = gpu_loop.Gpu(Window);

/// Direct3D 12 over a Win32 shell window: the device, the swapchain and the picture
/// (`win32_gpu.Gpu`), the application's memory and staging, and the loop's write buffers.
pub const Window = struct {
    g: win32_gpu.Gpu,
    /// The shell's window the GPU draws in: its events, size and background.
    w: *Win32,
    arena: gpu.Arena,
    staging_arena: gpu.Arena,
    /// The application's staging, a frame slot each.
    staging: [2]gpu.Staging,
    /// Where each channel's tight rows are staged (`stage`), read back by `copy` the same
    /// frame: a READBACK heap, mapped, which the CPU caches and the GPU never touches.
    tight: [3]Writes,
    /// Upload buffers the rows are laid out again in, per channel and frame slot.
    writes: [3][2]Writes,
    /// Upload buffers a frame outgrew while its copies still read them, let go of when their
    /// frame slot comes round again. ponytail: `retired_max` a slot; a frame past that waits
    /// for the GPU instead.
    retired: [2][retired_max]?*com.Resource,

    pub const gpu = d3d12.gpu;
    /// A texture of the window's, in PIXEL_SHADER_RESOURCE between frames; a surface's target
    /// has its render target view.
    pub const Image = struct {
        resource: *com.Resource,
        size: [2]u32,
        rtv: ?*com.DescriptorHeap = null,
    };
    pub const Frame = d3d12.setup.Window.Frame;
    pub const max_textures = d3d12.CanvasRenderer.max_textures;
    /// The shell window the GPU draws in.
    pub const Shell = struct { w: *Win32 };

    const retired_max = 8;
    const Writes = struct {
        buffer: ?*com.Resource = null,
        mapped: [*]u8 = undefined,
        size: u64 = 0,
        used: u64 = 0,
    };
    /// Where a target rests: sampled by the UI's pixel shader, and by `draw`'s shaders.
    const sampled = c.D3D12_RESOURCE_STATE_PIXEL_SHADER_RESOURCE |
        c.D3D12_RESOURCE_STATE_NON_PIXEL_SHADER_RESOURCE;
    const readable = c.D3D12_RESOURCE_STATE_PIXEL_SHADER_RESOURCE;

    pub fn open(p: *Window, shell: Shell, o: gpu_loop.Open, handles: u16) !void {
        std.debug.assert(handles <= max_textures);
        std.debug.assert(o.staging_bytes > 0);
        const w = shell.w;
        try p.g.open(w, .{ .rows = o.canvas_rows, .verts = o.canvas_verts });
        errdefer p.g.close();
        p.w = w;
        const g = &p.g.setup;
        const d = &g.device;
        const dev: gpu.Device = .wrap(d);
        p.arena = try .init(dev, .{ .bytes = o.gpu_bytes });
        errdefer p.arena.deinit();
        p.staging_arena = try .init(dev, .{ .bytes = 2 * o.staging_bytes, .memory = .host });
        errdefer p.staging_arena.deinit();
        p.staging[0] = try .init(dev, &p.staging_arena, o.staging_bytes);
        errdefer p.staging[0].deinit(dev);
        p.staging[1] = try .init(dev, &p.staging_arena, o.staging_bytes);
        while (g.gfx.texture_count < handles) _ = g.gfx.addTexture(d, g.white);
        p.tight = @splat(.{});
        p.writes = @splat(.{ .{}, .{} });
        p.retired = @splat(@splat(null));
    }

    pub fn close(p: *Window) void {
        p.waitIdle();
        for (&p.retired) |*slot| for (slot) |r| com.release(r);
        for (&p.writes) |*ch| for (ch) |b| com.release(b.buffer);
        for (p.tight) |t| com.release(t.buffer);
        const dev: gpu.Device = .wrap(&p.g.setup.device);
        for (p.staging) |s| s.deinit(dev);
        p.staging_arena.deinit();
        p.arena.deinit();
        p.g.close();
    }

    pub fn waitIdle(p: *Window) void {
        // tidy: allow(swallowed-error) a lost device has nothing left to wait for
        p.g.setup.device.waitIdle() catch {};
    }

    pub fn createImage(p: *Window, kind: ImageKind, size: [2]u32) !Image {
        std.debug.assert(size[0] > 0);
        std.debug.assert(size[1] > 0);
        const d = &p.g.setup.device;
        const w, const h = size;
        const rgba8 = c.DXGI_FORMAT_R8G8B8A8_UNORM;
        return switch (kind) {
            // Read as white with its byte as alpha (renderer.zig `addTexture`).
            .coverage => .{
                .resource = try d.createTexture(w, h, c.DXGI_FORMAT_R8_UNORM, false, readable),
                .size = size,
            },
            .rgba => .{
                .resource = try d.createTexture(w, h, rgba8, false, readable),
                .size = size,
            },
            .target => target: {
                const res = try d.createTexture(w, h, rgba8, true, sampled);
                errdefer com.release(res);
                const rtv = try d.handle.createDescriptorHeap(&.{
                    .Type = c.D3D12_DESCRIPTOR_HEAP_TYPE_RTV,
                    .NumDescriptors = 1,
                    .Flags = c.D3D12_DESCRIPTOR_HEAP_FLAG_NONE,
                    .NodeMask = 0,
                });
                d.handle.createRenderTargetView(res, null, rtv.cpuStart());
                break :target .{ .resource = res, .size = size, .rtv = rtv };
            },
        };
    }

    pub fn destroyImage(_: *Window, img: *Image) void {
        com.release(img.rtv);
        com.release(img.resource);
    }

    pub fn extent(img: *const Image) [2]u32 {
        return img.size;
    }

    pub fn bind(p: *Window, handle: u16, img: *const Image) void {
        const g = &p.g.setup;
        g.gfx.setTexture(&g.device, @fromBackingInt(handle), img.resource);
    }

    /// All of `img` from tight rows `bytes` in a submission of its own: for what `open` makes
    /// once.
    pub fn writeNow(p: *Window, img: *Image, bytes: []const u8) !void {
        const g = &p.g.setup;
        const d = &g.device;
        const r: d3d12.host.Rect = .{ .w = img.size[0], .h = img.size[1] };
        const row = bytes.len / (r.w * r.h) * r.w;
        std.debug.assert(row * r.h == bytes.len);
        const pitch = d3d12.host.rowPitch(r, @intCast(row / r.w));
        const staging = try d.createBuffer(@as(u64, pitch) * r.h, c.D3D12_HEAP_TYPE_UPLOAD);
        defer com.release(staging);
        const mapped = try staging.map(false);
        for (0..r.h) |y| @memcpy(mapped[y * pitch ..][0..row], bytes[y * row ..][0..row]);
        staging.unmap();
        const l = try g.once.begin();
        d3d12.host.uploadRegion(l, img.resource, readable, staging, 0, r);
        try g.once.submit(d);
    }

    pub fn targetTexture(img: *const Image) gpu.Texture {
        std.debug.assert(img.rtv != null);
        return .{
            .resource = img.resource,
            .format = Loop.Surface.format,
            .width = img.size[0],
            .height = img.size[1],
            .samples = 1,
            .resting = sampled,
            .rtv = img.rtv.?.cpuStart(),
        };
    }

    /// A minimised window (no client area) takes no frame: error.NotShown, as one the
    /// swapchain does not take. The buffers the slot's last frame retired are let go of.
    pub fn begin(p: *Window) !Frame {
        const f = p.g.target.begin(&p.g.setup, p.w.clientSize()) catch |e| return switch (e) {
            error.ZeroExtent => error.NotShown,
            else => e,
        };
        for (&p.retired[f.slot]) |*r| {
            com.release(r.*);
            r.* = null;
        }
        return f;
    }

    /// Room for `bytes` of tight rows in channel `ch`; the frame slot's buffers from its last
    /// frame are free (`begin` waited for it).
    pub fn stage(p: *Window, f: *Frame, ch: Channel, bytes: u64) ![]u8 {
        const t = &p.tight[@backingInt(ch)];
        // Never read by the GPU: an old buffer goes at once.
        if (t.size < bytes) try make(&p.g.setup.device, t, bytes, c.D3D12_HEAP_TYPE_READBACK);
        p.writes[@backingInt(ch)][f.slot].used = 0;
        return t.mapped[0..@intCast(bytes)];
    }

    /// Lays the staged rows of `r` from `at` out in the slot's upload buffer and records their
    /// copy. ponytail: `fresh` changes nothing, as D3D12 has no layout to discard.
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
        _ = fresh;
        std.debug.assert(r.x + r.w <= img.size[0]);
        std.debug.assert(r.y + r.h <= img.size[1]);
        const texel: u32 = if (img.resource.getDesc().Format == c.DXGI_FORMAT_R8_UNORM) 1 else 4;
        const region: d3d12.host.Rect = .{ .x = r.x, .y = r.y, .w = r.w, .h = r.h };
        const pitch = d3d12.host.rowPitch(region, texel);
        const need = @as(u64, pitch) * r.h;
        const b = &p.writes[@backingInt(ch)][f.slot];
        const placement = c.D3D12_TEXTURE_DATA_PLACEMENT_ALIGNMENT;
        var off = std.mem.alignForward(u64, b.used, placement);
        if (off + need > b.size) {
            p.grow(f.slot, b, need) catch @panic("lcgf_app: no memory for a texture upload");
            off = 0;
        }
        const row = r.w * texel;
        const tight = p.tight[@backingInt(ch)].mapped + @as(usize, @intCast(at));
        for (0..r.h) |y| {
            @memcpy(b.mapped[@intCast(off + y * pitch)..][0..row], tight[y * row ..][0..row]);
        }
        d3d12.host.uploadRegion(f.list, img.resource, readable, b.buffer.?, off, region);
        b.used = off + need;
    }

    pub fn gpuFrame(p: *Window, f: *Frame) gpu_loop.GpuParts(gpu) {
        const d = &p.g.setup.device;
        p.staging[f.slot].rewind();
        return .{
            .device = .wrap(d),
            .arena = &p.arena,
            .upload = .beginStaged(.wrap(d), f.list, &p.staging[f.slot]),
        };
    }

    pub fn present(p: *Window, f: *Frame, ui: gpu_loop.Ui) !void {
        const rows: ?d3d12.setup.Window.Rows = if (ui.rows) |r| .{
            .list = r.list,
            .glyphs = r.glyphs,
            .viewport = r.viewport,
            .scale = r.scale,
        } else null;
        const v: d3d12.setup.Window.Ui = .{
            .rows = rows,
            .damage = ui.damage,
            .clear = ui.clear,
            .canvases = ui.canvases,
        };
        try p.g.target.present(&p.g.setup, f, v);
    }

    pub fn kept(p: *const Window) ?*const DrawList {
        return p.g.setup.gfx.list;
    }

    pub fn canvasUploaded(p: *const Window) ?usize {
        const cv = p.g.setup.gfx.canvas orelse return null;
        return cv.uploaded;
    }

    /// A WM_PAINT: the window was uncovered or resized, and the picture still has its pixels.
    pub fn poll(p: *Window, ev: *Events) gpu_loop.Polled {
        if (!p.w.poll(ev)) return .closed;
        const exposed = p.w.damaged;
        p.w.damaged = false;
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

    // ---- private ----

    /// `b` made again with room for `need` bytes and more, its old buffer retired: this
    /// frame's copies recorded so far still read it.
    fn grow(p: *Window, slot: u32, b: *Writes, need: u64) !void {
        std.debug.assert(need > 0);
        const d = &p.g.setup.device;
        if (b.buffer) |old| {
            const free = for (&p.retired[slot]) |*r| {
                if (r.* == null) break r;
            } else null;
            if (free) |r| r.* = old else {
                p.waitIdle();
                com.release(old);
            }
        }
        b.buffer = null;
        try make(d, b, @max(need, 2 * b.size), c.D3D12_HEAP_TYPE_UPLOAD);
    }
};

/// Opens a Win32 window and Direct3D 12 over it, and runs the loop there until the window
/// closes. False, nothing left open, when there is no D3D12 device: the software path.
// tidy: allow-fn(large-generic-function) one instance per App
pub fn runApp(comptime App: type, app: *App, want: gpu_loop.Want, clock: anytype) !bool {
    std.debug.assert(want.size[0] > 0);
    std.debug.assert(want.size[1] > 0);
    // ponytail: static, as app.zig's buffers are: one window a program.
    const S = struct {
        var shell: Win32 = undefined;
        var gw: Loop.Window = undefined;
        var title: [256:0]u16 = undefined;
        var typed: [512]u8 = undefined;
        var events: [128]lcgf.input.Input.Event = undefined;
        var preedit: [256]u8 = undefined;
        var names: [8192]u8 = undefined;
        var ends: [64]u32 = undefined;
        // The shell's software framebuffer, never drawn into on the GPU.
        var pixels: [lcgf.render_sw.Framebuffer.len(16, 16)]u32 = undefined;
    };
    const title = want.title[0..@min(want.title.len, S.title.len)];
    const units = std.unicode.utf8ToUtf16Le(&S.title, title) catch 0;
    S.title[units] = 0;
    const bufs: Win32.Buffers = .{
        .text = &S.typed,
        .events = &S.events,
        .preedit = &S.preedit,
        .names = &S.names,
        .ends = &S.ends,
        .pixels = &S.pixels,
        .glyphs = want.quads,
        .first = want.first,
        .count = want.count,
    };
    S.shell.init(.{ .title = S.title[0..units :0], .size = want.size }, bufs) catch return false;
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

// ---- private ----

/// `b` made with room for `bytes` and more, in a buffer of `heap`, mapped: its old buffer, if
/// any, released (the caller keeps one a frame still reads).
fn make(
    d: *const d3d12.device.Device,
    b: *Window.Writes,
    bytes: u64,
    heap: c.D3D12_HEAP_TYPE,
) !void {
    std.debug.assert(bytes > 0);
    com.release(b.buffer);
    b.* = .{};
    const size = @max(bytes, 1 << 20);
    const buffer = try d.createBuffer(size, heap);
    errdefer com.release(buffer);
    const mapped = try buffer.map(heap == c.D3D12_HEAP_TYPE_READBACK);
    b.* = .{ .buffer = buffer, .mapped = mapped, .size = size };
    std.debug.assert(b.size >= bytes);
}

const Surface = Loop.Surface;
const GpuFrame = Loop.GpuFrame;
const testing = std.testing;

/// A shown Win32 window with Direct3D 12 over it and a context, the text in the bundled font
/// or a face of the test's. Filled in place; its buffers are static, one fixture at a time.
/// The tests run on Windows, or under Wine (ci/run.sh d3d12), and read the picture back.
const Fixture = struct {
    w: Win32,
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
    var typed: [64]u8 = undefined;
    var events: [32]lcgf.input.Input.Event = undefined;
    var preedit: [64]u8 = undefined;
    var names: [64]u8 = undefined;
    var ends: [4]u32 = undefined;
    var pixels: [lcgf.render_sw.Framebuffer.len(16, 16)]u32 = undefined;
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

    /// A 200 x 100 window at scale 1 (Wine may make it larger), the text service over `files`
    /// (none: the bundled font).
    fn open(fx: *Fixture, files: []const text.File) !void {
        std.debug.assert(files.len <= 1);
        const bufs: Win32.Buffers = .{
            .text = &typed,
            .events = &events,
            .preedit = &preedit,
            .names = &names,
            .ends = &ends,
            .pixels = &pixels,
            .glyphs = &quads,
            .first = &first,
            .count = &count,
        };
        try fx.w.init(.{ .size = .{ 200, 100 } }, bufs);
        errdefer fx.w.deinit();
        fx.w.t.setDpi(96);
        const room: gpu_loop.Open = .{ .gpu_bytes = 8 << 20, .staging_bytes = 1 << 20 };
        try fx.gw.open(.{ .w = &fx.w }, room);
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
        fx.w.deinit();
    }

    /// Runs `app` until `clock` says stop.
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

    /// `app` run for 0.3 s, then until its first frame is presented, nothing is owed and the
    /// swapchain is the window's size: a loaded machine takes longer, and Wine sizes a new
    /// window again in its own time. Up to 50 tries of 0.1 s.
    fn warm(fx: *Fixture, app: anytype) !void {
        try fx.run(app, seconds(0.3));
        for (0..50) |_| {
            try fx.settle(app, 0);
            const chain = &fx.gw.p.g.target.chain;
            if (std.meta.eql(fx.w.clientSize(), [2]u32{ chain.width, chain.height })) return;
            try fx.run(app, seconds(0.1));
        }
        return error.NeverSized;
    }

    /// `app` run until a frame past `presents` was presented and nothing is owed, or 30 s.
    fn settle(fx: *Fixture, app: anytype, presents: u32) !void {
        try fx.run(app, until(Settled{ .gw = &fx.gw, .presents = presents }));
    }

    /// The picture's pixels: what the window was last given, at its size. Free with
    /// `Shot.deinit`.
    fn read(fx: *Fixture) !Shot {
        const g = &fx.gw.p.g;
        const d = &g.setup.device;
        const width = g.target.chain.width;
        const height = g.target.chain.height;
        std.debug.assert(width >= 200);
        std.debug.assert(height >= 100);
        const px = try testing.allocator.alloc(Color, @as(usize, width) * height);
        errdefer testing.allocator.free(px);
        var rb = try d3d12.host.Readback.init(d, width, height);
        defer rb.deinit();
        const l = try g.setup.once.begin();
        rb.copy(l, g.target.picture);
        try g.setup.once.submit(d);
        try rb.read(std.mem.sliceAsBytes(px));
        return .{ .px = px, .width = width };
    }

    fn pixel(fx: *Fixture, x: usize, y: usize) !Color {
        const shot = try fx.read();
        defer shot.deinit();
        return shot.at(x, y);
    }
};

/// A picture read back: its pixels, row by row, `width` a row.
const Shot = struct {
    px: []Color,
    width: u32,

    fn at(s: Shot, x: usize, y: usize) Color {
        return s.px[y * s.width + x];
    }

    fn deinit(s: Shot) void {
        testing.allocator.free(s.px);
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

/// Stops once `done` says so, or after 30 s.
fn until(done: anytype) Clock(@TypeOf(done)) {
    return .{ .t0 = .now(testing.io, .awake), .seconds = 30, .done = done };
}

/// A button-like box beside a surface the application paints one colour at a time: `paints`
/// more frames of it, each a new colour, while `hot` toggling makes widget frames. As
/// src/app/gpu_x11.zig's.
const SurfaceApp = struct {
    plot: Surface = .{},
    builds: u32 = 0,
    draws: u32 = 0,
    paints: u32 = 0,
    toggles: u32 = 0,
    hot: bool = false,
    shade: u8 = 0,

    const ground: Color = .rgb(30, 30, 30);
    const lit: Color = .rgb(250, 250, 250);
    const plot_rect: [4]f32 = .{ 100, 20, 180, 80 };

    pub fn build(a: *SurfaceApp, f: *lcgf.frame.Frame, _: *const Events) void {
        a.builds += 1;
        if (a.toggles > 0) {
            a.toggles -= 1;
            a.hot = !a.hot;
            f.ctx.waker.post();
        }
        _ = f.open(.none, .{ .size = .{ .fill, .fill }, .fill = ground });
        const box: Color = if (a.hot) lit else .rgb(0, 0, 200);
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

const Settled = struct {
    gw: *const Loop.Window,
    presents: u32,
    fn stop(d: Settled) bool {
        const g = d.gw;
        return g.stats.presents > d.presents and g.rows == null and g.owed.count() == 0;
    }
};

const Painted = struct {
    a: *const SurfaceApp,
    fn stop(d: Painted) bool {
        return d.a.paints == 0;
    }
};

const Toggled = struct {
    a: *const SurfaceApp,
    fn stop(d: Toggled) bool {
        return d.a.toggles == 0;
    }
};

test "win32 T2: surface frames under an idle UI build nothing, upload no rows, redraw it only" {
    var fx: Fixture = undefined;
    try fx.open(&.{});
    defer fx.close();
    var app: SurfaceApp = .{};
    try fx.warm(&app);
    try testing.expect(app.draws >= 1);
    const builds = app.builds;
    const rows = fx.gw.stats.row_bytes;
    const before = try fx.read();
    defer before.deinit();
    app.paints = 100;
    app.plot.redraw();
    const draws = app.draws;
    try fx.run(&app, until(Painted{ .a = &app }));
    try testing.expect(app.draws - draws >= 100);
    try testing.expectEqual(builds, app.builds);
    try testing.expectEqual(rows, fx.gw.stats.row_bytes);
    // The picture's pass was scissored to the surface's rectangle, and only it.
    try testing.expectEqual(SurfaceApp.plot_rect, fx.gw.stats.damage.bounds());
    try testing.expectEqual(@as(u32, 1), fx.gw.stats.damage.count());
    // The last `redraw` (paints reached 0) is drawn: outside it the same bytes, inside it the
    // last colour.
    try fx.run(&app, seconds(0.2));
    const after = try fx.read();
    defer after.deinit();
    try testing.expectEqual(before.px.len, after.px.len);
    for (before.px, after.px, 0..) |b, a, k| {
        const x = k % after.width;
        const y = k / after.width;
        const inside = x >= 100 and x < 180 and y >= 20 and y < 80;
        if (!inside) try testing.expectEqual(b, a);
    }
    const inside = after.at(140, 50);
    try testing.expectEqual(app.shade, inside.r);
    try testing.expectEqual(255 - app.shade, inside.g);
}

test "win32 T3: widget frames beside a surface never call draw" {
    var fx: Fixture = undefined;
    try fx.open(&.{});
    defer fx.close();
    var app: SurfaceApp = .{};
    try fx.warm(&app);
    const draws = app.draws;
    const builds = app.builds;
    app.toggles = 100;
    fx.ctx.waker.post();
    try fx.run(&app, until(Toggled{ .a = &app }));
    try testing.expect(app.builds - builds >= 100);
    try testing.expectEqual(draws, app.draws);
}

test "win32 T4: an idle second presents nothing" {
    var fx: Fixture = undefined;
    try fx.open(&.{});
    defer fx.close();
    var app: SurfaceApp = .{};
    try fx.warm(&app);
    const presents = fx.gw.stats.presents;
    const builds = app.builds;
    try fx.run(&app, seconds(1));
    try testing.expectEqual(presents, fx.gw.stats.presents);
    try testing.expectEqual(builds, app.builds);
}

test "win32 not shown: a frame the window does not take owes the whole window, drawn when it is" {
    var fx: Fixture = undefined;
    try fx.open(&.{});
    defer fx.close();
    var app: SurfaceApp = .{};
    try fx.warm(&app);
    const presents = fx.gw.stats.presents;
    const whole = fx.gw.stats.whole;
    const refused = fx.gw.stats.not_shown;
    // A widget changes while the window takes no frame, for two attempts.
    fx.gw.refuse = 2;
    app.toggles = 1;
    fx.ctx.waker.post();
    try fx.run(&app, seconds(2 * gpu_loop.retry_seconds + 0.5));
    try fx.settle(&app, presents);
    try testing.expect(fx.gw.stats.not_shown - refused >= 2);
    try testing.expect(fx.gw.stats.presents > presents);
    try testing.expect(fx.gw.stats.whole > whole);
    try testing.expectEqual(SurfaceApp.lit, try fx.pixel(30, 30));
}

test "win32 not shown: a minimised window takes no frame, and one restored is drawn whole" {
    var fx: Fixture = undefined;
    try fx.open(&.{});
    defer fx.close();
    var app: SurfaceApp = .{};
    try fx.warm(&app);
    const presents = fx.gw.stats.presents;
    const refused = fx.gw.stats.not_shown;
    _ = ShowWindow(fx.w.hwnd, 6); // SW_MINIMIZE
    app.toggles = 1;
    fx.ctx.waker.post();
    try fx.run(&app, seconds(0.3));
    try testing.expect(fx.gw.stats.not_shown > refused);
    try testing.expectEqual(presents, fx.gw.stats.presents);
    const whole = fx.gw.stats.whole;
    _ = ShowWindow(fx.w.hwnd, 9); // SW_RESTORE
    try fx.run(&app, seconds(2 * gpu_loop.retry_seconds + 0.5));
    try fx.settle(&app, presents);
    try testing.expect(fx.gw.stats.presents > presents);
    try testing.expect(fx.gw.stats.whole > whole);
    try testing.expectEqual(SurfaceApp.lit, try fx.pixel(30, 30));
}

/// Two of the application's images on nodes and a line of text in the test face. As
/// src/app/gpu_x11.zig's.
const PictureApp = struct {
    const green: Color = .rgb(0, 200, 0);
    const ground: Color = .rgb(30, 30, 30);
    const blue: Color = .rgb(0, 0, 220);
    const Picture = struct { pixels: []const u32, size: [2]u32, generation: u32 = 0 };
    const first_rect = [4]f32{ 10, 10, 30, 30 };
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
        std.debug.assert(first_rect[2] <= 50);
        _ = f.open(.none, .{ .size = .{ .fill, .fill }, .fill = ground });
        const size: [2]lcgf.types.Size = .{ .px(20), .px(20) };
        const one: lcgf.types.Texture = @fromBackingInt(1);
        const two: lcgf.types.Texture = @fromBackingInt(2);
        const at: [2][2]f32 = .{ .{ 10, 10 }, .{ 50, 10 } };
        const image: lcgf.types.Style = .{ .float = true, .size = size, .fill = .white };
        var st = image;
        st.offset = at[0];
        st.texture = one;
        _ = f.leaf(.none, st);
        st.offset = at[1];
        st.texture = two;
        _ = f.leaf(.none, st);
        const line: lcgf.types.Style = .{ .float = true, .offset = .{ 100, 10 } };
        _ = f.textStyled("W", .{ .px = 20, .color = .white }, line);
        f.close();
    }
};

test "win32 images and text: images and the service's glyphs draw; a new generation, its node" {
    var fx: Fixture = undefined;
    try fx.open(&Fixture.face);
    defer fx.close();
    try testing.expect(fx.tw.on());
    var app: PictureApp = .{};
    try fx.warm(&app);
    const shot = try fx.read();
    defer shot.deinit();
    try testing.expectEqual(PictureApp.green, shot.at(20, 20));
    try testing.expectEqual(PictureApp.blue, shot.at(60, 20));
    try testing.expectEqual(PictureApp.ground, shot.at(50, 50));
    // The glyph covers part of its box, smoothly: some pixels lit, most of the box not. Its
    // atlas went through `copy`, its rows laid out again.
    var lit: u32 = 0;
    for (10..35) |y| for (100..115) |x| {
        lit += @intFromBool(shot.at(x, y).r > 128);
    };
    try testing.expect(lit > 12);
    try testing.expect(lit < 15 * 25 / 2);

    // New pixels in image 0, under a new generation: only its node is drawn, from them.
    const whole = fx.gw.stats.whole;
    const red: Color = .rgb(220, 0, 0);
    app.texels = @splat(red.bitsOf());
    app.generation += 1;
    fx.ctx.waker.post();
    try fx.settle(&app, fx.gw.stats.presents);
    try testing.expectEqual(red, try fx.pixel(20, 20));
    try testing.expectEqual(PictureApp.first_rect, fx.gw.stats.damage.bounds());
    try testing.expectEqual(whole, fx.gw.stats.whole);
    try testing.expectEqual(PictureApp.blue, try fx.pixel(60, 20));
}

extern "user32" fn ShowWindow(@FieldType(Win32, "hwnd"), c_int) callconv(.winapi) c_int;
