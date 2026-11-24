//! Rich brushes, with caller-owned prepared stops and borrowed images. Stop preparation is
//! separate from sampling: color-space conversion happens once, and the pixel pass is SIMD.
//! All samplers return premultiplied encoded-sRGB channels for `surface`/`compositor`.

const std = @import("std");
const simd = @import("../core/simd.zig");
const color = @import("color_math.zig");
const surface = @import("surface.zig");
const Rect = @import("../core/types.zig").Rect;
const F = simd.F;
const Batch = surface.Batch;

pub const Error = surface.Error || error{ InvalidColor, InvalidStops, InvalidGeometry };
pub const Spread = enum { pad, repeat, reflect };
pub const Sampling = enum { nearest, linear };
pub const Address = enum { clamp, repeat, mirror, transparent };
pub const Fit = enum { fill, contain, cover, none, scale_down };
pub const Repeat = enum { none, repeat, mirror, round, space };

/// Positions may extend outside 0..1 and may coincide for a hard stop. `midpoint` is the
/// interpolation midpoint between this stop and the next, in the open interval (0,1).
pub const Stop = struct { position: f32, color: color.Rgba, midpoint: f32 = 0.5 };
pub const Segment = struct {
    position: f32,
    reciprocal_span: f32,
    from: color.Rgba,
    to: color.Rgba,
    exponent: f32,
};
pub const Ramp = struct {
    segments: []const Segment,
    interpolation: color.Interpolation = .{},
    spread: Spread = .pad,
};

fn coordinates(c: color.Rgba, space: color.Space) color.Rgba {
    return switch (space) {
        .srgb => c,
        .linear_srgb => color.linear(c),
        .oklab => color.toOklab(c),
        .oklch => color.toOklch(c),
    };
}

/// Writes one segment per supplied stop, including the final constant segment. The returned
/// ramp borrows `out`; it can be reused or discarded by the caller without synchronization.
pub fn prepareStops(stops: []const Stop, out: []Segment, interpolation: color.Interpolation, spread: Spread) Error!Ramp {
    if (stops.len == 0) return error.InvalidStops;
    if (out.len < stops.len) return error.InsufficientStorage;
    for (stops, 0..) |s, i| {
        if (!std.math.isFinite(s.position) or !std.math.isFinite(s.midpoint) or s.midpoint <= 0 or s.midpoint >= 1) return error.InvalidStops;
        if (i > 0 and s.position < stops[i - 1].position) return error.InvalidStops;
        if (!color.finite(s.color) or s.color[3] < 0 or s.color[3] > 1) return error.InvalidColor;
    }
    for (stops, 0..) |s, i| {
        const next = stops[@min(i + 1, stops.len - 1)];
        var from = coordinates(s.color, interpolation.space);
        var to = coordinates(next.color, interpolation.space);
        if (interpolation.space == .oklch) {
            if (from[1] < 1e-6) from[2] = to[2];
            if (to[1] < 1e-6) to[2] = from[2];
            const increasing = @mod(to[2] - from[2], 360);
            const shorter = if (increasing > 180) increasing - 360 else increasing;
            to[2] = from[2] + switch (interpolation.hue) {
                .shorter => shorter,
                .longer => if (shorter >= 0) shorter - 360 else shorter + 360,
                .increasing => increasing,
                .decreasing => if (increasing == 0) @as(f32, 0) else increasing - 360,
            };
        }
        if (interpolation.premultiplied) inline for (0..3) |c| {
            if (c != 2 or interpolation.space != .oklch) {
                from[c] *= from[3];
                to[c] *= to[3];
            }
        };
        const span = next.position - s.position;
        out[i] = .{
            .position = s.position,
            .reciprocal_span = if (span > 0) 1 / span else 0,
            .from = from,
            .to = to,
            .exponent = @log(0.5) / @log(s.midpoint),
        };
    }
    return .{ .segments = out[0..stops.len], .interpolation = interpolation, .spread = spread };
}

