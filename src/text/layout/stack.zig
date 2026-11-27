//! The full text stack on the measure / wrap protocol (src/text/protocol.zig): shaping, line
//! breaking and placement for every run of `Texts`, at the two points the caller sequences.
//! Tier 0.
//!
//! `Stack` is to real fonts what `protocol.Mono` is to the fixed-advance one, and slots into
//! the same places of the frame (prototype/ui.zig `Frame.end`):
//!
//!   tree.seal(0);
//!   stack.measure(tx, strings, ascent);  // was font.measure(tx)
//!   layout.prepare(t); layout.applyText(t, tx, .x); layout.fit(t, .x); layout.resolve(t, .x, vw);
//!   layout.textAvail(t, tx);
//!   stack.wrap(tx, strings, ascent);     // was font.wrap(tx)
//!   layout.applyText(t, tx, .y); layout.fit(t, .y); layout.resolve(t, .y, vh);
//!   layout.place(t); layout.finalize(t); paint.emit(...);
//!
//! and, when drawing, `paragraph` lays run k out again exactly as `wrap` did (draw list run k
//! is texts row k), for glyph quads at the run's rect. Which runs it serves is the `font`
//! column: a run whose font has no shaper here is left alone for another font to measure.
//!
//! `ascent` is one row per run: the first line's baseline below the run's top, for
//! layout/baseline.zig `apply` to line rows of text up. Shaping is per run and reads its bytes,
//! like `shape.measure`: not a row pass, so it may skip rows.

const std = @import("std");
const shape = @import("../shape/shape.zig");
const lines = @import("lines.zig");
const Texts = @import("../../core/texts.zig").Texts;
const Strings = @import("../../core/strings.zig").Strings;
const whitespace = @import("whitespace.zig");
const fallback_ = @import("../fallback/fallback.zig");
const spans_ = @import("spans.zig");
const Direction = @import("../unicode/bidi.zig").Direction;
const metrics_ = @import("metrics.zig");
pub const emit = @import("emit.zig");
const protocol = @import("../protocol.zig");
const decorations_ = @import("decorations.zig");
const DrawList = @import("../../draw/draw_list.zig").DrawList;
const Rect = @import("../../core/types.zig").Rect;

/// Paragraph inputs, passed directly or in caller-owned rows. This is a capability input,
/// not a retained style object: changing one row affects the next measure/layout call.
pub const Paragraph = struct {
    pub const Alignment = enum { start, center, end, left, right, justify };
    pub const LineHeight = union(enum) { font, px: f32, multiple: f32 };
    alignment: Alignment = .start,
    last_align: Alignment = .start,
    direction: ?Direction = null,
    /// Null inherits the Texts.wrap flag at the wrap/draw steps. Explicit modes override it.
    wrap: ?lines.Flow.Wrap = null,
    whitespace: whitespace.Mode = .preserve,
    /// Stops are this many space advances apart, unless `tab_width` supplies logical pixels.
    tab_size: f32 = 8,
    tab_width: ?f32 = null,
    letter_spacing: f32 = 0,
    word_spacing: f32 = 0,
    line_height: LineHeight = .font,
    /// Fraction of explicit line-height leading placed above the baseline, 0..1.
    leading: f32 = 0.5,
    max_lines: u32 = std.math.maxInt(u32),
    /// The last visible line ends in U+2026 when it is cut. False clamps without a marker.
    ellipsis: bool = false,
    features: shape.Features = .{},
    /// Which measured line is reported to the native baseline-layout pass.
    baseline_source: metrics_.Source = .first,

    fn placement(p: Paragraph, width: f32, direction: Direction) lines.Align {
        const a = if (p.alignment == .justify) p.last_align else p.alignment;
        return .{
            .width = width,
            .factor = switch (a) {
                .center => 0.5,
                .end, .right => 1,
                else => 0,
            },
            .justify = p.alignment == .justify,
            .physical = a == .left or a == .right,
            .direction = p.direction orelse direction,
        };
    }

    fn metrics(p: Paragraph, m: lines.Metrics, px: f32) lines.Metrics {
        const target = switch (p.line_height) {
            .font => return m,
            .px => |v| v,
            .multiple => |v| v * px,
        };
        const leading = @max(target, 0) - m.ascent - m.descent;
        const above = std.math.clamp(p.leading, 0, 1);
        return .{ .ascent = m.ascent + leading * above, .descent = m.descent + leading * (1 - above) };
    }

    fn needsWidth(p: Paragraph) bool {
        return p.alignment != .start or p.wrap != null or p.ellipsis;
    }
};

/// Optional plain-paragraph fallback. Face indices in the chain index Stack.shapers. Metrics
/// scratch has one row per shaper; run columns fit the paragraph's font/script transitions.
pub const Fallback = struct {
    chain: *const fallback_.Chain,
    /// Row f, when present, is the chain of the runs whose font is f, used in place of
    /// `chain`: a monospace run tries its own face before the proportional one.
    by_font: []const fallback_.Chain = &.{},
    runs: fallback_.Runs,
    metrics: []lines.Metrics,
};

