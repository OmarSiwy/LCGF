//! Draws a dumped frame with the software back end and writes it as a PNG, for comparison with
//! the GPU golden images (ci/jobs/sw-golden.sh):
//!
//!     sw-play DIR OUT.png [RRGGBB]
//!
//! DIR is what conformance-dump or draw-dump wrote (quads.bin, glyphs.bin, cmds.txt). The
//! drawing mirrors src/render/conformance/render.py and tools/golden/gpu.py: the same stand-in
//! glyph atlas as texture 1, the same host gradient for custom commands, the size from
//! cmds.txt (800x600 without a `size` line) and the clear colour from the argument (black).
const std = @import("std");
const lcgf = @import("lcgf");
const sw = lcgf.render_sw;
const Quad = lcgf.draw_list.Quad;
const Color = lcgf.types.Color;

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.arena.allocator();
    var args = try init.minimal.args.iterateAllocator(gpa);
    _ = args.next();
    const dir_path = args.next() orelse return error.Usage;
    const out_path = args.next() orelse return error.Usage;
    const clear: Color = if (args.next()) |hex| .hex((try std.fmt.parseInt(u32, hex, 16) << 8) | 0xff) else .black;

    const cwd = std.Io.Dir.cwd();
    var dir = try cwd.openDir(io, dir_path, .{});
    defer dir.close(io);
    const cmds = try dir.readFileAlloc(io, "cmds.txt", gpa, .limited(1 << 20));
    const quads = try readQuads(io, dir, "quads.bin", gpa);
    const glyph_quads = try readQuads(io, dir, "glyphs.bin", gpa);

    var w: u32 = 800;
    var h: u32 = 600;
    var first: std.ArrayList(u32) = .empty;
    var count: std.ArrayList(u32) = .empty;
    var lines = std.mem.tokenizeScalar(u8, cmds, '\n');
    while (lines.next()) |line| {
        var f = std.mem.tokenizeScalar(u8, line, ' ');
        const key = f.next().?;
        if (std.mem.eql(u8, key, "size")) {
            w = try std.fmt.parseInt(u32, f.next().?, 10);
            h = try std.fmt.parseInt(u32, f.next().?, 10);
        } else if (std.mem.eql(u8, key, "text")) {
            try first.append(gpa, try std.fmt.parseInt(u32, f.next().?, 10));
            try count.append(gpa, try std.fmt.parseInt(u32, f.next().?, 10));
        }
    }

    // Stand-in atlas, 16x16 cells of 4x4 texels: every printable byte is a small block.
    var atlas: [64 * 64]u32 = @splat(0);
    for (33..127) |byte| for (1..4) |y| for (1..3) |x| {
        atlas[((byte >> 4) * 4 + y) * 64 + (byte & 15) * 4 + x] = 0xffff_ffff;
    };
    const atlas_tex: lcgf.types.Texture = @fromBackingInt(1);
    const s: sw.Software = .{
        .quads = quads,
        .glyphs = .{ .quads = glyph_quads, .first = first.items, .count = count.items, .texture = atlas_tex },
        .images = &.{ sw.Image.white, .{ .pixels = &atlas, .width = 64, .height = 64 } },
    };

    const px = try gpa.alloc(u32, sw.Framebuffer.len(w, h));
    var fb = sw.Framebuffer.init(px, w, h, .rgba8);
    fb.clear(clear);
    const t: sw.Target = .{ .fb = &fb, .scissor = fb.all() };
    var run: u32 = 0;
    lines.reset();
    while (lines.next()) |line| {
        var f = std.mem.tokenizeScalar(u8, line, ' ');
        const key = f.next().?;
        var v: [5]f32 = undefined;
        for (&v) |*x| x.* = std.fmt.parseFloat(f32, f.next() orelse "0") catch 0;
        if (std.mem.eql(u8, key, "quads")) {
            // Texture 0 is white, any other the stand-in atlas.
            const tex: lcgf.types.Texture = if (v[2] == 0) .white else atlas_tex;
            s.drawBatch(t, .{ .first = @intFromFloat(v[0]), .count = @intFromFloat(v[1]), .texture = tex, .material = .solid });
        } else if (std.mem.eql(u8, key, "text")) {
            s.drawText(t, run);
            run += 1;
        } else if (std.mem.eql(u8, key, "custom")) {
            // The host's own pipeline: a gradient over the scissored rect, replacing what is there.
            const wf: f32 = @floatFromInt(w);
            const hf: f32 = @floatFromInt(h);
            for (@intFromFloat(v[1])..@intFromFloat(v[3])) |y| for (@intFromFloat(v[0])..@intFromFloat(v[2])) |x| {
                const fx = @as(f32, @floatFromInt(x)) + 0.5;
                const fy = @as(f32, @floatFromInt(y)) + 0.5;
                fb.pixels[y * fb.stride + x] = fb.pack(.rgb(unorm(fx / wf * 0.5), unorm(0.25), unorm(fy / hf * 0.6)));
            };
        }
    }

    // Tightly packed RGBA rows, then a PNG with stored (uncompressed) deflate blocks.
    var raw: std.ArrayList(u8) = .empty;
    for (0..h) |y| {
        try raw.append(gpa, 0); // filter: none
        for (0..w) |x| try raw.appendSlice(gpa, &@as([4]u8, @bitCast(fb.at(@intCast(x), @intCast(y)).bitsOf())));
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
    try cwd.writeFile(io, .{ .sub_path = out_path, .data = png.items });
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
