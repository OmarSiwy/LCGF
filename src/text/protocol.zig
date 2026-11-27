//! The measure / wrap protocol: how text extents reach layout. Data, not callbacks.
//!
//! The core never calls into a font. There is no `measure(node)` hook, no shaper interface and
//! no re-measure loop that layout drives. Text is a side list (`Texts`), and a font is anything
//! that reads its columns and writes others back, at two points the caller sequences:
//!
//! 1. Measure. After the tree is built and before layout, the caller fills `Texts.w` and
//!    `Texts.h` for every run, from `start`/`bytes` (the run's bytes in `Strings`), `px` and
//!    `font`. This is the single-line extent.
//! 2. Wrap. After widths are resolved, layout writes `Texts.avail` (the width it gave each run).
//!    For runs whose `wrap` is 1.0 the caller may then rewrite `w` and `h`; layout reads them for
//!    the vertical axis. Runs that do not wrap keep their measured extent.
//!
//! Why data: a callback per run is an indirect call per row, hides the loop from SIMD, and hands
//! control flow to the framework (Muratori, *Designing and Evaluating Reusable Components*:
//! flow control stays with the caller). Columns in and columns out let one font measure every
//! run in one vector loop, let a real shaper run on another thread or cache by string, and let
//! a test write the numbers by hand. Which font a run uses is a column (`font`), not a type, so
//! several fonts are several passes over the same rows, each masked by `font`.
//!
//! `Mono` below is the protocol for a fixed-advance font and the reference for plugging in a
//! real shaper. Ported from prototype/ui.zig ("fonts").

const std = @import("std");
const simd = @import("../core/simd.zig");
const mem = @import("../core/mem.zig");
const Texts = @import("../core/texts.zig").Texts;
const Strings = @import("../core/strings.zig").Strings;
const draw_list = @import("../draw/draw_list.zig");
const DrawList = draw_list.DrawList;
const Quad = draw_list.Quad;
const Paragraph = @import("layout/stack.zig").Paragraph;
const Decoration = @import("layout/decorations.zig").Style;
const paint = @import("../draw/paint.zig");
const types = @import("../core/types.zig");

const W = simd.lanes;

/// A fixed-advance font: every byte is `advance` ems wide, every line `line` ems tall.
pub const Mono = struct {
    /// Advance per byte, in ems.
    advance: f32 = 0.6,
    /// Line height, in ems.
    line: f32 = 1.25,

    /// Mono's glyph atlas: a 16 x 16 grid of cells indexed by byte.
    pub const atlas: Atlas = .{};

    /// The characters of the cells 0x80 to 0x9f in the bundled bitmap fonts
    /// (`render_sw_font`, the examples' atlas): Windows-1252's, with the infinity sign in 0x81.
    /// 0 is a byte with no character. The cells from 0xa0 on are the code points of the same
    /// number, and the ones below 0x80 are ASCII.
    pub const high_cells = [32]u21{
        0x20ac, 0x221e, 0x201a, 0x0192, 0x201e, 0x2026, 0x2020, 0x2021,
        0x02c6, 0x2030, 0x0160, 0x2039, 0x0152, 0,      0x017d, 0,
        0,      0x2018, 0x2019, 0x201c, 0x201d, 0x2022, 0x2013, 0x2014,
        0x02dc, 0x2122, 0x0161, 0x203a, 0x0153, 0,      0x017e, 0x0178,
    };

    /// UTF-8 `text` as the bytes that show it in the bundled bitmap fonts, one byte and one
    /// cell per character: ASCII as it is, a control character as a space, a character with a
    /// cell (`high_cells`, Latin-1) as that cell's byte, and any other character, or a byte
    /// that is not UTF-8, as '?'. `Mono` is a byte to a cell, so text with characters past
    /// ASCII goes through here before `Frame.text`; a shaper takes the UTF-8 itself. Returns
    /// the part of `out` written, cut at `out.len`.
    pub fn encode(text: []const u8, out: []u8) []u8 {
        var n: usize = 0;
        var i: usize = 0;
        // Ends at the end of `text` or of `out`: a turn takes at least one byte of `text`.
        while (i < text.len and n < out.len) : (n += 1) {
            const len: usize = std.unicode.utf8ByteSequenceLength(text[i]) catch 0;
            // Not the first byte of a character, or one cut short by the end of the text.
            if (len == 0 or i + len > text.len) {
                out[n] = '?';
                i += 1;
                continue;
            }
            const point: u21 = std.unicode.utf8Decode(text[i..][0..len]) catch 0xfffd;
            i += len;
            out[n] = cellOf(point);
        }
        return out[0..n];
    }

    /// The byte whose cell shows `point` in the bundled bitmap fonts, or '?'.
    pub fn cellOf(point: u21) u8 {
        if (point < ' ' or point == 0x7f) return ' ';
        if (point < 0x7f) return @intCast(point);
        if (point >= 0xa0 and point <= 0xff) return @intCast(point);
        for (high_cells, 0x80..) |high, byte| {
            if (high == point) return @intCast(byte);
        }
        return '?';
    }

    /// SIMD. Single-line extent of every run. Reads `bytes`, `px`; writes `w`, `h`.
    /// Rows past `tx.len` up to the padding are written too; they are never read.
    pub fn measure(font: Mono, tx: *Texts) void {
        const c = &tx.c;
        const n = simd.padded(tx.len);
        var i: usize = 0;
        while (i < n) : (i += W) {
            const px = simd.loadF(c.px, i);
            const count: simd.F = @floatFromInt(simd.loadU(c.bytes, i));
            simd.storeF(c.w, i, count * px * simd.f(font.advance));
            simd.storeF(c.h, i, px * simd.f(font.line));
        }
    }

    /// SIMD. Re-flows runs flagged `wrap` into `avail` and rewrites their `w`, `h`. Runs after
    /// `measure` and `layout.textAvail`. A run that does not wrap keeps its measured `w` and `h`,
    /// so a font that serves only non-wrapping runs needs to run after `Mono` at measure only.
    pub fn wrap(font: Mono, tx: *Texts) void {
        const c = &tx.c;
        const n = simd.padded(tx.len);
        // Labels and controls commonly have no wrapping runs. One narrow-column
        // scan avoids divisions, rounding and writes across all the metric columns.
        // Read the padded rows as the pass below does: a stale wrapping flag there
        // can only disable this shortcut, never skip a live wrapping run.
        var any_wrap: simd.B = @splat(false);
        var at: usize = 0;
        while (at < n) : (at += W) any_wrap |= simd.loadF(c.wrap, at) > simd.f(0);
        if (!@reduce(.Or, any_wrap)) return;

        const one = simd.f(1);
        var i: usize = 0;
        while (i < n) : (i += W) {
            const px = simd.loadF(c.px, i);
            // The floor keeps a zero-size font from dividing by zero.
            const adv = @max(px * simd.f(font.advance), simd.f(1e-6));
            const count: simd.F = @floatFromInt(simd.loadU(c.bytes, i));
            const avail = simd.loadF(c.avail, i);
            const wraps = simd.loadF(c.wrap, i) > simd.f(0);
            const per_line = @max(@floor(avail / adv + simd.f(0.5)), one);
            const lines = @max(@ceil(count / per_line), one);
            const w = simd.loadF(c.w, i);
            simd.storeF(c.w, i, @select(f32, wraps, @min(w, avail), w));
            simd.storeF(c.h, i, @select(f32, wraps, lines * px * simd.f(font.line), simd.loadF(c.h, i)));
        }
    }

    /// Where glyph quads for run k landed in the output of `quads`.
    pub const Glyphs = struct { first: []u32, count: []u32 };

    /// Expands the draw list's text runs into glyph quads for a 16x16 byte-indexed atlas: byte b
    /// samples cell (b & 15, b >> 4). Bytes flow left to right and wrap at the run's width, the
    /// same way `wrap` counted lines. `glyphs` (at least `d.run_len` long) gets each run's slice
    /// of `out`. Returns the number of quads written; stops quietly when `out` is full (the last
    /// row is then overwritten in place, never past the end).
    pub fn quads(font: Mono, d: *const DrawList, out: []Quad, glyphs: Glyphs) u32 {
        return font.quadsFor(FullGrid, d, out, glyphs) catch unreachable;
    }

    /// The same metrics and geometry, with UVs from a static atlas subset.
    pub fn quadsFor(font: Mono, comptime Grid: type, d: *const DrawList, out: []Quad, glyphs: Glyphs) error{GlyphOutsideSubset}!u32 {
        std.debug.assert(out.len >= 1);
        var n: u32 = 0;
        for (0..d.run_len) |k| n = try font.appendRun(Grid, d, @intCast(k), out, glyphs, n);
        return n;
    }

    /// Expands only runs referenced by text commands. Run indices stay unchanged; a
    /// non-submitted run gets an empty span. Repeated commands share one expansion.
    /// The host still draws every submitted command in its original paint order.
    /// This avoids constructing geometry for offscreen runs retained in the side list.
    pub fn quadsForCommands(font: Mono, comptime Grid: type, d: *const DrawList, out: []Quad, glyphs: Glyphs) error{GlyphOutsideSubset}!u32 {
        std.debug.assert(out.len >= 1);
        std.debug.assert(glyphs.first.len >= d.run_len and glyphs.count.len >= d.run_len);
        @memset(glyphs.first[0..d.run_len], 0);
        @memset(glyphs.count[0..d.run_len], 0);
        var n: u32 = 0;
        for (0..d.cmd_len) |i| {
            if (d.cmd.kind[i] != @backingInt(DrawList.Kind.text)) continue;
            const k = d.cmd.first[i];
            // Empty/truncated repeated runs can be revisited, but emit no live quads.
            if (glyphs.count[k] != 0) continue;
            n = try font.appendRun(Grid, d, k, out, glyphs, n);
        }
        return n;
    }

    fn appendRun(font: Mono, comptime Grid: type, d: *const DrawList, k: u32, out: []Quad, glyphs: Glyphs, start: u32) error{GlyphOutsideSubset}!u32 {
        const r = d.runs[k];
        const adv = @max(r.px * font.advance, 1e-6);
        const line = r.px * font.line;
        const per_line: u32 = @intFromFloat(@min(@max(@floor((r.rect[2] - r.rect[0]) / adv + 0.5), 1), 1e6));
        const last: u32 = @intCast(out.len - 1);
        var n = start;
        glyphs.first[k] = n;
        for (d.strings[r.start..][0..r.bytes], 0..) |byte, j| {
            const col: f32 = @floatFromInt(j % per_line);
            const row: f32 = @floatFromInt(j / per_line);
            const x = r.rect[0] + col * adv;
            const y = r.rect[1] + row * line;
            out[n] = .{
                .rect = .{ x, y, x + adv, y + line },
                .clip = r.clip,
                .params = .{ 0, 0, 0, 0 },
                .uv = try Grid.uv(byte),
                .fill = r.color,
                .border_color = 0,
                .radii = @splat(0),
                .border = 0,
                .opacity = 1, // the run's colour already carries its opacity
                .xform = r.xform,
                .clip_radii = r.clip_radii,
            };
            // Write always, advance until the last row.
            n = @min(n + 1, last);
        }
        glyphs.count[k] = n - start;
        return n;
    }
};