/// Optional rich paragraph row. Font choices are explicit in Spans; the plain-paragraph
/// fallback chain does not override them. Scratch metrics fit every span. When whitespace is
/// collapsed, normalized_spans is required to remap source boundaries without mutating input.
pub const Rich = struct {
    spans: *const spans_.Spans,
    metrics: []lines.Metrics,
    normalized_spans: ?*spans_.Spans = null,
};

/// Caller-owned rows for `Stack.style`: a paragraph and a rich row per text, spans for the
/// styled runs that have them (their span columns: every span plus one per run), and
/// metrics scratch for the longest span list (plus one).
pub const StyledRows = struct {
    paragraphs: []Paragraph,
    rich: []?Rich,
    spans: []spans_.Spans,
    start: []u32,
    font: []u16,
    px: []f32,
    color: []u32,
    metrics: []lines.Metrics,
};

/// Shapers by font index, and scratch for one paragraph. The caller owns all of it.
pub const Stack = struct {
    shapers: []const shape.Shaper,
    /// Optional persistent caller cache; direct uncached layout remains the default.
    cache: ?*@import("../shape/cache.zig").Cache = null,
    font_ids: []const u64 = &.{},
    font_generations: []const u64 = &.{},
    run: shape.Run,
    g: lines.Glyphs,
    l: lines.Lines,
    /// When set, lines are reordered for display (`lines.reorder`) after placing.
    bidi: ?lines.BidiScratch = null,
    /// The base direction of every paragraph (`lines.Align.direction`).
    direction: @import("../unicode/bidi.zig").Direction = .auto,
    /// A row overrides `default_paragraph`; absent rows use it. No registry or cache required.
    paragraphs: []const Paragraph = &.{},
    default_paragraph: Paragraph = .{},
    /// Required only for collapsing whitespace. The prepared text and source map are valid
    /// until this Stack lays out the next paragraph.
    normalization: ?whitespace.Buffer = null,
    fallback: ?Fallback = null,
    rich: []const ?Rich = &.{},
    /// Current paint/size tables, borrowed from the rich row when present. Plain paragraphs
    /// use TextRun.color and px. The metadata remains valid until the next paragraph call.
    paint_colors: []const u32 = &.{},
    span_px: []const f32 = &.{},
    px: f32 = 0,
    /// Text whose byte offsets the current Glyphs/Lines index, after optional normalization.
    text: []const u8 = "",
    normalized: bool = false,
    /// Marker to obtain from the atlas when `l.ellipsis` is nonzero.
    ellipsis_glyph: u16 = 0,
    ellipsis_font: u16 = 0,
    ellipsis_px: f32 = 0,
    /// A run did not fit the scratch: it was measured as empty. Reset by the caller.
    overflow: bool = false,

    /// Points the stack at the styled runs `s` (the description `MonoParagraphs` measures, as
    /// `spec.paragraph`, `spec.spans` and the markup lower to): each listed row's paragraph,
    /// and for a run with spans a rich row whose first span is the run's own style. Rows not
    /// listed take `default_paragraph`. Call after the tree is built and before `measure`;
    /// `rows` must outlive the frame's measure, wrap and drawing. NoSpace leaves the stack
    /// as it was.
    pub fn style(st: *Stack, tx: *const Texts, s: protocol.Styled, rows: StyledRows) error{NoSpace}!void {
        const n = tx.len;
        if (rows.paragraphs.len < n or rows.rich.len < n) return error.NoSpace;
        var need: usize = 0;
        var runs: usize = 0;
        var longest: usize = 0;
        for (s.styles) |i| if (s.spans.len > 0 and s.spans[i].len > 0) {
            need += s.spans[i].len + 1;
            runs += 1;
            longest = @max(longest, s.spans[i].len + 1);
        };
        if (runs > rows.spans.len or need > @min(rows.start.len, rows.font.len, rows.px.len, rows.color.len) or longest > rows.metrics.len) return error.NoSpace;
        @memset(rows.paragraphs[0..n], st.default_paragraph);
        @memset(rows.rich[0..n], null);
        var used: usize = 0;
        var r: usize = 0;
        for (s.rows, s.styles) |k, i| {
            rows.paragraphs[k] = s.table[i];
            const list = if (s.spans.len > 0) s.spans[i] else &.{};
            if (list.len == 0) continue;
            const lead: usize = @intFromBool(list[0].start != 0);
            const m = lead + list.len;
            var sp: spans_.Spans = .{ .start = rows.start[used..][0..m], .font = rows.font[used..][0..m], .px = rows.px[used..][0..m], .color = rows.color[used..][0..m] };
            if (lead == 1) _ = sp.push(0, tx.c.font[k], tx.c.px[k], tx.c.color[k]) catch unreachable;
            for (list) |x| _ = sp.push(x.start, @backingInt(x.style.font), x.style.px, x.style.color.bitsOf()) catch unreachable;
            rows.spans[r] = sp;
            rows.rich[k] = .{ .spans = &rows.spans[r], .metrics = rows.metrics };
            used += m;
            r += 1;
        }
        st.paragraphs = rows.paragraphs[0..n];
        st.rich = rows.rich[0..n];
    }

    /// After `paint.emit`: the decorations of `s`'s decorated runs as solid quads right after
    /// each run's text (`protocol.insertAfter`), each run laid out again as drawn
    /// (`paragraph`) and decorated by `text_decorations.quads` with its face's metrics.
    /// `rects` is scratch of at least the glyph rows. A run that does not fit is left bare.
    pub fn decorate(st: *Stack, tx: *const Texts, strings: *const Strings, s: protocol.Styled, d: *DrawList, rects: []Rect) void {
        if (s.decorations.len == 0 and s.spans.len == 0) return;
        var j: u32 = 0;
        while (j < d.op_len) : (j += 1) {
            if (d.op.kind[j] != @backingInt(DrawList.Kind.text)) continue;
            const k = d.op.ref[j];
            const at = std.mem.indexOfScalar(u32, s.rows, k) orelse continue;
            const row_style = s.styles[at];
            const list = if (s.spans.len > 0) s.spans[row_style] else &.{};
            const whole: decorations_.Style = if (s.decorations.len > 0) s.decorations[row_style] else .{};
            var any = lined(whole);
            for (list) |x| any = any or lined(x.decoration);
            if (!any or !st.serves(tx, k)) continue;
            st.paragraph(tx, strings, k) catch continue;
            const face = &st.shapers[tx.c.font[k]].face;
            const run = d.runs[k];
            const metrics: decorations_.Metrics = .of(face, run.px);
            const first = d.quad_len;
            const len: u32 = @intCast(st.text.len);
            // The paragraph's lines under all of it; a span's under its bytes (display
            // offsets when the stack collapsed white space).
            st.decorateRange(run, .{ 0, len }, whole, metrics, rects, d);
            for (list, 0..) |x, i| {
                const end = if (i + 1 < list.len) list[i + 1].start else len;
                st.decorateRange(run, .{ st.displayOf(x.start), st.displayOf(end) }, x.decoration, metrics, rects, d);
            }
            j += protocol.insertAfter(d, j, first);
        }
        @import("../../draw/paint.zig").encode(d);
    }

    fn lined(x: decorations_.Style) bool {
        return x.underline or x.overline or x.strike;
    }

    fn displayOf(st: *const Stack, source: u32) u32 {
        return if (st.normalized) st.normalization.?.displayOffset(source) else @min(source, @as(u32, @intCast(st.text.len)));
    }

    fn decorateRange(st: *Stack, run: @import("../../draw/draw_list.zig").TextRun, range: [2]u32, deco: decorations_.Style, metrics: decorations_.Metrics, rects: []Rect, d: *DrawList) void {
        if (!lined(deco) or range[0] >= range[1]) return;
        const room = d.quads[d.quad_len .. d.quads.len - 1];
        d.quad_len += decorations_.quads(run, &st.l, &st.g, st.text, range, deco, metrics, &.{}, rects, room) catch 0;
    }

    /// Whether this stack measures row `k`.
    pub fn serves(st: *const Stack, tx: *const Texts, k: usize) bool {
        if (k < st.rich.len) if (st.rich[k]) |r| {
            if (r.spans.len == 0) return false;
            for (r.spans.font[0..r.spans.len]) |font| if (font >= st.shapers.len) return false;
            return true;
        };
        return tx.c.font[k] < st.shapers.len;
    }

    /// Lays row `k` of `tx` out into the scratch (`g`, `l`), start aligned, broken at
    /// `width`: shaped with its font at its size, then `lines.breakLines`, `lines.place` and,
    /// with `bidi`, `lines.reorder`.
    pub fn layoutAt(st: *Stack, tx: *const Texts, strings: *const Strings, k: usize, width: f32) error{NoSpace}!void {
        return st.layoutRow(tx, strings, k, width, true);
    }

    fn options(st: *const Stack, k: usize) Paragraph {
        return if (k < st.paragraphs.len) st.paragraphs[k] else st.default_paragraph;
    }

    fn shapeRun(st: *Stack, font: u16, text: []const u8, features: shape.Features) error{NoSpace}!shape.Run {
        const shaper = &st.shapers[font];
        if (st.cache) |cache| return cache.shapeVersioned(shaper, .{
            .font = if (font < st.font_ids.len) st.font_ids[font] else font,
            .generation = if (font < st.font_generations.len) st.font_generations[font] else 0,
        }, text, features, &st.run);
        try shaper.shape(text, &st.run, features);
        return st.run;
    }

    fn layoutRow(st: *Stack, tx: *const Texts, strings: *const Strings, k: usize, width: f32, wraps: bool) error{NoSpace}!void {
        const c = &tx.c;
        const p = st.options(k);
        const rich = if (k < st.rich.len) st.rich[k] else null;
        const primary_font = if (rich) |r| r.spans.font[0] else c.font[k];
        const px = if (rich) |r| r.spans.px[0] else c.px[k];
        const sh = &st.shapers[primary_font];
        st.text = strings.get(.{ .start = c.start[k], .bytes = c.bytes[k] });
        st.normalized = p.whitespace != .preserve;
        if (st.normalized) {
            const b = if (st.normalization) |*b| b else return error.NoSpace;
            st.text = try b.prepare(st.text, p.whitespace);
        }
        const text = st.text;
        st.paint_colors = &.{};
        st.span_px = &.{};
        st.px = px;
        var features = p.features;
        // Optional ligatures suppress character spacing; disabling them exposes each
        // typographic character while mandatory script shaping remains the shaper's job.
        if (p.letter_spacing != 0) features.liga = false;
        st.g.len = 0;
        st.g.fonts = .{ .one = primary_font };
        const scale = px / @as(f32, @floatFromInt(sh.face.units_per_em));
        const primary = [_]lines.Metrics{p.metrics(.of(&sh.face, px), px)};
        var metrics: []const lines.Metrics = &primary;
        if (rich) |r| {
            var spans = r.spans;
            if (st.normalized) {
                const mapped = r.normalized_spans orelse return error.NoSpace;
                mapped.len = 0;
                for (0..spans.len) |i| _ = try mapped.push(st.normalization.?.displayOffset(spans.start[i]), spans.font[i], spans.px[i], spans.color[i]);
                spans = mapped;
            }
            if (r.metrics.len < spans.len) return error.NoSpace;
            try spans_.shapeCached(st.shapers, text, spans, &st.run, &st.g, features, st.cache, st.font_ids, st.font_generations);
            spans_.metrics(st.shapers, spans, r.metrics);
            for (r.metrics[0..spans.len], spans.px[0..spans.len]) |*m, size| m.* = p.metrics(m.*, size);
            metrics = r.metrics[0..spans.len];
            st.paint_colors = spans.color[0..spans.len];
            st.span_px = spans.px[0..spans.len];
        } else if (st.fallback) |*fb| {
            st.g.fonts = .indices;
            if (fb.metrics.len < st.shapers.len) return error.NoSpace;
            const own = primary_font < fb.by_font.len;
            const chain = if (own) &fb.by_font[primary_font] else fb.chain;
            try fallback_.resolveClusters(chain, text, &fb.runs);
            var start: u32 = 0;
            for (fb.runs.end[0..fb.runs.len], fb.runs.face[0..fb.runs.len]) |end, font| {
                const f = &st.shapers[font];
                const shaped = try st.shapeRun(font, text[start..end], features);
                try st.g.append(&shaped, px / @as(f32, @floatFromInt(f.face.units_per_em)), start, font);
                start = end;
            }
            for (st.shapers, 0..) |f, j| fb.metrics[j] = p.metrics(.of(&f.face, px), px);
            metrics = fb.metrics[0..st.shapers.len];
        } else {
            const shaped = try st.shapeRun(primary_font, text, features);
            try st.g.append(&shaped, scale, 0, 0);
        }
        lines.graphemeClusters(&st.g, text);
        if (p.letter_spacing != 0 or p.word_spacing != 0) lines.spacing(&st.g, text, p.letter_spacing, p.word_spacing);
        const space = @as(f32, @floatFromInt(sh.face.hMetrics(sh.face.cmap.glyph(' ')).advance)) * scale;
        try lines.breakFlow(&st.g, text, width, &st.l, .{
            .wrap = p.wrap orelse (if (wraps) .word else .none),
            .tab_width = @max(p.tab_width orelse (space * p.tab_size), 0),
        });
        const marker_line = @min(st.l.len, @max(p.max_lines, 1)) - 1;
        const marker_index = if (st.l.ink[marker_line] > st.l.first[marker_line]) st.l.ink[marker_line] - 1 else st.l.first[marker_line];
        st.ellipsis_font = if (marker_index < st.g.len) st.g.fontAt(marker_index) else primary_font;
        st.ellipsis_px = if (marker_index < st.g.len) st.pxAt(marker_index) else px;
        const marker_face = &st.shapers[st.ellipsis_font].face;
        st.ellipsis_glyph = marker_face.cmap.glyph(0x2026);
        if (p.ellipsis) {
            const advance = @as(f32, @floatFromInt(marker_face.hMetrics(st.ellipsis_glyph).advance)) * st.ellipsis_px / @as(f32, @floatFromInt(marker_face.units_per_em));
            lines.ellipsize(&st.l, &st.g, text, width, p.max_lines, advance);
        } else st.l.len = @min(st.l.len, @max(p.max_lines, 1));
        const a = p.placement(width, st.direction);
        lines.place(&st.l, &st.g, text, metrics, a);
        if (st.bidi) |s| try lines.reorder(&st.l, &st.g, text, a, s);
    }

    /// Row `k` laid out as `wrap` left it: broken at `avail` when it wraps, else not at all.
    /// For drawing run k of the draw list at its rect.
    pub fn paragraph(st: *Stack, tx: *const Texts, strings: *const Strings, k: usize) error{NoSpace}!void {
        return st.layoutRow(tx, strings, k, tx.c.avail[k], tx.c.wrap[k] > 0);
    }

    /// Maps a current layout/query byte offset back to the original text after collapse.
    pub fn sourceOffset(st: *const Stack, display: u32) u32 {
        return if (st.normalized) st.normalization.?.sourceOffset(display) else @min(display, @as(u32, @intCast(st.text.len)));
    }

    /// Actual pixel size for a glyph's font/atlas lookup, independent of metric-span identity.
    pub fn pxAt(st: *const Stack, glyph: usize) f32 {
        return if (st.span_px.len == 0) st.px else st.span_px[st.g.span[glyph]];
    }

    /// Run-aware rendering convenience over the same public emission pass and caller images.
    pub fn quads(st: *const Stack, run: @import("../../draw/draw_list.zig").TextRun, images: emit.Images, out: []@import("../../draw/draw_list.zig").Quad) emit.Error!u32 {
        var effective = images;
        if (effective.colors.len == 0) effective.colors = st.paint_colors;
        return emit.quads(run, &st.g, &st.l, st.text, effective, out);
    }

    /// Step 1 of the protocol: every run's extent unbroken (newlines still break): `w` the
    /// widest line, `h` the stacked lines, `ascent` the first baseline.
    pub fn measure(st: *Stack, tx: *Texts, strings: *const Strings, ascent: []f32) void {
        std.debug.assert(ascent.len >= tx.len);
        for (0..tx.len) |k| {
            if (!st.serves(tx, k)) continue;
            st.fill(tx, strings, k, std.math.inf(f32), ascent);
        }
    }

    /// Step 2: runs flagged `wrap` broken at `avail` (written by `layout.textAvail`); `w`, `h`
    /// and `ascent` rewritten. Other runs keep their measured extent.
    pub fn wrap(st: *Stack, tx: *Texts, strings: *const Strings, ascent: []f32) void {
        std.debug.assert(ascent.len >= tx.len);
        for (0..tx.len) |k| {
            if (!st.serves(tx, k) or (tx.c.wrap[k] == 0 and !st.options(k).needsWidth())) continue;
            st.fill(tx, strings, k, tx.c.avail[k], ascent);
        }
    }

    fn fill(st: *Stack, tx: *Texts, strings: *const Strings, k: usize, at: f32, ascent: []f32) void {
        st.layoutRow(tx, strings, k, at, tx.c.wrap[k] > 0) catch {
            st.overflow = true;
            tx.c.w[k] = 0;
            tx.c.h[k] = 0;
            ascent[k] = 0;
            return;
        };
        tx.c.w[k] = lines.widest(&st.l);
        tx.c.h[k] = lines.stackHeight(&st.l);
        ascent[k] = metrics_.baseline(&st.l, st.options(k).baseline_source);
    }
};

