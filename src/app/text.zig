//! The window layer's text: font files in, measured runs and a frame's glyph quads over one
//! coverage atlas out. It joins the tier-0 text stack (opentype, shape, fallback, text_stack,
//! raster, raster_atlas; docs/guide/text.md) into the three calls a window makes:
//!
//!     var text = try Text.init(buffer, .{}, &.{.{ .bytes = @embedFile("Inter.ttf") }});
//!     const out = f.endText(&text.stack, text.ascent);       // measure and wrap, logical px
//!     const frame = text.glyphs(out.draw, out.texts, scale);  // quads at physical pixels
//!     // upload frame.dirty of frame.atlas (or sample it: sw.Image.alpha8), then draw with
//!     // frame.glyphs, its `texture` set to the handle the atlas is registered as.
//!
//! Font k of a run (`TextStyle.font`) is file k. Every face is in every run's fallback chain,
//! the run's own first, so a character its face lacks draws from the next face that has it.
//! `systemFiles` finds the system's default faces (proportional, then monospace where the
//! platform says which) and `cover` adds a system face for a character no face has.
//!
//! Glyph images are rasterised at the physical size (px times scale), each glyph's pen on a
//! quarter of a physical pixel (raster.subpixel_bins) and its baseline on a whole one, and
//! keep their place in the atlas while it lives: only new images change texels (`dirty`).
//! When the atlas or its table is full, or the scale changes, the atlas starts again empty and
//! `generation` moves on: every texel and every quad of an earlier frame is then stale. Equal
//! generations and equal draw lists give equal glyph quads, which is what lets a host that
//! keeps last frame's pixels skip the text that did not change.
//!
//! Tier 3, the window layer (src/app/): it reads font files and asks the OS for faces. Every
//! table is carved from the caller's buffer (`requiredBytes`); nothing allocates per frame.
//! Loading a face file uses the caller's allocator, once per face. Cites docs/plans/window.md,
//! stage 4.
//!
//! Contents
//!   pub const Options = struct
//!   pub const File = struct
//!   pub const Frame = struct
//!   pub const Side = struct
//!   pub const Text = struct
//!     pub fn requiredBytes(o: Options) usize
//!     pub fn init(buf: []align(64) u8, o: Options, files: []const File) InitError!Text
//!     pub fn addFace(t: *Text, file: File) InitError!void
//!     pub fn glyphs(t: *Text, d: *const DrawList, tx: *const Texts, scale: f32) Frame
//!     pub fn glyphsOf(t: *Text, d: *const DrawList, sides: []const Side, scale: f32) Frame
//!     pub fn addSystemDefaults(t: *Text, gpa: Allocator, io: Io, d: *Discovery) !void
//!     pub fn cover(t: *Text, gpa: Allocator, io: Io, d: *Discovery, text: []const u8) !u32
//!     pub fn deinit(t: *Text, gpa: Allocator) void
//!   pub const Discovery = system.Discovery
//!   pub const can_discover: bool
//!   pub const labels = @import("labels.zig")

const std = @import("std");
const builtin = @import("builtin");
const lcgf = @import("lcgf");
const system = @import("font_system");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const mem = lcgf.mem;
const opentype = lcgf.opentype;
const shape = lcgf.shape;
const raster = lcgf.raster;
const fallback = lcgf.fallback;
const text_stack = lcgf.text_stack;
const text_lines = lcgf.text_lines;
const DrawList = lcgf.draw_list.DrawList;
const TextRun = lcgf.draw_list.TextRun;
const Quad = lcgf.draw_list.Quad;
const Texts = lcgf.texts.Texts;
const Strings = lcgf.strings.Strings;
const Atlas = lcgf.raster_atlas.Atlas;
const Image = text_stack.emit.Image;

/// Capacities: every table the service keeps is this size, whatever a frame uses.
pub const Options = struct {
    /// Width and height of the coverage atlas, one byte a texel.
    atlas: [2]u32 = .{ 1024, 1024 },
    /// Glyph images the atlas's table holds (at one size and subpixel position each).
    images: u32 = 4096,
    /// Faces: the files given to `init` plus those `addFace` adds. At most 32.
    faces: u32 = 8,
    /// Text runs of a frame: the frame's `Limits.texts`.
    texts: u32 = 256,
    /// Glyph quads of a frame.
    quads: u32 = 8192,
    /// Glyphs and lines of the longest run; a longer run is measured as empty.
    run_glyphs: u32 = 1024,
    run_lines: u32 = 128,
    /// Runs of one face and script inside one text run (fallback).
    run_faces: u32 = 64,
    /// Extents kept across frames (`text_stack.Extents`): slots, a power of two, about four
    /// times the runs a frame measures (a wrapping run takes two).
    extents: u32 = 2048,
    /// The shaping cache: slots (a power of two) of up to `cached_glyphs` glyphs each.
    shape_slots: u32 = 256,
    cached_glyphs: u32 = 64,
    /// Largest em in physical pixels a glyph is rasterised at; a larger glyph draws nothing.
    glyph_px_max: u32 = 96,
    /// Points and contours of the most complex glyph outline.
    outline_points: u32 = 2048,
    outline_contours: u32 = 256,
    /// Style spans of a frame's text leaves drawn in several styles (`Frame.textSpans`), all
    /// leaves together; past them the leaves are drawn plain (`Stack.overflow`).
    spans: u32 = 256,
};

/// A font file's bytes (`@embedFile`, or read from disk) and the face's index in it, non-zero
/// only in a collection. The bytes must outlive the `Text`.
pub const File = struct { bytes: []const u8, index: u32 = 0 };

/// One frame's glyphs: what a back end draws and the atlas it samples.
pub const Frame = struct {
    /// Quads, and where each run's are. `texture` is `.white`: the caller sets the handle it
    /// registered the atlas as. Valid until the next `glyphs`.
    glyphs: lcgf.render_iface.Glyphs,
    /// The coverage texture, `w * h` bytes, row by row: a software back end samples it
    /// (`sw.Image.alpha8`), a GPU back end keeps a copy.
    atlas: *const Atlas,
    /// The region of `atlas` that changed since the last frame, the whole of it after a
    /// reset; null when nothing changed. Upload it before drawing.
    dirty: ?Atlas.Upload,
    /// Moves on when the atlas started again empty: no texel or quad of an earlier frame is
    /// valid. The same generation and the same draw list give the same quads.
    generation: u32,
    /// The window's canvas label atlas (`Window.labels`), what `Glyphs.canvas` names, and its
    /// region changed since the last frame (all of it at first); null without labels.
    labels: ?*const Atlas = null,
    labels_dirty: ?Atlas.Upload = null,
};

/// The rows behind a run of a draw list: of one front end's frame, or of one side of a list
/// `ct_interop.compose` joined. `tx` is the `Texts` the side's runs were measured in (row k is
/// the draw list's run `first_run + k`) and `strings` the bytes its rows index: the side's own
/// list's `strings`, before the compose moved them.
pub const Side = struct { tx: *const Texts, strings: []const u8, first_run: u32 = 0 };

pub const InitError = opentype.Error || error{TooManyFaces};

/// The platform's font discovery (src/text/fallback/system.zig): fontconfig, DirectWrite or
/// Core Text, opened at run time.
pub const Discovery = system.Discovery;