pub const Linear = struct { ramp: Ramp, from: [2]f32, to: [2]f32 };
/// The center and radii define the final ellipse; the optional focus shifts the zero-radius
/// point. Focus must lie strictly inside the ellipse. This also supports focal SVG gradients.
pub const Radial = struct { ramp: Ramp, center: [2]f32, radius: [2]f32, focus: ?[2]f32 = null };
/// Angle zero points up; positive angles turn clockwise. `angle` is in radians.
pub const Conic = struct { ramp: Ramp, center: [2]f32, angle: f32 = 0 };

pub const ImageBrush = struct {
    image: surface.Image,
    /// Pixel-space source rectangle, allowing atlas regions and fractional crops.
    source: Rect,
    /// One tile, in the same logical coordinate system as sample x/y.
    destination: Rect,
    /// Area used to distribute `round` and `space` tiles. Repeats are not implicitly clipped
    /// to this area; the painting layer chooses its own box or mask.
    area: Rect,
    repeat: [2]Repeat = .{ .none, .none },
    sampling: Sampling = .linear,
    tint: color.Rgba = .{ 1, 1, 1, 1 },
};

pub const Brush = union(enum) {
    solid: color.Rgba,
    linear: Linear,
    radial: Radial,
    conic: Conic,
    image: ImageBrush,
};

fn finite2(v: [2]f32) bool {
    return std.math.isFinite(v[0]) and std.math.isFinite(v[1]);
}

pub fn validRect(r: Rect) bool {
    return std.math.isFinite(r.x0) and std.math.isFinite(r.y0) and std.math.isFinite(r.x1) and std.math.isFinite(r.y1) and r.x1 > r.x0 and r.y1 > r.y0;
}

fn validateRamp(r: Ramp) Error!void {
    if (r.segments.len == 0) return error.InvalidStops;
    for (r.segments, 0..) |s, i| {
        if (!std.math.isFinite(s.position) or !std.math.isFinite(s.reciprocal_span) or s.reciprocal_span < 0 or !std.math.isFinite(s.exponent) or s.exponent <= 0 or !color.finite(s.from) or !color.finite(s.to)) return error.InvalidStops;
        if (i > 0 and s.position < r.segments[i - 1].position) return error.InvalidStops;
    }
}

pub fn validate(b: Brush) Error!void {
    switch (b) {
        .solid => |s| if (!color.finite(s) or s[3] < 0 or s[3] > 1) return error.InvalidColor,
        .linear => |g| {
            try validateRamp(g.ramp);
            if (!finite2(g.from) or !finite2(g.to)) return error.InvalidGeometry;
        },
        .radial => |g| {
            try validateRamp(g.ramp);
            if (!finite2(g.center) or !finite2(g.radius) or g.radius[0] <= 0 or g.radius[1] <= 0) return error.InvalidGeometry;
            if (g.focus) |f| {
                if (!finite2(f)) return error.InvalidGeometry;
                const x = (f[0] - g.center[0]) / g.radius[0];
                const y = (f[1] - g.center[1]) / g.radius[1];
                if (x * x + y * y >= 1) return error.InvalidGeometry;
            }
        },
        .conic => |g| {
            try validateRamp(g.ramp);
            if (!finite2(g.center) or !std.math.isFinite(g.angle)) return error.InvalidGeometry;
        },
        .image => |g| {
            try g.image.validate();
            if (!validRect(g.source) or !validRect(g.destination) or !validRect(g.area)) return error.InvalidGeometry;
            if (g.source.x0 < 0 or g.source.y0 < 0 or g.source.x1 > @as(f32, @floatFromInt(g.image.width)) or g.source.y1 > @as(f32, @floatFromInt(g.image.height))) return error.InvalidGeometry;
            if (!color.finite(g.tint) or g.tint[3] < 0 or g.tint[3] > 1) return error.InvalidColor;
        },
    }
}

inline fn pow(v: F, e: F) F {
    return @select(f32, v > simd.f(0), @exp(@log(@max(v, simd.f(1e-30))) * e), simd.f(0));
}