/// The width run `k` is broken at: `avail` when it wraps, else infinite.
pub fn breakWidth(tx: *const Texts, k: usize) f32 {
    return if (tx.c.wrap[k] > 0) tx.c.avail[k] else std.math.inf(f32);
}

// ---------------------------------------------------------------------------------------------

const testing = std.testing;
const golden = @import("golden.zig");

test "measure and wrap fill w, h and ascent of the runs in this stack's fonts" {
    const mem = @import("../../core/mem.zig");
    const shapers = [_]shape.Shaper{.init(try @import("../font/opentype.zig").Face.parse(golden.font, 0))};
    var buf: [16 * 1024]u8 align(mem.column_align) = undefined;
    var carver: mem.Carver = .{ .buf = &buf };
    var tx: Texts = .init(&carver, 4);
    var bytes: [128]u8 = undefined;
    var strings: Strings = .{ .buf = &bytes };
    const a = tx.push(0, strings.add("one two three"), &.{ .px = 20, .wrap = true });
    const b = tx.push(1, strings.add("one two three"), &.{ .px = 20 });
    const c = tx.push(2, strings.add("other font"), &.{ .px = 20, .font = @fromBackingInt(1) });
    const d = tx.push(3, strings.add("two\nlines"), &.{ .px = 20 });
    var p: golden.Para = .{};
    p.bind();
    var cols: golden.RunCols = .{};
    const cache_module = @import("../shape/cache.zig");
    var cache = cache_module.Cache.init(&carver, 4, 32);
    var generations = [_]u64{5};
    var st: Stack = .{ .shapers = &shapers, .cache = &cache, .font_ids = &.{100}, .font_generations = &generations, .run = cols.run(), .g = p.g, .l = p.l };
    var ascent: [4]f32 = @splat(-1);
    st.measure(&tx, &strings, &ascent);
    const m: lines.Metrics = .of(&shapers[0].face, 20);
    try testing.expectEqual(tx.c.w[a], tx.c.w[b]);
    try testing.expect(tx.c.w[a] > 100);
    try testing.expectEqual(m.height(), tx.c.h[a]);
    try testing.expectEqual(m.ascent, ascent[a]);
    try testing.expectEqual(0, tx.c.w[c]); // not this stack's font: untouched
    try testing.expectEqual(-1, ascent[c]);
    try testing.expectEqual(2 * m.height(), tx.c.h[d]);
    const cached_key = cache_module.Cache.keyVersioned("two\nlines", .{ .font = 100, .generation = 5 }, .{});
    try testing.expect(cache.get(cached_key) != null);
    @memset(st.run.glyph[0..st.run.len], 0);
    try st.paragraph(&tx, &strings, d);
    try testing.expect(st.g.glyph[0] != 0);
    try testing.expectEqual(@as(u16, 0), st.run.glyph[0]); // the cache hit did not reshape
    generations[0] += 1;
    try st.paragraph(&tx, &strings, d);
    try testing.expect(st.run.glyph[0] != 0); // changing the caller generation shapes again
    // The measured width fits exactly: wrapping at it changes nothing.
    const w = tx.c.w[a];
    tx.c.avail[a] = w;
    tx.c.avail[b] = 10;
    st.wrap(&tx, &strings, &ascent);
    try testing.expectEqual(w, tx.c.w[a]);
    try testing.expectEqual(m.height(), tx.c.h[a]);
    // Narrower: three lines; the run that does not wrap keeps its extent.
    tx.c.avail[a] = w / 2;
    st.wrap(&tx, &strings, &ascent);
    try testing.expectEqual(3 * m.height(), tx.c.h[a]);
    try testing.expect(tx.c.w[a] <= w / 2);
    try testing.expectEqual(w, tx.c.w[b]);
    try testing.expectEqual(m.height(), tx.c.h[b]);
    try testing.expect(!st.overflow);
    st.default_paragraph.baseline_source = .last;
    st.measure(&tx, &strings, &ascent);
    try testing.expectEqual(m.height() + m.ascent, ascent[d]);
}

