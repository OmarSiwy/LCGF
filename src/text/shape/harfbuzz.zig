//! Optional HarfBuzz adapter: complex-script shaping (Indic reordering and conjuncts, Arabic
//! joining, everything the built-in shaper of shape.zig does not do) behind the same data:
//! it fills the same `Run` columns, in font units with byte clusters, so caret mapping,
//! the shaping cache, measuring and rasterising work unchanged on its output.
//!
//! Outside the tiers: it links the C library HarfBuzz, so it is its own module over
//! `lcgf` (`zig build harfbuzz`; HarfBuzz 13.2.1 is a lazy build.zig.zon dependency built
//! from source), never
//! imported by the core and not exported from src/lcgf.zig. The C API is declared by hand
//! below (docs/DEPENDENCIES.md: small APIs need no header translation). HarfBuzz allocates
//! internally; the adapter keeps one face, font and buffer and reuses them.

const std = @import("std");
const lcgf = @import("lcgf");
const Run = lcgf.shape.Run;

const hb_blob_t = opaque {};
const hb_face_t = opaque {};
const hb_font_t = opaque {};
const hb_buffer_t = opaque {};
const hb_language_impl_t = opaque {};
const hb_draw_funcs_t = opaque {};
const hb_draw_state_t = opaque {};
const Destroy = ?*const fn (?*anyopaque) callconv(.c) void;
const DrawTo = *const fn (*hb_draw_funcs_t, ?*anyopaque, *hb_draw_state_t, f32, f32, ?*anyopaque) callconv(.c) void;
const DrawQuad = *const fn (*hb_draw_funcs_t, ?*anyopaque, *hb_draw_state_t, f32, f32, f32, f32, ?*anyopaque) callconv(.c) void;
const DrawCubic = *const fn (*hb_draw_funcs_t, ?*anyopaque, *hb_draw_state_t, f32, f32, f32, f32, f32, f32, ?*anyopaque) callconv(.c) void;
const DrawClose = *const fn (*hb_draw_funcs_t, ?*anyopaque, *hb_draw_state_t, ?*anyopaque) callconv(.c) void;
const hb_glyph_info_t = extern struct { codepoint: u32, mask: u32, cluster: u32, var1: u32, var2: u32 };
const hb_glyph_position_t = extern struct { x_advance: i32, y_advance: i32, x_offset: i32, y_offset: i32, v: u32 };
const hb_memory_mode_readonly: c_int = 1;
const hb_buffer_cluster_level_monotone_characters: c_int = 1;

