//! The software back end: draws a `DrawList` into a caller-owned framebuffer on the CPU, with the
//! semantics of the stock quad shader (src/render/shaders/quad.wgsl) so its pixels match the GPU
//! back ends' golden images. No GPU, no allocation, no OS.
//!
//! Framebuffer rows are padded to whole vectors, so every span is whole vectors with a mask for
//! the pixels outside the quad or the scissor; there is no scalar tail.

const std = @import("std");
const simd = @import("../../core/simd.zig");
const types = @import("../../core/types.zig");
const draw_list = @import("../../draw/draw_list.zig");
const iface = @import("../iface.zig");
const Color = types.Color;
const Quad = draw_list.Quad;
const DrawList = draw_list.DrawList;

const W = simd.lanes;
const U = simd.U;
const B = simd.B;

/// Byte order of a pixel in memory.
pub const Format = enum(u8) { rgba8, bgra8 };

/// The render target: `height` rows of `stride` pixels, one u32 each, owned by the caller.
pub const Framebuffer = struct {
    pixels: []u32,
    width: u32,
    height: u32,
    /// `width` padded to whole vectors (`simd.padded`); pixels past `width` are scratch.
    stride: u32,
    format: Format,

    /// Pixels a `width` x `height` framebuffer needs.
    pub fn len(width: u32, height: u32) usize {
        return simd.padded(width) * height;
    }

    pub fn init(pixels: []u32, width: u32, height: u32, format: Format) Framebuffer {
        std.debug.assert(pixels.len >= len(width, height));
        return .{ .pixels = pixels, .width = width, .height = height, .stride = @intCast(simd.padded(width)), .format = format };
    }

    /// Whole framebuffer as a scissor rect.
    pub fn all(fb: *const Framebuffer) [4]u32 {
        return .{ 0, 0, fb.width, fb.height };
    }

    /// Shift of red in a pixel; blue sits at 16 minus it.
    inline fn red(fb: *const Framebuffer) u5 {
        return @as(u5, @intFromBool(fb.format == .bgra8)) * 16;
    }

    /// `c` in this framebuffer's byte order.
    pub fn pack(fb: *const Framebuffer, c: Color) u32 {
        const r = fb.red();
        return (@as(u32, c.r) << r) | (@as(u32, c.g) << 8) | (@as(u32, c.b) << (16 - r)) | (@as(u32, c.a) << 24);
    }

    /// Pixel (x, y) as a colour.
    pub fn at(fb: *const Framebuffer, x: u32, y: u32) Color {
        const p = fb.pixels[y * fb.stride + x];
        const r = fb.red();
        return .{ .r = @truncate(p >> r), .g = @truncate(p >> 8), .b = @truncate(p >> (16 - r)), .a = @truncate(p >> 24) };
    }

    /// Sets every pixel of `box` (x0, y0, x1, y1, clamped to the framebuffer) to `c`.
    pub fn fill(fb: *Framebuffer, box: [4]u32, c: Color) void {
        const b = clampBox(box, fb.all());
        const v: U = @splat(fb.pack(c));
        for (b[1]..b[3]) |y| {
            const row = fb.pixels[y * fb.stride ..][0..fb.stride];
            var x = std.mem.alignBackward(u32, b[0], W);
            while (x < b[2]) : (x += W) {
                const in = spanMask(x, b[0], b[2]);
                row[x..][0..W].* = @select(u32, in, v, @as(U, row[x..][0..W].*));
            }
        }
    }

    pub fn clear(fb: *Framebuffer, c: Color) void {
        fb.fill(fb.all(), c);
    }
};

/// Where draws land: the framebuffer and a scissor rect in pixels (x0, y0, x1, y1). Pixels outside
/// the scissor are never written, which is what splits a frame into damage rects and tiles.
pub const Target = struct {
    fb: *Framebuffer,
    scissor: [4]u32,
};

pub const Software = struct {
    pub const Queue = void;
    pub const Pass = Target;

    /// The frame's quads and glyphs, borrowed from the caller until the frame is drawn.
    quads: []const Quad = &.{},
    glyphs: iface.Glyphs = .{},
    /// Physical pixels per logical pixel.
    scale: f32 = 1,

    /// Nothing to upload: the back end reads the caller's rows in place.
    pub fn prepare(s: *Software, _: void, draw: *const DrawList, glyphs: iface.Glyphs, _: [2]f32, scale: f32) void {
        s.quads = draw.quads[0..draw.quad_len];
        s.glyphs = glyphs;
        s.scale = scale;
    }

    pub fn drawBatch(s: *const Software, t: Target, batch: draw_list.Batch) void {
        s.drawQuads(t, s.quads[batch.first..][0..batch.count]);
    }

    /// Glyphs need the atlas texture: not drawn yet.
    pub fn drawText(_: *const Software, _: Target, _: u32) void {}

    fn drawQuads(s: *const Software, t: Target, quads: []const Quad) void {
        for (quads) |*q| {
            // Other quads need blending: not drawn yet.
            if (opaqueRect(q, s.scale)) t.fb.fill(clampBox(coveredPixels(q, s.scale), t.scissor), @bitCast(q.fill));
        }
    }
};

