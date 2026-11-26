//! Specialist image filters built from the same caller-owned surfaces. These operations are
//! opt-in CPU passes, not implicit work attached to every node. Kernels, component tables and
//! storage are supplied by the application; an unsupported resource size is an explicit error.
//! Algorithms correspond to the primitive families in https://www.w3.org/TR/filter-effects-1/;
//! noise is deterministic gradient noise, not a claim of SVG's legacy seed-table bit parity.

const std = @import("std");
const simd = @import("../core/simd.zig");
const surface = @import("surface.zig");
const brushes = @import("brushes.zig");
const compositor = @import("compositor.zig");
const color = @import("color_math.zig");
const F = simd.F;
const Batch = surface.Batch;

pub const Error = surface.Error || error{ InvalidFilter, InvalidColor };
pub const Kernel = struct {
    values: []const f32,
    width: u32,
    height: u32,
    anchor: [2]u32,
    divisor: f32 = 1,
    bias: f32 = 0,
    preserve_alpha: bool = false,
    space: compositor.FilterSpace = .linear_srgb,
    edge: [2]brushes.Address = .{ .clamp, .clamp },
};
pub const Component = union(enum) {
    identity,
    table: []const f32,
    discrete: []const f32,
    linear: struct { slope: f32 = 1, intercept: f32 = 0 },
    gamma: struct { amplitude: f32 = 1, exponent: f32 = 1, offset: f32 = 0 },
};
pub const Noise = struct {
    frequency: [2]f32 = .{ 0.05, 0.05 },
    octaves: u8 = 4,
    seed: u32 = 0,
    turbulence: bool = false,
    /// A nonzero period repeats lattice coordinates. Choosing integer frequency*image-size
    /// periods gives a seamless tile; the period doubles per octave with the frequency.
    period: [2]u32 = .{ 0, 0 },
};
pub const Light = union(enum) {
    /// Vector pointing from the surface toward the light, in pixel coordinates.
    distant: [3]f32,
    point: [3]f32,
    spot: struct { position: [3]f32, target: [3]f32, exponent: f32 = 1, cone_radians: f32 = std.math.pi / 2.0 },
};
pub const Lighting = struct {
    light: Light,
    /// RGB light color; alpha must be one. Apply group opacity after lighting if needed.
    color: color.Rgba = .{ 1, 1, 1, 1 },
    surface_scale: f32 = 1,
    constant: f32 = 1,
    /// Null selects diffuse Lambert lighting; otherwise this is the specular exponent.
    specular_exponent: ?f32 = null,
};

inline fn power(value: F, exponent: f32) F {
    return @select(f32, value > simd.f(0), @exp(@log(@max(value, simd.f(1e-30))) * simd.f(exponent)), simd.f(0));
}
inline fn decode(value: F) F {
    return @select(f32, value <= simd.f(0.04045), value / simd.f(12.92), power((value + simd.f(0.055)) / simd.f(1.055), 2.4));
}
inline fn encode(value: F) F {
    return @select(f32, value <= simd.f(0.0031308), value * simd.f(12.92), simd.f(1.055) * power(value, 1.0 / 2.4) - simd.f(0.055));
}

fn filterInput(dst: surface.Surface, src: surface.Image) Error!void {
    try dst.validate();
    try src.validate();
    if (surface.overlaps(dst.pixels, src.pixels)) return error.AliasedStorage;
}