inline fn encode(v: F) F {
    const a = @abs(v);
    const enc = @select(f32, a <= simd.f(0.0031308), a * simd.f(12.92), simd.f(1.055) * pow(a, simd.f(1.0 / 2.4)) - simd.f(0.055));
    return @select(f32, v < simd.f(0), -enc, enc);
}

fn fromCoordinates(v: Batch, interpolation: color.Interpolation) Batch {
    var c = v;
    if (interpolation.premultiplied) {
        const count: usize = if (interpolation.space == .oklch) 2 else 3;
        for (0..count) |k| c[k] /= @max(c[3], simd.f(1e-20));
    }
    switch (interpolation.space) {
        .srgb => {},
        .linear_srgb => inline for (0..3) |k| {
            c[k] = encode(c[k]);
        },
        .oklab, .oklch => {
            if (interpolation.space == .oklch) {
                const radians = c[2] * simd.f(std.math.pi / 180.0);
                const chroma = c[1];
                c[1] = chroma * @cos(radians);
                c[2] = chroma * @sin(radians);
            }
            const l = c[0] + simd.f(0.3963377774) * c[1] + simd.f(0.2158037573) * c[2];
            const m = c[0] - simd.f(0.1055613458) * c[1] - simd.f(0.0638541728) * c[2];
            const s = c[0] - simd.f(0.0894841775) * c[1] - simd.f(1.2914855480) * c[2];
            const l3 = l * l * l;
            const m3 = m * m * m;
            const s3 = s * s * s;
            c[0] = encode(simd.f(4.0767416621) * l3 - simd.f(3.3077115913) * m3 + simd.f(0.2309699292) * s3);
            c[1] = encode(-simd.f(1.2684380046) * l3 + simd.f(2.6097574011) * m3 - simd.f(0.3413193965) * s3);
            c[2] = encode(-simd.f(0.0041960863) * l3 - simd.f(0.7034186147) * m3 + simd.f(1.7076147010) * s3);
        },
    }
    // RGBA8 surfaces have an explicit sRGB gamut. Clip straight colors before alpha, otherwise
    // out-of-gamut channels could exceed alpha and violate the surface representation.
    inline for (0..3) |k| c[k] = @min(@max(c[k], simd.f(0)), simd.f(1)) * c[3];
    return c;
}

pub fn sampleRamp(r: Ramp, position: F) Batch {
    const first = r.segments[0];
    const last = r.segments[r.segments.len - 1];
    const length = last.position - first.position;
    const period = @max(length, 1e-20);
    var p = position;
    switch (r.spread) {
        .pad => {},
        .repeat => p = simd.f(first.position) + @mod(p - simd.f(first.position), simd.f(period)),
        .reflect => p = simd.f(first.position) + simd.f(period) - @abs(@mod(p - simd.f(first.position), simd.f(period * 2)) - simd.f(period)),
    }
    var result = surface.splat(first.from);
    for (r.segments) |s| {
        const t = @min(@max((p - simd.f(s.position)) * simd.f(s.reciprocal_span), simd.f(0)), simd.f(1));
        const fraction = if (s.exponent == 1) t else pow(t, simd.f(s.exponent));
        inline for (0..4) |c| {
            const value = simd.f(s.from[c]) + simd.f(s.to[c] - s.from[c]) * fraction;
            result[c] = @select(f32, p >= simd.f(s.position), value, result[c]);
        }
    }
    return fromCoordinates(result, r.interpolation);
}

/// SIMD atan2 for finite coordinates, including a stable zero-angle at the center. The std
/// vector atan implementation handles its approximation; quadrant selection stays branchless.
pub inline fn angle(y: F, x: F) F {
    const ax = @abs(x);
    const ay = @abs(y);
    const a = std.math.atan(@min(ax, ay) / @max(@max(ax, ay), simd.f(1e-30)));
    const quadrant = @select(f32, ay > ax, simd.f(std.math.pi / 2.0) - a, a);
    const left = @select(f32, x < simd.f(0), simd.f(std.math.pi) - quadrant, quadrant);
    return @select(f32, y < simd.f(0), -left, left);
}