test "golden: a frame measured, wrapped and painted through the stack matches the reference" {
    try golden.expectFrame();
}

test "paragraph rows drive normal measure wrap query and transformed glyph emission" {
    const mem = @import("../../core/mem.zig");
    const shapers = [_]shape.Shaper{.init(try @import("../font/opentype.zig").Face.parse(golden.font, 0))};
    var buf: [16 * 1024]u8 align(mem.column_align) = undefined;
    var carver: mem.Carver = .{ .buf = &buf };
    var tx: Texts = .init(&carver, 1);
    var bytes: [128]u8 = undefined;
    var strings: Strings = .{ .buf = &bytes };
    _ = tx.push(0, strings.add("  office  AV\tone two three  "), &.{ .px = 20, .wrap = true });
    var p: golden.Para = .{};
    p.bind();
    var cols: golden.RunCols = .{};
    var normalized: [128]u8 = undefined;
    var source: [129]u32 = undefined;
    const options = [_]Paragraph{.{
        .alignment = .center,
        .whitespace = .collapse,
        .letter_spacing = 1,
        .word_spacing = 2,
        .line_height = .{ .px = 30 },
        .max_lines = 2,
        .ellipsis = true,
    }};
    var st: Stack = .{
        .shapers = &shapers,
        .run = cols.run(),
        .g = p.g,
        .l = p.l,
        .paragraphs = &options,
        .normalization = .{ .bytes = &normalized, .source = &source },
    };
    var ascent: [1]f32 = undefined;
    st.measure(&tx, &strings, &ascent);
    try testing.expectEqualStrings("office AV one two three", st.text);
    try testing.expectEqual(3, st.sourceOffset(1));
    try testing.expectEqual(st.text.len, st.g.len); // optional ligatures disabled for spacing
    try testing.expectEqual(30, tx.c.h[0]);
    tx.c.avail[0] = 61;
    st.wrap(&tx, &strings, &ascent);
    try testing.expectEqual(60, tx.c.h[0]);
    try testing.expect(tx.c.w[0] <= 61 + lines.slack);
    const height = tx.c.h[0];
    try st.paragraph(&tx, &strings, 0);
    try testing.expectEqual(height, lines.stackHeight(&st.l));
    try testing.expect(st.l.ellipsis > 0);
    try testing.expect(st.l.x[0] >= 0 and st.l.x[0] < 61);
    const image: emit.Image = .{ .bounds = .{ 0, -10, 8, 0 }, .uv = .{ 0, 0, 1, 1 } };
    const images: [256]emit.Image = @splat(image);
    var out: [256]@import("../../draw/draw_list.zig").Quad = undefined;
    const n = try st.quads(.{
        .rect = .{ 0, 0, 61, height },
        .clip = .{ 0, 0, 100, 100 },
        .start = 0,
        .bytes = tx.c.bytes[0],
        .px = 20,
        .color = 0xffffffff,
        .font = 0,
        .xform = .{ 2, 0, 0, 2, 10, 20 },
        .clip_radii = .{ 4, 4, 4, 4 },
    }, .{ .glyphs = &images, .ellipsis = image }, &out);
    try testing.expect(n > 0);
    try testing.expectEqual([6]f32{ 2, 0, 0, 2, 10, 20 }, out[0].xform);
    try testing.expect(!st.overflow);
}