/// General signed 2D convolution. With preserve_alpha, convolution operates on straight RGB
/// while original alpha is retained. Otherwise the working-space channels are premultiplied.
/// `anchor` names the kernel tap aligned with the current output pixel.
pub fn convolve(dst: surface.Surface, src: surface.Image, kernel: Kernel) Error!void {
    try filterInput(dst, src);
    if (kernel.width == 0 or kernel.height == 0 or kernel.anchor[0] >= kernel.width or kernel.anchor[1] >= kernel.height) return error.InvalidFilter;
    const taps = std.math.mul(usize, kernel.width, kernel.height) catch return error.InvalidFilter;
    if (kernel.values.len != taps or !std.math.isFinite(kernel.divisor) or kernel.divisor == 0 or !std.math.isFinite(kernel.bias)) return error.InvalidFilter;
    for (kernel.values) |v| if (!std.math.isFinite(v)) return error.InvalidFilter;
    for (0..dst.height) |y| {
        var x: usize = 0;
        while (x < simd.padded(dst.width)) : (x += simd.lanes) {
            const xx = @as(F, @floatFromInt(simd.iota + simd.u(@intCast(x)))) + simd.f(0.5);
            const yy = simd.f(@as(f32, @floatFromInt(y)) + 0.5);
            var sum: Batch = @splat(simd.f(0));
            for (0..kernel.height) |ky| for (0..kernel.width) |kx| {
                const sx = xx + simd.f(@as(f32, @floatFromInt(kx)) - @as(f32, @floatFromInt(kernel.anchor[0])));
                const sy = yy + simd.f(@as(f32, @floatFromInt(ky)) - @as(f32, @floatFromInt(kernel.anchor[1])));
                var sample = surface.unpremultiply(brushes.sampleImage(src, sx, sy, .nearest, kernel.edge));
                if (kernel.space == .linear_srgb) inline for (0..3) |c| {
                    sample[c] = decode(sample[c]);
                };
                if (!kernel.preserve_alpha) sample = surface.premultiply(sample);
                const weight = kernel.values[ky * kernel.width + kx] / kernel.divisor;
                inline for (0..4) |c| sum[c] += sample[c] * simd.f(weight);
            };
            if (kernel.preserve_alpha) {
                sum[3] = brushes.sampleImage(src, xx, yy, .nearest, kernel.edge)[3];
                inline for (0..3) |c| sum[c] = @min(@max(sum[c] + simd.f(kernel.bias), simd.f(0)), simd.f(1));
            } else {
                sum[3] = @min(@max(sum[3] + simd.f(kernel.bias), simd.f(0)), simd.f(1));
                inline for (0..3) |c| sum[c] = @min(@max(sum[c] + simd.f(kernel.bias) * sum[3], simd.f(0)), sum[3]) / @max(sum[3], simd.f(1e-20));
            }
            if (kernel.space == .linear_srgb) inline for (0..3) |c| {
                sum[c] = encode(sum[c]);
            };
            surface.store(dst, x, y, surface.premultiply(sum));
        }
    }
}

fn validateComponent(component: Component) Error!void {
    switch (component) {
        .identity => {},
        .table, .discrete => |values| {
            if (values.len == 0 or values.len > std.math.maxInt(u32)) return error.InvalidFilter;
            for (values) |v| if (!std.math.isFinite(v)) return error.InvalidFilter;
        },
        .linear => |p| if (!std.math.isFinite(p.slope) or !std.math.isFinite(p.intercept)) return error.InvalidFilter,
        .gamma => |p| if (!std.math.isFinite(p.amplitude) or !std.math.isFinite(p.exponent) or p.exponent < 0 or !std.math.isFinite(p.offset)) return error.InvalidFilter,
    }
}

fn transfer(value: F, component: Component) F {
    return switch (component) {
        .identity => value,
        .linear => |p| value * simd.f(p.slope) + simd.f(p.intercept),
        .gamma => |p| simd.f(p.amplitude) * (if (p.exponent == 0) simd.f(1) else power(value, p.exponent)) + simd.f(p.offset),
        .table => |values| blk: {
            const position = value * simd.f(@floatFromInt(values.len - 1));
            const low = @floor(position);
            const low_index: simd.U = @intFromFloat(low);
            const high_index = @min(low_index + simd.u(1), simd.u(@intCast(values.len - 1)));
            var a: F = undefined;
            var b: F = undefined;
            inline for (0..simd.lanes) |lane| {
                a[lane] = values[low_index[lane]];
                b[lane] = values[high_index[lane]];
            }
            break :blk a + (b - a) * (position - low);
        },
        .discrete => |values| blk: {
            const index: simd.U = @intFromFloat(@min(@floor(value * simd.f(@floatFromInt(values.len))), simd.f(@floatFromInt(values.len - 1))));
            var out: F = undefined;
            inline for (0..simd.lanes) |lane| out[lane] = values[index[lane]];
            break :blk out;
        },
    };
}

pub fn componentTransfer(dst: surface.Surface, components: [4]Component, space: compositor.FilterSpace) Error!void {
    try dst.validate();
    for (components) |component| try validateComponent(component);
    for (0..dst.height) |y| {
        var x: usize = 0;
        while (x < simd.padded(dst.width)) : (x += simd.lanes) {
            var pixel = surface.unpremultiply(surface.load(dst, x, y));
            if (space == .linear_srgb) inline for (0..3) |c| {
                pixel[c] = decode(pixel[c]);
            };
            inline for (0..4) |c| pixel[c] = @min(@max(transfer(pixel[c], components[c]), simd.f(0)), simd.f(1));
            if (space == .linear_srgb) inline for (0..3) |c| {
                pixel[c] = encode(pixel[c]);
            };
            surface.store(dst, x, y, surface.premultiply(pixel));
        }
    }
}