const Addressed = struct { index: simd.U, visible: simd.B };
inline fn address(coordinate: F, limit: u32, mode: Address) Addressed {
    const max_index = simd.f(@floatFromInt(limit - 1));
    const length = simd.f(@floatFromInt(limit));
    const visible = (coordinate >= simd.f(0)) & (coordinate < length);
    const bounded = switch (mode) {
        .clamp, .transparent => @min(@max(coordinate, simd.f(0)), max_index),
        .repeat => @mod(coordinate, length),
        .mirror => @min(@mod(coordinate, length * simd.f(2)), length * simd.f(2) - simd.f(1) - @mod(coordinate, length * simd.f(2))),
    };
    return .{ .index = @intFromFloat(bounded), .visible = if (mode == .transparent) visible else @splat(true) };
}

inline fn gather(im: surface.Image, x: F, y: F, modes: [2]Address) Batch {
    const xx = address(x, im.width, modes[0]);
    const yy = address(y, im.height, modes[1]);
    var pixels: simd.U = undefined;
    inline for (0..simd.lanes) |lane| pixels[lane] = im.pixels[@as(usize, yy.index[lane]) * im.stride + xx.index[lane]];
    const unpacked = surface.unpack(@select(u32, xx.visible & yy.visible, pixels, simd.u(0)));
    return if (im.alpha == .straight) surface.premultiply(unpacked) else unpacked;
}

/// Pixel-space sample coordinates: pixel (0,0) is centered at (.5,.5). Bilinear sampling mixes
/// premultiplied values even for a straight source, preventing colored transparent fringes.
pub fn sampleImage(im: surface.Image, x: F, y: F, sampling: Sampling, modes: [2]Address) Batch {
    if (sampling == .nearest) return gather(im, @floor(x), @floor(y), modes);
    const px = x - simd.f(0.5);
    const py = y - simd.f(0.5);
    const x0 = @floor(px);
    const y0 = @floor(py);
    const fx = px - x0;
    const fy = py - y0;
    const a = gather(im, x0, y0, modes);
    const b = gather(im, x0 + simd.f(1), y0, modes);
    const c = gather(im, x0, y0 + simd.f(1), modes);
    const d = gather(im, x0 + simd.f(1), y0 + simd.f(1), modes);
    var out: Batch = undefined;
    inline for (0..4) |k| out[k] = (a[k] + (b[k] - a[k]) * fx) * (simd.f(1) - fy) + (c[k] + (d[k] - c[k]) * fx) * fy;
    return out;
}

const Tile = struct { fraction: F, visible: simd.B };
inline fn tileAxis(v: F, origin: f32, extent: f32, area_origin: f32, area_extent: f32, mode: Repeat) Tile {
    const u = (v - simd.f(origin)) / simd.f(extent);
    return switch (mode) {
        .none => .{ .fraction = @min(@max(u, simd.f(0)), simd.f(1)), .visible = (u >= simd.f(0)) & (u < simd.f(1)) },
        .repeat => .{ .fraction = @mod(u, simd.f(1)), .visible = @splat(true) },
        .mirror => .{ .fraction = simd.f(1) - @abs(@mod(u, simd.f(2)) - simd.f(1)), .visible = @splat(true) },
        .round => .{ .fraction = @mod((v - simd.f(area_origin)) * simd.f(@max(@round(area_extent / extent), 1) / area_extent), simd.f(1)), .visible = @splat(true) },
        .space => blk: {
            const count = @floor(area_extent / extent);
            if (count < 2) break :blk .{ .fraction = @min(@max(u, simd.f(0)), simd.f(1)), .visible = (u >= simd.f(0)) & (u < simd.f(1)) };
            const gap = (area_extent - count * extent) / (count - 1);
            const within = @mod(v - simd.f(area_origin), simd.f(extent + gap));
            break :blk .{ .fraction = within / simd.f(extent), .visible = within < simd.f(extent) };
        },
    };
}