extern fn hb_blob_create(data: [*]const u8, length: c_uint, mode: c_int, user_data: ?*anyopaque, destroy: ?*const fn (?*anyopaque) callconv(.c) void) *hb_blob_t;
extern fn hb_blob_destroy(blob: *hb_blob_t) void;
extern fn hb_blob_get_length(blob: *hb_blob_t) c_uint;
extern fn hb_blob_get_data(blob: *hb_blob_t, length: ?*c_uint) ?[*]const u8;
extern fn hb_face_create(blob: *hb_blob_t, index: c_uint) *hb_face_t;
extern fn hb_face_destroy(face: *hb_face_t) void;
extern fn hb_face_reference_table(face: *hb_face_t, tag: u32) *hb_blob_t;
extern fn hb_font_create(face: *hb_face_t) *hb_font_t;
extern fn hb_font_destroy(font: *hb_font_t) void;
extern fn hb_font_set_ppem(font: *hb_font_t, x: c_uint, y: c_uint) void;
extern fn hb_buffer_create() *hb_buffer_t;
extern fn hb_buffer_destroy(buf: *hb_buffer_t) void;
extern fn hb_buffer_clear_contents(buf: *hb_buffer_t) void;
extern fn hb_buffer_add_utf8(buf: *hb_buffer_t, text: [*]const u8, text_length: c_int, item_offset: c_uint, item_length: c_int) void;
extern fn hb_buffer_guess_segment_properties(buf: *hb_buffer_t) void;
extern fn hb_buffer_set_cluster_level(buf: *hb_buffer_t, level: c_int) void;
extern fn hb_buffer_set_direction(buf: *hb_buffer_t, direction: c_int) void;
extern fn hb_buffer_set_script(buf: *hb_buffer_t, script: u32) void;
extern fn hb_buffer_set_language(buf: *hb_buffer_t, language: ?*const hb_language_impl_t) void;
extern fn hb_language_from_string(text: [*]const u8, length: c_int) ?*const hb_language_impl_t;
extern fn hb_font_set_variations(font: *hb_font_t, variations: ?[*]const Variation, length: c_uint) void;
extern fn hb_draw_funcs_create() *hb_draw_funcs_t;
extern fn hb_draw_funcs_get_empty() *hb_draw_funcs_t;
extern fn hb_draw_funcs_destroy(funcs: *hb_draw_funcs_t) void;
extern fn hb_draw_funcs_make_immutable(funcs: *hb_draw_funcs_t) void;
extern fn hb_draw_funcs_set_move_to_func(funcs: *hb_draw_funcs_t, callback: DrawTo, data: ?*anyopaque, destroy: Destroy) void;
extern fn hb_draw_funcs_set_line_to_func(funcs: *hb_draw_funcs_t, callback: DrawTo, data: ?*anyopaque, destroy: Destroy) void;
extern fn hb_draw_funcs_set_quadratic_to_func(funcs: *hb_draw_funcs_t, callback: DrawQuad, data: ?*anyopaque, destroy: Destroy) void;
extern fn hb_draw_funcs_set_cubic_to_func(funcs: *hb_draw_funcs_t, callback: DrawCubic, data: ?*anyopaque, destroy: Destroy) void;
extern fn hb_draw_funcs_set_close_path_func(funcs: *hb_draw_funcs_t, callback: DrawClose, data: ?*anyopaque, destroy: Destroy) void;
extern fn hb_font_draw_glyph_or_fail(font: *hb_font_t, glyph: u32, funcs: *hb_draw_funcs_t, data: ?*anyopaque) c_int;
extern fn hb_ot_color_has_layers(face: *hb_face_t) c_int;
extern fn hb_ot_color_has_paint(face: *hb_face_t) c_int;
extern fn hb_ot_color_glyph_has_paint(face: *hb_face_t, glyph: u32) c_int;
extern fn hb_ot_color_has_svg(face: *hb_face_t) c_int;
extern fn hb_ot_color_has_png(face: *hb_face_t) c_int;
extern fn hb_ot_color_palette_get_count(face: *hb_face_t) c_uint;
extern fn hb_ot_color_palette_get_colors(face: *hb_face_t, palette: c_uint, start: c_uint, count: ?*c_uint, colors: ?[*]u32) c_uint;
extern fn hb_ot_color_glyph_get_layers(face: *hb_face_t, glyph: u32, start: c_uint, count: ?*c_uint, layers: ?[*]LayerRef) c_uint;
extern fn hb_ot_color_glyph_reference_svg(face: *hb_face_t, glyph: u32) *hb_blob_t;
extern fn hb_ot_color_glyph_reference_png(font: *hb_font_t, glyph: u32) *hb_blob_t;
extern fn hb_buffer_get_length(buf: *hb_buffer_t) c_uint;
extern fn hb_buffer_get_glyph_infos(buf: *hb_buffer_t, length: ?*c_uint) [*]hb_glyph_info_t;
extern fn hb_buffer_get_glyph_positions(buf: *hb_buffer_t, length: ?*c_uint) [*]hb_glyph_position_t;
extern fn hb_shape(font: *hb_font_t, buf: *hb_buffer_t, features: ?*const anyopaque, num_features: c_uint) void;

/// OpenType feature values and byte ranges, passed directly to HarfBuzz. Use tag("tnum"),
/// tag("smcp"), tag("ss01"), etc.; features unsupported by a font leave its glyphs alone.
pub const Feature = extern struct {
    tag: u32,
    value: u32 = 1,
    start: u32 = 0,
    end: u32 = std.math.maxInt(u32),
};
pub const Variation = extern struct { tag: u32, value: f32 };
pub const Options = struct {
    /// Horizontal directions supported by Run's advance column. Vertical advances need a
    /// vertical text pipeline and are not silently discarded through this API.
    direction: enum(c_int) { auto = 0, ltr = 4, rtl = 5 } = .auto,
    /// ISO 15924 tag (e.g. tag("Arab")); null guesses from the text.
    script: ?u32 = null,
    /// BCP 47 language, e.g. "tr" for Turkish localized forms. Empty uses HarfBuzz's guess.
    language: []const u8 = "",
    features: []const Feature = &.{},
    /// Complete axis settings for this call. An empty slice resets all axes to defaults;
    /// callers rasterizing these glyphs must use the same variable-font instance.
    variations: []const Variation = &.{},
    cluster_level: enum(c_int) { graphemes = 0, characters = 1 } = .characters,
};

pub const LayerRef = extern struct { glyph: u32, color_index: u32 };
pub const ColorLayer = struct { glyph: u16, color: lcgf.types.Color };
pub const ColorError = error{ NoSpace, NoColorLayers, InvalidPalette, InvalidGlyph, NeedsPaintPipeline };
pub const Formats = struct {
    true_type: bool,
    cff: bool,
    cff2: bool,
    variable: bool,
    colr_layers: bool,
    colr_paint: bool,
    palettes: u32,
    png: bool,
    svg: bool,
};

