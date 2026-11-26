//! The canvas batch behind the C seam (lcgf.h `lcgf_canvas_*`): `canvas.Instances` in the
//! caller's memory, its builders, `kill`, `clearDirty` and `hit`, for C, C++ (lcgf/runtime.hpp
//! `lcgf::Canvas`) and Rust (`lcgf::runtime::Canvas`). `lcgf_rt_canvas` (runtime.zig) puts one
//! in a frame.
//!
//! An `lcgf_canvas` is the `Instances` itself, at the start of the caller's buffer, its columns
//! after it. The options cross as the extern structs below; an optional world width is 0 for
//! none (a 0-unit width draws nothing anyway).

const std = @import("std");
const canvas = @import("../draw/canvas.zig");
const mem = @import("../core/mem.zig");
const Instances = canvas.Instances;

/// lcgf_canvas_line: segments and polylines.
pub const CLine = extern struct { layer: u8 = 0, weight: u8 = 1, cap: u8 = 0, dash: u8 = 0, width: u32 = 0 };
/// lcgf_canvas_box: rects and circles.
pub const CBox = extern struct { layer: u8 = 0, weight: u8 = 1, fill: u8 = 1, stroke: u8 = 1, radius: u32 = 0, width: u32 = 0 };
/// lcgf_canvas_arc.
pub const CArc = extern struct { layer: u8 = 0, weight: u8 = 1, cap: u8 = 0, dash: u8 = 0, start: f32 = 0, sweep: f32 = std.math.tau, width: u32 = 0 };
/// lcgf_canvas_area: polygons.
pub const CArea = extern struct { layer: u8 = 0, weight: u8 = 1, fill: u8 = 1, stroke: u8 = 0, width: u32 = 0 };
/// lcgf_canvas_text: a line of `protocol.Mono` glyphs.
pub const CText = extern struct { px: u32, layer: u8 = 0, turns: u8 = 0, pad: [2]u8 = .{ 0, 0 } };
/// lcgf_camera.
pub const CCamera = extern struct { origin: [2]i64 = .{ 0, 0 }, scale: f32 = 1, offset: [2]f32 = .{ 0, 0 }, zoom: f32 = 1 };
/// lcgf_canvas_options: what `Frame.canvas` and `hit` read, all of it the caller's.
pub const COptions = extern struct {
    camera: CCamera = .{},
    layers: [*]const canvas.Layer,
    layers_len: usize,
    zoom_scale: u32 = 0,
    ranges: [*]const canvas.Range,
    ranges_len: usize,
    overrides: ?[*]const canvas.Override = null,
    overrides_len: usize = 0,

    pub fn cam(o: *const COptions) canvas.Camera {
        return .{ .origin = o.camera.origin, .scale = o.camera.scale, .offset = o.camera.offset, .zoom = o.camera.zoom };
    }
    pub fn palette(o: *const COptions) canvas.Palette {
        return .{ .layers = o.layers[0..o.layers_len], .zoom_scale = o.zoom_scale != 0 };
    }
    pub fn spans(o: *const COptions) []const canvas.Range {
        return o.ranges[0..o.ranges_len];
    }
    pub fn marks(o: *const COptions) []const canvas.Override {
        return if (o.overrides) |p| p[0..o.overrides_len] else &.{};
    }
};

const head = std.mem.alignForward(usize, @sizeOf(Instances), mem.column_align);

fn width(w: u32) ?u32 {
    return if (w == 0) null else w;
}

fn cap(c: u8) canvas.Cap {
    return @fromBackingInt(@as(u2, @intCast(@min(c, 2))));
}

fn cBytes(rows: u32, verts: u32, dirty: u32) callconv(.c) usize {
    return head + Instances.requiredBytes(@max(rows, 1), verts, dirty);
}

/// The batch at the start of `buf`, or null when `buf` is unaligned or too small.
fn cInit(buf: [*]u8, len: usize, rows: u32, verts: u32, dirty: u32) callconv(.c) ?*Instances {
    if (@intFromPtr(buf) % mem.column_align != 0 or len < cBytes(rows, verts, dirty)) return null;
    var carver: mem.Carver = .{ .buf = @alignCast(buf[head..len]) };
    const s: *Instances = @ptrCast(@alignCast(buf));
    s.* = Instances.init(&carver, @max(rows, 1), verts, dirty);
    return s;
}

fn cSegment(s: *Instances, ax: i32, ay: i32, bx: i32, by: i32, o: *const CLine) callconv(.c) u32 {
    return s.segment(.{ ax, ay }, .{ bx, by }, line(o));
}

fn line(o: *const CLine) Instances.Line {
    return .{ .layer = o.layer, .weight = o.weight, .cap = cap(o.cap), .dash = @truncate(o.dash), .width = width(o.width) };
}

fn cPolyline(s: *Instances, points: [*]const [2]i32, n: usize, o: *const CLine) callconv(.c) canvas.Range {
    return s.polyline(points[0..n], line(o));
}

fn box(o: *const CBox) Instances.Box {
    return .{ .layer = o.layer, .weight = o.weight, .fill = o.fill != 0, .stroke = o.stroke != 0, .radius = o.radius, .width = width(o.width) };
}

fn cRect(s: *Instances, x0: i32, y0: i32, x1: i32, y1: i32, o: *const CBox) callconv(.c) u32 {
    return s.rect(.{ x0, y0 }, .{ x1, y1 }, box(o));
}

fn cCircle(s: *Instances, cx: i32, cy: i32, r: u32, o: *const CBox) callconv(.c) u32 {
    return s.circle(.{ cx, cy }, r, box(o));
}

