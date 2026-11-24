//! Optional HarfBuzz COLRv1 interpreter adapter. HarfBuzz traverses the validated variable
//! paint graph; these callbacks lower it to LCGF's path coverage, SIMD brushes and compositor.
//! All temporary pixels, transform/clip/group stacks and gradient stops are caller-owned.
//! Only the optional HarfBuzz callback object allocates, once, with the owning HarfBuzz font.

const std = @import("std");
const lcgf = @import("lcgf");
const surface = lcgf.surface;
const brushes = lcgf.brushes;
const compositor = lcgf.compositor;
const simd = lcgf.simd;
const F = simd.F;
const paths = lcgf.paths;
const Color = lcgf.types.Color;
pub const Functions = opaque {};
const ColorLine = opaque {};
pub const ColorStop = extern struct { offset: f32, is_foreground: c_int, color: u32 };
const Destroy = ?*const fn (?*anyopaque) callconv(.c) void;
const Simple = *const fn (*Functions, ?*anyopaque, ?*anyopaque) callconv(.c) void;
const Transform = *const fn (*Functions, ?*anyopaque, f32, f32, f32, f32, f32, f32, ?*anyopaque) callconv(.c) void;
const ClipGlyph = *const fn (*Functions, ?*anyopaque, u32, *anyopaque, ?*anyopaque) callconv(.c) void;
const ClipRect = *const fn (*Functions, ?*anyopaque, f32, f32, f32, f32, ?*anyopaque) callconv(.c) void;
const Solid = *const fn (*Functions, ?*anyopaque, c_int, u32, ?*anyopaque) callconv(.c) void;
const Gradient = *const fn (*Functions, ?*anyopaque, *ColorLine, f32, f32, f32, f32, f32, f32, ?*anyopaque) callconv(.c) void;
const Sweep = *const fn (*Functions, ?*anyopaque, *ColorLine, f32, f32, f32, f32, ?*anyopaque) callconv(.c) void;
const PopGroup = *const fn (*Functions, ?*anyopaque, c_int, ?*anyopaque) callconv(.c) void;
const Palette = *const fn (*Functions, ?*anyopaque, u32, *u32, ?*anyopaque) callconv(.c) c_int;

extern fn hb_paint_funcs_create() *Functions;
extern fn hb_paint_funcs_get_empty() *Functions;
extern fn hb_paint_funcs_destroy(*Functions) void;
extern fn hb_paint_funcs_make_immutable(*Functions) void;
extern fn hb_paint_funcs_set_push_transform_func(*Functions, Transform, ?*anyopaque, Destroy) void;
extern fn hb_paint_funcs_set_pop_transform_func(*Functions, Simple, ?*anyopaque, Destroy) void;
extern fn hb_paint_funcs_set_push_clip_glyph_func(*Functions, ClipGlyph, ?*anyopaque, Destroy) void;
extern fn hb_paint_funcs_set_push_clip_rectangle_func(*Functions, ClipRect, ?*anyopaque, Destroy) void;
extern fn hb_paint_funcs_set_pop_clip_func(*Functions, Simple, ?*anyopaque, Destroy) void;
extern fn hb_paint_funcs_set_color_func(*Functions, Solid, ?*anyopaque, Destroy) void;
extern fn hb_paint_funcs_set_linear_gradient_func(*Functions, Gradient, ?*anyopaque, Destroy) void;
extern fn hb_paint_funcs_set_radial_gradient_func(*Functions, Gradient, ?*anyopaque, Destroy) void;
extern fn hb_paint_funcs_set_sweep_gradient_func(*Functions, Sweep, ?*anyopaque, Destroy) void;
extern fn hb_paint_funcs_set_push_group_func(*Functions, Simple, ?*anyopaque, Destroy) void;
extern fn hb_paint_funcs_set_pop_group_func(*Functions, PopGroup, ?*anyopaque, Destroy) void;
extern fn hb_paint_funcs_set_custom_palette_color_func(*Functions, Palette, ?*anyopaque, Destroy) void;
extern fn hb_color_line_get_color_stops(*ColorLine, c_uint, ?*c_uint, ?[*]ColorStop) c_uint;
extern fn hb_color_line_get_extend(*ColorLine) c_int;
extern fn hb_font_paint_glyph(*anyopaque, u32, *Functions, ?*anyopaque, u32, u32) void;

