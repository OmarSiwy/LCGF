//! A Direct3D 12 setup for an application that brings no device of its own: the device and
//! renderer (`Setup`), and per window its swapchain, frames and picture (`Window`). The Vulkan
//! back end's src/render/vk/setup.zig on D3D12; an application that owns its D3D12 objects
//! uses `Renderer` directly instead (renderer.zig, "WHO OWNS WHAT").
//!
//! The window keeps its picture: a render target of its own, the swapchain's size and format,
//! that holds what the window shows between frames. A frame draws the UI into the picture only
//! inside its damage, from rows that stay in the renderer's upload ring until a new list
//! replaces them, then copies the picture to the back buffer (docs/plans/window.md, "How a
//! frame is drawn").
//!
//!     var g: Setup = undefined;
//!     try g.init(.{}, .{});
//!     var w = try Window.init(&g, hwnd, .{ width, height });
//!     // per frame, in one call:
//!     try w.draw(&g, list, glyphs, viewport, scale, clear, .{ width, height });
//!     // or in two, with the application's own work between them:
//!     const f = try w.begin(&g, .{ width, height });
//!     ... its uploads and passes, recorded into f.list ...
//!     try w.present(&g, &f, .{ .rows = rows, .damage = list.damage, .clear = clear });
//!     w.deinit(&g);
//!     g.deinit();
//!
//! Contents
//!   pub const Setup = struct
//!     pub const Canvas = struct
//!     pub fn init(g: *Setup, desc: device.Desc, canvas: Canvas) !void
//!     pub fn deinit(g: *Setup) void
//!   pub const Window = struct
//!     pub const wait_ms
//!     pub const Frame = struct
//!     pub const Ui = struct
//!     pub const Rows = struct
//!     pub fn init(g: *Setup, hwnd: c.HWND, size: [2]u32) !Window
//!     pub fn deinit(w: *Window, g: *Setup) void
//!     pub fn draw(w: *Window, g: *Setup, list: *const DrawList, glyphs: Glyphs,
//!         viewport: [2]f32, scale: f32, clear: [4]f32, want: [2]u32) !void
//!     pub fn begin(w: *Window, g: *Setup, want: [2]u32) !Frame
//!     pub fn present(w: *Window, g: *Setup, f: *const Frame, ui: Ui) !void
//!     pub fn rebuild(w: *Window, g: *Setup, want: [2]u32) !void

const std = @import("std");
const lcgf = @import("lcgf");
const com = @import("com.zig");
const device = @import("device.zig");
const frame = @import("frame.zig");
const host = @import("host.zig");
const renderer = @import("renderer.zig");
const c = com.c;
const Device = device.Device;
const Swapchain = device.Swapchain;
const transition = device.transition;
const DrawList = lcgf.draw_list.DrawList;
const Region = lcgf.damage.Region;
const Glyphs = renderer.Glyphs;

/// The device and what is drawn with: made once, kept while windows come and go. Filled in
/// place and not moved after: the renderer keeps a pointer to `device`.
pub const Setup = struct {
    device: Device,
    once: host.Once,
    /// `Texture.white`, and what an unused texture handle shows.
    white: *com.Resource,
    gfx: renderer.CanvasRenderer,
    /// The renderer's ring slot the next new list is uploaded to: never the slot of the rows
    /// drawn last, which a frame still in flight may be reading (`Window.present`).
    rows_next: u32,
    /// The same for the canvases' copy: counted apart, as a frame may write the canvases
    /// alone (`Ui.canvases`) and leave the rows where they are.
    canvases_next: u32,

    /// Canvas instance rows and polygon vertices the renderer keeps on the GPU
    /// (`renderer.Desc.canvas_rows`, `canvas_verts`); none: canvases draw nothing.
    pub const Canvas = struct { rows: u32 = 0, verts: u32 = 0 };

    /// The device on `desc`'s adapter and an RGBA8 renderer of two ring slots. Fails as
    /// `Device.init` does (no adapter, no D3D12), leaving nothing open.
    pub fn init(g: *Setup, desc: device.Desc, canvas: Canvas) !void {
        g.device = try .init(desc);
        errdefer g.device.deinit();
        g.once = try .init(&g.device);
        errdefer g.once.deinit();
        g.white = try host.sampled(&g.device, &g.once, 1, 1, &.{ 0xff, 0xff, 0xff, 0xff });
        errdefer com.release(g.white);
        const rd: renderer.Desc = .{
            .frames = 2,
            .canvas_rows = canvas.rows,
            .canvas_verts = canvas.verts,
        };
        g.gfx = try .init(&g.device, rd, g.white);
        g.rows_next = 0;
        g.canvases_next = 0;
    }

    /// Waits for the device, then lets go of everything `init` made.
    pub fn deinit(g: *Setup) void {
        // tidy: allow(swallowed-error) a lost device has nothing left to wait for
        g.device.waitIdle() catch {};
        g.gfx.deinit();
        com.release(g.white);
        g.once.deinit();
        g.device.deinit();
    }
};

