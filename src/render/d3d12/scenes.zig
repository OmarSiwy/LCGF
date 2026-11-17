//! The render conformance scenes (src/render/conformance.zig) drawn by the Direct3D 12 back end,
//! as a host would: used by d3d12-play (PNG files for tools/golden/golden.py) and by the test
//! below, which compares every scene with its golden image.
//!
//! The host side mirrors src/render/conformance/render.py, which drew the goldens: a target
//! cleared to black, nearest sampling, scale 1, the same stand-in glyph atlas, and the custom
//! command drawn inline by the host's own pipeline (custom.zig) in the renderer's command list.
//!
//!   offscreen  an RGBA8 texture, read back after the frame.
//!   present    a hidden window's waitable flip-model swapchain through the frame loop
//!              (frame.zig: latency wait, slot fence, present), the back buffer copied out
//!              just before it is presented: the pixels a window shows.

const std = @import("std");
const lcgf = @import("lcgf");
const com = @import("com.zig");
const device_mod = @import("device.zig");
const host = @import("host.zig");
const frame = @import("frame.zig");
const custom = @import("custom.zig");
const Renderer = @import("renderer.zig").Renderer;
const c = com.c;
const Device = device_mod.Device;
const transition = device_mod.transition;
const conformance = lcgf.render_conformance;
const iface = lcgf.render_iface;

pub const Mode = enum { offscreen, present };

/// Every scene's size.
pub const width = 160;
pub const height = 120;