pub const Override = struct { index: u32, color: Color };
pub const Options = struct {
    palette: u32 = 0,
    foreground: Color = .black,
    /// Font-space y-up -> pixel-space y-down, applied before graph transforms.
    transform: [6]f32 = .{ 1, 0, 0, 1, 0, 0 },
    palette_overrides: []const Override = &.{},
    max_operations: usize = 131072,
};
pub const Scratch = struct {
    path: *paths.Path,
    poly: *paths.Polyline,
    scan: paths.Scratch,
    acc: []f32,
    coverage: []u8,
    /// Each live clip consumes destination.stride * destination.height bytes. A group
    /// applies its inherited clip once at composite time, avoiding doubled edge coverage.
    clips: []u8,
    transforms: [][6]f32,
    groups: []surface.Surface,
    group_clips: []usize,
    stops: []ColorStop,
    brush_stops: []brushes.Stop,
    segments: []brushes.Segment,
    tolerance: f32 = 0.25,
};

pub fn destroy(funcs: *Functions) void {
    hb_paint_funcs_destroy(funcs);
}

fn hbColor(c: Color) u32 {
    return (@as(u32, c.b) << 24) | (@as(u32, c.g) << 16) | (@as(u32, c.r) << 8) | c.a;
}
fn rgba(c: u32) lcgf.color_math.Rgba {
    return lcgf.color_math.fromColor(.rgba(@truncate(c >> 8), @truncate(c >> 16), @truncate(c >> 24), @truncate(c)));
}
fn multiply(a: [6]f32, b: [6]f32) [6]f32 {
    return .{ a[0] * b[0] + a[2] * b[1], a[1] * b[0] + a[3] * b[1], a[0] * b[2] + a[2] * b[3], a[1] * b[2] + a[3] * b[3], a[0] * b[4] + a[2] * b[5] + a[4], a[1] * b[4] + a[3] * b[5] + a[5] };
}
fn inverse(m: [6]f32) ?[6]f32 {
    const determinant = m[0] * m[3] - m[1] * m[2];
    if (determinant == 0 or !std.math.isFinite(determinant)) return null;
    const s = 1 / determinant;
    return .{ m[3] * s, -m[1] * s, -m[2] * s, m[0] * s, (m[2] * m[5] - m[3] * m[4]) * s, (m[1] * m[4] - m[0] * m[5]) * s };
}

