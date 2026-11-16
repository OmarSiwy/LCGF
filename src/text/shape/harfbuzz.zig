//! Optional HarfBuzz adapter: complex-script shaping (Indic reordering and conjuncts, Arabic
//! joining, everything the built-in shaper of shape.zig does not do) behind the same data:
//! it fills the same `Run` columns, in font units with byte clusters, so caret mapping,
//! the shaping cache, measuring and rasterising work unchanged on its output.
//!
//! Outside the tiers: it links the C library HarfBuzz, so it is its own module over
//! `lcgr` (`zig build harfbuzz`; HarfBuzz 13.2.1 is a lazy build.zig.zon dependency built
//! from source), never
//! imported by the core and not exported from src/lcgr.zig. The C API is declared by hand
//! below (docs/DEPENDENCIES.md: small APIs need no header translation). HarfBuzz allocates
//! internally; the adapter keeps one face, font and buffer and reuses them.

const std = @import("std");
const lcgr = @import("lcgr");
const Run = lcgr.shape.Run;

const hb_blob_t = opaque {};
const hb_face_t = opaque {};
const hb_font_t = opaque {};
const hb_buffer_t = opaque {};
const hb_glyph_info_t = extern struct { codepoint: u32, mask: u32, cluster: u32, var1: u32, var2: u32 };
const hb_glyph_position_t = extern struct { x_advance: i32, y_advance: i32, x_offset: i32, y_offset: i32, v: u32 };
const hb_memory_mode_readonly: c_int = 1;
const hb_buffer_cluster_level_monotone_characters: c_int = 1;

extern fn hb_blob_create(data: [*]const u8, length: c_uint, mode: c_int, user_data: ?*anyopaque, destroy: ?*const fn (?*anyopaque) callconv(.c) void) *hb_blob_t;
extern fn hb_blob_destroy(blob: *hb_blob_t) void;
extern fn hb_face_create(blob: *hb_blob_t, index: c_uint) *hb_face_t;
extern fn hb_face_destroy(face: *hb_face_t) void;
extern fn hb_font_create(face: *hb_face_t) *hb_font_t;
extern fn hb_font_destroy(font: *hb_font_t) void;
extern fn hb_buffer_create() *hb_buffer_t;
extern fn hb_buffer_destroy(buf: *hb_buffer_t) void;
extern fn hb_buffer_clear_contents(buf: *hb_buffer_t) void;
extern fn hb_buffer_add_utf8(buf: *hb_buffer_t, text: [*]const u8, text_length: c_int, item_offset: c_uint, item_length: c_int) void;
extern fn hb_buffer_guess_segment_properties(buf: *hb_buffer_t) void;
extern fn hb_buffer_set_cluster_level(buf: *hb_buffer_t, level: c_int) void;
extern fn hb_buffer_get_length(buf: *hb_buffer_t) c_uint;
extern fn hb_buffer_get_glyph_infos(buf: *hb_buffer_t, length: ?*c_uint) [*]hb_glyph_info_t;
extern fn hb_buffer_get_glyph_positions(buf: *hb_buffer_t, length: ?*c_uint) [*]hb_glyph_position_t;
extern fn hb_shape(font: *hb_font_t, buf: *hb_buffer_t, features: ?*const anyopaque, num_features: c_uint) void;

/// One face shaped through HarfBuzz. The font bytes must outlive it (HarfBuzz reads them in
/// place). The font's scale is left at its default, units per em, so results are in font
/// units like the built-in shaper's.
pub const HarfBuzz = struct {
    blob: *hb_blob_t,
    face: *hb_face_t,
    font: *hb_font_t,
    buf: *hb_buffer_t,

    pub fn init(data: []const u8, index: u32) HarfBuzz {
        const blob = hb_blob_create(data.ptr, @intCast(data.len), hb_memory_mode_readonly, null, null);
        const face = hb_face_create(blob, index);
        return .{ .blob = blob, .face = face, .font = hb_font_create(face), .buf = hb_buffer_create() };
    }

    pub fn deinit(hb: *HarfBuzz) void {
        hb_buffer_destroy(hb.buf);
        hb_font_destroy(hb.font);
        hb_face_destroy(hb.face);
        hb_blob_destroy(hb.blob);
    }

    /// Shapes `text` (one run: direction, script and language guessed from the text, as
    /// `hb_buffer_guess_segment_properties` does) into `run`, glyphs in visual order with
    /// clusters as byte offsets into `text`. `error.NoSpace` when the run's columns are short.
    pub fn shape(hb: *HarfBuzz, text: []const u8, run: *Run) error{NoSpace}!void {
        hb_buffer_clear_contents(hb.buf);
        hb_buffer_add_utf8(hb.buf, text.ptr, @intCast(text.len), 0, @intCast(text.len));
        hb_buffer_guess_segment_properties(hb.buf);
        // Clusters never merge across characters that are not part of one shaping unit, the
        // same granularity as the built-in shaper (one cluster per character before ligation).
        hb_buffer_set_cluster_level(hb.buf, hb_buffer_cluster_level_monotone_characters);
        hb_shape(hb.font, hb.buf, null, 0);
        const n = hb_buffer_get_length(hb.buf);
        if (n > run.glyph.len) return error.NoSpace;
        const infos = hb_buffer_get_glyph_infos(hb.buf, null)[0..n];
        const pos = hb_buffer_get_glyph_positions(hb.buf, null)[0..n];
        for (infos, pos, 0..) |info, p, k| {
            run.glyph[k] = @intCast(info.codepoint);
            run.cluster[k] = info.cluster;
            run.advance[k] = p.x_advance;
            run.x_offset[k] = p.x_offset;
            run.y_offset[k] = p.y_offset;
        }
        run.len = @intCast(n);
    }
};