/// Whether this build can ask the OS for fonts. On Linux fontconfig is a C library opened
/// with libc's dynamic loader, so a build without libc (lcgf_app's today) cannot: it draws
/// with the application's files or the bundled bitmap font.
pub const can_discover = builtin.os.tag != .linux or builtin.link_libc;

/// Canvas labels in these faces over a distance atlas (src/app/labels.zig).
pub const labels = @import("labels.zig");

/// The glyph quads of list `d` in the bundled bitmap font (`render_sw_font.glyphs`); a frame's
/// leaves with spans (`Frame.textSpans`) in their spans' sizes and colours, as `Bitmap.end`
/// laid them out, when `d` is `ctx`'s list of this frame.
pub fn bitmapGlyphs(
    ctx: *Context,
    d: *const DrawList,
    quads: []Quad,
    first: []u32,
    count: []u32,
) lcgf.render_iface.Glyphs {
    const font = lcgf.render_sw_font;
    const s = ctx.spanned orelse return font.glyphs(d, quads, first, count);
    if (s.len == 0 or d != &ctx.draw) return font.glyphs(d, quads, first, count);
    var p = s.mono();
    p.strings = d.strings;
    const n = p.quads(d, &ctx.texts[ctx.cur], quads, .{ .first = first, .count = count });
    return .{ .quads = quads[0..n], .first = first, .count = count, .texture = font.texture };
}

