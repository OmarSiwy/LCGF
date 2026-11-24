//! The software back end: draws a `DrawList` into a caller-owned framebuffer on the CPU, with the
//! semantics of the stock quad shader (src/render/shaders/quad.wgsl) so its pixels match the GPU
//! back ends' golden images (`ci/run.sh sw-golden`). No GPU, no allocation, no OS.
//!
//! Each quad is shaded over the pixels of its bounding box, `simd.lanes` pixels of one row at a
//! time, with the shader's math as vector expressions: rounded-box distance, border, clip and
//! rounded clip as coverage, the per-quad feature of `params.x`, then premultiplied "over"
//! blending (Porter and Duff 1984: out = src + dst * (1 - src.a)). Per pixel there is no branch;
//! batches specialize white bindings and each quad picks the loop for its material and geometry.
//! Ordinary textured rectangles (including glyph cells) omit inactive transform, border and
//! rounded-clip work, while preserving the same coverage, sampling and blend arithmetic.
//! Opaque panels fill a proven full-coverage interior and shade the unchanged perimeter.
//!
//! Framebuffer rows are padded to whole vectors, so shading uses whole vectors with a mask for
//! the pixels outside the quad or the scissor.

const std = @import("std");
const simd = @import("../../core/simd.zig");
const types = @import("../../core/types.zig");
const draw_list = @import("../../draw/draw_list.zig");
const damage = @import("../../draw/damage.zig");
const features = @import("../../draw/features.zig");
const iface = @import("../iface.zig");
const Color = types.Color;
const Quad = draw_list.Quad;
const DrawList = draw_list.DrawList;

const W = simd.lanes;
const F = simd.F;
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
        if (b[0] == b[2]) return;
        const color: U = @splat(fb.pack(c));
        const head = std.mem.alignBackward(u32, b[0], W);
        const tail = std.mem.alignBackward(u32, b[2] - 1, W);
        // For a single-vector span both masks select the same pixels.
        const head_mask = spanMask(head, b[0], b[2]);
        const tail_mask = spanMask(tail, b[0], b[2]);
        const stride: usize = fb.stride;
        const end = stride * b[3];
        var start = stride * b[1];
        while (start < end) : (start += stride) {
            const row = fb.pixels[start..][0..stride];
            const first = row[head..][0..W];
            first.* = @select(u32, head_mask, color, @as(U, first.*));
            var x = head + W;
            while (x < tail) : (x += W) row[x..][0..W].* = color;
            const last = row[tail..][0..W];
            last.* = @select(u32, tail_mask, color, @as(U, last.*));
        }
    }

    fn solid(fb: *Framebuffer, box: [4]u32, c: Color) void {
        if (c.a == 255) fb.fill(box, c) else fb.blend(box, c);
    }

    /// A solid translucent rectangle with full pixel coverage. Each pair of
    /// 8-bit channels is multiplied in parallel in two independent u16 fields.
    fn blend(fb: *Framebuffer, box: [4]u32, c: Color) void {
        const b = clampBox(box, fb.all());
        if (b[0] == b[2]) return;
        const a: u32 = c.a;
        const source = fb.pack(.rgba(c.r, c.g, c.b, 255));
        const mask = simd.u(0x00ff00ff);
        const rb = simd.u((source & 0x00ff00ff) * a);
        const ga = simd.u(((source >> 8) & 0x00ff00ff) * a);
        const inv = simd.u(255 - a);
        for (b[1]..b[3]) |y| {
            const row = fb.pixels[y * fb.stride ..][0..fb.stride];
            var x = std.mem.alignBackward(u32, b[0], W);
            while (x < b[2]) : (x += W) {
                const old: U = row[x..][0..W].*;
                const lo = rb + (old & mask) * inv;
                const hi = ga + ((old >> @splat(8)) & mask) * inv;
                const result = div255(lo) | (div255(hi) << @splat(8));
                row[x..][0..W].* = @select(u32, spanMask(x, b[0], b[2]), result, old);
            }
        }
    }

    /// round(x / 255), independently in both 16-bit fields, for 0 <= x <= 255².
    inline fn div255(x: U) U {
        const bias = x + simd.u(0x00800080);
        const mask = simd.u(0x00ff00ff);
        return ((bias + ((bias >> @splat(8)) & mask)) >> @splat(8)) & mask;
    }

    pub fn clear(fb: *Framebuffer, c: Color) void {
        fb.fill(fb.all(), c);
    }
};

/// Caller-owned nearest-sampled texture. Existing initializers use RGBA8 `pixels`
/// (`Color` bits). A nonempty `alpha8` instead supplies one coverage byte per texel
/// with implicit white RGB, avoiding an expanded RGBA copy for monochrome glyphs.
/// The selected slice has at least width * height elements and remains alive while
/// drawing. Alpha8 takes precedence when both slices are supplied.
/// Sampled dimensions must be positive; the selected slice must contain width * height texels.
pub const Image = struct {
    pixels: []const u32 = &.{},
    width: u32,
    height: u32,
    alpha8: []const u8 = &.{},

    /// Texture 0 (`types.Texture.white`): put it at row 0 of `Software.images`.
    pub const white: Image = .{ .pixels = &.{0xffff_ffff}, .width = 1, .height = 1 };
};

const ImageEncoding = enum { rgba8, alpha8 };

/// Where draws land: the framebuffer and a scissor rect in pixels (x0, y0, x1, y1). Pixels outside
/// the scissor are never written, which is what splits a frame into damage rects and tiles.
pub const Target = struct {
    fb: *Framebuffer,
    scissor: [4]u32,
};

/// The back end with every feature of the stock material compiled in.
pub const Software = SoftwareOf(all_kinds);

/// Every `features.Kind`, in declaration order.
pub const all_kinds: []const features.Kind = std.enums.values(features.Kind);

/// Colour of a quad whose feature this build left out: drawn over its covered pixels, opaque, so
/// a missing feature shows instead of turning into another one.
pub const missing_kind: Color = .rgb(255, 0, 255);

/// The back end compiled for the feature kinds in `kinds` only (`solid` must be one). Each kind
/// is its own shading loop (`shade`), and a loop no kind selects is not compiled: a build that
/// draws only solid quads leaves out the gradients' `sin`/`cos`, the shadow's `exp`, nine-slice
/// and the border patterns. A quad of a kind left out is filled with `missing_kind`.
pub fn SoftwareOf(comptime kinds: []const features.Kind) type {
    return SoftwareCoords(kinds, false);
}

/// Quantize bare-metal rectangle and clip coordinates to Q12.4 when requested.
pub fn SoftwareCoords(comptime kinds: []const features.Kind, comptime fixed_point: bool) type {
    var use = features.Usage.all;
    use.kinds = .initMany(kinds);
    return Renderer(use, fixed_point);
}

/// Software renderer for the features collected from a comptime UI.
pub fn SoftwareFor(comptime use: features.Usage) type {
    return Renderer(use, false);
}

