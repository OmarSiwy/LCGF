//! Canvas labels under zoom, the two candidates of docs/plans/window.md stage 5, measured
//! before either is built: `zig build canvas-text-bench`, ReleaseFast, Linux.
//!
//! A label is 13 world px at camera scale 1; the camera runs 0.5 to 8, so a glyph is drawn at
//! P = 13 * scale physical px. For every printable ASCII glyph of the repository's test face
//! (Noto Sans subset), against its coverage rasterised exactly at P (src/text/raster/):
//!
//!   sdf E      a distance image made once at an em of E px, spread 4 (src/text/raster/sdf.zig),
//!              sampled bilinearly and turned into coverage at P, as a shader would;
//!   stale      the coverage image of the last settled size (13 px), sampled bilinearly at P:
//!              what "rasterise again once the zoom settles" shows while the camera moves;
//!   settled    rasterised again at P: exact by construction, costs a rasterisation of every
//!              glyph shown each time the zoom settles, and an image per size in the atlas.
//!
//! Per scale: mean and largest difference from exact over every pixel of the glyphs' boxes
//! (levels of 255), and the edge width: partly covered pixels over the exact image's, so 1.0
//! is as sharp as exact and 8 is eight times as wide. Costs: building the glyph set's images
//! (us, median of 20) and their atlas bytes (boxes plus a pixel of gap).

const std = @import("std");
const linux = std.os.linux;
const lcgf = @import("lcgf");
const raster = lcgf.raster;
const sdf = lcgf.raster_sdf;
const opentype = lcgf.opentype;

const font = @embedFile("layout.ttf");
const label_px = 13;
const scales = [_]f32{ 0.5, 1, 2, 4, 8 };
const spread = 4;
const side = 256;

var xs: [4096]f32 = undefined;
var ys: [4096]f32 = undefined;
var on: [4096]bool = undefined;
var ends: [512]u32 = undefined;
var acc: [side * side + 64]f32 = undefined;
var exact: [side * side + 64]u8 = undefined;
var source: [side * side + 64]u8 = undefined;
var sx0: [8192]f32 = undefined;
var sy0: [8192]f32 = undefined;
var sx1: [8192]f32 = undefined;
var sy1: [8192]f32 = undefined;

const Stat = struct {
    sum: u64 = 0,
    pixels: u64 = 0,
    max: u32 = 0,
    partial: u64 = 0,
    exact_partial: u64 = 0,

    fn add(s: *Stat, got: u8, want: u8) void {
        const e: u32 = @abs(@as(i32, got) - want);
        s.sum += e;
        s.pixels += 1;
        s.max = @max(s.max, e);
        s.partial += @intFromBool(got > 0 and got < 255);
        s.exact_partial += @intFromBool(want > 0 and want < 255);
    }
};

const Method = enum { sdf32, sdf48, stale };

pub fn main(init: std.process.Init) !void {
    const face = try opentype.Face.parse(font, 0);
    var buf: [8192]u8 = undefined;
    var w = std.Io.File.stdout().writerStreaming(init.io, &buf);
    const o = &w.interface;
    try o.print("{s:<8} {s:>6} {s:>10} {s:>6} {s:>8}\n", .{ "method", "scale", "mean diff", "max", "edge x" });
    inline for (comptime std.enums.values(Method)) |m| {
        for (scales) |s| {
            var st: Stat = .{};
            for (33..127) |cp| try compare(&face, @intCast(cp), m, s, &st);
            const mean = @as(f64, @floatFromInt(st.sum)) / @as(f64, @floatFromInt(st.pixels));
            const edge = @as(f64, @floatFromInt(st.partial)) / @as(f64, @floatFromInt(st.exact_partial));
            try o.print("{s:<8} {d:>6.1} {d:>10.2} {d:>6} {d:>8.2}\n", .{ @tagName(m), s, mean, st.max, edge });
        }
    }
    try o.print("\n{s:<24} {s:>10} {s:>10}\n", .{ "images of 94 glyphs", "build us", "bytes" });
    for ([_]u32{ 32, 48 }) |e| {
        const c = try cost(&face, @floatFromInt(e), true);
        try o.print("sdf em {d:<17} {d:>10.1} {d:>10}\n", .{ e, c[0], c[1] });
    }
    for (scales) |s| {
        const c = try cost(&face, label_px * s, false);
        try o.print("coverage at {d:>5.1} px     {d:>10.1} {d:>10}\n", .{ label_px * s, c[0], c[1] });
    }
    try o.flush();
}