pub const Text = struct {
    /// Shapes, measures and wraps every run whose font is a face here, in logical pixels: the
    /// stack `Frame.endText` takes.
    stack: text_stack.Stack,
    /// One row per run: its first baseline, written by measure and wrap (`Frame.endText`).
    ascent: []f32,
    /// The rows `Frame.endTextStyled` points the stack at for a frame's leaves with spans,
    /// and its scratch for their decorations (`end`).
    styled: text_stack.StyledRows,
    rects: []lcgf.types.Rect,
    faces: []opentype.Face,
    shapers: []shape.Shaper,
    /// Chain f lists every face, f first; `order` holds the lists, `faces` rows each.
    chains: []fallback.Chain,
    order: []u16,
    face_len: u32 = 0,
    atlas: Atlas,
    /// Open-addressed table of glyph images: key (0 empty) and where its image is.
    keys: []u32,
    slots: []Slot,
    image_len: u32 = 0,
    image_cap: u32,
    /// Physical pixel sizes seen since the atlas was last reset; a key holds the index.
    sizes: []f32,
    size_len: u32 = 0,
    outline: opentype.Outline,
    acc: []f32,
    cov: []u8,
    images: []Image,
    /// This frame's glyph quads, and last frame's: a run whose key (`runKey`) matches one of
    /// last frame's is copied from there, not laid out and placed again. The two swap each
    /// frame, so the quads `glyphs` returns stay valid until the frame after next.
    quads: []Quad,
    kept_quads: []Quad,
    /// Open-addressed tables of run keys (0 empty) to `{ first, count }` in `quads` and in
    /// `kept_quads`; they swap with them.
    run_keys: []u64,
    run_at: [][2]u32,
    kept_keys: []u64,
    kept_at: [][2]u32,
    /// Extents kept across frames for the stack's measure and wrap, in the caller's buffer.
    extents: *text_stack.Extents,
    first: []u32,
    count: []u32,
    scale: f32 = 0,
    generation: u32 = 0,
    /// A run, glyph or frame did not fit a capacity of `Options` and was drawn short. Reset by
    /// the caller.
    overflow: bool = false,
    /// Font files read from disk (`addSystemDefaults`, `cover`), freed by `deinit`.
    loaded: [][]u8,
    loaded_len: u32 = 0,
    /// Characters no system face had, so `cover` does not ask again: a ring.
    missing: []u21,
    /// Characters remembered so far; the next goes to `missing_at % missing.len`.
    missing_at: u32 = 0,

    /// Bytes of the buffer `init` carves for `o`.
    pub fn requiredBytes(o: Options) usize {
        @setEvalBranchQuota(10_000);
        var counter: mem.Carver = .{ .buf = null };
        _ = carve(&counter, o);
        return counter.off;
    }

    /// A service over `buf` (`requiredBytes(o)` bytes, which it keeps) with `files` as fonts 0,
    /// 1, ... Fails when a file is not a TrueType or OpenType face this stack reads, or when
    /// there are more files than `o.faces`. No files is allowed: the stack then serves no run.
    pub fn init(buf: []align(mem.column_align) u8, o: Options, files: []const File) InitError!Text {
        std.debug.assert(buf.len >= requiredBytes(o));
        std.debug.assert(o.faces <= 32);
        std.debug.assert(std.math.isPowerOfTwo(o.shape_slots));
        var c: mem.Carver = .{ .buf = buf };
        var t = carve(&c, o);
        for (files) |f| try t.addFace(f);
        std.debug.assert(t.face_len == files.len);
        return t;
    }

    /// Adds `file` as the next font. Runs already measured keep their extent; the next frame
    /// may draw characters from it that no face had.
    pub fn addFace(t: *Text, file: File) InitError!void {
        if (t.face_len == t.faces.len) return error.TooManyFaces;
        const offset = try opentype.faceOffset(file.bytes, file.index);
        const face = try opentype.Face.parse(file.bytes, offset);
        t.faces[t.face_len] = face;
        t.shapers[t.face_len] = .init(face);
        t.face_len += 1;
        const n = t.face_len;
        const cap = t.faces.len;
        for (0..n) |f| {
            const row = t.order[f * cap ..][0..n];
            row[0] = @intCast(f);
            var at: usize = 1;
            for (0..n) |other| if (other != f) {
                row[at] = @intCast(other);
                at += 1;
            };
            t.chains[f] = .{ .faces = t.faces[0..n], .default = row };
        }
        t.stack.shapers = t.shapers[0..n];
        t.stack.fallback.?.chain = &t.chains[0];
        t.stack.fallback.?.by_font = t.chains[0..n];
        std.debug.assert(t.stack.fallback.?.metrics.len >= n);
        // A run measured before may draw from this face now: no kept extent or run holds.
        t.extents.generation +%= 1;
    }

    /// Ends frame `f` with the service's stack: `Frame.endTextStyled` when the frame has
    /// leaves with spans (`Frame.textSpans`, each span's `TextStyle.font` a face here), else
    /// `Frame.endText`, the stack's styles of an earlier frame dropped.
    pub fn end(t: *Text, f: *lcgf.frame.Frame) lcgf.context.Output {
        if (f.ctx.spanned) |s| if (s.len > 0) {
            const styled = s.styled(t.stack.default_paragraph);
            return f.endTextStyled(&t.stack, t.ascent, styled, t.styled, t.rects);
        };
        t.stack.paragraphs = &.{};
        t.stack.rich = &.{};
        return f.endText(&t.stack, t.ascent);
    }

    /// The glyph quads of every text run `d` draws (draw-list run k is `tx` row k, as
    /// `Frame.endText` left them), placed at `scale` physical pixels per logical pixel.
    /// Rasterises the images no earlier frame left in the atlas. Asserts `scale` is positive
    /// and finite and `d` has no more runs than `Options.texts`.
    pub fn glyphs(t: *Text, d: *const DrawList, tx: *const Texts, scale: f32) Frame {
        return t.glyphsOf(d, &.{.{ .tx = tx, .strings = d.strings }}, scale);
    }

    /// `glyphs` of a list whose runs come from several frames (`ct_interop.compose`): run k is
    /// row `k - first_run` of the last side whose `first_run` is at most k. Each side was
    /// measured through `stack`; the glyphs are placed at the list's runs, where the compose
    /// moved them. Asserts the sides are in order, the first at run 0.
    pub fn glyphsOf(t: *Text, d: *const DrawList, sides: []const Side, scale: f32) Frame {
        std.debug.assert(scale > 0);
        std.debug.assert(std.math.isFinite(scale));
        std.debug.assert(d.run_len <= t.first.len);
        std.debug.assert(sides.len > 0);
        std.debug.assert(sides[0].first_run == 0);
        if (scale != t.scale) t.reset(scale);
        const n = t.placeRuns(d, sides, .reset) catch blk: {
            t.reset(scale);
            // tidy: allow(swallowed-error) a pass that drops what does not fit never fails
            break :blk t.placeRuns(d, sides, .drop) catch unreachable;
        };
        std.debug.assert(n <= t.quads.len);
        const runs = d.run_len;
        const frame: Frame = .{
            .glyphs = .{
                .quads = t.quads[0..n],
                .first = t.first[0..runs],
                .count = t.count[0..runs],
            },
            .atlas = &t.atlas,
            .dirty = t.atlas.takeDirty(),
            .generation = t.generation,
        };
        std.mem.swap([]Quad, &t.quads, &t.kept_quads);
        std.mem.swap([]u64, &t.run_keys, &t.kept_keys);
        std.mem.swap([][2]u32, &t.run_at, &t.kept_at);
        return frame;
    }

    /// Adds the system's default faces as the next two fonts: the proportional face, then the
    /// monospace one where the platform names it (fontconfig's "monospace"), else the
    /// proportional face again, so a run in font 1 is still measured. Each file is read into
    /// memory from `gpa`, once, and freed by `deinit`. Fails when no face is found
    /// (`error.NoSystemFont`), a file cannot be read, or the faces do not fit `Options.faces`.
    pub fn addSystemDefaults(t: *Text, gpa: Allocator, io: Io, d: *Discovery) !void {
        comptime std.debug.assert(can_discover);
        const before = t.face_len;
        var path: [4096]u8 = undefined;
        const sans = (try d.find('a', &path)) orelse return error.NoSystemFont;
        const file = try t.load(gpa, io, sans);
        const named = comptime @hasDecl(Discovery, "findFamily");
        const mono = if (named) try d.findFamily('a', "monospace", &path) else null;
        if (mono) |found| _ = try t.load(gpa, io, found) else try t.addFace(file);
        std.debug.assert(t.face_len == before + 2);
    }

    /// Adds, for each character of `text` that no face has, the system face that draws it
    /// (`Discovery.find`), so the next frame draws it instead of a box. A character the system
    /// has no face for is remembered and not asked again. Returns the faces added. Reads each
    /// new file from `gpa`, freed by `deinit`. Call it with a frame's strings before its
    /// `endText`: ASCII costs a byte compare, other text a cmap lookup per face.
    pub fn cover(t: *Text, gpa: Allocator, io: Io, d: *Discovery, text: []const u8) !u32 {
        comptime std.debug.assert(can_discover);
        const before = t.face_len;
        var path: [4096]u8 = undefined;
        var i: usize = 0;
        while (i < text.len) {
            if (text[i] < 0x80) {
                i += 1;
                continue;
            }
            const c = lcgf.unicode_utf8.decode(text, i);
            i += c.len;
            const asked = t.missing[0..@min(t.missing_at, t.missing.len)];
            if (t.has(c.cp) or std.mem.indexOfScalar(u21, asked, c.cp) != null) continue;
            const found = (try d.find(c.cp, &path)) orelse {
                t.remember(c.cp);
                continue;
            };
            if (t.face_len == t.faces.len) return error.TooManyFaces;
            _ = try t.load(gpa, io, found);
            // The face found may lack it after all (Core Text answers every character).
            // ponytail: such a face is loaded anyway; compare paths first if it wastes faces.
            if (!t.has(c.cp)) t.remember(c.cp);
        }
        std.debug.assert(t.face_len >= before);
        return t.face_len - before;
    }

    /// Frees the files `addSystemDefaults` and `cover` read. The faces read from them are
    /// invalid afterwards.
    pub fn deinit(t: *Text, gpa: Allocator) void {
        for (t.loaded[0..t.loaded_len]) |bytes| gpa.free(bytes);
        t.loaded_len = 0;
    }

    // ---- private ----

    /// Whether some face has a glyph for `cp`.
    fn has(t: *const Text, cp: u21) bool {
        for (t.faces[0..t.face_len]) |f| if (f.cmap.glyph(cp) != 0) return true;
        return false;
    }

    fn remember(t: *Text, cp: u21) void {
        std.debug.assert(t.missing.len > 0);
        t.missing[t.missing_at % t.missing.len] = cp;
        t.missing_at +%= 1;
    }

    /// Reads the file of `found` and adds its face.
    fn load(t: *Text, gpa: Allocator, io: Io, found: system.Found) !File {
        std.debug.assert(t.loaded_len < t.loaded.len);
        const bytes = try Io.Dir.cwd().readFileAlloc(io, found.path, gpa, .limited(256 << 20));
        errdefer gpa.free(bytes);
        const index = if (found.name.len > 0)
            (try fallback.faceByName(bytes, found.name)) orelse return error.NoSuchFace
        else
            found.index;
        const file: File = .{ .bytes = bytes, .index = index };
        try t.addFace(file);
        t.loaded[t.loaded_len] = bytes;
        t.loaded_len += 1;
        return file;
    }

    /// What a glyph image that does not fit does: start the atlas again, or draw nothing.
    const WhenFull = enum { reset, drop };

    /// Empties the atlas for glyphs at `scale`: every image is rasterised again.
    fn reset(t: *Text, scale: f32) void {
        t.atlas.clear();
        @memset(t.keys, 0);
        t.image_len = 0;
        t.size_len = 0;
        t.scale = scale;
        t.generation +%= 1;
    }

    fn placeRuns(
        t: *Text,
        d: *const DrawList,
        sides: []const Side,
        full: WhenFull,
    ) error{Full}!u32 {
        @memset(t.first[0..d.run_len], 0);
        @memset(t.count[0..d.run_len], 0);
        @memset(t.run_keys, 0);
        var n: u32 = 0;
        for (0..d.cmd_len) |i| {
            const k = switch (d.command(@intCast(i))) {
                .text => |k| k,
                else => continue,
            };
            const side = sideOf(sides, k);
            const tx = side.tx;
            const row = k - side.first_run;
            std.debug.assert(row < tx.len);
            // A run drawn by two commands is placed once.
            if (t.count[k] != 0 or !t.stack.serves(tx, row)) continue;
            const key = t.runKey(d, tx, k, row);
            if (find(t.kept_keys, key)) |at| {
                // Unchanged since last frame: its quads, copied.
                const span = t.kept_at[at];
                if (span[1] > t.quads.len - n) {
                    t.overflow = true;
                    continue;
                }
                @memcpy(t.quads[n..][0..span[1]], t.kept_quads[span[0]..][0..span[1]]);
                t.keep(key, n, span[1]);
                t.first[k] = n;
                t.count[k] = span[1];
                n += span[1];
                continue;
            }
            // The row's bytes are its side's strings, which Stack reads as a frame's Strings.
            const strings = stringsOf(side);
            t.stack.paragraph(tx, &strings, row) catch {
                t.overflow = true;
                continue;
            };
            const run = d.runs[k];
            const ellipsis = try t.paragraphImages(run, full);
            const images: text_stack.emit.Images = .{
                .glyphs = t.images[0..t.stack.g.len],
                .ellipsis = ellipsis,
            };
            const wrote = t.stack.quads(run, images, t.quads[n..]) catch {
                t.overflow = true;
                continue;
            };
            t.keep(key, n, wrote);
            t.first[k] = n;
            t.count[k] = wrote;
            n += wrote;
        }
        return n;
    }

    /// The side run `k` of the list belongs to: the last that starts at or before it.
    fn sideOf(sides: []const Side, k: u32) Side {
        var at: usize = 0;
        for (sides, 0..) |side, i| at = if (side.first_run <= k) i else at;
        std.debug.assert(sides[at].first_run <= k);
        return sides[at];
    }

    /// What run `k`'s quads depend on: its bytes, its draw-list row (rect, clip, size, colour,
    /// font, transform), the width layout gave it, the scale, the atlas generation and the
    /// faces. Its place in `strings` is not part of it.
    fn runKey(t: *const Text, d: *const DrawList, tx: *const Texts, k: u32, row: u32) u64 {
        var run = d.runs[k];
        const bytes = d.strings[run.start..][0..run.bytes];
        run.start = 0;
        const scale: u32 = @bitCast(t.scale);
        const avail: u32 = @bitCast(tx.c.avail[row]);
        const wrap: u32 = @bitCast(tx.c.wrap[row]);
        const words = [3]u64{ t.generation, t.extents.generation, (@as(u64, scale) << 32) | avail };
        var hash: std.hash.Wyhash = .init(wrap);
        hash.update(std.mem.asBytes(&words));
        hash.update(std.mem.asBytes(&run));
        hash.update(bytes);
        return hash.final() | 1;
    }

    /// Records this frame's run `key` at `{ first, count }` of `quads`. A second run with the
    /// same key (the same text drawn twice at one place) replaces the first's, which is equal.
    fn keep(t: *Text, key: u64, first: u32, count: u32) void {
        const mask = t.run_keys.len - 1;
        var at: usize = @intCast((key >> 1) & mask);
        var probes: usize = 0;
        while (t.run_keys[at] != 0 and t.run_keys[at] != key) : (at = (at + 1) & mask) {
            probes += 1;
            std.debug.assert(probes < t.run_keys.len); // twice the runs: never full
        }
        t.run_keys[at] = key;
        t.run_at[at] = .{ first, count };
    }

    /// The image of every inked glyph of the stack's paragraph at its pen in `run`, the pen
    /// computed as `emit.quads` computes it; and the ellipsis's when the text was cut.
    fn paragraphImages(t: *Text, run: TextRun, full: WhenFull) error{Full}!?Image {
        const st = &t.stack;
        const g = &st.g;
        const l = &st.l;
        std.debug.assert(g.len <= t.images.len);
        for (0..l.len) |k| for (l.first[k]..l.ink[k]) |i| {
            const pen: [2]f32 = .{
                run.rect[0] + l.x[k] + g.x[i] + g.x_offset[i],
                run.rect[1] + l.baseline[k] - g.y_offset[i],
            };
            t.images[i] = try t.place(g.fontAt(i), g.glyph[i], st.pxAt(i), pen, full);
        };
        if (l.len == 0 or l.ellipsis == 0) return null;
        const k = l.len - 1;
        const pen: [2]f32 = .{ run.rect[0] + l.x[k] + l.ellipsis_x, run.rect[1] + l.baseline[k] };
        return try t.place(st.ellipsis_font, st.ellipsis_glyph, st.ellipsis_px, pen, full);
    }

    /// Glyph `glyph` of face `font` at `px` logical pixels, its pen at `pen`: the image
    /// snapped to the physical pixel grid, as bounds relative to the pen in logical pixels.
    fn place(
        t: *Text,
        font: u16,
        glyph: u16,
        px: f32,
        pen: [2]f32,
        full: WhenFull,
    ) error{Full}!Image {
        const s = t.scale;
        std.debug.assert(s > 0);
        const p = raster.pen(pen[0] * s);
        const base: i32 = @intFromFloat(@floor(pen[1] * s + 0.5));
        const slot = t.image(font, glyph, px * s, p.bin) catch |e| switch (full) {
            .reset => return e,
            .drop => {
                t.overflow = true;
                return .{};
            },
        };
        if (slot.w == 0) return .{};
        const x0: f32 = @floatFromInt(p.pixel + slot.left);
        const y0: f32 = @floatFromInt(base - slot.top);
        const rect: Atlas.Rect = .{ .x = slot.x, .y = slot.y, .w = slot.w, .h = slot.h };
        return .{
            .bounds = .{
                x0 / s - pen[0],
                y0 / s - pen[1],
                (x0 + @as(f32, @floatFromInt(slot.w))) / s - pen[0],
                (y0 + @as(f32, @floatFromInt(slot.h))) / s - pen[1],
            },
            .uv = t.atlas.uv(rect),
        };
    }

    /// The atlas slot of an image, rasterised into the atlas when no earlier glyph made it.
    /// `error.Full` when the atlas, its table or the size list has no room.
    fn image(t: *Text, font: u16, glyph: u16, px: f32, bin: u32) error{Full}!Slot {
        const size = for (t.sizes[0..t.size_len], 0..) |v, i| {
            if (v == px) break i;
        } else blk: {
            if (t.size_len == t.sizes.len) return error.Full;
            t.sizes[t.size_len] = px;
            t.size_len += 1;
            break :blk t.size_len - 1;
        };
        // Bit 31 marks a used slot: faces are fewer than 32.
        const key = lcgf.raster_atlas.key(font, glyph, @intCast(size), bin) | (1 << 31);
        const mask: u32 = @intCast(t.keys.len - 1);
        var at = ((key *% 0x9e37_79b1) >> 7) & mask;
        var probes: u32 = 0;
        while (t.keys[at] != 0) : (at = (at + 1) & mask) {
            if (t.keys[at] == key) return t.slots[at];
            probes += 1;
            std.debug.assert(probes <= mask);
        }
        if (t.image_len == t.image_cap) return error.Full;
        const slot = try t.rasterise(font, glyph, px, bin);
        t.keys[at] = key;
        t.slots[at] = slot;
        t.image_len += 1;
        return slot;
    }

    /// Rasterises the image into a new place in the atlas; an empty slot for a glyph with no
    /// ink, and for one too large or complex for the scratch (`overflow`).
    fn rasterise(t: *Text, font: u16, glyph: u16, px: f32, bin: u32) error{Full}!Slot {
        const face = &t.faces[font];
        t.outline.points = 0;
        t.outline.contours = 0;
        face.outline(glyph, &t.outline) catch {
            t.overflow = true;
            return .{};
        };
        const scale = px / @as(f32, @floatFromInt(face.units_per_em));
        const dx = raster.shift(bin);
        const b = raster.box(&t.outline, scale, dx);
        if (b.w == 0 or b.h == 0) return .{};
        // The scratch is square and smaller than 2^16 on a side, so this bounds w and h too.
        if (raster.accLen(b) > t.acc.len or raster.imageLen(b) > t.cov.len) {
            t.overflow = true;
            return .{};
        }
        // A texel of gap, so a GPU's bilinear sampler never reads the neighbour.
        const r = t.atlas.pack(b.w + 1, b.h + 1) orelse return error.Full;
        raster.fill(&t.outline, scale, dx, b, t.acc);
        raster.coverage(t.acc, t.cov, @as(usize, b.w) * b.h);
        t.atlas.put(.{ .x = r.x, .y = r.y, .w = b.w, .h = b.h }, t.cov);
        std.debug.assert(r.x + b.w <= t.atlas.w);
        return .{
            .x = @intCast(r.x),
            .y = @intCast(r.y),
            .w = @intCast(b.w),
            .h = @intCast(b.h),
            .left = @intCast(b.left),
            .top = @intCast(b.top),
        };
    }
};