/// A window's swapchain, frames and picture: made when a window arrives, gone with it. One
/// window per `Setup`: the rows on the GPU are the setup's renderer's, and a frame with no new
/// list draws the last list any window gave.
pub const Window = struct {
    chain: Swapchain,
    frames: frame.Frames,
    /// What the window shows, kept between frames: the swapchain's size and format, a render
    /// target and copy source. Rests in COPY_SOURCE between frames.
    picture: *com.Resource,
    /// The picture's render target view.
    rtv: *com.DescriptorHeap,
    /// The picture holds nothing yet (new, or made again with the swapchain): the next
    /// `present` draws all of it, whatever damage it is given.
    lost: bool = true,
    /// The last present went nowhere (DXGI_STATUS_OCCLUDED): `begin` asks the swapchain
    /// whether the window shows frames again before it draws one.
    occluded: bool = false,

    /// How long `begin` waits for the swapchain to take a frame. A shown window's latency
    /// object is signalled within a refresh or two; past this it is not shown.
    pub const wait_ms: u32 = 100;

    /// A frame between `begin` and `present`: its command list recording outside any pass.
    pub const Frame = struct {
        /// The frame's command list. An application records its own uploads and passes into
        /// it before `present` (its `gpu.Upload` begun on it with a staging ring of its own,
        /// one per `slot`); at `present` its render targets are its own business, `present`
        /// sets the picture.
        list: *com.GraphicsCommandList,
        /// The frame slot, 0 or 1: the previous frame in it has finished on the GPU, so
        /// what it wrote (a staging ring) is free.
        slot: u32,
        acquired: frame.Frame,
    };

    /// What `present` draws into the picture.
    pub const Ui = struct {
        /// A new list to upload and draw from, or null: the list of the last `rows` given is
        /// unchanged and still alive, and its rows on the GPU are drawn again with no upload.
        rows: ?Rows,
        /// Logical pixels to draw again: the list's `damage`, with any rect of the
        /// application's added. Ignored (everything is drawn) while the picture is `lost`.
        /// Outside it the picture keeps last frame's pixels.
        damage: Region,
        /// Straight RGBA, 0 to 1: each damage rect is cleared to it before the list draws.
        clear: [4]f32,
        /// With no new `rows`: the kept list's canvas rows changed (a camera, a palette, an
        /// instance's rows), so their uniforms and dirty rows are written again, the list's
        /// quads not. Implied by `rows`.
        canvases: bool = false,
    };

    pub const Rows = struct {
        /// Not culled to its damage (`Context.trackDamageWhole`, or no damage tracking): a
        /// later frame may draw any rect of the window from these rows.
        list: *const DrawList,
        glyphs: Glyphs,
        viewport: [2]f32,
        scale: f32,
    };

    /// A flip-model swapchain on `hwnd` of `size` physical pixels, and its picture. Asserts
    /// that the renderer has two ring slots and that `size` is not zero.
    pub fn init(g: *Setup, hwnd: c.HWND, size: [2]u32) !Window {
        // A new list goes to the ring slot the rows drawn last are not in, which is free only
        // while at most one other frame is in flight (`present`).
        std.debug.assert(g.gfx.desc.frames == 2);
        std.debug.assert(size[0] > 0);
        std.debug.assert(size[1] > 0);
        const d = &g.device;
        const chain_desc: Swapchain.Desc = .{
            .width = size[0],
            .height = size[1],
            .format = g.gfx.desc.format,
            .flags = frame.flags,
        };
        var chain: Swapchain = try .init(d, hwnd, chain_desc);
        errdefer chain.deinit();
        var frames: frame.Frames = try .init(d, &chain, g.gfx.desc.frames);
        errdefer frames.deinit();
        frames.wait_ms = wait_ms;
        const rtv = try d.handle.createDescriptorHeap(&.{
            .Type = c.D3D12_DESCRIPTOR_HEAP_TYPE_RTV,
            .NumDescriptors = 1,
            .Flags = c.D3D12_DESCRIPTOR_HEAP_FLAG_NONE,
            .NodeMask = 0,
        });
        errdefer com.release(rtv);
        const picture = try makePicture(d, &chain, rtv);
        return .{ .chain = chain, .frames = frames, .picture = picture, .rtv = rtv };
    }

    pub fn deinit(w: *Window, g: *Setup) void {
        // tidy: allow(swallowed-error) a lost device has nothing left to wait for
        g.device.waitIdle() catch {};
        com.release(w.picture);
        com.release(w.rtv);
        w.frames.deinit();
        w.chain.deinit();
    }

    /// `begin` and `present` in one call, for a host with nothing of its own to draw: uploads
    /// `list` and draws it inside `list.damage` (all of the window unless the context tracks
    /// damage), each rect cleared to `clear` first.
    // tidy: allow(too-many-parameters) a frame's rows, clear and size in one call, as vk's
    pub fn draw(
        w: *Window,
        g: *Setup,
        list: *const DrawList,
        glyphs: Glyphs,
        viewport: [2]f32,
        scale: f32,
        clear: [4]f32,
        want: [2]u32,
    ) !void {
        const f = try w.begin(g, want);
        const rows: Rows = .{
            .list = list,
            .glyphs = glyphs,
            .viewport = viewport,
            .scale = scale,
        };
        try w.present(g, &f, .{ .rows = rows, .damage = list.damage, .clear = clear });
    }

    /// Begins the next frame's command list. A swapchain whose size is not `want` is resized
    /// first, and the picture made again: the next `present` draws all of it. Blocks on the
    /// swapchain's latency object (which paces it to the display) and on the fence of the
    /// frame two before.
    /// error.NotShown: the last present went nowhere and the window still shows nothing
    /// (minimised, covered), or the swapchain took no frame within `wait_ms`; nothing was
    /// drawn, the picture and the damage owed are as they were, so wait for an event and try
    /// again. error.ZeroExtent: `want` has no area (a minimised window), try again when it
    /// has a size. error.DeviceLost: make the setup and the window again (device.zig).
    pub fn begin(w: *Window, g: *Setup, want: [2]u32) !Frame {
        if (want[0] == 0 or want[1] == 0) return error.ZeroExtent;
        if (w.occluded) {
            if (try w.chain.visible() == .occluded) return error.NotShown;
            w.occluded = false;
        }
        if (want[0] != w.chain.width or want[1] != w.chain.height) try w.rebuild(g, want);
        const acquired = w.frames.begin(&g.device, &w.chain) catch |e| switch (e) {
            error.Timeout => return error.NotShown,
            else => return e,
        };
        std.debug.assert(acquired.slot < g.gfx.desc.frames);
        std.debug.assert(w.picture.getDesc().Width == w.chain.width);
        return .{ .list = acquired.list, .slot = acquired.slot, .acquired = acquired };
    }

    /// Draws the UI into the picture, copies the picture to `f`'s back buffer and presents
    /// it. With `ui.rows` the list is uploaded first; without, the rows of the last list are
    /// drawn again. One pass on the picture that keeps it; per damage rect a clear and the
    /// whole list scissored to the rect: the scissor culls, so the list stays whole. A present
    /// that goes nowhere is not an error: the next `begin` says `NotShown` until the window
    /// shows frames again. Asserts that some `rows` were given before.
    pub fn present(w: *Window, g: *Setup, f: *const Frame, ui: Ui) !void {
        std.debug.assert(ui.rows != null or g.gfx.list != null);
        std.debug.assert(w.picture.getDesc().Height == w.chain.height);
        const l = f.list;
        if (ui.rows) |r| {
            g.gfx.prepareRows(g.rows_next, r.list, r.glyphs, r.viewport, r.scale);
            g.rows_next = (g.rows_next + 1) % g.gfx.desc.frames;
        }
        if (ui.rows != null or ui.canvases) {
            g.gfx.prepareCanvases(g.canvases_next);
            g.canvases_next = (g.canvases_next + 1) % g.gfx.desc.frames;
        }
        const target = c.D3D12_RESOURCE_STATE_RENDER_TARGET;
        const source = c.D3D12_RESOURCE_STATE_COPY_SOURCE;
        const dest = c.D3D12_RESOURCE_STATE_COPY_DEST;
        l.resourceBarrier(&.{transition(w.picture, source, target)});
        l.omSetRenderTarget(w.rtv.cpuStart());
        const size: [2]u32 = .{ w.chain.width, w.chain.height };
        drawDamage(g, l, w.rtv.cpuStart(), if (w.lost) .everything else ui.damage, ui.clear, size);
        const buffer = f.acquired.buffer;
        const out = [_]c.D3D12_RESOURCE_BARRIER{
            transition(w.picture, target, source),
            transition(buffer, target, dest),
        };
        l.resourceBarrier(&out);
        copyWhole(l, buffer, w.picture);
        // `Frames.present` takes the back buffer from RENDER_TARGET to PRESENT.
        l.resourceBarrier(&.{transition(buffer, dest, target)});
        w.lost = false;
        w.occluded = try w.frames.present(&g.device, &w.chain, f.acquired, 1) == .occluded;
    }

    /// The swapchain resized to `want` and the picture made again (WM_SIZE): waits for the
    /// GPU, which DXGI needs to let go of the buffers. The next `present` draws all of the
    /// picture: from new rows when the size changed, since the last list was laid out for the
    /// old one. Asserts that `want` has area.
    pub fn rebuild(w: *Window, g: *Setup, want: [2]u32) !void {
        std.debug.assert(want[0] > 0);
        std.debug.assert(want[1] > 0);
        const d = &g.device;
        try d.waitIdle();
        try w.chain.resize(d, want[0], want[1]);
        com.release(w.picture);
        w.picture = try makePicture(d, &w.chain, w.rtv);
        w.lost = true;
    }
};