pub fn raster(hb: anytype, glyph: u16, variations: anytype, options: Options, destination: surface.Surface, scratch: Scratch) !void {
    try destination.validate();
    if (destination.width == 0 or destination.height == 0) return error.InvalidGeometry;
    if (scratch.transforms.len == 0 or scratch.group_clips.len < scratch.groups.len) return error.NoSpace;
    if (!std.math.isFinite(scratch.tolerance) or scratch.tolerance <= 0) return error.InvalidGeometry;
    for (options.transform) |v| if (!std.math.isFinite(v)) return error.InvalidGeometry;
    const pixel_count = try std.math.mul(usize, destination.stride, destination.height);
    if (scratch.acc.len < paths.accLen(.{ .w = destination.width, .h = destination.height }) or scratch.coverage.len < paths.imageLen(.{ .w = destination.width, .h = destination.height })) return error.NoSpace;
    for (scratch.groups, 0..) |group, i| {
        try group.validate();
        if (group.width != destination.width or group.height != destination.height or group.stride != destination.stride) return error.SizeMismatch;
        if (surface.overlaps(destination.pixels, group.pixels)) return error.AliasedStorage;
        for (scratch.groups[0..i]) |other| if (surface.overlaps(other.pixels, group.pixels)) return error.AliasedStorage;
    }
    const Renderer = State(@TypeOf(hb.*), @TypeOf(variations));
    if (hb.painter == null) {
        const funcs = hb_paint_funcs_create();
        if (funcs == hb_paint_funcs_get_empty()) return error.Unavailable;
        hb_paint_funcs_set_push_transform_func(funcs, Renderer.pushTransform, null, null);
        hb_paint_funcs_set_pop_transform_func(funcs, Renderer.popTransform, null, null);
        hb_paint_funcs_set_push_clip_glyph_func(funcs, Renderer.pushGlyph, null, null);
        hb_paint_funcs_set_push_clip_rectangle_func(funcs, Renderer.pushRectangle, null, null);
        hb_paint_funcs_set_pop_clip_func(funcs, Renderer.popClip, null, null);
        hb_paint_funcs_set_color_func(funcs, Renderer.solid, null, null);
        hb_paint_funcs_set_linear_gradient_func(funcs, Renderer.linear, null, null);
        hb_paint_funcs_set_radial_gradient_func(funcs, Renderer.radial, null, null);
        hb_paint_funcs_set_sweep_gradient_func(funcs, Renderer.sweep, null, null);
        hb_paint_funcs_set_push_group_func(funcs, Renderer.pushGroup, null, null);
        hb_paint_funcs_set_pop_group_func(funcs, Renderer.popGroup, null, null);
        hb_paint_funcs_set_custom_palette_color_func(funcs, Renderer.paletteColor, null, null);
        hb_paint_funcs_make_immutable(funcs);
        hb.painter = funcs;
    }
    scratch.transforms[0] = options.transform;
    try surface.clear(destination, @splat(0));
    errdefer surface.clear(destination, @splat(0)) catch {};
    var state: Renderer = .{ .hb = hb, .variations = variations, .options = options, .destination = destination, .scratch = scratch, .pixel_count = pixel_count };
    hb_font_paint_glyph(hb.font, glyph, hb.painter.?, &state, options.palette, hbColor(options.foreground));
    if (state.failure) |err| return err;
    if (state.transform_depth != 1 or state.clip_depth != 0 or state.group_depth != 0) return error.UnbalancedPaint;
}