fn Renderer(comptime use: features.Usage, comptime fixed_point: bool) type {
    comptime std.debug.assert(use.kinds.contains(.solid));
    return struct {
        const Self = @This();
        pub const Queue = void;
        pub const Pass = Target;

        /// The frame's quads and glyphs, borrowed from the caller until the frame is drawn.
        quads: []const Quad = &.{},
        glyphs: if (use.text) iface.Glyphs else void = if (use.text) .{} else {},
        /// Indexed by `types.Texture`; row 0 is `Image.white`.
        images: if (use.image or use.text) []const Image else void = if (use.image or use.text) &.{Image.white} else {},
        /// Physical pixels per logical pixel.
        scale: f32 = 1,

        /// Nothing to upload: the back end reads the caller's rows in place.
        pub fn prepare(s: *Self, _: void, draw: *const DrawList, glyphs: iface.Glyphs, _: [2]f32, scale: f32) void {
            s.quads = draw.quads[0..draw.quad_len];
            if (use.text) s.glyphs = glyphs;
            s.scale = scale;
        }

        pub fn drawBatch(s: *const Self, t: Target, batch: draw_list.Batch) void {
            const img = if (use.image) s.images[@backingInt(batch.texture)] else Image.white;
            s.drawQuads(t, s.quads[batch.first..][0..batch.count], img);
        }

        pub fn drawText(s: *const Self, t: Target, run: u32) void {
            if (!use.text) return;
            const g = s.glyphs;
            const r = g.span(run);
            s.drawQuads(t, g.quads[r[0]..][0..r[1]], s.images[@backingInt(g.texture)]);
        }

        fn drawQuads(s: *const Self, t: Target, quads: []const Quad, img: Image) void {
            // Texture binding is constant across the batch. A white binding has no
            // sampling work: retain the material and geometry, but compile out UV
            // conversion, gathers and channel unpacking for every covered pixel.
            // Keep `shade` as the complete shader reference for conformance tests.
            if (img.alpha8.len != 0) {
                s.drawQuadsUsing(use, .alpha8, t, quads, img);
            } else if (img.pixels.ptr == Image.white.pixels.ptr and img.width == 1 and img.height == 1) {
                const untextured = comptime blk: {
                    var value = use;
                    value.image = false;
                    value.text = false;
                    break :blk value;
                };
                s.drawQuadsUsing(untextured, .rgba8, t, quads, img);
            } else {
                s.drawQuadsUsing(use, .rgba8, t, quads, img);
            }
        }

        fn drawQuadsUsing(s: *const Self, comptime shading: features.Usage, comptime encoding: ImageEncoding, t: Target, quads: []const Quad, img: Image) void {
            for (quads) |*source| {
                var local: Quad = undefined;
                const q = if (fixed_point) q: {
                    const fixed = @import("../../embedded/fixed.zig");
                    local = source.*;
                    local.rect = fixed.decode(fixed.encode(local.rect));
                    local.clip = fixed.decode(fixed.encode(local.clip));
                    break :q &local;
                } else source;
                if (solidRect(q, img, s.scale)) {
                    const box = clampBox(coveredPixels(q, s.scale), t.scissor);
                    const color: Color = @bitCast(q.fill);
                    const radius = @reduce(.Max, @as(@Vector(4, f32), q.radii));
                    if (use.radius and radius > 0) {
                        // Only the four corner squares need the distance shader.
                        const center = clampBox(toPixels(.{
                            @ceil((q.rect[0] + radius) * s.scale),
                            @ceil((q.rect[1] + radius) * s.scale),
                            (q.rect[2] - radius) * s.scale,
                            (q.rect[3] - radius) * s.scale,
                        }), box);
                        for ([_][2]u32{ .{ box[1], center[1] }, .{ center[3], box[3] } }) |band| {
                            if (band[0] == band[1]) continue;
                            for ([_][2]u32{ .{ box[0], center[0] }, .{ center[2], box[2] } }) |corner| {
                                if (corner[0] == corner[1]) continue;
                                shadeFor(shading, .solid, encoding, .{ .fb = t.fb, .scissor = .{ corner[0], band[0], corner[1], band[1] } }, q, img, s.scale);
                            }
                            t.fb.solid(.{ center[0], band[0], center[2], band[1] }, color);
                        }
                        t.fb.solid(.{ box[0], center[1], box[2], center[3] }, color);
                    } else {
                        t.fb.solid(box, color);
                    }
                    continue;
                }
                if (comptime !(shading.image or shading.text)) {
                    if (opaqueInterior(q, img, s.scale)) |interior| {
                        // Preserve the full shader's loop box, including its final
                        // candidate pixel for fractional edges. Only coverage decides
                        // whether that pixel contributes.
                        const box = clampBox(toPixels(.{
                            @max(q.rect[0], q.clip[0]) * s.scale,
                            @max(q.rect[1], q.clip[1]) * s.scale,
                            @min(q.rect[2], q.clip[2]) * s.scale + 1,
                            @min(q.rect[3], q.clip[3]) * s.scale + 1,
                        }), t.scissor);
                        const center = clampBox(interior, box);
                        if (center[0] < center[2] and center[1] < center[3]) {
                            t.fb.fill(center, @bitCast(q.fill));
                            // Four disjoint bands plus the center cover the original box.
                            // Keep the original quad: only its scissor changes, so border
                            // color, corner coverage and clipping use the same shader math.
                            for ([_][4]u32{
                                .{ box[0], box[1], box[2], center[1] },
                                .{ box[0], center[3], box[2], box[3] },
                                .{ box[0], center[1], center[0], center[3] },
                                .{ center[2], center[1], box[2], center[3] },
                            }) |band| {
                                if (band[0] == band[2] or band[1] == band[3]) continue;
                                shadeFor(shading, .solid, encoding, .{ .fb = t.fb, .scissor = band }, q, img, s.scale);
                            }
                            continue;
                        }
                    }
                }
                if (comptime shading.image or shading.text) {
                    if (plainTexturedRect(shading, q)) {
                        shadeTexturedRect(encoding, t, q, img, s.scale);
                        continue;
                    }
                }
                // One loop per feature; unknown codes draw as solid, as the shader's selects do.
                const code: u32 = @bitCast(q.params[0]);
                switch (std.enums.fromInt(features.Kind, code) orelse .solid) {
                    inline else => |kind| if (comptime use.kinds.contains(kind))
                        shadeFor(shading, kind, encoding, t, q, img, s.scale)
                    else
                        t.fb.fill(clampBox(coveredPixels(q, s.scale), t.scissor), missing_kind),
                }
            }
        }

        /// Clears every damage rect of `draw` inside `scissor` to `background` and draws the whole
        /// list into it, leaving last frame's pixels everywhere else (`DrawList.damage`). Custom
        /// commands are skipped: a host with custom draws runs its own `iface.drawUntilCustom` loop
        /// per rect. Rects may overlap; a pixel in two is cleared and drawn twice, with the same result.
        pub fn redraw(s: *const Self, fb: *Framebuffer, scissor: [4]u32, draw: *const DrawList, background: Color) void {
            for (0..damage.max_rects) |k| {
                const r = damage.Region.scissor(draw.damage.rect(@intCast(k)), .{ fb.width, fb.height }, s.scale);
                const box = clampBox(.{ r[0], r[1], r[0] + r[2], r[1] + r[3] }, scissor);
                if (box[0] >= box[2] or box[1] >= box[3]) continue;
                fb.fill(box, background);
                iface.render(s, .{ .fb = fb, .scissor = box }, draw);
            }
        }
    };
}

comptime {
    iface.check(Software);
}

/// What a shell that draws in software keeps, and its frame: clear the framebuffer and draw the
/// whole list into it. Moved from the X11, Win32 and Wayland shells, which each repeated it;
/// the shell owns the pixels and shows them (PutImage, SetDIBitsToDevice, a wl_shm buffer).
pub const Setup = struct {
    gfx: Software = .{},

    pub fn draw(s: *Setup, fb: *Framebuffer, list: *const DrawList, glyphs: iface.Glyphs, background: Color, scale: f32) void {
        s.gfx.prepare({}, list, glyphs, .{ 0, 0 }, scale);
        fb.clear(background);
        iface.render(&s.gfx, .{ .fb = fb, .scissor = fb.all() }, list);
    }
};

/// Tile `k` of `n`: a band of whole rows. Bands share no pixel, so `n` threads may each draw one
/// (`Software.redraw` with the band as scissor) into the same framebuffer at once.
pub fn tile(fb: *const Framebuffer, k: u32, n: u32) [4]u32 {
    return .{ 0, fb.height * k / n, fb.width, fb.height * (k + 1) / n };
}

/// `a` cut to `b`. An `a` wholly past `b`'s right or bottom edge comes out empty at that edge,
/// not past it: the shade loop reads whole vectors from the box's start, so a start past the
/// row would read beyond it.
fn clampBox(a: [4]u32, b: [4]u32) [4]u32 {
    const lo = @min(@max(a[0], b[0]), b[2]);
    const top = @min(@max(a[1], b[1]), b[3]);
    return .{ lo, top, @max(@min(a[2], b[2]), lo), @max(@min(a[3], b[3]), top) };
}

/// Lanes of the vector at `x` whose pixel lies in [x0, x1).
inline fn spanMask(x: u32, x0: u32, x1: u32) B {
    const xs = simd.iota + simd.u(x);
    return (xs >= simd.u(x0)) & (xs < simd.u(x1));
}

/// True when `q` covers whole pixels with one colour: no feature, texture, transform,
/// rounded clip or border, and edges on pixel boundaries. Its own rounded corners need shading.
fn solidRect(q: *const Quad, img: Image, scale: f32) bool {
    const r: @Vector(4, f32) = q.rect;
    const s: @Vector(4, f32) = r * @as(@Vector(4, f32), @splat(scale));
    const zero: @Vector(4, f32) = @splat(0);
    const xform: [6]f32 = q.xform;
    return @as(u32, @bitCast(q.params[0])) == 0 and img.alpha8.len == 0 and img.pixels.ptr == Image.white.pixels.ptr and
        std.mem.eql(f32, &xform, &.{ 1, 0, 0, 1, 0, 0 }) and
        @reduce(.And, @as(@Vector(4, f32), q.clip_radii) <= zero) and
        q.border < 0.001 and q.opacity == 1 and @reduce(.And, @floor(s) == s);
}

/// An opaque interior whose coverage is proven in the shader's own f32 arithmetic.
/// Fractional scales and edges are allowed: only pixels far from the contour use
/// a fill, and an exact extrema check rejects a candidate that cannot be proved.
/// Zero and subthreshold border widths use the same conservative coverage proof.
fn opaqueInterior(q: *const Quad, img: Image, scale: f32) ?[4]u32 {
    const V = @Vector(4, f32);
    const zero: V = @splat(0);
    const color: Color = @bitCast(q.fill);
    if (@as(u32, @bitCast(q.params[0])) != 0 or img.alpha8.len != 0 or
        img.pixels.ptr != Image.white.pixels.ptr or img.width != 1 or img.height != 1 or
        color.a != 255 or q.opacity != 1 or
        !std.mem.eql(f32, &q.xform, &.{ 1, 0, 0, 1, 0, 0 }) or
        !@reduce(.And, @as(V, q.clip_radii) == zero)) return null;
    // These bounds reject nonfinite values and keep all later arithmetic finite.
    // Pixel centers below 2^24 are ordered in f32; the extrema proof below does
    // not assume a reciprocal or a fractional scale is represented exactly.
    if (!(scale >= 0.125 and scale <= 16)) return null;
    const s: V = @splat(scale);
    const rect = @as(V, q.rect) * s;
    const radii = @as(V, q.radii) * s;
    const border = q.border * scale;
    const clip = @as(V, q.clip) * s;
    const limit: V = @splat(1 << 16);
    if (!@reduce(.And, @abs(rect) <= limit) or
        rect[0] >= rect[2] or rect[1] >= rect[3] or
        !@reduce(.And, (radii >= zero) & (radii <= limit)) or
        !(q.border >= 0 and border <= (1 << 16)) or
        !@reduce(.And, @abs(clip) <= @as(V, @splat(1 << 22)))) return null;

    // This geometric inset only proposes a useful interior; it is not a floating
    // point tolerance. The proof below decides whether every included sample has
    // exactly saturated coverage. Rounding inward can leave extra work at the edge.
    const inset = @max(@reduce(.Max, radii), border) + 1;
    const center: [4]f32 = .{
        @ceil(@max(rect[0] + inset, clip[0])),
        @ceil(@max(rect[1] + inset, clip[1])),
        @floor(@min(rect[2] - inset, clip[2])),
        @floor(@min(rect[3] - inset, clip[3])),
    };
    if (center[0] >= center[2] or center[1] >= center[3]) return null;
    const pixels = toPixels(center);
    if (pixels[0] == pixels[2] or pixels[1] == pixels[3]) return null;
    if (!interiorCovered(q, scale, pixels)) return null;
    return pixels;
}