// ---- private ----

/// A render target of `chain`'s size and format in COPY_SOURCE, its view written into `rtv`.
fn makePicture(d: *const Device, chain: *const Swapchain, rtv: *com.DescriptorHeap) !*com.Resource {
    std.debug.assert(chain.width > 0);
    std.debug.assert(chain.height > 0);
    const state = c.D3D12_RESOURCE_STATE_COPY_SOURCE;
    const picture = try d.createTexture(chain.width, chain.height, chain.format, true, state);
    d.handle.createRenderTargetView(picture, null, rtv.cpuStart());
    return picture;
}

/// Per non-empty rect of `damage`: cleared to `clear`, then the renderer's last list drawn
/// with its scissor narrowed to the rect. Into render target `rtv`, of `size`.
fn drawDamage(
    g: *Setup,
    l: *com.GraphicsCommandList,
    rtv: c.D3D12_CPU_DESCRIPTOR_HANDLE,
    damage: Region,
    clear: [4]f32,
    size: [2]u32,
) void {
    std.debug.assert(size[0] > 0);
    std.debug.assert(size[1] > 0);
    const list = g.gfx.list.?;
    const whole = g.gfx.scissor;
    for (0..lcgf.damage.max_rects) |k| {
        const box = damage.rect(@intCast(k));
        const r = Region.scissor(box, size, g.gfx.scale);
        if (r[2] == 0 or r[3] == 0) continue;
        const rect: c.D3D12_RECT = .{
            .left = @intCast(r[0]),
            .top = @intCast(r[1]),
            .right = @intCast(r[0] + r[2]),
            .bottom = @intCast(r[1] + r[3]),
        };
        l.clearRenderTargetRect(rtv, clear, rect);
        g.gfx.scissor = rect;
        g.gfx.render(l, list);
    }
    g.gfx.scissor = whole;
}