test "Stack fallback keeps a combining sequence in one face through shaping and line layout" {
    const mem = @import("../../core/mem.zig");
    const opentype = @import("../font/opentype.zig");
    const faces = [_]opentype.Face{ try .parse(fallback_.test_latin, 0), try .parse(golden.font, 0) };
    const shapers = [_]shape.Shaper{ .init(faces[0]), .init(faces[1]) };
    const chain: fallback_.Chain = .{ .faces = &faces, .default = &.{ 0, 1 } };
    var runs: fallback_.TestRuns = .{};
    var metrics: [2]lines.Metrics = undefined;
    var buf: [4096]u8 align(mem.column_align) = undefined;
    var carver: mem.Carver = .{ .buf = &buf };
    var tx: Texts = .init(&carver, 1);
    var bytes: [32]u8 = undefined;
    var strings: Strings = .{ .buf = &bytes };
    _ = tx.push(0, strings.add("Hi\u{301}!"), &.{ .px = 20 });
    var p: golden.Para = .{};
    p.bind();
    var cols: golden.RunCols = .{};
    var st: Stack = .{
        .shapers = &shapers,
        .run = cols.run(),
        .g = p.g,
        .l = p.l,
        .fallback = .{ .chain = &chain, .runs = runs.runs(), .metrics = &metrics },
    };
    var ascent: [1]f32 = undefined;
    st.measure(&tx, &strings, &ascent);
    try testing.expect(!st.overflow);
    try testing.expectEqualSlices(u32, &.{ 0, 1, 1, 1 }, st.g.span[0..st.g.len]);
    try testing.expectEqualSlices(u32, &.{ 0, 1, 1, 4 }, st.g.cluster[0..st.g.len]);
    for (st.g.glyph[0..st.g.len]) |g| try testing.expect(g != 0);
    for (0..st.g.len) |i| try testing.expectEqual(st.g.span[i], st.g.fontAt(i));
    try testing.expect(tx.c.w[0] > 0 and tx.c.h[0] > 0);
}