/// Positive scaling and each rounded f32 add/subtract are monotone. The extrema
/// of the logical pixel-center coordinates therefore occur at the first/last
/// sample on each axis, even when 1 / scale rounds. roundedBox is monotone in
/// |local x| and |local y| for any fixed radius; using both maximum magnitudes
/// is conservative even when they belong to different physical corners.
/// Evaluate every possible capped radius (and zero for radius-disabled builds)
/// with the same expressions as shadeFor. If outer and inner coverage saturate
/// to one at those extrema, they do so throughout the candidate rectangle.
fn interiorCovered(q: *const Quad, scale: f32, pixels: [4]u32) bool {
    const inv_scale = 1 / scale;
    const lo_x = (@as(f32, @floatFromInt(pixels[0])) + 0.5) * inv_scale;
    const lo_y = (@as(f32, @floatFromInt(pixels[1])) + 0.5) * inv_scale;
    const hi_x = (@as(f32, @floatFromInt(pixels[2] - 1)) + 0.5) * inv_scale;
    const hi_y = (@as(f32, @floatFromInt(pixels[3] - 1)) + 0.5) * inv_scale;
    if (!(lo_x >= q.rect[0] and hi_x < q.rect[2] and
        lo_y >= q.rect[1] and hi_y < q.rect[3] and
        lo_x >= q.clip[0] and hi_x <= q.clip[2] and
        lo_y >= q.clip[1] and hi_y <= q.clip[3])) return false;
    const hx = (q.rect[2] - q.rect[0]) * 0.5;
    const hy = (q.rect[3] - q.rect[1]) * 0.5;
    const cx = (q.rect[0] + q.rect[2]) * 0.5;
    const cy = (q.rect[1] + q.rect[3]) * 0.5;
    const mx = simd.f(@max(@abs(lo_x - cx), @abs(hi_x - cx)));
    const my = simd.f(@max(@abs(lo_y - cy), @abs(hi_y - cy)));
    const cap = @min(hx, hy);
    const candidates = [_]f32{ 0, q.radii[0], q.radii[1], q.radii[2], q.radii[3] };
    var covered = true;
    inline for (candidates) |radius| {
        const dist = roundedBox(mx, my, hx, hy, simd.f(@min(radius, cap))) * simd.f(scale);
        const shape = sat(simd.f(0.5) - dist);
        const inner = sat(simd.f(0.5) - (dist + simd.f(q.border * scale)));
        covered = covered and @reduce(.And, (shape == simd.f(1)) & (inner == simd.f(1)));
    }
    return covered;
}

/// The common glyph/image geometry: square, borderless, untransformed and without
/// a rounded clip. Texture content and opacity are unrestricted. This is a quad
/// predicate, never a pixel branch; every other case keeps the complete shader.
fn plainTexturedRect(comptime use: features.Usage, q: *const Quad) bool {
    const zero: @Vector(4, f32) = @splat(0);
    const square = !use.radius or (@reduce(.And, @as(@Vector(4, f32), q.radii) == zero) and
        @reduce(.And, @as(@Vector(4, f32), q.clip_radii) == zero));
    return @as(u32, @bitCast(q.params[0])) == 0 and square and (!use.border or q.border == 0) and
        q.rect[2] > q.rect[0] and q.rect[3] > q.rect[1] and
        std.mem.eql(f32, &q.xform, &.{ 1, 0, 0, 1, 0, 0 });
}

/// Pixels whose centres lie in `q.rect` and inside `q.clip` (the shader's `step` tests).
fn coveredPixels(q: *const Quad, scale: f32) [4]u32 {
    const s: @Vector(4, f32) = @splat(scale);
    const rect = @as(@Vector(4, f32), q.rect) * s;
    const clip = @as(@Vector(4, f32), q.clip) * s - @as(@Vector(4, f32), @splat(0.5));
    // A centre x + 0.5 is in the clip when ceil(c0 - 0.5) <= x <= floor(c1 - 0.5).
    const lo = @max(rect, @ceil(clip));
    const hi = @min(rect, @floor(clip) + @as(@Vector(4, f32), @splat(1)));
    return toPixels(.{ lo[0], lo[1], hi[2], hi[3] });
}

/// Logical box (x0, y0, x1, y1) in pixels, floored and clamped to [0, 2^24].
fn toPixels(box: [4]f32) [4]u32 {
    const v = @min(@max(@floor(@as(@Vector(4, f32), box)), @as(@Vector(4, f32), @splat(0))), @as(@Vector(4, f32), @splat(1 << 24)));
    const p: @Vector(4, u32) = @intFromFloat(v);
    return p;
}

fn rgba(c: u32) [4]f32 {
    const v: @Vector(4, f32) = @floatFromInt(@as(@Vector(4, u8), @bitCast(c)));
    return v / @as(@Vector(4, f32), @splat(255));
}

inline fn sat(x: F) F {
    return @min(@max(x, simd.f(0)), simd.f(1));
}

inline fn len2(x: F, y: F) F {
    return @sqrt(x * x + y * y);
}

/// The shader's `corner_radius`: the radius of p's quadrant, capped by the half size.
inline fn cornerRadius(px: F, py: F, hx: f32, hy: f32, radii: [4]f32) F {
    const down = py > simd.f(0);
    const right = @select(f32, down, simd.f(radii[2]), simd.f(radii[1]));
    const left = @select(f32, down, simd.f(radii[3]), simd.f(radii[0]));
    return @min(@select(f32, px > simd.f(0), right, left), simd.f(@min(hx, hy)));
}

/// The shader's `rounded_box`: signed distance to a box of half size (hx, hy) with radius r.
inline fn roundedBox(px: F, py: F, hx: f32, hy: f32, r: F) F {
    const qx = @abs(px) - simd.f(hx) + r;
    const qy = @abs(py) - simd.f(hy) + r;
    return len2(@max(qx, simd.f(0)), @max(qy, simd.f(0))) + @min(@max(qx, qy), simd.f(0)) - r;
}

/// The shader's `nine_axis`.
inline fn nineAxis(pos: F, size: f32, lo: f32, hi: f32, src_lo: f32, src_hi: f32) F {
    const start = pos / simd.f(@max(lo, 1e-6)) * simd.f(src_lo);
    const end = simd.f(1) - (simd.f(size) - pos) / simd.f(@max(hi, 1e-6)) * simd.f(src_hi);
    const mid = simd.f(src_lo) + (pos - simd.f(lo)) / simd.f(@max(size - lo - hi, 1e-6)) * simd.f(1 - src_lo - src_hi);
    return @select(f32, pos < simd.f(lo), start, @select(f32, pos > simd.f(size - hi), end, mid));
}

/// The shader's `floor_div`: floor(num / den) for den > 0, settled by products.
inline fn floorDiv(num: F, den: F) F {
    const q = @floor(num / den);
    const one = simd.f(1);
    const up: F = @floatFromInt(@intFromBool((q + one) * den <= num));
    const down: F = @floatFromInt(@intFromBool(q * den > num));
    return q + up - down;
}

/// The shader's nearest texel number, before its normalized-UV round trip.
inline fn texelNumber(pos: F, size: f32, uv0: f32, uv1: f32, n: f32) F {
    const s = @max(size, 1e-6);
    const a = uv0 * n;
    const whole = @floor(a);
    const k = simd.f(whole) + floorDiv(simd.f((a - whole) * s) + simd.f((uv1 - uv0) * n) * pos, simd.f(s));
    return @min(@max(k, simd.f(0)), simd.f(n - 1));
}

/// The shader's `texel_centre`: the uv of the nearest texel's centre along one axis.
inline fn texelCentre(pos: F, size: f32, uv0: f32, uv1: f32, n: f32) F {
    return (texelNumber(pos, size, uv0, uv1, n) + simd.f(0.5)) / simd.f(n);
}

inline fn sampleCoverage(img: Image, idx: U) F {
    var coverage: U = undefined;
    inline for (0..W) |l| coverage[l] = img.alpha8[idx[l]];
    return @as(F, @floatFromInt(coverage)) * simd.f(1.0 / 255.0);
}

/// Nearest texel at (u, v), coordinates clamped to the edge; returns r, g, b, a in 0..1.
inline fn sample(comptime encoding: ImageEncoding, img: Image, u: F, v: F) [4]F {
    const wf: f32 = @floatFromInt(img.width);
    const hf: f32 = @floatFromInt(img.height);
    const tx: U = @intFromFloat(@min(@max(@floor(u * simd.f(wf)), simd.f(0)), simd.f(wf - 1)));
    const ty: U = @intFromFloat(@min(@max(@floor(v * simd.f(hf)), simd.f(0)), simd.f(hf - 1)));
    const idx = ty * simd.u(img.width) + tx;
    var texel: U = undefined;
    if (encoding == .alpha8)
        return .{ simd.f(1), simd.f(1), simd.f(1), sampleCoverage(img, idx) };
    inline for (0..W) |l| texel[l] = img.pixels[idx[l]];
    return unpack(texel, 0);
}

inline fn unpack(p: U, red: u5) [4]F {
    const m = simd.u(255);
    const k = simd.f(1.0 / 255.0);
    return .{
        @as(F, @floatFromInt((p >> @splat(red)) & m)) * k,
        @as(F, @floatFromInt((p >> @splat(8)) & m)) * k,
        @as(F, @floatFromInt((p >> @splat(16 - red)) & m)) * k,
        @as(F, @floatFromInt((p >> @splat(24)) & m)) * k,
    };
}

inline fn pack(c: [4]F, red: u5) U {
    var out: [4]U = undefined;
    inline for (0..4) |i| out[i] = @intFromFloat(@round(sat(c[i]) * simd.f(255)));
    return (out[0] << @splat(red)) | (out[1] << @splat(8)) | (out[2] << @splat(16 - red)) | (out[3] << @splat(24));
}

/// Shades `q` into `t` with the stock material's `kind` loop: quad.wgsl `vs` and `fs` per pixel.
pub fn shade(comptime kind: features.Kind, t: Target, q: *const Quad, img: Image, scale: f32) void {
    if (img.alpha8.len != 0)
        shadeFor(.all, kind, .alpha8, t, q, img, scale)
    else
        shadeFor(.all, kind, .rgba8, t, q, img, scale);
}

/// `shadeFor(.solid)` with the facts established by plainTexturedRect. Retain
/// the distance calculation even for square edges: fractional positions still
/// need its antialias coverage, and replacing it with integer bounds would alter
/// pixels. RGBA sampling also stays intact, so colored glyphs/images work here.
fn shadeTexturedRect(comptime encoding: ImageEncoding, t: Target, q: *const Quad, img: Image, scale: f32) void {
    // For n <= 2^16, integer k and k + 0.5 are exactly represented. The
    // division/multiplication round trip differs from k + 0.5 by less than
    // 0.008, so floor(((k + 0.5) / n) * n) is exactly k. Coverage atlases
    // can address that texel directly instead of normalizing UV and undoing it.
    // Larger images retain the reference arithmetic, without a pixel branch.
    if (encoding == .alpha8 and img.width <= (1 << 16) and img.height <= (1 << 16))
        shadeRect(encoding, true, t, q, img, scale)
    else
        shadeRect(encoding, false, t, q, img, scale);
}