inline fn hash(x: simd.U, y: simd.U, seed: u32) simd.U {
    var v = (x *% simd.u(0x9e3779b1)) ^ (y *% simd.u(0x85ebca77)) ^ simd.u(seed);
    v = (v ^ (v >> simd.u(16))) *% simd.u(0x7feb352d);
    v = (v ^ (v >> simd.u(15))) *% simd.u(0x846ca68b);
    return v ^ (v >> simd.u(16));
}
inline fn periodic(index: simd.U, period: u32) simd.U {
    return if (period == 0) index else index % simd.u(period);
}
inline fn gradient(ix: simd.U, iy: simd.U, x: F, y: F, seed: u32, period: [2]u32) F {
    const bits = hash(periodic(ix, period[0]), periodic(iy, period[1]), seed);
    const gx = @select(f32, (bits & simd.u(1)) == simd.u(0), x, -x);
    const gy = @select(f32, (bits & simd.u(2)) == simd.u(0), y, -y);
    return (gx + gy) * simd.f(0.7071067811865476);
}
inline fn fade(v: F) F {
    return v * v * v * (v * (v * simd.f(6) - simd.f(15)) + simd.f(10));
}
fn noiseAt(x: F, y: F, seed: u32, period: [2]u32) F {
    const fx = @floor(x);
    const fy = @floor(y);
    const ix: simd.U = @intFromFloat(fx);
    const iy: simd.U = @intFromFloat(fy);
    const px = x - fx;
    const py = y - fy;
    const u = fade(px);
    const v = fade(py);
    const a = gradient(ix, iy, px, py, seed, period);
    const b = gradient(ix +% simd.u(1), iy, px - simd.f(1), py, seed, period);
    const c = gradient(ix, iy +% simd.u(1), px, py - simd.f(1), seed, period);
    const d = gradient(ix +% simd.u(1), iy +% simd.u(1), px - simd.f(1), py - simd.f(1), seed, period);
    return (a + (b - a) * u) * (simd.f(1) - v) + (c + (d - c) * u) * v;
}

/// Four decorrelated gradient-noise channels, with RGB premultiplied by the generated alpha.
/// Octaves are bounded explicitly (1..16); frequency must keep coordinates representable.
pub fn turbulence(dst: surface.Surface, options: Noise) Error!void {
    try dst.validate();
    if (options.octaves == 0 or options.octaves > 16) return error.InvalidFilter;
    const multiplier: f32 = @floatFromInt(@as(u32, 1) << @as(u5, @intCast(options.octaves - 1)));
    for (options.frequency, 0..) |frequency, axis| {
        const dimension = if (axis == 0) dst.width else dst.height;
        if (!std.math.isFinite(frequency) or frequency <= 0 or frequency * multiplier * @as(f32, @floatFromInt(dimension + simd.lanes)) >= 4_000_000_000) return error.InvalidFilter;
        if (@as(u64, options.period[axis]) * @as(u64, @intFromFloat(multiplier)) > std.math.maxInt(u32)) return error.InvalidFilter;
    }
    for (0..dst.height) |y| {
        var x: usize = 0;
        while (x < simd.padded(dst.width)) : (x += simd.lanes) {
            const xx = @as(F, @floatFromInt(simd.iota + simd.u(@intCast(x)))) + simd.f(0.5);
            const yy = simd.f(@as(f32, @floatFromInt(y)) + 0.5);
            var sum: Batch = @splat(simd.f(0));
            var amplitude: f32 = 1;
            var total: f32 = 0;
            var frequency = options.frequency;
            var period = options.period;
            for (0..options.octaves) |_| {
                inline for (0..4) |c| {
                    const value = noiseAt(xx * simd.f(frequency[0]), yy * simd.f(frequency[1]), options.seed +% @as(u32, c) *% 0x9e3779b9, period);
                    sum[c] += simd.f(amplitude) * (if (options.turbulence) @abs(value) else value);
                }
                total += amplitude;
                amplitude *= 0.5;
                frequency[0] *= 2;
                frequency[1] *= 2;
                period[0] *%= 2;
                period[1] *%= 2;
            }
            inline for (0..4) |c| sum[c] = @min(@max(if (options.turbulence) sum[c] / simd.f(total) else sum[c] / simd.f(total) + simd.f(0.5), simd.f(0)), simd.f(1));
            surface.store(dst, x, y, surface.premultiply(sum));
        }
    }
}

