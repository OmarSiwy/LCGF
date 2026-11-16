//! TinyVG decoding: a .tvg file's draw commands as paths for src/draw/paths.zig. Tier 0: the
//! file is a byte slice the caller owns, each command is decoded into the caller's `Path`, and
//! the caller loops (`Image.next`) and draws each one (flatten, stroke, fill, place, emit).
//!
//! Format: the TinyVG specification 1.0 (tinyvg.tech). Behaviour the specification leaves open
//! follows the reference SDK's renderer (github.com/TinyVG/sdk, src/lib/rendering.zig), which
//! is what DVUI draws its icons with: arcs are placed as it places them, and an ellipse arc goes
//! through the same transform to a circle and back.
//!
//! What the paths carry from the specification: fills are even-odd ("fill polygon", "fill
//! path"); rectangles drawn first to last are their union; lines have round caps and joins (a
//! Minkowski sum with a disc) and are at least one pixel wide. Not carried: gradients draw in
//! their first colour (`Item.gradient` says so; the quad material has no gradient yet), a line
//! width change inside a path (the command's width is used throughout), and text hints, which
//! must not change the picture and are skipped.

const std = @import("std");
const paths = @import("paths.zig");
const types = @import("../core/types.zig");
const Path = paths.Path;
const Color = types.Color;
const Verb = paths.Verb;

pub const Error = error{
    /// Not a TinyVG file: wrong magic.
    BadMagic,
    /// A version other than 1.
    BadVersion,
    /// The custom colour encoding, which the specification leaves undefined.
    UnsupportedColors,
    /// The data ends inside a value.
    Truncated,
    /// An unknown command, path instruction or style kind, or a count the format forbids.
    BadData,
    /// A colour index past the colour table.
    BadColor,
    /// The caller's path has no room for the command.
    NoSpace,
};

/// A parsed header and colour table over the file's bytes; `next` decodes the commands.
pub const Image = struct {
    data: []const u8,
    /// Size in display units (1/96 inch).
    width: u32,
    height: u32,
    /// Fraction bits of a unit.
    scale_bits: u4,
    /// Bytes of a unit: 1, 2 or 4.
    unit_bytes: u3,
    color_encoding: u2,
    color_count: u32,
    /// Offset of the colour table.
    colors: usize,
    /// Offset of the next command; `next` advances it.
    at: usize,

    /// The colour at `index` of the colour table, as 8-bit sRGB with straight alpha.
    pub fn color(img: *const Image, index: u32) Error!Color {
        if (index >= img.color_count) return error.BadColor;
        const at = img.colors + @as(usize, index) * colorBytes(img.color_encoding);
        const c = img.data[at..];
        return switch (img.color_encoding) {
            0 => .rgba(c[0], c[1], c[2], c[3]),
            1 => blk: {
                const v = std.mem.readInt(u16, c[0..2], .little);
                break :blk .rgb(expand(5, v & 31), expand(6, (v >> 5) & 63), expand(5, v >> 11));
            },
            2 => .rgba(unitByte(c[0..4]), unitByte(c[4..8]), unitByte(c[8..12]), unitByte(c[12..16])),
            3 => unreachable, // rejected by `parse`
        };
    }

    /// Decodes the next draw command into `path` (cleared first), its coordinates mapped to
    /// `x * scale + ox`, `y * scale + oy` px. Null at the end of the document.
    pub fn next(img: *Image, scale: f32, ox: f32, oy: f32, path: *Path) Error!?Item {
        var r: Reader = .{ .img = img, .at = img.at, .scale = scale, .ox = ox, .oy = oy };
        path.clear();
        const head = try r.byte();
        const index: u6 = @truncate(head);
        const kind: u2 = @intCast(head >> 6);
        var item: Item = .{};
        switch (index) {
            0 => return null,
            1, 2, 3 => {
                const n = try r.varCount();
                item.fill = try r.style(kind, &item.gradient);
                item.rule = if (index == 2) .nonzero else .even_odd;
                try r.shape(index, n, path);
            },
            4, 5, 6, 7 => {
                const n = try r.varCount();
                item.line = try r.style(kind, &item.gradient);
                item.width = try r.width();
                try r.lines(index, n, path);
            },
            8, 9, 10 => {
                const b = try r.byte();
                const n = @as(u32, b & 63) + 1;
                item.fill = try r.style(kind, &item.gradient);
                item.line = try r.style(@intCast(b >> 6), &item.gradient);
                item.width = try r.width();
                item.rule = if (index == 9) .nonzero else .even_odd;
                try r.shape(index - 7, n, path);
            },
            11 => {
                // Text hint: center, rotation, height, text, glyph offsets. Skipped.
                for (0..4) |_| _ = try r.unit();
                r.at = try r.skip(try r.varUint());
                const glyphs = try r.varUint();
                r.at = try r.skip(@as(usize, glyphs) * 2 * img.unit_bytes);
            },
            else => return error.BadData,
        }
        img.at = r.at;
        return item;
    }
};