fn shadeRect(comptime encoding: ImageEncoding, comptime direct_coverage: bool, t: Target, q: *const Quad, img: Image, scale: f32) void {
    const x0, const y0, const x1, const y1 = q.rect;
    const hx = (x1 - x0) * 0.5;
    const hy = (y1 - y0) * 0.5;
    const cx = (x0 + x1) * 0.5;
    const cy = (y0 + y1) * 0.5;
    const clip = q.clip;
    const box = clampBox(toPixels(.{
        @max(x0, clip[0]) * scale,
        @max(y0, clip[1]) * scale,
        @min(x1, clip[2]) * scale + 1,
        @min(y1, clip[3]) * scale + 1,
    }), t.scissor);
    const fill = rgba(q.fill);
    const tex_w: f32 = @floatFromInt(img.width);
    const tex_h: f32 = @floatFromInt(img.height);
    const red = t.fb.red();
    const inv_scale = 1 / scale;
    for (box[1]..box[3]) |y| {
        const row = t.fb.pixels[y * t.fb.stride ..][0..t.fb.stride];
        const fy = simd.f(@as(f32, @floatFromInt(y)) + 0.5);
        const sy = fy * simd.f(inv_scale);
        const py = sy - simd.f(y0);
        const ly = sy - simd.f(cy);
        // The identity transform makes the vertical sample constant for a row.
        const tv = if (direct_coverage) undefined else texelCentre(py, 2 * hy, q.uv[1], q.uv[3], tex_h);
        const texture_row = if (direct_coverage)
            @as(U, @intFromFloat(texelNumber(py, 2 * hy, q.uv[1], q.uv[3], tex_h))) * simd.u(img.width)
        else
            undefined;
        var x = std.mem.alignBackward(u32, box[0], W);
        while (x < box[2]) : (x += W) {
            const fx = @as(F, @floatFromInt(simd.iota + simd.u(x))) + simd.f(0.5);
            const sx = fx * simd.f(inv_scale);
            const px = sx - simd.f(x0);
            const lx = sx - simd.f(cx);
            const geo = (sx >= simd.f(x0)) & (sx < simd.f(x1)) & (sy >= simd.f(y0)) & (sy < simd.f(y1));
            const dist = roundedBox(lx, ly, hx, hy, simd.f(0)) * simd.f(scale);
            const shape = sat(simd.f(0.5) - dist);
            const tex: [4]F = if (direct_coverage) blk: {
                const tx: U = @intFromFloat(texelNumber(px, 2 * hx, q.uv[0], q.uv[2], tex_w));
                break :blk .{ simd.f(1), simd.f(1), simd.f(1), sampleCoverage(img, texture_row + tx) };
            } else sample(encoding, img, texelCentre(px, 2 * hx, q.uv[0], q.uv[2], tex_w), tv);
            var color: [4]F = undefined;
            inline for (0..4) |i| color[i] = simd.f(fill[i]) * tex[i];
            const inside = (sx >= simd.f(clip[0])) & (sx <= simd.f(clip[2])) & (sy >= simd.f(clip[1])) & (sy <= simd.f(clip[3]));
            const alpha = @select(f32, inside & geo, shape * simd.f(q.opacity), simd.f(0));

            const old: U = row[x..][0..W].*;
            const dst_px = unpack(old, red);
            const sa = color[3] * alpha;
            var out: [4]F = undefined;
            inline for (0..3) |i| out[i] = color[i] * sa + dst_px[i] * (simd.f(1) - sa);
            out[3] = sa + dst_px[3] * (simd.f(1) - sa);
            row[x..][0..W].* = @select(u32, spanMask(x, box[0], box[2]), pack(out, red), old);
        }
    }
}

fn shadeFor(comptime use: features.Usage, comptime kind: features.Kind, comptime encoding: ImageEncoding, t: Target, q: *const Quad, img: Image, scale: f32) void {
    const p: [4]u32 = @bitCast(q.params);
    const x0, const y0, const x1, const y1 = q.rect;
    const hx = (x1 - x0) * 0.5;
    const hy = (y1 - y0) * 0.5;
    const cx = (x0 + x1) * 0.5;
    const cy = (y0 + y1) * 0.5;
    // A shadow draws 3 sigma past its rect, where the blur fades out.
    const sigma: f32 = @bitCast(p[1]);
    const grow: f32 = if (kind == .shadow) 3 * sigma else 0;
    const g0 = [2]f32{ x0 - grow, y0 - grow };
    const g1 = [2]f32{ x1 + grow, y1 + grow };

    // The vertex shader maps corners by the transform; per pixel, its inverse gives the point
    // in the node's own space, which is what the interpolated `local` and `uv` are.
    const a, const b, const c, const d, const tx, const ty = q.xform;
    const inv = 1 / (a * d - b * c);
    // The shader's `to_rect`: pixel centre (physical) to the offset from the rect's top left.
    const k_rect = 1 / ((a * d - b * c) * scale);
    const mr = [4]f32{ d * k_rect, -b * k_rect, -c * k_rect, a * k_rect };
    const off_x = -(mr[0] * (tx * scale) + mr[2] * (ty * scale)) - x0;
    const off_y = -(mr[1] * (tx * scale) + mr[3] * (ty * scale)) - y0;
    var lo: @Vector(2, f32) = @splat(std.math.inf(f32));
    var hi: @Vector(2, f32) = @splat(-std.math.inf(f32));
    for ([_][2]f32{ g0, .{ g1[0], g0[1] }, .{ g0[0], g1[1] }, g1 }) |corner| {
        const sc: @Vector(2, f32) = .{ a * corner[0] + c * corner[1] + tx, b * corner[0] + d * corner[1] + ty };
        lo = @min(lo, sc);
        hi = @max(hi, sc);
    }
    const clip = q.clip;
    const box = clampBox(toPixels(.{
        @max(lo[0], clip[0]) * scale,
        @max(lo[1], clip[1]) * scale,
        @min(hi[0], clip[2]) * scale + 1,
        @min(hi[1], clip[3]) * scale + 1,
    }), t.scissor);

    const fill = rgba(q.fill);
    const edge = rgba(q.border_color);
    const to = rgba(p[1]);
    const border = q.border;
    const has_border: f32 = @floatFromInt(@intFromBool(border >= 0.001));
    const uv = q.uv;
    const tex_w: f32 = @floatFromInt(img.width);
    const tex_h: f32 = @floatFromInt(img.height);
    // Linear gradient: direction and the reach to the corners it meets.
    const angle: f32 = @bitCast(p[2]);
    const dir_x = @cos(angle);
    const dir_y = @sin(angle);
    const reach = @max(@abs(hx * dir_x) + @abs(hy * dir_y), 1e-6);
    // Radial gradient: centre as two f16 fractions of the size, radius in pixels.
    const centre: [2]f16 = @bitCast(p[2]);
    const rc_x = (@as(f32, centre[0]) * 2 - 1) * hx;
    const rc_y = (@as(f32, centre[1]) * 2 - 1) * hy;
    const radius = @max(@as(f32, @bitCast(p[3])), 1e-6);
    // Nine-slice insets.
    const dst: [4]f32 = rgba(p[1]) * @as(@Vector(4, f32), @splat(255));
    const src = [4]f32{ unorm16(p[2]), unorm16(p[2] >> 16), unorm16(p[3]), unorm16(p[3] >> 16) };
    // Dashed and dotted borders.
    const dash: f32 = if (kind == .dotted) border else @bitCast(p[1]);
    const period = @max(dash + @as(f32, @bitCast(p[2])), 1e-3);
    // Clip, and its rounded corners when it has any.
    const ccx = (clip[0] + clip[2]) * 0.5;
    const ccy = (clip[1] + clip[3]) * 0.5;
    const chx = (clip[2] - clip[0]) * 0.5;
    const chy = (clip[3] - clip[1]) * 0.5;
    const rounded_clip: B = @splat(@reduce(.Or, @as(@Vector(4, f32), q.clip_radii) > @as(@Vector(4, f32), @splat(0))));

    const red = t.fb.red();
    const inv_scale = 1 / scale;
    for (box[1]..box[3]) |y| {
        const row = t.fb.pixels[y * t.fb.stride ..][0..t.fb.stride];
        const fy = simd.f(@as(f32, @floatFromInt(y)) + 0.5);
        const sy = fy * simd.f(inv_scale);
        var x = std.mem.alignBackward(u32, box[0], W);
        while (x < box[2]) : (x += W) {
            const fx = @as(F, @floatFromInt(simd.iota + simd.u(x))) + simd.f(0.5);
            const sx = fx * simd.f(inv_scale);
            // The shader's `rect_pos`, from exact inputs only.
            const px = simd.f(mr[0]) * fx + simd.f(mr[2]) * fy + simd.f(off_x);
            const py = simd.f(mr[1]) * fx + simd.f(mr[3]) * fy + simd.f(off_y);
            // The point in the quad's own space; pixels whose centre is outside the drawn
            // geometry get no fragment.
            const ox = sx - simd.f(tx);
            const oy = sy - simd.f(ty);
            const qx = (simd.f(d) * ox - simd.f(c) * oy) * simd.f(inv);
            const qy = (simd.f(a) * oy - simd.f(b) * ox) * simd.f(inv);
            const geo = (qx >= simd.f(g0[0])) & (qx < simd.f(g1[0])) & (qy >= simd.f(g0[1])) & (qy < simd.f(g1[1]));
            const lx = qx - simd.f(cx);
            const ly = qy - simd.f(cy);

            const r = if (use.radius) cornerRadius(lx, ly, hx, hy, q.radii) else simd.f(0);
            const dist = roundedBox(lx, ly, hx, hy, r) * simd.f(scale);
            const shape = sat(simd.f(0.5) - dist);
            const inner = sat(simd.f(0.5) - (dist + simd.f(border * scale)));

            // Border pattern: how much of the border is drawn here.
            var pattern = simd.f(1);
            if (kind == .dashed or kind == .dotted) {
                const ex = simd.f(hx) - @abs(px - simd.f(hx));
                const ey = simd.f(hy) - @abs(py - simd.f(hy));
                const s = @select(f32, ex < ey, py, px);
                const across = @min(ex, ey);
                const at = s - floorDiv(s, simd.f(period)) * simd.f(period);
                pattern = if (kind == .dashed)
                    sat((@min(at, simd.f(dash) - at) + simd.f(0.5)) * simd.f(scale))
                else
                    sat(simd.f(0.5) - (len2(at - simd.f(border * 0.5), across - simd.f(border * 0.5)) - simd.f(border * 0.5)) * simd.f(scale));
            }
            const on_border = (simd.f(1) - inner) * simd.f(has_border) * pattern;

            // Material: the fill or its gradient, times the texture.
            var tu = texelCentre(px, 2 * hx, uv[0], uv[2], tex_w);
            var tv = texelCentre(py, 2 * hy, uv[1], uv[3], tex_h);
            if (kind == .nine_slice) {
                const fu = nineAxis(lx + simd.f(hx), 2 * hx, dst[0], dst[2], src[0], src[2]);
                const fv = nineAxis(ly + simd.f(hy), 2 * hy, dst[1], dst[3], src[1], src[3]);
                tu = simd.f(uv[0]) + simd.f(uv[2] - uv[0]) * fu;
                tv = simd.f(uv[1]) + simd.f(uv[3] - uv[1]) * fv;
            }
            var base: [4]F = .{ simd.f(fill[0]), simd.f(fill[1]), simd.f(fill[2]), simd.f(fill[3]) };
            if (kind == .linear or kind == .radial) {
                const g = sat(if (kind == .linear)
                    (lx * simd.f(dir_x) + ly * simd.f(dir_y)) / simd.f(reach) * simd.f(0.5) + simd.f(0.5)
                else
                    len2(lx - simd.f(rc_x), ly - simd.f(rc_y)) / simd.f(radius));
                inline for (0..4) |i| base[i] += (simd.f(to[i]) - base[i]) * g;
            }
            var color: [4]F = undefined;
            var cover = shape;
            if (kind == .shadow) {
                // The rounded rect blurred by a Gaussian: 0.5 - erf(d / (sigma sqrt 2)) / 2.
                const e = dist * simd.f(inv_scale / (@max(sigma, 1e-3) * 1.41421356));
                const e2 = e * e;
                const k = simd.f(0.147);
                const erf = std.math.sign(e) * @sqrt(simd.f(1) - @exp(-e2 * (simd.f(1.27323954) + k * e2) / (simd.f(1) + k * e2)));
                cover = simd.f(0.5) - simd.f(0.5) * erf;
                color = base;
            } else {
                const tex: [4]F = if (use.image or use.text) sample(encoding, img, tu, tv) else @splat(simd.f(1));
                inline for (0..4) |i| {
                    const m = base[i] * tex[i];
                    color[i] = if (use.border) m + (simd.f(edge[i]) - m) * on_border else m;
                }
            }

            // Clip as coverage: the rect as a step, its rounded corners as a distance field.
            const inside = (sx >= simd.f(clip[0])) & (sx <= simd.f(clip[2])) & (sy >= simd.f(clip[1])) & (sy <= simd.f(clip[3]));
            const tcx = sx - simd.f(ccx);
            const tcy = sy - simd.f(ccy);
            const clip_d = roundedBox(tcx, tcy, chx, chy, cornerRadius(tcx, tcy, chx, chy, q.clip_radii)) * simd.f(scale);
            const rounded = if (use.radius) @select(f32, rounded_clip, sat(simd.f(0.5) - clip_d), simd.f(1)) else simd.f(1);
            const alpha = @select(f32, inside & geo, cover * rounded * simd.f(q.opacity), simd.f(0));

            // Premultiplied source over the framebuffer.
            const old: U = row[x..][0..W].*;
            const dst_px = unpack(old, red);
            const sa = color[3] * alpha;
            var out: [4]F = undefined;
            inline for (0..3) |i| out[i] = color[i] * sa + dst_px[i] * (simd.f(1) - sa);
            out[3] = sa + dst_px[3] * (simd.f(1) - sa);
            row[x..][0..W].* = @select(u32, spanMask(x, box[0], box[2]), pack(out, red), old);
        }
    }
}