inline fn normalize3(v: [3]F) [3]F {
    const reciprocal = simd.f(1) / @sqrt(@max(v[0] * v[0] + v[1] * v[1] + v[2] * v[2], simd.f(1e-20)));
    return .{ v[0] * reciprocal, v[1] * reciprocal, v[2] * reciprocal };
}
inline fn dot3(a: [3]F, b: [3]F) F {
    return a[0] * b[0] + a[1] * b[1] + a[2] * b[2];
}
fn valid3(v: [3]f32) bool {
    return std.math.isFinite(v[0]) and std.math.isFinite(v[1]) and std.math.isFinite(v[2]);
}

pub fn lighting(dst: surface.Surface, height_map: surface.Image, options: Lighting) Error!void {
    try filterInput(dst, height_map);
    if (!std.math.isFinite(options.surface_scale) or !std.math.isFinite(options.constant) or options.constant < 0 or !color.finite(options.color) or options.color[3] != 1) return error.InvalidFilter;
    if (options.specular_exponent) |exponent| if (!std.math.isFinite(exponent) or exponent < 1 or exponent > 128) return error.InvalidFilter;
    switch (options.light) {
        .distant, .point => |p| if (!valid3(p)) return error.InvalidFilter,
        .spot => |s| if (!valid3(s.position) or !valid3(s.target) or !std.math.isFinite(s.exponent) or s.exponent < 0 or !std.math.isFinite(s.cone_radians) or s.cone_radians < 0 or s.cone_radians > std.math.pi) return error.InvalidFilter,
    }
    for (0..dst.height) |y| {
        var x: usize = 0;
        while (x < simd.padded(dst.width)) : (x += simd.lanes) {
            const xx = @as(F, @floatFromInt(simd.iota + simd.u(@intCast(x)))) + simd.f(0.5);
            const yy = simd.f(@as(f32, @floatFromInt(y)) + 0.5);
            const middle = brushes.sampleImage(height_map, xx, yy, .nearest, .{ .clamp, .clamp })[3] * simd.f(options.surface_scale);
            const left = brushes.sampleImage(height_map, xx - simd.f(1), yy, .nearest, .{ .clamp, .clamp })[3];
            const right = brushes.sampleImage(height_map, xx + simd.f(1), yy, .nearest, .{ .clamp, .clamp })[3];
            const top = brushes.sampleImage(height_map, xx, yy - simd.f(1), .nearest, .{ .clamp, .clamp })[3];
            const bottom = brushes.sampleImage(height_map, xx, yy + simd.f(1), .nearest, .{ .clamp, .clamp })[3];
            const normal = normalize3(.{ (left - right) * simd.f(options.surface_scale * 0.5), (top - bottom) * simd.f(options.surface_scale * 0.5), simd.f(1) });
            const direction = switch (options.light) {
                .distant => |d| normalize3(.{ simd.f(d[0]), simd.f(d[1]), simd.f(d[2]) }),
                .point => |p| normalize3(.{ simd.f(p[0]) - xx, simd.f(p[1]) - yy, simd.f(p[2]) - middle }),
                .spot => |s| normalize3(.{ simd.f(s.position[0]) - xx, simd.f(s.position[1]) - yy, simd.f(s.position[2]) - middle }),
            };
            var intensity = simd.f(options.constant);
            if (options.light == .spot) {
                const s = options.light.spot;
                const axis = normalize3(.{ simd.f(s.target[0] - s.position[0]), simd.f(s.target[1] - s.position[1]), simd.f(s.target[2] - s.position[2]) });
                const alignment = -dot3(direction, axis);
                intensity *= @select(f32, alignment >= simd.f(@cos(s.cone_radians)), if (s.exponent == 0) simd.f(1) else power(@max(alignment, simd.f(0)), s.exponent), simd.f(0));
            }
            if (options.specular_exponent) |exponent| {
                const halfway = normalize3(.{ direction[0], direction[1], direction[2] + simd.f(1) });
                intensity *= power(@max(dot3(normal, halfway), simd.f(0)), exponent);
            } else intensity *= @max(dot3(normal, direction), simd.f(0));
            var out: Batch = undefined;
            inline for (0..3) |c| out[c] = @min(@max(intensity * simd.f(options.color[c]), simd.f(0)), simd.f(1));
            out[3] = if (options.specular_exponent != null) @max(@max(out[0], out[1]), out[2]) else simd.f(1);
            // Filter-light RGB is already premultiplied by the specular alpha definition.
            surface.store(dst, x, y, out);
        }
    }
}