/// What to draw with a decoded path: fill it under `rule` in `fill`, then stroke it with round
/// joins and caps at `width` px in `line`. Either colour may be absent; a text hint has neither.
pub const Item = struct {
    fill: ?Color = null,
    line: ?Color = null,
    rule: paths.Rule = .even_odd,
    /// Line width in px, at least 1.
    width: f32 = 1,
    /// A style was a gradient, drawn in its first colour.
    gradient: bool = false,

    /// The stroke style for `line`: TinyVG lines have round caps and joins.
    pub fn stroke(it: Item) paths.Stroke {
        return .{ .width = it.width, .join = .round, .cap = .round };
    }
};

/// Parses the header and colour table of `data`.
pub fn parse(data: []const u8) Error!Image {
    if (data.len < 4) return error.Truncated;
    if (data[0] != 0x72 or data[1] != 0x56) return error.BadMagic;
    if (data[2] != 1) return error.BadVersion;
    const b = data[3];
    const range: u2 = @intCast(b >> 6);
    const unit_bytes: u3 = switch (range) {
        0 => 2,
        1 => 1,
        2 => 4,
        3 => return error.BadData,
    };
    var img: Image = .{
        .data = data,
        .width = 0,
        .height = 0,
        .scale_bits = @truncate(b),
        .unit_bytes = unit_bytes,
        .color_encoding = @truncate(b >> 4),
        .color_count = 0,
        .colors = 0,
        .at = 4,
    };
    if (img.color_encoding == 3) return error.UnsupportedColors;
    var r: Reader = .{ .img = &img, .at = 4 };
    img.width = try r.uint(unit_bytes);
    img.height = try r.uint(unit_bytes);
    img.color_count = try r.varUint();
    img.colors = r.at;
    r.at = try r.skip(@as(usize, img.color_count) * colorBytes(img.color_encoding));
    img.at = r.at;
    return img;
}

fn colorBytes(encoding: u2) usize {
    const sizes = [4]usize{ 4, 2, 16, 0 };
    return sizes[encoding];
}

/// An n-bit channel to 8 bits, rounded.
fn expand(comptime bits: u4, v: u16) u8 {
    const max = (1 << bits) - 1;
    return @intCast((@as(u32, v) * 255 + max / 2) / max);
}

/// A 0..1 float channel to a byte, clamped and rounded. scRGB values outside 0..1 clamp.
fn unitByte(b: *const [4]u8) u8 {
    const v: f32 = @bitCast(std.mem.readInt(u32, b, .little));
    return @intFromFloat(@round(std.math.clamp(if (std.math.isNan(v)) 0 else v, 0, 1) * 255));
}

