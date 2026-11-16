//! Golden-image dumper for the path scenes: draws every scene of testdata/paths/scenes.txt with
//! src/draw/paths.zig and writes the images to one file for testdata/paths/check.py, which
//! compares them with the references testdata/paths/make.py drew independently.
//!
//!   zig build paths-golden -- OUT.bin
//!
//! A tool, not part of the package: not exported from src/lcgr.zig. Each shape is rasterised,
//! placed in a coverage atlas and emitted as a quad into a draw list (paths.place, paths.emit);
//! at the end of a scene `composite` draws the list's quads in command order the way the stock
//! quad material does (fill times the atlas sample, nearest texel, premultiplied over), which is
//! the compositing make.py specifies.
const std = @import("std");
const lcgr = @import("lcgr");
const paths = lcgr.paths;

const scenes = @embedFile("testdata/paths/scenes.txt");
/// The TinyVG files scenes.txt names (testdata/paths/tvg.py writes them).
const tvg_files = [_]struct { []const u8, []const u8 }{
    .{ "icon_all", @embedFile("testdata/paths/icon_all.tvg") },
    .{ "icon_565", @embedFile("testdata/paths/icon_565.tvg") },
    .{ "icon_f32", @embedFile("testdata/paths/icon_f32.tvg") },
};
const bg = [3]f32{ 16, 16, 20 };
/// Chord tolerance in px. Chords cut inside a curve, so the error does not cancel: 1/64 px
/// moved edge pixels by up to 8 levels, 1/128 px by 5 where two curves share a pixel. A miter
/// where a curve meets a corner takes the last chord's direction, not the tangent: at 1/256 px
/// that put one tip 5 levels off. At 1/1024 px every scene matches within 3 (check.py's TOL is 4).
const tolerance = 1.0 / 1024.0;

const max_px = 128 * 128;
const atlas_side = 512;
const max_shapes = 64;
const max_points = 1 << 16;