fn State(comptime HB: type, comptime Variations: type) type {
    return struct {
        const Self = @This();
        hb: *HB,
        variations: Variations,
        options: Options,
        destination: surface.Surface,
        scratch: Scratch,
        pixel_count: usize,
        failure: ?anyerror = null,
        operations: usize = 0,
        transform_depth: usize = 1,
        clip_depth: usize = 0,
        group_depth: usize = 0,

        fn get(pointer: ?*anyopaque) *Self {
            return @ptrCast(@alignCast(pointer.?));
        }
        fn enter(s: *Self) bool {
            if (s.failure != null) return false;
            if (s.operations == s.options.max_operations) {
                s.failure = error.LimitExceeded;
                return false;
            }
            s.operations += 1;
            return true;
        }
        fn matrix(s: *const Self) [6]f32 {
            return s.scratch.transforms[s.transform_depth - 1];
        }
        fn target(s: *const Self) surface.Surface {
            return if (s.group_depth == 0) s.destination else s.scratch.groups[s.group_depth - 1];
        }
        fn clipBase(s: *const Self) usize {
            return if (s.group_depth == 0) 0 else s.scratch.group_clips[s.group_depth - 1];
        }
        fn mask(s: *const Self) ?[]const u8 {
            return if (s.clip_depth <= s.clipBase()) null else s.scratch.clips[(s.clip_depth - 1) * s.pixel_count ..][0..s.pixel_count];
        }
        fn coverage(s: *const Self, x: usize, y: usize) F {
            const bytes = s.mask() orelse return simd.f(1);
            const lanes: @Vector(simd.lanes, u8) = bytes[y * s.destination.stride + x ..][0..simd.lanes].*;
            return @as(F, @floatFromInt(lanes)) / simd.f(255);
        }
        fn pushTransform(_: *Functions, pointer: ?*anyopaque, xx: f32, yx: f32, xy: f32, yy: f32, dx: f32, dy: f32, _: ?*anyopaque) callconv(.c) void {
            const s = get(pointer);
            if (!s.enter()) return;
            if (s.transform_depth == s.scratch.transforms.len) {
                s.failure = error.NoSpace;
                return;
            }
            const next = multiply(s.matrix(), .{ xx, yx, xy, yy, dx, dy });
            for (next) |v| if (!std.math.isFinite(v)) {
                s.failure = error.InvalidGeometry;
                return;
            };
            s.scratch.transforms[s.transform_depth] = next;
            s.transform_depth += 1;
        }
        fn popTransform(_: *Functions, pointer: ?*anyopaque, _: ?*anyopaque) callconv(.c) void {
            const s = get(pointer);
            if (!s.enter()) return;
            if (s.transform_depth <= 1) {
                s.failure = error.UnbalancedPaint;
                return;
            }
            s.transform_depth -= 1;
        }
        fn clipPath(s: *Self) !void {
            if (s.clip_depth >= s.scratch.clips.len / s.pixel_count) return error.NoSpace;
            const need = paths.flattenLen(s.scratch.path, s.scratch.tolerance);
            if (need.points > s.scratch.poly.x.len or need.points > s.scratch.poly.y.len or need.contours > s.scratch.poly.end.len or need.contours > s.scratch.poly.closed.len) return error.NoSpace;
            paths.flatten(s.scratch.path, s.scratch.tolerance, s.scratch.poly);
            const points = s.scratch.poly.points;
            const scan = s.scratch.scan;
            if (scan.x0.len < points or scan.y0.len < points or scan.y1.len < points or scan.dxdy.len < points or scan.cross_x.len < points or scan.cross_d.len < points) return error.NoSpace;
            const box: paths.Box = .{ .w = s.destination.width, .h = s.destination.height };
            paths.fill(s.scratch.poly, box, .nonzero, scan, s.scratch.acc);
            lcgf.raster.coverage(s.scratch.acc, s.scratch.coverage, @as(usize, box.w) * box.h);
            const output = s.scratch.clips[s.clip_depth * s.pixel_count ..][0..s.pixel_count];
            const prior = s.mask();
            @memset(output, 0);
            for (0..box.h) |y| for (0..box.w) |x| {
                const at = y * s.destination.stride + x;
                const alpha: u32 = s.scratch.coverage[y * box.w + x];
                output[at] = @intCast(if (prior) |p| (alpha * p[at] + 127) / 255 else alpha);
            };
            s.clip_depth += 1;
        }
        fn pushGlyph(_: *Functions, pointer: ?*anyopaque, glyph: u32, font: *anyopaque, _: ?*anyopaque) callconv(.c) void {
            const s = get(pointer);
            if (!s.enter()) return;
            if (@intFromPtr(font) != @intFromPtr(s.hb.font) or glyph > std.math.maxInt(u16)) {
                s.failure = error.UnsupportedFont;
                return;
            }
            s.hb.outline(@intCast(glyph), s.variations, s.matrix(), s.scratch.path) catch |err| {
                s.failure = err;
                return;
            };
            s.clipPath() catch |err| {
                s.failure = err;
            };
        }
        fn pushRectangle(_: *Functions, pointer: ?*anyopaque, x0: f32, y0: f32, x1: f32, y1: f32, _: ?*anyopaque) callconv(.c) void {
            const s = get(pointer);
            if (!s.enter()) return;
            const p = s.scratch.path;
            p.clear();
            if (p.verb.len < 5 or p.x.len < 4 or p.y.len < 4) {
                s.failure = error.NoSpace;
                return;
            }
            const m = s.matrix();
            const xy: [4][2]f32 = .{ .{ x0, y0 }, .{ x1, y0 }, .{ x1, y1 }, .{ x0, y1 } };
            for (xy, 0..) |point, i| {
                const x = m[0] * point[0] + m[2] * point[1] + m[4];
                const y = m[1] * point[0] + m[3] * point[1] + m[5];
                if (!std.math.isFinite(x) or !std.math.isFinite(y)) {
                    s.failure = error.InvalidGeometry;
                    return;
                }
                if (i == 0) p.moveTo(x, y) else p.lineTo(x, y);
            }
            p.close();
            s.clipPath() catch |err| {
                s.failure = err;
            };
        }
        fn popClip(_: *Functions, pointer: ?*anyopaque, _: ?*anyopaque) callconv(.c) void {
            const s = get(pointer);
            if (!s.enter()) return;
            if (s.clip_depth == 0) {
                s.failure = error.UnbalancedPaint;
                return;
            }
            s.clip_depth -= 1;
        }
        fn paint(s: *Self, brush: brushes.Brush) !void {
            try brushes.validate(brush);
            const m = inverse(s.matrix()) orelse return;
            const dst = s.target();
            for (0..dst.height) |y| {
                var x: usize = 0;
                while (x < dst.width) : (x += simd.lanes) {
                    const px: F = @as(F, @floatFromInt(simd.iota + simd.u(@intCast(x)))) + simd.f(0.5);
                    const py = simd.f(@as(f32, @floatFromInt(y)) + 0.5);
                    const sampled = brushes.sample(brush, simd.f(m[0]) * px + simd.f(m[2]) * py + simd.f(m[4]), simd.f(m[1]) * px + simd.f(m[3]) * py + simd.f(m[5]));
                    surface.store(dst, x, y, compositor.combine(surface.load(dst, x, y), sampled, s.coverage(x, y), .source_over, .normal));
                }
            }
        }
        fn solid(_: *Functions, pointer: ?*anyopaque, _: c_int, color: u32, _: ?*anyopaque) callconv(.c) void {
            const s = get(pointer);
            if (!s.enter()) return;
            s.paint(.{ .solid = rgba(color) }) catch |err| {
                s.failure = err;
            };
        }
        fn ramp(s: *Self, line: *ColorLine) !brushes.Ramp {
            const total = hb_color_line_get_color_stops(line, 0, null, null);
            if (total == 0) return error.InvalidStops;
            if (s.scratch.stops.len < total or s.scratch.brush_stops.len < total or s.scratch.segments.len < total) return error.NoSpace;
            var count = total;
            _ = hb_color_line_get_color_stops(line, 0, &count, s.scratch.stops.ptr);
            if (count != total) return error.InvalidStops;
            for (s.scratch.stops[0..count], s.scratch.brush_stops[0..count]) |stop, *out| out.* = .{ .position = stop.offset, .color = rgba(stop.color) };
            const extend = hb_color_line_get_extend(line);
            if (extend < 0 or extend > 2) return error.InvalidStops;
            return brushes.prepareStops(s.scratch.brush_stops[0..count], s.scratch.segments, .{ .space = .srgb, .premultiplied = true }, @fromBackingInt(@intCast(extend)));
        }
        fn linear(_: *Functions, pointer: ?*anyopaque, line: *ColorLine, x0: f32, y0: f32, x1: f32, y1: f32, x2: f32, y2: f32, _: ?*anyopaque) callconv(.c) void {
            const s = get(pointer);
            if (!s.enter()) return;
            const r = s.ramp(line) catch |err| {
                s.failure = err;
                return;
            };
            const nx = -(y2 - y0);
            const ny = x2 - x0;
            const squared = nx * nx + ny * ny;
            const projection = (x1 - x0) * nx + (y1 - y0) * ny;
            if (squared == 0 or projection == 0) return; // COLR degenerate gradient paints nothing.
            s.paint(.{ .linear = .{ .ramp = r, .from = .{ x0, y0 }, .to = .{ x0 + nx * projection / squared, y0 + ny * projection / squared } } }) catch |err| {
                s.failure = err;
            };
        }
        fn radial(_: *Functions, pointer: ?*anyopaque, line: *ColorLine, x0: f32, y0: f32, r0: f32, x1: f32, y1: f32, r1: f32, _: ?*anyopaque) callconv(.c) void {
            const s = get(pointer);
            if (!s.enter()) return;
            const r = s.ramp(line) catch |err| {
                s.failure = err;
                return;
            };
            s.paint(.{ .two_circle = .{ .ramp = r, .start = .{ x0, y0 }, .start_radius = r0, .end = .{ x1, y1 }, .end_radius = r1 } }) catch |err| {
                s.failure = err;
            };
        }
        fn sweep(_: *Functions, pointer: ?*anyopaque, line: *ColorLine, x: f32, y: f32, start: f32, end: f32, _: ?*anyopaque) callconv(.c) void {
            const s = get(pointer);
            if (!s.enter()) return;
            const r = s.ramp(line) catch |err| {
                s.failure = err;
                return;
            };
            s.paint(.{ .sweep = .{ .ramp = r, .center = .{ x, y }, .start_angle = start, .end_angle = end } }) catch |err| {
                s.failure = err;
            };
        }
        fn pushGroup(_: *Functions, pointer: ?*anyopaque, _: ?*anyopaque) callconv(.c) void {
            const s = get(pointer);
            if (!s.enter()) return;
            if (s.group_depth == s.scratch.groups.len) {
                s.failure = error.NoSpace;
                return;
            }
            surface.clear(s.scratch.groups[s.group_depth], @splat(0)) catch |err| {
                s.failure = err;
                return;
            };
            s.scratch.group_clips[s.group_depth] = s.clip_depth;
            s.group_depth += 1;
        }
        fn popGroup(_: *Functions, pointer: ?*anyopaque, mode: c_int, _: ?*anyopaque) callconv(.c) void {
            const s = get(pointer);
            if (!s.enter()) return;
            if (s.group_depth == 0 or mode < 0 or mode > 27 or s.clip_depth != s.clipBase()) {
                s.failure = error.UnbalancedPaint;
                return;
            }
            const src = s.target();
            s.group_depth -= 1;
            const dst = s.target();
            const operator: compositor.Operator = if (mode < 13) @fromBackingInt(@intCast(mode)) else .source_over;
            const modes = [_]compositor.Blend{ .screen, .overlay, .darken, .lighten, .color_dodge, .color_burn, .hard_light, .soft_light, .difference, .exclusion, .multiply, .hue, .saturation, .color, .luminosity };
            const blend: compositor.Blend = if (mode < 13) .normal else modes[@intCast(mode - 13)];
            for (0..dst.height) |y| {
                var x: usize = 0;
                while (x < dst.width) : (x += simd.lanes) {
                    const old = surface.load(dst, x, y);
                    var combined = compositor.combine(old, surface.load(src, x, y), simd.f(1), operator, blend);
                    const mask_value = s.coverage(x, y);
                    inline for (0..4) |c| combined[c] = old[c] + (combined[c] - old[c]) * mask_value;
                    surface.store(dst, x, y, combined);
                }
            }
        }
        fn paletteColor(_: *Functions, pointer: ?*anyopaque, index: u32, color: *u32, _: ?*anyopaque) callconv(.c) c_int {
            const s = get(pointer);
            if (!s.enter()) return 0;
            for (s.options.palette_overrides) |override| if (override.index == index) {
                color.* = hbColor(override.color);
                return 1;
            };
            return 0;
        }
    };
}