/// Copies all of `src` into `dst`, of its size and format: `src` in COPY_SOURCE, `dst` in
/// COPY_DEST.
fn copyWhole(l: *com.GraphicsCommandList, dst: *com.Resource, src: *com.Resource) void {
    std.debug.assert(dst.getDesc().Width == src.getDesc().Width);
    std.debug.assert(dst.getDesc().Height == src.getDesc().Height);
    var to: c.D3D12_TEXTURE_COPY_LOCATION = std.mem.zeroes(c.D3D12_TEXTURE_COPY_LOCATION);
    to.pResource = @ptrCast(@alignCast(dst));
    to.Type = c.D3D12_TEXTURE_COPY_TYPE_SUBRESOURCE_INDEX;
    var from: c.D3D12_TEXTURE_COPY_LOCATION = std.mem.zeroes(c.D3D12_TEXTURE_COPY_LOCATION);
    from.pResource = @ptrCast(@alignCast(src));
    from.Type = c.D3D12_TEXTURE_COPY_TYPE_SUBRESOURCE_INDEX;
    l.copyTextureRegion(&to, &from);
}

const testing = std.testing;
const Context = lcgf.context.Context;
const Color = lcgf.types.Color;

/// A setup and window over a hidden HWND, and a context whose frames fill the window with one
/// colour. Filled in place: the renderer points at the setup's device.
const Hidden = struct {
    g: Setup,
    hwnd: device.Window,
    w: Window,
    ctx: Context,
    in: lcgf.input.Input,

    const limits: lcgf.context.Limits = .{
        .nodes = 4,
        .texts = 1,
        .customs = 1,
        .strings = 16,
        .depth = 4,
    };
    var buffer: [Context.requiredBytes(limits)]u8 align(lcgf.mem.column_align) = undefined;

    fn init(h: *Hidden, width: u32, height: u32, canvas: Setup.Canvas) !void {
        try h.g.init(.{ .adapter = .warp }, canvas);
        errdefer h.g.deinit();
        h.hwnd = try .init(width, height, false);
        errdefer h.hwnd.deinit();
        h.w = try .init(&h.g, h.hwnd.hwnd, .{ width, height });
        h.ctx = try .init(&buffer, limits);
        h.in = .{ .viewport = .{ @floatFromInt(width), @floatFromInt(height) } };
    }

    fn deinit(h: *Hidden) void {
        h.w.deinit(&h.g);
        h.hwnd.deinit();
        h.g.deinit();
    }

    /// A list that is all `color`, laid out at `in.viewport`.
    fn fill(h: *Hidden, color: Color) *DrawList {
        var f = h.ctx.begin(&h.in);
        _ = f.leaf(.none, .{ .size = .{ .fill, .fill }, .fill = color });
        _ = f.end(.{});
        return &h.ctx.draw;
    }

    fn size(h: *const Hidden) [2]u32 {
        return .{ @intFromFloat(h.in.viewport[0]), @intFromFloat(h.in.viewport[1]) };
    }

    /// `Window.begin` at `in.viewport`, tried again while the swapchain takes no frame: a
    /// loaded machine can hold the latency object past `wait_ms`. Gives up after 50 tries,
    /// 5 s of waits.
    fn begin(h: *Hidden) !Window.Frame {
        for (0..50) |_| {
            if (h.w.begin(&h.g, h.size())) |f| return f else |e| if (e != error.NotShown) return e;
        }
        return error.NotShown;
    }

    /// One frame at `in.viewport`, waited for: `list` uploaded (or none), `damage` drawn.
    fn present(h: *Hidden, list: ?*const DrawList, damage: Region) !void {
        const f = try h.begin();
        try h.finish(&f, list, damage);
    }

    fn finish(h: *Hidden, f: *const Window.Frame, list: ?*const DrawList, damage: Region) !void {
        var rows: ?Window.Rows = null;
        if (list) |l| rows = .{ .list = l, .glyphs = .{}, .viewport = h.in.viewport, .scale = 1 };
        try h.w.present(&h.g, f, .{ .rows = rows, .damage = damage, .clear = .{ 0, 0, 0, 1 } });
        try h.g.device.waitIdle();
    }

    /// The picture's pixels, RGBA, into `out`.
    fn read(h: *Hidden, out: []u8) !void {
        const s = h.size();
        var rb = try host.Readback.init(&h.g.device, s[0], s[1]);
        defer rb.deinit();
        const l = try h.g.once.begin();
        rb.copy(l, h.w.picture);
        try h.g.once.submit(&h.g.device);
        try rb.read(out);
    }
};

