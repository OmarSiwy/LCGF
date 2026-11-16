//! Draws a dumped frame with the Gompute back end and writes it as a PNG, for comparison with the
//! GPU golden images (ci/jobs/gompute-golden.sh):
//!
//!     gompute-play DIR OUT.png [RRGGBB] [cpu|cuda]
//!
//! DIR is what conformance-dump or draw-dump wrote (quads.bin, glyphs.bin, cmds.txt), read as
//! src/render/sw/play.zig reads it: the same stand-in glyph atlas as texture 1, the same host
//! gradient for custom commands, the size from cmds.txt (800x600 without a `size` line) and the
//! clear colour from the argument (black). The frame is drawn on the CPU path, or with the
//! kernels on CUDA device 0 and read back; the time per frame (median of 15; for CUDA from the
//! clear to the GPU being done, without the read-back) goes to stdout, next to the software back
//! end's for the same frame.
const std = @import("std");
const lcgr = @import("lcgr");
const gc = @import("gompute.zig");
const Quad = lcgr.draw_list.Quad;
const Color = lcgr.types.Color;

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.arena.allocator();
    var args = try init.minimal.args.iterateAllocator(gpa);
    _ = args.next();
    const dir_path = args.next() orelse return error.Usage;
    const out_path = args.next() orelse return error.Usage;
    const clear: Color = if (args.next()) |hex| .hex((try std.fmt.parseInt(u32, hex, 16) << 8) | 0xff) else .black;
    const mode = std.meta.stringToEnum(enum { cpu, cuda }, args.next() orelse "cpu") orelse return error.Usage;

    const cwd = std.Io.Dir.cwd();
    var dir = try cwd.openDir(io, dir_path, .{});
    defer dir.close(io);
    const cmds = try dir.readFileAlloc(io, "cmds.txt", gpa, .limited(1 << 20));
    const quads = try readQuads(io, dir, "quads.bin", gpa);
    const glyph_quads = try readQuads(io, dir, "glyphs.bin", gpa);

    var w: u32 = 800;
    var h: u32 = 600;
    var lines = std.mem.tokenizeScalar(u8, cmds, '\n');
    while (lines.next()) |line| {
        var f = std.mem.tokenizeScalar(u8, line, ' ');
        if (std.mem.eql(u8, f.next().?, "size")) {
            w = try std.fmt.parseInt(u32, f.next().?, 10);
            h = try std.fmt.parseInt(u32, f.next().?, 10);
        }
    }

    // Texture 0 is white, 1 the stand-in atlas: 16x16 cells of 4x4 texels, every printable byte a block.
    var texels: [1 + 64 * 64]u32 = @splat(0);
    texels[0] = 0xffff_ffff;
    for (33..127) |byte| for (1..4) |y| for (1..3) |x| {
        texels[1 + ((byte >> 4) * 4 + y) * 64 + (byte & 15) * 4 + x] = 0xffff_ffff;
    };
    const images = [_]gc.kernels.Image{ .{ .first = 0, .width = 1, .height = 1 }, .{ .first = 1, .width = 64, .height = 64 } };

    const stride = std.mem.alignForward(u32, w, 16);
    const px = try gpa.alloc(u32, @as(usize, stride) * h);
    const t: gc.Target = .{ .px = px, .width = w, .height = h, .stride = stride };
    const cap = 64;
    const bins: gc.Bins = .{ .idx = try gpa.alloc(u32, gc.Bins.len(w, h, cap)), .count = try gpa.alloc(u32, gc.Bins.len(w, h, 1)), .cap = cap };
    var rec: gc.Recorder = .{ .quads = try gpa.alloc(Quad, quads.len + glyph_quads.len), .tex = try gpa.alloc(u32, quads.len + glyph_quads.len) };

    var dev: ?gc.Device(.cuda) = null;
    if (mode == .cuda) {
        dev = try gc.Device(.cuda).init(0, .{ .width = w, .height = h, .stride = stride, .quads = @intCast(rec.quads.len), .images = images.len, .texels = texels.len, .bin_cap = cap });
        try dev.?.setImages(&images, &texels);
    }
    defer if (dev) |*d| d.deinit();

    var total: usize = 0;
    var times: [15]u64 = undefined;
    for (&times) |*ns| {
        total = 0;
        const t0 = std.Io.Timestamp.now(io, .awake);
        if (dev) |*d| try d.clear(clear.bitsOf()) else gc.fillCpu(px, clear.bitsOf());
        rec.len = 0;
        lines.reset();
        while (lines.next()) |line| {
            var f = std.mem.tokenizeScalar(u8, line, ' ');
            const key = f.next().?;
            var v: [5]f32 = undefined;
            for (&v) |*x| x.* = std.fmt.parseFloat(f32, f.next() orelse "0") catch 0;
            if (std.mem.eql(u8, key, "quads")) {
                const first: usize = @intFromFloat(v[0]);
                const tex: lcgr.types.Texture = if (v[2] == 0) .white else @fromBackingInt(1);
                rec.append(quads[first..][0..@intFromFloat(v[1])], tex);
                total += @intFromFloat(v[1]);
            } else if (std.mem.eql(u8, key, "text")) {
                const n: usize = @intFromFloat(v[1]);
                rec.append(glyph_quads[@intFromFloat(v[0])..][0..n], @fromBackingInt(1));
                total += n;
            } else if (std.mem.eql(u8, key, "custom")) {
                if (dev) |*d| {
                    // The host draws on the CPU: read back, draw, upload.
                    try d.draw(&rec, 0, 1);
                    try d.download(px);
                } else gc.rasterCpu(t, &rec, &images, &texels, bins);
                rec.len = 0;
                // The host's own pipeline: a gradient over the scissored rect, replacing what is there.
                const wf: f32 = @floatFromInt(w);
                const hf: f32 = @floatFromInt(h);
                for (@intFromFloat(v[1])..@intFromFloat(v[3])) |y| for (@intFromFloat(v[0])..@intFromFloat(v[2])) |x| {
                    const fx = @as(f32, @floatFromInt(x)) + 0.5;
                    const fy = @as(f32, @floatFromInt(y)) + 0.5;
                    px[y * stride + x] = Color.rgb(unorm(fx / wf * 0.5), unorm(0.25), unorm(fy / hf * 0.6)).bitsOf();
                };
                if (dev) |*d| try d.upload(px);
            }
        }
        if (dev) |*d| {
            try d.draw(&rec, 0, 1);
            try d.synchronize();
        } else gc.rasterCpu(t, &rec, &images, &texels, bins);
        ns.* = @intCast(t0.durationTo(std.Io.Timestamp.now(io, .awake)).toNanoseconds());
    }
    std.mem.sort(u64, &times, {}, std.sort.asc(u64));
    if (dev) |*d| try d.download(px);
    const sw_us = try swFrameUs(io, gpa, cmds, quads, glyph_quads, texels[1..], w, h, clear);
    var buf: [256]u8 = undefined;
    var out = std.Io.File.stdout().writerStreaming(io, &buf);
    try out.interface.print("{s}: {d}x{d}, {d} quads, gompute {t} {d} us/frame, sw {d} us/frame\n", .{ dir_path, w, h, total, mode, times[times.len / 2] / 1000, sw_us });
    try out.interface.flush();

    try writePng(io, gpa, out_path, px, stride, w, h);
}

