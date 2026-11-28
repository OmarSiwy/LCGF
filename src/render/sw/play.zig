//! Draws a dumped frame with the software back end and writes it as a PNG, for comparison with
//! the GPU golden images (ci/jobs/sw-golden.sh):
//!
//!     sw-play DIR OUT.png [RRGGBB]
//!
//! DIR is what conformance-dump or draw-dump wrote (quads.bin, glyphs.bin, cmds.txt). The
//! drawing mirrors src/render/conformance/render.py and tools/golden/gpu.py: the same stand-in
//! glyph atlas as texture 1, the same host gradient for custom commands, the size from
//! cmds.txt (800x600 without a `size` line, times its `scale` line's physical pixels per
//! logical pixel, 1 without one) and the clear colour from the argument (black).
//! A `canvas` line (tools/golden/draw.zig `canvasScene`) adds one canvas node from canvas.bin,
//! verts.bin and its `camera`, `palette`, `layer`, `range` and `override` lines.
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
    var scale: f32 = 1;
    // `texture ID W H FILE`: an RGBA8 texture of its own (gpu.py binds it the same way).
    var own: ?struct { id: u32, img: sw.Image } = null;
    var first: std.ArrayList(u32) = .empty;
    var count: std.ArrayList(u32) = .empty;
    var lines = std.mem.tokenizeScalar(u8, cmds, '\n');
    while (lines.next()) |line| {
        var f = std.mem.tokenizeScalar(u8, line, ' ');
        const key = f.next().?;
        if (std.mem.eql(u8, key, "size")) {
            w = try std.fmt.parseInt(u32, f.next().?, 10);
            h = try std.fmt.parseInt(u32, f.next().?, 10);
        } else if (std.mem.eql(u8, key, "scale")) {
            scale = try std.fmt.parseFloat(f32, f.next().?);
            if (!(scale > 0)) return error.BadScale;
        } else if (std.mem.eql(u8, key, "texture")) {
            const id = try std.fmt.parseInt(u32, f.next().?, 10);
            const tw = try std.fmt.parseInt(u32, f.next().?, 10);
            const th = try std.fmt.parseInt(u32, f.next().?, 10);
            const bytes = try dir.readFileAlloc(io, f.next().?, gpa, .limited(64 << 20));
            const pixels = try gpa.alloc(u32, tw * th);
            @memcpy(std.mem.sliceAsBytes(pixels), bytes[0 .. tw * th * 4]);
            own = .{ .id = id, .img = .{ .pixels = pixels, .width = tw, .height = th } };
        } else if (std.mem.eql(u8, key, "text")) {
            try first.append(gpa, try std.fmt.parseInt(u32, f.next().?, 10));
            try count.append(gpa, try std.fmt.parseInt(u32, f.next().?, 10));
        }
    }

    w = @intFromFloat(@round(@as(f32, @floatFromInt(w)) * scale));
    h = @intFromFloat(@round(@as(f32, @floatFromInt(h)) * scale));

    // Stand-in atlas, 16x16 cells of 4x4 texels: every printable byte is a small block.
    var atlas: [64 * 64]u32 = @splat(0);
    for (33..127) |byte| for (1..4) |y| for (1..3) |x| {
        atlas[((byte >> 4) * 4 + y) * 64 + (byte & 15) * 4 + x] = 0xffff_ffff;
    };
    const atlas_tex: lcgf.types.Texture = @fromBackingInt(1);
    // The own texture is image 2; its id must be 2 too, the rows the renderer indexes by id.
    const images = [_]sw.Image{ sw.Image.white, .{ .pixels = &atlas, .width = 64, .height = 64 }, if (own) |o| o.img else sw.Image.white };
    if (own) |o| if (o.id != 2) return error.TextureIdNotTwo;
    const s: sw.Software = .{
        .quads = quads,
        .glyphs = .{ .quads = glyph_quads, .first = first.items, .count = count.items, .texture = atlas_tex },
        .images = images[0 .. @as(usize, 2) + @intFromBool(own != null)],
        .scale = scale,
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
            // Texture 0 is white, a `texture` line's id its own, any other the stand-in atlas.
            const own_id: f32 = if (own) |o| @floatFromInt(o.id) else -1;
            const tex: lcgf.types.Texture = if (v[2] == 0) .white else if (v[2] == own_id) @fromBackingInt(2) else atlas_tex;
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

    if (std.mem.indexOf(u8, cmds, "canvas ") != null) {
        // A `canvas-atlas w h file` line: the canvas glyphs' own atlas, alpha bytes (draw.zig's
        // `labels`); else the stand-in atlas.
        var canvas_atlas = s.images[1];
        var atlas_lines = std.mem.tokenizeScalar(u8, cmds, '\n');
        while (atlas_lines.next()) |line| {
            var f = std.mem.tokenizeScalar(u8, line, ' ');
            if (!std.mem.eql(u8, f.next().?, "canvas-atlas")) continue;
            const aw = try std.fmt.parseInt(u32, f.next().?, 10);
            const ah = try std.fmt.parseInt(u32, f.next().?, 10);
            const bytes = try dir.readFileAlloc(io, f.next().?, gpa, .limited(1 << 26));
            if (bytes.len != @as(usize, aw) * ah) return error.BadAtlas;
            canvas_atlas = .{ .width = aw, .height = ah, .alpha8 = bytes };
        }
        try drawCanvas(io, dir, gpa, cmds, t.fb, clear, canvas_atlas, scale);
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

/// The canvas scene through `sw.Setup.draw`, as a host draws it: three threads, a band each,
/// and the canvas binned into them (`Setup.bins`), so sw-golden covers the binned path; the
/// walk without a bin is covered by sw/canvas.zig's tests. The scene is the canvas alone, so
/// Setup's clear to `clear` loses nothing.
fn drawCanvas(io: std.Io, dir: std.Io.Dir, gpa: std.mem.Allocator, cmds: []const u8, fb: *sw.Framebuffer, clear: Color, atlas: sw.Image, scale: f32) !void {
    const canvas = lcgf.canvas;
    const DrawList = lcgf.draw_list.DrawList;
    // One command per `canvas` line; the `camera`, `range` and `override` lines after it are its.
    const Cmd = struct { node: [19]f32 = .{ 0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 0, 0, 1, 0, 0, 0, 0, 0, 0 }, cam: canvas.Camera = .{}, ranges: std.ArrayList(canvas.Range) = .empty, overrides: std.ArrayList(canvas.Override) = .empty };
    var cmd_list: std.ArrayList(Cmd) = .empty;
    var pal: canvas.Palette = .{ .layers = &.{} };
    var layers: std.ArrayList(canvas.Layer) = .empty;
    var lines = std.mem.tokenizeScalar(u8, cmds, '\n');
    while (lines.next()) |line| {
        var f = std.mem.tokenizeScalar(u8, line, ' ');
        const key = f.next().?;
        if (std.mem.eql(u8, key, "canvas")) {
            try cmd_list.append(gpa, .{});
            const c = &cmd_list.items[cmd_list.items.len - 1];
            // rect, clip, opacity, then optionally the transform and the clip's radii.
            var i: usize = 0;
            while (f.next()) |x| : (i += 1) c.node[i] = try std.fmt.parseFloat(f32, x);
        } else if (std.mem.eql(u8, key, "camera")) {
            const cam = &cmd_list.items[cmd_list.items.len - 1].cam;
            cam.origin = .{ try std.fmt.parseInt(i64, f.next().?, 10), try std.fmt.parseInt(i64, f.next().?, 10) };
            cam.scale = try std.fmt.parseFloat(f32, f.next().?);
            cam.offset = .{ try std.fmt.parseFloat(f32, f.next().?), try std.fmt.parseFloat(f32, f.next().?) };
        } else if (std.mem.eql(u8, key, "layer")) {
            try layers.append(gpa, .{
                .stroke = try std.fmt.parseInt(u32, f.next().?, 10),
                .fill = try std.fmt.parseInt(u32, f.next().?, 10),
                .width = try std.fmt.parseFloat(f32, f.next().?),
                .flags = try std.fmt.parseInt(u32, f.next().?, 10),
            });
        } else if (std.mem.eql(u8, key, "range")) {
            try cmd_list.items[cmd_list.items.len - 1].ranges.append(gpa, .{ .first = try std.fmt.parseInt(u32, f.next().?, 10), .count = try std.fmt.parseInt(u32, f.next().?, 10) });
        } else if (std.mem.eql(u8, key, "override")) {
            const first = try std.fmt.parseInt(u32, f.next().?, 10);
            const count = try std.fmt.parseInt(u32, f.next().?, 10);
            try cmd_list.items[cmd_list.items.len - 1].overrides.append(gpa, .{ .range = .{ .first = first, .count = count }, .color = try std.fmt.parseInt(u32, f.next().?, 10) });
        }
    }
    pal.layers = layers.items;
    const nc: u32 = @intCast(cmd_list.items.len);

    const rows = try dir.readFileAlloc(io, "canvas.bin", gpa, .limited(1 << 26));
    const verts = try dir.readFileAlloc(io, "verts.bin", gpa, .limited(1 << 26));
    const n: u32 = @intCast(rows.len / 32);
    const nv: u32 = @intCast(verts.len / 8);
    const A = comptime std.mem.Alignment.fromByteUnits(lcgf.mem.column_align);
    // colors.bin, when there: a colour a row.
    const colors = dir.readFileAlloc(io, "colors.bin", gpa, .limited(1 << 26)) catch &.{};
    const o: canvas.Instances.Options = .{ .colors = colors.len != 0 };
    var carver: lcgf.mem.Carver = .{ .buf = try gpa.alignedAlloc(u8, A, canvas.Instances.requiredBytes(@max(n, 1), nv, 1, o)) };
    var s = canvas.Instances.init(&carver, @max(n, 1), nv, 1, o);
    if (o.colors) @memcpy(std.mem.sliceAsBytes(s.colors[0..n]), colors[0 .. 4 * n]);
    for (0..n) |i| {
        const row = std.mem.bytesAsValue([8]u32, rows[i * 32 ..][0..32]).*;
        s.c.pos[i] = @bitCast(row[0..4].*);
        s.c.look[i] = row[4..8].*;
    }
    @memcpy(std.mem.sliceAsBytes(s.verts[0..nv]), verts[0 .. nv * 8]);
    s.len = n;
    s.vert_len = nv;

    var counter: lcgf.mem.Carver = .{ .buf = null };
    _ = DrawList.init(&counter, 1, 1, nc);
    var list_carver: lcgf.mem.Carver = .{ .buf = try gpa.alignedAlloc(u8, A, counter.off) };
    var list = DrawList.init(&list_carver, 1, 1, nc);
    const canvases = try gpa.alloc(lcgf.draw_list.CanvasDraw, nc);
    for (cmd_list.items, 0..) |c, k| {
        const nd = c.node;
        canvases[k] = .{ .instances = &s, .camera = c.cam, .ranges = c.ranges.items, .palette = &pal, .overrides = c.overrides.items };
        list.customs[k] = .{ .rect = nd[0..4].*, .clip = nd[4..8].*, .data = 0, .id = 0, .node = @intCast(k), .opacity = nd[8], .xform = nd[9..15].*, .clip_radii = nd[15..19].* };
        list.cmd.kind[k] = @backingInt(DrawList.Kind.canvas);
        list.cmd.first[k] = @intCast(k);
        list.cmd.count[k] = 1;
    }
    list.canvases = canvases;
    list.custom_len = nc;
    list.cmd_len = nc;

    var pool: sw.bands.Pool = undefined;
    try pool.init(io, 3);
    defer pool.deinit();
    const cap = @max(n, 1);
    var bin_carver: lcgf.mem.Carver = .{ .buf = try gpa.alignedAlloc(u8, A, sw.canvas.Bin.requiredBytes(cap, 2 * cap)) };
    var bins = [1]sw.canvas.Bin{.init(&bin_carver, cap, 2 * cap)};
    var setup: sw.Setup = .{ .pool = &pool, .bins = &bins };
    setup.gfx.images = &.{ sw.Image.white, atlas };
    setup.draw(fb, &list, .{ .texture = @fromBackingInt(1) }, clear, scale);
    // Every band drew from the bin.
    if (bins[0].list != &list or bins[0].bands != pool.count) return error.CanvasNotBinned;
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
