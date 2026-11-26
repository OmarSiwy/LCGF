//! The render conformance scenes (src/render/conformance.zig) drawn by the Vulkan back end, as a
//! host would: used by vk-play (PNG files for tools/golden/golden.py) and by the test below,
//! which compares every scene with its golden image in `zig build vk`.
//!
//! The host side mirrors src/render/conformance/render.py, which drew the goldens: a target
//! cleared to black, nearest sampling, scale 1, the same stand-in glyph atlas, and the custom
//! command drawn inline by the host through lcgf_render.gpu (src/render/gpu/gradient.zig).
//!
//!   offscreen  an RGBA8 image, read back after the frame.
//!   present    a headless swapchain image through the frame loop (frame.zig: acquire, submit,
//!              present), copied out just before it is presented: the pixels a window shows.
//! With `samples` above 1 the pass draws into a multisampled image resolved into the target.

const std = @import("std");
const lcgf = @import("lcgf");
const loader = @import("loader.zig");
const device_mod = @import("device.zig");
const swapchain = @import("swapchain.zig");
const frame = @import("frame.zig");
const pass = @import("pass.zig");
const host = @import("host.zig");
const gpu = @import("gpu.zig");
const Gradient = lcgf.gpu_gradient.Gradient(gpu, @import("gpu_shaders").gradient);
const Renderer = @import("renderer.zig").Renderer;
const c = loader.c;
const conformance = lcgf.render_conformance;
const iface = lcgf.render_iface;

pub const Mode = enum { offscreen, present };

/// Every scene's size.
pub const size: c.VkExtent2D = .{ .width = 160, .height = 120 };