pub fn arithmetic(dst: surface.Surface, a: surface.Image, b: surface.Image, coefficients: [4]f32) Error!void {
    try filterInput(dst, a);
    try b.validate();
    if (surface.overlaps(dst.pixels, b.pixels)) return error.AliasedStorage;
    for (coefficients) |v| if (!std.math.isFinite(v)) return error.InvalidFilter;
    for (0..dst.height) |y| {
        var x: usize = 0;
        while (x < simd.padded(dst.width)) : (x += simd.lanes) {
            const xx = @as(F, @floatFromInt(simd.iota + simd.u(@intCast(x)))) + simd.f(0.5);
            const yy = simd.f(@as(f32, @floatFromInt(y)) + 0.5);
            const aa = brushes.sampleImage(a, xx, yy, .nearest, .{ .transparent, .transparent });
            const bb = brushes.sampleImage(b, xx, yy, .nearest, .{ .transparent, .transparent });
            var out: Batch = undefined;
            inline for (0..4) |c| out[c] = @min(@max(simd.f(coefficients[0]) * aa[c] * bb[c] + simd.f(coefficients[1]) * aa[c] + simd.f(coefficients[2]) * bb[c] + simd.f(coefficients[3]), simd.f(0)), simd.f(1));
            out[3] = @max(out[3], @max(@max(out[0], out[1]), out[2]));
            surface.store(dst, x, y, out);
        }
    }
}

const testing = std.testing;

test "signed convolution and component tables are real filter consumers" {
    var pixels: [simd.rows(3)]u32 = undefined;
    const dst = try surface.init(&pixels, 3, 1);
    const src = [_]u32{ 0xff000000, 0xffffffff, 0xff000000 };
    try convolve(dst, .{ .pixels = &src, .width = 3, .height = 1, .stride = 3 }, .{ .values = &.{ -1, 2, -1 }, .width = 3, .height = 1, .anchor = .{ 1, 0 }, .preserve_alpha = true, .space = .srgb });
    try testing.expectEqual(@as(u32, 0xffffffff), dst.pixels[1]);
    try testing.expectEqual(@as(u32, 0xff000000), dst.pixels[0]);
    try componentTransfer(dst, .{ .{ .table = &.{ 1, 0 } }, .{ .discrete = &.{ 1, 0 } }, .{ .linear = .{ .slope = -1, .intercept = 1 } }, .{ .gamma = .{ .amplitude = 0.5 } } }, .srgb);
    try testing.expectEqual(@as(u32, 0x80000000), dst.pixels[1]);
    try testing.expectEqual(@as(u32, 0x80808080), dst.pixels[0]);
}

test "noise is repeatable and supplied seed changes generated pixels" {
    var a: [simd.rows(8) * 8]u32 = undefined;
    var b: [simd.rows(8) * 8]u32 = undefined;
    const one = try surface.init(&a, 8, 8);
    const two = try surface.init(&b, 8, 8);
    const options: Noise = .{ .frequency = .{ 0.5, 0.5 }, .seed = 31, .period = .{ 4, 4 } };
    try turbulence(one, options);
    try turbulence(two, options);
    try testing.expectEqualSlices(u32, one.pixels, two.pixels);
    try turbulence(two, .{ .frequency = .{ 0.5, 0.5 }, .seed = 32, .period = .{ 4, 4 } });
    try testing.expect(!std.mem.eql(u32, one.pixels, two.pixels));
}

test "distant point spot diffuse and specular lights shade an alpha height field" {
    var pixels: [simd.rows(3) * 3]u32 = undefined;
    const dst = try surface.init(&pixels, 3, 3);
    const heights: [9]u32 = @splat(0xffffffff);
    const source: surface.Image = .{ .pixels = &heights, .width = 3, .height = 3, .stride = 3 };
    try lighting(dst, source, .{ .light = .{ .distant = .{ 0, 0, 1 } }, .color = .{ 1, 0, 0, 1 } });
    try testing.expectEqual(@as(u32, 0xff0000ff), dst.pixels[dst.stride + 1]);
    try lighting(dst, source, .{ .light = .{ .point = .{ 1.5, 1.5, 10 } }, .specular_exponent = 8 });
    try testing.expectEqual(@as(u32, 0xffffffff), dst.pixels[dst.stride + 1]);
    try lighting(dst, source, .{ .light = .{ .spot = .{ .position = .{ 1.5, 1.5, 10 }, .target = .{ 1.5, 1.5, 0 }, .cone_radians = 0.1 } } });
    try testing.expectEqual(@as(u32, 0xffffffff), dst.pixels[dst.stride + 1]);
    try arithmetic(dst, source, source, .{ 0, 0.25, 0.25, 0 });
    try testing.expectEqual(@as(u32, 0x80808080), dst.pixels[dst.stride + 1]);
}