fn cArc(s: *Instances, cx: i32, cy: i32, r: u32, o: *const CArc) callconv(.c) u32 {
    return s.arc(.{ cx, cy }, r, .{ .layer = o.layer, .weight = o.weight, .start = o.start, .sweep = o.sweep, .cap = cap(o.cap), .dash = @truncate(o.dash), .width = width(o.width) });
}

fn cPolygon(s: *Instances, points: [*]const [2]i32, n: usize, o: *const CArea) callconv(.c) u32 {
    return s.polygon(points[0..n], .{ .layer = o.layer, .weight = o.weight, .fill = o.fill != 0, .stroke = o.stroke != 0, .width = width(o.width) });
}

fn cGlyph(s: *Instances, ax: i32, ay: i32, w: u32, h: u32, uv: *const [4]f32, layer: u8, turns: u8) callconv(.c) u32 {
    return s.glyph(.{ ax, ay }, .{ w, h }, uv.*, .{ .layer = layer, .turns = @truncate(turns) });
}

fn cGlyphs(s: *Instances, bytes: [*]const u8, len: usize, x: i32, y: i32, o: *const CText) callconv(.c) canvas.Range {
    return s.glyphs(bytes[0..len], .{ x, y }, .{ .px = o.px, .layer = o.layer, .turns = @truncate(o.turns) });
}

fn cKill(s: *Instances, i: u32) callconv(.c) void {
    if (i < s.len) s.kill(i);
}

fn cReset(s: *Instances) callconv(.c) void {
    s.reset();
}

fn cClearDirty(s: *Instances) callconv(.c) void {
    s.clearDirty();
}

fn cLen(s: *const Instances) callconv(.c) u32 {
    return s.len;
}

/// `canvas.hit`, or LCGF_NO_WIDGET when nothing is there.
fn cHit(s: *const Instances, o: *const COptions, x: f32, y: f32, slop: f32) callconv(.c) u32 {
    const pal = o.palette();
    return canvas.hit(s, &pal, o.cam(), o.spans(), .{ x, y }, slop) orelse std.math.maxInt(u32);
}

pub const exports = .{
    .{ "lcgf_canvas_bytes", &cBytes },
    .{ "lcgf_canvas_init", &cInit },
    .{ "lcgf_canvas_segment", &cSegment },
    .{ "lcgf_canvas_polyline", &cPolyline },
    .{ "lcgf_canvas_rect", &cRect },
    .{ "lcgf_canvas_circle", &cCircle },
    .{ "lcgf_canvas_arc", &cArc },
    .{ "lcgf_canvas_polygon", &cPolygon },
    .{ "lcgf_canvas_glyph", &cGlyph },
    .{ "lcgf_canvas_glyphs", &cGlyphs },
    .{ "lcgf_canvas_kill", &cKill },
    .{ "lcgf_canvas_reset", &cReset },
    .{ "lcgf_canvas_clear_dirty", &cClearDirty },
    .{ "lcgf_canvas_len", &cLen },
    .{ "lcgf_canvas_hit", &cHit },
};

test "canvas: the C builders write the rows the Zig builders do" {
    const bytes = cBytes(8, 8, 2);
    const a = try std.testing.allocator.alignedAlloc(u8, .fromByteUnits(mem.column_align), bytes);
    defer std.testing.allocator.free(a);
    try std.testing.expectEqual(null, cInit(a.ptr, bytes - 1, 8, 8, 2));
    const s = cInit(a.ptr, a.len, 8, 8, 2).?;
    var buf: [Instances.requiredBytes(8, 8, 2)]u8 align(mem.column_align) = undefined;
    var carver: mem.Carver = .{ .buf = &buf };
    var z = Instances.init(&carver, 8, 8, 2);
    _ = cSegment(s, 0, 0, 10, 5, &.{ .layer = 2, .weight = 3, .cap = 2, .dash = 1, .width = 40 });
    _ = z.segment(.{ 0, 0 }, .{ 10, 5 }, .{ .layer = 2, .weight = 3, .cap = .round, .dash = 1, .width = 40 });
    _ = cArc(s, 1, 2, 30, &.{ .start = 0.5, .sweep = -2, .dash = 3 });
    _ = z.arc(.{ 1, 2 }, 30, .{ .start = 0.5, .sweep = -2, .dash = 3 });
    const tri = [_][2]i32{ .{ 0, 0 }, .{ 9, 0 }, .{ 0, 9 } };
    _ = cPolygon(s, &tri, 3, &.{ .stroke = 1 });
    _ = z.polygon(&tri, .{ .stroke = true });
    try std.testing.expectEqual(canvas.Range{ .first = 3, .count = 2 }, cGlyphs(s, "ab", 2, 5, 5, &.{ .px = 100, .turns = 1 }));
    _ = z.glyphs("ab", .{ 5, 5 }, .{ .px = 100, .turns = 1 });
    try std.testing.expectEqual(z.len, cLen(s));
    try std.testing.expectEqualSlices([4]i32, z.c.pos[0..z.len], s.c.pos[0..s.len]);
    try std.testing.expectEqualSlices([4]u32, z.c.look[0..z.len], s.c.look[0..s.len]);
    const layers = [_]canvas.Layer{.of(.{ .width = 4 })};
    const all = [_]canvas.Range{s.since(0)};
    // The triangle, drawn after the segment, is on top there.
    try std.testing.expectEqual(2, cHit(s, &.{ .layers = &layers, .layers_len = 1, .ranges = &all, .ranges_len = 1 }, 5, 2.5, 0));
    try std.testing.expectEqual(std.math.maxInt(u32), cHit(s, &.{ .layers = &layers, .layers_len = 1, .ranges = &all, .ranges_len = 1 }, 500, 500, 0));
}