fn at(px: []const u8, width: u32, x: usize, y: usize) [4]u8 {
    return px[(y * width + x) * 4 ..][0..4].*;
}

const blue = [4]u8{ 0, 0, 255, 255 };
const red = [4]u8{ 255, 0, 0, 255 };

test "setup: T1, a red list damaged in a 32 x 32 rect is red there and the blue frame elsewhere" {
    var h: Hidden = undefined;
    try h.init(64, 48, .{});
    defer h.deinit();
    try h.present(h.fill(.rgb(0, 0, 255)), .everything);
    const list = h.fill(.rgb(255, 0, 0));
    list.damage = .empty;
    list.damage.add(.{ 8, 8, 40, 40 });
    try h.present(list, list.damage);
    var px: [64 * 48 * 4]u8 = undefined;
    try h.read(&px);
    for (0..48) |y| for (0..64) |x| {
        const inside = x >= 8 and x < 40 and y >= 8 and y < 40;
        try testing.expectEqual(if (inside) red else blue, at(&px, 64, x, y));
    };
}

test "setup: a frame with no new list uploads nothing and draws its damage from the rows kept" {
    var h: Hidden = undefined;
    try h.init(64, 48, .{});
    defer h.deinit();
    try h.present(h.fill(.rgb(0, 0, 255)), .everything);
    const list = h.fill(.rgb(255, 0, 0));
    list.damage = .empty;
    list.damage.add(.{ 8, 8, 40, 40 });
    try h.present(list, list.damage);
    var before: [64 * 48 * 4]u8 = undefined;
    try h.read(&before);
    const ring = try testing.allocator.dupe(u8, h.g.gfx.mapped);
    defer testing.allocator.free(ring);

    // Nothing damaged: the same pixels, and not a byte of either ring slot written.
    try h.present(null, .empty);
    var px: [64 * 48 * 4]u8 = undefined;
    try h.read(&px);
    try testing.expectEqualSlices(u8, &before, &px);
    try testing.expectEqualSlices(u8, ring, h.g.gfx.mapped);

    // A rect damaged with no new list (a surface's) is drawn from the red rows still on the
    // GPU; the rest keeps its pixels.
    var surface: Region = .empty;
    surface.add(.{ 48, 0, 64, 16 });
    try h.present(null, surface);
    try h.read(&px);
    try testing.expectEqualSlices(u8, ring, h.g.gfx.mapped);
    try testing.expectEqual(red, at(&px, 64, 48, 0));
    try testing.expectEqual(red, at(&px, 64, 63, 15));
    try testing.expectEqual(blue, at(&px, 64, 47, 0));
    try testing.expectEqual(blue, at(&px, 64, 48, 16));
    try testing.expectEqual(red, at(&px, 64, 8, 8));
    try testing.expectEqual(blue, at(&px, 64, 0, 0));
}

