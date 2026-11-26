//! The software back end: draws a `DrawList` into a caller-owned framebuffer on the CPU, with the
//! semantics of the stock quad shader (src/render/shaders/quad.wgsl) so its pixels match the GPU
//! back ends' golden images (`ci/run.sh sw-golden`). No GPU, no allocation, no OS.
//!
//! Each quad is shaded over the pixels of its bounding box, `simd.lanes` pixels of one row at a
//! time, with the shader's math as vector expressions: rounded-box distance, border, clip and
//! rounded clip as coverage, the per-quad feature of `params.x`, then premultiplied "over"
//! blending (Porter and Duff 1984: out = src + dst * (1 - src.a)). Per pixel there is no branch;
//! per quad there is one, picking the loop compiled for its feature (what a GPU back end does
//! with one pipeline and a uniform branch). A batch bound to the white texture compiles out the
//! texture sampling.
//!
//! Framebuffer rows are padded to whole vectors, so shading uses whole vectors with a mask for
//! the pixels outside the quad or the scissor.
//!
//! The quads of a UI are nearly all untransformed solid rects, glyphs and images, and those take
//! loops specialised to them (`fast_paths`), which split the shader's terms into one part per
//! column and one per row, computed once each:
//!
//!   rectQuad     fills the interior whole vectors at a time; the frame around it (`rectFrame`)
//!                takes a square root only in the corners
//!   texturedQuad an image or a lone glyph: coverage and texel column per column, texel row per row
//!   textStrip    a line of glyphs a row at a time; from an alpha atlas (`Image.alpha8`) the
//!                texels of a vector come from one or two 16-byte loads and a byte shuffle, and
//!                vectors whose texels are all 0 are skipped
//!
//! Their branches are per vector at most (all-zero texels, a corner), never per lane. Blending is
//! in 8-bit integers, two channels per 16-bit field of a u32 (`overSa`), as pixman does; it may
//! differ from float arithmetic by a level. `frame` starts at the last quad that covers the
//! target opaquely, so what lies under a full-window panel, the clear included, is not drawn.