const Context = lcgf.context.Context;

/// `Window` when the service can ever serve (it has font files, or the build can ask the
/// system for faces), else `Bitmap`: then no code of the service is in the program.
pub fn WindowOf(comptime serves: bool) type {
    return if (serves) Window else Bitmap;
}

/// A window's text in the bundled bitmap font: `Window`'s calls, none of the service's code.
pub const Bitmap = struct {
    pub fn open(_: []u8, _: Options, files: []const File, _: bool, _: Allocator, _: Io) !Bitmap {
        std.debug.assert(files.len == 0);
        return .{};
    }

    pub fn close(_: *Bitmap) void {}

    pub fn on(_: *const Bitmap) bool {
        return false;
    }

    /// Ends frame `f` in the bundled font: its leaves with spans (`Frame.textSpans`) through
    /// `MonoParagraphs`, in their spans' sizes and colours.
    pub fn end(_: *Bitmap, f: *lcgf.frame.Frame) lcgf.context.Output {
        if (f.ctx.spanned) |s| if (s.len > 0) return f.endParagraphs(s.mono());
        return f.end(.{});
    }

    /// Never called: `on` is false.
    pub fn glyphs(_: *Bitmap, _: *Context, _: *const lcgf.context.Output, _: f32) Frame {
        unreachable;
    }

    /// Never called: `on` is false.
    pub fn glyphsOf(_: *Bitmap, _: *Context, _: *const DrawList, _: []const Side, _: f32) Frame {
        unreachable;
    }
};

