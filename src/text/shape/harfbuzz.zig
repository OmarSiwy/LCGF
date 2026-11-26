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
const color_paint = @import("harfbuzz_paint.zig");
pub const PaintOptions = color_paint.Options;
pub const PaintScratch = color_paint.Scratch;
pub const PaintColorStop = color_paint.ColorStop;

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
extern fn hb_face_get_upem(face: *hb_face_t) c_uint;
extern fn hb_face_reference_table(face: *hb_face_t, tag: u32) *hb_blob_t;
extern fn hb_font_create(face: *hb_face_t) *hb_font_t;
extern fn hb_font_destroy(font: *hb_font_t) void;
extern fn hb_font_set_ppem(font: *hb_font_t, x: c_uint, y: c_uint) void;
extern fn hb_font_get_ppem(font: *hb_font_t, x: *c_uint, y: *c_uint) void;
extern fn hb_font_set_synthetic_bold(font: *hb_font_t, x: f32, y: f32, in_place: c_int) void;
extern fn hb_font_set_synthetic_slant(font: *hb_font_t, slant: f32) void;
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
/// Explicit fallback styling for an outline face. Bold strengths are fractions of em;
/// slant is horizontal displacement per vertical em (0.2 means a 20% skew). A real selected
/// bold/italic face remains the caller's first choice. SVG/bitmap artwork is not synthesized.
pub const Synthesis = struct {
    bold: [2]f32 = .{ 0, 0 },
    slant: f32 = 0,
    /// Retains advances while thickening outlines, useful for an explicit grade policy.
    in_place: bool = false,

    pub fn validate(value: Synthesis) error{NonFinite}!void {
        if (!std.math.isFinite(value.bold[0]) or !std.math.isFinite(value.bold[1]) or !std.math.isFinite(value.slant)) return error.NonFinite;
    }
};
pub const SvgOptions = struct {
    px: f32,
    /// Baseline origin in output pixels. SVG font coordinates have positive y downwards.
    origin: [2]f32 = .{ 0, 0 },
    foreground: lcgf.types.Color = .black,
    /// Null ignores font palette entries, retaining var() fallbacks/currentColor.
    palette: ?u32 = 0,
};
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
    /// Complete synthesis state for this call. Defaults reset earlier bold/slant settings.
    synthesis: Synthesis = .{},
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
    /// Optional COLRv1 callbacks, created only by rasterPaint.
    painter: ?*color_paint.Functions = null,

    pub fn init(data: []const u8, index: u32) HarfBuzz {
        const blob = hb_blob_create(data.ptr, @intCast(data.len), hb_memory_mode_readonly, null, null);
        const face = hb_face_create(blob, index);
        return .{ .blob = blob, .face = face, .font = hb_font_create(face), .buf = hb_buffer_create() };
    }

    pub fn deinit(hb: *HarfBuzz) void {
        if (hb.draw) |draw| hb_draw_funcs_destroy(draw);
        if (hb.painter) |painter| color_paint.destroy(painter);
        hb_buffer_destroy(hb.buf);
        hb_font_destroy(hb.font);
        hb_face_destroy(hb.face);
        hb_blob_destroy(hb.blob);
    }

    /// Shapes `text` (one run: direction, script and language guessed from the text, as
    /// `hb_buffer_guess_segment_properties` does) into `run`, glyphs in visual order with
    /// clusters as byte offsets into `text`. `error.NoSpace` when the run's columns are short.
    pub fn shape(hb: *HarfBuzz, text: []const u8, run: *Run) error{NoSpace}!void {
        hb.shapeBuffer(text, .{}, 0);
        try hb.copyRun(run);
    }

    /// Explicit script/language/direction, feature ranges and variable axes. This remains an
    /// optional allocating host adapter: its output is the same caller-owned glyph rows.
    pub fn shapeOptions(hb: *HarfBuzz, text: []const u8, run: *Run, options: Options) error{ NoSpace, NonFinite }!void {
        try options.synthesis.validate();
        hb.shapeBuffer(text, options, @backingInt(options.direction));
        try hb.copyRun(run);
    }

    /// Includes every current shaping option plus caller font identity/generation. Feature
    /// and variation ordering remains significant (equivalent descriptions may miss, never
    /// falsely hit). Run output is in font units; rendering at another px does not reshape.
    pub fn cacheKey(text: []const u8, identity: lcgf.shape_cache.Identity, options: Options) u64 {
        var hash: std.hash.Wyhash = .init(0x4842466561747572);
        const values = [10]u64{ @intCast(@backingInt(options.direction)), options.script orelse 0, @intCast(@backingInt(options.cluster_level)), options.language.len, options.features.len, options.variations.len, @as(u32, @bitCast(options.synthesis.bold[0])), @as(u32, @bitCast(options.synthesis.bold[1])), @as(u32, @bitCast(options.synthesis.slant)), @intFromBool(options.synthesis.in_place) };
        hash.update(std.mem.asBytes(&values));
        hash.update(options.language);
        hash.update(std.mem.sliceAsBytes(options.features));
        hash.update(std.mem.sliceAsBytes(options.variations));
        return lcgf.shape_cache.Cache.keyContext(text, .{ .identity = identity, .engine = 130201, .configuration = hash.final() });
    }

    /// Optional cache convenience over shapeOptions + public Cache.get/put. Cache storage
    /// stays caller-owned, and long runs still shape directly into the supplied scratch.
    pub fn shapeCached(hb: *HarfBuzz, cache: *lcgf.shape_cache.Cache, identity: lcgf.shape_cache.Identity, text: []const u8, options: Options, scratch: *Run) error{ NoSpace, NonFinite }!Run {
        try options.synthesis.validate();
        const key = cacheKey(text, identity, options);
        if (cache.get(key)) |hit| {
            hb_font_set_variations(hb.font, if (options.variations.len == 0) null else options.variations.ptr, @intCast(options.variations.len));
            hb.applySynthesis(options.synthesis);
            return hit;
        }
        try hb.shapeOptions(text, scratch, options);
        _ = cache.put(key, scratch);
        return scratch.*;
    }

    /// Real vertical shaping, including the font's vertical substitutions, origins and
    /// advances. Horizontal advances stay in Run.advance, vertical ones in caller y_advance;
    /// vertical_text.fromRun consumes both, so no advance component is silently discarded.
    pub fn shapeVertical(hb: *HarfBuzz, text: []const u8, run: *Run, y_advance: []i32, options: Options, direction: enum { top_to_bottom, bottom_to_top }) error{ NoSpace, NonFinite }!void {
        try options.synthesis.validate();
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
        hb.applySynthesis(options.synthesis);
        hb_shape(hb.font, hb.buf, if (options.features.len == 0) null else options.features.ptr, @intCast(options.features.len));
    }

    /// Fine-grained configuration for callers sequencing shaping and outline extraction.
    /// Each shape/shapeOptions call supplies a complete state again; no implicit synthesis
    /// policy is inferred from missing family faces or from their catalog metadata.
    pub fn setSynthesis(hb: *HarfBuzz, synthesis: Synthesis) error{NonFinite}!void {
        try synthesis.validate();
        hb.applySynthesis(synthesis);
    }

    fn applySynthesis(hb: *HarfBuzz, synthesis: Synthesis) void {
        hb_font_set_synthetic_bold(hb.font, synthesis.bold[0], synthesis.bold[1], @intFromBool(synthesis.in_place));
        hb_font_set_synthetic_slant(hb.font, synthesis.slant);
    }

    /// Explicit outline convenience for atlas generation without a preceding shape call.
    pub fn outlineStyled(hb: *HarfBuzz, glyph: u16, variations: []const Variation, synthesis: Synthesis, transform: [6]f32, path: *lcgf.paths.Path) error{ NoSpace, NoOutline, Unavailable, NonFinite }!void {
        try hb.setSynthesis(synthesis);
        try hb.outline(glyph, variations, transform, path);
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
    /// Synthetic outline settings are the current state set by shaping/setSynthesis;
    /// outlineStyled supplies them explicitly when building an atlas independently.
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
        var previous: [2]c_uint = undefined;
        hb_font_get_ppem(hb.font, &previous[0], &previous[1]);
        hb_font_set_ppem(hb.font, ppem[0], ppem[1]);
        defer hb_font_set_ppem(hb.font, previous[0], previous[1]);
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

    /// Decodes plain or gzip-compressed OpenType SVG into caller storage. The bounded SVG
    /// renderer reports unsupported visual features explicitly; the host can choose another
    /// renderer for those documents without silently losing their appearance.
    pub fn svgDocument(hb: *const HarfBuzz, glyph: u16, out: []u8) error{ NoSpace, NoImage, InvalidSvgCompression }![]const u8 {
        const blob = hb_ot_color_glyph_reference_svg(hb.face, glyph);
        defer hb_blob_destroy(blob);
        var count: c_uint = 0;
        const data = hb_blob_get_data(blob, &count) orelse return error.NoImage;
        if (count == 0) return error.NoImage;
        if (count >= 3 and std.mem.eql(u8, data[0..3], &.{ 0x1f, 0x8b, 0x08 })) {
            var input: std.Io.Reader = .fixed(data[0..count]);
            var gzip: std.compress.flate.Decompress = .init(&input, .gzip, &.{});
            var output: std.Io.Writer = .fixed(out);
            const n = gzip.reader.streamRemaining(&output) catch |err| return if (err == error.WriteFailed) error.NoSpace else error.InvalidSvgCompression;
            return out[0..n];
        }
        return copyBlob(blob, out);
    }

    /// Copies a selected CPAL palette into the renderer's explicit RGBA color space.
    pub fn paletteColors(hb: *const HarfBuzz, palette: u32, out: []lcgf.color_math.Rgba) error{ InvalidPalette, NoSpace }![]const lcgf.color_math.Rgba {
        if (palette >= hb_ot_color_palette_get_count(hb.face)) return error.InvalidPalette;
        const count = hb_ot_color_palette_get_colors(hb.face, palette, 0, null, null);
        if (out.len < count) return error.NoSpace;
        for (out[0..count], 0..) |*color, i| {
            var n: c_uint = 1;
            var value: [1]u32 = undefined;
            _ = hb_ot_color_palette_get_colors(hb.face, palette, @intCast(i), &n, &value);
            if (n != 1) return error.InvalidPalette;
            color.* = lcgf.color_math.fromColor(.rgba(@truncate(value[0] >> 8), @truncate(value[0] >> 16), @truncate(value[0] >> 24), @truncate(value[0])));
        }
        return out[0..count];
    }

    /// Connected static OpenType SVG subset: plain/gzip document -> detached glyphN ->
    /// paths/gradients -> premultiplied surface. The unclipped em viewport and baseline agree
    /// with OpenType's SVG coordinate rules. Unsupported SVG features return the parser's
    /// explicit profile error; this is not a claim of complete SVG/CSS/filter conformance.
    pub fn rasterSvg(hb: *const HarfBuzz, glyph: u16, options: SvgOptions, destination: lcgf.surface.Surface, document_storage: []u8, palette_storage: []lcgf.color_math.Rgba, buffers: lcgf.svg.Buffers) !void {
        try destination.validate();
        if (!std.math.isFinite(options.px) or options.px <= 0 or !std.math.isFinite(options.origin[0]) or !std.math.isFinite(options.origin[1])) return error.InvalidGeometry;
        const upem = hb_face_get_upem(hb.face);
        if (upem == 0) return error.InvalidGeometry;
        const document = try hb.svgDocument(glyph, document_storage);
        const colors: []const lcgf.color_math.Rgba = if (options.palette != null and hb_ot_color_palette_get_count(hb.face) > 0) try hb.paletteColors(options.palette.?, palette_storage) else &.{};
        var id_storage: [16]u8 = undefined;
        const id = try std.fmt.bufPrint(&id_storage, "glyph{d}", .{glyph});
        const em: f32 = @floatFromInt(upem);
        const scale = options.px / em;
        try lcgf.surface.clear(destination, @splat(0));
        errdefer lcgf.surface.clear(destination, @splat(0)) catch {};
        try lcgf.svg.paint(document, destination, .{
            .viewport = .{ .x0 = 0, .y0 = 0, .x1 = em, .y1 = em },
            .initial_transform = .{ scale, 0, 0, scale, options.origin[0], options.origin[1] },
            .clip_viewport = false,
            .fragment_ancestors = false,
            .use_intrinsic_size = true,
            .fragment = id,
            .palette = colors,
            .current_color = lcgf.color_math.fromColor(options.foreground),
        }, buffers);
    }

    /// Renders COLRv1 solid/linear/two-circle/sweep paints, nested affine transforms, glyph
    /// and rectangle clips, all OpenType composite/blend modes and palette overrides through
    /// LCGF's shared CPU brushes/compositor. The selected variable instance applies to both
    /// the paint graph and its outlines. Short stacks/storage return an error and clear output.
    pub fn rasterPaint(hb: *HarfBuzz, glyph: u16, variations: []const Variation, options: PaintOptions, destination: lcgf.surface.Surface, scratch: PaintScratch) !void {
        if (hb_ot_color_glyph_has_paint(hb.face, glyph) == 0) return error.NoPaint;
        if (options.palette >= hb_ot_color_palette_get_count(hb.face)) return error.InvalidPalette;
        hb_font_set_variations(hb.font, if (variations.len == 0) null else variations.ptr, @intCast(variations.len));
        try color_paint.raster(hb, glyph, variations, options, destination, scratch);
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

test "optional HarfBuzz cache separates variable instances features language and font generations" {
    var hb: HarfBuzz = .init(@embedFile("testdata/variable.ttf"), 0);
    defer hb.deinit();
    var bytes: [8192]u8 align(lcgf.mem.column_align) = undefined;
    var carver: lcgf.mem.Carver = .{ .buf = &bytes };
    var cache = lcgf.shape_cache.Cache.init(&carver, 4, 16);
    var columns: lcgf.shape.TestRun = .{};
    var scratch = columns.run();
    const identity: lcgf.shape_cache.Identity = .{ .font = 77, .generation = 2 };
    const heavy: Options = .{ .variations = &.{.{ .tag = lcgf.opentype.tag("wght"), .value = 900 }} };
    const normal = try hb.shapeCached(&cache, identity, "A", .{}, &scratch);
    try std.testing.expectEqual(@as(i32, 500), normal.advance[0]);
    const bold = try hb.shapeCached(&cache, identity, "A", heavy, &scratch);
    try std.testing.expectEqual(@as(i32, 900), bold.advance[0]);
    const again = try hb.shapeCached(&cache, identity, "A", .{}, &scratch);
    try std.testing.expectEqual(@as(i32, 500), again.advance[0]);
    const base = HarfBuzz.cacheKey("A", identity, .{});
    try std.testing.expect(base != HarfBuzz.cacheKey("A", identity, heavy));
    try std.testing.expect(base != HarfBuzz.cacheKey("A", identity, .{ .language = "tr" }));
    try std.testing.expect(base != HarfBuzz.cacheKey("A", identity, .{ .features = &.{.{ .tag = lcgf.opentype.tag("kern"), .value = 0 }} }));
    try std.testing.expect(base != HarfBuzz.cacheKey("A", identity, .{ .synthesis = .{ .bold = .{ 0.05, 0 } } }));
    try std.testing.expect(base != HarfBuzz.cacheKey("A", identity, .{ .synthesis = .{ .slant = 0.2 } }));
    try std.testing.expect(HarfBuzz.cacheKey("A", identity, .{ .synthesis = .{ .bold = .{ 0.05, 0 } } }) != HarfBuzz.cacheKey("A", identity, .{ .synthesis = .{ .bold = .{ 0.05, 0 }, .in_place = true } }));
    try std.testing.expect(base != HarfBuzz.cacheKey("A", .{ .font = 77, .generation = 3 }, .{}));
}

test "explicit synthesis changes real outline coverage and matching advances with default reset" {
    var hb: HarfBuzz = .init(@embedFile("testdata/variable.ttf"), 0);
    defer hb.deinit();
    var columns: lcgf.shape.TestRun = .{};
    var run = columns.run();
    var buffers: lcgf.paths.TestBuffers(32, 256) = .{};
    var path = buffers.path();
    var poly = buffers.polyline();
    var acc: [8192]f32 = undefined;
    var coverage: [8192]u8 = undefined;
    var previous_ink: usize = 0;
    const bold: Synthesis = .{ .bold = .{ 0.05, 0 } };
    for ([_]Synthesis{ .{}, bold }, [_]i32{ 500, 550 }) |synthesis, advance| {
        try hb.shapeOptions("A", &run, .{ .synthesis = synthesis });
        try std.testing.expectEqual(advance, run.advance[0]);
        try hb.outline(run.glyph[0], &.{}, .{ 0.1, 0, 0, -0.1, 0, 80 }, &path);
        lcgf.paths.flatten(&path, 0.1, &poly);
        const box = lcgf.paths.bounds(&poly);
        lcgf.paths.fill(&poly, box, .nonzero, buffers.scratch(), &acc);
        lcgf.raster.coverage(&acc, &coverage, @as(usize, box.w) * box.h);
        var ink: usize = 0;
        for (coverage[0 .. @as(usize, box.w) * box.h]) |value| ink += value;
        try std.testing.expect(ink > previous_ink);
        previous_ink = ink;
    }
    try hb.shapeOptions("A", &run, .{ .synthesis = .{ .bold = bold.bold, .in_place = true } });
    try std.testing.expectEqual(@as(i32, 500), run.advance[0]);
    try hb.outlineStyled(run.glyph[0], &.{}, .{ .slant = 0.2 }, .{ 0.1, 0, 0, -0.1, 0, 80 }, &path);
    lcgf.paths.flatten(&path, 0.1, &poly);
    try std.testing.expect(lcgf.paths.bounds(&poly).w > 40);
    try hb.shape("A", &run);
    try std.testing.expectEqual(@as(i32, 500), run.advance[0]);
    try hb.outline(run.glyph[0], &.{}, .{ 0.1, 0, 0, -0.1, 0, 80 }, &path);
    lcgf.paths.flatten(&path, 0.1, &poly);
    try std.testing.expectEqual(@as(u32, 40), lcgf.paths.bounds(&poly).w);
    try std.testing.expectError(error.NonFinite, hb.setSynthesis(.{ .slant = std.math.nan(f32) }));
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
    var retained_ppem: [2]c_uint = undefined;
    hb_font_get_ppem(hb.font, &retained_ppem[0], &retained_ppem[1]);
    try std.testing.expectEqual([2]c_uint{ 0, 0 }, retained_ppem);
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

test "COLRv1 callbacks render real gradients groups transforms palette overrides and bounded failures" {
    var hb: HarfBuzz = .init(@embedFile("testdata/color-paint.ttf"), 0);
    defer hb.deinit();
    try std.testing.expect(hb.formats().colr_paint);
    var glyph_cols: lcgf.shape.TestRun = .{};
    var run = glyph_cols.run();
    try hb.shape("ABCDEFGH", &run);
    try std.testing.expectEqual(8, run.len);
    var path_buffers: lcgf.paths.TestBuffers(64, 512) = .{};
    var path = path_buffers.path();
    var poly = path_buffers.polyline();
    var accumulator: [60 * 90 + 32]f32 = undefined;
    var coverage: [60 * 90 + 32]u8 = undefined;
    var pixels: [80 * 90]u32 = undefined;
    const destination = try lcgf.surface.init(&pixels, 60, 90);
    var group_pixels: [3][80 * 90]u32 = undefined;
    var groups: [3]lcgf.surface.Surface = undefined;
    for (&groups, &group_pixels) |*group, *storage| group.* = try lcgf.surface.init(storage, 60, 90);
    var clips: [8 * 80 * 90]u8 = undefined;
    var transforms: [16][6]f32 = undefined;
    var group_clips: [3]usize = undefined;
    var stops: [8]PaintColorStop = undefined;
    var brush_stops: [8]lcgf.brushes.Stop = undefined;
    var segments: [8]lcgf.brushes.Segment = undefined;
    const scratch: PaintScratch = .{ .path = &path, .poly = &poly, .scan = path_buffers.scratch(), .acc = &accumulator, .coverage = &coverage, .clips = &clips, .transforms = &transforms, .groups = &groups, .group_clips = &group_clips, .stops = &stops, .brush_stops = &brush_stops, .segments = &segments };
    const options: PaintOptions = .{ .transform = .{ 0.1, 0, 0, -0.1, 0, 80 } };
    try hb.rasterPaint(run.glyph[0], &.{}, options, destination, scratch);
    const gradient: lcgf.types.Color = @bitCast(destination.pixels[20 * destination.stride + 10]);
    try std.testing.expect(gradient.r >= 180 and gradient.r <= 190 and gradient.b >= 65 and gradient.b <= 75 and gradient.a == 255);
    try std.testing.expectEqual(lcgf.types.Color.rgba(0, 0, 255, 255).bitsOf(), destination.pixels[20 * destination.stride + 35]);
    const reference = destination.pixels[20 * destination.stride + 10];
    try hb.rasterPaint(run.glyph[5], &.{}, options, destination, scratch);
    try std.testing.expectEqual(reference, destination.pixels[20 * destination.stride + 10]); // PaintColrGlyph traversal
    try hb.rasterPaint(run.glyph[1], &.{}, options, destination, scratch);
    // Pinned HarfBuzz COLR get_color feeds 255 * .5 through HB_COLOR/HB_TAG u8,
    // truncating to 127 before our premultiplied compositor sees the source.
    const composite: lcgf.types.Color = @bitCast(destination.pixels[20 * destination.stride + 10]);
    try std.testing.expectEqual(@as(u8, 127), composite.r);
    try std.testing.expectEqual(@as(u8, 127), composite.a);
    try std.testing.expectEqual(@as(u32, 0), destination.pixels[20 * destination.stride + 35]);
    try hb.rasterPaint(run.glyph[2], &.{}, options, destination, scratch);
    const radial_center: lcgf.types.Color = @bitCast(destination.pixels[44 * destination.stride + 25]);
    try std.testing.expect(radial_center.r > 240 and radial_center.b < 15);
    try hb.rasterPaint(run.glyph[3], &.{}, options, destination, scratch);
    const sweep_right: lcgf.types.Color = @bitCast(destination.pixels[44 * destination.stride + 35]);
    const sweep_left: lcgf.types.Color = @bitCast(destination.pixels[44 * destination.stride + 15]);
    try std.testing.expect(sweep_right.r > 245 and sweep_right.b < 10);
    try std.testing.expect(sweep_left.r > 120 and sweep_left.r < 140 and sweep_left.b > 120 and sweep_left.b < 140);
    var changed = options;
    changed.palette = 1;
    try hb.rasterPaint(run.glyph[4], &.{}, changed, destination, scratch);
    try std.testing.expectEqual(@as(u32, 0), destination.pixels[20 * destination.stride + 10]);
    try std.testing.expectEqual(lcgf.types.Color.rgba(0, 255, 0, 255).bitsOf(), destination.pixels[20 * destination.stride + 20]);
    changed = options;
    changed.palette_overrides = &.{.{ .index = 0, .color = .rgba(255, 128, 0, 255) }};
    try hb.rasterPaint(run.glyph[4], &.{}, changed, destination, scratch);
    try std.testing.expectEqual(lcgf.types.Color.rgba(255, 128, 0, 255).bitsOf(), destination.pixels[20 * destination.stride + 20]);
    changed = options;
    changed.foreground = .rgba(0, 255, 0, 255);
    try hb.rasterPaint(run.glyph[6], &.{}, changed, destination, scratch);
    try std.testing.expectEqual(lcgf.types.Color.rgba(0, 127, 0, 127).bitsOf(), destination.pixels[20 * destination.stride + 20]);
    try hb.rasterPaint(run.glyph[7], &.{}, options, destination, scratch);
    for (destination.pixels) |pixel| try std.testing.expectEqual(@as(u32, 0), pixel);
    var short = scratch;
    short.transforms = transforms[0..1];
    try std.testing.expectError(error.NoSpace, hb.rasterPaint(run.glyph[4], &.{}, options, destination, short));
    for (destination.pixels) |pixel| try std.testing.expectEqual(@as(u32, 0), pixel);
    changed = options;
    changed.max_operations = 1;
    try std.testing.expectError(error.LimitExceeded, hb.rasterPaint(run.glyph[0], &.{}, changed, destination, scratch));
}

test "plain and gzip SVG font glyphs render detached at the true baseline with palette fallback" {
    var bytes: [1024]u8 = undefined;
    var palette: [4]lcgf.color_math.Rgba = undefined;
    var path_storage: lcgf.paths.TestBuffers(64, 256) = .{};
    var work_storage: lcgf.paths.TestBuffers(64, 256) = .{};
    var outline_storage: lcgf.paths.TestBuffers(64, 256) = .{};
    var path = path_storage.path();
    var center = path_storage.polyline();
    var work = work_storage.polyline();
    var outline = outline_storage.polyline();
    var acc: [16384]f32 = undefined;
    var coverage: [16384]u8 = undefined;
    var gradients: [4]lcgf.svg.Gradient = undefined;
    var stops: [8]lcgf.brushes.Stop = undefined;
    var segments: [8]lcgf.brushes.Segment = undefined;
    var stack: [16]lcgf.svg.Frame = undefined;
    var dashes: [8]f32 = undefined;
    var clips: [1]lcgf.decoration.Clip = undefined;
    var pixels: [80 * 90]u32 = undefined;
    const destination = try lcgf.surface.init(&pixels, 60, 90);
    var layer_pixels: [80 * 90]u32 = undefined;
    var layers = [_]lcgf.surface.Surface{try lcgf.surface.init(&layer_pixels, 60, 90)};
    const buffers: lcgf.svg.Buffers = .{ .path = &path, .centerline = &center, .work = &work, .outline = &outline, .fill = path_storage.scratch(), .accumulator = &acc, .coverage = &coverage, .gradients = &gradients, .stops = &stops, .segments = &segments, .stack = &stack, .layers = &layers, .dashes = &dashes, .clips = &clips };
    inline for (.{ @embedFile("testdata/color-svg.ttf"), @embedFile("testdata/color-svg-gzip.ttf"), @embedFile("testdata/color-svg-palette.ttf") }, 0..) |data, i| {
        var hb: HarfBuzz = .init(data, 0);
        defer hb.deinit();
        var glyph_columns: lcgf.shape.TestRun = .{};
        var run = glyph_columns.run();
        try hb.shape("A", &run);
        const document = try hb.svgDocument(run.glyph[0], &bytes);
        try std.testing.expect(std.mem.startsWith(u8, document, "<svg"));
        try std.testing.expectError(error.NoSpace, hb.svgDocument(run.glyph[0], bytes[0..4]));
        try hb.rasterSvg(run.glyph[0], .{ .px = 100, .origin = .{ 0, 80 } }, destination, &bytes, &palette, buffers);
        const expected = if (i == 2) lcgf.types.Color.rgba(0, 128, 0, 128) else lcgf.types.Color.rgba(255, 128, 0, 255);
        try std.testing.expectEqual(expected.bitsOf(), destination.pixels[20 * destination.stride + 10]);
        try std.testing.expectEqual(@as(u32, 0), destination.pixels[5 * destination.stride + 10]);
        try std.testing.expectEqual(@as(u32, 0), destination.pixels[20 * destination.stride + 50]);
        if (i == 2) {
            try hb.rasterSvg(run.glyph[0], .{ .px = 100, .origin = .{ 0, 80 }, .palette = null }, destination, &bytes, &palette, buffers);
            try std.testing.expectEqual(lcgf.types.Color.rgba(255, 128, 0, 255).bitsOf(), destination.pixels[20 * destination.stride + 10]);
        }
    }
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
