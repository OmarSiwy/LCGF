//! Draws every render conformance scene (src/render/conformance.zig) with the Vulkan back end
//! and writes each as a PNG, for comparison with the golden images (ci/jobs/vk.sh):
//!
//!     vk-play OUT [offscreen|present]      ->  OUT/<scene>.png
//!
//! offscreen (default) draws into an RGBA8 image. present draws each frame into a headless
//! swapchain's image through the frame loop (frame.zig: acquire, submit, present) and copies the
//! image out just before presenting it, so the pixels are the ones the window would show.
//!
//! The host side mirrors src/render/conformance/render.py, which drew the goldens: an RGBA8
//! target cleared to black, nearest sampling, scale 1, the same stand-in glyph atlas.
const std = @import("std");
const lcgr = @import("lcgr");
const vk = @import("vk.zig");
const c = vk.c;
const host = vk.host;
const pass = vk.pass;
const conformance = lcgr.render_conformance;
const iface = lcgr.render_iface;

var st: conformance.Storage = .{};

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.arena.allocator();
    var args = try init.minimal.args.iterateAllocator(gpa);
    _ = args.next();
    const out_path = args.next() orelse return error.MissingOutputDir;
    const present = std.mem.eql(u8, args.next() orelse "offscreen", "present");
    const cwd = std.Io.Dir.cwd();
    try cwd.createDirPath(io, out_path);
    var out = try cwd.openDir(io, out_path, .{});
    defer out.close(io);

    var h: host.Host = undefined;
    var headless: vk.swapchain.Headless = undefined;
    if (present) {
        try headless.init();
        h.device = headless.device;
        h.once = try host.Once.init(&h.device);
    } else try h.init();
    defer if (present) {
        _ = h.device.fns.vkDeviceWaitIdle.?(h.device.handle);
        h.once.deinit(&h.device);
        headless.deinit();
    } else h.deinit();
    const d = &h.device;
    const sampler = try host.nearestSampler(d);
    defer d.fns.vkDestroySampler.?(d.handle, sampler, null);
    var white = try h.sampled(1, 1, &.{ 0xff, 0xff, 0xff, 0xff });
    defer d.destroyImage(&white);
    var atlas = try h.sampled(64, 64, &standInAtlas());
    defer d.destroyImage(&atlas);

    const size: c.VkExtent2D = .{ .width = 160, .height = 120 }; // every scene's
    var chain: vk.swapchain.Swapchain = if (present) try .init(&headless.instance, d, headless.surface, size, null) else undefined;
    defer if (present) chain.deinit(d);
    var frames: vk.frame.Frames = if (present) try .init(d, 2) else undefined;
    defer if (present) frames.deinit(d);
    const format = if (present) chain.format else c.VK_FORMAT_R8G8B8A8_UNORM;

    var gfx = try vk.Renderer.init(d, .{ .format = format, .frames = 2 }, white.view, sampler);
    defer gfx.deinit(d);
    const atlas_handle = try gfx.addTexture(d, atlas.view, sampler);

    for (&conformance.scenes) |*s| {
        st.load(s);
        const w: u32 = @intFromFloat(s.viewport[0]);
        const ht: u32 = @intFromFloat(s.viewport[1]);
        std.debug.assert(w == size.width and ht == size.height);
        var glyphs = st.glyphs();
        glyphs.texture = atlas_handle;
        const px = try gpa.alloc(u8, @as(usize, w) * ht * 4);

        if (present) {
            var staging = try d.createBuffer(px.len, c.VK_BUFFER_USAGE_TRANSFER_DST_BIT, true);
            defer d.destroyBuffer(&staging);
            const f = try frames.begin(d, &chain);
            gfx.prepare(f.slot, &st.draw, glyphs, s.viewport, 1);
            pass.begin(d, f.cmd, .{ .image = f.image, .view = f.view, .extent = chain.extent });
            drawScene(&gfx, f.cmd);
            pass.end(d, f.cmd, .{ .image = f.image, .layout = c.VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL });
            copyOut(d, f.cmd, f.image, chain.extent, staging.handle);
            pass.transition(d, f.cmd, f.image, c.VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL, c.VK_IMAGE_LAYOUT_PRESENT_SRC_KHR);
            _ = try frames.present(d, &chain, f);
            try frames.wait(d);
            @memcpy(px, staging.mapped);
            if (format == c.VK_FORMAT_B8G8R8A8_UNORM) {
                for (0..px.len / 4) |k| std.mem.swap(u8, &px[k * 4], &px[k * 4 + 2]);
            }
        } else {
            var target = try host.Target.init(d, w, ht, 1);
            defer target.deinit(d);
            gfx.prepare(0, &st.draw, glyphs, s.viewport, 1);
            const cmd = try h.once.begin(d);
            pass.begin(d, cmd, target.begin(.{ 0, 0, 0, 1 }));
            drawScene(&gfx, cmd);
            pass.end(d, cmd, .{ .image = target.image.handle, .layout = c.VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL });
            try h.once.submit(d);
            try h.readback(target.image.handle, target.image.extent, px);
        }
        var name: [64]u8 = undefined;
        try out.writeFile(io, .{ .sub_path = try std.fmt.bufPrint(&name, "{s}.png", .{s.name}), .data = try png(gpa, w, ht, px) });
    }
}

/// The host's loop over the scene's commands.
fn drawScene(gfx: *const vk.Renderer, cmd: c.VkCommandBuffer) void {
    var i = iface.drawUntilCustom(gfx, cmd, &st.draw, 0);
    while (i < st.draw.cmd_len) : (i = iface.drawUntilCustom(gfx, cmd, &st.draw, i + 1)) {}
}

fn copyOut(d: *const vk.device.Device, cmd: c.VkCommandBuffer, image: c.VkImage, extent: c.VkExtent2D, buffer: c.VkBuffer) void {
    d.fns.vkCmdCopyImageToBuffer.?(cmd, image, c.VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL, buffer, 1, &.{
        .imageSubresource = .{ .aspectMask = c.VK_IMAGE_ASPECT_COLOR_BIT, .layerCount = 1 },
        .imageExtent = .{ .width = extent.width, .height = extent.height, .depth = 1 },
    });
}

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

/// RGBA rows as a PNG (filter byte 0 before each row).
fn png(gpa: std.mem.Allocator, w: u32, h: u32, rgba: []const u8) ![]const u8 {
    var raw: std.ArrayList(u8) = .empty;
    for (0..h) |y| {
        try raw.append(gpa, 0);
        try raw.appendSlice(gpa, rgba[y * w * 4 ..][0 .. w * 4]);
    }
    return lcgr.png.encodeForTest(gpa, w, h, 8, .rgba, false, &.{}, raw.items);
}