pub fn sample(b: Brush, x: F, y: F) Batch {
    return switch (b) {
        .solid => |s| surface.splat(color.premultiply(.{ std.math.clamp(s[0], 0, 1), std.math.clamp(s[1], 0, 1), std.math.clamp(s[2], 0, 1), s[3] })),
        .linear => |g| blk: {
            const dx = g.to[0] - g.from[0];
            const dy = g.to[1] - g.from[1];
            const d = dx * dx + dy * dy;
            const p = if (d > 0) ((x - simd.f(g.from[0])) * simd.f(dx) + (y - simd.f(g.from[1])) * simd.f(dy)) / simd.f(d) else simd.f(1);
            break :blk sampleRamp(g.ramp, p);
        },
        .radial => |g| blk: {
            const focus = g.focus orelse g.center;
            const fx = (focus[0] - g.center[0]) / g.radius[0];
            const fy = (focus[1] - g.center[1]) / g.radius[1];
            const dx = (x - simd.f(focus[0])) / simd.f(g.radius[0]);
            const dy = (y - simd.f(focus[1])) / simd.f(g.radius[1]);
            const a = dx * dx + dy * dy;
            const bcoef = simd.f(fx) * dx + simd.f(fy) * dy;
            const ccoef = 1 - fx * fx - fy * fy;
            const p = (bcoef + @sqrt(bcoef * bcoef + a * simd.f(ccoef))) / simd.f(ccoef);
            break :blk sampleRamp(g.ramp, p);
        },
        .conic => |g| sampleRamp(g.ramp, @mod(angle(x - simd.f(g.center[0]), -(y - simd.f(g.center[1]))) - simd.f(g.angle), simd.f(2 * std.math.pi)) / simd.f(2 * std.math.pi)),
        .image => |g| blk: {
            const tx = tileAxis(x, g.destination.x0, g.destination.w(), g.area.x0, g.area.w(), g.repeat[0]);
            const ty = tileAxis(y, g.destination.y0, g.destination.h(), g.area.y0, g.area.h(), g.repeat[1]);
            // Clamp to the selected source's pixel centers, rather than adjacent atlas texels.
            const sx = @min(@max(simd.f(g.source.x0) + tx.fraction * simd.f(g.source.w()), simd.f(g.source.x0 + 0.5)), simd.f(@max(g.source.x0 + 0.5, g.source.x1 - 0.5)));
            const sy = @min(@max(simd.f(g.source.y0) + ty.fraction * simd.f(g.source.h()), simd.f(g.source.y0 + 0.5)), simd.f(@max(g.source.y0 + 0.5, g.source.y1 - 0.5)));
            var pixels = sampleImage(g.image, sx, sy, g.sampling, .{ .clamp, .clamp });
            const visible: F = @floatFromInt(@intFromBool(tx.visible & ty.visible));
            inline for (0..3) |c| pixels[c] *= visible * simd.f(std.math.clamp(g.tint[c], 0, 1) * g.tint[3]);
            pixels[3] *= visible * simd.f(g.tint[3]);
            break :blk pixels;
        },
    };
}

/// Stable-box image placement: alignment is a fraction of the leftover space (0=start,
/// .5=center, 1=end). The caller clips cover/none overflow to `box` if desired.
pub fn fitRect(intrinsic: [2]f32, box: Rect, fit: Fit, alignment: [2]f32) Error!Rect {
    if (!finite2(intrinsic) or intrinsic[0] <= 0 or intrinsic[1] <= 0 or !validRect(box) or !finite2(alignment)) return error.InvalidGeometry;
    const contain = @min(box.w() / intrinsic[0], box.h() / intrinsic[1]);
    const scale = switch (fit) {
        .contain => contain,
        .cover => @max(box.w() / intrinsic[0], box.h() / intrinsic[1]),
        .scale_down => @min(contain, 1),
        .none, .fill => @as(f32, 1),
    };
    const width = if (fit == .fill) box.w() else intrinsic[0] * scale;
    const height = if (fit == .fill) box.h() else intrinsic[1] * scale;
    const x = box.x0 + (box.w() - width) * alignment[0];
    const y = box.y0 + (box.h() - height) * alignment[1];
    return .{ .x0 = x, .y0 = y, .x1 = x + width, .y1 = y + height };
}