test "Stack fallback takes a run's own chain from by_font: its face first" {
    const mem = @import("../../core/mem.zig");
    const opentype = @import("../font/opentype.zig");
    // Both faces have 'H' and 'i': the chain decides which draws them.
    const faces = [_]opentype.Face{
        try .parse(fallback_.test_latin, 0),
        try .parse(golden.font, 0),
    };
    const shapers = [_]shape.Shaper{ .init(faces[0]), .init(faces[1]) };
    const chain: fallback_.Chain = .{ .faces = &faces, .default = &.{ 0, 1 } };
    const by_font = [_]fallback_.Chain{ chain, .{ .faces = &faces, .default = &.{ 1, 0 } } };
    var runs: fallback_.TestRuns = .{};
    var metrics: [2]lines.Metrics = undefined;
    var buf: [4096]u8 align(mem.column_align) = undefined;
    var carver: mem.Carver = .{ .buf = &buf };
    var tx: Texts = .init(&carver, 2);
    var bytes: [32]u8 = undefined;
    var strings: Strings = .{ .buf = &bytes };
    _ = tx.push(0, strings.add("Hi"), &.{ .px = 20 });
    _ = tx.push(1, strings.add("Hi"), &.{ .px = 20, .font = @fromBackingInt(1) });
    var p: golden.Para = .{};
    p.bind();
    var cols: golden.RunCols = .{};
    var st: Stack = .{
        .shapers = &shapers,
        .run = cols.run(),
        .g = p.g,
        .l = p.l,
        .fallback = .{
            .chain = &chain,
            .by_font = &by_font,
            .runs = runs.runs(),
            .metrics = &metrics,
        },
    };
    for ([_]u16{ 0, 1 }) |k| {
        try st.paragraph(&tx, &strings, k);
        try testing.expectEqual(2, st.g.len);
        for (0..st.g.len) |i| try testing.expectEqual(k, st.g.fontAt(i));
    }
}