/// A filled shape, or a stroked one when `stroke` is set (filled nonzero).
const Shape = struct { rule: paths.Rule = .nonzero, stroke: ?paths.Stroke = null, color: [4]u8 };

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    var args = try init.minimal.args.iterateAllocator(gpa);
    defer args.deinit();
    _ = args.next();
    const out_path = args.next() orelse return error.MissingOutputPath;

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);

    const bufs = try gpa.create(Buffers);
    defer gpa.destroy(bufs);
    var canvas: [max_px][3]f32 = undefined;
    const frame = try gpa.create(Frame);
    defer gpa.destroy(frame);
    frame.init();
    var acc: [max_px + 64]f32 = undefined;
    var img: [max_px + 64]u8 = undefined;

    var name: []const u8 = "";
    var w: u32 = 0;
    var h: u32 = 0;
    var shape: ?Shape = null;
    var path = bufs.path();

    var lines = std.mem.splitScalar(u8, scenes, '\n');
    while (true) {
        const line = lines.next();
        const t = std.mem.trim(u8, if (line) |l| l[0 .. std.mem.indexOfScalar(u8, l, '#') orelse l.len] else "", " \t\r");
        var tok = std.mem.tokenizeScalar(u8, t, ' ');
        const op = tok.next() orelse "";
        // A new shape, a new scene or the end draws the pending shape; a new scene or the end
        // writes the pending scene.
        const ends_shape = line == null or std.mem.eql(u8, op, "fill") or std.mem.eql(u8, op, "stroke") or std.mem.eql(u8, op, "scene");
        if (ends_shape) if (shape) |s| {
            draw(bufs, &path, s, frame, &acc, &img);
            shape = null;
        };
        if ((line == null or std.mem.eql(u8, op, "scene")) and w != 0) {
            try out.append(gpa, @intCast(name.len));
            try out.appendSlice(gpa, name);
            var hdr: [8]u8 = undefined;
            std.mem.writeInt(u32, hdr[0..4], w, .little);
            std.mem.writeInt(u32, hdr[4..8], h, .little);
            try out.appendSlice(gpa, &hdr);
            composite(frame, w, h, &canvas);
            for (canvas[0 .. w * h]) |px| {
                for (px) |c| try out.append(gpa, @intFromFloat(@round(c)));
                try out.append(gpa, 255);
            }
        }
        if (line == null) break;
        if (op.len == 0) continue;
        if (std.mem.eql(u8, op, "scene")) {
            name = tok.next().?;
            w = try std.fmt.parseInt(u32, tok.next().?, 10);
            h = try std.fmt.parseInt(u32, tok.next().?, 10);
            std.debug.assert(w * h <= max_px);
            for (canvas[0 .. w * h]) |*px| px.* = bg;
            frame.reset();
        } else if (std.mem.eql(u8, op, "fill")) {
            const rule = std.meta.stringToEnum(paths.Rule, tok.next().?) orelse return error.BadRule;
            var color: [4]u8 = undefined;
            _ = try std.fmt.hexToBytes(&color, tok.next().?);
            shape = .{ .rule = rule, .color = color };
            path.clear();
        } else if (std.mem.eql(u8, op, "tvg")) {
            const file = tok.next().?;
            const data = for (tvg_files) |f| {
                if (std.mem.eql(u8, f[0], file)) break f[1];
            } else return error.UnknownTvgFile;
            var v: [3]f32 = undefined;
            for (&v) |*x| x.* = try std.fmt.parseFloat(f32, tok.next().?);
            var image = try lcgr.tinyvg.parse(data);
            while (try image.next(v[2], v[0], v[1], &path)) |item| {
                if (item.fill) |c| draw(bufs, &path, .{ .rule = item.rule, .color = rgba(c) }, frame, &acc, &img);
                if (item.line) |c| draw(bufs, &path, .{ .stroke = item.stroke(), .color = rgba(c) }, frame, &acc, &img);
            }
            path.clear();
        } else if (std.mem.eql(u8, op, "stroke")) {
            const width = try std.fmt.parseFloat(f32, tok.next().?);
            const join = std.meta.stringToEnum(paths.Join, tok.next().?) orelse return error.BadJoin;
            const cap = std.meta.stringToEnum(paths.Cap, tok.next().?) orelse return error.BadCap;
            const limit = try std.fmt.parseFloat(f32, tok.next().?);
            var color: [4]u8 = undefined;
            _ = try std.fmt.hexToBytes(&color, tok.next().?);
            shape = .{ .stroke = .{ .width = width, .join = join, .cap = cap, .miter_limit = limit }, .color = color };
            path.clear();
        } else {
            var v: [6]f32 = undefined;
            var n: usize = 0;
            while (tok.next()) |s| : (n += 1) v[n] = try std.fmt.parseFloat(f32, s);
            switch (op[0]) {
                'M' => path.moveTo(v[0], v[1]),
                'L' => path.lineTo(v[0], v[1]),
                'Q' => path.quadTo(v[0], v[1], v[2], v[3]),
                'C' => path.cubicTo(v[0], v[1], v[2], v[3], v[4], v[5]),
                'Z' => path.close(),
                else => return error.BadVerb,
            }
        }
    }
    try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = out_path, .data = out.items });
}

/// The test columns plus a second polyline for stroke outlines.
const Buffers = struct {
    t: paths.TestBuffers(8192, max_points) = .{},
    ox: [max_points]f32 = undefined,
    oy: [max_points]f32 = undefined,
    oend: [8192]u32 = undefined,
    oclosed: [8192]bool = undefined,

    fn path(b: *Buffers) paths.Path {
        return b.t.path();
    }
    fn polyline(b: *Buffers) paths.Polyline {
        return b.t.polyline();
    }
    fn scratch(b: *Buffers) paths.Scratch {
        return b.t.scratch();
    }
    fn outline(b: *Buffers) paths.Polyline {
        return .{ .x = &b.ox, .y = &b.oy, .end = &b.oend, .closed = &b.oclosed };
    }
};

fn rgba(c: lcgr.types.Color) [4]u8 {
    return .{ c.r, c.g, c.b, c.a };
}

