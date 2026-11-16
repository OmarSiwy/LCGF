//! The Gompute back end's kernels. This file is compiled twice (Gompute's model): as part of the
//! host module, where every `pub fn` below is an ordinary function the CPU path calls, and once
//! per GPU target (PTX for CUDA, HSACO for HIP), where the `comptime` block at the end exports
//! thin entry points that call the same functions per thread. One source, the same results.
//!
//! The rasteriser is a tile rasteriser in two kernels (Laine and Karras 2011, without the
//! triangle stages a GUI does not need):
//!
//!   bin     one thread per 16x16 tile: walks the frame's quads in paint order and appends the
//!           index of each one whose pixel box meets the tile to the tile's bin.
//!   raster  one thread per pixel: shades its tile's quads in bin order over the framebuffer
//!           pixel, with the stock quad shader's math (src/render/shaders/quad.wgsl), as the
//!           software back end (src/render/sw/sw.zig `shade`) does it per vector lane.
//!
//! A bin holds `Frame.bin_cap - 1` indices. A tile that meets more quads keeps counting; its pixels
//! then walk every quad of the frame instead, testing each box, so the result never depends on
//! the capacity, only the speed does.
//!
//! Buffers are `g.GlobalPtr(T)`: a plain `[*]T` on the host (the CPU path passes its slices'
//! pointers), a global-address-space pointer on the device.

const std = @import("std");
const g = @import("gompute");
const lcgr = @import("lcgr");
const Quad = lcgr.draw_list.Quad;
const Kind = lcgr.features.Kind;
const math = g.math;

/// A read-only buffer: `g.GlobalPtr` with a const element.
fn In(comptime T: type) type {
    return if (g.is_device) [*]addrspace(.global) const T else [*]const T;
}

/// Threads per block in every launch (a multiple of both vendors' 32-lane groups).
pub const block = 256;

/// Tile side in pixels.
pub const tile = 16;

/// A texture in `texels`: `width` x `height` RGBA8 texels (`Color` bits) from `first`.
pub const Image = extern struct { first: u32, width: u32, height: u32, pad: u32 = 0 };

/// What every kernel needs to know about the frame, passed by value.
pub const Frame = extern struct {
    width: u32,
    height: u32,
    /// Pixels per framebuffer row (>= width).
    stride: u32,
    /// Shift of red in a pixel: 0 for RGBA8, 16 for BGRA8 (blue sits at 16 minus it).
    red: u32,
    tiles_x: u32,
    tiles_y: u32,
    quad_len: u32,
    bin_cap: u32,
    /// Physical pixels per logical pixel.
    scale: f32,

    pub fn init(width: u32, height: u32, stride: u32, red: u32, scale: f32, quad_len: u32, bin_cap: u32) Frame {
        return .{
            .width = width,
            .height = height,
            .stride = stride,
            .red = red,
            .tiles_x = (width + tile - 1) / tile,
            .tiles_y = (height + tile - 1) / tile,
            .quad_len = quad_len,
            .bin_cap = bin_cap,
            .scale = scale,
        };
    }

    pub fn tiles(f: Frame) u32 {
        return f.tiles_x * f.tiles_y;
    }
};

/// Pixel `i` of a clear: the colour, already in the framebuffer's byte order.
pub fn fill(px: g.GlobalPtr(u32), i: usize, value: u32) void {
    px[i] = value;
}