/// One style run of a paragraph: from byte `start` of its text on (to the next span's
/// start), `style`'s size, colour and font instead of the run's. Spans are sorted by `start`.
/// `decoration` adds lines under its bytes to the paragraph's own.
pub const Span = struct { start: u32, style: types.TextStyle, decoration: Decoration = .{} };

/// Styled runs of a frame, for any font: run `rows[i]` of `Texts` takes `table[styles[i]]`,
/// and `decorations` and `spans`, when not empty, have one row per `table` row.
/// `MonoParagraphs` measures them with `Mono`; `text_stack.Stack.style` points a real shaper
/// at them.
pub const Styled = struct {
    rows: []const u32,
    styles: []const u16,
    table: []const Paragraph,
    decorations: []const Decoration = &.{},
    spans: []const []const Span = &.{},
};

/// Puts quads `first..d.quad_len` (just appended after `paint.emit`) right after op `j`, the
/// text op of their run: their ops after it, and the quads themselves moved to where the next
/// quad op's quads begin, so every run of consecutive quad ops still names consecutive quads
/// (`paint.encode` merges them). Later ops' quads move up. Quads past the op rows are
/// dropped. Returns how many were put in; call `paint.encode` once after the last.
pub fn insertAfter(d: *DrawList, j: u32, first: u32) u32 {
    const added = @min(d.quad_len - first, @as(u32, @intCast(d.op.kind.len)) - d.op_len);
    d.quad_len = first + added;
    const quads_kind = @backingInt(DrawList.Kind.quads);
    // Where the quads after op j begin: the first later quad op's, or the end.
    var at: u32 = first;
    for (j + 1..d.op_len) |o| if (d.op.kind[o] == quads_kind) {
        at = d.op.ref[o];
        break;
    };
    std.mem.rotate(Quad, d.quads[at..d.quad_len], first - at);
    for (j + 1..d.op_len) |o| d.op.ref[o] += simd.selU(d.op.kind[o] == quads_kind, added, 0);
    const tail = d.op_len - (j + 1);
    inline for (.{ "kind", "key", "ref" }) |col| {
        const c = @field(d.op, col);
        std.mem.copyBackwards(@TypeOf(c[0]), c[j + 1 + added ..][0..tail], c[j + 1 ..][0..tail]);
    }
    for (0..added) |m| {
        d.op.kind[j + 1 + m] = quads_kind;
        d.op.key[j + 1 + m] = 0; // white texture, solid material
        d.op.ref[j + 1 + m] = at + @as(u32, @intCast(m));
    }
    d.op_len += added;
    return added;
}

/// Which inputs a `MonoParagraphsOf` reads. A page without spans leaves them out; one that
/// draws no decoration (a run's or a span's) leaves out `decorations` and `decorate`'s code.
pub const Features = struct { spans: bool = true, decorations: bool = true };

/// `MonoParagraphsOf` with every input.
pub const MonoParagraphs = MonoParagraphsOf(.{});