test "a nonzero font row retains its actual face identity independently of metric span zero" {
    const mem = @import("../../core/mem.zig");
    const opentype = @import("../font/opentype.zig");
    const faces = [_]opentype.Face{ try .parse(fallback_.test_latin, 0), try .parse(golden.font, 0) };
    const shapers = [_]shape.Shaper{ .init(faces[0]), .init(faces[1]) };
    var buf: [4096]u8 align(mem.column_align) = undefined;
    var carver: mem.Carver = .{ .buf = &buf };
    var tx: Texts = .init(&carver, 1);
    var bytes: [16]u8 = undefined;
    var strings: Strings = .{ .buf = &bytes };
    _ = tx.push(0, strings.add("AV"), &.{ .px = 20, .font = @fromBackingInt(1) });
    var p: golden.Para = .{};
    p.bind();
    var cols: golden.RunCols = .{};
    var st: Stack = .{ .shapers = &shapers, .run = cols.run(), .g = p.g, .l = p.l };
    var ascent: [1]f32 = undefined;
    st.measure(&tx, &strings, &ascent);
    const wanted: lines.Metrics = .of(&faces[1], 20);
    try testing.expectEqual(wanted.ascent, ascent[0]);
    try testing.expectEqual(wanted.height(), tx.c.h[0]);
    try testing.expectEqual(0, faces[0].cmap.glyph('A'));
    try testing.expect(st.g.glyph[0] != 0);
    for (0..st.g.len) |i| {
        try testing.expectEqual(0, st.g.span[i]);
        try testing.expectEqual(1, st.g.fontAt(i));
    }
}