const Reader = struct {
    img: *const Image,
    at: usize,
    scale: f32 = 1,
    ox: f32 = 0,
    oy: f32 = 0,

    fn skip(r: *Reader, n: usize) Error!usize {
        if (n > r.img.data.len - r.at) return error.Truncated;
        return r.at + n;
    }

    fn byte(r: *Reader) Error!u8 {
        if (r.at >= r.img.data.len) return error.Truncated;
        r.at += 1;
        return r.img.data[r.at - 1];
    }

    fn uint(r: *Reader, n: u3) Error!u32 {
        var v: u32 = 0;
        for (0..n) |k| v |= @as(u32, try r.byte()) << @intCast(8 * k);
        return v;
    }

    /// VarUInt: 7 bits per byte, low first, at most 5 bytes and 32 bits.
    fn varUint(r: *Reader) Error!u32 {
        var v: u64 = 0;
        for (0..5) |k| {
            const b = try r.byte();
            v |= @as(u64, b & 0x7f) << @intCast(7 * k);
            if (b & 0x80 == 0) {
                if (v > std.math.maxInt(u32)) return error.BadData;
                return @intCast(v);
            }
        }
        return error.BadData;
    }

    /// A count stored minus one.
    fn varCount(r: *Reader) Error!u32 {
        const v = try r.varUint();
        if (v == std.math.maxInt(u32)) return error.BadData;
        return v + 1;
    }

    /// A unit: a signed integer of the file's width over 2^scale_bits.
    fn unit(r: *Reader) Error!f32 {
        const n = r.img.unit_bytes;
        const raw = try r.uint(n);
        const v: i32 = switch (n) {
            1 => @as(i8, @bitCast(@as(u8, @intCast(raw)))),
            2 => @as(i16, @bitCast(@as(u16, @intCast(raw)))),
            else => @bitCast(raw),
        };
        return @as(f32, @floatFromInt(v)) / @as(f32, @floatFromInt(@as(u32, 1) << @as(u5, r.img.scale_bits)));
    }

    fn point(r: *Reader) Error![2]f32 {
        const x = try r.unit();
        const y = try r.unit();
        return .{ x * r.scale + r.ox, y * r.scale + r.oy };
    }

    fn width(r: *Reader) Error!f32 {
        return @max(try r.unit() * r.scale, 1);
    }

    fn style(r: *Reader, kind: u2, gradient: *bool) Error!Color {
        switch (kind) {
            0 => return r.img.color(try r.varUint()),
            1, 2 => {
                // Gradient: two points, two colours. Drawn in the first colour.
                _ = try r.point();
                _ = try r.point();
                const c0 = try r.img.color(try r.varUint());
                _ = try r.img.color(try r.varUint());
                gradient.* = true;
                return c0;
            },
            3 => return error.BadData,
        }
    }

    /// Fill commands 1 (polygon), 2 (rectangles), 3 (path) with `n` elements.
    fn shape(r: *Reader, index: u6, n: u32, path: *Path) Error!void {
        switch (index) {
            1 => {
                if (n < 2) return error.BadData;
                for (0..n) |k| {
                    const p = try r.point();
                    try room(path, 1, 1);
                    if (k == 0) path.moveTo(p[0], p[1]) else path.lineTo(p[0], p[1]);
                }
                try room(path, 1, 0);
                path.close();
            },
            2 => for (0..n) |_| {
                // Every rectangle wound the same way, so the nonzero rule makes the union.
                const p = try r.point();
                const w = try r.unit() * r.scale;
                const h = try r.unit() * r.scale;
                try room(path, 5, 4);
                path.moveTo(p[0], p[1]);
                path.lineTo(p[0] + w, p[1]);
                path.lineTo(p[0] + w, p[1] + h);
                path.lineTo(p[0], p[1] + h);
                path.close();
            },
            3 => try r.pathData(n, path),
            else => unreachable,
        }
    }

    /// Line commands 4 (lines), 5 (loop), 6 (strip), 7 (path) with `n` elements.
    fn lines(r: *Reader, index: u6, n: u32, path: *Path) Error!void {
        switch (index) {
            4 => for (0..n) |_| {
                const a = try r.point();
                const b = try r.point();
                try room(path, 2, 2);
                path.moveTo(a[0], a[1]);
                path.lineTo(b[0], b[1]);
            },
            5, 6 => {
                for (0..n) |k| {
                    const p = try r.point();
                    try room(path, 1, 1);
                    if (k == 0) path.moveTo(p[0], p[1]) else path.lineTo(p[0], p[1]);
                }
                if (index == 5) {
                    try room(path, 1, 0);
                    path.close();
                }
            },
            7 => try r.pathData(n, path),
            else => unreachable,
        }
    }

    /// A TinyVG path of `n` segments: all segment lengths first, then per segment its start
    /// point and instructions.
    fn pathData(r: *Reader, n: u32, path: *Path) Error!void {
        // The lengths are read again below from where they start, so none is stored.
        const lengths = r.at;
        for (0..n) |_| _ = try r.varCount();
        var lr: Reader = .{ .img = r.img, .at = lengths };
        for (0..n) |_| {
            const len = try lr.varCount();
            const start = try r.point();
            try room(path, 1, 1);
            path.moveTo(start[0], start[1]);
            var cur = start;
            for (0..len) |_| {
                const tag = try r.byte();
                if (tag & 0x10 != 0) _ = try r.unit(); // a line width change: not carried
                switch (tag & 7) {
                    0 => {
                        cur = try r.point();
                        try room(path, 1, 1);
                        path.lineTo(cur[0], cur[1]);
                    },
                    1 => {
                        cur[0] = try r.unit() * r.scale + r.ox;
                        try room(path, 1, 1);
                        path.lineTo(cur[0], cur[1]);
                    },
                    2 => {
                        cur[1] = try r.unit() * r.scale + r.oy;
                        try room(path, 1, 1);
                        path.lineTo(cur[0], cur[1]);
                    },
                    3 => {
                        const c0 = try r.point();
                        const c1 = try r.point();
                        cur = try r.point();
                        try room(path, 1, 3);
                        path.cubicTo(c0[0], c0[1], c1[0], c1[1], cur[0], cur[1]);
                    },
                    4, 5 => {
                        const ellipse = tag & 7 == 5;
                        const flags = try r.byte();
                        const rx = try r.unit() * r.scale;
                        const ry = if (ellipse) try r.unit() * r.scale else rx;
                        const rotation = if (ellipse) try r.unit() else 0;
                        const to = try r.point();
                        try arc(path, cur, to, rx, ry, rotation, flags & 1 != 0, flags & 2 != 0);
                        cur = to;
                    },
                    6 => {
                        try room(path, 1, 0);
                        path.close();
                        cur = start;
                    },
                    7 => {
                        const c = try r.point();
                        cur = try r.point();
                        try room(path, 1, 2);
                        path.quadTo(c[0], c[1], cur[0], cur[1]);
                    },
                    else => unreachable,
                }
            }
        }
    }
};