pub const Player = struct {
    mode: Mode,
    d: Device,
    once: host.Once,
    white: *com.Resource,
    atlas: *com.Resource,
    gfx: Renderer,
    atlas_handle: lcgf.types.Texture,
    gradient: custom.Gradient,
    target: host.Target,
    readback: host.Readback,
    window: device_mod.Window,
    chain: device_mod.Swapchain,
    frames: frame.Frames,
    st: conformance.Storage,

    /// Fills `p` in place (`st` holds the draw list's memory and must not move).
    pub fn init(p: *Player, mode: Mode) !void {
        p.mode = mode;
        p.st = .{};
        if (mode == .present) p.window = try .init(width, height, false);
        try p.initGpu();
    }

    /// Everything made from a device, against the window `p` already has.
    fn initGpu(p: *Player) !void {
        p.d = try Device.init(.{ .adapter = .warp });
        errdefer p.d.deinit();
        p.once = try host.Once.init(&p.d);
        p.white = try host.sampled(&p.d, &p.once, 1, 1, &.{ 0xff, 0xff, 0xff, 0xff });
        p.atlas = try host.sampled(&p.d, &p.once, 64, 64, &standInAtlas());
        p.gfx = try Renderer.init(&p.d, .{ .frames = 2 }, p.white);
        p.atlas_handle = p.gfx.addTexture(&p.d, p.atlas);
        p.gradient = try custom.Gradient.init(p.d.handle, c.DXGI_FORMAT_R8G8B8A8_UNORM);
        p.target = try host.Target.init(&p.d, width, height);
        p.readback = try host.Readback.init(&p.d, width, height);
        if (p.mode == .present) {
            p.chain = try .init(&p.d, p.window.hwnd, .{ .width = width, .height = height, .flags = frame.flags });
            p.frames = try .init(&p.d, &p.chain, 2);
        }
    }

    pub fn deinit(p: *Player) void {
        p.deinitGpu();
        if (p.mode == .present) p.window.deinit();
    }

    /// After `error.DeviceLost`: releases everything made from the lost device, in reverse
    /// order, and makes it again on a new device, against the same window.
    pub fn recover(p: *Player) !void {
        p.deinitGpu();
        try p.initGpu();
    }

    fn deinitGpu(p: *Player) void {
        p.d.waitIdle() catch {};
        if (p.mode == .present) {
            p.frames.deinit();
            p.chain.deinit();
        }
        p.readback.deinit();
        p.target.deinit();
        p.gradient.deinit();
        p.gfx.deinit();
        com.release(p.atlas);
        com.release(p.white);
        p.once.deinit();
        p.d.deinit();
    }

    /// Draws `s` and writes its pixels into `px` as RGBA rows (`width` x `height`).
    pub fn draw(p: *Player, s: *const conformance.Scene, px: []u8) !void {
        std.debug.assert(s.viewport[0] == width and s.viewport[1] == height);
        p.st.load(s);
        var glyphs = p.st.glyphs();
        glyphs.texture = p.atlas_handle;
        switch (p.mode) {
            .offscreen => {
                p.gfx.prepare(0, &p.st.draw, glyphs, s.viewport, 1);
                const l = try p.once.begin();
                p.drawFrame(l, p.target.texture, p.target.rtv());
                try p.once.submit(&p.d);
            },
            .present => {
                const f = try p.frames.begin(&p.d, &p.chain);
                p.gfx.prepare(f.slot, &p.st.draw, glyphs, s.viewport, 1);
                p.drawFrame(f.list, f.buffer, f.rtv);
                try p.frames.present(&p.d, &p.chain, f, 0);
                try p.d.waitIdle();
            },
        }
        try p.readback.read(px);
    }

    /// Clear, the scene, and a copy of the target into the read-back buffer, leaving the
    /// target in RENDER_TARGET as it found it.
    fn drawFrame(p: *Player, l: *com.GraphicsCommandList, target: *com.Resource, rtv: c.D3D12_CPU_DESCRIPTOR_HANDLE) void {
        l.omSetRenderTarget(rtv);
        l.clearRenderTargetView(rtv, .{ 0, 0, 0, 1 });
        p.drawCommands(l);
        l.resourceBarrier(&.{transition(target, c.D3D12_RESOURCE_STATE_RENDER_TARGET, c.D3D12_RESOURCE_STATE_COPY_SOURCE)});
        p.readback.copy(l, target);
        l.resourceBarrier(&.{transition(target, c.D3D12_RESOURCE_STATE_COPY_SOURCE, c.D3D12_RESOURCE_STATE_RENDER_TARGET)});
    }

    /// The host's loop: UI draws up to each custom command, the host's own pipeline there, in
    /// the same command list.
    fn drawCommands(p: *const Player, l: *com.GraphicsCommandList) void {
        const dl = &p.st.draw;
        var i = iface.drawUntilCustom(&p.gfx, l, dl, 0);
        while (i < dl.cmd_len) : (i = iface.drawUntilCustom(&p.gfx, l, dl, i + 1)) {
            p.gradient.draw(l, p.gfx.customScissor(dl.customs[dl.command(i).custom]), p.gfx.extent);
        }
    }
};

/// render.py's stand-in glyph atlas: 16x16 cells of 4x4 texels, every printable byte a 2x3
/// block of opaque white.
fn standInAtlas() [64 * 64 * 4]u8 {
    var px: [64 * 64 * 4]u8 = @splat(0);
    for (33..127) |byte| {
        const cx = byte & 15;
        const cy = byte >> 4;
        for (1..4) |y| for (1..3) |x| {
            const o = ((cy * 4 + y) * 64 + cx * 4 + x) * 4;
            px[o..][0..4].* = @splat(0xff);
        };
    }
    return px;
}

/// The golden images, embedded by build.zig (src/render/conformance/<scene>.png).
pub const goldens = [_][]const u8{ @embedFile("golden_rects"), @embedFile("golden_clip"), @embedFile("golden_text"), @embedFile("golden_custom") };

/// Pixels whose channels differ from the golden's by more than 2: tools/golden/golden.py's
/// measure, which every back end's conformance job applies with 0 allowed.
pub fn pixelsOff(got: []const u8, want: []const u8) u32 {
    var off: u32 = 0;
    for (0..got.len / 4) |i| {
        var worst: u8 = 0;
        for (0..4) |k| worst = @max(worst, @max(got[i * 4 + k], want[i * 4 + k]) - @min(got[i * 4 + k], want[i * 4 + k]));
        off += @intFromBool(worst > 2);
    }
    return off;
}