/// The pixels quad `q` can touch (x0, y0, x1, y1), as sw.zig `shade` bounds them: its
/// transformed corners (grown by 3 sigma for a shadow) cut to its clip, at `scale`.
pub fn quadBox(q: *const Quad, scale: f32) [4]u32 {
    const p: [4]u32 = @bitCast(q.params);
    const x0, const y0, const x1, const y1 = q.rect;
    const sigma: f32 = @bitCast(p[1]);
    const grow: f32 = if (p[0] == @backingInt(Kind.shadow)) 3 * sigma else 0;
    const g0 = [2]f32{ x0 - grow, y0 - grow };
    const g1 = [2]f32{ x1 + grow, y1 + grow };
    const a, const b, const c, const d, const tx, const ty = q.xform;
    var lo = [2]f32{ std.math.inf(f32), std.math.inf(f32) };
    var hi = [2]f32{ -std.math.inf(f32), -std.math.inf(f32) };
    for ([_][2]f32{ g0, .{ g1[0], g0[1] }, .{ g0[0], g1[1] }, g1 }) |corner| {
        const sx = a * corner[0] + c * corner[1] + tx;
        const sy = b * corner[0] + d * corner[1] + ty;
        lo = .{ @min(lo[0], sx), @min(lo[1], sy) };
        hi = .{ @max(hi[0], sx), @max(hi[1], sy) };
    }
    const clip = q.clip;
    return toPixels(.{
        @max(lo[0], clip[0]) * scale,
        @max(lo[1], clip[1]) * scale,
        @min(hi[0], clip[2]) * scale + 1,
        @min(hi[1], clip[3]) * scale + 1,
    });
}

/// Logical box in pixels, floored and clamped to [0, 2^24] (sw.zig `toPixels`).
fn toPixels(box: [4]f32) [4]u32 {
    var out: [4]u32 = undefined;
    for (box, &out) |v, *o| o.* = @intFromFloat(@min(@max(@floor(v), 0), 1 << 24));
    return out;
}

/// Tile `t`'s bin: every quad whose box meets the tile, in paint order. Writes
/// `counts[t]` (which may exceed `f.bin_cap`) and up to `f.bin_cap - 1` indices from
/// `bins[t * f.bin_cap]`.
pub fn bin(f: Frame, quads: In(Quad), bins: g.GlobalPtr(u32), counts: g.GlobalPtr(u32), t: usize) void {
    const tx0 = @as(u32, @intCast(t % f.tiles_x)) * tile;
    const ty0 = @as(u32, @intCast(t / f.tiles_x)) * tile;
    const base = t * f.bin_cap;
    var n: u32 = 0;
    for (0..f.quad_len) |i| {
        const q = quads[i]; // a copy: device pointers are global, quadBox's are generic
        const box = quadBox(&q, f.scale);
        const hit = box[0] < tx0 + tile and box[2] > tx0 and box[1] < ty0 + tile and box[3] > ty0 and box[0] < box[2] and box[1] < box[3];
        // Write always, advance by 0 or 1; slots past the count are scratch.
        bins[base + @min(n, f.bin_cap - 1)] = @intCast(i);
        n += @intFromBool(hit);
    }
    counts[t] = n;
}

/// Pixel `i` (of `f.stride * f.height`): its tile's quads shaded over it in paint order.
/// `quad_tex[k]` is quad k's row in `images`.
pub fn raster(
    f: Frame,
    quads: In(Quad),
    quad_tex: In(u32),
    images: In(Image),
    texels: In(u32),
    bins: In(u32),
    counts: In(u32),
    px: g.GlobalPtr(u32),
    i: usize,
) void {
    const x: u32 = @intCast(i % f.stride);
    const y: u32 = @intCast(i / f.stride);
    if (x >= f.width) return;
    const t = (y / tile) * f.tiles_x + x / tile;
    const n = counts[t];
    // The last slot is scratch for misses once the bin is full, so a full bin walks every quad.
    const overflow = n >= f.bin_cap;
    const len = if (overflow) f.quad_len else n;
    var pixel = px[i];
    for (0..len) |k| {
        const qi = if (overflow) k else bins[t * f.bin_cap + k];
        const q = quads[qi];
        const box = quadBox(&q, f.scale);
        if (x < box[0] or x >= box[2] or y < box[1] or y >= box[3]) continue;
        const img = images[quad_tex[qi]];
        const code: u32 = @bitCast(q.params[0]);
        pixel = switch (std.enums.fromInt(Kind, code) orelse .solid) {
            inline else => |kind| shade(kind, &q, img, texels, f.scale, @intCast(f.red), x, y, pixel),
        };
    }
    px[i] = pixel;
}