/// The text of a window `lcgf_app` runs: the service over the application's font files, else
/// over the system's default faces where the build can ask for them (`can_discover`), else
/// none, and the window draws with the bundled bitmap font as before. Each frame, `end`
/// measures and lays it out and `glyphs` places its glyphs at the window's scale.
pub const Window = struct {
    /// Null when there is nothing to serve: no file and no way to ask the system, so the
    /// buffer is never carved and its pages never touched (3 MB of a default service).
    text: ?Text,
    discovery: if (can_discover) ?Discovery else void,
    gpa: Allocator,
    io: Io,
    /// The generation of the last frame's glyphs.
    generation: ?u32 = null,
    /// The canvas label atlas, set by `lcgf_app.run` for an App with labels, and the
    /// generation of the last frame's.
    labels: ?*labels.Labels = null,
    label_generation: u32 = 0,

    /// The service over `buf` (`Text.requiredBytes(o)`) with `files`, else, when `discover`
    /// and the build can, the system's default faces. Fails when a file is not a face this
    /// stack reads; a system without fonts (or fontconfig) leaves the window on the bitmap
    /// font. `gpa` reads system font files, once each.
    pub fn open(
        buf: []align(mem.column_align) u8,
        o: Options,
        files: []const File,
        discover: bool,
        gpa: Allocator,
        io: Io,
    ) InitError!Window {
        // No fontconfig, DirectWrite or Core Text: no system faces, and the bitmap font.
        const ask = can_discover and discover;
        const found: ?Discovery = if (ask) Discovery.init() catch null else null;
        var w: Window = .{
            .text = if (files.len > 0 or found != null) try Text.init(buf, o, files) else null,
            .discovery = if (can_discover) found else {},
            .gpa = gpa,
            .io = io,
        };
        if (can_discover) if (w.discovery) |*d| if (files.len == 0) {
            // tidy: allow(swallowed-error) a system with no default face draws the bitmap font
            w.text.?.addSystemDefaults(gpa, io, d) catch {};
        };
        if (w.text) |t| std.debug.assert(t.face_len >= files.len);
        return w;
    }

    pub fn close(w: *Window) void {
        if (w.text) |*t| t.deinit(w.gpa);
        if (can_discover) if (w.discovery) |*d| d.deinit();
    }

    /// Whether the window draws with the service (it has a face), not the bitmap font.
    pub fn on(w: *const Window) bool {
        return if (w.text) |t| t.face_len > 0 else false;
    }

    /// Ends frame `f`: through the service when `on` (`Text.end`), else in the bundled font
    /// (`Bitmap.end`).
    pub fn end(w: *Window, f: *lcgf.frame.Frame) lcgf.context.Output {
        if (!w.on()) {
            var b: Bitmap = .{};
            return b.end(f);
        }
        return w.text.?.end(f);
    }

    /// `Text.glyphs` of `out` at `scale`. When the atlas started again, or a character of the
    /// frame no face had brought a new face (`cover`), `ctx` redraws the whole window in a
    /// frame of its own, at once. Asserts `on`.
    pub fn glyphs(w: *Window, ctx: *Context, out: *const lcgf.context.Output, scale: f32) Frame {
        const sides = [_]Side{.{ .tx = out.texts, .strings = out.draw.strings }};
        return w.glyphsOf(ctx, out.draw, &sides, scale);
    }

    /// `glyphs` of a list joined from `sides` (`Text.glyphsOf`).
    pub fn glyphsOf(
        w: *Window,
        ctx: *Context,
        d: *const DrawList,
        sides: []const Side,
        scale: f32,
    ) Frame {
        std.debug.assert(w.on());
        const t = &w.text.?;
        const frame = t.glyphsOf(d, sides, scale);
        var again = if (w.generation) |g| g != frame.generation else false;
        w.generation = frame.generation;
        var placed = frame;
        if (w.labels) |l| {
            placed.labels = &l.atlas;
            placed.labels_dirty = l.atlas.takeDirty();
            // A new label atlas: canvases with labels not yet made again sample nothing.
            again = again or l.generation != w.label_generation;
            w.label_generation = l.generation;
        }
        if (can_discover) if (w.discovery) |*found| {
            again = again or (t.cover(w.gpa, w.io, found, d.strings) catch 0) > 0;
        };
        if (again) {
            ctx.redrawAll();
            ctx.waker.post();
        }
        return placed;
    }
};

/// Where a glyph image is in the atlas, and its box relative to the pen's pixel
/// (`raster.Box`). `w == 0`: no ink.
const Slot = struct {
    x: u16 = 0,
    y: u16 = 0,
    w: u16 = 0,
    h: u16 = 0,
    left: i16 = 0,
    top: i16 = 0,
};

// ---- private ----