const testing = std.testing;

/// Draws every scene named in `names` with `p` and expects each to match its golden exactly.
pub fn expectGoldens(p: *Player, names: []const []const u8) !void {
    const bytes = width * height * 4;
    const px = try testing.allocator.alloc(u8, bytes);
    defer testing.allocator.free(px);
    const want = try testing.allocator.alloc(u8, bytes);
    defer testing.allocator.free(want);
    for (&conformance.scenes, goldens) |*s, png| {
        for (names) |n| {
            if (std.mem.eql(u8, n, s.name)) break;
        } else continue;
        const info = try lcgf.png.info(png);
        try testing.expectEqual(@as(usize, bytes), info.pixelBytes());
        const scratch = try testing.allocator.alloc(u8, info.scratchBytes());
        defer testing.allocator.free(scratch);
        _ = try lcgf.png.decode(png, want, scratch);
        try p.draw(s, px);
        const off = pixelsOff(px, want);
        std.debug.print("{s} {t}: {d} pixels off\n", .{ s.name, p.mode, off });
        try testing.expectEqual(@as(u32, 0), off);
    }
}

test "conformance: every scene matches its golden image, offscreen and presented" {
    try testing.expectEqual(conformance.scenes.len, goldens.len);
    for ([_]Mode{ .offscreen, .present }) |mode| {
        var p: Player = undefined;
        try p.init(mode);
        defer p.deinit();
        try expectGoldens(&p, &.{ "rects", "clip", "text", "custom" });
    }
}

test "conformance: the scenes still match after the swapchain was resized away and back" {
    var p: Player = undefined;
    try p.init(.present);
    defer p.deinit();
    try p.d.waitIdle();
    try p.chain.resize(&p.d, 64, 48);
    try testing.expectEqual(@as(u64, 64), p.chain.buffers[0].getDesc().Width);
    try testing.expectEqual(@as(u32, 48), p.chain.buffers[1].getDesc().Height);
    // A frame at the small size: the loop and the renderer take the new buffers as they come.
    const f = try p.frames.begin(&p.d, &p.chain);
    f.list.omSetRenderTarget(f.rtv);
    f.list.clearRenderTargetView(f.rtv, .{ 0, 0, 0, 1 });
    try p.frames.present(&p.d, &p.chain, f, 0);
    try p.d.waitIdle();
    try p.chain.resize(&p.d, width, height);
    try expectGoldens(&p, &.{ "rects", "clip", "text", "custom" });
}

test "conformance: everything made again on a new device, against the same window, draws the scenes" {
    var p: Player = undefined;
    try p.init(.present);
    defer p.deinit();
    try p.recover();
    try expectGoldens(&p, &.{ "rects", "clip", "text", "custom" });
}

test "conformance: after device removal the next frame fails with DeviceLost, and recovery draws the scenes" {
    var p: Player = undefined;
    try p.init(.present);
    defer p.deinit();
    try p.d.remove();
    if (p.d.removedReason() >= 0) {
        // vkd3d (Wine) implements RemoveDevice as a no-op: removal cannot be caused there.
        std.debug.print("skipped: this runtime's RemoveDevice does not remove the device\n", .{});
        return error.SkipZigTest;
    }
    var px: [width * height * 4]u8 = undefined;
    try testing.expectError(error.DeviceLost, p.draw(&conformance.scenes[0], &px));
    try p.recover();
    try expectGoldens(&p, &.{ "rects", "clip", "text", "custom" });
}

test "pixelsOff counts pixels with any channel more than 2 away" {
    try testing.expectEqual(@as(u32, 0), pixelsOff(&.{ 10, 10, 10, 255, 0, 0, 0, 0 }, &.{ 12, 8, 10, 255, 2, 0, 0, 0 }));
    try testing.expectEqual(@as(u32, 1), pixelsOff(&.{ 10, 10, 10, 255, 0, 0, 0, 0 }, &.{ 10, 10, 10, 252, 0, 0, 0, 0 }));
}