comptime {
    iface.check(Software);
}

fn clampBox(a: [4]u32, b: [4]u32) [4]u32 {
    const lo = @max(a[0], b[0]);
    const top = @max(a[1], b[1]);
    return .{ lo, top, @max(@min(a[2], b[2]), lo), @max(@min(a[3], b[3]), top) };
}

/// Lanes of the vector at `x` whose pixel lies in [x0, x1).
inline fn spanMask(x: u32, x0: u32, x1: u32) B {
    const xs = simd.iota + simd.u(x);
    return (xs >= simd.u(x0)) & (xs < simd.u(x1));
}

/// True when `q` covers whole pixels with one opaque colour: no feature, transform,
/// rounding, border or translucency, and edges on pixel boundaries. Its pixels are then the
/// colour itself, exactly as the shader would write them, and need no shading or blending.
fn opaqueRect(q: *const Quad, scale: f32) bool {
    const r: @Vector(4, f32) = q.rect;
    const s: @Vector(4, f32) = r * @as(@Vector(4, f32), @splat(scale));
    const zero: @Vector(4, f32) = @splat(0);
    const xform: [6]f32 = q.xform;
    return @as(u32, @bitCast(q.params[0])) == 0 and
        std.mem.eql(f32, &xform, &.{ 1, 0, 0, 1, 0, 0 }) and
        @reduce(.And, @as(@Vector(4, f32), q.radii) <= zero) and @reduce(.And, @as(@Vector(4, f32), q.clip_radii) <= zero) and
        q.border < 0.001 and q.opacity == 1 and (q.fill >> 24) == 255 and @reduce(.And, @floor(s) == s);
}

/// Pixels whose centres lie in `q.rect`.
fn coveredPixels(q: *const Quad, scale: f32) [4]u32 {
    const rect = @as(@Vector(4, f32), q.rect) * @as(@Vector(4, f32), @splat(scale));
    return toPixels(rect);
}

/// Logical box (x0, y0, x1, y1) in pixels, floored and clamped to [0, 2^24].
fn toPixels(box: [4]f32) [4]u32 {
    const v = @min(@max(@floor(@as(@Vector(4, f32), box)), @as(@Vector(4, f32), @splat(0))), @as(@Vector(4, f32), @splat(1 << 24)));
    const p: @Vector(4, u32) = @intFromFloat(v);
    return p;
}

const testing = std.testing;

fn Frame(comptime w: u32, comptime h: u32) type {
    return struct {
        px: [Framebuffer.len(w, h)]u32 = undefined,
        fn fb(f: *@This(), format: Format) Framebuffer {
            return .init(&f.px, w, h, format);
        }
    };
}

fn testQuad(rect: [4]f32, fill: Color) Quad {
    return .{ .rect = rect, .clip = .{ -1e6, -1e6, 1e6, 1e6 }, .params = @splat(0), .uv = .{ 0, 0, 1, 1 }, .radii = @splat(0), .fill = fill.bitsOf(), .border_color = 0, .border = 0, .opacity = 1 };
}

test "framebuffer: RGBA8 and BGRA8 byte order, rows padded to whole vectors" {
    var f: Frame(5, 3) = .{};
    for ([_]Format{ .rgba8, .bgra8 }) |format| {
        var fb = f.fb(format);
        try testing.expectEqual(simd.padded(5), fb.stride);
        fb.clear(.rgba(1, 2, 3, 4));
        fb.fill(.{ 1, 1, 9, 2 }, .rgba(10, 20, 30, 40));
        try testing.expectEqual(Color.rgba(1, 2, 3, 4), fb.at(0, 1));
        try testing.expectEqual(Color.rgba(10, 20, 30, 40), fb.at(4, 1));
        try testing.expectEqual(Color.rgba(1, 2, 3, 4), fb.at(1, 2));
        const bytes: [4]u8 = @bitCast(fb.pixels[fb.stride + 1]);
        const want: [4]u8 = if (format == .rgba8) .{ 10, 20, 30, 40 } else .{ 30, 20, 10, 40 };
        try testing.expectEqual(want, bytes);
    }
}

test "opaque rects: filled exactly, cut by the scissor" {
    var f: Frame(16, 8) = .{};
    var fb = f.fb(.rgba8);
    fb.clear(.black);
    var q = testQuad(.{ 2, 1, 14, 7 }, .rgb(200, 100, 50));
    try testing.expect(opaqueRect(&q, 1));
    const s: Software = .{ .quads = &.{q} };
    s.drawBatch(.{ .fb = &fb, .scissor = .{ 0, 0, 16, 5 } }, .{ .first = 0, .count = 1, .texture = .white, .material = .solid });
    // Rows 1 .. 4 are inside the scissor.
    for (0..8) |y| for (0..16) |x| {
        const in = x >= 2 and x < 14 and y >= 1 and y < 5;
        try testing.expectEqual(if (in) Color.rgb(200, 100, 50) else Color.black, fb.at(@intCast(x), @intCast(y)));
    };
}