fn unorm16(v: u32) f32 {
    return @as(f32, @floatFromInt(v & 0xffff)) / 65535;
}

const testing = std.testing;
const conformance = @import("../conformance.zig");

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
        @memset(fb.pixels, 0xfeedbeef);
        fb.clear(.rgba(1, 2, 3, 4));
        fb.fill(.{ 9, 0, 12, 3 }, .rgba(99, 99, 99, 99)); // clipped to an empty span
        fb.fill(.{ 1, 1, 9, 2 }, .rgba(10, 20, 30, 40));
        try testing.expectEqual(Color.rgba(1, 2, 3, 4), fb.at(0, 1));
        try testing.expectEqual(Color.rgba(10, 20, 30, 40), fb.at(4, 1));
        try testing.expectEqual(Color.rgba(1, 2, 3, 4), fb.at(1, 2));
        for (0..fb.height) |y| {
            const padding = fb.pixels[y * fb.stride ..][fb.width..fb.stride];
            for (padding) |p| try testing.expectEqual(0xfeedbeef, p);
        }
        const bytes: [4]u8 = @bitCast(fb.pixels[fb.stride + 1]);
        const want: [4]u8 = if (format == .rgba8) .{ 10, 20, 30, 40 } else .{ 30, 20, 10, 40 };
        try testing.expectEqual(want, bytes);
    }
}

test "SoftwareOf: a kind left out of the build draws as missing_kind, the others as before" {
    var f: Frame(16, 4) = .{};
    var g: Frame(16, 4) = .{};
    var fb = f.fb(.rgba8);
    var ref = g.fb(.rgba8);
    var quads = [_]Quad{ testQuad(.{ 0, 0, 8, 4 }, .rgb(10, 20, 30)), testQuad(.{ 8, 0, 16, 4 }, .rgb(10, 20, 30)) };
    quads[0].radii = @splat(2); // solid, shaded: rounded corners
    quads[1].params = features.linear(.rgb(200, 0, 0), 0);
    const slim: SoftwareOf(&.{.solid}) = .{ .quads = &quads };
    const full: Software = .{ .quads = &quads };
    fb.clear(.black);
    ref.clear(.black);
    const batch: draw_list.Batch = .{ .first = 0, .count = 2, .texture = .white, .material = .solid };
    slim.drawBatch(.{ .fb = &fb, .scissor = fb.all() }, batch);
    full.drawBatch(.{ .fb = &ref, .scissor = ref.all() }, batch);
    for (0..4) |y| for (0..16) |x| {
        const want = if (x < 8) ref.at(@intCast(x), @intCast(y)) else missing_kind;
        try testing.expectEqual(want, fb.at(@intCast(x), @intCast(y)));
    };
}

test "opaque rects: filled exactly, cut by the clip's pixel centres and the scissor" {
    var f: Frame(16, 8) = .{};
    var fb = f.fb(.rgba8);
    fb.clear(.black);
    var q = testQuad(.{ 2, 1, 14, 7 }, .rgb(200, 100, 50));
    q.clip = .{ 3.4, 0, 12.5, 6 };
    try testing.expect(solidRect(&q, Image.white, 1));
    const s: Software = .{ .quads = &.{q} };
    s.drawBatch(.{ .fb = &fb, .scissor = .{ 0, 0, 16, 5 } }, .{ .first = 0, .count = 1, .texture = .white, .material = .solid });
    // Centres 3.5 .. 12.5 are inside the clip (its edges are inclusive), rows 1 .. 4 inside the scissor.
    for (0..8) |y| for (0..16) |x| {
        const in = x >= 3 and x <= 12 and y >= 1 and y < 5;
        try testing.expectEqual(if (in) Color.rgb(200, 100, 50) else Color.black, fb.at(@intCast(x), @intCast(y)));
    };
}

test "blend: premultiplied over, and a shaded rect matches the opaque fill" {
    var f: Frame(8, 4) = .{};
    var fb = f.fb(.bgra8);
    fb.clear(.rgb(0, 0, 200));
    const t: Target = .{ .fb = &fb, .scissor = fb.all() };
    // Half-transparent red over blue: (255 * 0.5, 0, 200 * 0.5).
    var q = testQuad(.{ 0, 0, 8, 4 }, .rgba(255, 0, 0, 128));
    shade(.solid, t, &q, Image.white, 1);
    const got = fb.at(3, 2);
    try testing.expect(@abs(@as(i32, got.r) - 128) <= 1 and got.g == 0 and @abs(@as(i32, got.b) - 99) <= 1 and got.a == 255);
    // The general loop writes what the fast path writes for an opaque rect.
    q.fill = Color.rgb(9, 99, 199).bitsOf();
    shade(.solid, t, &q, Image.white, 1);
    for (0..4) |y| for (0..8) |x| try testing.expectEqual(Color.rgb(9, 99, 199), fb.at(@intCast(x), @intCast(y)));
}

test "solid fills and corner bands agree with the shader through a partial scissor" {
    var fast: Frame(33, 23) = .{};
    var slow: Frame(33, 23) = .{};
    for ([_]Format{ .rgba8, .bgra8 }) |format| {
        var fb = fast.fb(format);
        var reference = slow.fb(format);
        const scissor = [4]u32{ 3, 3, 30, 20 };
        for ([_]u8{ 0, 1, 126, 127, 128, 254, 255 }) |alpha| {
            var q = testQuad(.{ 1, 1, 15, 11 }, .rgba(233, 81, 106, alpha));
            q.radii = .{ 0, 1, 2, 3 };
            q.clip = .{ 0.75, 0.5, 14.25, 11 };
            const gfx: Software = .{ .scale = 2 };
            for (fb.pixels, 0..) |*px, i| px.* = @as(u32, @intCast(i)) *% 0x21098571;
            @memcpy(reference.pixels, fb.pixels);
            gfx.drawQuads(.{ .fb = &fb, .scissor = scissor }, &.{q}, Image.white);
            shade(.solid, .{ .fb = &reference, .scissor = scissor }, &q, Image.white, 2);
            try testing.expectEqualSlices(u32, reference.pixels, fb.pixels);
        }
    }
}