/// The service's tables, carved in one order for sizing and for use.
fn carve(c: *mem.Carver, o: Options) Text {
    std.debug.assert(o.images > 0);
    // Slot holds places in u16.
    std.debug.assert(o.atlas[0] < 1 << 16);
    std.debug.assert(o.atlas[1] < 1 << 16);
    const table = std.math.ceilPowerOfTwoAssert(u32, 2 * o.images);
    // The largest box a glyph of `glyph_px_max` has: wide glyphs reach about 2 em.
    const side: u32 = 2 * o.glyph_px_max + 2;
    const scratch: raster.Box = .{ .w = side, .h = side };
    // Twice the runs, so the run tables never fill.
    const runs = std.math.ceilPowerOfTwoAssert(u32, 2 * o.texts);
    // In the buffer, not in `Text`, so the stack's pointer to it survives a move of `Text`.
    const extents = c.slice(text_stack.Extents, 1);
    const kept: text_stack.Extents = .{
        .key = c.slice(u64, o.extents),
        .w = c.slice(f32, o.extents),
        .h = c.slice(f32, o.extents),
        .ascent = c.slice(f32, o.extents),
    };
    if (extents.len > 0) extents[0] = kept;
    const atlas_pixels = c.slice(u8, @as(usize, o.atlas[0]) * o.atlas[1]);
    const sky: Atlas.Skyline = .{
        .x = c.slice(u32, o.atlas[0]),
        .y = c.slice(u32, o.atlas[0]),
        .w = c.slice(u32, o.atlas[0]),
    };
    var t: Text = .{
        .stack = carveStack(c, o),
        .ascent = c.slice(f32, o.texts),
        .styled = .{
            .paragraphs = c.slice(text_stack.Paragraph, o.texts),
            .rich = c.slice(?text_stack.Rich, o.texts),
            .spans = c.slice(lcgf.text_spans.Spans, o.texts),
            .start = c.slice(u32, o.spans + o.texts),
            .font = c.slice(u16, o.spans + o.texts),
            .px = c.slice(f32, o.spans + o.texts),
            .color = c.slice(u32, o.spans + o.texts),
            .metrics = c.slice(text_lines.Metrics, o.spans + 1),
        },
        .rects = c.slice(lcgf.types.Rect, o.run_glyphs),
        .faces = c.slice(opentype.Face, o.faces),
        .shapers = c.slice(shape.Shaper, o.faces),
        .chains = c.slice(fallback.Chain, o.faces),
        .order = c.slice(u16, @as(usize, o.faces) * o.faces),
        .atlas = undefined,
        .keys = c.slice(u32, table),
        .slots = c.slice(Slot, table),
        .image_cap = o.images,
        .sizes = c.slice(f32, 256),
        .outline = .{
            .x = c.slice(f32, o.outline_points),
            .y = c.slice(f32, o.outline_points),
            .on = c.slice(bool, o.outline_points),
            .ends = c.slice(u32, o.outline_contours),
        },
        .acc = c.slice(f32, raster.accLen(scratch)),
        .cov = c.slice(u8, raster.imageLen(scratch)),
        .images = c.slice(Image, o.run_glyphs),
        .quads = c.slice(Quad, o.quads),
        .kept_quads = c.slice(Quad, o.quads),
        .run_keys = c.slice(u64, runs),
        .run_at = c.slice([2]u32, runs),
        .kept_keys = c.slice(u64, runs),
        .kept_at = c.slice([2]u32, runs),
        .extents = if (extents.len > 0) &extents[0] else undefined,
        .first = c.slice(u32, o.texts),
        .count = c.slice(u32, o.texts),
        .loaded = c.slice([]u8, o.faces),
        .missing = c.slice(u21, 64),
    };
    if (atlas_pixels.len > 0) t.atlas = .init(o.atlas[0], o.atlas[1], atlas_pixels, sky);
    if (extents.len > 0) t.stack.extents = t.extents;
    return t;
}

/// The stack's scratch for one run, its fallback columns and the shaping cache. The cache
/// lives in the buffer, not in `Text`, so the stack's pointer to it survives a move of `Text`.
fn carveStack(c: *mem.Carver, o: Options) text_stack.Stack {
    std.debug.assert(o.run_glyphs > 0);
    std.debug.assert(o.run_lines > 0);
    const shape_cache = c.slice(lcgf.shape_cache.Cache, 1);
    const cache: lcgf.shape_cache.Cache = .init(c, o.shape_slots, o.cached_glyphs);
    if (shape_cache.len > 0) shape_cache[0] = cache;
    const n = o.run_glyphs;
    const lines = o.run_lines;
    return .{
        .shapers = &.{},
        .cache = if (shape_cache.len > 0) &shape_cache[0] else null,
        .run = .{
            .glyph = c.slice(u16, n),
            .cluster = c.slice(u32, n),
            .advance = c.slice(i32, n),
            .x_offset = c.slice(i32, n),
            .y_offset = c.slice(i32, n),
        },
        .g = .{
            .glyph = c.slice(u16, n),
            .cluster = c.slice(u32, n),
            .advance = c.slice(f32, n),
            .x_offset = c.slice(f32, n),
            .y_offset = c.slice(f32, n),
            .span = c.slice(u32, n),
            .x = c.slice(f32, n),
            .level = c.slice(u8, n),
        },
        .l = .{
            .first = c.slice(u32, lines),
            .end = c.slice(u32, lines),
            .ink = c.slice(u32, lines),
            .start = c.slice(u32, lines),
            .width = c.slice(f32, lines),
            .hard = c.slice(f32, lines),
            .x = c.slice(f32, lines),
            .top = c.slice(f32, lines),
            .baseline = c.slice(f32, lines),
            .height = c.slice(f32, lines),
            .extra = c.slice(f32, lines),
        },
        .fallback = .{
            .chain = undefined, // set by addFace; no run is served before
            .runs = .{
                .end = c.slice(u32, o.run_faces),
                .face = c.slice(u16, o.run_faces),
                .script = c.slice(lcgf.unicode_property.Script, o.run_faces),
            },
            .metrics = c.slice(text_lines.Metrics, o.faces),
        },
    };
}

/// The slot of `key` in the open-addressed table `keys` (0 empty), or null.
fn find(keys: []const u64, key: u64) ?usize {
    std.debug.assert(std.math.isPowerOfTwo(keys.len));
    std.debug.assert(key != 0);
    const mask = keys.len - 1;
    var at: usize = @intCast((key >> 1) & mask);
    for (0..keys.len) |_| {
        if (keys[at] == key) return at;
        if (keys[at] == 0) return null;
        at = (at + 1) & mask;
    }
    return null;
}

// ---------------------------------------------------------------------------------------------

const testing = std.testing;
const sw = lcgf.render_sw;
const Color = lcgf.types.Color;

/// The repository's text test face (Noto Sans subset, src/text/layout/testdata/layout.ttf)
/// and the face it falls back to for the infinity sign and the middle dot (testdata/make.py).
pub const test_files = [_]File{
    .{ .bytes = @embedFile("layout.ttf") },
    .{ .bytes = @embedFile("testdata/symbols.ttf") },
};
const paragraph = "A paragraph in a proportional face: \u{221e} loops \u{00b7} dots \u{2026} " ++
    "and wraps to the box at any scale.";
const limits: lcgf.context.Limits = .{ .nodes = 16, .texts = 4, .customs = 1, .strings = 512 };
pub const test_options: Options = .{
    .atlas = .{ 256, 256 },
    .images = 512,
    .texts = limits.texts,
    .quads = 512,
    .run_glyphs = 256,
    .run_lines = 16,
    .shape_slots = 16,
};
const view = [2]f32{ 240, 120 };