test "setup: a resize makes the picture again and draws all of it, whatever the damage" {
    var h: Hidden = undefined;
    try h.init(64, 48, .{});
    defer h.deinit();
    try h.present(h.fill(.rgb(0, 0, 255)), .everything);
    h.in.viewport = .{ 80, 60 };
    const list = h.fill(.rgb(255, 0, 0));
    try h.present(list, .empty);
    try testing.expectEqual(@as(u64, 80), h.w.picture.getDesc().Width);
    try testing.expectEqual(@as(u32, 60), h.w.chain.height);
    var px: [80 * 60 * 4]u8 = undefined;
    try h.read(&px);
    for (0..60) |y| for (0..80) |x| try testing.expectEqual(red, at(&px, 80, x, y));
}

test "setup: a swapchain that takes no frame within wait_ms is NotShown, and nothing is drawn" {
    var h: Hidden = undefined;
    try h.init(64, 48, .{});
    defer h.deinit();
    try h.present(h.fill(.rgb(0, 0, 255)), .everything);
    // A frame begun and not presented holds the one frame of latency the swapchain allows:
    // the next `begin` waits `wait_ms` for the latency object and gives up.
    const f = try h.begin();
    try testing.expectError(error.NotShown, h.w.begin(&h.g, h.size()));
    try testing.expectError(error.ZeroExtent, h.w.begin(&h.g, .{ 0, 48 }));
    // The frame begun first is still good, and draws what it was given.
    const list = h.fill(.rgb(255, 0, 0));
    list.damage = .empty;
    list.damage.add(.{ 0, 0, 16, 16 });
    try h.finish(&f, list, list.damage);
    var px: [64 * 48 * 4]u8 = undefined;
    try h.read(&px);
    try testing.expectEqual(red, at(&px, 64, 15, 15));
    try testing.expectEqual(blue, at(&px, 64, 16, 16));
}