/// `Mono` with paragraph styles on some runs: run `rows[i]` of `Texts` takes
/// `table[styles[i]]` (`rows` ascending; draw list run k is texts row k). Of `stack.Paragraph`,
/// Mono honours `line_height` (and `leading`), `letter_spacing`, `word_spacing` (after every
/// space byte), `max_lines` and `ellipsis` ("..." at the cut); the rest is for a real shaper's
/// `Stack`. Measure and wrap run Mono's passes over every run, then rewrite only the listed
/// runs by walking their bytes, so a frame without styled runs costs what Mono costs. `quads`
/// places glyphs by the same walk. Mono's own rules hold: every byte is one cell and lines
/// break between any two bytes. `decorate` adds underlines, overlines and line-throughs to
/// the draw list as solid quads.
pub fn MonoParagraphsOf(comptime with: Features) type {
    return struct {
        const Self = @This();

        mono: Mono = .{},
        rows: []const u32,
        styles: []const u16,
        table: []const Paragraph,
        /// Empty, or one row per `table` row: its runs' decoration lines (`text_decorations.Style`;
        /// Mono draws `underline`, `overline` and `strike` solid, in `color` and `thickness`).
        decorations: if (with.decorations) []const Decoration else *const [0]Decoration = &.{},
        /// Empty, or one row per `table` row: its runs' style spans (inline runs: one paragraph in
        /// several sizes, colours and fonts). With `line_height = .font` a line is as tall as the
        /// largest size's, else as the paragraph says.
        spans: if (with.spans) []const []const Span else *const [0][]const Span = &.{},
        /// The bytes the runs' `start` and `bytes` index: the frame's strings (`Frame` sets it).
        strings: []const u8 = "",

        /// Mono's measure, then the single-line extent of every styled run.
        pub fn measure(p: Self, tx: *Texts) void {
            p.mono.measure(tx);
            const c = &tx.c;
            for (p.rows, p.styles) |k, i| {
                const w = p.walker(i, c.px[k]);
                const f = w.fit(p.strings[c.start[k]..][0..c.bytes[k]], std.math.inf(f32), false);
                c.w[k] = f.w;
                c.h[k] = w.line();
            }
        }

        /// Mono's wrap, then every styled run in its `avail`: re-flowed when it wraps, cut to it
        /// when it shows an ellipsis.
        pub fn wrap(p: Self, tx: *Texts) void {
            p.mono.wrap(tx);
            const c = &tx.c;
            for (p.rows, p.styles) |k, i| {
                const w = p.walker(i, c.px[k]);
                const wraps = c.wrap[k] > 0;
                const avail = c.avail[k];
                const f = w.fit(p.strings[c.start[k]..][0..c.bytes[k]], avail, wraps);
                c.w[k] = if (wraps or w.st.ellipsis) @min(f.w, avail) else f.w;
                c.h[k] = @as(f32, @floatFromInt(f.lines)) * w.line();
            }
        }

        /// `Mono.quads` with the styled runs laid out as `wrap` measured them (from the frame's
        /// `tx`: each run's wrap flag and width), each glyph in its span's size and colour.
        pub fn quads(p: Self, d: *const DrawList, tx: *const Texts, out: []Quad, glyphs: Mono.Glyphs) u32 {
            std.debug.assert(out.len >= 1);
            var n: u32 = 0;
            var next: usize = 0;
            for (0..d.run_len) |k_| {
                const k: u32 = @intCast(k_);
                const listed = next < p.rows.len and p.rows[next] == k;
                n = if (listed) p.appendStyled(d, tx, k, p.styles[next], out, glyphs, n) else p.mono.appendRun(FullGrid, d, k, out, glyphs, n) catch unreachable;
                next += @intFromBool(listed);
            }
            return n;
        }

        fn walker(p: Self, style: u16, px: f32) Walk {
            return .{ .mono = p.mono, .st = p.table[style], .spans = if (p.spans.len > 0) p.spans[style] else &.{}, .px = px };
        }

        /// The run's layout as `quads` and `decorate` draw it: the walker, whether it wrapped, and
        /// the walk's result.
        /// Draw list run k is texts row k: its wrap flag and the width layout gave it are the ones
        /// `wrap` laid it out with, so this is the same layout exactly.
        fn placed(p: Self, d: *const DrawList, tx: *const Texts, k: u32, style: u16) struct { w: Walk, wraps: bool, f: Fit, bytes: []const u8, avail: f32 } {
            const r = d.runs[k];
            const w = p.walker(style, r.px);
            const bytes = d.strings[r.start..][0..r.bytes];
            const avail = tx.c.avail[k];
            const wraps = tx.c.wrap[k] > 0;
            return .{ .w = w, .wraps = wraps, .f = w.fit(bytes, avail, wraps), .bytes = bytes, .avail = avail };
        }

        fn appendStyled(p: Self, d: *const DrawList, tx: *const Texts, k: u32, style: u16, out: []Quad, glyphs: Mono.Glyphs, start: u32) u32 {
            const r = d.runs[k];
            const l = p.placed(d, tx, k, style);
            const w = l.w;
            const last: u32 = @intCast(out.len - 1);
            var n = start;
            glyphs.first[k] = n;
            var at: Pen = .{};
            const dots: u32 = if (l.f.cut < l.bytes.len and w.st.ellipsis) 3 else 0;
            for (0..l.f.cut + dots) |j| {
                // The ellipsis takes the style of the last byte kept.
                const b = if (j < l.f.cut) l.bytes[j] else '.';
                const at_byte: u32 = @intCast(@min(j, @max(l.f.cut, 1) - 1));
                const span = w.styleAt(at_byte, r);
                at.advance(w, at_byte, b, l.avail, l.wraps and j < l.f.cut);
                const adv = span.px * w.mono.advance;
                const cell = span.px * w.mono.line;
                const y = r.rect[1] + @as(f32, @floatFromInt(at.line)) * w.line() + (w.line() - cell) * std.math.clamp(w.st.leading, 0, 1);
                n = glyph(out, n, last, r, at.x - w.width(at_byte, b), y, adv, cell, b, span.color);
            }
            glyphs.count[k] = n - start;
            return n;
        }

        /// After `paint.emit`: one solid quad per line and decoration of every decorated run,
        /// painted right after the run's text and encoded into commands again. Lines are those
        /// `quads` draws. Quads and ops past the draw list's rows are dropped.
        pub fn decorate(p: Self, d: *DrawList, tx: *const Texts) void {
            if (comptime !with.decorations) return;
            if (p.decorations.len == 0 and p.spans.len == 0) return;
            std.debug.assert(p.decorations.len == 0 or p.decorations.len == p.table.len);
            var j: u32 = 0;
            while (j < d.op_len) : (j += 1) {
                if (d.op.kind[j] != @backingInt(DrawList.Kind.text)) continue;
                const k = d.op.ref[j];
                const at = std.mem.indexOfScalar(u32, p.rows, k) orelse continue;
                const first = d.quad_len;
                p.decorationQuads(d, tx, k, p.styles[at]);
                j += insertAfter(d, j, first);
            }
            paint.encode(d);
        }

        /// The styled runs this font measures, for a real shaper (`text_stack.Stack.style`).
        pub fn styled(p: Self) Styled {
            return .{ .rows = p.rows, .styles = p.styles, .table = p.table, .decorations = p.decorations, .spans = p.spans };
        }

        fn decorationQuads(p: Self, d: *DrawList, tx: *const Texts, k: u32, style: u16) void {
            const l = p.placed(d, tx, k, style);
            const dots: u32 = if (l.f.cut < l.bytes.len and l.w.st.ellipsis) 3 else 0;
            // The paragraph's lines under all of it, dots included; a span's under its bytes.
            if (p.decorations.len > 0) rangeBars(d, d.runs[k], l, 0, l.f.cut + dots, p.decorations[style]);
            for (l.w.spans, 0..) |sp, i| {
                const end = if (i + 1 < l.w.spans.len) l.w.spans[i + 1].start else l.f.cut + dots;
                rangeBars(d, d.runs[k], l, sp.start, @min(end, l.f.cut + dots), sp.decoration);
            }
        }

        /// One bar per line and decoration line under bytes `a..b` of the run as `quads` draws it.
        fn rangeBars(d: *DrawList, r: draw_list.TextRun, l: anytype, a: u32, b: u32, deco: Decoration) void {
            if (!(deco.underline or deco.overline or deco.strike) or a >= b) return;
            const w = l.w;
            const cell = r.px * w.mono.line;
            const top = (w.line() - cell) * std.math.clamp(w.st.leading, 0, 1);
            const thickness = deco.thickness orelse @max(1, @round(r.px / 14));
            const color = if (deco.color) |authored| paint.fade(authored, r.opacity) else r.color;
            var pen: Pen = .{};
            var x0: f32 = 0;
            var x1: f32 = 0;
            var line_no: u32 = 0;
            var any = false;
            for (0..b) |i| {
                const byte = if (i < l.f.cut) l.bytes[i] else '.';
                const at: u32 = @intCast(@min(i, @max(l.f.cut, 1) - 1));
                const before = pen.line;
                pen.advance(w, at, byte, l.avail, l.wraps and i < l.f.cut);
                if (pen.line != before and any) {
                    bars(d, r, line_no, x0, x1, w.line(), top, cell, thickness, color, deco);
                    any = false;
                }
                line_no = pen.line;
                if (i < a) continue;
                if (!any) x0 = pen.x - w.width(at, byte);
                x1 = pen.x;
                any = true;
            }
            if (any) bars(d, r, line_no, x0, x1, w.line(), top, cell, thickness, color, deco);
        }

        /// The decoration bars of one line, from `x0` to `x1` px into the run.
        fn bars(d: *DrawList, r: draw_list.TextRun, line_no: u32, x0: f32, x1: f32, line: f32, top: f32, cell: f32, thickness: f32, color: u32, deco: Decoration) void {
            const cell_top = r.rect[1] + @as(f32, @floatFromInt(line_no)) * line + top;
            // Mono has no face metrics: the underline below the baseline, the strike through
            // the x-height's middle, the overline at the cell's top.
            const ys = [_]f32{ cell_top + cell * 0.82, cell_top + cell * 0.08, cell_top + cell * 0.5 };
            for ([_]bool{ deco.underline, deco.overline, deco.strike }, ys) |on, y| {
                if (!on or d.quad_len + 1 >= d.quads.len) continue;
                d.quads[d.quad_len] = .{
                    .rect = .{ r.rect[0] + x0, y, r.rect[0] + x1, y + thickness },
                    .clip = r.clip,
                    .params = @splat(0),
                    .uv = .{ 0, 0, 1, 1 },
                    .fill = color,
                    .border_color = 0,
                    .radii = @splat(0),
                    .border = 0,
                    .opacity = 1,
                    .xform = r.xform,
                    .clip_radii = r.clip_radii,
                };
                d.quad_len += 1;
            }
        }

        fn glyph(out: []Quad, n: u32, last: u32, r: draw_list.TextRun, x_: f32, y: f32, adv: f32, cell: f32, b: u8, color: u32) u32 {
            const x = r.rect[0] + x_;
            out[n] = .{
                .rect = .{ x, y, x + adv, y + cell },
                .clip = r.clip,
                .params = .{ 0, 0, 0, 0 },
                .uv = FullGrid.uv(b) catch unreachable,
                .fill = color,
                .border_color = 0,
                .radii = @splat(0),
                .border = 0,
                .opacity = 1,
                .xform = r.xform,
                .clip_radii = r.clip_radii,
            };
            return @min(n + 1, last);
        }

        /// One run's style: its paragraph, spans and own size.
        const Walk = struct {
            mono: Mono,
            st: Paragraph,
            spans: if (with.spans) []const Span else *const [0]Span,
            px: f32,

            fn line(w: Walk) f32 {
                var px = w.px;
                for (w.spans) |sp| px = @max(px, sp.style.px);
                return switch (w.st.line_height) {
                    .font => px * w.mono.line,
                    .px => |v| v,
                    .multiple => |v| v * w.px,
                };
            }

            /// The size and colour of byte `j`: its span's, else the run's (`r` for the colour).
            /// ponytail: a scan over the spans per byte; keep a cursor if paragraphs get many.
            fn styleAt(w: Walk, j: u32, r: draw_list.TextRun) struct { px: f32, color: u32 } {
                var out: @TypeOf(w.styleAt(j, r)) = .{ .px = w.px, .color = r.color };
                for (w.spans) |sp| if (sp.start <= j) {
                    out = .{ .px = sp.style.px, .color = paint.fade(sp.style.color.bitsOf(), r.opacity) };
                };
                return out;
            }

            fn pxAt(w: Walk, j: u32) f32 {
                var px = w.px;
                for (w.spans) |sp| px = simd.selF(sp.start <= j, sp.style.px, px);
                return px;
            }

            /// The advance of byte `b` at `j`: its cell, letter spacing and, after a space, word
            /// spacing.
            fn width(w: Walk, j: u32, b: u8) f32 {
                return w.pxAt(j) * w.mono.advance + w.st.letter_spacing + simd.b2f(b == ' ') * w.st.word_spacing;
            }

            fn fit(w: Walk, bytes: []const u8, avail: f32, wraps: bool) Fit {
                var total: f32 = 0;
                for (bytes, 0..) |b, j| total += w.width(@intCast(j), b);
                var pen: Pen = .{};
                var cut: u32 = @intCast(bytes.len);
                for (bytes, 0..) |b, j| {
                    const before = pen;
                    pen.advance(w, @intCast(j), b, avail, wraps);
                    if (pen.line >= w.st.max_lines) {
                        pen = before;
                        cut = @intCast(j);
                        break;
                    }
                }
                const lines = pen.line + 1;
                const overflow = cut < bytes.len or (!wraps and total > avail);
                if (w.st.ellipsis and overflow) {
                    // Back off until "..." fits after the last byte kept on the last line.
                    var x = pen.x;
                    var j = if (cut < bytes.len) cut else visible: {
                        var x_end: f32 = 0;
                        var m: u32 = 0;
                        while (m < bytes.len and x_end + w.width(m, bytes[m]) <= avail) : (m += 1) x_end += w.width(m, bytes[m]);
                        x = x_end;
                        break :visible m;
                    };
                    while (j > 0 and x + 3 * w.width(j - 1, '.') > avail) {
                        j -= 1;
                        x -= w.width(j, bytes[j]);
                    }
                    cut = j;
                }
                return .{ .w = total, .lines = lines, .cut = cut };
            }
        };

        /// Where the walk is: x after the last byte placed, on line `line`.
        const Pen = struct {
            x: f32 = 0,
            line: u32 = 0,

            /// Places byte `b` (at `j`): on this line if it fits within `avail` (half a cell of
            /// slack, as Mono rounds), else first on the next one. A line's first byte always fits.
            fn advance(pen: *Pen, w: Walk, j: u32, b: u8, avail: f32, wraps: bool) void {
                const bw = w.width(j, b);
                const slack = @max(w.pxAt(j) * w.mono.advance, 1e-6) * 0.5;
                const next = wraps and pen.x > 0 and pen.x + bw > avail + slack;
                pen.line += @intFromBool(next);
                pen.x = if (next) bw else pen.x + bw;
            }
        };

        /// The walk's result: single-line width, lines shown (clamped to `max_lines`) and the
        /// bytes drawn before the ellipsis (all of them when nothing is cut).
        const Fit = struct { w: f32, lines: u32, cut: u32 };
    };
}