fn rgba(c: u32) [4]f32 {
    var out: [4]f32 = undefined;
    inline for (0..4) |k| out[k] = @as(f32, @floatFromInt(@as(u8, @truncate(c >> (8 * k))))) / 255;
    return out;
}

fn sat(x: f32) f32 {
    return @min(@max(x, 0), 1);
}

fn len2(x: f32, y: f32) f32 {
    return @sqrt(x * x + y * y);
}

/// The shader's `corner_radius`.
fn cornerRadius(px: f32, py: f32, hx: f32, hy: f32, radii: [4]f32) f32 {
    const right = if (py > 0) radii[2] else radii[1];
    const left = if (py > 0) radii[3] else radii[0];
    return @min(if (px > 0) right else left, @min(hx, hy));
}

/// The shader's `rounded_box`.
fn roundedBox(px: f32, py: f32, hx: f32, hy: f32, r: f32) f32 {
    const qx = @abs(px) - hx + r;
    const qy = @abs(py) - hy + r;
    return len2(@max(qx, 0), @max(qy, 0)) + @min(@max(qx, qy), 0) - r;
}

/// The shader's `nine_axis`.
fn nineAxis(pos: f32, size: f32, lo: f32, hi: f32, src_lo: f32, src_hi: f32) f32 {
    const start = pos / @max(lo, 1e-6) * src_lo;
    const end = 1 - (size - pos) / @max(hi, 1e-6) * src_hi;
    const mid = src_lo + (pos - lo) / @max(size - lo - hi, 1e-6) * (1 - src_lo - src_hi);
    return if (pos < lo) start else if (pos > size - hi) end else mid;
}

/// The shader's `floor_div`.
fn floorDiv(num: f32, den: f32) f32 {
    const q = @floor(num / den);
    const up: f32 = @floatFromInt(@intFromBool((q + 1) * den <= num));
    const down: f32 = @floatFromInt(@intFromBool(q * den > num));
    return q + up - down;
}

/// The shader's `texel_centre`.
fn texelCentre(pos: f32, size: f32, uv0: f32, uv1: f32, n: f32) f32 {
    const s = @max(size, 1e-6);
    const a = uv0 * n;
    const whole = @floor(a);
    const k = whole + floorDiv((a - whole) * s + ((uv1 - uv0) * n) * pos, s);
    return (@min(@max(k, 0), n - 1) + 0.5) / n;
}

fn sample(img: Image, texels: In(u32), u: f32, v: f32) [4]f32 {
    const wf: f32 = @floatFromInt(img.width);
    const hf: f32 = @floatFromInt(img.height);
    const tx: u32 = @intFromFloat(@min(@max(@floor(u * wf), 0), wf - 1));
    const ty: u32 = @intFromFloat(@min(@max(@floor(v * hf), 0), hf - 1));
    return unpack(texels[img.first + ty * img.width + tx], 0);
}

fn unpack(p: u32, red: u5) [4]f32 {
    const k: f32 = 1.0 / 255.0;
    return .{
        @as(f32, @floatFromInt((p >> red) & 255)) * k,
        @as(f32, @floatFromInt((p >> 8) & 255)) * k,
        @as(f32, @floatFromInt((p >> (16 - red)) & 255)) * k,
        @as(f32, @floatFromInt((p >> 24) & 255)) * k,
    };
}

fn pack(c: [4]f32, red: u5) u32 {
    var out: [4]u32 = undefined;
    inline for (0..4) |k| out[k] = @intFromFloat(@round(sat(c[k]) * 255));
    return (out[0] << red) | (out[1] << 8) | (out[2] << (16 - red)) | (out[3] << 24);
}

fn unorm16(v: u32) f32 {
    return @as(f32, @floatFromInt(v & 0xffff)) / 65535;
}