/// Expands nine-slice into the same image brushes used by backgrounds. Cuts are left, top,
/// right, bottom in source pixels and destination logical pixels, with no 8-bit packing limit.
/// Center/edge tiling is explicit. The middle is omitted when `fill_center` is false.
pub fn nineSlice(image: surface.Image, source: Rect, destination: Rect, source_cuts: [4]f32, destination_cuts: [4]f32, repeat: [2]Repeat, fill_center: bool, sampling: Sampling, out: []ImageBrush) Error![]ImageBrush {
    try image.validate();
    if (out.len < 9) return error.InsufficientStorage;
    if (!validRect(source) or !validRect(destination) or source.x0 < 0 or source.y0 < 0 or source.x1 > @as(f32, @floatFromInt(image.width)) or source.y1 > @as(f32, @floatFromInt(image.height))) return error.InvalidGeometry;
    for (source_cuts) |cut| if (!std.math.isFinite(cut) or cut < 0) return error.InvalidGeometry;
    for (destination_cuts) |cut| if (!std.math.isFinite(cut) or cut < 0) return error.InvalidGeometry;
    if (source_cuts[0] + source_cuts[2] > source.w() or source_cuts[1] + source_cuts[3] > source.h()) return error.InvalidGeometry;
    const scale = @min(@min(destination.w() / @max(destination_cuts[0] + destination_cuts[2], 1e-20), destination.h() / @max(destination_cuts[1] + destination_cuts[3], 1e-20)), 1);
    const sx = [4]f32{ source.x0, source.x0 + source_cuts[0], source.x1 - source_cuts[2], source.x1 };
    const sy = [4]f32{ source.y0, source.y0 + source_cuts[1], source.y1 - source_cuts[3], source.y1 };
    const dx = [4]f32{ destination.x0, destination.x0 + destination_cuts[0] * scale, destination.x1 - destination_cuts[2] * scale, destination.x1 };
    const dy = [4]f32{ destination.y0, destination.y0 + destination_cuts[1] * scale, destination.y1 - destination_cuts[3] * scale, destination.y1 };
    var count: usize = 0;
    for (0..3) |y| for (0..3) |x| {
        if (x == 1 and y == 1 and !fill_center) continue;
        const src: Rect = .{ .x0 = sx[x], .y0 = sy[y], .x1 = sx[x + 1], .y1 = sy[y + 1] };
        const dst: Rect = .{ .x0 = dx[x], .y0 = dy[y], .x1 = dx[x + 1], .y1 = dy[y + 1] };
        if (src.w() <= 0 or src.h() <= 0 or dst.w() <= 0 or dst.h() <= 0) continue;
        const modes: [2]Repeat = .{ if (x == 1) repeat[0] else .none, if (y == 1) repeat[1] else .none };
        const tile_w = if (modes[0] == .none) dst.w() else src.w() * (if (y != 1) dst.h() / src.h() else 1);
        const tile_h = if (modes[1] == .none) dst.h() else src.h() * (if (x != 1) dst.w() / src.w() else 1);
        out[count] = .{ .image = image, .source = src, .destination = .{ .x0 = dst.x0, .y0 = dst.y0, .x1 = dst.x0 + tile_w, .y1 = dst.y0 + tile_h }, .area = dst, .repeat = modes, .sampling = sampling };
        count += 1;
    };
    return out[0..count];
}

const testing = std.testing;

