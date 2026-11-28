//! Canvas labels in real fonts, sharp at any camera scale: text in, canvas glyph instances
//! (`canvas.Instances.glyph` with `distance`) over one distance atlas out. Stage 5 of
//! docs/plans/window.md; the choice of distance images over rasterising again at each zoom is
//! measured by bench/micro/canvastext.zig.
//!
//!     var labels = try Labels.init(buffer, .{});
//!     const r = try labels.label(&text, &shapes, "R1", .{ .origin = .{ 2000, 0 }, .px = 1300 });
//!     // each frame: upload labels.atlas.takeDirty(), and draw with Glyphs.canvas set to the
//!     // handle it is registered as (canvas.wgsl and sw read the alpha channel).
//!
//! Each glyph's image is made once, at an em of `Options.em` px with `canvas.distance_spread`
//! texels of distance either side of the edge (src/text/raster/sdf.zig), whatever the label's
//! size or the camera's, and keeps its place while the atlas lives. When the atlas or its
//! table is full, `label` starts it again empty, moves `generation` on and fails: every label
//! made before is stale, and the caller makes them again. Shapes with the faces and fallback
//! chains of a `text.Text`, which must outlive the labels' rows only while they are made.
//!
//! Tier 3, the window layer (src/app/), next to the text service; every table is carved from the
//! caller's buffer (`requiredBytes`), nothing allocates.
//!
//! Contents
//!   pub const Options = struct
//!   pub const Label = struct
//!   pub const Labels = struct
//!     pub fn requiredBytes(o: Options) usize
//!     pub fn init(buf: []align(64) u8, o: Options) Labels
//!     pub fn label(l: *Labels, t: *const Text, s: *Instances, str: []const u8, o: Label)
//!         Error!Range
//!   pub const Error = error{ Full, NoSpace }
//!   pub const Handle = struct
//!     pub fn label(h: Handle, s: *Instances, str: []const u8, o: Label) LabelError!Range
//!     pub fn generation(h: Handle) u32
//!     pub fn available(h: Handle) bool

const std = @import("std");
const lcgf = @import("lcgf");
const mem = lcgf.mem;
const raster = lcgf.raster;
const sdf = lcgf.raster_sdf;
const canvas = lcgf.canvas;
const fallback = lcgf.fallback;
const shape = lcgf.shape;
const opentype = lcgf.opentype;
const Atlas = lcgf.raster_atlas.Atlas;
const Instances = canvas.Instances;
const Range = canvas.Range;
const Text = @import("text.zig").Text;

/// Capacities.
pub const Options = struct {
    /// Width and height of the distance atlas, one byte a texel.
    atlas: [2]u32 = .{ 512, 512 },
    /// Glyph images its table holds (one per face and glyph).
    images: u32 = 1024,
    /// The em, px, each image is made at: 48 is within about a level of the exact glyph from
    /// camera scale 2 to 8 (bench/micro/canvastext.zig), 121 KB for printable ASCII.
    em: u32 = 48,
    /// Glyphs, and runs of one face, of the longest label.
    label_glyphs: u32 = 256,
    label_faces: u32 = 16,
    /// Points, contours and flattened edges of the most complex outline.
    outline_points: u32 = 2048,
    outline_contours: u32 = 256,
    edges: u32 = 8192,
};

/// Where a label is and how it looks. Its baseline runs through `origin` (world units) along
/// the glyphs' x axis, turned `turns` quarter turns clockwise on screen with them; `px` is its
/// em in world units. `alignment` is where along the baseline `origin` falls, as a fraction of the
/// label's advance: 0 its start, 0.5 its middle, 1 its end (a pin name ending at its pin).
pub const Label = struct {
    origin: [2]i32,
    px: u32,
    font: u16 = 0,
    layer: u8 = 0,
    turns: u2 = 0,
    alignment: f32 = 0,
};

/// `error.Full`: the atlas or its table filled up and is empty again (`label`).
/// `error.NoSpace`: the instances or the label scratch are short.
pub const Error = error{ Full, NoSpace };