fn cellUv(index: u8, comptime columns: usize, comptime rows: usize) [4]f32 {
    const x: f32 = @floatFromInt(@as(usize, index) % columns);
    const y: f32 = @floatFromInt(@as(usize, index) / columns);
    const w: f32 = @floatFromInt(columns);
    const h: f32 = @floatFromInt(rows);
    return .{ x / w, y / h, (x + 1) / w, (y + 1) / h };
}

const FullGrid = struct {
    fn uv(byte: u8) error{}![4]f32 {
        return Mono.atlas.uv(byte);
    }
};

/// Where each byte's glyph sits in a bitmap font atlas: `columns` x `rows` equal cells, each
/// `cell` of the texture in UV, holding the bytes from `first` to `last` in order, row by row.
/// Another byte shows `missing`'s cell, or the space's when it is a control byte and the atlas
/// has a space: a tab or a newline in a line of text is blank. A host passes its font's
/// descriptor to whatever maps bytes to cells (`canvas.Instances.glyphs`); the default is
/// `Mono`'s full 16 x 16 grid.
pub const Atlas = struct {
    columns: u8 = 16,
    rows: u8 = 16,
    first: u8 = 0,
    last: u8 = 255,
    missing: u8 = '?',
    cell: [2]f32 = .{ 1.0 / 16.0, 1.0 / 16.0 },

    /// `columns` x `rows` cells filling the texture, holding the bytes `first` to `last`.
    pub fn grid(columns: u8, rows: u8, first: u8, last: u8) Atlas {
        return .{ .columns = columns, .rows = rows, .first = first, .last = last, .cell = .{ 1 / @as(f32, @floatFromInt(columns)), 1 / @as(f32, @floatFromInt(rows)) } };
    }

    /// The UV rect (u0, v0, u1, v1) of `byte`'s cell.
    pub fn uv(a: Atlas, byte: u8) [4]f32 {
        const blank = byte < ' ' and a.first <= ' ' and a.last >= ' ';
        const other: u8 = if (blank) ' ' else a.missing;
        const shown = if (byte >= a.first and byte <= a.last) byte else other;
        const index: u32 = shown -% a.first;
        const x: f32 = @floatFromInt(index % a.columns);
        const y: f32 = @floatFromInt(index / a.columns);
        return .{ x * a.cell[0], y * a.cell[1], (x + 1) * a.cell[0], (y + 1) * a.cell[1] };
    }
};

/// Pack only the byte cells referenced by a static vocabulary, using the same pixels and
/// glyph metrics as Mono's 16x16 atlas. Pass the resulting type to Mono.quadsFor.
pub fn StaticAtlas(comptime strings: []const []const u8) type {
    const table: struct { map: [256]u8, count: usize } = comptime blk: {
        var map: [256]u8 = @splat(255);
        var seen: std.bit_set.Static(256) = .empty;
        var n: usize = 0;
        var quota: usize = 10000;
        for (strings) |str| {
            quota += 20 * (str.len + 1);
            @setEvalBranchQuota(quota);
            for (str) |byte| {
                if (seen.isSet(byte)) continue;
                seen.set(byte);
                map[byte] = @intCast(n);
                n += 1;
            }
        }
        break :blk .{ .map = map, .count = n };
    };
    return struct {
        const lookup = table.map;
        pub const count = table.count;
        pub const columns = @min(count, 16);
        pub const rows = (count + 15) / 16;

        pub fn uv(byte: u8) error{GlyphOutsideSubset}![4]f32 {
            if (count == 0) return error.GlyphOutsideSubset;
            const index = lookup[byte];
            if (count < 256 and index == 255) return error.GlyphOutsideSubset;
            return cellUv(index, columns, rows);
        }

        /// Copy each referenced cell's scanlines from the full source atlas at compile time.
        /// The caller embeds the returned pixels directly. Unoccupied trailing cells are zero.
        pub fn pixels(comptime Pixel: type, comptime cell: [2]usize, comptime full: []const Pixel) [columns * rows * cell[0] * cell[1]]Pixel {
            return comptime blk: {
                if (cell[0] == 0 or cell[1] == 0 or full.len != 256 * cell[0] * cell[1])
                    @compileError("expected a 16x16 atlas of equally sized nonempty glyph cells");
                const len = columns * rows * cell[0] * cell[1];
                @setEvalBranchQuota(4000 + 20 * len);
                var out: [len]Pixel = @splat(0);
                if (count > 0) for (table.map, 0..) |slot, byte| {
                    if (count < 256 and slot == 255) continue;
                    for (0..cell[1]) |line| {
                        const src = ((byte / 16 * cell[1] + line) * 16 + byte % 16) * cell[0];
                        const dst = ((@as(usize, slot) / columns * cell[1] + line) * columns + @as(usize, slot) % columns) * cell[0];
                        @memcpy(out[dst..][0..cell[0]], full[src..][0..cell[0]]);
                    }
                };
                break :blk out;
            };
        }
    };
}