/// Adds glyph `cp` drawn by `m` at camera scale `s`, against exact, to `st`.
fn compare(face: *const opentype.Face, cp: u21, m: Method, s: f32, st: *Stat) !void {
    var ol: opentype.Outline = .{ .x = &xs, .y = &ys, .on = &on, .ends = &ends };
    try face.outline(face.cmap.glyph(cp), &ol);
    const em: f32 = @floatFromInt(face.units_per_em);
    const p = label_px * s;
    const b = raster.box(&ol, p / em, 0);
    if (b.w == 0) return;
    raster.fill(&ol, p / em, 0, b, &acc);
    raster.coverage(&acc, &exact, @as(usize, b.w) * b.h);
    // The source image and its box, at its own size `q` px.
    const q: f32 = switch (m) {
        .sdf32 => 32,
        .sdf48 => 48,
        .stale => label_px,
    };
    const field = m != .stale;
    const sb = if (field) sdf.box(&ol, q / em, 0, spread) else raster.box(&ol, q / em, 0);
    if (field) {
        var segs: raster.Segments = .{ .x0 = &sx0, .y0 = &sy0, .x1 = &sx1, .y1 = &sy1 };
        try sdf.fill(&ol, q / em, 0, spread, sb, &segs, &acc, &source);
    } else {
        raster.fill(&ol, q / em, 0, sb, &acc);
        raster.coverage(&acc, &source, @as(usize, sb.w) * sb.h);
    }
    const k = q / p; // source texels per output pixel
    for (0..b.h) |y| for (0..b.w) |x| {
        // The output pixel's centre relative to the pen, y up, then in source texels.
        const px = @as(f32, @floatFromInt(b.left)) + @as(f32, @floatFromInt(x)) + 0.5;
        const py = @as(f32, @floatFromInt(b.top)) - @as(f32, @floatFromInt(y)) - 0.5;
        const u = px * k - @as(f32, @floatFromInt(sb.left));
        const v = @as(f32, @floatFromInt(sb.top)) - py * k;
        const t = bilinear(&source, sb, u, v, if (field) 0 else 0);
        const got: u8 = if (field) c: {
            const d = (t - 128) / 127 * spread; // texels
            const ppt = @max(1 / k, 0.5 / @as(f32, spread));
            break :c @intFromFloat(std.math.clamp(d * ppt + 0.5, 0, 1) * 255 + 0.5);
        } else @intFromFloat(std.math.clamp(t, 0, 255) + 0.5);
        st.add(got, exact[y * b.w + x]);
    };
}

/// The image `img` of box `b` read bilinearly at texel coordinates (`u`, `v`), centres at
/// half texels; `outside` past its edges.
fn bilinear(img: []const u8, b: raster.Box, u: f32, v: f32, outside: f32) f32 {
    const fx = u - 0.5;
    const fy = v - 0.5;
    const x0 = @floor(fx);
    const y0 = @floor(fy);
    const ax = fx - x0;
    const ay = fy - y0;
    var t: [4]f32 = undefined;
    for (0..4) |i| {
        const xi = @as(i32, @intFromFloat(x0)) + @as(i32, @intCast(i & 1));
        const yi = @as(i32, @intFromFloat(y0)) + @as(i32, @intCast(i >> 1));
        t[i] = if (xi < 0 or yi < 0 or xi >= b.w or yi >= b.h) outside else @floatFromInt(img[@as(usize, @intCast(yi)) * b.w + @as(usize, @intCast(xi))]);
    }
    const top = t[0] + (t[1] - t[0]) * ax;
    const bottom = t[2] + (t[3] - t[2]) * ax;
    return top + (bottom - top) * ay;
}

/// Median us to build the images of the printable ASCII glyphs at `px` (distance images when
/// `field`), and their atlas bytes.
fn cost(face: *const opentype.Face, px: f32, field: bool) ![2]f64 {
    const em: f32 = @floatFromInt(face.units_per_em);
    var times: [20]u64 = undefined;
    var bytes: u64 = 0;
    for (&times) |*time| {
        bytes = 0;
        const t0 = now();
        for (33..127) |cp| {
            var ol: opentype.Outline = .{ .x = &xs, .y = &ys, .on = &on, .ends = &ends };
            try face.outline(face.cmap.glyph(@intCast(cp)), &ol);
            const b = if (field) sdf.box(&ol, px / em, 0, spread) else raster.box(&ol, px / em, 0);
            if (b.w == 0) continue;
            if (field) {
                var segs: raster.Segments = .{ .x0 = &sx0, .y0 = &sy0, .x1 = &sx1, .y1 = &sy1 };
                try sdf.fill(&ol, px / em, 0, spread, b, &segs, &acc, &source);
            } else {
                raster.fill(&ol, px / em, 0, b, &acc);
                raster.coverage(&acc, &source, @as(usize, b.w) * b.h);
            }
            bytes += (@as(u64, b.w) + 1) * (b.h + 1);
        }
        time.* = now() - t0;
    }
    std.mem.sortUnstable(u64, &times, {}, std.sort.asc(u64));
    return .{ @as(f64, @floatFromInt(times[10])) / 1000, @floatFromInt(bytes) };
}

fn now() u64 {
    var ts: linux.timespec = undefined;
    _ = linux.clock_gettime(.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * 1_000_000_000 + @as(u64, @intCast(ts.nsec));
}