fn expectBorderedMatches(q: Quad, scale: f32, format: Format, scissor: [4]u32) !void {
    var fast: Frame(99, 83) = .{};
    var slow: Frame(99, 83) = .{};
    var fb = fast.fb(format);
    var reference = slow.fb(format);
    // Preserve arbitrary destination alpha and row padding in the comparison.
    for (fb.pixels, 0..) |*px, i| px.* = @as(u32, @intCast(i)) *% 0x21098571;
    @memcpy(reference.pixels, fb.pixels);
    const gfx: Software = .{ .quads = &.{q}, .scale = scale };
    gfx.drawBatch(.{ .fb = &fb, .scissor = scissor }, .{ .first = 0, .count = 1, .texture = .white, .material = .solid });
    shade(.solid, .{ .fb = &reference, .scissor = scissor }, &q, Image.white, scale);
    try testing.expectEqualSlices(u32, reference.pixels, fb.pixels);
}

test "bordered interiors preserve corners clipping and transparent borders at integer scales" {
    const Scene = struct {
        rect: [4]f32,
        radii: [4]f32,
        border: f32,
        clip: [4]f32 = .{ -1e6, -1e6, 1e6, 1e6 },
        scissor: [4]u32 = .{ 0, 0, 99, 83 },
    };
    // Describe physical pixels, then divide by scale. Scales 2/4 also exercise
    // fractional logical edges/radii/borders that become exact physical pixels.
    const scenes = [_]Scene{
        .{ .rect = .{ 1, 1, 94, 77 }, .radii = @splat(5), .border = 1 },
        .{ .rect = .{ -7, -5, 89, 72 }, .radii = .{ 0, 2, 8, 4 }, .border = 4, .clip = .{ 3.5, 2.5, 92.5, 74.5 }, .scissor = .{ 3, 2, 91, 79 } },
        .{ .rect = .{ 3, 2, 48, 35 }, .radii = @splat(0), .border = 8, .clip = .{ 7.25, 5.75, 43.75, 32.25 }, .scissor = .{ 5, 4, 47, 34 } },
        // One fill pixel; the remaining panel still uses the original shader.
        .{ .rect = .{ 3, 4, 12, 13 }, .radii = .{ 3, 1, 2, 0 }, .border = 1 },
        .{ .rect = .{ -65536, -65536, 95, 79 }, .radii = .{ 5, 0, 2, 8 }, .border = 2, .clip = .{ 1.25, 0.5, 98.5, 82.5 } },
        // This scissor excludes the whole interior, exercising dispatch fallback.
        .{ .rect = .{ 1, 1, 94, 77 }, .radii = @splat(5), .border = 1, .scissor = .{ 0, 0, 99, 3 } },
    };
    for ([_]Format{ .rgba8, .bgra8 }) |format| {
        for ([_]f32{ 1, 2, 4 }) |scale| {
            const s: @Vector(4, f32) = @splat(scale);
            for (scenes) |scene| {
                var q = testQuad(@as(@Vector(4, f32), scene.rect) / s, .rgb(17, 149, 231));
                q.radii = @as(@Vector(4, f32), scene.radii) / s;
                q.clip = @as(@Vector(4, f32), scene.clip) / s;
                q.border = scene.border / scale;
                try testing.expect(!solidRect(&q, Image.white, scale));
                try testing.expect(opaqueInterior(&q, Image.white, scale) != null);
                for ([_]u8{ 0, 97, 255 }) |alpha| {
                    q.border_color = Color.rgba(211, 33, 80, alpha).bitsOf();
                    try expectBorderedMatches(q, scale, format, scene.scissor);
                }
            }
        }
    }
}

test "bordered interiors preserve fractional scales edges radii and clips exactly" {
    const Scene = struct { rect: [4]f32, radii: [4]f32, border: f32, clip: [4]f32 };
    const scenes = [_]Scene{
        .{ .rect = .{ 1.1, 0.7, 63.3, 47.9 }, .radii = .{ 2.5, 0.7, 5.3, 3.1 }, .border = 1.1, .clip = .{ 0.2, 0.9, 66.1, 49.7 } },
        .{ .rect = .{ -11.25, -6.75, 51.1, 38.7 }, .radii = .{ 0, 0.5, 1.25, 2.75 }, .border = 0.4, .clip = .{ 2.35, 1.25, 61.75, 43.125 } },
        .{ .rect = .{ 0.125, 0.375, 45.875, 34.625 }, .radii = @splat(0), .border = 2.75, .clip = .{ 0.1, 0.2, 46.1, 35.2 } },
        .{ .rect = .{ -32767.9, -16383.7, 65.1, 48.3 }, .radii = .{ 1.2, 3.7, 0.9, 4.1 }, .border = 2.1, .clip = .{ 0.35, 1.15, 65.8, 50.6 } },
        .{ .rect = .{ 0.1, 0.2, 31.3, 29.4 }, .radii = .{ 1.1, 2.3, 0.7, 3.1 }, .border = 0.8, .clip = .{ 6.4999995, 6.5000005, 25.500002, 24.499998 } },
    };
    for ([_]Format{ .rgba8, .bgra8 }) |format| {
        for ([_]f32{ 0.75, 1, 1.25, 1.5, 1.75, 1.3333334, 2 }) |scale| {
            for (scenes) |scene| {
                var q = testQuad(scene.rect, .rgb(17, 149, 231));
                q.radii = scene.radii;
                q.border = scene.border;
                q.clip = scene.clip;
                try testing.expect(opaqueInterior(&q, Image.white, scale) != null);
                for ([_]u8{ 0, 97, 255 }) |alpha| {
                    q.border_color = Color.rgba(211, 33, 80, alpha).bitsOf();
                    try expectBorderedMatches(q, scale, format, .{ 3, 2, 91, 79 });
                }
            }
        }
    }
}

test "opaque interiors preserve zero and subthreshold borders at fractional edges" {
    const Scene = struct {
        rect: [4]f32,
        radii: [4]f32,
        clip: [4]f32,
        scissor: [4]u32 = .{ 0, 0, 99, 83 },
    };
    const scenes = [_]Scene{
        .{ .rect = .{ 1.1, 0.7, 63.3, 47.9 }, .radii = @splat(0), .clip = .{ 0.2, 0.9, 66.1, 49.7 } },
        .{ .rect = .{ -11.25, -6.75, 51.1, 38.7 }, .radii = .{ 0, 0.5, 1.25, 2.75 }, .clip = .{ 2.35, 1.25, 61.75, 43.125 }, .scissor = .{ 3, 2, 91, 79 } },
        .{ .rect = .{ 0.1, 0.2, 31.3, 29.4 }, .radii = .{ 1.1, 2.3, 0.7, 3.1 }, .clip = .{ 6.4999995, 6.5000005, 25.500002, 24.499998 } },
        .{ .rect = .{ -32767.9, -16383.7, 65.1, 48.3 }, .radii = @splat(0), .clip = .{ 0.35, 1.15, 65.8, 50.6 } },
    };
    for ([_]Format{ .rgba8, .bgra8 }) |format| {
        for ([_]f32{ 0.75, 1.25, 1.5, 1.3333334, 2 }) |scale| {
            for (scenes) |scene| {
                var q = testQuad(scene.rect, .rgb(17, 149, 231));
                q.radii = scene.radii;
                q.clip = scene.clip;
                for ([_]f32{ 0, 0.000001, 0.0005, 0.0009999999 }) |border| {
                    q.border = border;
                    // Exercise the new eligibility directly, not the integer-edge fill.
                    try testing.expect(!solidRect(&q, Image.white, scale));
                    try testing.expect(opaqueInterior(&q, Image.white, scale) != null);
                    for ([_]u8{ 0, 97, 255 }) |alpha| {
                        q.border_color = Color.rgba(211, 33, 80, alpha).bitsOf();
                        // The helper compares every pixel, destination alpha and padding.
                        try expectBorderedMatches(q, scale, format, scene.scissor);
                    }
                }
            }
        }
    }
}

test "borderless interior fallback preserves tiny panels and inclusive narrow clips" {
    for ([_]Format{ .rgba8, .bgra8 }) |format| {
        for ([_]f32{ 1.25, 1.5 }) |scale| {
            for ([_]f32{ 0, 0.0005 }) |border| {
                var q = testQuad(.{ 3.1, 4.1, 3.9, 4.9 }, .rgb(19, 85, 211));
                q.border = border;
                q.border_color = Color.rgba(250, 61, 101, 97).bitsOf();
                try testing.expect(opaqueInterior(&q, Image.white, scale) == null);
                try expectBorderedMatches(q, scale, format, .{ 0, 0, 99, 83 });
                q.rect = .{ 1.1, 1.3, 31.1, 23.3 };
                q.radii = .{ 0, 2.5, 0.75, 3.25 };
                const center = @as(f32, 10.5) * (1 / scale);
                for ([_][4]f32{
                    .{ center, 0, center, 99 },
                    .{ 0, center, 99, center },
                    .{ center - 0.1, center - 0.1, center + 0.1, center + 0.1 },
                }) |clip| {
                    q.clip = clip;
                    try testing.expect(opaqueInterior(&q, Image.white, scale) == null);
                    try expectBorderedMatches(q, scale, format, .{ 0, 0, 99, 83 });
                }
            }
        }
    }
}

test "bordered interior fallback preserves small empty and narrowly clipped panels" {
    for ([_][4]f32{
        .{ 3, 4, 3, 15 }, // empty width
        .{ 8, 4, 3, 15 }, // inverted width
        .{ 3, 4, 15, 4 }, // empty height
        .{ 3, 4, 6, 7 }, // radius consumes the interior
        .{ 3, 4, 11, 12 }, // inset edges meet exactly
    }) |rect| {
        var q = testQuad(rect, .rgb(19, 85, 211));
        q.radii = @splat(3);
        q.border = 1;
        q.border_color = Color.rgba(250, 61, 101, 97).bitsOf();
        try testing.expect(opaqueInterior(&q, Image.white, 1) == null);
        for ([_]Format{ .rgba8, .bgra8 }) |format|
            try expectBorderedMatches(q, 1, format, .{ 0, 0, 99, 83 });
    }
    var q = testQuad(.{ 1, 1, 31, 23 }, .rgb(19, 85, 211));
    q.radii = @splat(3);
    q.border = 1;
    q.border_color = Color.rgba(250, 61, 101, 97).bitsOf();
    // The hard clip includes a pixel center but has no conservative fill interval.
    for ([_][4]f32{ .{ 8.4, 9.4, 8.6, 9.6 }, .{ 8, 9, 8, 9 } }) |clip| {
        q.clip = clip;
        try testing.expect(opaqueInterior(&q, Image.white, 1) == null);
        for ([_]Format{ .rgba8, .bgra8 }) |format|
            try expectBorderedMatches(q, 1, format, .{ 0, 0, 99, 83 });
    }
}