test "setup: an R8 texture written by uploadRegion samples as white with its byte as alpha" {
    var h: Hidden = undefined;
    try h.init(64, 48, .{});
    defer h.deinit();
    const g = &h.g;
    const d = &g.device;
    const dest = c.D3D12_RESOURCE_STATE_COPY_DEST;
    const tex = try d.createTexture(4, 4, c.DXGI_FORMAT_R8_UNORM, false, dest);
    defer com.release(tex);
    const region: host.Rect = .{ .x = 2, .y = 0, .w = 2, .h = 4 };
    const pitch = host.rowPitch(region, 1);
    const staging = try d.createBuffer(@as(u64, pitch) * region.h, c.D3D12_HEAP_TYPE_UPLOAD);
    defer com.release(staging);
    const mapped = try staging.map(false);
    for (0..region.h) |y| @memset(mapped[y * pitch ..][0..region.w], 0xff);
    staging.unmap();
    const l = try g.once.begin();
    // The left half is written zero first, as an atlas's whole first write is.
    const zeros = try d.createBuffer(@as(u64, pitch) * 4, c.D3D12_HEAP_TYPE_UPLOAD);
    defer com.release(zeros);
    const z = try zeros.map(false);
    @memset(z[0 .. pitch * 4], 0);
    zeros.unmap();
    host.uploadRegion(l, tex, dest, zeros, 0, .{ .w = 4, .h = 4 });
    host.uploadRegion(l, tex, c.D3D12_RESOURCE_STATE_PIXEL_SHADER_RESOURCE, staging, 0, region);
    try g.once.submit(d);
    const handle = g.gfx.addTexture(d, tex);
    // A red window, and over it a quad the texture's size of the window: white where the
    // texture's bytes are 0xff, red where they are 0.
    var f = h.ctx.begin(&h.in);
    _ = f.open(.none, .{ .size = .{ .fill, .fill }, .fill = .rgb(255, 0, 0) });
    _ = f.leaf(.none, .{ .size = .{ .fill, .fill }, .fill = .white, .texture = handle });
    f.close();
    _ = f.end(.{});
    try h.present(&h.ctx.draw, .everything);
    var px: [64 * 48 * 4]u8 = undefined;
    try h.read(&px);
    try testing.expectEqual(red, at(&px, 64, 8, 24));
    try testing.expectEqual([4]u8{ 255, 255, 255, 255 }, at(&px, 64, 56, 24));
}

test "setup: a canvas moved with no new list is drawn again inside the damage rect only" {
    const conformance = lcgf.render_conformance;
    const sc = conformance.canvas_scene;
    var h: Hidden = undefined;
    try h.init(800, 600, .{ .rows = sc.rows, .verts = sc.verts });
    defer h.deinit();
    const st = try testing.allocator.create(conformance.CanvasStorage);
    defer testing.allocator.destroy(st);
    st.load();
    try h.present(&st.draw, .everything);
    const before = try testing.allocator.alloc(u8, 800 * 600 * 4);
    defer testing.allocator.free(before);
    try h.read(before);
    // The camera pans 40 pixels: what a `lcgf_app.Canvas.redraw` writes into the kept list.
    st.rows[0].camera.offset[0] += 40;
    var damage: Region = .empty;
    damage.add(.{ 100, 100, 300, 300 });
    const f = try h.begin();
    const ui: Window.Ui = .{
        .rows = null,
        .damage = damage,
        .clear = .{ 0, 0, 0, 1 },
        .canvases = true,
    };
    try h.w.present(&h.g, &f, ui);
    try h.g.device.waitIdle();
    const after = try testing.allocator.alloc(u8, 800 * 600 * 4);
    defer testing.allocator.free(after);
    try h.read(after);
    var inside_changed: u32 = 0;
    for (0..600) |y| for (0..800) |x| {
        const inside = x >= 100 and x < 300 and y >= 100 and y < 300;
        const same = std.meta.eql(at(before, 800, x, y), at(after, 800, x, y));
        if (!inside) try testing.expect(same);
        inside_changed += @intFromBool(inside and !same);
    };
    try testing.expect(inside_changed > 0);
}
