//! Draws every render conformance scene (src/render/conformance.zig) with the Vulkan back end
//! and writes each as a PNG, for comparison with the golden images (ci/jobs/vk.sh):
//!
//!     vk-play OUT      ->  OUT/<scene>.png
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
    const cwd = std.Io.Dir.cwd();
    try cwd.createDirPath(io, out_path);
    var out = try cwd.openDir(io, out_path, .{});
    defer out.close(io);

    var h: host.Host = undefined;
    try h.init();
    defer h.deinit();
    const d = &h.device;
    const sampler = try host.nearestSampler(d);
    defer d.fns.vkDestroySampler.?(d.handle, sampler, null);
    var white = try h.sampled(1, 1, &.{ 0xff, 0xff, 0xff, 0xff });
    defer d.destroyImage(&white);
    var atlas = try h.sampled(64, 64, &standInAtlas());
    defer d.destroyImage(&atlas);

    var gfx = try vk.Renderer.init(d, .{ .format = c.VK_FORMAT_R8G8B8A8_UNORM, .frames = 1 }, white.view, sampler);
    defer gfx.deinit(d);
    const atlas_handle = try gfx.addTexture(d, atlas.view, sampler);

    for (&conformance.scenes) |*s| {
        st.load(s);
        const w: u32 = @intFromFloat(s.viewport[0]);
        const ht: u32 = @intFromFloat(s.viewport[1]);
        var target = try host.Target.init(d, w, ht, 1);
        defer target.deinit(d);

        var glyphs = st.glyphs();
        glyphs.texture = atlas_handle;
        gfx.prepare(0, &st.draw, glyphs, s.viewport, 1);
        const cmd = try h.once.begin(d);
        pass.begin(d, cmd, target.begin(.{ 0, 0, 0, 1 }));
        var i = iface.drawUntilCustom(&gfx, cmd, &st.draw, 0);
        while (i < st.draw.cmd_len) : (i = iface.drawUntilCustom(&gfx, cmd, &st.draw, i + 1)) {}
        pass.end(d, cmd, .{ .image = target.image.handle, .layout = c.VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL });
        try h.once.submit(d);

        const px = try gpa.alloc(u8, @as(usize, w) * ht * 4);
        try h.readback(target.image.handle, target.image.extent, px);
        var name: [64]u8 = undefined;
        try out.writeFile(io, .{ .sub_path = try std.fmt.bufPrint(&name, "{s}.png", .{s.name}), .data = try png(gpa, w, ht, px) });
    }
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