/// The software back end's median time for the same frame (custom commands skipped), drawn
/// as sw-play draws it, for comparison.
fn swFrameUs(io: std.Io, gpa: std.mem.Allocator, cmds: []const u8, quads: []const Quad, glyph_quads: []const Quad, atlas: []const u32, w: u32, h: u32, clear: Color) !u64 {
    const sw = lcgr.render_sw;
    var first: std.ArrayList(u32) = .empty;
    var count: std.ArrayList(u32) = .empty;
    var lines = std.mem.tokenizeScalar(u8, cmds, '\n');
    while (lines.next()) |line| {
        var f = std.mem.tokenizeScalar(u8, line, ' ');
        if (!std.mem.eql(u8, f.next().?, "text")) continue;
        try first.append(gpa, try std.fmt.parseInt(u32, f.next().?, 10));
        try count.append(gpa, try std.fmt.parseInt(u32, f.next().?, 10));
    }
    const atlas_tex: lcgr.types.Texture = @fromBackingInt(1);
    const s: sw.Software = .{
        .quads = quads,
        .glyphs = .{ .quads = glyph_quads, .first = first.items, .count = count.items, .texture = atlas_tex },
        .images = &.{ sw.Image.white, .{ .pixels = atlas, .width = 64, .height = 64 } },
    };
    var fb = sw.Framebuffer.init(try gpa.alloc(u32, sw.Framebuffer.len(w, h)), w, h, .rgba8);
    var times: [15]u64 = undefined;
    for (&times) |*ns| {
        const t0 = std.Io.Timestamp.now(io, .awake);
        fb.clear(clear);
        const t: sw.Target = .{ .fb = &fb, .scissor = fb.all() };
        var run: u32 = 0;
        lines.reset();
        while (lines.next()) |line| {
            var f = std.mem.tokenizeScalar(u8, line, ' ');
            const key = f.next().?;
            var v: [3]f32 = undefined;
            for (&v) |*x| x.* = std.fmt.parseFloat(f32, f.next() orelse "0") catch 0;
            if (std.mem.eql(u8, key, "quads")) {
                const tex: lcgr.types.Texture = if (v[2] == 0) .white else atlas_tex;
                s.drawBatch(t, .{ .first = @intFromFloat(v[0]), .count = @intFromFloat(v[1]), .texture = tex, .material = .solid });
            } else if (std.mem.eql(u8, key, "text")) {
                s.drawText(t, run);
                run += 1;
            }
        }
        ns.* = @intCast(t0.durationTo(std.Io.Timestamp.now(io, .awake)).toNanoseconds());
    }
    std.mem.sort(u64, &times, {}, std.sort.asc(u64));
    return times[times.len / 2] / 1000;
}