/// One pixel of quad.wgsl `fs` for `q`, blended over `old`: sw.zig `shade`'s loop body for one
/// lane, expression for expression, so both back ends round the same way.
fn shade(comptime kind: Kind, q: *const Quad, img: Image, texels: In(u32), scale: f32, red: u5, x: u32, y: u32, old: u32) u32 {
    const p: [4]u32 = @bitCast(q.params);
    const x0, const y0, const x1, const y1 = q.rect;
    const hx = (x1 - x0) * 0.5;
    const hy = (y1 - y0) * 0.5;
    const cx = (x0 + x1) * 0.5;
    const cy = (y0 + y1) * 0.5;
    const sigma: f32 = @bitCast(p[1]);
    const grow: f32 = if (kind == .shadow) 3 * sigma else 0;
    const g0 = [2]f32{ x0 - grow, y0 - grow };
    const g1 = [2]f32{ x1 + grow, y1 + grow };

    const a, const b, const c, const d, const tx, const ty = q.xform;
    const inv = 1 / (a * d - b * c);
    const k_rect = 1 / ((a * d - b * c) * scale);
    const mr = [4]f32{ d * k_rect, -b * k_rect, -c * k_rect, a * k_rect };
    const off_x = -(mr[0] * (tx * scale) + mr[2] * (ty * scale)) - x0;
    const off_y = -(mr[1] * (tx * scale) + mr[3] * (ty * scale)) - y0;
    const clip = q.clip;

    const fill_c = rgba(q.fill);
    const edge = rgba(q.border_color);
    const to = rgba(p[1]);
    const border = q.border;
    const has_border: f32 = @floatFromInt(@intFromBool(border >= 0.001));
    const uv = q.uv;
    const tex_w: f32 = @floatFromInt(img.width);
    const tex_h: f32 = @floatFromInt(img.height);

    const inv_scale = 1 / scale;
    const fy = @as(f32, @floatFromInt(y)) + 0.5;
    const sy = fy * inv_scale;
    const fx = @as(f32, @floatFromInt(x)) + 0.5;
    const sx = fx * inv_scale;
    const px = mr[0] * fx + mr[2] * fy + off_x;
    const py = mr[1] * fx + mr[3] * fy + off_y;
    const ox = sx - tx;
    const oy = sy - ty;
    const qx = (d * ox - c * oy) * inv;
    const qy = (a * oy - b * ox) * inv;
    const geo = qx >= g0[0] and qx < g1[0] and qy >= g0[1] and qy < g1[1];
    const lx = qx - cx;
    const ly = qy - cy;

    const r = cornerRadius(lx, ly, hx, hy, q.radii);
    const dist = roundedBox(lx, ly, hx, hy, r) * scale;
    const shape = sat(0.5 - dist);
    const inner = sat(0.5 - (dist + border * scale));

    var pattern: f32 = 1;
    if (kind == .dashed or kind == .dotted) {
        const dash: f32 = if (kind == .dotted) border else @bitCast(p[1]);
        const period = @max(dash + @as(f32, @bitCast(p[2])), 1e-3);
        const ex = hx - @abs(px - hx);
        const ey = hy - @abs(py - hy);
        const s = if (ex < ey) py else px;
        const across = @min(ex, ey);
        const at = s - floorDiv(s, period) * period;
        pattern = if (kind == .dashed)
            sat((@min(at, dash - at) + 0.5) * scale)
        else
            sat(0.5 - (len2(at - border * 0.5, across - border * 0.5) - border * 0.5) * scale);
    }
    const on_border = (1 - inner) * has_border * pattern;

    var tu = texelCentre(px, 2 * hx, uv[0], uv[2], tex_w);
    var tv = texelCentre(py, 2 * hy, uv[1], uv[3], tex_h);
    if (kind == .nine_slice) {
        var dst: [4]f32 = rgba(p[1]);
        for (&dst) |*v| v.* *= 255;
        const src = [4]f32{ unorm16(p[2]), unorm16(p[2] >> 16), unorm16(p[3]), unorm16(p[3] >> 16) };
        const fu = nineAxis(lx + hx, 2 * hx, dst[0], dst[2], src[0], src[2]);
        const fv = nineAxis(ly + hy, 2 * hy, dst[1], dst[3], src[1], src[3]);
        tu = uv[0] + (uv[2] - uv[0]) * fu;
        tv = uv[1] + (uv[3] - uv[1]) * fv;
    }
    var base = fill_c;
    if (kind == .linear) {
        const angle: f32 = @bitCast(p[2]);
        const dir_x = math.cos(angle);
        const dir_y = math.sin(angle);
        const reach = @max(@abs(hx * dir_x) + @abs(hy * dir_y), 1e-6);
        const grad = sat((lx * dir_x + ly * dir_y) / reach * 0.5 + 0.5);
        inline for (0..4) |k| base[k] += (to[k] - base[k]) * grad;
    }
    if (kind == .radial) {
        const centre: [2]f16 = @bitCast(p[2]);
        const rc_x = (@as(f32, centre[0]) * 2 - 1) * hx;
        const rc_y = (@as(f32, centre[1]) * 2 - 1) * hy;
        const radius = @max(@as(f32, @bitCast(p[3])), 1e-6);
        const grad = sat(len2(lx - rc_x, ly - rc_y) / radius);
        inline for (0..4) |k| base[k] += (to[k] - base[k]) * grad;
    }
    var color: [4]f32 = undefined;
    var cover = shape;
    if (kind == .shadow) {
        const e = dist * (inv_scale / (@max(sigma, 1e-3) * 1.41421356));
        const e2 = e * e;
        const k: f32 = 0.147;
        const erf = std.math.sign(e) * @sqrt(1 - math.exp(-e2 * (1.27323954 + k * e2) / (1 + k * e2)));
        cover = 0.5 - 0.5 * erf;
        color = base;
    } else {
        const tex = sample(img, texels, tu, tv);
        inline for (0..4) |k| {
            const m = base[k] * tex[k];
            color[k] = m + (edge[k] - m) * on_border;
        }
    }

    const inside = sx >= clip[0] and sx <= clip[2] and sy >= clip[1] and sy <= clip[3];
    const ccx = (clip[0] + clip[2]) * 0.5;
    const ccy = (clip[1] + clip[3]) * 0.5;
    const chx = (clip[2] - clip[0]) * 0.5;
    const chy = (clip[3] - clip[1]) * 0.5;
    const rounded_clip = q.clip_radii[0] > 0 or q.clip_radii[1] > 0 or q.clip_radii[2] > 0 or q.clip_radii[3] > 0;
    const tcx = sx - ccx;
    const tcy = sy - ccy;
    const clip_d = roundedBox(tcx, tcy, chx, chy, cornerRadius(tcx, tcy, chx, chy, q.clip_radii)) * scale;
    const rounded = if (rounded_clip) sat(0.5 - clip_d) else 1;
    const alpha = if (inside and geo) cover * rounded * q.opacity else 0;

    const dst_px = unpack(old, red);
    const sa = color[3] * alpha;
    var out: [4]f32 = undefined;
    inline for (0..3) |k| out[k] = color[k] * sa + dst_px[k] * (1 - sa);
    out[3] = sa + dst_px[3] * (1 - sa);
    return pack(out, red);
}

fn fillKernel(px: g.GlobalPtr(u32), len: u32, value: u32) callconv(g.kernel_callconv) void {
    const i = g.globalIdX(block);
    if (i < len) fill(px, i, value);
}

fn binKernel(f: Frame, quads: In(Quad), bins: g.GlobalPtr(u32), counts: g.GlobalPtr(u32)) callconv(g.kernel_callconv) void {
    const t = g.globalIdX(block);
    if (t < f.tiles()) bin(f, quads, bins, counts, t);
}

fn rasterKernel(
    f: Frame,
    quads: In(Quad),
    quad_tex: In(u32),
    images: In(Image),
    texels: In(u32),
    bins: In(u32),
    counts: In(u32),
    px: g.GlobalPtr(u32),
) callconv(g.kernel_callconv) void {
    const i = g.globalIdX(block);
    if (i < f.stride * f.height) raster(f, quads, quad_tex, images, texels, bins, counts, px, i);
}

comptime {
    if (g.is_device) {
        g.exportRaw("lcgr_fill", &fillKernel);
        g.exportRaw("lcgr_bin", &binKernel);
        g.exportRaw("lcgr_raster", &rasterKernel);
    }
}