/// One face shaped through HarfBuzz. The font bytes must outlive it (HarfBuzz reads them in
/// place). The font's scale is left at its default, units per em, so results are in font
/// units like the built-in shaper's.
pub const HarfBuzz = struct {
    blob: *hb_blob_t,
    face: *hb_face_t,
    font: *hb_font_t,
    buf: *hb_buffer_t,
    /// Lazily allocated by outline; shaping-only callers do not create drawing callbacks.
    draw: ?*hb_draw_funcs_t = null,

    pub fn init(data: []const u8, index: u32) HarfBuzz {
        const blob = hb_blob_create(data.ptr, @intCast(data.len), hb_memory_mode_readonly, null, null);
        const face = hb_face_create(blob, index);
        return .{ .blob = blob, .face = face, .font = hb_font_create(face), .buf = hb_buffer_create() };
    }

    pub fn deinit(hb: *HarfBuzz) void {
        if (hb.draw) |draw| hb_draw_funcs_destroy(draw);
        hb_buffer_destroy(hb.buf);
        hb_font_destroy(hb.font);
        hb_face_destroy(hb.face);
        hb_blob_destroy(hb.blob);
    }

    /// Shapes `text` (one run: direction, script and language guessed from the text, as
    /// `hb_buffer_guess_segment_properties` does) into `run`, glyphs in visual order with
    /// clusters as byte offsets into `text`. `error.NoSpace` when the run's columns are short.
    pub fn shape(hb: *HarfBuzz, text: []const u8, run: *Run) error{NoSpace}!void {
        return hb.shapeOptions(text, run, .{});
    }

    /// Explicit script/language/direction, feature ranges and variable axes. This remains an
    /// optional allocating host adapter: its output is the same caller-owned glyph rows.
    pub fn shapeOptions(hb: *HarfBuzz, text: []const u8, run: *Run, options: Options) error{NoSpace}!void {
        hb.shapeBuffer(text, options, @backingInt(options.direction));
        try hb.copyRun(run);
    }

    /// Real vertical shaping, including the font's vertical substitutions, origins and
    /// advances. Horizontal advances stay in Run.advance, vertical ones in caller y_advance;
    /// vertical_text.fromRun consumes both, so no advance component is silently discarded.
    pub fn shapeVertical(hb: *HarfBuzz, text: []const u8, run: *Run, y_advance: []i32, options: Options, direction: enum { top_to_bottom, bottom_to_top }) error{NoSpace}!void {
        hb.shapeBuffer(text, options, if (direction == .top_to_bottom) 6 else 7);
        const n = hb_buffer_get_length(hb.buf);
        if (y_advance.len < n) return error.NoSpace;
        try hb.copyRun(run);
        const positions = hb_buffer_get_glyph_positions(hb.buf, null)[0..n];
        for (positions, y_advance[0..n]) |position, *advance| advance.* = position.y_advance;
    }

    fn shapeBuffer(hb: *HarfBuzz, text: []const u8, options: Options, direction: c_int) void {
        hb_buffer_clear_contents(hb.buf);
        hb_buffer_add_utf8(hb.buf, text.ptr, @intCast(text.len), 0, @intCast(text.len));
        if (direction != 0) hb_buffer_set_direction(hb.buf, direction);
        if (options.script) |script| hb_buffer_set_script(hb.buf, script);
        if (options.language.len > 0) hb_buffer_set_language(hb.buf, hb_language_from_string(options.language.ptr, @intCast(options.language.len)));
        hb_buffer_guess_segment_properties(hb.buf);
        // Clusters never merge across characters that are not part of one shaping unit, the
        // same granularity as the built-in shaper (one cluster per character before ligation).
        hb_buffer_set_cluster_level(hb.buf, @backingInt(options.cluster_level));
        hb_font_set_variations(hb.font, if (options.variations.len == 0) null else options.variations.ptr, @intCast(options.variations.len));
        hb_shape(hb.font, hb.buf, if (options.features.len == 0) null else options.features.ptr, @intCast(options.features.len));
    }

    fn copyRun(hb: *HarfBuzz, run: *Run) error{NoSpace}!void {
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

    /// TrueType, CFF/CFF2 and variable outlines through HarfBuzz into the existing bounded
    /// path rasterizer. `transform` maps font units (y up) to caller path coordinates; e.g.
    /// {px/em,0,0,-px/em,x,baseline}. Axes are explicit for this call and reset when empty.
    /// Callback allocation occurs lazily in this optional host adapter, never in the core.
    /// A short path or unsupported outline returns an error and clears the partial result.
    pub fn outline(hb: *HarfBuzz, glyph: u16, variations: []const Variation, transform: [6]f32, path: *lcgf.paths.Path) error{ NoSpace, NoOutline, Unavailable, NonFinite }!void {
        path.clear();
        for (transform) |v| if (!std.math.isFinite(v)) return error.NonFinite;
        if (hb.draw == null) {
            const funcs = hb_draw_funcs_create();
            if (funcs == hb_draw_funcs_get_empty()) return error.Unavailable;
            hb_draw_funcs_set_move_to_func(funcs, PathSink.move, null, null);
            hb_draw_funcs_set_line_to_func(funcs, PathSink.line, null, null);
            hb_draw_funcs_set_quadratic_to_func(funcs, PathSink.quadratic, null, null);
            hb_draw_funcs_set_cubic_to_func(funcs, PathSink.cubic, null, null);
            hb_draw_funcs_set_close_path_func(funcs, PathSink.close, null, null);
            hb_draw_funcs_make_immutable(funcs);
            hb.draw = funcs;
        }
        hb_font_set_variations(hb.font, if (variations.len == 0) null else variations.ptr, @intCast(variations.len));
        var sink: PathSink = .{ .path = path, .transform = transform };
        const present = hb_font_draw_glyph_or_fail(hb.font, glyph, hb.draw.?, &sink);
        errdefer path.clear();
        if (sink.full) return error.NoSpace;
        if (sink.invalid) return error.NonFinite;
        if (present == 0) return error.NoOutline;
    }

    /// Concrete file-format diagnostics for selecting the appropriate existing draw path.
    /// COLRv1 is distinguished from COLRv0 layers instead of silently rendering it as v0.
    pub fn formats(hb: *const HarfBuzz) Formats {
        return .{
            .true_type = hb.hasTable(lcgf.opentype.tag("glyf")),
            .cff = hb.hasTable(lcgf.opentype.tag("CFF ")),
            .cff2 = hb.hasTable(lcgf.opentype.tag("CFF2")),
            .variable = hb.hasTable(lcgf.opentype.tag("fvar")),
            .colr_layers = hb_ot_color_has_layers(hb.face) != 0,
            .colr_paint = hb_ot_color_has_paint(hb.face) != 0,
            .palettes = hb_ot_color_palette_get_count(hb.face),
            .png = hb_ot_color_has_png(hb.face) != 0,
            .svg = hb_ot_color_has_svg(hb.face) != 0,
        };
    }

    fn hasTable(hb: *const HarfBuzz, table: u32) bool {
        const blob = hb_face_reference_table(hb.face, table);
        defer hb_blob_destroy(blob);
        return hb_blob_get_length(blob) != 0;
    }

    /// COLRv0 layer glyphs in paint order with actual selected CPAL colors. A foreground
    /// reference (0xffff) uses the supplied foreground. Caller tables bound all work/storage.
    pub fn colorLayers(hb: *const HarfBuzz, glyph: u16, palette: u32, foreground: lcgf.types.Color, refs: []LayerRef, out: []ColorLayer) ColorError!u32 {
        const total = hb_ot_color_glyph_get_layers(hb.face, glyph, 0, null, null);
        if (total == 0) return if (hb_ot_color_glyph_has_paint(hb.face, glyph) != 0) error.NeedsPaintPipeline else error.NoColorLayers;
        if (palette >= hb_ot_color_palette_get_count(hb.face)) return error.InvalidPalette;
        if (refs.len < total or out.len < total) return error.NoSpace;
        var count = total;
        _ = hb_ot_color_glyph_get_layers(hb.face, glyph, 0, &count, refs.ptr);
        for (refs[0..count], out[0..count]) |layer, *result| {
            if (layer.glyph > std.math.maxInt(u16)) return error.InvalidGlyph;
            var color = foreground;
            if (layer.color_index != 0xffff) {
                var n: c_uint = 1;
                var hb_colors: [1]u32 = undefined;
                _ = hb_ot_color_palette_get_colors(hb.face, palette, layer.color_index, &n, &hb_colors);
                if (n != 1) return error.InvalidPalette;
                const c = hb_colors[0]; // HarfBuzz is 0xBBGGRRAA; Color is explicit RGBA channels.
                color = .rgba(@truncate(c >> 8), @truncate(c >> 16), @truncate(c >> 24), @truncate(c));
            }
            result.* = .{ .glyph = @intCast(layer.glyph), .color = color };
        }
        return count;
    }

    /// Copies the glyph's compressed PNG from sbix/CBDT into caller bytes. The returned
    /// payload is accepted by lcgf.png.decode and can then enter the existing image atlas.
    pub fn copyPng(hb: *HarfBuzz, glyph: u16, ppem: [2]u32, out: []u8) error{ NoSpace, NoImage }![]const u8 {
        hb_font_set_ppem(hb.font, ppem[0], ppem[1]);
        const blob = hb_ot_color_glyph_reference_png(hb.font, glyph);
        defer hb_blob_destroy(blob);
        return copyBlob(blob, out);
    }

    /// Copies the SVG document bytes, preserving their exact profile for the caller's SVG
    /// decoder. SVG fonts can use features beyond a UI SVG subset; extraction alone never
    /// claims those features were rendered. A compressed document stays compressed.
    pub fn copySvg(hb: *const HarfBuzz, glyph: u16, out: []u8) error{ NoSpace, NoImage }![]const u8 {
        const blob = hb_ot_color_glyph_reference_svg(hb.face, glyph);
        defer hb_blob_destroy(blob);
        return copyBlob(blob, out);
    }

    /// Renders real COLRv0 layers through outline -> paths.flatten/fill -> premultiplied
    /// source-over RGBA, using the requested palette and variable axes. The output surface
    /// is cleared first. Transforms map font coordinates into this image's coordinates.
    pub fn rasterLayers(hb: *HarfBuzz, glyph: u16, palette: u32, foreground: lcgf.types.Color, variations: []const Variation, transform: [6]f32, surface: Surface, scratch: ColorScratch) !void {
        if (surface.pixels.len < @as(usize, surface.width) * surface.height * 4) return error.NoSpace;
        @memset(surface.pixels[0 .. @as(usize, surface.width) * surface.height * 4], 0);
        const count = try hb.colorLayers(glyph, palette, foreground, scratch.refs, scratch.layers);
        for (scratch.layers[0..count]) |layer| {
            try hb.outline(layer.glyph, variations, transform, scratch.path);
            const need = lcgf.paths.flattenLen(scratch.path, scratch.tolerance);
            if (need.points > scratch.poly.x.len or need.points > scratch.poly.y.len or need.contours > scratch.poly.end.len or need.contours > scratch.poly.closed.len) return error.NoSpace;
            lcgf.paths.flatten(scratch.path, scratch.tolerance, scratch.poly);
            const b = lcgf.paths.bounds(scratch.poly);
            if (scratch.acc.len < lcgf.paths.accLen(b) or scratch.coverage.len < lcgf.paths.imageLen(b)) return error.NoSpace;
            const points = scratch.poly.points;
            if (scratch.scan.x0.len < points or scratch.scan.y0.len < points or scratch.scan.y1.len < points or scratch.scan.dxdy.len < points or scratch.scan.cross_x.len < points or scratch.scan.cross_d.len < points) return error.NoSpace;
            lcgf.paths.fill(scratch.poly, b, .nonzero, scratch.scan, scratch.acc);
            lcgf.raster.coverage(scratch.acc, scratch.coverage, @as(usize, b.w) * b.h);
            const color = layer.color;
            for (0..b.h) |y| for (0..b.w) |x| {
                const dx = @as(i64, b.x) + @as(i64, @intCast(x));
                const dy = @as(i64, b.y) + @as(i64, @intCast(y));
                if (dx < 0 or dy < 0 or dx >= surface.width or dy >= surface.height) continue;
                const to = (@as(usize, @intCast(dy)) * surface.width + @as(usize, @intCast(dx))) * 4;
                const alpha: u32 = (@as(u32, color.a) * scratch.coverage[y * b.w + x] + 127) / 255;
                const inverse = 255 - alpha;
                inline for (.{ "r", "g", "b" }, 0..) |channel, c| {
                    const premultiplied = (@as(u32, @field(color, channel)) * alpha + 127) / 255;
                    surface.pixels[to + c] = @intCast(@min(premultiplied + (@as(u32, surface.pixels[to + c]) * inverse + 127) / 255, 255));
                }
                surface.pixels[to + 3] = @intCast(@min(alpha + (@as(u32, surface.pixels[to + 3]) * inverse + 127) / 255, 255));
            };
        }
    }
};

fn copyBlob(blob: *hb_blob_t, out: []u8) error{ NoSpace, NoImage }![]const u8 {
    var n: c_uint = 0;
    const bytes = hb_blob_get_data(blob, &n) orelse return error.NoImage;
    if (n == 0) return error.NoImage;
    if (n > out.len) return error.NoSpace;
    @memcpy(out[0..n], bytes[0..n]);
    return out[0..n];
}

pub const Surface = struct { width: u32, height: u32, pixels: []u8 };
pub const ColorScratch = struct {
    refs: []LayerRef,
    layers: []ColorLayer,
    path: *lcgf.paths.Path,
    poly: *lcgf.paths.Polyline,
    scan: lcgf.paths.Scratch,
    acc: []f32,
    coverage: []u8,
    tolerance: f32 = 0.25,
};

/// C callbacks are confined to this adapter and only append to the caller's bounded columns.
const PathSink = struct {
    path: *lcgf.paths.Path,
    transform: [6]f32,
    full: bool = false,
    invalid: bool = false,

    fn get(data: ?*anyopaque) *PathSink {
        return @ptrCast(@alignCast(data.?));
    }
    fn room(s: *PathSink, points: usize) bool {
        s.full = s.full or s.path.verbs >= s.path.verb.len or s.path.points + points > s.path.x.len or s.path.points + points > s.path.y.len;
        return !s.full and !s.invalid;
    }
    fn point(s: *PathSink, x: f32, y: f32) [2]f32 {
        const m = s.transform;
        const p = [2]f32{ m[0] * x + m[2] * y + m[4], m[1] * x + m[3] * y + m[5] };
        s.invalid = s.invalid or !std.math.isFinite(p[0]) or !std.math.isFinite(p[1]);
        return p;
    }
    fn move(_: *hb_draw_funcs_t, data: ?*anyopaque, _: *hb_draw_state_t, x: f32, y: f32, _: ?*anyopaque) callconv(.c) void {
        const s = get(data);
        if (!s.room(1)) return;
        const p = s.point(x, y);
        if (!s.invalid) s.path.moveTo(p[0], p[1]);
    }
    fn line(_: *hb_draw_funcs_t, data: ?*anyopaque, _: *hb_draw_state_t, x: f32, y: f32, _: ?*anyopaque) callconv(.c) void {
        const s = get(data);
        if (!s.room(1)) return;
        const p = s.point(x, y);
        if (!s.invalid) s.path.lineTo(p[0], p[1]);
    }
    fn quadratic(_: *hb_draw_funcs_t, data: ?*anyopaque, _: *hb_draw_state_t, cx: f32, cy: f32, x: f32, y: f32, _: ?*anyopaque) callconv(.c) void {
        const s = get(data);
        if (!s.room(2)) return;
        const c = s.point(cx, cy);
        const p = s.point(x, y);
        if (!s.invalid) s.path.quadTo(c[0], c[1], p[0], p[1]);
    }
    fn cubic(_: *hb_draw_funcs_t, data: ?*anyopaque, _: *hb_draw_state_t, c0x: f32, c0y: f32, c1x: f32, c1y: f32, x: f32, y: f32, _: ?*anyopaque) callconv(.c) void {
        const s = get(data);
        if (!s.room(3)) return;
        const c0 = s.point(c0x, c0y);
        const c1 = s.point(c1x, c1y);
        const p = s.point(x, y);
        if (!s.invalid) s.path.cubicTo(c0[0], c0[1], c1[0], c1[1], p[0], p[1]);
    }
    fn close(_: *hb_draw_funcs_t, data: ?*anyopaque, _: *hb_draw_state_t, _: ?*anyopaque) callconv(.c) void {
        const s = get(data);
        if (s.room(0)) s.path.close();
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
    var cols: lcgf.shape.TestRun = .{};
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
    const face = try lcgf.opentype.Face.parse(deva, 0);
    var plain_cols: lcgf.shape.TestRun = .{};
    var plain = plain_cols.run();
    try lcgf.shape.shape(&face, sample, &plain);
    try std.testing.expectEqual(face.cmap.glyph(0x939), plain.glyph[0]);
    try std.testing.expect(plain.glyph[0] != run.glyph[0]);
    try std.testing.expect(plain.len != run.len);
}

test "explicit feature ranges direction and language reach HarfBuzz and reset per call" {
    var hb: HarfBuzz = .init(@embedFile("testdata/shape.ttf"), 0);
    defer hb.deinit();
    var cols: lcgf.shape.TestRun = .{};
    var run = cols.run();
    try hb.shape("office", &run);
    const ligatures = run.len;
    try hb.shapeOptions("office", &run, .{
        .language = "en",
        .script = lcgf.opentype.tag("Latn"),
        .direction = .ltr,
        .features = &.{.{ .tag = lcgf.opentype.tag("liga"), .value = 0, .start = 0, .end = 6 }},
    });
    try std.testing.expectEqual(6, run.len);
    try std.testing.expect(ligatures < run.len);
    try hb.shape("office", &run);
    try std.testing.expectEqual(ligatures, run.len);
    try hb.shapeOptions("abc", &run, .{ .direction = .rtl, .script = lcgf.opentype.tag("Latn"), .language = "en" });
    try std.testing.expectEqualSlices(u32, &.{ 2, 1, 0 }, run.cluster[0..run.len]);
    try hb.shape("abc", &run);
    try std.testing.expectEqualSlices(u32, &.{ 0, 1, 2 }, run.cluster[0..run.len]);
}

test "variable coordinates change real glyph advances and an empty axis list restores defaults" {
    var hb: HarfBuzz = .init(@embedFile("testdata/variable.ttf"), 0);
    defer hb.deinit();
    var cols: lcgf.shape.TestRun = .{};
    var run = cols.run();
    try hb.shape("A", &run);
    try std.testing.expectEqual(500, run.advance[0]);
    try hb.shapeOptions("A", &run, .{ .variations = &.{.{ .tag = lcgf.opentype.tag("wght"), .value = 500 }} });
    try std.testing.expectEqual(700, run.advance[0]);
    try hb.shapeOptions("A", &run, .{ .variations = &.{.{ .tag = lcgf.opentype.tag("wght"), .value = 900 }} });
    try std.testing.expectEqual(900, run.advance[0]);
    try hb.shape("A", &run);
    try std.testing.expectEqual(500, run.advance[0]);
}

test "vertical HarfBuzz advances feed the bounded vertical layout consumer" {
    var hb: HarfBuzz = .init(@embedFile("testdata/variable.ttf"), 0);
    defer hb.deinit();
    var cols: lcgf.shape.TestRun = .{};
    var run = cols.run();
    var y_advance: [8]i32 = undefined;
    try hb.shapeVertical("AAAA", &run, &y_advance, .{}, .top_to_bottom);
    try std.testing.expectEqual(4, run.len);
    for (y_advance[0..run.len]) |advance| try std.testing.expect(advance < 0);
    var items: [8]lcgf.vertical_text.Item = undefined;
    const input = try lcgf.vertical_text.fromRun(&run, &y_advance, 0.02, .upright, &items);
    var heights: [8]f32 = undefined;
    var positions: [8]lcgf.vertical_text.Position = undefined;
    const extent = input[0].advance;
    const result = try lcgf.vertical_text.place(input, "AAAA", .{ .inline_limit = extent * 2, .column_extent = 20 }, &heights, &positions);
    try std.testing.expectEqual(2, result.columns);
    try std.testing.expect(positions[0].pen[0] > positions[2].pen[0]);
}

test "variable outlines change rasterized coverage through bounded existing path buffers" {
    var hb: HarfBuzz = .init(@embedFile("testdata/variable.ttf"), 0);
    defer hb.deinit();
    var glyph_cols: lcgf.shape.TestRun = .{};
    var run = glyph_cols.run();
    try hb.shape("A", &run);
    const glyph = run.glyph[0];
    var buffers: lcgf.paths.TestBuffers(16, 128) = .{};
    var path = buffers.path();
    var poly = buffers.polyline();
    var acc: [8192]f32 = undefined;
    var coverage: [8192]u8 = undefined;
    for ([_]f32{ 100, 500, 900 }, [_]u32{ 40, 60, 80 }) |weight, width| {
        try hb.outline(glyph, &.{.{ .tag = lcgf.opentype.tag("wght"), .value = weight }}, .{ 0.1, 0, 0, -0.1, 0, 80 }, &path);
        lcgf.paths.flatten(&path, 0.1, &poly);
        const box = lcgf.paths.bounds(&poly);
        try std.testing.expectEqual(width, box.w);
        try std.testing.expectEqual(70, box.h);
        lcgf.paths.fill(&poly, box, .nonzero, buffers.scratch(), &acc);
        lcgf.raster.coverage(&acc, &coverage, @as(usize, box.w) * box.h);
        var sum: usize = 0;
        for (coverage[0 .. @as(usize, box.w) * box.h]) |value| sum += value;
        try std.testing.expectEqual(@as(usize, width) * 70 * 255, sum);
    }
    path.verb = path.verb[0..1];
    try std.testing.expectError(error.NoSpace, hb.outline(glyph, &.{}, .{ 1, 0, 0, 1, 0, 0 }, &path));
    try std.testing.expectEqual(0, path.verbs);
    try std.testing.expectEqual(0, path.points);
}

test "CFF and CFF2 cubic outlines connect to the same path rasterizer" {
    inline for (.{ @embedFile("testdata/cff.otf"), @embedFile("testdata/cff2.otf") }) |data| {
        try std.testing.expectError(error.Unsupported, lcgf.opentype.Face.parse(data, 0));
        var hb: HarfBuzz = .init(data, 0);
        defer hb.deinit();
        var glyph_cols: lcgf.shape.TestRun = .{};
        var run = glyph_cols.run();
        try hb.shape("A", &run);
        try std.testing.expect(run.glyph[0] != 0);
        var buffers: lcgf.paths.TestBuffers(16, 256) = .{};
        var path = buffers.path();
        var poly = buffers.polyline();
        try hb.outline(run.glyph[0], &.{}, .{ 0.1, 0, 0, -0.1, 0, 80 }, &path);
        try std.testing.expect(std.mem.indexOfScalar(lcgf.paths.Verb, path.verb[0..path.verbs], .cubic) != null);
        lcgf.paths.flatten(&path, 0.1, &poly);
        const box = lcgf.paths.bounds(&poly);
        var acc: [8192]f32 = undefined;
        var coverage: [8192]u8 = undefined;
        lcgf.paths.fill(&poly, box, .nonzero, buffers.scratch(), &acc);
        lcgf.raster.coverage(&acc, &coverage, @as(usize, box.w) * box.h);
        var ink: usize = 0;
        for (coverage[0 .. @as(usize, box.w) * box.h]) |value| ink += @intFromBool(value > 0);
        try std.testing.expect(ink > 500);
    }
}

test "COLRv0 palettes change real rasterized glyph layer colors" {
    var hb: HarfBuzz = .init(@embedFile("testdata/color-layers.ttf"), 0);
    defer hb.deinit();
    var glyph_cols: lcgf.shape.TestRun = .{};
    var run = glyph_cols.run();
    try hb.shape("A", &run);
    const f = hb.formats();
    try std.testing.expect(f.colr_layers and !f.colr_paint and f.palettes == 2);
    var refs: [4]LayerRef = undefined;
    var layers: [4]ColorLayer = undefined;
    const n = try hb.colorLayers(run.glyph[0], 0, .black, &refs, &layers);
    try std.testing.expectEqual(2, n);
    try std.testing.expectEqual(lcgf.types.Color.rgba(255, 0, 0, 255), layers[0].color);
    try std.testing.expectEqual(lcgf.types.Color.rgba(0, 0, 255, 255), layers[1].color);
    try std.testing.expectError(error.InvalidPalette, hb.colorLayers(run.glyph[0], 9, .black, &refs, &layers));
    try std.testing.expectError(error.NoSpace, hb.colorLayers(run.glyph[0], 0, .black, refs[0..1], &layers));
    var buffers: lcgf.paths.TestBuffers(16, 128) = .{};
    var path = buffers.path();
    var poly = buffers.polyline();
    var acc: [4096]f32 = undefined;
    var coverage: [4096]u8 = undefined;
    var rgba: [50 * 80 * 4]u8 = undefined;
    const surface: Surface = .{ .width = 50, .height = 80, .pixels = &rgba };
    const scratch: ColorScratch = .{ .refs = &refs, .layers = &layers, .path = &path, .poly = &poly, .scan = buffers.scratch(), .acc = &acc, .coverage = &coverage };
    try hb.rasterLayers(run.glyph[0], 0, .black, &.{}, .{ 0.1, 0, 0, -0.1, 0, 80 }, surface, scratch);
    const left = (20 * 50 + 10) * 4;
    const right = (20 * 50 + 35) * 4;
    try std.testing.expectEqualSlices(u8, &.{ 255, 0, 0, 255 }, rgba[left..][0..4]);
    try std.testing.expectEqualSlices(u8, &.{ 0, 0, 255, 255 }, rgba[right..][0..4]);
    try hb.rasterLayers(run.glyph[0], 1, .black, &.{}, .{ 0.1, 0, 0, -0.1, 0, 80 }, surface, scratch);
    try std.testing.expectEqualSlices(u8, &.{ 0, 255, 0, 255 }, rgba[left..][0..4]);
    try std.testing.expectEqualSlices(u8, &.{ 128, 128, 0, 128 }, rgba[right..][0..4]);
}

test "bitmap color fonts decode with the existing PNG path and SVG extraction is explicit" {
    var hb: HarfBuzz = .init(@embedFile("testdata/color-png.ttf"), 0);
    defer hb.deinit();
    var glyph_cols: lcgf.shape.TestRun = .{};
    var run = glyph_cols.run();
    try hb.shape("A", &run);
    try std.testing.expect(hb.formats().png);
    var encoded: [1024]u8 = undefined;
    const png = try hb.copyPng(run.glyph[0], .{ 16, 16 }, &encoded);
    var pixels: [4]u8 = undefined;
    var scratch: [1024]u8 = undefined;
    const info = try lcgf.png.decode(png, &pixels, &scratch);
    try std.testing.expectEqual(1, info.w);
    try std.testing.expectEqual(1, info.h);
    try std.testing.expectEqualSlices(u8, &.{ 255, 128, 0, 255 }, &pixels);
    try std.testing.expectError(error.NoSpace, hb.copyPng(run.glyph[0], .{ 16, 16 }, encoded[0..1]));
    var svg_hb: HarfBuzz = .init(@embedFile("testdata/color-svg.ttf"), 0);
    defer svg_hb.deinit();
    try svg_hb.shape("A", &run);
    try std.testing.expect(svg_hb.formats().svg);
    const svg = try svg_hb.copySvg(run.glyph[0], &encoded);
    try std.testing.expect(std.mem.startsWith(u8, svg, "<svg "));
    try std.testing.expect(std.mem.indexOf(u8, svg, "id=\"glyph2\"") != null);
    try std.testing.expectError(error.NoImage, svg_hb.copyPng(run.glyph[0], .{ 16, 16 }, &encoded));
}

test "a complex-script sample renders through the adapter" {
    var hb: HarfBuzz = .init(deva, 0);
    defer hb.deinit();
    var cols: lcgf.shape.TestRun = .{};
    var run = cols.run();
    try hb.shape(sample, &run);

    const raster = lcgf.raster;
    const face = try lcgf.opentype.Face.parse(deva, 0);
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
