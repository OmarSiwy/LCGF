//! Golden-image dumper for the path scenes: draws every scene of testdata/paths/scenes.txt with
//! src/draw/paths.zig and writes the images to one file for testdata/paths/check.py, which
//! compares them with the references testdata/paths/make.py drew independently.
//!
//!   zig build paths-golden -- OUT.bin
//!
//! A tool, not part of the package: not exported from src/lcgr.zig. Shapes are composited in
//! order over an opaque background the way make.py specifies.
const std = @import("std");
const lcgr = @import("lcgr");
const paths = lcgr.paths;

const scenes = @embedFile("testdata/paths/scenes.txt");
const bg = [3]f32{ 16, 16, 20 };
/// Chord tolerance in px. Chords cut inside a curve, so the error does not cancel: 1/64 px
/// moved edge pixels by up to 8 levels, 1/128 px by 5 where two curves share a pixel; at 1/256
/// px every scene matches within 3 (check.py's TOL is 4).
const tolerance = 1.0 / 256.0;

const max_px = 128 * 128;
const max_points = 4096;

const Shape = struct { rule: paths.Rule, color: [4]u8 };

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    var args = try init.minimal.args.iterateAllocator(gpa);
    defer args.deinit();
    _ = args.next();
    const out_path = args.next() orelse return error.MissingOutputPath;

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);

    const bufs = try gpa.create(paths.TestBuffers(512, max_points));
    defer gpa.destroy(bufs);
    var canvas: [max_px][3]f32 = undefined;
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
        const ends_shape = line == null or std.mem.eql(u8, op, "fill") or std.mem.eql(u8, op, "scene");
        if (ends_shape) if (shape) |s| {
            draw(bufs, &path, s, w, h, &canvas, &acc, &img);
            shape = null;
        };
        if ((line == null or std.mem.eql(u8, op, "scene")) and w != 0) {
            try out.append(gpa, @intCast(name.len));
            try out.appendSlice(gpa, name);
            var hdr: [8]u8 = undefined;
            std.mem.writeInt(u32, hdr[0..4], w, .little);
            std.mem.writeInt(u32, hdr[4..8], h, .little);
            try out.appendSlice(gpa, &hdr);
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
        } else if (std.mem.eql(u8, op, "fill")) {
            const rule = std.meta.stringToEnum(paths.Rule, tok.next().?) orelse return error.BadRule;
            var color: [4]u8 = undefined;
            _ = try std.fmt.hexToBytes(&color, tok.next().?);
            shape = .{ .rule = rule, .color = color };
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

/// Rasterises `path` and composites it into the canvas: c * a * v + dst * (1 - a * v).
fn draw(bufs: anytype, path: *const paths.Path, s: Shape, w: u32, h: u32, canvas: [][3]f32, acc: []f32, img: []u8) void {
    var l = bufs.polyline();
    std.debug.assert(paths.flattenLen(path, tolerance).points <= bufs.lx.len);
    paths.flatten(path, tolerance, &l);
    const b = paths.bounds(&l);
    std.debug.assert(paths.accLen(b) <= acc.len);
    paths.fill(&l, b, s.rule, bufs.scratch(), acc);
    paths.coverage(acc, img, @as(usize, b.w) * b.h);
    const alpha = @as(f32, @floatFromInt(s.color[3])) / 255;
    for (0..b.h) |r| for (0..b.w) |c| {
        const x = b.x + @as(i32, @intCast(c));
        const y = b.y + @as(i32, @intCast(r));
        if (x < 0 or y < 0 or x >= w or y >= h) continue;
        const a = alpha * @as(f32, @floatFromInt(img[r * b.w + c])) / 255;
        const px = &canvas[@as(usize, @intCast(y)) * w + @as(usize, @intCast(x))];
        for (px, 0..) |*ch, k| ch.* = @as(f32, @floatFromInt(s.color[k])) * a + ch.* * (1 - a);
    };
}