/// Fails unless `path` has room for `verbs` more verbs and `points` more points.
fn room(path: *const Path, verbs: usize, points: usize) Error!void {
    if (path.verbs + verbs > path.verb.len or path.points + points > path.x.len) return error.NoSpace;
}

/// An arc from `p0` to `p1` as cubics of at most a quarter turn, placed as the reference SDK
/// places it (`renderEllipse`, `renderCircle`): an ellipse is mapped to a circle (rotate by
/// -rotation, scale y by rx / ry, shrink by the up-scale that makes the radii fit) and back.
fn arc(path: *Path, p0: [2]f32, p1: [2]f32, rx: f32, ry: f32, rotation: f32, large: bool, turn_left: bool) Error!void {
    // The SDK skips arcs to (almost) the same point.
    if (@abs(p0[0] - p1[0]) < 1e-5 and @abs(p0[1] - p1[1]) < 1e-5) return;
    const radius_min = std.math.hypot(p1[0] - p0[0], p1[1] - p0[1]) / 2;
    const radius_lim = std.math.hypot(rx, ry);
    const up = if (radius_lim < radius_min) radius_min / radius_lim else 1;
    const ratio = if (ry != 0) rx / ry else 1;
    const ang = std.math.degreesToRadians(-rotation);
    const rot = [2][2]f32{ .{ @cos(ang), -@sin(ang) }, .{ @sin(ang), @cos(ang) } };
    const to = [2][2]f32{
        .{ rot[0][0] / up, rot[0][1] / up },
        .{ rot[1][0] / up * ratio, rot[1][1] / up * ratio },
    };
    const back = [2][2]f32{
        .{ rot[1][1] * up, -rot[0][1] / ratio * up },
        .{ -rot[1][0] * up, rot[0][0] / ratio * up },
    };
    const q0 = apply(to, p0);
    const q1 = apply(to, p1);
    var r = rx * up;

    // The SDK's circle: centre left of q0 -> q1 for a large left turn or a small right one.
    const left_side = large == turn_left;
    const delta = [2]f32{ (q1[0] - q0[0]) / 2, (q1[1] - q0[1]) / 2 };
    const mid = [2]f32{ q0[0] + delta[0], q0[1] + delta[1] };
    const rv = if (left_side) [2]f32{ -delta[1], delta[0] } else [2]f32{ delta[1], -delta[0] };
    const len2 = rv[0] * rv[0] + rv[1] * rv[1];
    if (len2 - 0.03 > r * r or r < 0) r = @sqrt(len2);
    const k = @sqrt(@max(0, r * r / len2 - 1));
    const center = [2]f32{ mid[0] + rv[0] * k, mid[1] + rv[1] * k };
    const angle = std.math.asin(std.math.clamp(@sqrt(len2) / r, -1, 1)) * 2;
    const sweep = (if (large) std.math.tau - angle else angle) * @as(f32, if (turn_left) -1 else 1);

    // Points rotate by +angle with the matrix [c -s; s c] in x right, y down.
    const start = std.math.atan2(q0[1] - center[1], q0[0] - center[0]);
    const pieces: u32 = @intFromFloat(@max(@ceil(@abs(sweep) / (std.math.pi / 2.0) - 1e-4), 1));
    const step = sweep / @as(f32, @floatFromInt(pieces));
    const h = 4.0 / 3.0 * @tan(step / 4);
    try room(path, pieces, 3 * pieces);
    for (0..pieces) |i| {
        const a0 = start + step * @as(f32, @floatFromInt(i));
        const a1 = a0 + step;
        const e0 = [2]f32{ center[0] + r * @cos(a0), center[1] + r * @sin(a0) };
        const e1 = if (i + 1 == pieces) q1 else [2]f32{ center[0] + r * @cos(a1), center[1] + r * @sin(a1) };
        const c0 = [2]f32{ e0[0] - h * r * @sin(a0), e0[1] + h * r * @cos(a0) };
        const c1 = [2]f32{ center[0] + r * @cos(a1) + h * r * @sin(a1), center[1] + r * @sin(a1) - h * r * @cos(a1) };
        const b0 = apply(back, c0);
        const b1 = apply(back, c1);
        const b2 = if (i + 1 == pieces) p1 else apply(back, e1);
        path.cubicTo(b0[0], b0[1], b1[0], b1[1], b2[0], b2[1]);
    }
}