/// One frame of the test paragraph, laid out through `Frame.endText` with the service's stack.
fn layOut(ctx: *Context, t: *Text) lcgf.context.Output {
    const in: lcgf.input.Input = .{ .viewport = view };
    var f = ctx.begin(&in);
    _ = f.open(.from("page"), .{ .size = .{ .px(view[0]), .px(view[1]) }, .pad = @splat(6) });
    _ = f.text(paragraph, .{ .px = 15, .wrap = true, .color = .white });
    f.close();
    return f.endText(&t.stack, t.ascent);
}

test "a paragraph through the service and the software back end matches direct rasterising" {
    var ctx_buf: [Context.requiredBytes(limits)]u8 align(mem.column_align) = undefined;
    var ctx = try Context.init(&ctx_buf, limits);
    var buf: [Text.requiredBytes(test_options)]u8 align(mem.column_align) = undefined;
    var t = try Text.init(&buf, test_options, &test_files);
    var pixels: [sw.Framebuffer.len(480, 240)]u32 = undefined;
    var reference: [480 * 240]u8 = undefined;
    for ([_]f32{ 1, 1.25, 2 }) |scale| {
        const out = layOut(&ctx, &t);
        try testing.expect(!t.stack.overflow);
        const frame = t.glyphs(out.draw, out.texts, scale);
        try testing.expect(!t.overflow);
        // Drawn as a software shell draws it: the atlas is image 1.
        const w: u32 = @intFromFloat(@ceil(view[0] * scale));
        const h: u32 = @intFromFloat(@ceil(view[1] * scale));
        var fb: sw.Framebuffer = .init(&pixels, w, h, .rgba8);
        const a = frame.atlas;
        const atlas: sw.Image = .{ .alpha8 = a.pixels, .width = a.w, .height = a.h };
        const images = [_]sw.Image{ .white, atlas };
        var setup: sw.Setup = .{};
        setup.gfx.images = &images;
        var g = frame.glyphs;
        g.texture = @fromBackingInt(1);
        setup.draw(&fb, out.draw, g, .black, scale);
        // The reference: every inked glyph rasterised straight from its face at its physical
        // pen, composited over black as white ink at its coverage.
        @memset(reference[0 .. w * h], 0);
        const fallbacks = try drawReference(&t, out, scale, reference[0 .. w * h], w);
        try testing.expect(fallbacks == 2); // the infinity sign and the middle dot
        var bad: u32 = 0;
        var ink: u32 = 0;
        for (0..h) |y| for (0..w) |x| {
            const want = reference[y * w + x];
            const got = fb.at(@intCast(x), @intCast(y));
            ink += @intFromBool(want != 0);
            const grey = got.r == got.g and got.g == got.b;
            bad += @intFromBool(@abs(@as(i32, got.r) - want) > 2 or !grey);
        };
        errdefer std.debug.print("scale {d}: {d} bad pixels of {d} inked\n", .{ scale, bad, ink });
        try testing.expectEqual(0, bad);
        try testing.expect(ink > 1000);
    }
}

/// Test helper, lcgf_app's tests' too: composites every glyph `out` draws into `img` (`w`
/// wide), rasterised by src/text/raster/ at the physical pen the service rounds to; returns
/// how many came from a fallback face.
pub fn drawReference(t: *Text, out: lcgf.context.Output, scale: f32, img: []u8, w: u32) !u32 {
    const sides = [_]Side{.{ .tx = out.texts, .strings = out.draw.strings }};
    return drawReferenceOf(t, out.draw, &sides, scale, img, w);
}

/// `side`'s bytes as the `Strings` its rows index, which `Stack` reads.
fn stringsOf(side: Side) Strings {
    return .{ .buf = @constCast(side.strings), .len = @intCast(side.strings.len) };
}

/// `drawReference` of a list joined from `sides` (`Text.glyphsOf`).
// tidy: allow(too-many-parameters) `drawReference`'s, with the list's sides
pub fn drawReferenceOf(
    t: *Text,
    d: *const DrawList,
    sides: []const Side,
    scale: f32,
    img: []u8,
    w: u32,
) !u32 {
    std.debug.assert(img.len % w == 0);
    var cols: raster.TestOutline = .{};
    var acc: [96 * 96]f32 = undefined;
    var cov: [96 * 96]u8 = undefined;
    var fallbacks: u32 = 0;
    for (d.runs[0..d.run_len], 0..) |run, k| {
        const side = Text.sideOf(sides, @intCast(k));
        const strings = stringsOf(side);
        try t.stack.paragraph(side.tx, &strings, k - side.first_run);
        const g = &t.stack.g;
        const l = &t.stack.l;
        for (0..l.len) |li| for (l.first[li]..l.ink[li]) |i| {
            const face = t.faces[g.fontAt(i)];
            fallbacks += @intFromBool(g.fontAt(i) != run.font);
            var o = cols.outline();
            try face.outline(g.glyph[i], &o);
            const pen = raster.pen((run.rect[0] + l.x[li] + g.x[i] + g.x_offset[i]) * scale);
            const pen_y = (run.rect[1] + l.baseline[li] - g.y_offset[i]) * scale;
            const base: i32 = @intFromFloat(@floor(pen_y + 0.5));
            const s = t.stack.pxAt(i) * scale / @as(f32, @floatFromInt(face.units_per_em));
            const b = raster.box(&o, s, raster.shift(pen.bin));
            if (b.w == 0) continue;
            raster.fill(&o, s, raster.shift(pen.bin), b, &acc);
            raster.coverage(&acc, &cov, @as(usize, b.w) * b.h);
            for (0..b.h) |r| for (0..b.w) |c| {
                const x = pen.pixel + b.left + @as(i32, @intCast(c));
                const y = base - b.top + @as(i32, @intCast(r));
                // Off the picture, as off the window.
                if (x < 0 or y < 0 or x >= w or y >= img.len / w) continue;
                const at = @as(usize, @intCast(y)) * w + @as(usize, @intCast(x));
                // White over what is there, at the glyph's coverage: "over", as the back end
                // blends overlapping glyphs.
                const a: u32 = cov[r * b.w + c];
                img[at] = @intCast(img[at] + (a * (255 - @as(u32, img[at])) + 127) / 255);
            };
        };
    }
    return fallbacks;
}

test "a second frame of the same text changes no texel; a new scale starts the atlas again" {
    var ctx_buf: [Context.requiredBytes(limits)]u8 align(mem.column_align) = undefined;
    var ctx = try Context.init(&ctx_buf, limits);
    var buf: [Text.requiredBytes(test_options)]u8 align(mem.column_align) = undefined;
    var t = try Text.init(&buf, test_options, &test_files);
    var quads: [512]Quad = undefined;
    var out = layOut(&ctx, &t);
    const first = t.glyphs(out.draw, out.texts, 1.25);
    try testing.expect(first.dirty != null);
    const n = first.glyphs.quads.len;
    try testing.expect(n > 40);
    @memcpy(quads[0..n], first.glyphs.quads);

    out = layOut(&ctx, &t);
    const second = t.glyphs(out.draw, out.texts, 1.25);
    try testing.expectEqual(null, second.dirty);
    try testing.expectEqual(first.generation, second.generation);
    const again = std.mem.sliceAsBytes(second.glyphs.quads);
    try testing.expectEqualSlices(u8, std.mem.sliceAsBytes(quads[0..n]), again);

    out = layOut(&ctx, &t);
    const third = t.glyphs(out.draw, out.texts, 2);
    try testing.expect(third.generation != second.generation);
    const all: Atlas.Upload = .{
        .x = 0,
        .y = 0,
        .w = 256,
        .h = 256,
        .offset = 0,
        .bytes_per_row = 256,
    };
    try testing.expectEqual(all, third.dirty.?);
}