test "rich rows preserve shaping and expose per-glyph font size and inherited-opacity paint" {
    const mem = @import("../../core/mem.zig");
    const opentype = @import("../font/opentype.zig");
    const shapers = [_]shape.Shaper{ .init(try opentype.Face.parse(fallback_.test_latin, 0)), .init(try opentype.Face.parse(golden.font, 0)) };
    var buf: [8192]u8 align(mem.column_align) = undefined;
    var carver: mem.Carver = .{ .buf = &buf };
    var tx: Texts = .init(&carver, 1);
    var bytes: [32]u8 = undefined;
    var strings: Strings = .{ .buf = &bytes };
    _ = tx.push(0, strings.add("office BIG"), &.{ .px = 10, .wrap = true });
    var p: golden.Para = .{};
    p.bind();
    const Color = @import("../../core/types.zig").Color;
    _ = try p.s.push(0, 1, 16, Color.rgba(255, 0, 0, 255).bitsOf());
    _ = try p.s.push(2, 1, 16, Color.rgba(0, 0, 255, 255).bitsOf());
    _ = try p.s.push(7, 1, 24, Color.rgba(0, 255, 0, 255).bitsOf());
    var metrics: [3]lines.Metrics = undefined;
    const rich = [_]?Rich{.{ .spans = &p.s, .metrics = &metrics }};
    var cols: golden.RunCols = .{};
    var st: Stack = .{ .shapers = &shapers, .run = cols.run(), .g = p.g, .l = p.l, .rich = &rich };
    var ascent: [1]f32 = undefined;
    st.measure(&tx, &strings, &ascent);
    try testing.expect(!st.overflow and st.g.len < st.text.len);
    tx.c.avail[0] = 200;
    st.wrap(&tx, &strings, &ascent);
    try st.paragraph(&tx, &strings, 0);
    for (0..st.g.len) |i| try testing.expectEqual(1, st.g.fontAt(i));
    try testing.expectEqual(16, st.pxAt(0));
    try testing.expectEqual(24, st.pxAt(st.g.len - 1));
    const image: emit.Image = .{ .bounds = .{ 0, -10, 8, 0 } };
    const images: [256]emit.Image = @splat(image);
    var out: [256]@import("../../draw/draw_list.zig").Quad = undefined;
    const n = try st.quads(.{
        .rect = .{ 0, 0, 200, 100 },
        .clip = .{ 0, 0, 200, 100 },
        .start = 0,
        .bytes = 10,
        .px = 10,
        .font = 0,
        .color = Color.rgba(255, 255, 255, 128).bitsOf(),
        .opacity = 0.5,
    }, .{ .glyphs = &images }, &out);
    try testing.expectEqual(Color.rgba(255, 0, 0, 128).bitsOf(), out[0].fill);
    try testing.expectEqual(Color.rgba(0, 255, 0, 128).bitsOf(), out[n - 1].fill);
}