fn apply(m: [2][2]f32, p: [2]f32) [2]f32 {
    return .{ p[0] * m[0][0] + p[1] * m[0][1], p[0] * m[1][0] + p[1] * m[1][1] };
}

const testing = std.testing;
const icon_all = @embedFile("testdata/paths/icon_all.tvg");
const icon_565 = @embedFile("testdata/paths/icon_565.tvg");
const icon_f32 = @embedFile("testdata/paths/icon_f32.tvg");

/// Decodes every command of `data`; returns the items, or the first error.
fn testDecode(data: []const u8, path: *Path, items: []Item) Error![]Item {
    var img = try parse(data);
    var n: usize = 0;
    while (try img.next(1, 0, 0, path)) |it| : (n += 1) items[n] = it;
    return items[0..n];
}

test "parse: header, colour table and every colour encoding" {
    const a = try parse(icon_all);
    try testing.expectEqual(24, a.width);
    try testing.expectEqual(4, a.scale_bits);
    try testing.expectEqual(2, a.unit_bytes);
    try testing.expectEqual(7, a.color_count);
    try testing.expectEqual(Color.rgba(96, 192, 255, 200), try a.color(2));
    try testing.expectError(error.BadColor, a.color(7));
    const b = try parse(icon_565);
    try testing.expectEqual(1, b.unit_bytes);
    // (31, 20, 4) in 5/6/5 bits: 255, 81, 33.
    try testing.expectEqual(Color.rgb(255, 81, 33), try b.color(1));
    const c = try parse(icon_f32);
    try testing.expectEqual(4, c.unit_bytes);
    // (0.2, 0.9, 1.5, 0.6): blue clamps to 1.
    try testing.expectEqual(Color.rgba(51, 230, 255, 153), try c.color(1));
    try testing.expectError(error.BadMagic, parse("\x72\x57\x01\x00"));
    try testing.expectError(error.BadVersion, parse("\x72\x56\x02\x00"));
    try testing.expectError(error.UnsupportedColors, parse("\x72\x56\x01\x30\x00\x00\x00"));
}