/// Remembers measured extents across frames, keyed by a hash of the run's bytes, its font and
/// its size, so an expensive shaper measures only text it has not seen. Font-agnostic: it sits
/// on the measure step of the protocol, around whatever fills `w` and `h`.
///
/// Per frame: `lookup` fills `w`, `h` of every hit and lists the misses; the caller measures the
/// misses; `store` records them. Direct-mapped, one entry per slot: a new key evicts the old one.
/// Tier 0: the table is carved from the caller's buffer and never grows.
pub const Cache = struct {
    /// Slots - 1. Index from bit 1 because generated keys reserve bit 0 for the empty marker.
    mask: u32,
    c: Columns,

    pub const Columns = struct {
        /// 0 marks an empty slot; `key` never returns 0.
        key: []u64,
        w: []f32,
        h: []f32,
    };

    /// Carves a table of `slots` entries (a power of two), all empty. With a counting carver this
    /// sizes the buffer instead.
    pub fn init(carver: *mem.Carver, slots: u32) Cache {
        std.debug.assert(std.math.isPowerOfTwo(slots));
        return .{ .mask = slots - 1, .c = carver.columns(Columns, slots) };
    }

    /// Forgets every entry, e.g. after a font is reloaded.
    pub fn clear(cache: *Cache) void {
        @memset(cache.c.key, 0);
    }

    /// The key of a run: Wyhash of its bytes, seeded with font and size. Two different runs share a
    /// key with probability about 2^-63; the cache accepts that instead of storing the bytes.
    pub fn key(bytes: []const u8, font: u16, px: f32) u64 {
        const seed = (@as(u64, font) << 32) | @as(u32, @bitCast(px));
        return std.hash.Wyhash.hash(seed, bytes) | 1;
    }

    /// Writes `w`, `h` of every run of `tx` found in the cache and appends the rows of the others
    /// to `misses` (at least `tx.len` long). Returns the number of misses. Hashing reads each run's
    /// bytes, so this is a scalar loop; hits are selected, not branched on.
    pub fn lookup(cache: *const Cache, tx: *Texts, strings: *const Strings, misses: []u32) u32 {
        std.debug.assert(misses.len >= tx.len);
        const c = &tx.c;
        var n: u32 = 0;
        for (0..tx.len) |k| {
            const want = key(strings.get(.{ .start = c.start[k], .bytes = c.bytes[k] }), c.font[k], c.px[k]);
            const slot: usize = @intCast((want >> 1) & cache.mask); // mask < slot count, so it fits a 32-bit usize
            const hit = cache.c.key[slot] == want;
            c.w[k] = simd.selF(hit, cache.c.w[slot], c.w[k]);
            c.h[k] = simd.selF(hit, cache.c.h[slot], c.h[k]);
            // Write always, advance by 0 or 1.
            misses[n] = @intCast(k);
            n += @intFromBool(!hit);
        }
        return n;
    }

    /// Records the measured `w`, `h` of the runs listed in `rows` (the misses, once measured).
    pub fn store(cache: *Cache, tx: *const Texts, strings: *const Strings, rows: []const u32) void {
        const c = &tx.c;
        for (rows) |k| {
            const want = key(strings.get(.{ .start = c.start[k], .bytes = c.bytes[k] }), c.font[k], c.px[k]);
            const slot: usize = @intCast((want >> 1) & cache.mask); // mask < slot count, so it fits a 32-bit usize
            cache.c.key[slot] = want;
            cache.c.w[slot] = c.w[k];
            cache.c.h[slot] = c.h[k];
        }
    }
};

const testing = std.testing;

fn Fixture(comptime cap: u32) type {
    return struct {
        buf: [bytes]u8 align(mem.column_align) = undefined,

        const bytes = blk: {
            var counter: mem.Carver = .{ .buf = null };
            _ = Texts.init(&counter, cap);
            break :blk counter.off;
        };
        fn texts(fx: *@This()) Texts {
            var carver: mem.Carver = .{ .buf = &fx.buf };
            return Texts.init(&carver, cap);
        }
    };
}

test "the protocol is columns: a caller can measure by hand" {
    var fx: Fixture(4) = .{};
    var tx = fx.texts();
    const k = tx.push(0, .{ .start = 0, .bytes = 3 }, &.{ .px = 10, .wrap = true });
    // Inputs a font reads, outputs it writes: plain f32 columns, no hook to register.
    try testing.expectEqual(0, tx.c.w[k]);
    try testing.expectEqual(0, tx.c.h[k]);
    tx.c.w[k] = 18;
    tx.c.h[k] = 12;
    tx.c.avail[k] = 10;
    try testing.expectEqual(1, tx.c.wrap[k]);
    try testing.expectEqual(18, tx.c.w[k]);
}

test "Mono.encode: UTF-8 as the bundled fonts' cell bytes, one for each character" {
    var buf: [32]u8 = undefined;
    try testing.expectEqualStrings("\x81 Agent", Mono.encode("\u{221e} Agent", &buf));
    try testing.expectEqualStrings("Working\x85", Mono.encode("Working\u{2026}", &buf));
    const dotted = Mono.encode("1 file \u{b7} 1 edit", &buf);
    try testing.expectEqualStrings("1 file \xb7 1 edit", dotted);
    const quoted = Mono.encode("caf\u{e9} \u{201c}x\u{201d}", &buf);
    try testing.expectEqualStrings("caf\xe9 \x93x\x94", quoted);
    // A control character is a space; a character with no cell, a byte that is not UTF-8 and
    // a character cut short are each one '?'.
    try testing.expectEqualStrings("a b?c??", Mono.encode("a\nb\u{4e2d}c\xff\xe2", &buf));
    // Cut at the room there is.
    try testing.expectEqualStrings("ab", Mono.encode("abc", buf[0..2]));
    // Every cell with a character comes back from its character.
    for (Mono.high_cells, 0x80..) |point, byte| {
        if (point != 0) try testing.expectEqual(@as(u8, @intCast(byte)), Mono.cellOf(point));
    }
}

test "Atlas.uv: a control byte outside the atlas shows the space, another byte the missing cell" {
    const wide: Atlas = .grid(16, 14, ' ', 255);
    try testing.expectEqual(wide.uv(' '), wide.uv('\n'));
    try testing.expectEqual(wide.uv(' '), wide.uv('\t'));
    const ascii: Atlas = .grid(16, 6, ' ', '~');
    try testing.expectEqual(ascii.uv('?'), ascii.uv(0x85));
    // Mono's own grid has a cell for every byte.
    const full: Atlas = .{};
    try testing.expect(!std.meta.eql(full.uv(' '), full.uv('\n')));
}

test "Mono.measure: bytes * px * advance wide, px * line tall, for every run" {
    var fx: Fixture(20) = .{};
    var tx = fx.texts();
    // More runs than lanes, so the loop takes several steps at every lane count.
    for (0..19) |k| _ = tx.push(0, .{ .bytes = @intCast(k) }, &.{ .px = 10 });
    _ = tx.push(0, .{ .bytes = 24 }, &.{ .px = 20 });
    const font: Mono = .{ .advance = 0.5, .line = 1.2 };
    font.measure(&tx);
    for (0..19) |k| {
        try testing.expectEqual(@as(f32, @floatFromInt(k)) * 5, tx.c.w[k]);
        try testing.expectEqual(12, tx.c.h[k]);
    }
    try testing.expectEqual(240, tx.c.w[19]);
    try testing.expectEqual(24, tx.c.h[19]);
}

test "Mono.wrap: wrapping runs re-flow into avail, others keep one line" {
    var fx: Fixture(20) = .{};
    var tx = fx.texts();
    // The prototype's paragraph: 24 bytes * 5 px = 120 px into 100 px is two lines.
    for (0..10) |_| _ = tx.push(0, .{ .bytes = 24 }, &.{ .px = 10, .wrap = true });
    for (0..10) |_| _ = tx.push(0, .{ .bytes = 24 }, &.{ .px = 10 });
    const font: Mono = .{ .advance = 0.5, .line = 1.2 };
    font.measure(&tx);
    for (0..20) |k| tx.c.avail[k] = 100;
    tx.c.avail[1] = 200; // fits on one line: w stays 120
    tx.c.avail[2] = 0; // no room: one byte per line, w clamps to 0
    font.wrap(&tx);
    try testing.expectEqual(100, tx.c.w[0]);
    try testing.expectEqual(24, tx.c.h[0]);
    try testing.expectEqual(120, tx.c.w[1]);
    try testing.expectEqual(12, tx.c.h[1]);
    try testing.expectEqual(0, tx.c.w[2]);
    try testing.expectEqual(24 * 12, tx.c.h[2]);
    for (3..10) |k| try testing.expectEqual(24, tx.c.h[k]);
    for (10..20) |k| {
        try testing.expectEqual(120, tx.c.w[k]);
        try testing.expectEqual(12, tx.c.h[k]);
    }
}

test "Mono.wrap: a run that does not wrap keeps the extent another font measured" {
    var fx: Fixture(4) = .{};
    var tx = fx.texts();
    _ = tx.push(0, .{ .bytes = 4 }, &.{ .px = 20, .font = @fromBackingInt(1) });
    _ = tx.push(0, .{ .bytes = 24 }, &.{ .px = 10, .wrap = true });
    const font: Mono = .{ .advance = 0.5, .line = 1.2 };
    font.measure(&tx);
    // A second font measures run 0 after Mono: four 20 px squares.
    tx.c.w[0] = 80;
    tx.c.h[0] = 20;
    tx.c.avail[0] = 100;
    tx.c.avail[1] = 100;
    font.wrap(&tx);
    try testing.expectEqual(80, tx.c.w[0]);
    try testing.expectEqual(20, tx.c.h[0]);
    try testing.expectEqual(100, tx.c.w[1]);
    try testing.expectEqual(24, tx.c.h[1]);
}