// ---------------------------------------------------------------------------------------------
// Done when: a complex-script sample renders through the adapter. Devanagari "हिन्दी नमस्ते"
// (pre-base matra reordering, conjuncts), shaped here and rasterised with src/text/raster/,
// against HarfBuzz's own output and FreeType's picture of it (testdata/deva.py).

const deva = @embedFile("testdata/deva.ttf");
const deva_hb = @embedFile("testdata/deva-hb.txt");
const deva_pgm = @embedFile("testdata/deva.pgm");
const sample = "\u{939}\u{93f}\u{928}\u{94d}\u{926}\u{940} \u{928}\u{92e}\u{938}\u{94d}\u{924}\u{947}";
// The picture's geometry (deva.py).
const px = 32;
const picture_w = 224;
const picture_h = 48;
const baseline = 36;

test "the adapter gives HarfBuzz's glyphs in the shaper's columns" {
    var hb: HarfBuzz = .init(deva, 0);
    defer hb.deinit();
    var cols: lcgr.shape.TestRun = .{};
    var run = cols.run();
    try hb.shape(sample, &run);
    // deva-hb.txt: gid,cluster,advance,x_offset,y_offset per glyph.
    var want = std.mem.tokenizeScalar(u8, std.mem.trimEnd(u8, deva_hb, "\n")[std.mem.lastIndexOfScalar(u8, deva_hb, '\t').? + 1 ..], ';');
    var k: u32 = 0;
    while (want.next()) |g| : (k += 1) {
        var f = std.mem.splitScalar(u8, g, ',');
        try std.testing.expectEqual(try std.fmt.parseInt(u16, f.next().?, 10), run.glyph[k]);
        try std.testing.expectEqual(try std.fmt.parseInt(u32, f.next().?, 10), run.cluster[k]);
        try std.testing.expectEqual(try std.fmt.parseInt(i32, f.next().?, 10), run.advance[k]);
        try std.testing.expectEqual(try std.fmt.parseInt(i32, f.next().?, 10), run.x_offset[k]);
        try std.testing.expectEqual(try std.fmt.parseInt(i32, f.next().?, 10), run.y_offset[k]);
    }
    try std.testing.expectEqual(k, run.len);
    // The i-matra (U+093F, after HA in the text) is drawn before HA and shares its cluster;
    // the built-in shaper, which does not reorder, keeps text order.
    try std.testing.expectEqual(run.cluster[0], run.cluster[1]);
    const face = try lcgr.opentype.Face.parse(deva, 0);
    var plain_cols: lcgr.shape.TestRun = .{};
    var plain = plain_cols.run();
    try lcgr.shape.shape(&face, sample, &plain);
    try std.testing.expectEqual(face.cmap.glyph(0x939), plain.glyph[0]);
    try std.testing.expect(plain.glyph[0] != run.glyph[0]);
    try std.testing.expect(plain.len != run.len);
}

test "a complex-script sample renders through the adapter" {
    var hb: HarfBuzz = .init(deva, 0);
    defer hb.deinit();
    var cols: lcgr.shape.TestRun = .{};
    var run = cols.run();
    try hb.shape(sample, &run);

    const raster = lcgr.raster;
    const face = try lcgr.opentype.Face.parse(deva, 0);
    const scale = @as(f32, px) / @as(f32, @floatFromInt(face.units_per_em));
    var img: [picture_w * picture_h]u8 = @splat(0);
    var ocols: raster.TestOutline = .{};
    var acc: [64 * 64]f32 = undefined;
    var cov: [64 * 64]u8 = undefined;
    var pen: i32 = 0;
    for (run.glyph[0..run.len], run.advance[0..run.len], run.x_offset[0..run.len], run.y_offset[0..run.len]) |g, adv, xo, yo| {
        defer pen += adv;
        // The sample has no vertical offsets, so the baseline stays on a pixel row.
        try std.testing.expectEqual(0, yo);
        var o = ocols.outline();
        try face.outline(g, &o);
        const x = 2 + @as(f32, @floatFromInt(pen + xo)) * scale;
        const pixel = @floor(x);
        const b = raster.box(&o, scale, x - pixel);
        if (b.w == 0) continue;
        raster.fill(&o, scale, x - pixel, b, &acc);
        raster.coverage(&acc, &cov, @as(usize, b.w) * b.h);
        // Composite by maximum coverage, as the reference does.
        for (0..b.h) |r| for (0..b.w) |c| {
            const ix = @as(i32, @intFromFloat(pixel)) + b.left + @as(i32, @intCast(c));
            const iy = baseline - b.top + @as(i32, @intCast(r));
            if (ix < 0 or iy < 0 or ix >= picture_w or iy >= picture_h) continue;
            const at = @as(usize, @intCast(iy)) * picture_w + @as(usize, @intCast(ix));
            img[at] = @max(img[at], cov[r * b.w + c]);
        };
    }

    const header = "P5\n224 48\n255\n";
    try std.testing.expectEqualStrings(header, deva_pgm[0..header.len]);
    const ref = deva_pgm[header.len..];
    var max: u32 = 0;
    var sum: u64 = 0;
    var ink: u64 = 0;
    for (img, ref) |a, b| {
        const d: u32 = @abs(@as(i32, a) - b);
        max = @max(max, d);
        sum += d;
        ink += @intFromBool(b != 0);
    }
    // The picture is the same glyphs at the same places, so only the rasterisers differ: the
    // per-pixel bound of raster.zig's reference test (measured: max 13 levels of 255), and a
    // mean under 2 levels per inked pixel of the reference (measured: 1,804 over 1,577).
    try std.testing.expect(max <= 16);
    try std.testing.expect(sum < 2 * ink);
    try std.testing.expect(ink > 1000);
}