const std = @import("std");
const builtin = @import("builtin");
const simd = @import("../../core/simd.zig");
const types = @import("../../core/types.zig");
const draw_list = @import("../../draw/draw_list.zig");
const damage = @import("../../draw/damage.zig");
pub const bands = @import("bands.zig");
pub const canvas = @import("canvas.zig");
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
        const inv = simd.u((255 - a) * 0x00010001);
        for (b[1]..b[3]) |y| {
            const row = fb.pixels[y * fb.stride ..][0..fb.stride];
            var x = std.mem.alignBackward(u32, b[0], W);
            while (x < b[2]) : (x += W) {
                const old: U = row[x..][0..W].*;
                const lo = rb + mul16(old & mask, inv);
                const hi = ga + mul16((old >> @splat(8)) & mask, inv);
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

/// A caller-owned texture: `width` x `height` texels, RGBA8 (`Color` bits) in `pixels` or
/// coverage in `alpha8`, sampled nearest with clamped coordinates, as the GPU back ends'
/// samplers do. The slice read stays alive while drawing; both dimensions are positive.
pub const Image = struct {
    pixels: []const u32 = &.{},
    width: u32,
    height: u32,
    /// The texture as 8-bit alpha with implicit white RGB (a glyph atlas): `width * height`
    /// bytes, row by row, or empty. Nonempty, it is read instead of `pixels`, which may then be
    /// empty: a quarter of the bytes, no expanded RGBA copy, and text skips runs of texels that
    /// are 0.
    alpha8: []const u8 = &.{},

    /// Texture 0 (`types.Texture.white`): put it at row 0 of `Software.images`.
    pub const white: Image = .{ .pixels = &.{0xffff_ffff}, .width = 1, .height = 1 };

    /// Whether `img` is the white texture, which needs no sampling.
    fn isWhite(img: Image) bool {
        return img.alpha8.len == 0 and img.pixels.ptr == white.pixels.ptr and img.width == 1 and img.height == 1;
    }
};

/// `any` reads the image as it comes (alpha8 when it has coverage, else RGBA), one branch per
/// sample: size builds compile the shader loop once instead of once per encoding.
const ImageEncoding = enum { rgba8, alpha8, any };

/// Where draws land: the framebuffer and a scissor rect in pixels (x0, y0, x1, y1). Pixels outside
/// the scissor are never written, which is what splits a frame into damage rects and tiles.
pub const Target = struct {
    fb: *Framebuffer,
    scissor: [4]u32,
};

/// The back end with every feature of the stock material compiled in, and the canvas.
pub const Software = SoftwareOf(all_kinds);

/// Every `features.Kind`, in declaration order.
pub const all_kinds: []const features.Kind = std.enums.values(features.Kind);

/// Colour of a quad whose feature this build left out: drawn over its covered pixels, opaque, so
/// a missing feature shows instead of turning into another one.
pub const missing_kind: Color = .rgb(255, 0, 255);

/// The back end compiled for the feature kinds in `kinds` only (`solid` must be one). Each kind
/// is its own shading loop (`shade`), and a loop no kind selects is not compiled: a build that
/// draws only solid quads leaves out the gradients' `sin`/`cos`, the shadow's `exp`, nine-slice
/// and the border patterns. A quad of a kind left out is filled with `missing_kind`. A subset
/// also leaves out the canvas loops (`canvas.zig`): its canvas commands draw nothing.
pub fn SoftwareOf(comptime kinds: []const features.Kind) type {
    return SoftwareCoords(kinds, false);
}

/// Quantize bare-metal rectangle and clip coordinates to Q12.4 when requested.
pub fn SoftwareCoords(comptime kinds: []const features.Kind, comptime fixed_point: bool) type {
    var use = features.Usage.all;
    use.kinds = .initMany(kinds);
    return Renderer(use, fixed_point, kinds.len == all_kinds.len and !fixed_point);
}

/// Software renderer for the features collected from a comptime UI.
pub fn SoftwareFor(comptime use: features.Usage) type {
    return Renderer(use, false, false);
}

fn Renderer(comptime use: features.Usage, comptime fixed_point: bool, comptime with_canvas: bool) type {
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
        /// The list `prepare` was given, for `drawCanvas`.
        list: if (with_canvas) ?*const DrawList else void = if (with_canvas) null else {},

        /// Nothing to upload: the back end reads the caller's rows in place.
        pub fn prepare(s: *Self, _: void, draw: *const DrawList, glyphs: iface.Glyphs, _: [2]f32, scale: f32) void {
            s.quads = draw.quads[0..draw.quad_len];
            if (with_canvas) s.list = draw;
            if (use.text) s.glyphs = glyphs;
            s.scale = scale;
        }

        pub fn drawBatch(s: *const Self, t: Target, batch: draw_list.Batch) void {
            const img = if (use.image) s.images[@backingInt(batch.texture)] else Image.white;
            s.drawQuads(t, s.quads[batch.first..][0..batch.count], img);
        }

        /// Canvas command `k` of the prepared list (`iface.drawsCanvas`), glyphs from the glyph
        /// atlas. Nothing in a build without the canvas (`SoftwareOf` a subset).
        pub fn drawCanvas(s: *const Self, t: Target, k: u32) void {
            if (with_canvas) s.drawCanvasOf(t, s.list.?, k);
        }

        fn drawCanvasOf(s: *const Self, t: Target, list: anytype, k: u32) void {
            if (comptime !(with_canvas and @hasField(@typeInfo(@TypeOf(list)).pointer.child, "canvases"))) return;
            const atlas = if (use.text) s.images[@backingInt(s.glyphs.texture)] else Image.white;
            canvas.draw(t, list, k, s.scale, atlas);
        }

        pub fn drawText(s: *const Self, t: Target, run: u32) void {
            if (use.text) s.drawGlyphSpan(t, s.glyphs.span(run));
        }

        /// The `span[1]` glyph quads from `span[0]`: consecutive text runs at once
        /// (`iface.drawUntilCustom`), so a line's strip may run on across them.
        pub fn drawGlyphSpan(s: *const Self, t: Target, span: [2]u32) void {
            if (!use.text) return;
            const g = s.glyphs;
            s.drawGlyphs(t, g.quads[span[0]..][0..span[1]], s.images[@backingInt(g.texture)]);
        }

        /// Glyph quads. Consecutive glyphs on one line (`stripLen`) are drawn as one strip, a
        /// row of the whole line at a time; any other quad as `drawQuads` draws it.
        fn drawGlyphs(s: *const Self, t: Target, quads: []const Quad, img: Image) void {
            var i: usize = 0;
            while (i < quads.len) {
                const n = if (fixed_point or !fast_paths or !(use.image or use.text)) 1 else stripLen(quads[i..], img);
                if (n < 2 or !textStrip(t, quads[i..][0..n], img, s.scale)) {
                    s.drawQuads(t, quads[i..][0..n], img);
                }
                i += n;
            }
        }

        fn drawQuads(s: *const Self, t: Target, quads: []const Quad, img: Image) void {
            // The fast paths divide by the scale; the shader loop draws nothing at such a scale.
            if (!std.math.isFinite(s.scale) or s.scale <= 0) return;
            // Builds optimized for size keep one copy of the shader loop (about 9 KB of flash
            // each on a microcontroller): the encoding is read per sample instead.
            if (!fast_paths) return s.drawQuadsUsing(use, .any, t, quads, img);
            // The texture is constant across the batch: a white one compiles out the UV
            // conversion, the gathers and the channel unpacking of every covered pixel.
            if (img.alpha8.len != 0) {
                s.drawQuadsUsing(use, .alpha8, t, quads, img);
            } else if (img.isWhite()) {
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
                // Whatever the quad's transform, it draws only inside its clip: one wholly above
                // or below the target (another band of a threaded frame) costs two compares.
                if (q.clip[3] * s.scale <= @as(f32, @floatFromInt(t.scissor[1])) or
                    q.clip[1] * s.scale >= @as(f32, @floatFromInt(t.scissor[3]))) continue;
                const code: u32 = @bitCast(q.params[0]);
                // Untransformed quads of the solid kind with a square clip, which is nearly every
                // quad of a UI, take loops specialised to them (one branch per quad).
                if (fast_paths and code == 0 and plain(q)) {
                    if (comptime !(shading.image or shading.text)) {
                        rectQuad(shading, t, q, s.scale);
                        continue;
                    }
                    if (q.border < 0.001 and @reduce(.Max, @as(@Vector(4, f32), q.radii)) <= 0) {
                        texturedQuad(encoding, t, q, img, s.scale);
                        continue;
                    }
                }
                // One loop per feature; unknown codes draw as solid, as the shader's selects do.
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
                s.frame(.{ .fb = fb, .scissor = box }, draw, background);
            }
        }

        /// `t.scissor` cleared to `background` with the commands of `list` drawn over it, custom
        /// ones skipped. `list` is a `DrawList` or anything with its `cmd_len` and `command`.
        /// Whatever the last quad that covers the whole scissor opaquely (`covers`) is drawn
        /// over, the clear included, is never seen, so it is not drawn: the frame starts at that
        /// quad. A full-window background panel saves a clear of the window.
        pub fn frame(s: *const Self, t: Target, list: anytype, background: Color) void {
            var i: u32 = 0;
            if (s.cover(t.scissor, list)) |at| {
                var batch = list.command(at[0]).quads;
                batch.first += at[1];
                batch.count -= at[1];
                s.drawBatch(t, batch);
                i = at[0] + 1;
            } else t.fb.fill(t.scissor, background);
            while (i < list.cmd_len) : (i += 1) switch (list.command(i)) {
                .quads => |batch| s.drawBatch(t, batch),
                .text => |run| if (use.text) {
                    const span = iface.glyphSpan(s.glyphs, list, &i, run);
                    s.drawGlyphSpan(t, span);
                },
                .custom => {},
                .canvas => |k| s.drawCanvasOf(t, list, k),
            };
        }

        /// The command and the quad in its batch of the last quad of `list` that `covers` `box`.
        fn cover(s: *const Self, box: [4]u32, list: anytype) ?[2]u32 {
            // Fixed-point quads are drawn at their quantized rect, not the one tested here.
            if (fixed_point or box[0] >= box[2] or box[1] >= box[3]) return null;
            var i = list.cmd_len;
            while (i > 0) {
                i -= 1;
                const batch = switch (list.command(i)) {
                    .quads => |batch| batch,
                    else => continue,
                };
                if (use.image and batch.texture != .white) continue;
                var k = batch.count;
                while (k > 0) {
                    k -= 1;
                    if (covers(use, &s.quads[batch.first + k], s.scale, box)) return .{ i, k };
                }
            }
            return null;
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
    /// Threads to draw with, a band of rows each (`bands`), set by a host that has them; null
    /// draws on the caller's thread alone.
    pool: ?*bands.Pool = null,

    /// Draws `list` over `fb`, which holds the last frame: only the rects of `list.damage` (all
    /// of `fb` unless the context tracks damage, `Context.trackDamage`), each cleared and drawn.
    pub fn draw(s: *Setup, fb: *Framebuffer, list: *const DrawList, glyphs: iface.Glyphs, background: Color, scale: f32) void {
        s.gfx.prepare({}, list, glyphs, .{ 0, 0 }, scale);
        for (0..damage.max_rects) |k| {
            const r = damage.Region.scissor(list.damage.rect(@intCast(k)), .{ fb.width, fb.height }, scale);
            if (r[2] == 0 or r[3] == 0) continue;
            const job: Band = .{ .gfx = &s.gfx, .fb = fb, .box = .{ r[0], r[1], r[0] + r[2], r[1] + r[3] }, .list = list, .background = background };
            // One band a thread: every band walks the whole list, so more bands cost more than
            // the balance they buy.
            if (s.pool) |pool| pool.run(pool.count, &job, Band.draw) else job.draw(0, 1);
        }
    }

    const Band = struct {
        gfx: *const Software,
        fb: *Framebuffer,
        box: [4]u32,
        list: *const DrawList,
        background: Color,

        /// Rows `k` of `n` of the box.
        fn draw(b: *const Band, k: u32, n: u32) void {
            const h = b.box[3] - b.box[1];
            const box: [4]u32 = .{ b.box[0], b.box[1] + h * k / n, b.box[2], b.box[1] + h * (k + 1) / n };
            if (box[1] < box[3]) b.gfx.frame(.{ .fb = b.fb, .scissor = box }, b.list, b.background);
        }
    };
};

/// Whether quads take the loops specialised to their case (`rectQuad`, `texturedQuad`,
/// `textStrip`) or all go through the shader loop. A build optimised for size keeps the one loop:
/// the specialised ones cost a microcontroller image about 7 to 12 KiB of flash.
const fast_paths = !for ([_][]const u8{ "small", "ReleaseSmall" }) |name| {
    // The mode's name differs between Zig versions.
    if (std.mem.eql(u8, @tagName(builtin.mode), name)) break true;
} else false;

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
pub inline fn spanMask(x: u32, x0: u32, x1: u32) B {
    const xs = simd.iota + simd.u(x);
    return (xs >= simd.u(x0)) & (xs < simd.u(x1));
}

/// True when `q` has no transform and a square clip: its shading then needs neither the
/// inverse transform nor the clip's distance field.
fn plain(q: *const Quad) bool {
    const xform: [6]f32 = q.xform;
    return std.mem.eql(f32, &xform, &.{ 1, 0, 0, 1, 0, 0 }) and
        @reduce(.And, @as(@Vector(4, f32), q.clip_radii) <= @as(@Vector(4, f32), @splat(0)));
}

/// The pixels of an untransformed quad the shader loop can change, cut by the scissor: those
/// whose centre passes its `geo` and `inside` tests, rect[0] <= c < rect[2] and clip[0] <= c <=
/// clip[2] on each axis, in the same arithmetic. (The loop's own box reaches a pixel past both
/// far edges; those pixels get alpha 0.)
fn plainBox(q: *const Quad, scale: f32, scissor: [4]u32) [4]u32 {
    const r = q.rect;
    const c = q.clip;
    // Both axes at once.
    const p = axisPixelsN(2, .{ @max(r[0], c[0]), @max(r[1], c[1]) }, .{ r[2], r[3] }, .{ c[2], c[3] }, scale, 1 / scale);
    return clampBox(.{ p[0][0], p[0][1], p[1][0], p[1][1] }, scissor);
}

/// First and end pixel whose centre (p + 0.5) / scale is >= lo, < hi_open and <= hi_closed: an
/// estimate, settled by the loop's own test on the pixels next to it.
fn axisPixels(lo: f32, hi_open: f32, hi_closed: f32, scale: f32, inv: f32) [2]u32 {
    const p = axisPixelsN(1, .{lo}, .{hi_open}, .{hi_closed}, scale, inv);
    return .{ p[0][0], p[1][0] };
}

/// `axisPixels` on `n` axes with selects, the pixel numbers kept as floats (exact to 2^24): the
/// same tests on the same values, so the same pixels, without a branch per test.
fn axisPixelsN(comptime n: comptime_int, lo: @Vector(n, f32), hi_open: @Vector(n, f32), hi_closed: @Vector(n, f32), scale: f32, inv: f32) [2]@Vector(n, u32) {
    const V = @Vector(n, f32);
    const zero: V = @splat(0);
    const one: V = @splat(1);
    const half: V = @splat(0.5);
    const limit: V = @splat(1 << 24);
    const s: V = @splat(scale);
    const k: V = @splat(inv);
    var first = std.math.clamp(@ceil(lo * s - half), zero, limit);
    first = @select(f32, (first > zero) & ((first - one + half) * k >= lo), first - one, first);
    first = @select(f32, (first < limit) & !((first + half) * k >= lo), first + one, first);
    var end = std.math.clamp(@min(@ceil(hi_open * s - half), @floor(hi_closed * s - half) + one), zero, limit);
    const before = (end - one + half) * k;
    end = @select(f32, (end > zero) & !((before < hi_open) & (before <= hi_closed)), end - one, end);
    const at = (end + half) * k;
    end = @select(f32, (end < limit) & (at < hi_open) & (at <= hi_closed), end + one, end);
    return .{ @intFromFloat(first), @intFromFloat(@max(end, first)) };
}

inline fn pixelCentre(p: u32, inv: f32) f32 {
    return (@as(f32, @floatFromInt(p)) + 0.5) * inv;
}

/// An untransformed, untextured quad of the solid kind with a square clip. Pixels whose centres
/// lie at least max(radius, border + half a pixel) inside its rect, and inside the clip, have
/// full coverage and no border: they take the fill (or its blend) whole vectors at a time. The
/// frame of pixels around them is the shader's rounded box with its terms split by column and
/// row (`rectFrame`).
fn rectQuad(comptime use: features.Usage, t: Target, q: *const Quad, scale: f32) void {
    const box = plainBox(q, scale, t.scissor);
    if (box[0] >= box[2] or box[1] >= box[3]) return;
    const inner = interior(use, q, scale, box);
    const parts: [4][4]u32 = if (inner[0] < inner[2] and inner[1] < inner[3]) .{
        .{ box[0], box[1], box[2], inner[1] },
        .{ box[0], inner[3], box[2], box[3] },
        .{ box[0], inner[1], inner[0], inner[3] },
        .{ inner[2], inner[1], box[2], inner[3] },
    } else .{ box, @splat(0), @splat(0), @splat(0) };
    if (inner[0] < inner[2] and inner[1] < inner[3]) {
        const color = interiorColor(q);
        if (color.a > 0) t.fb.solid(inner, color);
        // A rect on whole pixels has no frame.
        if (std.meta.eql(inner, box)) return;
    }
    const bordered = use.border and q.border >= 0.001;
    if (bordered) rectFrame(use, true, t, q, scale, &parts) else rectFrame(use, false, t, q, scale, &parts);
}

/// The pixels of `box` (a `plainBox`) a `rectQuad` fills whole: those whose centres lie at
/// least max(radius, border + half a pixel) inside its rect, and inside the clip, where coverage
/// is full and there is no border. Centre x + 0.5 is inside when |(x + 0.5) / scale - cx| <=
/// hx - inset.
fn interior(comptime use: features.Usage, q: *const Quad, scale: f32, box: [4]u32) [4]u32 {
    const x0, const y0, const x1, const y1 = q.rect;
    const hx = (x1 - x0) * 0.5;
    const hy = (y1 - y0) * 0.5;
    const cx = (x0 + x1) * 0.5;
    const cy = (y0 + y1) * 0.5;
    const radius: f32 = if (use.radius) @min(@reduce(.Max, @as(@Vector(4, f32), q.radii)), @min(hx, hy)) else 0;
    const bordered = use.border and q.border >= 0.001;
    const inset = @max(radius, (if (bordered) q.border else 0) + 0.5 / scale);
    const c = q.clip;
    const lo: @Vector(2, f32) = .{ @max(cx - (hx - inset), c[0]), @max(cy - (hy - inset), c[1]) };
    const hi: @Vector(2, f32) = .{ @min(cx + (hx - inset), c[2]), @min(cy + (hy - inset), c[3]) };
    const half: @Vector(2, f32) = @splat(0.5);
    const s: @Vector(2, f32) = @splat(scale);
    const first = @ceil(lo * s - half);
    const end = @floor(hi * s - half) + @as(@Vector(2, f32), @splat(1));
    return clampBox(toPixels(.{ first[0], first[1], @max(end[0], first[0]), @max(end[1], first[1]) }), box);
}

/// Whether `q`, untextured, fills every pixel of `box` with an opaque colour: a `rectQuad` whose
/// interior holds the box.
fn covers(comptime use: features.Usage, q: *const Quad, scale: f32, box: [4]u32) bool {
    // What the interior needs first, cheaply, since `cover` asks of every quad: an opaque fill
    // and the centres of the box's edge pixels inside the rect and the clip. (NaN fails too.)
    const V = @Vector(4, f32);
    const s: V = @splat(scale);
    const near: V = @as(V, .{ q.rect[0], q.rect[1], q.clip[0], q.clip[1] }) * s;
    const far: V = @as(V, .{ q.rect[2], q.rect[3], q.clip[2], q.clip[3] }) * s;
    const b: V = @floatFromInt(@as(@Vector(4, u32), .{ box[0], box[1], box[0], box[1] }));
    const e: V = @floatFromInt(@as(@Vector(4, u32), .{ box[2], box[3], box[2], box[3] }));
    const half: V = @splat(0.5);
    if (q.fill >> 24 != 255 or !@reduce(.And, near <= b + half) or !@reduce(.And, far >= e - half)) return false;
    if (@as(u32, @bitCast(q.params[0])) != 0 or !plain(q) or interiorColor(q).a != 255) return false;
    const inner = interior(use, q, scale, plainBox(q, scale, box));
    return inner[0] <= box[0] and inner[1] <= box[1] and inner[2] >= box[2] and inner[3] >= box[3];
}

/// The fill of a `rectQuad`'s interior: its colour at the quad's opacity.
fn interiorColor(q: *const Quad) Color {
    var color: Color = @bitCast(q.fill);
    color.a = @intFromFloat(@round(std.math.clamp(@as(f32, @floatFromInt(color.a)) * q.opacity, 0, 255)));
    return color;
}

/// The frame of a `rectQuad`: the shader's rounded box with no transform, no texture and a square
/// clip, over pixels that all pass its `geo` and `inside` tests. Its distance there is
/// len(max(qx, 0), max(qy, 0)) + min(max(qx, qy), 0) - r with qx = |lx| - hx + r, qy = |ly| - hy + r
/// and r the radius of the pixel's quadrant: |lx| - hx and the quadrant's column side are terms of
/// the column, computed once per column, |ly| - hy and its row side terms of the row. The square
/// root is needed only where both qx and qy are positive, in the corners; elsewhere the length is
/// the positive one of the two, which the root gives to the last bit too. The blend is 8-bit.
fn rectFrame(comptime use: features.Usage, comptime bordered: bool, t: Target, q: *const Quad, scale: f32, parts: []const [4]u32) void {
    const x0, const y0, const x1, const y1 = q.rect;
    const hx = (x1 - x0) * 0.5;
    const hy = (y1 - y0) * 0.5;
    const cx = (x0 + x1) * 0.5;
    const cy = (y0 + y1) * 0.5;
    const inv_scale = 1 / scale;
    const cap = @min(hx, hy);
    const radii: [4]f32 = if (use.radius) @min(@as(@Vector(4, f32), q.radii), @as(@Vector(4, f32), @splat(cap))) else @splat(0);
    const fill = rgba(q.fill);
    const edge = rgba(q.border_color);
    const fill8: [4]u8 = @bitCast(q.fill);
    const width = q.border * scale;
    const opacity = simd.f(q.opacity);
    const fb = t.fb;
    const red = fb.red();
    const chunk = 64;
    var ax: [chunk]F = undefined;
    var r_top: [chunk]F = undefined;
    var r_bottom: [chunk]F = undefined;
    for (parts) |part| {
        if (part[0] >= part[2] or part[1] >= part[3]) continue;
        var x_start = std.mem.alignBackward(u32, part[0], W);
        while (x_start < part[2]) : (x_start += chunk * W) {
            const n: u32 = @min(chunk, (part[2] - x_start + W - 1) / W);
            for (0..n) |j| {
                const fx = @as(F, @floatFromInt(simd.iota + simd.u(x_start + @as(u32, @intCast(j)) * W))) + simd.f(0.5);
                const lx = fx * simd.f(inv_scale) - simd.f(cx);
                ax[j] = @abs(lx) - simd.f(hx);
                const right = lx > simd.f(0);
                r_top[j] = @select(f32, right, simd.f(radii[1]), simd.f(radii[0]));
                r_bottom[j] = @select(f32, right, simd.f(radii[2]), simd.f(radii[3]));
            }
            for (part[1]..part[3]) |y| {
                const ly = (@as(f32, @floatFromInt(y)) + 0.5) * inv_scale - cy;
                const ay = simd.f(@abs(ly) - hy);
                const rs = if (ly > 0) &r_bottom else &r_top;
                const row = fb.pixels[y * fb.stride ..][0..fb.stride];
                for (0..n) |j| {
                    const x = x_start + @as(u32, @intCast(j)) * W;
                    const r = rs[j];
                    const qx = ax[j] + r;
                    const qy = ay + r;
                    const mx = @max(qx, simd.f(0));
                    const my = @max(qy, simd.f(0));
                    const len = if (@reduce(.Or, (qx > simd.f(0)) & (qy > simd.f(0)))) len2(mx, my) else mx + my;
                    const dist = (len + @min(@max(qx, qy), simd.f(0)) - r) * simd.f(scale);
                    const shape = sat(simd.f(0.5) - dist);
                    const alpha = sat(shape * opacity);
                    const old: U = row[x..][0..W].*;
                    const out = if (bordered) out: {
                        const on_border = simd.f(1) - sat(simd.f(0.5) - (dist + simd.f(width)));
                        var c: [4]F = undefined;
                        inline for (0..4) |i| {
                            const m = simd.f(fill[i]);
                            c[i] = m + (simd.f(edge[i]) - m) * on_border;
                        }
                        var c8: [3]U = undefined;
                        inline for (0..3) |i| c8[i] = @intFromFloat(@round(c[i] * simd.f(255)));
                        break :out overSa(c8, @intFromFloat(@round(c[3] * alpha * simd.f(255))), old, red);
                    } else overSa(.{ simd.u(fill8[0]), simd.u(fill8[1]), simd.u(fill8[2]) }, @intFromFloat(@round(alpha * simd.f(fill[3] * 255))), old, red);
                    row[x..][0..W].* = @select(u32, spanMask(x, part[0], part[2]), out, old);
                }
            }
        }
    }
}

/// An untransformed quad of the solid kind with a texture, no radius, no border and a square
/// clip: glyphs, icons and images. Its coverage is the smaller of a term of the pixel's column and
/// a term of its row, its texel column depends on x only and its texel row on y only, so all of
/// them are computed once per column and once per row instead of once per pixel. Per pixel
/// what is left is the texel fetch and the blend, with the shader loop's arithmetic.
fn texturedQuad(comptime encoding: ImageEncoding, t: Target, q: *const Quad, img: Image, scale: f32) void {
    const box = plainBox(q, scale, t.scissor);
    if (box[0] >= box[2] or box[1] >= box[3]) return;
    const x0, const y0, const x1, const y1 = q.rect;
    const hx = (x1 - x0) * 0.5;
    const hy = (y1 - y0) * 0.5;
    const cx = (x0 + x1) * 0.5;
    const cy = (y0 + y1) * 0.5;
    const c = q.clip;
    const uv = q.uv;
    const tex_w: f32 = @floatFromInt(img.width);
    const tex_h: f32 = @floatFromInt(img.height);
    const tinted = tint(q.fill);
    const opacity = simd.f(q.opacity);
    const inv_scale = 1 / scale;
    const red = t.fb.red();
    // Up to `chunk` vectors of columns at a time; a wider quad takes several passes.
    const chunk = 16;
    var cover: [chunk]F = undefined;
    var texel_x: [chunk]U = undefined;
    var in_x: [chunk]B = undefined;
    var start = std.mem.alignBackward(u32, box[0], W);
    while (start < box[2]) : (start += chunk * W) {
        const n: u32 = @min(chunk, (box[2] - start + W - 1) / W);
        for (0..n) |j| {
            const x = start + @as(u32, @intCast(j)) * W;
            const fx = @as(F, @floatFromInt(simd.iota + simd.u(x))) + simd.f(0.5);
            const sx = fx * simd.f(inv_scale);
            // The shader's rect_pos, local position and texel column for this column.
            const px = sx - simd.f(x0);
            const lx = sx - simd.f(cx);
            cover[j] = sat(simd.f(0.5) - (@abs(lx) - simd.f(hx)) * simd.f(scale));
            const u = texelCentre(px, 2 * hx, uv[0], uv[2], tex_w);
            texel_x[j] = @intFromFloat(@min(@max(@floor(u * simd.f(tex_w)), simd.f(0)), simd.f(tex_w - 1)));
            in_x[j] = (sx >= simd.f(x0)) & (sx < simd.f(x1)) & (sx >= simd.f(c[0])) & (sx <= simd.f(c[2])) & spanMask(x, box[0], box[2]);
        }
        for (box[1]..box[3]) |y| {
            const fy = @as(f32, @floatFromInt(y)) + 0.5;
            const sy = fy * inv_scale;
            // A row outside the rect or the clip gets alpha 0: its pixels stay as they are.
            if (!(sy >= y0 and sy < y1 and sy >= c[1] and sy <= c[3])) continue;
            const ly = sy - cy;
            const row_cover = simd.f(std.math.clamp(0.5 - (@abs(ly) - hy) * scale, 0, 1));
            const v = texelCentre(simd.f(sy - y0), 2 * hy, uv[1], uv[3], tex_h);
            const texel_y: u32 = @intFromFloat(@min(@max(@floor(v[0] * tex_h), 0), tex_h - 1));
            const texels = texel_y * img.width;
            const row = t.fb.pixels[y * t.fb.stride ..][0..t.fb.stride];
            for (0..n) |j| {
                const x = start + @as(u32, @intCast(j)) * W;
                var texel: U = undefined;
                const alpha: U = @intFromFloat(@round(sat(@min(cover[j], row_cover) * opacity) * simd.f(255)));
                const old: U = row[x..][0..W].*;
                const out = if (encoding == .alpha8) out: {
                    inline for (0..W) |l| texel[l] = img.alpha8[texels + texel_x[j][l]];
                    // A white texel at that alpha: the tint's colour, its alpha times the texel's.
                    break :out overSa(.{ tinted.r, tinted.g, tinted.b }, round255(mul16(round255(mul16(tinted.a, texel)), alpha)), old, red);
                } else out: {
                    inline for (0..W) |l| texel[l] = img.pixels[texels + texel_x[j][l]];
                    break :out overTexel(texel, tinted, alpha, old, red);
                };
                row[x..][0..W].* = @select(u32, in_x[j], out, old);
            }
        }
    }
}

/// How many quads from the first form a strip `textStrip` can draw: glyphs of the solid kind
/// with no transform, radius or border, a square clip and a texture, sharing their rows, colour,
/// opacity and clip, left to right, whose texel rows step alike (same fraction of a texel at
/// the top, same cell height). At least 1.
fn stripLen(quads: []const Quad, img: Image) usize {
    if (img.isWhite()) return 1;
    const q0 = &quads[0];
    if (!glyphLike(q0)) return 1;
    const tex_h: f32 = @floatFromInt(img.height);
    const rows = texelRows(q0, tex_h);
    var n: usize = 1;
    while (n < quads.len) : (n += 1) {
        const q = &quads[n];
        const same = glyphLike(q) and q.rect[1] == q0.rect[1] and q.rect[3] == q0.rect[3] and
            q.fill == q0.fill and q.opacity == q0.opacity and
            @reduce(.And, @as(@Vector(4, f32), q.clip) == @as(@Vector(4, f32), q0.clip)) and
            q.rect[0] >= quads[n - 1].rect[0] and
            std.meta.eql(texelRows(q, tex_h), rows);
        if (!same) break;
    }
    return n;
}

fn glyphLike(q: *const Quad) bool {
    return @as(u32, @bitCast(q.params[0])) == 0 and plain(q) and q.border < 0.001 and
        @reduce(.Max, @as(@Vector(4, f32), q.radii)) <= 0 and q.uv[1] >= 0;
}

/// The parts of the shader's `texel_centre` along y that a strip's glyphs must share: the
/// fraction of a texel at the cell's top times the size, and the cell height in texels.
fn texelRows(q: *const Quad, tex_h: f32) [2]f32 {
    const size = @max(q.rect[3] - q.rect[1], 1e-6);
    const a = q.uv[1] * tex_h;
    return .{ (a - @floor(a)) * size, (q.uv[3] - q.uv[1]) * tex_h };
}

/// The shader's `floor_div` on one value.
fn floorDiv1(num: f32, den: f32) f32 {
    const q = @floor(num / den);
    const up: f32 = @floatFromInt(@intFromBool((q + 1) * den <= num));
    const down: f32 = @floatFromInt(@intFromBool(q * den > num));
    return q + up - down;
}

/// Glyphs on one line drawn together, a row of the whole line at a time (`stripLen` says which
/// may be), framebuffer vector by vector. Each pixel column belongs to the glyph whose [x0, x1)
/// holds its centre; per column its coverage term and texel column are computed once, per row
/// the row's coverage term and its texel row, which all glyphs share up to their cell's first
/// row. Per vector and row: the texels (from an alpha atlas, one or two 16-byte loads and a
/// byte shuffle, skipped where all are 0), then the blend. Returns false, having drawn nothing,
/// when a pixel centre falls in two glyphs or a texel row would be clamped; the caller then draws
/// the quads one by one.
fn textStrip(t: Target, glyphs: []const Quad, img: Image, scale: f32) bool {
    const q0 = &glyphs[0];
    const last = &glyphs[glyphs.len - 1];
    const c = q0.clip;
    const inv_scale = 1 / scale;
    const xs = axisPixels(@max(q0.rect[0], c[0]), last.rect[2], c[2], scale, inv_scale);
    const ys = axisPixels(@max(q0.rect[1], c[1]), q0.rect[3], c[3], scale, inv_scale);
    const box = clampBox(.{ xs[0], ys[0], xs[1], ys[1] }, t.scissor);
    if (box[0] >= box[2] or box[1] >= box[3]) return true;
    const tex_w: f32 = @floatFromInt(img.width);
    const tex_h: f32 = @floatFromInt(img.height);
    const y0 = q0.rect[1];
    const hy = (q0.rect[3] - y0) * 0.5;
    const cy = (y0 + q0.rect[3]) * 0.5;
    const size_y = @max(2 * hy, 1e-6);
    const step = texelRows(q0, tex_h);
    // The texel row is the glyph's first cell row plus a part shared by the strip; it stays in
    // the texture over the strip's rows when it does at the first and the last.
    var top: f32 = std.math.inf(f32);
    var bottom: f32 = -std.math.inf(f32);
    for (glyphs) |*g| {
        const whole = @floor(g.uv[1] * tex_h);
        top = @min(top, whole);
        bottom = @max(bottom, whole);
    }
    for ([2]u32{ box[1], box[3] - 1 }) |y| {
        const pos = pixelCentre(y, inv_scale) - y0;
        const shared = floorDiv1(step[0] + step[1] * pos, size_y);
        if (top + shared < 0 or bottom + shared > tex_h - 1) return false;
    }
    // Each pixel column belongs to one glyph, by the loop's own test; a centre in two glyphs
    // needs them drawn one over the other, one by one.
    var prev_end: u32 = 0;
    for (glyphs) |*q| {
        const cols = axisPixels(@max(q.rect[0], c[0]), q.rect[2], c[2], scale, inv_scale);
        if (cols[0] < cols[1] and cols[0] < prev_end) return false;
        prev_end = @max(prev_end, cols[1]);
    }

    const tinted = tint(q0.fill);
    const opaque_tint = q0.fill >> 24 == 255;
    const opacity = q0.opacity;
    const red = t.fb.red();
    const width = img.width;
    const a8 = img.alpha8.len > 0;
    // Alpha texels by a byte shuffle of 16-byte windows of a row; otherwise one load per lane.
    const windows = byte_shuffle and a8;
    const chunk = 64;
    // Per framebuffer vector of the strip, as u32 lanes (vectors of bools load bit by bit):
    // whether a glyph holds the column, its coverage times opacity in 8 bits and its texel index
    // in the cell's first row. When the vector's texels lie in at most two windows of 16 bytes
    // (a window per glyph piece in it), each window's first index and, per lane, the shuffle
    // control that picks the lane's byte (0x80, zero, in the lanes of the other).
    var in_x: [chunk]U = undefined;
    var cover: [chunk]U = undefined;
    var base: [chunk]U = undefined;
    var win_at: [chunk][2]u32 = undefined;
    // The last window's first index: the vector's windows are in the texture when it is.
    var win_last: [chunk]u32 = undefined;
    var win_ctl: [chunk][2]U = undefined;
    // 0: no glyph; 1 or 2: windows; `lanewise`: a load per lane.
    var pieces: [chunk]u8 = undefined;
    const lanewise = 3;
    const none = simd.u(0);
    const all = simd.u(~@as(u32, 0));
    var g: usize = 0;
    var start = std.mem.alignBackward(u32, box[0], W);
    while (start < box[2]) : (start += chunk * W) {
        const n: u32 = @min(chunk, (box[2] - start + W - 1) / W);
        const stop = @min(start + n * W, box[2]);
        @memset(in_x[0..n], none);
        @memset(cover[0..n], none);
        @memset(pieces[0..n], 0);
        while (g < glyphs.len) : (g += 1) {
            const q = &glyphs[g];
            const x0, _, const x1, _ = q.rect;
            const cols = axisPixels(@max(x0, c[0]), x1, c[2], scale, inv_scale);
            const from = @max(cols[0], @max(start, box[0]));
            const to = @min(cols[1], stop);
            const hx = (x1 - x0) * 0.5;
            const cx = (x0 + x1) * 0.5;
            const row0 = @as(u32, @intFromFloat(@floor(q.uv[1] * tex_h))) * width;
            var v = (from - start) / W;
            while (from < to and start + v * W < to) : (v += 1) {
                const xs_v = simd.iota + simd.u(start + v * W);
                const live = (xs_v >= simd.u(from)) & (xs_v < simd.u(to));
                const sx = (@as(F, @floatFromInt(xs_v)) + simd.f(0.5)) * simd.f(inv_scale);
                const cv = sat(simd.f(0.5) - (@abs(sx - simd.f(cx)) - simd.f(hx)) * simd.f(scale));
                const cover8: U = @intFromFloat(@round(sat(cv * simd.f(opacity)) * simd.f(255)));
                const u = texelCentre(sx - simd.f(x0), 2 * hx, q.uv[0], q.uv[2], tex_w);
                const tx: U = @intFromFloat(@min(@max(@floor(u * simd.f(tex_w)), simd.f(0)), simd.f(tex_w - 1)));
                const index = simd.u(row0) + tx;
                in_x[v] |= @select(u32, live, all, none);
                cover[v] = @select(u32, live, cover8, cover[v]);
                base[v] = @select(u32, live, index, base[v]);
                // The piece's window starts at its first texel: texel columns rise with x.
                const first = @reduce(.Min, @select(u32, live, index, all));
                const rel = index -% simd.u(first);
                const k = pieces[v];
                if (k < 2 and @reduce(.And, (rel < simd.u(16)) | ~live)) {
                    win_at[v][k] = first;
                    win_last[v] = @max(first, if (k == 1) win_at[v][0] else 0);
                    win_ctl[v][k] = @select(u32, live, rel | simd.u(0x80808000), simd.u(0x80808080));
                    pieces[v] = k + 1;
                } else pieces[v] = lanewise;
            }
            // A glyph running past this chunk carries on in the next.
            if (cols[1] > stop) break;
        }
        for (box[1]..box[3]) |y| {
            const sy = pixelCentre(@intCast(y), inv_scale);
            const ly = sy - cy;
            const row_cover = std.math.clamp(0.5 - (@abs(ly) - hy) * scale, 0, 1);
            const row_alpha = simd.u(@intFromFloat(@round(std.math.clamp(row_cover * opacity, 0, 1) * 255)));
            // May be negative for a cell below the texture's top row: indices wrap back.
            const shared: i32 = @intFromFloat(floorDiv1(step[0] + step[1] * (sy - y0), size_y));
            const offset: u32 = @bitCast(shared *% @as(i32, @intCast(width)));
            const row = t.fb.pixels[y * t.fb.stride ..][0..t.fb.stride];
            for (0..n) |j| {
                const k = pieces[j];
                if (k == 0) continue;
                const x = start + @as(u32, @intCast(j)) * W;
                const mask = in_x[j] != none;
                const alpha = @min(cover[j], row_alpha);
                const old: U = row[x..][0..W].*;
                const out = if (a8) out: {
                    const at = win_at[j];
                    const fits = @as(u64, win_last[j] +% offset) + 16 <= img.alpha8.len;
                    const cov: U = if (windows and k < lanewise and fits) window: {
                        const one: @Vector(16, u8) = img.alpha8[at[0] +% offset ..][0..16].*;
                        const two: @Vector(16, u8) = if (k == 2) img.alpha8[at[1] +% offset ..][0..16].* else @splat(0);
                        if (!@reduce(.Or, (one | two) != @as(@Vector(16, u8), @splat(0)))) continue;
                        const first = shuffleBytes(one, win_ctl[j][0]);
                        break :window if (k == 2) first | shuffleBytes(two, win_ctl[j][1]) else first;
                    } else gather: {
                        const idx = base[j] +% simd.u(offset);
                        var v: U = undefined;
                        inline for (0..W) |l| v[l] = img.alpha8[if (mask[l]) idx[l] else 0];
                        break :gather v;
                    };
                    // round255(255 * cov) is cov.
                    const ca = if (opaque_tint) cov else round255(mul16(tinted.a, cov));
                    break :out overSa(.{ tinted.r, tinted.g, tinted.b }, round255(mul16(ca, alpha)), old, red);
                } else out: {
                    const idx = base[j] +% simd.u(offset);
                    var texel: U = undefined;
                    inline for (0..W) |l| texel[l] = img.pixels[if (mask[l]) idx[l] else 0];
                    break :out overTexel(texel, tinted, alpha, old, red);
                };
                row[x..][0..W].* = @select(u32, mask, out, old);
            }
        }
    }
    return true;
}

/// Whether `shuffleBytes` is one instruction here (AVX2's vpshufb over 8 lanes).
const byte_shuffle = builtin.cpu.arch == .x86_64 and W == 8 and std.Target.x86.featureSetHas(builtin.cpu.features, .avx2);

/// Per u32 lane, byte `ctl & 15` of `bytes` (the lane's other control bytes are 0x80, which
/// zero theirs): a texel fetch from a 16-byte window of an alpha atlas.
inline fn shuffleBytes(bytes: @Vector(16, u8), ctl: U) U {
    const both = @shuffle(u8, bytes, undefined, [32]i32{ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15 });
    return @bitCast(asm ("vpshufb %[ctl], %[src], %[dst]"
        : [dst] "=x" (-> @Vector(32, u8)),
        : [src] "x" (both),
          [ctl] "x" (@as(@Vector(32, u8), @bitCast(ctl))),
    ));
}

/// A colour as 8-bit channel factors for `overTexel`: red and blue, green and alpha.
const Tint = struct { r: U, g: U, b: U, a: U };

fn tint(c: u32) Tint {
    const v: [4]u8 = @bitCast(c);
    return .{ .r = simd.u(v[0]), .g = simd.u(v[1]), .b = simd.u(v[2]), .a = simd.u(v[3]) };
}

/// `overTexel` in 8-bit integers: the texel (Color bits, red in the low byte) times `t`, at
/// coverage `alpha8` (0..255), premultiplied over `old`. Two channels share a u32 in 16-bit fields,
/// as `Framebuffer.blend` does. Each step rounds to the nearest level, so a channel may differ
/// from the float loop by a level or two.
inline fn overTexel(texel: U, t: Tint, alpha8: U, old: U, red: u5) U {
    const m8 = simd.u(255);
    return overRgba(.{
        round255(mul16(t.r, texel & m8)),
        round255(mul16(t.g, (texel >> @splat(8)) & m8)),
        round255(mul16(t.b, (texel >> @splat(16)) & m8)),
        round255(mul16(t.a, texel >> @splat(24))),
    }, alpha8, old, red);
}

/// Straight 8-bit r, g, b, a at coverage `alpha8` (0..255), premultiplied over `old`.
inline fn overRgba(c: [4]U, alpha8: U, old: U, red: u5) U {
    return overSa(c[0..3].*, round255(mul16(c[3], alpha8)), old, red);
}

/// Straight 8-bit r, g, b with source alpha `sa` (0..255), premultiplied over `old`.
inline fn overSa(c: [3]U, sa: U, old: U, red: u5) U {
    const fields = simd.u(0x00ff00ff);
    const cr, const cg, const cb = c;
    // Source alpha and its complement in both 16-bit fields.
    const sa2 = sa | (sa << @splat(16));
    const inv = fields - sa2;
    // The framebuffer's red sits at bit `red`, its blue at 16 - red.
    const src_lo = (cr << @splat(red)) | (cb << @splat(16 - red));
    const src_hi = cg | simd.u(0x00ff0000);
    const lo = mul16(src_lo, sa2) + mul16(old & fields, inv);
    const hi = mul16(src_hi, sa2) + mul16((old >> @splat(8)) & fields, inv);
    return Framebuffer.div255(lo) | (Framebuffer.div255(hi) << @splat(8));
}

/// Products of the 16-bit fields of `a` and `b`, each pair on its own: a u32 lane holding two
/// channels times one holding a factor in both, or a plain product below 2^16 (8 bits times 8
/// bits). One 16-bit multiply where a 32-bit one costs two micro-ops and twice the latency.
inline fn mul16(a: U, b: U) U {
    const U16 = @Vector(2 * W, u16);
    return @bitCast(@as(U16, @bitCast(a)) *% @as(U16, @bitCast(b)));
}

/// round(x / 255) for 0 <= x <= 255², one value per lane.
inline fn round255(x: U) U {
    const bias = x + simd.u(128);
    return (bias + (bias >> @splat(8))) >> @splat(8);
}

/// Source `color` (straight, 0..1) at coverage `alpha` premultiplied over the pixels `old`: the
/// colour and its alpha times the coverage rounded to 8 bits, then `overSa`. Each rounds to the
/// nearest level, so a channel may differ from float arithmetic by a level.
pub inline fn overColor(color: [4]F, alpha: F, old: U, red: u5) U {
    var c8: [3]U = undefined;
    inline for (0..3) |i| c8[i] = @intFromFloat(@round(sat(color[i]) * simd.f(255)));
    const sa: U = @intFromFloat(@round(sat(color[3] * alpha) * simd.f(255)));
    return overSa(c8, sa, old, red);
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

/// The shader's `texel_centre`: the uv of the nearest texel's centre along one axis.
inline fn texelCentre(pos: F, size: f32, uv0: f32, uv1: f32, n: f32) F {
    const s = @max(size, 1e-6);
    const a = uv0 * n;
    const whole = @floor(a);
    const k = simd.f(whole) + floorDiv(simd.f((a - whole) * s) + simd.f((uv1 - uv0) * n) * pos, simd.f(s));
    return (@min(@max(k, simd.f(0)), simd.f(n - 1)) + simd.f(0.5)) / simd.f(n);
}

/// Nearest texel at (u, v), coordinates clamped to the edge; returns r, g, b, a in 0..1.
inline fn sample(comptime encoding: ImageEncoding, img: Image, u: F, v: F) [4]F {
    const wf: f32 = @floatFromInt(img.width);
    const hf: f32 = @floatFromInt(img.height);
    const tx: U = @intFromFloat(@min(@max(@floor(u * simd.f(wf)), simd.f(0)), simd.f(wf - 1)));
    const ty: U = @intFromFloat(@min(@max(@floor(v * simd.f(hf)), simd.f(0)), simd.f(hf - 1)));
    const idx = ty * simd.u(img.width) + tx;
    var texel: U = undefined;
    if (encoding == .any) return if (img.alpha8.len != 0) sample(.alpha8, img, u, v) else sample(.rgba8, img, u, v);
    if (encoding == .alpha8) {
        inline for (0..W) |l| texel[l] = img.alpha8[idx[l]];
        return .{ simd.f(1), simd.f(1), simd.f(1), @as(F, @floatFromInt(texel)) * simd.f(1.0 / 255.0) };
    }
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

/// Shades `q` into `t` with the stock material's `kind` loop: quad.wgsl `vs` and `fs` per pixel.
pub fn shade(comptime kind: features.Kind, t: Target, q: *const Quad, img: Image, scale: f32) void {
    if (img.alpha8.len != 0)
        shadeFor(.all, kind, .alpha8, t, q, img, scale)
    else
        shadeFor(.all, kind, .rgba8, t, q, img, scale);
}

/// The shader loop over the pixels of `q`'s box. A scale or transform the vertex shader could
/// not invert draws nothing.
fn shadeFor(comptime use: features.Usage, comptime kind: features.Kind, comptime encoding: ImageEncoding, t: Target, q: *const Quad, img: Image, scale: f32) void {
    if (!std.math.isFinite(scale) or scale <= 0 or @import("../../draw/geometry.zig").inverse(q.xform) == null) return;
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
    shadeRows(use, kind, encoding, t.fb, red, box, .{
        .q = q,
        .img = img,
        .scale = scale,
        .inv_scale = inv_scale,
        .mr = mr,
        .off = .{ off_x, off_y },
        .m = .{ a, b, c, d, tx, ty, inv },
        .g0 = g0,
        .g1 = g1,
        .half = .{ hx, hy },
        .centre = .{ cx, cy },
        .fill = fill,
        .edge = edge,
        .to = to,
        .border = border,
        .has_border = has_border,
        .uv = uv,
        .tex = .{ tex_w, tex_h },
        .dir = .{ dir_x, dir_y },
        .reach = reach,
        .rc = .{ rc_x, rc_y },
        .radius = radius,
        .dst = dst,
        .src = src,
        .dash = dash,
        .period = period,
        .sigma = sigma,
        .clip = clip,
        .clip_centre = .{ ccx, ccy },
        .clip_half = .{ chx, chy },
        .rounded_clip = rounded_clip,
    });
}

/// Per-quad constants of the shader loop, computed once by `shadeFor`.
const Consts = struct {
    q: *const Quad,
    img: Image,
    scale: f32,
    inv_scale: f32,
    mr: [4]f32,
    off: [2]f32,
    m: [7]f32,
    g0: [2]f32,
    g1: [2]f32,
    half: [2]f32,
    centre: [2]f32,
    fill: [4]f32,
    edge: [4]f32,
    to: [4]f32,
    border: f32,
    has_border: f32,
    uv: [4]f32,
    tex: [2]f32,
    dir: [2]f32,
    reach: f32,
    rc: [2]f32,
    radius: f32,
    dst: [4]f32,
    src: [4]f32,
    dash: f32,
    period: f32,
    sigma: f32,
    clip: [4]f32,
    clip_centre: [2]f32,
    clip_half: [2]f32,
    rounded_clip: B,
};

inline fn shadeRows(comptime use: features.Usage, comptime kind: features.Kind, comptime encoding: ImageEncoding, fb: *Framebuffer, red: u5, box: [4]u32, kc: Consts) void {
    const q = kc.q;
    const img = kc.img;
    const scale = kc.scale;
    const inv_scale = kc.inv_scale;
    const mr = kc.mr;
    const off_x, const off_y = kc.off;
    const a, const b, const c, const d, const tx, const ty, const inv = kc.m;
    const g0 = kc.g0;
    const g1 = kc.g1;
    const hx, const hy = kc.half;
    const cx, const cy = kc.centre;
    const fill = kc.fill;
    const edge = kc.edge;
    const to = kc.to;
    const border = kc.border;
    const has_border = kc.has_border;
    const uv = kc.uv;
    const tex_w, const tex_h = kc.tex;
    const dir_x, const dir_y = kc.dir;
    const reach = kc.reach;
    const rc_x, const rc_y = kc.rc;
    const radius = kc.radius;
    const dst = kc.dst;
    const src = kc.src;
    const dash = kc.dash;
    const period = kc.period;
    const sigma = kc.sigma;
    const clip = kc.clip;
    const ccx, const ccy = kc.clip_centre;
    const chx, const chy = kc.clip_half;
    const rounded_clip = kc.rounded_clip;
    for (box[1]..box[3]) |y| {
        const row = fb.pixels[y * fb.stride ..][0..fb.stride];
        const fy = simd.f(@as(f32, @floatFromInt(y)) + 0.5);
        const sy = fy * simd.f(inv_scale);
        var x = std.mem.alignBackward(u32, box[0], W);
        while (x < box[2]) : (x += W) {
            const fx = @as(F, @floatFromInt(simd.iota + simd.u(x))) + simd.f(0.5);
            const sx = fx * simd.f(inv_scale);
            // The shader's `rect_pos`, from exact inputs only. For the identity it is the
            // physical position over the scale less the rect's corner, to the last bit.
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
                const tex: [4]F = if (use.image or use.text) tex: {
                    var tu = texelCentre(px, 2 * hx, uv[0], uv[2], tex_w);
                    var tv = texelCentre(py, 2 * hy, uv[1], uv[3], tex_h);
                    if (kind == .nine_slice) {
                        const fu = nineAxis(lx + simd.f(hx), 2 * hx, dst[0], dst[2], src[0], src[2]);
                        const fv = nineAxis(ly + simd.f(hy), 2 * hy, dst[1], dst[3], src[1], src[3]);
                        tu = simd.f(uv[0]) + simd.f(uv[2] - uv[0]) * fu;
                        tv = simd.f(uv[1]) + simd.f(uv[3] - uv[1]) * fv;
                    }
                    break :tex sample(encoding, img, tu, tv);
                } else @splat(simd.f(1));
                inline for (0..4) |i| {
                    const m = base[i] * tex[i];
                    color[i] = if (use.border) m + (simd.f(edge[i]) - m) * on_border else m;
                }
            }

            // Clip as coverage: the rect as a step, its rounded corners as a distance field.
            const inside = (sx >= simd.f(clip[0])) & (sx <= simd.f(clip[2])) & (sy >= simd.f(clip[1])) & (sy <= simd.f(clip[3]));
            const rounded = if (use.radius) rounded: {
                const tcx = sx - simd.f(ccx);
                const tcy = sy - simd.f(ccy);
                const clip_d = roundedBox(tcx, tcy, chx, chy, cornerRadius(tcx, tcy, chx, chy, q.clip_radii)) * simd.f(scale);
                break :rounded @select(f32, rounded_clip, sat(simd.f(0.5) - clip_d), simd.f(1));
            } else simd.f(1);
            const alpha = @select(f32, inside & geo, cover * rounded * simd.f(q.opacity), simd.f(0));

            // Premultiplied source over the framebuffer.
            const old: U = row[x..][0..W].*;
            row[x..][0..W].* = @select(u32, spanMask(x, box[0], box[2]), overColor(color, alpha, old, red), old);
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

test {
    _ = bands;
    _ = canvas;
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
    try testing.expect(plain(&q));
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
            // The frame blends in 8 bits, the shader loop in floats.
            try expectNear(reference.pixels, fb.pixels, 1);
        }
    }
}

/// Every channel of every pixel of `actual` within `tolerance` levels of `expected`.
fn expectNear(expected: []const u32, actual: []const u32, tolerance: u8) !void {
    try testing.expectEqual(expected.len, actual.len);
    for (expected, actual, 0..) |e, a, i| {
        const ev: @Vector(4, u8) = @bitCast(e);
        const av: @Vector(4, u8) = @bitCast(a);
        const d = @max(ev, av) - @min(ev, av);
        if (@reduce(.Max, d) > tolerance) {
            std.debug.print("pixel {d}: expected {x:0>8}, found {x:0>8}\n", .{ i, e, a });
            return error.TestExpectedEqual;
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
    // The fast paths blend in 8 bits, the shader loop in floats.
    try expectNear(reference.pixels, fb.pixels, 1);
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
        try testing.expectEqual(mode != 5 and mode != 6, plain(&q));
        for ([_]Format{ .rgba8, .bgra8 }) |format|
            try expectTexturedMatches(kind, q, img, scale, format, false);
    }
}

test "bordered interior gate rejects nonfinite inputs and recognizes the application panel" {
    var panel = testQuad(.{ 185, 138, 784, 478 }, .rgb(30, 31, 36));
    panel.clip = .{ 169, 57, 800, 600 };
    panel.radii = @splat(5);
    panel.border = 1;
    // Centres at least the radius inside the rect: 190 + 0.5 >= 185 + 5.
    try testing.expectEqual([4]u32{ 190, 143, 779, 473 }, interior(.all, &panel, 1, plainBox(&panel, 1, .{ 0, 0, 800, 600 })));
    for ([_]f32{ -1, -0.000001, std.math.inf(f32), std.math.nan(f32), 65537 }) |bad| {
        var q = panel;
        q.radii[0] = bad;
        try expectBorderedMatches(q, 1, .rgba8, .{ 0, 0, 99, 83 });
        q = panel;
        q.border = bad;
        try expectBorderedMatches(q, 1, .rgba8, .{ 0, 0, 99, 83 });
    }
    for ([_]f32{ std.math.inf(f32), std.math.nan(f32) }) |bad| {
        var q = panel;
        q.rect[0] = bad;
        try expectBorderedMatches(q, 1, .rgba8, .{ 0, 0, 99, 83 });
        q = panel;
        q.clip[0] = bad;
        try expectBorderedMatches(q, 1, .rgba8, .{ 0, 0, 99, 83 });
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
    try expectNear(reference.pixels, fb.pixels, 1);
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
        try testing.expectEqual(mode != 1 and mode != 3, plain(&q));
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
    try expectNear(reference.pixels, fb.pixels, 1);
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

test "the size build's run-time encoding shades exactly as each specialised encoding" {
    var coverage: [35]u8 = undefined;
    for (&coverage, 0..) |*a, i| a.* = @truncate(i * 37);
    var texels = testTexels();
    const images = [_]Image{ Image.white, .{ .pixels = &texels, .width = 7, .height = 5 }, .{ .alpha8 = &coverage, .width = 7, .height = 5 } };
    inline for (all_kinds) |kind| {
        var q = testQuad(.{ 1.3, 2.7, 27.4, 22.2 }, .rgba(233, 81, 106, 129));
        q.xform = .{ 1, 0.08, -0.05, 1, 1.5, -0.25 };
        q.radii = .{ 0, 1, 3, 2 };
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
        for (images) |img| for ([_]f32{ 0.75, 1.25, 2 }) |scale| {
            var any: Frame(67, 53) = .{};
            var one: Frame(67, 53) = .{};
            var fb = any.fb(.rgba8);
            var reference = one.fb(.rgba8);
            for (fb.pixels, 0..) |*px, i| px.* = @as(u32, @intCast(i)) *% 0x21098571;
            @memcpy(reference.pixels, fb.pixels);
            const scissor = [4]u32{ 3, 2, 61, 49 };
            shadeFor(.all, kind, .any, .{ .fb = &fb, .scissor = scissor }, &q, img, scale);
            shade(kind, .{ .fb = &reference, .scissor = scissor }, &q, img, scale);
            try testing.expectEqualSlices(u32, reference.pixels, fb.pixels);
        };
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

test "axisPixels: the first and end pixel whose centres pass the shader loop's tests" {
    var rng = std.Random.DefaultPrng.init(7);
    const r = rng.random();
    for (0..20_000) |i| {
        const scale = ([_]f32{ 0.75, 1, 1.25, 1.3333334, 2, 2.5 })[i % 6];
        const inv = 1 / scale;
        var v: [3]f32 = undefined;
        for (&v) |*x| x.* = @as(f32, @floatFromInt(r.intRangeAtMost(i32, -40, 400))) / ([_]f32{ 1, 2, 3, 4, 10 })[r.uintLessThan(u32, 5)];
        const got = axisPixels(v[0], v[1], v[2], scale, inv);
        // By definition: the run of pixels from 0 whose centres are >= lo, < hi_open, <= hi_closed.
        var first: u32 = 0;
        while (first < 2000 and !(pixelCentre(first, inv) >= v[0])) first += 1;
        var end = first;
        while (end < 2000 and pixelCentre(end, inv) < v[1] and pixelCentre(end, inv) <= v[2]) end += 1;
        // An empty run may sit anywhere.
        if (got[0] < got[1]) try testing.expectEqual([2]u32{ first, end }, got) else try testing.expectEqual(first, end);
    }
}

test "frame: starting at the opaque cover gives the cleared, fully drawn frame" {
    var a: Frame(40, 30) = .{};
    var b: Frame(40, 30) = .{};
    // A panel over the target, a translucent card on it, then one that covers only its own box.
    var quads = [_]Quad{
        testQuad(.{ 0, 0, 40, 30 }, .rgba(9, 9, 9, 128)),
        testQuad(.{ -0.25, -0.5, 40.5, 30.25 }, .rgb(30, 31, 36)),
        testQuad(.{ 3.3, 2.6, 21.2, 17.9 }, .rgba(200, 40, 90, 140)),
        testQuad(.{ 25, 10, 38, 28 }, .rgb(90, 140, 255)),
    };
    quads[1].radii = @splat(0.4);
    quads[3].radii = @splat(4);
    const Commands = struct {
        batch: draw_list.Batch,
        cmd_len: u32 = 1,
        pub fn command(c: *const @This(), _: u32) draw_list.Cmd {
            return .{ .quads = c.batch };
        }
    };
    const list: Commands = .{ .batch = .{ .first = 0, .count = quads.len, .texture = .white, .material = .solid } };
    const s: Software = .{ .quads = &quads, .scale = 1.25 };
    for ([_][4]u32{ .{ 0, 0, 40, 30 }, .{ 30, 15, 36, 25 }, .{ 2, 3, 17, 29 } }) |box| {
        var fa = a.fb(.rgba8);
        var fb = b.fb(.rgba8);
        @memset(fa.pixels, 0x01020304);
        @memset(fb.pixels, 0x01020304);
        s.frame(.{ .fb = &fa, .scissor = box }, &list, .black);
        fb.fill(box, .black);
        s.drawBatch(.{ .fb = &fb, .scissor = box }, list.batch);
        try testing.expectEqualSlices(u32, fb.pixels, fa.pixels);
    }
    // The second quad covers the whole target; the first, translucent, and the last do not.
    try testing.expect(covers(.all, &quads[1], 1.25, .{ 0, 0, 40, 30 }));
    try testing.expect(!covers(.all, &quads[0], 1.25, .{ 0, 0, 40, 30 }));
    try testing.expect(!covers(.all, &quads[3], 1.25, .{ 0, 0, 40, 30 }));
    try testing.expect(covers(.all, &quads[3], 1.25, .{ 37, 18, 42, 29 }));
    try testing.expect(!covers(.all, &quads[3], 1.25, .{ 32, 13, 46, 34 })); // its corners are round
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