test "kept runs: a frame draws what a new service draws, and one changed run is laid out alone" {
    var ctx_buf: [2][Context.requiredBytes(limits)]u8 align(mem.column_align) = undefined;
    var ctx = try Context.init(&ctx_buf[0], limits);
    var fresh_ctx = try Context.init(&ctx_buf[1], limits);
    var buf: [Text.requiredBytes(test_options)]u8 align(mem.column_align) = undefined;
    var fresh_buf: [Text.requiredBytes(test_options)]u8 align(mem.column_align) = undefined;
    var t = try Text.init(&buf, test_options, &test_files);
    for (0..3) |frame| {
        // Measured from kept extents from frame 1 on; frame 2 changes the middle label only.
        t.stack.g.len = 0;
        const out = labelled(&ctx, &t, frame == 2);
        if (frame == 1) try testing.expectEqual(0, t.stack.g.len);
        if (frame == 2) try testing.expectEqualStrings("changed", t.stack.text);
        const kept = t.glyphs(out.draw, out.texts, 1.25);
        // The same frame through a new service, which keeps nothing.
        var fresh = try Text.init(&fresh_buf, test_options, &test_files);
        const again = labelled(&fresh_ctx, &fresh, frame == 2);
        try testing.expectEqualSlices(f32, again.texts.c.w[0..3], out.texts.c.w[0..3]);
        try testing.expectEqualSlices(f32, again.texts.c.h[0..3], out.texts.c.h[0..3]);
        try testing.expectEqualSlices(f32, fresh.ascent[0..3], t.ascent[0..3]);
        const new = fresh.glyphs(again.draw, again.texts, 1.25);
        try testing.expectEqualSlices(u32, new.glyphs.first, kept.glyphs.first);
        try testing.expectEqualSlices(u32, new.glyphs.count, kept.glyphs.count);
        // Equal up to where each atlas put the images.
        for (kept.glyphs.quads, new.glyphs.quads) |a, b| {
            try testing.expectEqual(a.rect, b.rect);
            try testing.expectEqual(a.fill, b.fill);
            try testing.expectEqual(a.clip, b.clip);
        }
    }
}

/// Three labels, the middle one "changed" when `changed`, ended through `t`'s stack.
fn labelled(ctx: *Context, t: *Text, changed: bool) lcgf.context.Output {
    const in: lcgf.input.Input = .{ .viewport = view };
    var f = ctx.begin(&in);
    _ = f.open(.from("page"), .{ .size = .{ .px(view[0]), .px(view[1]) } });
    _ = f.text("first label", .{ .px = 14 });
    _ = f.text(if (changed) "changed" else "second", .{ .px = 14 });
    _ = f.text("third \u{221e}", .{ .px = 14 });
    f.close();
    return f.endText(&t.stack, t.ascent);
}

test "a full atlas starts again within the frame and reports it" {
    var ctx_buf: [Context.requiredBytes(limits)]u8 align(mem.column_align) = undefined;
    var ctx = try Context.init(&ctx_buf, limits);
    // Room for the paragraph's glyphs at one scale and not much more.
    const o: Options = comptime blk: {
        var o = test_options;
        o.atlas = .{ 128, 64 };
        break :blk o;
    };
    var buf: [Text.requiredBytes(o)]u8 align(mem.column_align) = undefined;
    var t = try Text.init(&buf, o, &test_files);
    var out = layOut(&ctx, &t);
    const a = t.glyphs(out.draw, out.texts, 1);
    try testing.expect(!t.overflow);
    // The same glyphs, each at a new subpixel position: the atlas fills and starts again.
    var moved = false;
    var b = a;
    for (1..4) |q| {
        out = layOut(&ctx, &t);
        const dx = @as(f32, @floatFromInt(q)) * 0.25;
        for (out.draw.runs[0..out.draw.run_len]) |*r| r.rect[0] += dx;
        b = t.glyphs(out.draw, out.texts, 1);
        moved = moved or b.generation != a.generation;
    }
    try testing.expect(moved);
    try testing.expect(!t.overflow);
    try testing.expectEqual(a.glyphs.quads.len, b.glyphs.quads.len);
}

test "no files: the stack serves no run" {
    var buf: [Text.requiredBytes(test_options)]u8 align(mem.column_align) = undefined;
    const t = try Text.init(&buf, test_options, &.{});
    try testing.expectEqual(0, t.stack.shapers.len);
    const three: [3]File = @splat(test_files[0]);
    const small: Options = comptime blk: {
        var small = test_options;
        small.faces = 2;
        break :blk small;
    };
    var buf2: [Text.requiredBytes(small)]u8 align(mem.column_align) = undefined;
    try testing.expectError(error.TooManyFaces, Text.init(&buf2, small, &three));
}

test "the system's default faces and a face for each character they lack draw text" {
    // Runs where the build links libc (zig build fallback-system), with the machine's fonts.
    if (!can_discover) return error.SkipZigTest;
    const gpa = testing.allocator;
    var ctx_buf: [Context.requiredBytes(limits)]u8 align(mem.column_align) = undefined;
    var ctx = try Context.init(&ctx_buf, limits);
    var buf: [Text.requiredBytes(test_options)]u8 align(mem.column_align) = undefined;
    var t = try Text.init(&buf, test_options, &.{});
    defer t.deinit(gpa);
    // lcgf_app's own tests link libc in a GPU build too, on machines without fontconfig.
    var d = Discovery.init() catch return error.SkipZigTest;
    defer d.deinit();
    try t.addSystemDefaults(gpa, testing.io, &d);
    try testing.expectEqual(2, t.face_len);
    const sample = paragraph ++ " Բարեւ αβγ";
    _ = try t.cover(gpa, testing.io, &d, sample);
    // Each character now has a face, and asking again adds none.
    var it = (try std.unicode.Utf8View.init(sample)).iterator();
    while (it.nextCodepoint()) |cp| try testing.expect(cp < 0x80 or t.has(cp));
    try testing.expectEqual(0, try t.cover(gpa, testing.io, &d, sample));
    // Laid out and drawn, in the proportional face and the monospace one: no .notdef.
    const in: lcgf.input.Input = .{ .viewport = view };
    var f = ctx.begin(&in);
    _ = f.open(.from("page"), .{ .size = .{ .px(view[0]), .px(view[1]) } });
    _ = f.text(sample, .{ .px = 15, .wrap = true });
    _ = f.text("mono: \u{221e}", .{ .px = 15, .font = @fromBackingInt(1) });
    f.close();
    const out = f.endText(&t.stack, t.ascent);
    const frame = t.glyphs(out.draw, out.texts, 1.5);
    try testing.expect(!t.overflow);
    try testing.expect(frame.glyphs.quads.len > 60);
    const bytes = out.draw.strings;
    const strings: Strings = .{ .buf = @constCast(bytes), .len = @intCast(bytes.len) };
    for (0..out.draw.run_len) |k| {
        try t.stack.paragraph(out.texts, &strings, k);
        for (t.stack.g.glyph[0..t.stack.g.len]) |g| try testing.expect(g != 0);
    }
}

test {
    _ = @import("labels.zig");
}