test "bordered interior gate accepts fractional geometry and retains semantic fallbacks" {
    const texels = testTexels();
    const texture: Image = .{ .pixels = &texels, .width = 7, .height = 5 };
    inline for (0..11) |mode| {
        var q = testQuad(.{ 1, 1, 31, 23 }, .rgb(17, 149, 231));
        q.radii = @splat(5);
        q.border = 1;
        q.border_color = Color.rgba(211, 33, 80, 97).bitsOf();
        switch (mode) {
            0 => q.rect[0] += 0.1,
            1 => q.radii[2] = 1.1,
            2 => q.border = 1.1,
            3 => q.opacity = 0.65,
            4 => q.fill = Color.rgba(17, 149, 231, 254).bitsOf(),
            5 => q.xform = .{ 1, 0.08, -0.05, 1, 1.5, -0.25 },
            6 => q.clip_radii = .{ 0, 2, 0, 0 },
            7 => q.params = features.linear(.rgba(19, 85, 211, 165), 0.7),
            8, 9 => {}, // nonwhite binding / fractional scale
            10 => q.rect[0] = -65537,
            else => unreachable,
        }
        const img = if (mode == 8) texture else Image.white;
        const scale: f32 = if (mode == 9) 1.25 else 1;
        const kind: features.Kind = if (mode == 7) .linear else .solid;
        const eligible = mode == 0 or mode == 1 or mode == 2 or mode == 9;
        try testing.expectEqual(eligible, opaqueInterior(&q, img, scale) != null);
        for ([_]Format{ .rgba8, .bgra8 }) |format|
            try expectTexturedMatches(kind, q, img, scale, format, false);
    }
}

test "bordered interior gate rejects nonfinite inputs and recognizes the application panel" {
    var panel = testQuad(.{ 185, 138, 784, 478 }, .rgb(30, 31, 36));
    panel.clip = .{ 169, 57, 800, 600 };
    panel.radii = @splat(5);
    panel.border = 1;
    try testing.expectEqual([4]u32{ 191, 144, 778, 472 }, opaqueInterior(&panel, Image.white, 1).?);
    for ([_]f32{ -1, -0.000001, std.math.inf(f32), std.math.nan(f32), 65537 }) |bad| {
        var q = panel;
        q.radii[0] = bad;
        try testing.expect(opaqueInterior(&q, Image.white, 1) == null);
        q = panel;
        q.border = bad;
        try testing.expect(opaqueInterior(&q, Image.white, 1) == null);
    }
    for ([_]f32{ std.math.inf(f32), std.math.nan(f32) }) |bad| {
        var q = panel;
        q.rect[0] = bad;
        try testing.expect(opaqueInterior(&q, Image.white, 1) == null);
        q = panel;
        q.clip[0] = bad;
        try testing.expect(opaqueInterior(&q, Image.white, 1) == null);
        try testing.expect(opaqueInterior(&panel, Image.white, bad) == null);
    }
}

test "white binding specialization matches the complete shader for every material" {
    var fast: Frame(67, 53) = .{};
    var slow: Frame(67, 53) = .{};
    inline for (all_kinds) |kind| {
        for ([_]Format{ .rgba8, .bgra8 }) |format| {
            var fb = fast.fb(format);
            var reference = slow.fb(format);
            for ([_]f32{ 0.75, 1, 1.25, 2 }) |scale| {
                // Fractional, transformed geometry misses the opaque fill path.
                // Rounded clips, opacity and borders must remain part of shading.
                var q = testQuad(.{ 1.3, 2.7, 27.4, 22.2 }, .rgba(233, 81, 106, 129));
                q.xform = .{ 1, 0.08, -0.05, 1, 1.5, -0.25 };
                q.radii = .{ 0, 1, 3, 2 };
                q.clip = .{ 0.75, 0.5, 26.25, 23 };
                q.clip_radii = .{ 1, 2, 0, 3 };
                q.uv = .{ -1.25, 0.875, 2.25, -0.5 };
                q.border = 1.3;
                q.border_color = Color.rgba(71, 205, 43, 202).bitsOf();
                q.opacity = 0.65;
                q.params = switch (kind) {
                    .solid => @splat(0),
                    .linear => features.linear(.rgba(50, 150, 250, 197), 0.7),
                    .radial => features.radial(.rgba(10, 250, 80, 218), .{ 0.3, 0.8 }, 9.5),
                    .shadow => features.shadow(2.5),
                    .nine_slice => features.nineSlice(.{ 3, 2, 4, 5 }, .{ 0.2, 0.3, 0.8, 0.7 }),
                    .dashed => features.dashed(3.25, 1.5),
                    .dotted => features.dotted(1.75),
                };
                for (fb.pixels, 0..) |*px, i| px.* = @as(u32, @intCast(i)) *% 0x21098571;
                @memcpy(reference.pixels, fb.pixels);
                const scissor = [4]u32{ 3, 2, 61, 49 };
                const gfx: Software = .{ .quads = &.{q}, .scale = scale };
                gfx.drawBatch(.{ .fb = &fb, .scissor = scissor }, .{ .first = 0, .count = 1, .texture = .white, .material = .solid });
                shade(kind, .{ .fb = &reference, .scissor = scissor }, &q, Image.white, scale);
                try testing.expectEqualSlices(u32, reference.pixels, fb.pixels);
            }
        }
    }
}

/// Exercise actual drawText/drawBatch dispatch against the unspecialized shader.
/// Initialize padding and destination alpha too, so clipping and source-over are
/// checked rather than only comparing RGB against an opaque cleared framebuffer.
fn expectTexturedMatches(comptime kind: features.Kind, q: Quad, img: Image, scale: f32, format: Format, comptime text: bool) !void {
    var fast: Frame(67, 53) = .{};
    var slow: Frame(67, 53) = .{};
    var fb = fast.fb(format);
    var reference = slow.fb(format);
    for (fb.pixels, 0..) |*px, i| px.* = @as(u32, @intCast(i)) *% 0x21098571;
    @memcpy(reference.pixels, fb.pixels);
    const scissor = [4]u32{ 3, 2, 61, 49 };
    const gfx: Software = .{
        .quads = &.{q},
        .glyphs = .{ .quads = &.{q}, .first = &.{0}, .count = &.{1} },
        .images = &.{img},
        .scale = scale,
    };
    const target: Target = .{ .fb = &fb, .scissor = scissor };
    if (text) gfx.drawText(target, 0) else gfx.drawBatch(target, .{ .first = 0, .count = 1, .texture = .white, .material = .solid });
    shade(kind, .{ .fb = &reference, .scissor = scissor }, &q, img, scale);
    try testing.expectEqualSlices(u32, reference.pixels, fb.pixels);
}

fn testTexels() [35]u32 {
    var texels: [35]u32 = undefined;
    for (&texels, 0..) |*px, i| px.* = Color.rgba(@truncate(i * 61), @truncate(i * 103), @truncate(i * 19), @truncate(i * 37)).bitsOf();
    return texels;
}

test "ordinary glyph quads preserve RGBA samples, fractional coverage and HiDPI" {
    const texels = testTexels();
    const img: Image = .{ .pixels = &texels, .width = 7, .height = 5 };
    for ([_]Format{ .rgba8, .bgra8 }) |format| {
        for ([_]f32{ 0.75, 1, 1.25, 2.5 }) |scale| {
            for ([_]f32{ 0, 0.1, 0.5, 0.9 }) |offset| {
                for ([_]f32{ 0, 0.17, 0.65, 1 }) |opacity| {
                    var q = testQuad(.{ 1 + offset, 0.3 + offset, 25.7 + offset, 19.4 + offset }, .rgba(17, 149, 231, 193));
                    q.clip = .{ 1.5, 2.5, 26.25, 20.5 };
                    q.uv = .{ -0.125, 1.25, 0.875, -0.25 };
                    q.opacity = opacity;
                    try testing.expect(plainTexturedRect(.all, &q));
                    try expectTexturedMatches(.solid, q, img, scale, format, true);
                }
            }
        }
    }
}

test "textured rectangle dispatch retains the full shader for radius border transform and material" {
    const texels = testTexels();
    const img: Image = .{ .pixels = &texels, .width = 7, .height = 5 };
    inline for (0..6) |mode| {
        var q = testQuad(.{ 1.3, 2.7, 27.4, 22.2 }, .rgba(233, 81, 106, 129));
        q.clip = .{ 1.5, 2.5, 26.25, 20.5 };
        q.opacity = 0.65;
        const kind: features.Kind = if (mode == 4) .linear else .solid;
        switch (mode) {
            0 => q.radii = .{ 0, 3, 1, 2 },
            1 => q.clip_radii = .{ 0, 3, 1, 2 },
            2 => {
                q.border = 1.25;
                q.border_color = Color.rgba(75, 205, 43, 197).bitsOf();
            },
            3 => q.xform = .{ 1, 0.08, -0.05, 1, 1.5, -0.25 },
            4 => q.params = features.linear(.rgba(19, 85, 211, 165), 0.7),
            // Ordinary image quads use the same specialization as text runs.
            5 => {},
            else => unreachable,
        }
        try testing.expectEqual(mode == 5, plainTexturedRect(.all, &q));
        for ([_]Format{ .rgba8, .bgra8 }) |format|
            for ([_]f32{ 0.75, 1, 1.25, 2.5 }) |scale|
                try expectTexturedMatches(kind, q, img, scale, format, false);
    }
}