test "multi-stop hard boundaries, repeat, hints and transparent colors reach the sampler" {
    const stops = [_]Stop{ .{ .position = 0, .color = .{ 1, 0, 0, 0 } }, .{ .position = 0.5, .color = .{ 0, 0, 1, 1 } }, .{ .position = 0.5, .color = .{ 0, 1, 0, 1 } }, .{ .position = 1, .color = .{ 1, 1, 1, 1 } } };
    var storage: [4]Segment = undefined;
    const ramp = try prepareStops(&stops, &storage, .{}, .repeat);
    const before = sampleRamp(ramp, simd.f(0.25));
    try testing.expectApproxEqAbs(@as(f32, 0), before[0][0], 0.0001);
    try testing.expectApproxEqAbs(@as(f32, 0.5), before[2][0], 0.0001);
    const hard = sampleRamp(ramp, simd.f(0.5));
    try testing.expectEqual(@as(f32, 1), hard[1][0]);
    try testing.expectEqual(@as(f32, 0), hard[2][0]);
    try testing.expectEqual(hard, sampleRamp(ramp, simd.f(1.5)));
    var hinted: [2]Segment = undefined;
    const hint = try prepareStops(&.{ .{ .position = 0, .color = .{ 0, 0, 0, 1 }, .midpoint = 0.25 }, .{ .position = 1, .color = .{ 1, 1, 1, 1 } } }, &hinted, .{}, .pad);
    try testing.expectApproxEqAbs(@as(f32, 0.5), sampleRamp(hint, simd.f(0.25))[0][0], 0.0001);
}

test "linear light and conic geometry are consumed without scalar pixel tails" {
    var storage: [2]Segment = undefined;
    const ramp = try prepareStops(&.{ .{ .position = 0, .color = .{ 0, 0, 0, 1 } }, .{ .position = 1, .color = .{ 1, 1, 1, 1 } } }, &storage, .{ .space = .linear_srgb }, .pad);
    const b: Brush = .{ .conic = .{ .ramp = ramp, .center = .{ 2, 2 } } };
    try validate(b);
    try testing.expectApproxEqAbs(@as(f32, 0.735357), sample(b, simd.f(2), simd.f(3))[0][0], 0.0001);
    const radial: Brush = .{ .radial = .{ .ramp = ramp, .center = .{ 0, 0 }, .radius = .{ 4, 2 }, .focus = .{ 1, 0 } } };
    try validate(radial);
    try testing.expectApproxEqAbs(@as(f32, 1), sample(radial, simd.f(4), simd.f(0))[0][0], 0.0001);
}

test "bilinear sampling prevents a transparent red fringe and respects placement" {
    const pixels = [_]u32{ 0x000000ff, 0xffff0000 };
    const image: surface.Image = .{ .pixels = &pixels, .width = 2, .height = 1, .stride = 2 };
    const mixed = sampleImage(image, simd.f(1), simd.f(0.5), .linear, .{ .clamp, .clamp });
    try testing.expectEqual(@as(f32, 0), mixed[0][0]);
    try testing.expectEqual(@as(f32, 0.5), mixed[2][0]);
    try testing.expectEqual(@as(f32, 0.5), mixed[3][0]);
    const box: Rect = .{ .x1 = 100, .y1 = 100 };
    const placed = try fitRect(.{ 40, 20 }, box, .contain, .{ 0.5, 1 });
    try testing.expectEqual(Rect{ .x0 = 0, .y0 = 50, .x1 = 100, .y1 = 100 }, placed);
    const repeated: Brush = .{ .image = .{ .image = image, .source = .{ .x1 = 2, .y1 = 1 }, .destination = .{ .x1 = 2, .y1 = 1 }, .area = .{ .x1 = 10, .y1 = 1 }, .repeat = .{ .space, .none }, .sampling = .nearest } };
    try validate(repeated);
    try testing.expectEqual(sample(repeated, simd.f(1.5), simd.f(0.5)), sample(repeated, simd.f(9.5), simd.f(0.5)));
}

test "nine slice consumes fractional and large destination cuts" {
    const pixels: [100]u32 = @splat(0xffffffff);
    var out: [9]ImageBrush = undefined;
    const slices = try nineSlice(.{ .pixels = &pixels, .width = 10, .height = 10, .stride = 10 }, .{ .x1 = 10, .y1 = 10 }, .{ .x1 = 1000, .y1 = 1000 }, .{ 2, 2, 2, 2 }, .{ 300.5, 300.5, 300.5, 300.5 }, .{ .round, .space }, false, .linear, &out);
    try testing.expectEqual(@as(usize, 8), slices.len);
    try testing.expectEqual(@as(f32, 300.5), slices[0].destination.x1);
    try testing.expectEqual(Repeat.round, slices[1].repeat[0]);
}