test "Mono.wrap: no wrapping flags preserve foreign metrics and a later final run still wraps" {
    const runs = 2 * W + 1;
    var fx: Fixture(runs) = .{};
    var tx = fx.texts();
    const font: Mono = .{ .advance = 0.5, .line = 1.2 };
    for (0..runs) |k| {
        _ = tx.push(0, .{ .bytes = 24 }, &.{ .px = 10 });
        tx.c.w[k] = @floatFromInt(k + 80);
        tx.c.h[k] = @floatFromInt(k + 20);
        tx.c.avail[k] = 100;
    }
    // Non-positive and unordered flags all mean "keep the extent" under the
    // protocol's > 0 predicate. Do not reinterpret them as a truthy bit pattern.
    tx.c.wrap[0] = -1;
    tx.c.wrap[1] = std.math.nan(f32);
    tx.c.w[0] = -0.0;
    tx.c.h[0] = std.math.inf(f32);
    font.wrap(&tx);
    try testing.expectEqual(@as(u32, 0x8000_0000), @as(u32, @bitCast(tx.c.w[0])));
    try testing.expectEqual(std.math.inf(f32), tx.c.h[0]);
    for (1..runs) |k| {
        try testing.expectEqual(@as(f32, @floatFromInt(k + 80)), tx.c.w[k]);
        try testing.expectEqual(@as(f32, @floatFromInt(k + 20)), tx.c.h[k]);
    }

    // No cached summary: a direct column write between calls must be observed,
    // including the single valid lane of a trailing partial vector.
    tx.c.wrap[runs - 1] = 1;
    tx.c.w[runs - 1] = 120;
    tx.c.h[runs - 1] = 12;
    font.wrap(&tx);
    try testing.expectEqual(@as(f32, 100), tx.c.w[runs - 1]);
    try testing.expectEqual(@as(f32, 24), tx.c.h[runs - 1]);
    for (1..runs - 1) |k| {
        try testing.expectEqual(@as(f32, @floatFromInt(k + 80)), tx.c.w[k]);
        try testing.expectEqual(@as(f32, @floatFromInt(k + 20)), tx.c.h[k]);
    }
}

test "Mono.wrap: stale padding after a shorter frame cannot change live nonwrapping extents" {
    var fx: Fixture(2 * W) = .{};
    var tx = fx.texts();
    const font: Mono = .{};
    for (0..2 * W) |_| _ = tx.push(0, .{ .bytes = 24 }, &.{ .wrap = true });
    font.measure(&tx);
    tx.reset();
    _ = tx.push(0, .{ .bytes = 4 }, &.{});
    tx.c.w[0] = 81;
    tx.c.h[0] = 21;
    tx.c.avail[0] = 30;
    font.wrap(&tx);
    try testing.expectEqual(@as(f32, 81), tx.c.w[0]);
    try testing.expectEqual(@as(f32, 21), tx.c.h[0]);
    tx.reset();
    font.wrap(&tx); // An empty list has no columns to read, including stale padding.
    try testing.expectEqual(@as(f32, 81), tx.c.w[0]);
    try testing.expectEqual(@as(f32, 21), tx.c.h[0]);
}

test "Cache: misses are measured once, hits come back without measuring" {
    var fx: Fixture(4) = .{};
    var tx = fx.texts();
    var str_buf: [64]u8 = undefined;
    var strings: Strings = .{ .buf = &str_buf };
    var cache_buf: [cache_bytes]u8 align(mem.column_align) = undefined;
    var carver: mem.Carver = .{ .buf = &cache_buf };
    var cache: Cache = .init(&carver, 16);
    const font: Mono = .{ .advance = 0.5, .line = 1.2 };
    var misses: [4]u32 = undefined;

    const frame = struct {
        fn build(t: *Texts, s: *Strings) void {
            t.reset();
            s.reset();
            _ = t.push(0, s.add("hello"), &.{ .px = 10 });
            _ = t.push(1, s.add("hello"), &.{ .px = 20 }); // same bytes, other size
            _ = t.push(2, s.add("hello"), &.{ .px = 10, .font = @fromBackingInt(1) }); // other font
            _ = t.push(3, s.add("hi"), &.{ .px = 10 });
        }
    };

    // Frame 1: everything misses; measure the misses (here Mono, standing in for a shaper).
    frame.build(&tx, &strings);
    var n = cache.lookup(&tx, &strings, &misses);
    try testing.expectEqual(4, n);
    try testing.expectEqualSlices(u32, &.{ 0, 1, 2, 3 }, misses[0..n]);
    font.measure(&tx);
    cache.store(&tx, &strings, misses[0..n]);

    // Frame 2: same runs, all hits, extents equal to measuring.
    frame.build(&tx, &strings);
    n = cache.lookup(&tx, &strings, &misses);
    try testing.expectEqual(0, n);
    try testing.expectEqualSlices(f32, &.{ 25, 50, 25, 10 }, tx.c.w[0..4]);
    try testing.expectEqualSlices(f32, &.{ 12, 24, 12, 12 }, tx.c.h[0..4]);

    // Different bytes miss; clear forgets everything.
    tx.reset();
    _ = tx.push(0, strings.add("hellp"), &.{ .px = 10 });
    try testing.expectEqual(1, cache.lookup(&tx, &strings, &misses));
    try testing.expectEqual(0, tx.c.w[0]);
    frame.build(&tx, &strings);
    cache.clear();
    try testing.expectEqual(4, cache.lookup(&tx, &strings, &misses));
}

test "Cache: both slots hold measured extents and a collision replaces only one" {
    var fx: Fixture(3) = .{};
    var tx = fx.texts();
    var buf: [32]u8 = undefined;
    var strings: Strings = .{ .buf = &buf };
    for ([_][]const u8{ "Type", "AVTa", "hello" }, 0..) |s, i|
        _ = tx.push(@intCast(i), strings.add(s), &.{ .px = 10 });
    var cache_buf: [cache_bytes]u8 align(mem.column_align) = undefined;
    var carver: mem.Carver = .{ .buf = &cache_buf };
    var cache = Cache.init(&carver, 2);
    var misses: [3]u32 = undefined;
    tx.c.w[0..3].* = .{ 15, 19, 25 };
    tx.c.h[0..3].* = .{ 10, 11, 12 };
    cache.store(&tx, &strings, &.{ 0, 1 });
    @memset(tx.c.w[0..2], 0);
    @memset(tx.c.h[0..2], 0);
    try testing.expectEqual(1, cache.lookup(&tx, &strings, &misses));
    try testing.expectEqual(2, misses[0]);
    try testing.expectEqualSlices(f32, &.{ 15, 19 }, tx.c.w[0..2]);
    try testing.expectEqualSlices(f32, &.{ 10, 11 }, tx.c.h[0..2]);

    // "hello" maps to the same slot as "Type".
    cache.store(&tx, &strings, misses[0..1]);
    try testing.expectEqual(1, cache.lookup(&tx, &strings, &misses));
    try testing.expectEqual(0, misses[0]);
}

test "Cache: key separates bytes, font and size, and is never the empty marker" {
    const a = Cache.key("abc", 0, 14);
    try testing.expect(a != 0);
    try testing.expect(a != Cache.key("abd", 0, 14));
    try testing.expect(a != Cache.key("abc", 1, 14));
    try testing.expect(a != Cache.key("abc", 0, 15));
    try testing.expectEqual(a, Cache.key("abc", 0, 14));
    try testing.expect(Cache.key("", 0, 0) != 0);
}

fn testList(runs: []draw_list.TextRun, strings: []const u8) DrawList {
    return .{
        .quads = &.{},
        .runs = runs,
        .run_len = @intCast(runs.len),
        .customs = &.{},
        .strings = strings,
        .cmd = .{ .kind = &.{}, .first = &.{}, .count = &.{}, .key = &.{} },
        .op = .{ .kind = &.{}, .key = &.{}, .ref = &.{} },
    };
}