/// Compare coverage-byte rendering with the old white-RGBA representation, not
/// merely another path that shares the same Alpha8 sampler. The framebuffer has
/// arbitrary alpha and initialized padding, and the scissor starts inside a vector.
fn expectAlpha8Matches(comptime kind: features.Kind, q: Quad, scale: f32, format: Format, comptime text: bool) !void {
    var coverage: [35]u8 = undefined;
    var expanded: [35]u32 = undefined;
    for (&coverage, &expanded, 0..) |*a, *rgba_pixel, i| {
        a.* = @truncate(i * 37);
        if (i == 1) a.* = 255;
        if (i == 2) a.* = 254;
        if (i == 3) a.* = 1;
        rgba_pixel.* = 0x00ff_ffff | (@as(u32, a.*) << 24);
    }
    const compact: Image = .{ .alpha8 = &coverage, .width = 7, .height = 5 };
    const rgba_image: Image = .{ .pixels = &expanded, .width = 7, .height = 5 };
    var fast: Frame(67, 53) = .{};
    var slow: Frame(67, 53) = .{};
    var fb = fast.fb(format);
    var reference = slow.fb(format);
    for (fb.pixels, 0..) |*px, i| px.* = @as(u32, @intCast(i)) *% 0x21098571;
    @memcpy(reference.pixels, fb.pixels);
    const gfx: Software = .{
        .quads = &.{q},
        .glyphs = .{ .quads = &.{q}, .first = &.{0}, .count = &.{1} },
        .images = &.{compact},
        .scale = scale,
    };
    const scissor = [4]u32{ 3, 2, 61, 49 };
    const target: Target = .{ .fb = &fb, .scissor = scissor };
    if (text) gfx.drawText(target, 0) else gfx.drawBatch(target, .{ .first = 0, .count = 1, .texture = .white, .material = .solid });
    shade(kind, .{ .fb = &reference, .scissor = scissor }, &q, rgba_image, scale);
    try testing.expectEqualSlices(u32, reference.pixels, fb.pixels);
    // The public reference entry point honors Image's storage contract too.
    for (fb.pixels, 0..) |*px, i| px.* = @as(u32, @intCast(i)) *% 0x21098571;
    shade(kind, target, &q, compact, scale);
    try testing.expectEqualSlices(u32, reference.pixels, fb.pixels);
}

test "Alpha8 glyphs match expanded RGBA across coverage geometry and framebuffer formats" {
    for ([_]Format{ .rgba8, .bgra8 }) |format| {
        for ([_]f32{ 0.75, 1, 1.25, 1.5, 2.5 }) |scale| {
            for ([_]f32{ 0, 0.17, 0.65, 1 }) |opacity| {
                var q = testQuad(.{ 1.1, 0.3, 25.7, 19.4 }, .rgba(17, 149, 231, 193));
                q.clip = .{ 1.5, 2.5, 26.25, 20.5 };
                q.uv = .{ -0.125, 1.25, 0.875, -0.25 };
                q.opacity = opacity;
                try expectAlpha8Matches(.solid, q, scale, format, true);
                try expectAlpha8Matches(.solid, q, scale, format, false);
            }
        }
    }
}

test "Alpha8 general materials transforms borders and rounded clips match expanded RGBA" {
    inline for (all_kinds) |kind| {
        var q = testQuad(.{ 1.3, 2.7, 27.4, 22.2 }, .rgba(233, 81, 106, 129));
        q.xform = .{ 1, 0.08, -0.05, 1, 1.5, -0.25 };
        q.radii = .{ 0, 1, 3, 2 };
        q.clip = .{ 0.75, 0.5, 26.25, 23 };
        q.clip_radii = .{ 1, 2, 0, 3 };
        q.uv = .{ -1.25, 0.875, 2.25, -0.5 };
        q.border = 1.3;
        q.border_color = Color.rgba(71, 205, 43, 202).bitsOf();
        q.opacity = 0.65;
        q.params = switch (kind) {
            .solid => @splat(0),
            .linear => features.linear(.rgba(50, 150, 250, 197), 0.7),
            .radial => features.radial(.rgba(10, 250, 80, 218), .{ 0.3, 0.8 }, 9.5),
            .shadow => features.shadow(2.5),
            .nine_slice => features.nineSlice(.{ 3, 2, 4, 5 }, .{ 0.2, 0.3, 0.8, 0.7 }),
            .dashed => features.dashed(3.25, 1.5),
            .dotted => features.dotted(1.75),
        };
        for ([_]Format{ .rgba8, .bgra8 }) |format|
            for ([_]f32{ 0.75, 1.25, 2 }) |scale|
                try expectAlpha8Matches(kind, q, scale, format, false);
    }
}

test "shade: a quad that starts right of the scissor, off a lane boundary, draws nothing" {
    // A width of whole vectors leaves rows no padding, so a box starting past the scissor's
    // right edge would read the vector after the row.
    const w = 2 * simd.lanes;
    var f: Frame(w, 4) = .{};
    var fb = f.fb(.rgba8);
    try testing.expectEqual(@as(u32, w), fb.stride);
    fb.clear(.black);
    const t: Target = .{ .fb = &fb, .scissor = fb.all() };
    var q = testQuad(.{ w + 5, 1, w + 13, 3 }, .rgba(255, 0, 0, 128));
    shade(.solid, t, &q, Image.white, 1);
    q.fill = Color.rgb(255, 0, 0).bitsOf();
    shade(.solid, t, &q, Image.white, 1);
    for (0..4) |y| for (0..w) |x| try testing.expectEqual(Color.black, fb.at(@intCast(x), @intCast(y)));
}

test "redraw: only the damage rects change, cleared to the background first" {
    var st: conformance.Storage = .{};
    st.load(&conformance.scenes[0]);
    var f: Frame(160, 120) = .{};
    var fb = f.fb(.rgba8);
    fb.clear(.rgb(1, 2, 3));
    var s: Software = .{};
    s.prepare({}, &st.draw, st.glyphs(), .{ 160, 120 }, 1);
    st.draw.damage = .empty;
    st.draw.damage.add(.{ 10, 10, 30, 30 });
    s.redraw(&fb, fb.all(), &st.draw, .black);
    try testing.expectEqual(Color.rgb(1, 2, 3), fb.at(9, 15));
    try testing.expectEqual(Color.rgb(1, 2, 3), fb.at(30, 15));
    try testing.expectEqual(Color.rgb(30, 31, 36), fb.at(10, 10)); // the panel, outside the card
    try testing.expectEqual(Color.rgb(90, 140, 255), fb.at(29, 29)); // the card, inside its border
}

fn drawBand(s: *const Software, fb: *Framebuffer, draw: *const DrawList, k: u32, n: u32) void {
    s.redraw(fb, tile(fb, k, n), draw, .black);
}

test "drawText: a frame with text runs and no glyphs draws its quads and no text" {
    var st: conformance.Storage = .{};
    st.load(&conformance.scenes[2]);
    try testing.expectEqualStrings("text", conformance.scenes[2].name);
    var f: Frame(160, 120) = .{};
    var fb = f.fb(.rgba8);
    fb.clear(.black);
    var s: Software = .{};
    s.prepare({}, &st.draw, .{}, .{ 160, 120 }, 1);
    iface.render(&s, .{ .fb = &fb, .scissor = fb.all() }, &st.draw);
    // The panel and the bar, and no glyph over either.
    for (0..120) |y| for (0..160) |x| {
        const want: Color = if (y >= 90) .rgb(90, 140, 255) else .rgb(30, 31, 36);
        try testing.expectEqual(want, fb.at(@intCast(x), @intCast(y)));
    };
}

test "tiles: bands drawn on separate threads give the single-threaded frame" {
    if (@import("builtin").single_threaded) return error.SkipZigTest;
    var one: Frame(160, 120) = .{};
    var four: Frame(160, 120) = .{};
    for (&conformance.scenes) |*scene| {
        var st: conformance.Storage = .{};
        st.load(scene);
        var s: Software = .{};
        s.prepare({}, &st.draw, st.glyphs(), scene.viewport, 1);
        var a = one.fb(.rgba8);
        var b = four.fb(.rgba8);
        s.redraw(&a, a.all(), &st.draw, .black);
        var threads: [4]std.Thread = undefined;
        for (&threads, 0..) |*th, k| th.* = try std.Thread.spawn(.{}, drawBand, .{ &s, &b, &st.draw, @as(u32, @intCast(k)), 4 });
        for (threads) |th| th.join();
        for (0..120) |y| try testing.expectEqualSlices(u32, a.pixels[y * a.stride ..][0..160], b.pixels[y * b.stride ..][0..160]);
    }
}

test "SoftwareFor: pixel equivalence of specialized paint paths" {
    inline for (comptime .{
        features.Usage{},
        features.Usage{ .radius = true },
        features.Usage{ .border = true, .radius = true, .kinds = .initMany(&.{ .solid, .dotted }) },
        features.Usage{ .image = true, .kinds = .initMany(&.{ .solid, .linear }) },
    }) |use| {
        var test_frame: Frame(16, 8) = .{};
        var reference_frame: Frame(16, 8) = .{};
        var fb = test_frame.fb(.rgba8);
        var ref = reference_frame.fb(.rgba8);
        fb.clear(.black);
        ref.clear(.black);
        var q = testQuad(.{ 0.25, 0.5, 13.25, 7 }, .rgba(10, 90, 220, 160));
        q.clip = .{ 1, 0, 12.5, 7 };
        if (use.radius) {
            q.radii = .{ 2, 3, 1, 0 };
            q.clip_radii = .{ 3, 1, 4, 2 };
        }
        if (use.border) {
            q.border = 2;
            q.border_color = Color.white.bitsOf();
            q.params = features.dotted(1);
        }
        if (use.image) q.params = features.linear(.white, 0.5);
        const imgs = [_]Image{ Image.white, .{ .pixels = &.{ 0xfffefdfc, 0xff030201 }, .width = 2, .height = 1 } };
        const batch: draw_list.Batch = .{ .first = 0, .count = 1, .material = .solid, .texture = @fromBackingInt(@intFromBool(use.image)) };
        const full: Software = .{ .quads = &.{q}, .images = &imgs };
        var small: SoftwareFor(use) = .{ .quads = &.{q} };
        if (comptime use.image) small.images = &imgs;
        full.drawBatch(.{ .fb = &ref, .scissor = ref.all() }, batch);
        small.drawBatch(.{ .fb = &fb, .scissor = fb.all() }, batch);
        try testing.expectEqualSlices(u32, ref.pixels, fb.pixels);
    }
}