pub const Labels = struct {
    atlas: Atlas,
    /// Moves on when the atlas started again empty: the rows of every label made before
    /// sample stale texels.
    generation: u32 = 0,
    /// A glyph too complex for the scratch, or a label longer than `Options.label_glyphs`,
    /// was drawn short. Reset by the caller.
    overflow: bool = false,
    em: f32,
    /// Open-addressed glyph table: key (face << 16 | glyph, bit 31 set; 0 empty), and where
    /// its image is.
    keys: []u32,
    slots: []Slot,
    image_len: u32 = 0,
    image_cap: u32,
    run: shape.Run,
    runs: fallback.Runs,
    outline: opentype.Outline,
    segs: raster.Segments,
    acc: []f32,
    cov: []u8,

    /// Bytes of the buffer `init` carves for `o`.
    pub fn requiredBytes(o: Options) usize {
        @setEvalBranchQuota(10_000);
        var counter: mem.Carver = .{ .buf = null };
        _ = carve(&counter, o);
        return counter.off;
    }

    /// Labels over `buf` (`requiredBytes(o)` bytes, which it keeps), the atlas empty.
    pub fn init(buf: []align(mem.column_align) u8, o: Options) Labels {
        std.debug.assert(buf.len >= requiredBytes(o));
        std.debug.assert(o.images > 0);
        var c: mem.Carver = .{ .buf = buf };
        return carve(&c, o);
    }

    /// Appends the glyphs of `str` to `s`, shaped in font `o.font` of `t` (its fallback
    /// chain for characters the font lacks), as distance glyphs of this atlas, the first pen
    /// at `o.origin`. Returns the rows. `error.Full` when the atlas or its table filled up:
    /// it is empty again, `generation` has moved on, and this label and every one before
    /// must be made again. `error.NoSpace` when `s` or the label scratch is short. Asserts
    /// `o.font` is a face of `t`.
    pub fn label(l: *Labels, t: *const Text, s: *Instances, str: []const u8, o: Label) Error!Range {
        std.debug.assert(o.font < t.face_len);
        const first = s.len;
        try fallback.resolveClusters(&t.chains[o.font], str, &l.runs);
        // World units per px of the em the images were made at, and the label's turn.
        const k = @as(f32, @floatFromInt(o.px)) / l.em;
        const c, const sn = canvas.turn(o.turns);
        var pen: f32 = 0;
        var start: u32 = 0;
        for (l.runs.end[0..l.runs.len], l.runs.face[0..l.runs.len]) |end, f| {
            defer start = end;
            const shaper = &t.shapers[f];
            try shaper.shape(str[start..end], &l.run, .{});
            const per_unit = l.em / @as(f32, @floatFromInt(shaper.face.units_per_em));
            for (0..l.run.len) |i| {
                defer pen += @as(f32, @floatFromInt(l.run.advance[i])) * per_unit;
                const slot = try l.image(t, f, l.run.glyph[i]);
                if (slot.w == 0) continue;
                // The image's top-left corner from the pen (y down), em px, then world units.
                const dx: f32 = @floatFromInt(l.run.x_offset[i]);
                const dy: f32 = @floatFromInt(l.run.y_offset[i]);
                const x = (pen + dx * per_unit + @as(f32, @floatFromInt(slot.left))) * k;
                const y = (-dy * per_unit - @as(f32, @floatFromInt(slot.top))) * k;
                const anchor = [2]i32{
                    o.origin[0] + @as(i32, @intFromFloat(@round(c * x - sn * y))),
                    o.origin[1] + @as(i32, @intFromFloat(@round(sn * x + c * y))),
                };
                const size = [2]u32{
                    @intFromFloat(@round(@as(f32, @floatFromInt(slot.w)) * k)),
                    @intFromFloat(@round(@as(f32, @floatFromInt(slot.h)) * k)),
                };
                if (s.len == s.cap) return error.NoSpace;
                const rect: Atlas.Rect = .{ .x = slot.x, .y = slot.y, .w = slot.w, .h = slot.h };
                const style: Instances.Glyph = .{
                    .layer = o.layer,
                    .turns = o.turns,
                    .distance = true,
                };
                _ = s.glyph(anchor, size, l.atlas.uv(rect), style);
            }
        }
        std.debug.assert(s.len >= first);
        // Aligned: every row moved back along the baseline by `alignment` of the advance.
        if (o.alignment != 0) {
            const back = o.alignment * pen * k;
            const sx: i32 = @intFromFloat(@round(-c * back));
            const sy: i32 = @intFromFloat(@round(-sn * back));
            const shift = [2]i32{ sx, sy };
            for (s.c.pos[first..s.len]) |*p| {
                p[0] += shift[0];
                p[1] += shift[1];
            }
        }
        return s.since(first);
    }

    // ---- private ----

    /// The atlas slot of glyph `glyph` of face `f`, its distance image made when no earlier
    /// label made it.
    fn image(l: *Labels, t: *const Text, f: u16, glyph: u16) error{Full}!Slot {
        const key = (@as(u32, f) << 16) | glyph | (1 << 31);
        const mask: u32 = @intCast(l.keys.len - 1);
        var at = ((key *% 0x9e37_79b1) >> 7) & mask;
        var probes: u32 = 0;
        while (l.keys[at] != 0) : (at = (at + 1) & mask) {
            if (l.keys[at] == key) return l.slots[at];
            probes += 1;
            std.debug.assert(probes <= mask);
        }
        if (l.image_len == l.image_cap) return l.reset();
        const slot = l.distance(&t.faces[f], glyph) orelse return l.reset();
        l.keys[at] = key;
        l.slots[at] = slot;
        l.image_len += 1;
        return slot;
    }

    /// Empties the atlas and its table, moves `generation` on and fails.
    fn reset(l: *Labels) error{Full} {
        l.atlas.clear();
        @memset(l.keys, 0);
        l.image_len = 0;
        l.generation +%= 1;
        return error.Full;
    }

    /// The distance image of `glyph` put in a new place of the atlas; an empty slot for a
    /// glyph with no ink or too complex for the scratch (`overflow`); null when the atlas
    /// has no room.
    fn distance(l: *Labels, face: *const opentype.Face, glyph: u16) ?Slot {
        std.debug.assert(glyph < face.glyph_count or face.glyph_count == 0);
        l.outline.points = 0;
        l.outline.contours = 0;
        face.outline(glyph, &l.outline) catch {
            l.overflow = true;
            return .{};
        };
        const scale = l.em / @as(f32, @floatFromInt(face.units_per_em));
        const spread = canvas.distance_spread;
        const b = sdf.box(&l.outline, scale, 0, spread);
        if (b.w == 0 or b.h == 0) return .{};
        if (raster.accLen(b) > l.acc.len or raster.imageLen(b) > l.cov.len) {
            l.overflow = true;
            return .{};
        }
        sdf.fill(&l.outline, scale, 0, spread, b, &l.segs, l.acc, l.cov) catch {
            l.overflow = true;
            return .{};
        };
        // A texel of gap, zero (far outside), between images: the bilinear read at an
        // image's edge sees no neighbour.
        const r = l.atlas.pack(b.w + 1, b.h + 1) orelse return null;
        l.atlas.put(.{ .x = r.x, .y = r.y, .w = b.w, .h = b.h }, l.cov);
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

/// What an application holds to make labels in its window's fonts: the window's text
/// service and label atlas, which `lcgf_app.run` gives an App with a field
/// `labels: lcgf_app.Labels` before its first `build`, and which the window draws canvas
/// glyphs from. Empty when the window draws the bitmap font: `label` then fails with
/// `error.Unavailable`, and bitmap canvas labels (`protocol.Mono.canvasGlyphs`) draw as before.
///
/// Make a label once and keep its rows while `generation` stays what it was when it was made.
/// When the atlas fills, `label` fails with `error.Full` and `generation` moves on: the rows
/// of every label made before sample texels that are gone, so make all of them again (the
/// call that failed too). Nothing else (a pan, a zoom, a new window scale) asks for that.
pub const Handle = struct {
    text: ?*const Text = null,
    labels: ?*Labels = null,

    pub const LabelError = Error || error{Unavailable};

    /// `Labels.label` in the window's faces and atlas.
    pub fn label(h: Handle, s: *Instances, str: []const u8, o: Label) LabelError!Range {
        const t = h.text orelse return error.Unavailable;
        const l = h.labels orelse return error.Unavailable;
        std.debug.assert(t.face_len > 0);
        return l.label(t, s, str, o);
    }

    /// The atlas's generation: a label made at another one is stale. 0 without an atlas.
    pub fn generation(h: Handle) u32 {
        return if (h.labels) |l| l.generation else 0;
    }

    /// Whether labels in real fonts can be made: the window draws with the text service.
    pub fn available(h: Handle) bool {
        return h.labels != null;
    }
};

/// Where a distance image is in the atlas and its box from the pen at the em (`sdf.box`).
const Slot = struct { x: u16 = 0, y: u16 = 0, w: u16 = 0, h: u16 = 0, left: i16 = 0, top: i16 = 0 };

/// The tables of `Labels`, carved in one order for sizing and for use.
fn carve(c: *mem.Carver, o: Options) Labels {
    std.debug.assert(o.atlas[0] < 1 << 16);
    std.debug.assert(o.atlas[1] < 1 << 16);
    const table = std.math.ceilPowerOfTwoAssert(u32, 2 * o.images);
    // The largest image at the em: wide glyphs reach about 2 em, plus the spread.
    const side: u32 = 2 * o.em + 2 * canvas.distance_spread + 2;
    const scratch: raster.Box = .{ .w = side, .h = side };
    const pixels = c.slice(u8, @as(usize, o.atlas[0]) * o.atlas[1]);
    const sky: Atlas.Skyline = .{
        .x = c.slice(u32, o.atlas[0]),
        .y = c.slice(u32, o.atlas[0]),
        .w = c.slice(u32, o.atlas[0]),
    };
    const n = o.label_glyphs;
    var l: Labels = .{
        .atlas = undefined,
        .em = @floatFromInt(o.em),
        .keys = c.slice(u32, table),
        .slots = c.slice(Slot, table),
        .image_cap = o.images,
        .run = .{
            .glyph = c.slice(u16, n),
            .cluster = c.slice(u32, n),
            .advance = c.slice(i32, n),
            .x_offset = c.slice(i32, n),
            .y_offset = c.slice(i32, n),
        },
        .runs = .{
            .end = c.slice(u32, o.label_faces),
            .face = c.slice(u16, o.label_faces),
            .script = c.slice(lcgf.unicode_property.Script, o.label_faces),
        },
        .outline = .{
            .x = c.slice(f32, o.outline_points),
            .y = c.slice(f32, o.outline_points),
            .on = c.slice(bool, o.outline_points),
            .ends = c.slice(u32, o.outline_contours),
        },
        .segs = .{
            .x0 = c.slice(f32, o.edges),
            .y0 = c.slice(f32, o.edges),
            .x1 = c.slice(f32, o.edges),
            .y1 = c.slice(f32, o.edges),
        },
        .acc = c.slice(f32, raster.accLen(scratch)),
        .cov = c.slice(u8, raster.imageLen(scratch)),
    };
    if (pixels.len > 0) l.atlas = .init(o.atlas[0], o.atlas[1], pixels, sky);
    return l;
}

// ---------------------------------------------------------------------------------------------

const testing = std.testing;
const sw = lcgf.render_sw;
const DrawList = lcgf.draw_list.DrawList;
const Camera = canvas.Camera;
const sw_font = lcgf.render_sw_font;
const AppImage = @import("app.zig").Image;
const page = @import("page.zig");
const Framebuffer = sw.Framebuffer;
const Img = sw.Image;
const text_mod = @import("text.zig");

const scales = [_]f32{ 0.5, 1, 2, 4, 8 };
/// World units per logical pixel at camera scale 1.
const per_px = 100;
const words = "R1 10k Vout";

/// One canvas node over all of `fb` drawing `shapes` under `cam`, white over `ground`, by the
/// software back end at `scale` physical pixels per logical one; `atlas` is the distance atlas.
const Node = struct {
    list_buf: [list_bytes]u8 align(mem.column_align) = undefined,
    rows: [1]lcgf.draw_list.CanvasDraw = undefined,
    all: [1]canvas.Range = undefined,
    list: DrawList = undefined,
    const list_bytes = blk: {
        var counter: mem.Carver = .{ .buf = null };
        _ = DrawList.init(&counter, 1, 1, 1);
        break :blk counter.off;
    };
    const palette: canvas.Palette = .{ .layers = &.{.of(.{ .stroke = .white })} };

    fn draw(n: *Node, fb: *sw.Framebuffer, s: *const Instances, cam: Camera, img: sw.Image) void {
        n.drawAt(fb, s, cam, img, .{ .scale = 1, .ground = .black });
    }

    const At = struct {
        scale: f32,
        ground: lcgf.types.Color,
        palette: *const canvas.Palette = &palette,
    };

    fn drawAt(n: *Node, fb: *Framebuffer, s: *const Instances, c: Camera, i: Img, at: At) void {
        std.debug.assert(at.scale > 0);
        var a: mem.Carver = .{ .buf = &n.list_buf };
        n.list = DrawList.init(&a, 1, 1, 1);
        const w = @as(f32, @floatFromInt(fb.width)) / at.scale;
        const h = @as(f32, @floatFromInt(fb.height)) / at.scale;
        const r: [4]f32 = .{ 0, 0, w, h };
        n.list.customs[0] = .{ .rect = r, .clip = r, .data = 0, .id = 0, .node = 0 };
        n.list.custom_len = 1;
        n.all = .{s.since(0)};
        n.rows = .{.{ .instances = s, .camera = c, .ranges = &n.all, .palette = at.palette }};
        n.list.canvases = &n.rows;
        n.list.cmd.kind[0] = @backingInt(DrawList.Kind.canvas);
        n.list.cmd.first[0] = 0;
        n.list.cmd.count[0] = 1;
        n.list.cmd_len = 1;
        fb.clear(at.ground);
        sw.canvas.draw(.{ .fb = fb, .scissor = fb.all() }, &n.list, 0, at.scale, i);
    }
};

/// How `drawCanvas` draws: physical pixels per logical one, the node's own fill, its palette.
pub const CanvasLook = struct {
    scale: f32 = 1,
    ground: lcgf.types.Color,
    palette: *const canvas.Palette,
};

/// Test helper: `s` under `cam` in a canvas node over all of `fb`, as `look` says, its glyphs
/// from `atlas`, drawn by the software back end: what a window shows of that node.
pub fn drawCanvas(
    fb: *Framebuffer,
    s: *const Instances,
    c: Camera,
    a: *const Atlas,
    look: CanvasLook,
) void {
    const Draw = struct {
        var node: Node = .{};
    };
    const img: Img = .{ .alpha8 = a.pixels, .width = a.w, .height = a.h };
    const at: Node.At = .{ .scale = look.scale, .ground = look.ground, .palette = look.palette };
    Draw.node.drawAt(fb, s, c, img, at);
}

/// Test helper for lcgf_app's own tests (app.zig, gpu.zig): an App whose window is one canvas
/// of labels in the test face, made once and made again only when `words` change or the
/// atlas starts again (`Handle.generation`).
pub const TestApp = struct {
    pub const ground: lcgf.types.Color = .rgb(20, 20, 24);
    const palette: canvas.Palette = .{ .layers = &.{.of(.{ .stroke = .white })} };
    labels: Handle = .{},
    shapes: *Instances,
    words: []const []const u8,
    /// Camera scale, and pixels the camera has moved right.
    zoom: f32 = 1,
    pan: f32 = 0,
    /// Where the first label's origin is, logical pixels from the canvas's top left, an em
    /// above (the others under it), and the alignment and turn `remake` writes them with.
    at: [2]f32 = .{ 4, 4 },
    alignment: f32 = 0,
    turns: u2 = 0,
    /// The generation and words the labels were made at; how often they were made and how
    /// often an atlas filled while making them.
    made: ?u32 = null,
    made_words: []const []const u8 = &.{},
    remakes: u32 = 0,
    fulls: u32 = 0,
    /// Read when the frame is drawn, after `build`.
    ranges: [1]Range = undefined,

    pub fn build(a: *TestApp, f: *lcgf.frame.Frame, _: *const lcgf.shell_iface.Events) void {
        if (a.made != a.labels.generation() or a.made_words.ptr != a.words.ptr) a.remake();
        a.ranges = .{a.shapes.since(0)};
        _ = f.open(.none, .{ .size = .{ .fill, .fill }, .fill = ground });
        const o: lcgf.frame.CanvasOptions = .{
            .camera = a.camera(),
            .palette = &palette,
            .ranges = &a.ranges,
        };
        _ = f.canvas(.from("labels"), .{ .size = .{ .fill, .fill } }, a.shapes, o);
        f.close();
    }

    /// The alignments and turns `align` takes, each case of the window tests.
    pub const alignments = [3]f32{ 0, 0.5, 1 };

    /// One label, "R1 10k Vout", with `alignment` and `turns`, its origin where all of it
    /// stays in a 200 x 100 window at camera scale 1 (`expectWindow`): made again at the next
    /// frame, the camera unpanned.
    pub fn aligned(a: *TestApp, alignment: f32, turns: u2) void {
        std.debug.assert(alignment >= 0);
        std.debug.assert(alignment <= 1);
        a.words = &.{"R1 10k Vout"};
        a.alignment = alignment;
        a.turns = turns;
        a.zoom = 1;
        a.pan = 0;
        a.made = null;
        // Along x the label is about 75 pixels; turned, it runs down from the origin.
        a.at = if (turns == 0) .{ 4 + 190 * alignment, 4 } else .{ 100, 4 + 80 * alignment };
    }

    pub fn camera(a: *const TestApp) canvas.Camera {
        return .{ .scale = a.zoom / per_px, .offset = .{ a.at[0] - a.pan, a.at[1] + 13 * a.zoom } };
    }

    /// Every word a label, one under the other: when the atlas fills, all of them again in
    /// the new one.
    fn remake(a: *TestApp) void {
        std.debug.assert(a.labels.available());
        a.remakes += 1;
        var fulls: u32 = 0;
        for (0..2) |_| {
            a.shapes.reset();
            const done = for (a.words, 0..) |w, k| {
                const o: Label = .{
                    .origin = .{ 0, @intCast(k * 2000) },
                    .px = 13 * per_px,
                    .turns = a.turns,
                    .alignment = a.alignment,
                };
                _ = a.labels.label(a.shapes, w, o) catch |e| switch (e) {
                    error.Full => break false,
                    else => @panic("labels: no room for the test's rows"),
                };
            } else true;
            if (done) break;
            fulls += 1;
        }
        a.fulls += fulls;
        a.made = a.labels.generation();
        a.made_words = a.words;
    }

    /// Every pixel of window `w` (read by `pixel(w, x, y)`) within 2 of `reference` at window
    /// scale `s`, drawn into `pixels`.
    // tidy: allow-fn(large-generic-function) a test helper over the X11 window, one instance
    pub fn expectWindow(a: *const TestApp, w: anytype, pixel: anytype, s: f32, buf: []u32) !void {
        try page.skipResized(w, null, sw.Framebuffer.len(w.width, w.height) <= buf.len);
        var fb = sw.Framebuffer.init(buf, w.width, w.height, .rgba8);
        a.reference(&fb, s);
        var bad: u32 = 0;
        var ink: u32 = 0;
        for (0..w.height) |y| for (0..w.width) |x| {
            const want = fb.at(@intCast(x), @intCast(y));
            const got = try pixel(w, @intCast(x), @intCast(y));
            ink += @intFromBool(want.r > 128);
            const off = @abs(@as(i32, got.r) - want.r) > 2 or @abs(@as(i32, got.b) - want.b) > 2;
            bad += @intFromBool(off);
        };
        const at = .{ s, a.zoom, bad, ink };
        errdefer std.debug.print("labels at scale {d}, zoom {d}: {d} bad pixels, {d} inked\n", at);
        try testing.expectEqual(0, bad);
        try testing.expect(ink > 50);
    }

    /// What the window shows at window scale `s`: the canvas drawn headless by the software
    /// back end from the same rows and atlas.
    pub fn reference(a: *const TestApp, fb: *sw.Framebuffer, s: f32) void {
        const Draw = struct {
            var node: Node = .{};
        };
        const l = &a.labels.labels.?.atlas;
        const img: sw.Image = .{ .alpha8 = l.pixels, .width = l.w, .height = l.h };
        Draw.node.drawAt(fb, a.shapes, a.camera(), img, .{ .scale = s, .ground = ground });
    }
};

/// Test helper for lcgf_app's own tests: an App without labels that writes canvas glyphs in
/// the bundled bitmap font (Schemify's labels), beside two images of its own and a line of
/// text, which the text service draws when it is on. Its canvas must sample the bundled font.
pub const BitmapApp = struct {
    pub const ground: lcgf.types.Color = .rgb(20, 20, 24);
    /// The canvas's height, logical pixels; the images and the text are under it.
    pub const height = 40;
    const palette: canvas.Palette = .{ .layers = &.{.of(.{ .stroke = .white })} };
    const lines = [_][]const u8{ "4-bit INVERTER BUFFER", "IN" };
    shapes: *Instances,
    texels: [2][4]u32 = .{ @splat(0xff0000ff), @splat(0xffff0000) },
    list: [2]AppImage = undefined,
    ranges: [1]Range = undefined,

    pub fn images(a: *BitmapApp) []const AppImage {
        a.list = .{
            .{ .pixels = &a.texels[0], .size = .{ 2, 2 } },
            .{ .pixels = &a.texels[1], .size = .{ 2, 2 } },
        };
        return &a.list;
    }

    pub fn build(a: *BitmapApp, f: *lcgf.frame.Frame, _: *const lcgf.shell_iface.Events) void {
        std.debug.assert(a.shapes.cap >= 32);
        if (a.shapes.len == 0) for (lines, 0..) |line, k| {
            const at: [2]i32 = .{ 0, @intCast(k * 2000) };
            _ = (lcgf.protocol.Mono{}).canvasGlyphs(a.shapes, line, at, .{ .px = 13 * per_px });
        };
        a.ranges = .{a.shapes.since(0)};
        _ = f.open(.none, .{ .size = .{ .fill, .fill }, .fill = ground });
        const o: lcgf.frame.CanvasOptions = .{
            .camera = camera,
            .palette = &palette,
            .ranges = &a.ranges,
        };
        _ = f.canvas(.from("bitmap"), .{ .size = .{ .fill, .px(height) } }, a.shapes, o);
        for (0..2) |k| _ = f.leaf(.none, .{
            .float = true,
            .offset = .{ @floatFromInt(10 + 30 * k), height + 10 },
            .size = .{ .px(20), .px(20) },
            .fill = .white,
            .texture = @fromBackingInt(@as(u16, @intCast(k + 1))),
        });
        const line: lcgf.types.Style = .{ .float = true, .offset = .{ 80, height + 8 } };
        _ = f.textStyled("Wave office", .{ .px = 15, .color = .white }, line);
        f.close();
    }

    const camera: Camera = .{ .scale = 1.0 / @as(f32, per_px), .offset = .{ 4, 4 } };

    /// Every pixel of the canvas in window `w` (read by `pixel(w, x, y)`) within 2 of the same
    /// rows drawn by the software back end from the bundled font, at window scale `s`.
    // tidy: allow-fn(large-generic-function) a test helper over the X11 window, one instance
    pub fn expectWindow(a: *const BitmapApp, w: anytype, pixel: anytype, s: f32, buf: []u32) !void {
        const rows: u32 = @intFromFloat(height * s);
        try page.skipResized(w, .{ 300, 200 }, sw.Framebuffer.len(w.width, rows) <= buf.len);
        var fb = sw.Framebuffer.init(buf, w.width, rows, .rgba8);
        const Draw = struct {
            var node: Node = .{};
        };
        Draw.node.drawAt(&fb, a.shapes, camera, sw_font.image, .{ .scale = s, .ground = ground });
        var bad: u32 = 0;
        var ink: u32 = 0;
        for (0..rows) |y| for (0..w.width) |x| {
            const want = fb.at(@intCast(x), @intCast(y));
            const got = try pixel(w, @intCast(x), @intCast(y));
            ink += @intFromBool(want.r > 128);
            const off = @abs(@as(i32, got.r) - want.r) > 2 or @abs(@as(i32, got.b) - want.b) > 2;
            bad += @intFromBool(off);
        };
        const at = .{ s, bad, ink };
        errdefer std.debug.print("bitmap glyphs at scale {d}: {d} bad pixels, {d} inked\n", at);
        try testing.expectEqual(0, bad);
        try testing.expect(ink > 50);
    }
};

test "an aligned label starts, centres or ends on its origin, along its own axis when turned" {
    var text_buf: [Text.requiredBytes(text_mod.test_options)]u8 align(mem.column_align) = undefined;
    const t = try Text.init(&text_buf, text_mod.test_options, &text_mod.test_files);
    const o: Options = comptime .{ .atlas = .{ 256, 256 }, .images = 64, .label_glyphs = 32 };
    var buf: [Labels.requiredBytes(o)]u8 align(mem.column_align) = undefined;
    var labels = Labels.init(&buf, o);
    var shapes_buf: [Instances.requiredBytes(64, 1, 1, .{})]u8 align(mem.column_align) = undefined;
    var carver: mem.Carver = .{ .buf = &shapes_buf };
    var shapes = Instances.init(&carver, 64, 1, 1, .{});
    const a = &labels.atlas;
    const atlas: sw.Image = .{ .alpha8 = a.pixels, .width = a.w, .height = a.h };
    var pixels: [sw.Framebuffer.len(400, 400)]u32 = undefined;
    var node: Node = .{};
    // The origin at pixel (200, 200), camera scale 1.
    const cam: canvas.Camera = .{ .scale = 1.0 / @as(f32, per_px), .offset = .{ 200, 200 } };
    for ([_]u2{ 0, 1 }) |turns| {
        // Without `alignment`: the rows of before, which an aligned label moves as one.
        shapes.reset();
        const at_start: Label = .{ .origin = .{ 0, 0 }, .px = 13 * per_px, .turns = turns };
        const plain = try labels.label(&t, &shapes, words, at_start);
        for ([_]f32{ 0, 0.5, 1 }) |alignment| {
            const first = shapes.len;
            var l = at_start;
            l.alignment = alignment;
            const r = try labels.label(&t, &shapes, words, l);
            try testing.expectEqual(plain.count, r.count);
            const p0 = shapes.c.pos[first];
            const q0 = shapes.c.pos[0];
            const d = [2]i32{ p0[0] - q0[0], p0[1] - q0[1] };
            for (0..r.count) |i| {
                const p = shapes.c.pos[first + i];
                const q = shapes.c.pos[i];
                try testing.expectEqual([4]i32{ q[0] + d[0], q[1] + d[1], q[2], q[3] }, p);
                try testing.expectEqual(shapes.c.look[i], shapes.c.look[first + i]);
            }
            if (alignment == 0) try testing.expectEqual([2]i32{ 0, 0 }, d);
            // The ink of this label alone along its axis: x unturned, y a quarter turn on.
            const n = comptime Instances.requiredBytes(32, 1, 1, .{});
            var one_buf: [n]u8 align(mem.column_align) = undefined;
            var one_carver: mem.Carver = .{ .buf = &one_buf };
            var one = Instances.init(&one_carver, 32, 1, 1, .{});
            _ = try labels.label(&t, &one, words, l);
            var fb: sw.Framebuffer = .init(&pixels, 400, 400, .rgba8);
            node.draw(&fb, &one, cam, atlas);
            var lo: f32 = 400;
            var hi: f32 = 0;
            for (0..400) |y| for (0..400) |x| {
                if (fb.at(@intCast(x), @intCast(y)).r < 128) continue;
                const along: f32 = @floatFromInt(if (turns == 0) x else y);
                lo = @min(lo, along);
                hi = @max(hi, along + 1);
            };
            const at = lo + (hi - lo) * alignment;
            const seen = .{ alignment, turns, lo, hi };
            errdefer std.debug.print("alignment {d}, turns {d}: ink {d}..{d}\n", seen);
            try testing.expect(@abs(at - 200) <= 1);
        }
    }
}

test "a label is as sharp at camera scale 8 as at 1 and close to its glyphs rasterised there" {
    var text_buf: [Text.requiredBytes(text_mod.test_options)]u8 align(mem.column_align) = undefined;
    const t = try Text.init(&text_buf, text_mod.test_options, &text_mod.test_files);
    const o: Options = comptime .{ .atlas = .{ 256, 256 }, .images = 64, .label_glyphs = 32 };
    var buf: [Labels.requiredBytes(o)]u8 align(mem.column_align) = undefined;
    var labels = Labels.init(&buf, o);
    var shapes_buf: [Instances.requiredBytes(32, 1, 1, .{})]u8 align(mem.column_align) = undefined;
    var carver: mem.Carver = .{ .buf = &shapes_buf };
    var shapes = Instances.init(&carver, 32, 1, 1, .{});
    const em = 13 * per_px;
    _ = try labels.label(&t, &shapes, words, .{ .origin = .{ 0, 0 }, .px = em });
    try testing.expect(!labels.overflow);
    const a = &labels.atlas;
    const atlas: sw.Image = .{ .alpha8 = a.pixels, .width = a.w, .height = a.h };
    var pixels: [sw.Framebuffer.len(800, 160)]u32 = undefined;
    var reference: [800 * 160]u8 = undefined;
    var node: Node = .{};
    var edge: [scales.len]f32 = undefined;
    for (scales, &edge) |s, *width| {
        var fb: sw.Framebuffer = .init(&pixels, 800, 160, .rgba8);
        // The baseline 4 px in and an em down.
        const cam: canvas.Camera = .{ .scale = s / per_px, .offset = .{ 4, 4 + 13 * s } };
        node.draw(&fb, &shapes, cam, atlas);
        @memset(&reference, 0);
        try rasterised(&t.shapers[0], 13 * s, .{ 4, 4 + 13 * s }, &reference, 800);
        var sum: u64 = 0;
        var ink: u64 = 0;
        var partial: [2]u32 = .{ 0, 0 };
        for (0..160) |y| for (0..800) |x| {
            const want = reference[y * 800 + x];
            const got = fb.at(@intCast(x), @intCast(y)).r;
            sum += @abs(@as(i32, got) - want);
            ink += @intFromBool(want != 0);
            partial[0] += @intFromBool(got > 0 and got < 255);
            partial[1] += @intFromBool(want > 0 and want < 255);
        };
        width.* = @as(f32, @floatFromInt(partial[0])) / @as(f32, @floatFromInt(partial[1]));
        // Levels of 255 per inked pixel: the bench's distance error (11 at 0.5, 4 at 1, 1 to
        // 2 from 2 up) with room for the anchors' rounding to world units.
        const mean = @as(f32, @floatFromInt(sum)) / @as(f32, @floatFromInt(ink));
        errdefer std.debug.print("scale {d}: mean {d:.2}, edge {d:.2}\n", .{ s, mean, width.* });
        try testing.expect(mean < @as(f32, if (s < 1) 40 else if (s < 2) 16 else 8));
        try testing.expect(width.* < 1.2);
    }
    try testing.expect(edge[4] <= edge[1] + 0.05);
}

/// `words` in `shaper`'s face at `px`, its first pen at `pen`, rasterised exactly and
/// composited white over black into `img` (`w` wide).
fn rasterised(shaper: *const shape.Shaper, px: f32, pen: [2]f32, img: []u8, w: u32) !void {
    std.debug.assert(img.len % w == 0);
    var cols: shape.TestRun = .{};
    var run = cols.run();
    try shaper.shape(words, &run, .{});
    var ocols: raster.TestOutline = .{};
    var acc: [160 * 160]f32 = undefined;
    var cov: [160 * 160]u8 = undefined;
    const scale = px / @as(f32, @floatFromInt(shaper.face.units_per_em));
    const base: i32 = @intFromFloat(@round(pen[1]));
    var x = pen[0];
    for (run.glyph[0..run.len], run.advance[0..run.len]) |g, advance| {
        defer x += @as(f32, @floatFromInt(advance)) * scale;
        var ol = ocols.outline();
        try shaper.face.outline(g, &ol);
        const left = @floor(x);
        const b = raster.box(&ol, scale, x - left);
        if (b.w == 0) continue;
        raster.fill(&ol, scale, x - left, b, &acc);
        raster.coverage(&acc, &cov, @as(usize, b.w) * b.h);
        for (0..b.h) |r| for (0..b.w) |col| {
            const ix = @as(i32, @intFromFloat(left)) + b.left + @as(i32, @intCast(col));
            const iy = base - b.top + @as(i32, @intCast(r));
            if (ix < 0 or iy < 0 or ix >= w or iy >= img.len / w) continue;
            const at = @as(usize, @intCast(iy)) * w + @as(usize, @intCast(ix));
            const a: u32 = cov[r * b.w + col];
            img[at] = @intCast(img[at] + (a * (255 - @as(u32, img[at])) + 127) / 255);
        };
    }
}