test "next: every command of the test icon, in order, with its styles" {
    var t: paths.TestBuffers(64, 512) = .{};
    var path = t.path();
    var items: [16]Item = undefined;
    const got = try testDecode(icon_all, &path, &items);
    // tvg.py: polygon, rects, path (gradient), lines, loop, strip, line path, outline polygon,
    // outline rects, text hint, outline path (radial gradient).
    try testing.expectEqual(11, got.len);
    try testing.expectEqual(Color.rgb(255, 128, 64), got[0].fill.?);
    try testing.expectEqual(paths.Rule.even_odd, got[0].rule);
    try testing.expectEqual(paths.Rule.nonzero, got[1].rule);
    try testing.expect(got[2].gradient and got[2].fill.?.g == 255);
    try testing.expectEqual(@as(?Color, null), got[3].fill);
    try testing.expectEqual(1.25, got[4].width);
    // At 1 px per unit the lines (0.75) and the strip (0.25) are at least a pixel wide.
    try testing.expectEqual(1, got[3].width);
    try testing.expectEqual(1, got[5].width);
    try testing.expect(got[7].fill != null and got[7].line != null);
    try testing.expect(got[9].fill == null and got[9].line == null);
    try testing.expect(got[10].gradient);
    // The end of the document leaves the path empty.
    try testing.expectEqual(0, path.verbs);
}

test "next: the path maps units to px by scale and offset" {
    var t: paths.TestBuffers(64, 512) = .{};
    var path = t.path();
    var img = try parse(icon_all);
    _ = (try img.next(2, 10, 20, &path)).?;
    // First polygon point (4, 1.5).
    try testing.expectEqual(18, path.x[0]);
    try testing.expectEqual(23, path.y[0]);
    try testing.expectEqual(5, path.points);
}

test "decoding: every truncation fails cleanly, a small path reports NoSpace" {
    var t: paths.TestBuffers(64, 512) = .{};
    var path = t.path();
    var items: [16]Item = undefined;
    for ([_][]const u8{ icon_all, icon_565, icon_f32 }) |data| {
        _ = try testDecode(data, &path, &items);
        for (0..data.len - 1) |n| {
            if (testDecode(data[0..n], &path, &items)) |_| return error.TestUnexpectedResult else |_| {}
        }
    }
    var small: paths.TestBuffers(4, 4) = .{};
    var p = small.path();
    try testing.expectError(error.NoSpace, testDecode(icon_all, &p, &items));
}

test "VarUInt: the specification's examples, overlong forms and rejects" {
    const cases = [_]struct { []const u8, u32 }{
        .{ "\x00", 0 },                       .{ "\x7f", 127 },               .{ "\x80\x01", 128 },
        .{ "\x8f\x7f", 16271 },               .{ "\x80\x80\x40", 1048576 },   .{ "\xff\xff\xff\xff\x0f", 4294967295 },
        // The specification lists this overlong form as 1, but its own algorithm (bits 28..31
        // in the fifth byte) reads 2^28; the algorithm wins.
        .{ "\x80\x80\x80\x80\x01", 1 << 28 }, .{ "\x80\x80\x80\x80\x00", 0 },
    };
    const img: Image = .{ .data = "", .width = 0, .height = 0, .scale_bits = 0, .unit_bytes = 2, .color_encoding = 0, .color_count = 0, .colors = 0, .at = 0 };
    for (cases) |c| {
        var copy = img;
        copy.data = c[0];
        var r: Reader = .{ .img = &copy, .at = 0 };
        try testing.expectEqual(c[1], try r.varUint());
    }
    for ([_][]const u8{ "\x80\x80\x80\x80\x80\x00", "\xff\xff\xff\xff\x1f", "\x80" }) |bad| {
        var copy = img;
        copy.data = bad;
        var r: Reader = .{ .img = &copy, .at = 0 };
        try testing.expect(std.meta.isError(r.varUint()));
    }
}

test "arc: a quarter circle as one cubic ending on its target" {
    var t: paths.TestBuffers(8, 64) = .{};
    var path = t.path();
    path.moveTo(10, 0);
    // From (10, 0) to (0, 10), radius 10, small arc turning right: centre (0, 0).
    try arc(&path, .{ 10, 0 }, .{ 0, 10 }, 10, 10, 0, false, false);
    try testing.expectEqual(2, path.verbs);
    try testing.expectEqual(Verb.cubic, path.verb[1]);
    try testing.expectEqual(0, path.x[3]);
    try testing.expectEqual(10, path.y[3]);
    // Controls at distance 4/3 tan(pi/8) * 10 = 5.52 along the tangents.
    try testing.expectApproxEqAbs(10, path.x[1], 1e-4);
    try testing.expectApproxEqAbs(5.5228, path.y[1], 1e-3);
    try testing.expectApproxEqAbs(5.5228, path.x[2], 1e-3);
}