/// One scene's atlas and draw list.
const Frame = struct {
    pixels: [atlas_side * atlas_side]u8,
    sky: [3][atlas_side]u32,
    atlas: paths.Atlas,
    buf: [bytes]u8 align(lcgr.mem.column_align),
    list: lcgr.draw_list.DrawList,

    const texture: lcgr.types.Texture = @fromBackingInt(1);
    const bytes = blk: {
        var counter: lcgr.mem.Carver = .{ .buf = null };
        _ = lcgr.draw_list.DrawList.init(&counter, max_shapes, 0, 0);
        break :blk counter.off;
    };

    fn init(f: *Frame) void {
        f.atlas = .init(atlas_side, atlas_side, &f.pixels, .{ .x = &f.sky[0], .y = &f.sky[1], .w = &f.sky[2] });
        var carver: lcgr.mem.Carver = .{ .buf = &f.buf };
        f.list = .init(&carver, max_shapes, 0, 0);
    }

    fn reset(f: *Frame) void {
        f.atlas.clear();
        f.list.quad_len = 0;
        f.list.cmd_len = 0;
    }
};

/// Rasterises `path`, places its coverage in the atlas and emits its quad.
fn draw(bufs: *Buffers, path: *const paths.Path, s: Shape, frame: *Frame, acc: []f32, img: []u8) void {
    var l = bufs.polyline();
    std.debug.assert(paths.flattenLen(path, tolerance).points <= bufs.t.lx.len);
    paths.flatten(path, tolerance, &l);
    if (s.stroke) |st| {
        var o = bufs.outline();
        std.debug.assert(paths.strokeLen(&l, st, tolerance).points <= o.x.len);
        paths.stroke(&l, st, tolerance, &o);
        l = o;
    }
    const b = paths.bounds(&l);
    std.debug.assert(paths.accLen(b) <= acc.len);
    paths.fill(&l, b, s.rule, bufs.scratch(), acc);
    paths.coverage(acc, img, @as(usize, b.w) * b.h);
    const r = paths.place(&frame.atlas, b, img).?;
    const color: lcgr.types.Color = .rgba(s.color[0], s.color[1], s.color[2], s.color[3]);
    paths.emit(&frame.list, b, frame.atlas.uv(r), Frame.texture, color, paths.no_clip);
}

/// Draws the frame's commands into the canvas: per quad pixel, coverage v from the nearest
/// atlas texel of its uv, then c * a * v + dst * (1 - a * v).
fn composite(frame: *const Frame, w: u32, h: u32, canvas: [][3]f32) void {
    const d = &frame.list;
    const side: f32 = atlas_side;
    for (0..d.cmd_len) |ci| {
        const batch = d.command(@intCast(ci)).quads;
        std.debug.assert(batch.texture == Frame.texture);
        for (d.quads[batch.first..][0..batch.count]) |q| {
            const fill: lcgr.types.Color = @bitCast(q.fill);
            const rgb = [3]f32{ @floatFromInt(fill.r), @floatFromInt(fill.g), @floatFromInt(fill.b) };
            const alpha = @as(f32, @floatFromInt(fill.a)) / 255;
            const x0: i32 = @intFromFloat(q.rect[0]);
            const y0: i32 = @intFromFloat(q.rect[1]);
            const x1: i32 = @intFromFloat(q.rect[2]);
            const y1: i32 = @intFromFloat(q.rect[3]);
            var y = @max(y0, 0);
            while (y < @min(y1, @as(i32, @intCast(h)))) : (y += 1) {
                var x = @max(x0, 0);
                while (x < @min(x1, @as(i32, @intCast(w)))) : (x += 1) {
                    // Pixel centre to texture coordinate, nearest texel.
                    const fx = (@as(f32, @floatFromInt(x - x0)) + 0.5) / (q.rect[2] - q.rect[0]);
                    const fy = (@as(f32, @floatFromInt(y - y0)) + 0.5) / (q.rect[3] - q.rect[1]);
                    const tx: usize = @intFromFloat(@floor((q.uv[0] + fx * (q.uv[2] - q.uv[0])) * side));
                    const ty: usize = @intFromFloat(@floor((q.uv[1] + fy * (q.uv[3] - q.uv[1])) * side));
                    const a = alpha * @as(f32, @floatFromInt(frame.atlas.pixels[ty * atlas_side + tx])) / 255;
                    const px = &canvas[@as(usize, @intCast(y)) * w + @as(usize, @intCast(x))];
                    for (px, rgb) |*ch, c| ch.* = c * a + ch.* * (1 - a);
                }
            }
        }
    }
}