test "Mono.quads: one quad per byte, wrapped at the run width, uv from the byte's atlas cell" {
    const font: Mono = .{ .advance = 0.5, .line = 1.2 };
    // Advance 5 px; run 0 is 10 px wide (2 glyphs per line), run 1 is wide enough for one line.
    var runs = [_]draw_list.TextRun{
        .{ .rect = .{ 100, 50, 110, 80 }, .clip = .{ 0, 0, 800, 600 }, .start = 0, .bytes = 3, .px = 10, .color = 0xff00ff00, .font = 0 },
        .{ .rect = .{ 0, 0, 100, 12 }, .clip = .{ 1, 2, 3, 4 }, .start = 3, .bytes = 2, .px = 10, .color = 0xffffffff, .font = 0 },
    };
    var d = testList(&runs, "AB\x00\xff!");
    var out: [8]Quad = undefined;
    var first: [2]u32 = undefined;
    var count: [2]u32 = undefined;
    const n = font.quads(&d, &out, .{ .first = &first, .count = &count });
    try testing.expectEqual(5, n);
    try testing.expectEqualSlices(u32, &.{ 0, 3 }, &first);
    try testing.expectEqualSlices(u32, &.{ 3, 2 }, &count);
    // "AB" on line 0, NUL wraps to line 1.
    try testing.expectEqual([4]f32{ 100, 50, 105, 62 }, out[0].rect);
    try testing.expectEqual([4]f32{ 105, 50, 110, 62 }, out[1].rect);
    try testing.expectEqual([4]f32{ 100, 62, 105, 74 }, out[2].rect);
    // 'A' = 0x41: column 1, row 4.
    try testing.expectEqual([4]f32{ 1.0 / 16.0, 4.0 / 16.0, 2.0 / 16.0, 5.0 / 16.0 }, out[0].uv);
    try testing.expectEqual([4]f32{ 0, 0, 1.0 / 16.0, 1.0 / 16.0 }, out[2].uv);
    try testing.expectEqual([4]f32{ 15.0 / 16.0, 15.0 / 16.0, 1, 1 }, out[3].uv);
    try testing.expectEqual([4]f32{ 5, 0, 10, 12 }, out[4].rect);
    for (out[0..3]) |q| {
        try testing.expectEqual(0xff00ff00, q.fill);
        try testing.expectEqual([4]f32{ 0, 0, 800, 600 }, q.clip);
        try testing.expectEqual(0, q.border_color);
    }
    try testing.expectEqual([4]f32{ 1, 2, 3, 4 }, out[4].clip);
}

test "Mono.quads: transformed labels carry the transform and rounded clip to every glyph" {
    var runs = [_]draw_list.TextRun{.{
        .rect = .{ 10, 20, 90, 40 },
        .clip = .{ 0, 0, 100, 100 },
        .start = 0,
        .bytes = 2,
        .px = 10,
        .color = 0xffffffff,
        .font = 0,
        .xform = .{ 0, 2, -2, 0, 70, 12 },
        .clip_radii = .{ 3, 4, 5, 6 },
    }};
    const d = testList(&runs, "Hi");
    var out: [4]Quad = undefined;
    var first: [1]u32 = undefined;
    var count: [1]u32 = undefined;
    const n = (Mono{}).quads(&d, &out, .{ .first = &first, .count = &count });
    try testing.expectEqual(2, n);
    for (out[0..n]) |q| {
        try testing.expectEqual(runs[0].xform, q.xform);
        try testing.expectEqual(runs[0].clip_radii, q.clip_radii);
        try testing.expectEqual(runs[0].clip, q.clip);
    }
    // Quads stay in layout space: the common vertex transform moves text and its box once.
    try testing.expectEqual(@as(f32, 10), out[0].rect[0]);
}

test "Mono.quads: a full output stops at its last row, a zero-width run gets one glyph per line" {
    const font: Mono = .{ .advance = 0.5, .line = 1.2 };
    var runs = [_]draw_list.TextRun{
        .{ .rect = .{ 0, 0, 0, 0 }, .clip = .{ 0, 0, 1, 1 }, .start = 0, .bytes = 5, .px = 10, .color = 1, .font = 0 },
    };
    var d = testList(&runs, "hello");
    var out: [3]Quad = undefined;
    var first: [1]u32 = undefined;
    var count: [1]u32 = undefined;
    const n = font.quads(&d, &out, .{ .first = &first, .count = &count });
    try testing.expectEqual(2, n);
    try testing.expectEqual(2, count[0]);
    // Rows 0 and 1 hold 'h' and 'e'; the last row was overwritten until 'o', on line 4.
    try testing.expectEqual([4]f32{ 0, 12, 5, 24 }, out[1].rect);
    try testing.expectEqual([4]f32{ 0, 48, 5, 60 }, out[2].rect);
}

const cache_bytes = blk: {
    var counter: mem.Carver = .{ .buf = null };
    _ = Cache.init(&counter, 16);
    break :blk counter.off;
};

test "StaticAtlas: subset pixels and glyph UVs select the same cells as the full atlas" {
    const Subset = StaticAtlas(&.{ "ABA", "ZA", "\xff" });
    const full = comptime blk: {
        var out: [256 * 4]u16 = undefined;
        for (&out, 0..) |*px, i| px.* = @intCast(i);
        break :blk out;
    };
    const packed_pixels = Subset.pixels(u16, .{ 2, 2 }, &full);
    try testing.expectEqual(4, Subset.count);
    try testing.expectEqual(16, packed_pixels.len);
    var run = [_]draw_list.TextRun{.{ .rect = .{ 0, 0, 40, 12 }, .clip = .{ 0, 0, 40, 12 }, .start = 0, .bytes = 4, .px = 10, .color = 0xffffffff, .font = 0 }};
    var d = testList(&run, "BZA\xff");
    var out: [5]Quad = undefined;
    var first: [1]u32 = undefined;
    var count: [1]u32 = undefined;
    try testing.expectEqual(4, try (Mono{}).quadsFor(Subset, &d, &out, .{ .first = &first, .count = &count }));
    for (d.strings, out[0..4]) |byte, q| {
        const dst: usize = @intFromFloat(q.uv[0] * 8);
        const src = (@as(usize, byte / 16) * 32 + byte % 16) * 2;
        for (0..2) |line|
            try testing.expectEqualSlices(u16, full[src + line * 32 ..][0..2], packed_pixels[dst + line * 8 ..][0..2]);
    }
    d.strings = "XXXX";
    try testing.expectError(error.GlyphOutsideSubset, (Mono{}).quadsFor(Subset, &d, &out, .{ .first = &first, .count = &count }));
    try testing.expectError(error.GlyphOutsideSubset, StaticAtlas(&.{}).uv('a'));
}

test "Mono command expansion skips unsubmitted runs and shares repeated text commands" {
    const Subset = StaticAtlas(&.{"ABC"});
    const r: draw_list.TextRun = .{ .rect = .{ 1.25, 2, 80, 24 }, .clip = .{ 0, 0, 80, 32 }, .start = 0, .bytes = 2, .px = 11, .color = 0x9f234567, .font = 0 };
    var runs = [_]draw_list.TextRun{ r, r, r };
    runs[1].start = 2;
    runs[1].bytes = 3;
    runs[2].start = 5;
    runs[2].bytes = 1;
    var d = testList(&runs, "ABXXXC");
    var kinds = [_]u8{ @backingInt(DrawList.Kind.text), @backingInt(DrawList.Kind.quads), @backingInt(DrawList.Kind.text), @backingInt(DrawList.Kind.text) };
    var refs = [_]u32{ 2, 0, 0, 2 };
    var counts = [_]u32{ 1, 0, 1, 1 };
    var keys = [_]u32{ 0, 0, 0, 0 };
    d.cmd = .{ .kind = &kinds, .first = &refs, .count = &counts, .key = &keys };
    d.cmd_len = kinds.len;
    var visible: [7]Quad = undefined;
    var all: [7]Quad = undefined;
    var first: [3]u32 = undefined;
    var count: [3]u32 = undefined;
    var all_first: [3]u32 = undefined;
    var all_count: [3]u32 = undefined;
    const mono: Mono = .{};
    try testing.expectEqual(3, try mono.quadsForCommands(Subset, &d, &visible, .{ .first = &first, .count = &count }));
    try testing.expectEqualSlices(u32, &.{ 2, 0, 1 }, &count);
    try testing.expectEqual(0, first[1]);
    try testing.expectError(error.GlyphOutsideSubset, mono.quadsFor(Subset, &d, &all, .{ .first = &all_first, .count = &all_count }));
    d.strings = "ABABCC";
    _ = try mono.quadsFor(Subset, &d, &all, .{ .first = &all_first, .count = &all_count });
    for ([_]u32{ 0, 2 }) |k| {
        const actual = visible[first[k]..][0..count[k]];
        const expected = all[all_first[k]..][0..all_count[k]];
        try testing.expectEqualSlices(u8, std.mem.sliceAsBytes(expected), std.mem.sliceAsBytes(actual));
    }
    d.cmd_len = 0;
    try testing.expectEqual(0, try mono.quadsForCommands(Subset, &d, &visible, .{ .first = &first, .count = &count }));
    try testing.expectEqualSlices(u32, &.{ 0, 0, 0 }, &count);
}

