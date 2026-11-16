//! Draws every render conformance scene (src/render/conformance.zig) with the wgpu back end over
//! wgpu-native and writes each as a PNG, for comparison with the golden images
//! (ci/jobs/wgpu.sh):
//!
//!     wgpu-play OUT      ->  OUT/<scene>.png
//!
//! The host side mirrors src/render/conformance/render.py, which drew the goldens: an RGBA8
//! target cleared to black, nearest sampling, scale 1, the same stand-in glyph atlas.
const std = @import("std");
const lcgr = @import("lcgr");
const native = @import("native.zig");
const host = native.host;
const c = native.c;
const conformance = lcgr.render_conformance;

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

    var h = try host.Host.init();
    defer h.deinit();
    var ctx = native.Context.init(h.device);
    defer ctx.deinit();
    const sampler = host.nearestSampler(&h);
    defer c.wgpuSamplerRelease(sampler);
    var white = host.Image.init(&h, 1, 1, &.{ 0xff, 0xff, 0xff, 0xff });
    defer white.deinit();
    var gfx = native.Renderer.init(&ctx, .{ .format = c.WGPUTextureFormat_RGBA8Unorm }, white.view, sampler);
    defer gfx.deinit();

    // The goldens' stand-in glyph atlas (render.py): 16x16 cells of 4x4 texels, every printable
    // byte a 2x3 block. Packed into a coverage atlas and uploaded like a real one.
    var atlas_px: [64 * 64]u8 = undefined;
    var sky: [3][64]u32 = undefined;
    var atlas = lcgr.raster_atlas.Atlas.init(64, 64, &atlas_px, .{ .x = &sky[0], .y = &sky[1], .w = &sky[2] });
    for (33..127) |byte| atlas.put(.{ .x = @intCast((byte & 15) * 4 + 1), .y = @intCast((byte >> 4) * 4 + 1), .w = 2, .h = 3 }, &@as([6]u8, @splat(255)));
    var atlas_tex = native.glyphs.GlyphTexture.init(h.device, 64, 64);
    defer atlas_tex.deinit();
    const atlas_handle = gfx.addTexture(&ctx, atlas_tex.view, sampler);

    for (&conformance.scenes) |*s| {
        st.load(s);
        const w: u32 = @intFromFloat(s.viewport[0]);
        const ht: u32 = @intFromFloat(s.viewport[1]);
        var target = host.Target.init(&h, w, ht, c.WGPUTextureFormat_RGBA8Unorm);
        defer target.deinit();

        _ = atlas_tex.upload(h.queue, &atlas);
        var glyphs = st.glyphs();
        glyphs.texture = atlas_handle;
        gfx.prepare(h.queue, &st.draw, glyphs, s.viewport, 1);
        const encoder = c.wgpuDeviceCreateCommandEncoder(h.device, null);
        const pass = host.beginPass(encoder, target.view, .{ 0, 0, 0, 1 });
        gfx.render(pass, &st.draw);
        host.endPass(pass);
        h.submit(encoder);

        const px = try gpa.alloc(u8, @as(usize, w) * ht * 4);
        try h.readback(&target, px);
        var name: [64]u8 = undefined;
        try out.writeFile(io, .{ .sub_path = try std.fmt.bufPrint(&name, "{s}.png", .{s.name}), .data = try png(gpa, w, ht, px) });
    }
}

/// RGBA rows as a PNG with stored (uncompressed) deflate blocks.
fn png(gpa: std.mem.Allocator, w: u32, h: u32, rgba: []const u8) ![]const u8 {
    var raw: std.ArrayList(u8) = .empty;
    for (0..h) |y| {
        try raw.append(gpa, 0); // filter: none
        try raw.appendSlice(gpa, rgba[y * w * 4 ..][0 .. w * 4]);
    }
    var z: std.ArrayList(u8) = .empty;
    try z.appendSlice(gpa, &.{ 0x78, 0x01 });
    var rest = raw.items;
    while (true) {
        const n: u16 = @intCast(@min(rest.len, 0xffff));
        const last = n == rest.len;
        try z.append(gpa, @intFromBool(last));
        try z.appendSlice(gpa, &std.mem.toBytes(std.mem.nativeToLittle(u16, n)));
        try z.appendSlice(gpa, &std.mem.toBytes(std.mem.nativeToLittle(u16, ~n)));
        try z.appendSlice(gpa, rest[0..n]);
        rest = rest[n..];
        if (last) break;
    }
    try z.appendSlice(gpa, &std.mem.toBytes(std.mem.nativeToBig(u32, std.hash.Adler32.hash(raw.items))));

    var file: std.ArrayList(u8) = .empty;
    try file.appendSlice(gpa, "\x89PNG\r\n\x1a\n");
    var ihdr: [13]u8 = undefined;
    std.mem.writeInt(u32, ihdr[0..4], w, .big);
    std.mem.writeInt(u32, ihdr[4..8], h, .big);
    ihdr[8..13].* = .{ 8, 6, 0, 0, 0 };
    for ([_]struct { []const u8, []const u8 }{ .{ "IHDR", &ihdr }, .{ "IDAT", z.items }, .{ "IEND", "" } }) |chunk| {
        try file.appendSlice(gpa, &std.mem.toBytes(std.mem.nativeToBig(u32, @intCast(chunk[1].len))));
        try file.appendSlice(gpa, chunk[0]);
        try file.appendSlice(gpa, chunk[1]);
        var crc = std.hash.Crc32.init();
        crc.update(chunk[0]);
        crc.update(chunk[1]);
        try file.appendSlice(gpa, &std.mem.toBytes(std.mem.nativeToBig(u32, crc.final())));
    }
    return file.items;
}