pub const Player = struct {
    mode: Mode,
    samples: u32,
    h: host.Host,
    headless: swapchain.Headless,
    sampler: c.VkSampler,
    white: device_mod.Image,
    atlas: device_mod.Image,
    chain: swapchain.Swapchain,
    frames: frame.Frames,
    /// The multisampled image a presented frame draws into before resolving.
    msaa: ?device_mod.Image,
    format: c.VkFormat,
    gfx: Renderer,
    // The custom command's draw, written once against lcgf_render.gpu (src/render/gpu/gradient.zig).
    arena: gpu.Arena,
    gradient: Gradient,
    atlas_handle: lcgf.types.Texture,
    st: conformance.Storage,

    /// Fills `p` in place (the renderer keeps a pointer to its device).
    pub fn init(p: *Player, mode: Mode, samples: u32) !void {
        p.mode = mode;
        p.samples = samples;
        p.msaa = null;
        p.st = .{};
        if (mode == .present) {
            try p.headless.init();
            p.h.device = p.headless.device;
            p.h.once = try host.Once.init(&p.h.device);
        } else try p.h.init();
        const d = &p.h.device;
        p.sampler = try host.nearestSampler(d);
        p.white = try p.h.sampled(1, 1, &.{ 0xff, 0xff, 0xff, 0xff });
        p.atlas = try p.h.sampled(64, 64, &standInAtlas());
        p.format = c.VK_FORMAT_R8G8B8A8_UNORM;
        if (mode == .present) {
            p.chain = try .init(&p.headless.instance, d, p.headless.surface, size, null);
            p.frames = try .init(d, 2);
            p.format = p.chain.format;
            if (samples > 1) p.msaa = try d.createImage(.{
                .width = size.width,
                .height = size.height,
                .format = p.format,
                .usage = c.VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT | c.VK_IMAGE_USAGE_TRANSIENT_ATTACHMENT_BIT,
                .samples = samples,
            });
        }
        p.gfx = try Renderer.init(d, .{ .format = p.format, .samples = samples, .frames = 2 }, p.white.view, p.sampler);
        p.atlas_handle = try p.gfx.addTexture(d, p.atlas.view, p.sampler);
        const dev: gpu.Device = .wrap(d);
        p.arena = try .init(dev, .{ .bytes = 64 * 1024, .bind_groups = 4 });
        p.gradient = try .init(dev, &p.arena, .{ .format = gpu.fromVkFormat(p.format), .samples = samples });
    }

    pub fn deinit(p: *Player) void {
        const d = &p.h.device;
        _ = d.fns.vkDeviceWaitIdle.?(d.handle);
        p.gradient.deinit(.wrap(d));
        p.arena.deinit();
        p.gfx.deinit(d);
        if (p.mode == .present) {
            if (p.msaa) |*m| d.destroyImage(m);
            p.frames.deinit(d);
            p.chain.deinit(d);
        }
        d.destroyImage(&p.atlas);
        d.destroyImage(&p.white);
        d.fns.vkDestroySampler.?(d.handle, p.sampler, null);
        if (p.mode == .present) {
            p.h.once.deinit(d);
            p.headless.deinit();
        } else p.h.deinit();
    }

    /// Draws `s` and writes its pixels into `px` as RGBA rows (`size` pixels).
    pub fn draw(p: *Player, s: *const conformance.Scene, px: []u8) !void {
        const d = &p.h.device;
        std.debug.assert(s.viewport[0] == size.width and s.viewport[1] == size.height);
        std.debug.assert(px.len == @as(usize, size.width) * size.height * 4);
        p.st.load(s);
        var glyphs = p.st.glyphs();
        glyphs.texture = p.atlas_handle;
        switch (p.mode) {
            .offscreen => {
                var target = try host.Target.init(d, size.width, size.height, p.samples);
                defer target.deinit(d);
                p.gfx.prepare(0, &p.st.draw, glyphs, s.viewport, 1);
                const cmd = try p.h.once.begin(d);
                p.upload(cmd);
                pass.begin(d, cmd, target.begin(.{ 0, 0, 0, 1 }));
                p.drawCommands(cmd);
                pass.end(d, cmd, .{ .image = target.image.handle, .layout = c.VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL });
                try p.h.once.submit(d);
                try p.h.readback(target.image.handle, target.image.extent, px);
            },
            .present => {
                var staging = try d.createBuffer(px.len, c.VK_BUFFER_USAGE_TRANSFER_DST_BIT, true);
                defer d.destroyBuffer(&staging);
                const f = try p.frames.begin(d, &p.chain);
                p.gfx.prepare(f.slot, &p.st.draw, glyphs, s.viewport, 1);
                p.upload(f.cmd);
                pass.begin(d, f.cmd, if (p.msaa) |m|
                    .{ .image = m.handle, .view = m.view, .extent = p.chain.extent, .resolve = .{ .image = f.image, .view = f.view } }
                else
                    .{ .image = f.image, .view = f.view, .extent = p.chain.extent });
                p.drawCommands(f.cmd);
                pass.end(d, f.cmd, .{ .image = f.image, .layout = c.VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL });
                d.fns.vkCmdCopyImageToBuffer.?(f.cmd, f.image, c.VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL, staging.handle, 1, &.{
                    .imageSubresource = .{ .aspectMask = c.VK_IMAGE_ASPECT_COLOR_BIT, .layerCount = 1 },
                    .imageExtent = .{ .width = size.width, .height = size.height, .depth = 1 },
                });
                pass.transition(d, f.cmd, f.image, c.VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL, c.VK_IMAGE_LAYOUT_PRESENT_SRC_KHR);
                _ = try p.frames.present(d, &p.chain, f);
                try p.frames.wait(d);
                @memcpy(px, staging.mapped);
                if (p.format == c.VK_FORMAT_B8G8R8A8_UNORM) {
                    for (0..px.len / 4) |k| std.mem.swap(u8, &px[k * 4], &px[k * 4 + 2]);
                }
            },
        }
    }

    /// The host's loop: UI draws up to each custom command, the host's own pipeline there, in
    /// the same command buffer.
    /// The frame's upload phase: the gradient's target size, before the pass begins.
    fn upload(p: *const Player, cmd: c.VkCommandBuffer) void {
        var up: gpu.Upload = .begin(.wrap(&p.h.device), cmd);
        p.gradient.upload(&up, p.gfx.extent.width, p.gfx.extent.height);
        _ = up.finish();
    }

    fn drawCommands(p: *const Player, cmd: c.VkCommandBuffer) void {
        const dl = &p.st.draw;
        const w = p.gfx.extent.width;
        const h = p.gfx.extent.height;
        // The UI's own pass, seen through the projection for the custom draws.
        var gp: gpu.RenderPass = .wrap(.wrap(&p.h.device), cmd, w, h);
        var i = iface.drawUntilCustom(&p.gfx, cmd, dl, 0);
        while (i < dl.cmd_len) : (i = iface.drawUntilCustom(&p.gfx, cmd, dl, i + 1)) {
            const k = dl.customs[dl.command(i).custom];
            p.gradient.draw(&gp, gpu.scissor(k.rect, k.clip, p.gfx.scale, w, h), w, h);
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
const goldens = [_][]const u8{ @embedFile("golden_rects"), @embedFile("golden_clip"), @embedFile("golden_text"), @embedFile("golden_custom") };

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

/// `pixelsOff` at 4x: the pixels just above and left of a custom draw's scissor may also be a
/// blend of the golden and the draw's colour just inside it. Mesa lavapipe (seen with LLVM 20)
/// tests multisampled fragments against the scissor's top and left edges half a pixel early, so
/// the two samples of the row and column outside it whose positions lie past the pixel centre
/// pass: those pixels come out 50% covered (25% at the corner), and nothing else changes. The
/// scissor itself is the same at 1x and 4x (the projection's `scissor`, which 1x checks exactly).
pub fn pixelsOffMultisampled(got: []const u8, want: []const u8, customs: []const lcgf.draw_list.CustomDraw) u32 {
    var off = pixelsOff(got, want);
    const w: usize = size.width;
    for (customs) |k| {
        const x0: usize = @intFromFloat(k.rect[0]);
        const y0: usize = @intFromFloat(k.rect[1]);
        const x1: usize = @intFromFloat(k.rect[2]);
        const y1: usize = @intFromFloat(k.rect[3]);
        if (x0 == 0 or y0 == 0) continue;
        // The row above (with the corner) and the column left of the scissor, each with the
        // pixel just inside that it may be blended with.
        var ring: [2][2]usize = undefined;
        for (x0 - 1..x1) |x| {
            ring = .{ .{ x, y0 - 1 }, .{ @max(x, x0), y0 } };
            off -= @intFromBool(blended(got, want, ring, w));
        }
        for (y0..y1) |y| {
            ring = .{ .{ x0 - 1, y }, .{ x0, y } };
            off -= @intFromBool(blended(got, want, ring, w));
        }
    }
    return off;
}

/// Whether the pixel at `p[0]` is off the golden but between it and the pixel at `p[1]`, on
/// every channel (2 of slack, as `pixelsOff`).
fn blended(got: []const u8, want: []const u8, p: [2][2]usize, w: usize) bool {
    const a = (p[0][1] * w + p[0][0]) * 4;
    const b = (p[1][1] * w + p[1][0]) * 4;
    var off = false;
    for (0..4) |k| {
        const g: i32 = got[a + k];
        const lo: i32 = @min(want[a + k], got[b + k]);
        const hi: i32 = @max(want[a + k], got[b + k]);
        if (g < lo - 2 or g > hi + 2) return false;
        off = off or @abs(g - @as(i32, want[a + k])) > 2;
    }
    return off;
}

const testing = std.testing;

test "conformance: every scene matches its golden image, offscreen and presented, 1x and 4x" {
    try testing.expectEqual(conformance.scenes.len, goldens.len);
    const bytes = @as(usize, size.width) * size.height * 4;
    const px = try testing.allocator.alloc(u8, bytes);
    defer testing.allocator.free(px);
    const want = try testing.allocator.alloc(u8, bytes);
    defer testing.allocator.free(want);
    for ([_]Mode{ .offscreen, .present }) |mode| for ([_]u32{ 1, 4 }) |samples| {
        var p: Player = undefined;
        try p.init(mode, samples);
        defer p.deinit();
        for (&conformance.scenes, goldens) |*s, png| {
            const info = try lcgf.png.info(png);
            try testing.expectEqual(bytes, info.pixelBytes());
            const scratch = try testing.allocator.alloc(u8, info.scratchBytes());
            defer testing.allocator.free(scratch);
            _ = try lcgf.png.decode(png, want, scratch);
            try p.draw(s, px);
            const off = if (samples > 1) pixelsOffMultisampled(px, want, s.customs) else pixelsOff(px, want);
            if (off != 0) std.debug.print("{s} {t} x{d}: {d} pixels off\n", .{ s.name, mode, samples, off });
            try testing.expectEqual(@as(u32, 0), off);
        }
    };
}

test "conformance: 4x multisampling resolves, changing only edges that cut pixels" {
    // A quad whose edges fall between pixel centres: at 1x the pixels whose centre lies outside
    // it are never shaded; at 4x some of their samples are covered, so they get partial colour.
    const q: lcgf.draw_list.Quad = .{
        .rect = .{ 10.25, 10.25, 20.75, 20.75 },
        .clip = .{ -1e6, -1e6, 1e6, 1e6 },
        .params = .{ 0, 0, 0, 0 },
        .uv = .{ 0, 0, 1, 1 },
        .fill = lcgf.types.Color.white.bitsOf(),
        .border_color = lcgf.types.Color.transparent.bitsOf(),
        .radii = @splat(0),
        .opacity = 1,
        .border = 0,
    };
    const scene: conformance.Scene = .{
        .name = "edge",
        .viewport = .{ 160, 120 },
        .quads = &.{q},
        .cmds = &.{.{ .quads = .{ .first = 0, .count = 1, .texture = .white, .material = .solid } }},
        .draws = &.{},
    };
    const bytes = @as(usize, size.width) * size.height * 4;
    var px: [2][]u8 = undefined;
    for (&px, [_]u32{ 1, 4 }) |*out, samples| {
        out.* = try testing.allocator.alloc(u8, bytes);
        var p: Player = undefined;
        try p.init(.offscreen, samples);
        defer p.deinit();
        try p.draw(&scene, out.*);
    }
    defer for (px) |b| testing.allocator.free(b);
    const at = struct {
        fn f(b: []const u8, x: usize, y: usize) u8 {
            return b[(y * size.width + x) * 4];
        }
    }.f;
    try testing.expectEqual(at(px[0], 15, 15), at(px[1], 15, 15)); // inside: the same
    try testing.expectEqual(at(px[0], 40, 40), at(px[1], 40, 40)); // outside: the same
    var edge_differs = false;
    for (9..23) |x| edge_differs = edge_differs or at(px[0], x, 20) != at(px[1], x, 20) or at(px[0], 20, x) != at(px[1], 20, x);
    try testing.expect(edge_differs);
}

test "pixelsOffMultisampled forgives only blends just outside a scissor's top and left" {
    const n = @as(usize, size.width) * size.height * 4;
    const want = try testing.allocator.alloc(u8, n);
    defer testing.allocator.free(want);
    const got = try testing.allocator.alloc(u8, n);
    defer testing.allocator.free(got);
    @memset(want, 30);
    @memcpy(got, want);
    const k: lcgf.draw_list.CustomDraw = .{ .rect = .{ 8, 8, 20, 20 }, .clip = .{ -1e6, -1e6, 1e6, 1e6 }, .data = 0, .id = 1, .node = 0 };
    const at = struct {
        fn f(b: []u8, x: usize, y: usize) *[4]u8 {
            return b[(y * size.width + x) * 4 ..][0..4];
        }
    }.f;
    at(got, 10, 8).* = .{ 200, 200, 200, 200 }; // inside, as the draw would make it
    at(want, 10, 8).* = .{ 200, 200, 200, 200 };
    at(got, 10, 7).* = .{ 115, 115, 115, 115 }; // half covered, above the top edge
    try testing.expectEqual(@as(u32, 0), pixelsOffMultisampled(got, want, &.{k}));
    at(got, 10, 7).* = .{ 250, 115, 115, 115 }; // not a blend
    try testing.expectEqual(@as(u32, 1), pixelsOffMultisampled(got, want, &.{k}));
    at(got, 10, 7).* = .{ 115, 115, 115, 115 };
    at(got, 10, 20).* = .{ 115, 115, 115, 115 }; // below the bottom edge: never forgiven
    try testing.expectEqual(@as(u32, 1), pixelsOffMultisampled(got, want, &.{k}));
}

test "pixelsOff counts pixels with any channel more than 2 away" {
    try testing.expectEqual(@as(u32, 0), pixelsOff(&.{ 10, 10, 10, 255, 0, 0, 0, 0 }, &.{ 12, 8, 10, 255, 2, 0, 0, 0 }));
    try testing.expectEqual(@as(u32, 1), pixelsOff(&.{ 10, 10, 10, 255, 0, 0, 0, 0 }, &.{ 10, 10, 10, 252, 0, 0, 0, 0 }));
}