test "MonoParagraphs: letter and word spacing, line height, a clamp and an ellipsis, only on styled runs" {
    var fx: Fixture(8) = .{};
    var tx = fx.texts();
    const text = "ab cd" ++ "abcdefgh" ++ "abcdefgh" ++ "ab cd";
    // Advance 5 px at 10 px; Mono lines are 12 px.
    _ = tx.push(0, .{ .start = 0, .bytes = 5 }, &.{ .px = 10 }); // spaced
    _ = tx.push(0, .{ .start = 5, .bytes = 8 }, &.{ .px = 10, .wrap = true }); // 1.5 lines, clamped to 2
    _ = tx.push(0, .{ .start = 13, .bytes = 8 }, &.{ .px = 10 }); // ellipsis in 25 px
    _ = tx.push(0, .{ .start = 21, .bytes = 5 }, &.{ .px = 10 }); // unstyled
    const font: MonoParagraphs = .{
        .mono = .{ .advance = 0.5, .line = 1.2 },
        .rows = &.{ 0, 1, 2 },
        .styles = &.{ 0, 1, 2 },
        .table = &.{
            .{ .letter_spacing = 1, .word_spacing = 4 },
            .{ .line_height = .{ .multiple = 2 }, .max_lines = 2 },
            .{ .ellipsis = true, .line_height = .{ .px = 16 } },
        },
        .strings = text,
    };
    font.measure(&tx);
    // 5 bytes of 6 px and one space of 4 more.
    try testing.expectEqual(34, tx.c.w[0]);
    try testing.expectEqual(12, tx.c.h[0]);
    try testing.expectEqual(40, tx.c.w[1]);
    try testing.expectEqual(20, tx.c.h[1]);
    try testing.expectEqual(16, tx.c.h[2]);
    try testing.expectEqual(25, tx.c.w[3]);
    @memset(tx.c.avail[0..4], 15);
    tx.c.avail[2] = 25;
    font.wrap(&tx);
    // Three bytes per 15 px line: three lines of "abcdefgh", clamped to two of 20 px.
    try testing.expectEqual(15, tx.c.w[1]);
    try testing.expectEqual(40, tx.c.h[1]);
    // Cut to its width; the unwrapped, unstyled runs keep their extents.
    try testing.expectEqual(25, tx.c.w[2]);
    try testing.expectEqual(34, tx.c.w[0]);
    try testing.expectEqual(25, tx.c.w[3]);

    // Drawn as measured: "ab" then "..." in 25 px; the spaced run's "c" after 6 + 6 + 10 px.
    var runs = [_]draw_list.TextRun{
        .{ .rect = .{ 0, 0, 34, 12 }, .clip = .{ 0, 0, 100, 100 }, .start = 0, .bytes = 5, .px = 10, .color = 1, .font = 0 },
        .{ .rect = .{ 0, 20, 15, 60 }, .clip = .{ 0, 0, 100, 100 }, .start = 5, .bytes = 8, .px = 10, .color = 1, .font = 0 },
        .{ .rect = .{ 0, 60, 25, 76 }, .clip = .{ 0, 0, 100, 100 }, .start = 13, .bytes = 8, .px = 10, .color = 1, .font = 0 },
    };
    var d = testList(&runs, text);
    var out: [32]Quad = undefined;
    var first: [3]u32 = undefined;
    var count: [3]u32 = undefined;
    _ = font.quads(&d, &tx, &out, .{ .first = &first, .count = &count });
    try testing.expectEqualSlices(u32, &.{ 5, 6, 5 }, &count);
    try testing.expectEqual([4]f32{ 22, 0, 27, 12 }, out[3].rect);
    // Line two of the clamped run starts at "d", 20 px lower, the 12 px cell centred in it.
    try testing.expectEqual([4]f32{ 0, 44, 5, 56 }, out[first[1] + 3].rect);
    try testing.expectEqual(FullGrid.uv('d') catch unreachable, out[first[1] + 3].uv);
    // "ab..." with the cell 2 px into the 16 px line.
    try testing.expectEqual([4]f32{ 10, 62, 15, 74 }, out[first[2] + 2].rect);
    try testing.expectEqual(FullGrid.uv('.') catch unreachable, out[first[2] + 4].uv);
}

test "MonoParagraphs: spans size and colour their bytes in one paragraph" {
    var fx: Fixture(2) = .{};
    var tx = fx.texts();
    // "ab" at 10 px, "CD" at 20 px in red: 5 + 5 + 10 + 10 px wide.
    _ = tx.push(0, .{ .start = 0, .bytes = 4 }, &.{ .px = 10 });
    const red: types.Color = .rgb(255, 0, 0);
    const spans = [_]Span{.{ .start = 2, .style = .{ .px = 20, .color = red } }};
    const font: MonoParagraphs = .{
        .mono = .{ .advance = 0.5, .line = 1.2 },
        .rows = &.{0},
        .styles = &.{0},
        .table = &.{.{}},
        .spans = &.{&spans},
        .strings = "abCD",
    };
    font.measure(&tx);
    try testing.expectEqual(30, tx.c.w[0]);
    // In 22 px "ab" and "C" fit (the half-cell slack), "D" wraps.
    tx.c.avail[0] = 22;
    tx.c.wrap[0] = 1;
    font.wrap(&tx);
    // Lines as tall as the 20 px span's.
    try testing.expectEqual(48, tx.c.h[0]);
    var runs = [_]draw_list.TextRun{.{ .rect = .{ 0, 0, 22, 48 }, .clip = .{ 0, 0, 100, 100 }, .start = 0, .bytes = 4, .px = 10, .color = 0xffffffff, .font = 0 }};
    var d = testList(&runs, "abCD");
    var out: [8]Quad = undefined;
    var first: [1]u32 = undefined;
    var count: [1]u32 = undefined;
    _ = font.quads(&d, &tx, &out, .{ .first = &first, .count = &count });
    try testing.expectEqual([4]f32{ 10, 0, 20, 24 }, out[2].rect);
    try testing.expectEqual(red.bitsOf(), out[2].fill);
    // The 10 px cells sit in the middle of the 24 px line.
    try testing.expectEqual([4]f32{ 0, 6, 5, 18 }, out[0].rect);
    try testing.expectEqual(0xffffffff, out[0].fill);
    try testing.expectEqual([4]f32{ 0, 24, 10, 48 }, out[3].rect);
}

test "insertAfter: quads after a run's text keep the later quads' commands whole" {
    var buf: [8 * 1024]u8 align(mem.column_align) = undefined;
    var carver: mem.Carver = .{ .buf = &buf };
    var d = DrawList.init(&carver, 4, 1, 1);
    const box = struct {
        fn q(x: f32) Quad {
            return .{ .rect = .{ x, 0, x + 1, 1 }, .clip = @splat(0), .params = @splat(0), .uv = @splat(0), .fill = 1, .border_color = 0, .radii = @splat(0), .border = 0, .opacity = 1 };
        }
    };
    // Paint gave: a box, the text of run 0, another box.
    d.quads[0] = box.q(0);
    d.quads[1] = box.q(1);
    d.quad_len = 2;
    const kinds = [_]DrawList.Kind{ .quads, .text, .quads };
    for (kinds, 0..) |k, o| {
        d.op.kind[o] = @backingInt(k);
        d.op.key[o] = 0;
    }
    d.op.ref[0] = 0;
    d.op.ref[1] = 0;
    d.op.ref[2] = 1;
    d.op_len = 3;
    // One underline appended after the run.
    d.quads[2] = box.q(9);
    d.quad_len = 3;
    try testing.expectEqual(1, insertAfter(&d, 1, 2));
    paint.encode(&d);
    try testing.expectEqual(3, d.cmd_len);
    try testing.expectEqual(draw_list.Cmd{ .quads = .{ .first = 1, .count = 2, .texture = .white, .material = .solid } }, d.command(2));
    try testing.expectEqual([4]f32{ 9, 0, 10, 1 }, d.quads[1].rect);
    try testing.expectEqual([4]f32{ 1, 0, 2, 1 }, d.quads[2].rect);
}

test "MonoParagraphs.quads: a run in a tall box keeps the one line it was measured on" {
    var fx: Fixture(1) = .{};
    var tx = fx.texts();
    _ = tx.push(0, .{ .start = 0, .bytes = 4 }, &.{ .px = 10 });
    const font: MonoParagraphs = .{ .mono = .{ .advance = 0.5, .line = 1.2 }, .rows = &.{0}, .styles = &.{0}, .table = &.{.{ .letter_spacing = 1 }}, .strings = "abcd" };
    font.measure(&tx);
    tx.c.avail[0] = 12;
    font.wrap(&tx);
    // Laid out 60 px tall and 12 px wide by its box, not by its text: still one line.
    var runs = [_]draw_list.TextRun{.{ .rect = .{ 0, 0, 12, 60 }, .clip = .{ 0, 0, 100, 100 }, .start = 0, .bytes = 4, .px = 10, .color = 1, .font = 0 }};
    var d = testList(&runs, "abcd");
    var out: [8]Quad = undefined;
    var first: [1]u32 = undefined;
    var count: [1]u32 = undefined;
    _ = font.quads(&d, &tx, &out, .{ .first = &first, .count = &count });
    for (out[0..4], 0..) |q, j| try testing.expectEqual(@as(f32, @floatFromInt(j)) * 6, q.rect[0]);
    for (out[0..4]) |q| try testing.expectEqual(@as(f32, 0), q.rect[1]);
}