fn unorm(x: f32) u8 {
    return @intFromFloat(@round(std.math.clamp(x, 0, 1) * 255));
}

fn readQuads(io: std.Io, dir: std.Io.Dir, name: []const u8, gpa: std.mem.Allocator) ![]const Quad {
    const bytes = try dir.readFileAlloc(io, name, gpa, .limited(1 << 24));
    const out = try gpa.alloc(Quad, bytes.len / @sizeOf(Quad));
    @memcpy(std.mem.sliceAsBytes(out), bytes[0 .. out.len * @sizeOf(Quad)]);
    return out;
}

/// RGBA8 rows as a PNG with stored (uncompressed) deflate blocks, as sw-play writes them.
fn writePng(io: std.Io, gpa: std.mem.Allocator, path: []const u8, px: []const u32, stride: u32, w: u32, h: u32) !void {
    var raw: std.ArrayList(u8) = .empty;
    for (0..h) |y| {
        try raw.append(gpa, 0); // filter: none
        for (px[y * stride ..][0..w]) |p| try raw.appendSlice(gpa, &@as([4]u8, @bitCast(p)));
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

    var png: std.ArrayList(u8) = .empty;
    try png.appendSlice(gpa, "\x89PNG\r\n\x1a\n");
    var ihdr: [13]u8 = undefined;
    std.mem.writeInt(u32, ihdr[0..4], w, .big);
    std.mem.writeInt(u32, ihdr[4..8], h, .big);
    ihdr[8..13].* = .{ 8, 6, 0, 0, 0 };
    for ([_]struct { []const u8, []const u8 }{ .{ "IHDR", &ihdr }, .{ "IDAT", z.items }, .{ "IEND", "" } }) |c| {
        try png.appendSlice(gpa, &std.mem.toBytes(std.mem.nativeToBig(u32, @intCast(c[1].len))));
        try png.appendSlice(gpa, c[0]);
        try png.appendSlice(gpa, c[1]);
        var crc = std.hash.Crc32.init();
        crc.update(c[0]);
        crc.update(c[1]);
        try png.appendSlice(gpa, &std.mem.toBytes(std.mem.nativeToBig(u32, crc.final())));
    }
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = png.items });
}
