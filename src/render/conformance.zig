//! Conformance scenes: small frames every back end must draw the same way. Each scene is a
//! hand-written draw list (not the output of layout and paint, so a back end is tested on its
//! own), with two oracles:
//!
//!   - `draws`: the instanced draws a back end issues, in order, for back ends that record calls
//!     (null.zig, checked by the test below) or count them.
//!   - a golden image, `conformance/<name>.png`, for back ends that produce pixels. They were
//!     drawn with a real wgpu device on Mesa lavapipe from what `conformance/dump.zig` writes
//!     (`ci/run.sh conformance`, which compares a fresh render against them with
//!     tools/golden/golden.py). The custom command is drawn by the host's own pipeline: a
//!     gradient scissored to the rect, the same host draw as the prototype's pixel check
//!     (docs/CHECKS.md section 4).
//!
//! Text uses `protocol.Mono` glyph quads over its 16x16 byte-indexed atlas.

const std = @import("std");
const types = @import("../core/types.zig");
const mem = @import("../core/mem.zig");
const draw_list = @import("../draw/draw_list.zig");
const Mono = @import("../text/protocol.zig").Mono;
const iface = @import("iface.zig");
const DrawList = draw_list.DrawList;
const Quad = draw_list.Quad;
const TextRun = draw_list.TextRun;
const CustomDraw = draw_list.CustomDraw;
const Cmd = draw_list.Cmd;
const Color = types.Color;
const canvas = @import("../draw/canvas.zig");

/// Which instance buffer a draw reads.
pub const Source = enum(u32) { quads, glyphs };
/// One expected instanced draw: 4 vertices, `count` instances from `first`.
pub const Draw = struct { source: Source, first: u32, count: u32 };

pub const Scene = struct {
    name: []const u8,
    /// Logical pixels; the golden image is this size at scale 1.
    viewport: [2]f32,
    quads: []const Quad,
    runs: []const TextRun = &.{},
    customs: []const CustomDraw = &.{},
    strings: []const u8 = "",
    cmds: []const Cmd,
    draws: []const Draw,
};

/// Capacity a draw list needs for any scene (`DrawList.init(carver, nodes, texts, customs)`).
pub const max_quads = 8;
pub const max_runs = 2;
pub const max_customs = 2;
pub const max_glyphs = 32;

/// Copies a scene into a draw list carved with at least the `max_*` capacities.
pub fn fill(s: *const Scene, d: *DrawList) void {
    @memcpy(d.quads[0..s.quads.len], s.quads);
    @memcpy(d.runs[0..s.runs.len], s.runs);
    @memcpy(d.customs[0..s.customs.len], s.customs);
    d.quad_len = @intCast(s.quads.len);
    d.run_len = @intCast(s.runs.len);
    d.custom_len = @intCast(s.customs.len);
    d.strings = s.strings;
    for (s.cmds, 0..) |cmd, i| {
        d.cmd.kind[i] = @backingInt(std.meta.activeTag(cmd));
        switch (cmd) {
            .quads => |b| {
                d.cmd.first[i] = b.first;
                d.cmd.count[i] = b.count;
                d.cmd.key[i] = (@as(u32, @backingInt(b.texture)) << 16) | @backingInt(b.material);
            },
            .text, .custom, .canvas => |k| {
                d.cmd.first[i] = k;
                d.cmd.count[i] = 1;
                d.cmd.key[i] = 0;
            },
        }
    }
    d.cmd_len = @intCast(s.cmds.len);
}

/// The scenes' font: `Mono` defaults.
pub const font: Mono = .{};

/// No clip: a rect larger than any viewport.
const open: [4]f32 = .{ -1e6, -1e6, 1e6, 1e6 };

fn quad(rect: [4]f32, fill_color: Color, o: struct { clip: [4]f32 = open, radius: f32 = 0, border: f32 = 0, border_color: Color = .transparent }) Quad {
    return .{
        .rect = rect,
        .clip = o.clip,
        .params = .{ 0, 0, 0, 0 },
        .uv = .{ 0, 0, 1, 1 },
        .fill = fill_color.bitsOf(),
        .border_color = o.border_color.bitsOf(),
        .radii = @splat(o.radius),
        .opacity = 1,
        .border = o.border,
    };
}

fn batch(first: u32, count: u32) Cmd {
    return .{ .quads = .{ .first = first, .count = count, .texture = .white, .material = .solid } };
}

const panel = Color.rgb(30, 31, 36);
const accent = Color.rgb(90, 140, 255);
const warm = Color.rgb(200, 90, 60);

pub const scenes = [_]Scene{
    // Solid, rounded and bordered quads, and a translucent one over both: premultiplied
    // blending and the SDF edge, one batch.
    .{
        .name = "rects",
        .viewport = .{ 160, 120 },
        .quads = &.{
            quad(.{ 0, 0, 160, 120 }, panel, .{}),
            quad(.{ 16, 16, 96, 72 }, accent, .{ .radius = 12, .border = 3, .border_color = Color.white }),
            quad(.{ 64, 48, 144, 104 }, Color.rgba(200, 90, 60, 128), .{ .radius = 4 }),
        },
        .cmds = &.{batch(0, 3)},
        .draws = &.{.{ .source = .quads, .first = 0, .count = 3 }},
    },
    // Per-instance clip: the bar is wider than its panel and is cut at the panel's edge.
    .{
        .name = "clip",
        .viewport = .{ 160, 120 },
        .quads = &.{
            quad(.{ 0, 0, 160, 120 }, panel, .{}),
            quad(.{ 20, 20, 120, 100 }, Color.rgb(20, 22, 28), .{ .border = 2, .border_color = accent }),
            quad(.{ 30, 50, 400, 74 }, warm, .{ .clip = .{ 20, 20, 120, 100 }, .radius = 6 }),
        },
        .cmds = &.{batch(0, 3)},
        .draws = &.{.{ .source = .quads, .first = 0, .count = 3 }},
    },
    // A text run between two batches: paint order across buffers, glyph quads from `Mono`
    // (16 px, 9.6 px advance; "Hello" wraps after four bytes in a 40 px run).
    .{
        .name = "text",
        .viewport = .{ 160, 120 },
        .quads = &.{
            quad(.{ 0, 0, 160, 120 }, panel, .{}),
            quad(.{ 0, 90, 160, 120 }, accent, .{}),
        },
        .runs = &.{
            .{ .rect = .{ 12, 12, 148, 40 }, .clip = open, .start = 0, .bytes = 3, .px = 16, .color = Color.white.bitsOf(), .font = 0 },
            .{ .rect = .{ 12, 44, 52, 84 }, .clip = open, .start = 3, .bytes = 5, .px = 16, .color = warm.bitsOf(), .font = 0 },
        },
        .strings = "UI!Hello",
        .cmds = &.{ batch(0, 1), .{ .text = 0 }, .{ .text = 1 }, batch(1, 1) },
        // The two runs' glyphs are adjacent: one draw (`iface.glyphSpan`).
        .draws = &.{
            .{ .source = .quads, .first = 0, .count = 1 },
            .{ .source = .glyphs, .first = 0, .count = 8 },
            .{ .source = .quads, .first = 1, .count = 1 },
        },
    },
    // An inline custom draw between UI draws, with a translucent quad over it: the host's
    // pipeline runs mid-pass and the UI must draw correctly after it.
    .{
        .name = "custom",
        .viewport = .{ 160, 120 },
        .quads = &.{
            quad(.{ 0, 0, 160, 120 }, panel, .{}),
            quad(.{ 24, 24, 136, 96 }, Color.rgba(20, 22, 28, 200), .{ .radius = 10, .border = 2, .border_color = accent }),
        },
        .customs = &.{.{ .rect = .{ 8, 8, 152, 112 }, .clip = open, .data = 7, .id = 1, .node = 0 }},
        .cmds = &.{ batch(0, 1), .{ .custom = 0 }, batch(1, 1) },
        .draws = &.{
            .{ .source = .quads, .first = 0, .count = 1 },
            .{ .source = .quads, .first = 1, .count = 1 },
        },
    },
};

/// The canvas batch (lcgf.canvas): every kind and cap, fills, strokes in a layer's pixels and
/// in world units, dashes across a chain, a non-convex polygon, glyphs turned 0 and 1 quarter
/// turns, an override, rows in their own colours, a dead row and a hidden layer, under a camera
/// that pans (a far i64 origin) and offsets, in a node clipped by its parent. Not a tree scene: `canvasScene` dumps the
/// instances, the palette and the command for sw-play and gpu.py; each GPU back end's player
/// draws it from `CanvasStorage`. Its golden is tools/golden/ref/draw/canvas.png.
pub const canvas_scene = struct {
    /// Logical pixels: the node, and the clip its parent gives it.
    pub const node = [4]f32{ 20, 20, 780, 580 };
    pub const clip = [4]f32{ 40, 30, 760, 570 };
    /// Twenty world units per pixel, centred on a point two billion units out.
    pub const far: i64 = 2_000_000_000;
    pub const camera: canvas.Camera = .{
        .origin = .{ far, -far },
        .scale = 0.05,
        .offset = .{ 10, 5 },
    };
    pub const layers = [_]canvas.Layer{
        .of(.{ .stroke = .rgb(230, 230, 230), .width = 2 }), // 0 wires
        .of(.{ .stroke = .rgb(90, 200, 255), .fill = .rgba(40, 90, 160, 180), .width = 3 }), // 1 symbols
        .of(.{ .stroke = .rgb(255, 120, 60), .fill = .rgb(255, 200, 60), .width = 4 }), // 2 pins
        .of(.{ .stroke = .rgb(250, 250, 120), .width = 2 }), // 3 labels
        .of(.{ .stroke = .rgb(255, 0, 255), .fill = .rgb(255, 0, 255), .width = 16, .visible = false }), // 4 hidden
        .of(.{ .stroke = .rgb(160, 255, 160), .fill = .rgb(60, 160, 60), .width = 2, .fill_on = false }), // 5 outlines only
        .of(.{ .stroke = .rgb(230, 230, 230), .width = 2, .dash = .{ 4, 4 } }), // 6 wires, dashed
    };
    pub const palette: canvas.Palette = .{ .layers = &layers };

    /// World point at logical (x, y) from the camera's origin.
    pub fn w(x: i32, y: i32) [2]i32 {
        return .{ @intCast(far + @as(i64, x) * 20), @intCast(-far + @as(i64, y) * 20) };
    }

    pub fn build(s: *canvas.Instances) [2]canvas.Range {
        // Caps: butt, square, round, 2 to 8 px wide (world widths: 20 units a pixel).
        const caps = [_]canvas.Cap{ .butt, .square, .round };
        for (caps, 0..) |c, k| for (0..4) |wt| {
            const y: i32 = @intCast(20 + 30 * k * 4 + 30 * wt);
            _ = s.segment(w(20, y), w(160, y + 10), .{ .width = @intCast(40 * (wt + 1)), .cap = c });
        };
        // A dashed chain with joints (4 px on, 4 off), and a world-width wire (200 units: 10 px).
        _ = s.polyline(&.{ w(200, 30), w(300, 30), w(340, 110), w(260, 160), w(200, 120) }, .{ .layer = 6, .width = 80, .cap = .round });
        _ = s.segment(w(200, 200), w(340, 260), .{ .width = 200, .cap = .round });
        // Rects: filled and stroked, rounded, stroke only, fill only; circles.
        _ = s.rect(w(380, 20), w(480, 90), .{ .layer = 1 });
        _ = s.rect(w(500, 20), w(620, 90), .{ .layer = 1, .radius = 20 * 20, .width = 180 });
        _ = s.rect(w(380, 110), w(480, 170), .{ .layer = 5, .radius = 8 * 20 });
        _ = s.rect(w(500, 110), w(620, 170), .{ .layer = 2, .stroke = false });
        _ = s.circle(w(660, 60), 40 * 20, .{ .layer = 2 });
        _ = s.circle(w(660, 150), 25 * 20, .{ .layer = 1, .fill = false, .width = 120 });
        // Arcs: each cap, a negative sweep, a full ring.
        for (caps, 0..) |c, k| _ = s.arc(w(@intCast(420 + 90 * k), 250), 35 * 20, .{ .layer = 1, .width = 180, .start = 0.4, .sweep = 4.2, .cap = c });
        _ = s.arc(w(690, 250), 30 * 20, .{ .layer = 2, .width = 160, .start = 0, .sweep = -2.5, .cap = .round });
        _ = s.arc(w(690, 250), 12 * 20, .{ .layer = 0, .width = 80 });
        // A dashed arc, round caps continuing the pattern.
        _ = s.arc(w(705, 195), 16 * 20, .{ .layer = 6, .width = 80, .start = 0.2, .sweep = 5.5, .cap = .round });
        // Polygons: a pin triangle, a concave arrow stroked, a self-crossing star (nonzero).
        _ = s.polygon(&.{ w(40, 420), w(110, 450), w(40, 480) }, .{ .layer = 2 });
        _ = s.polygon(&.{ w(140, 400), w(260, 400), w(260, 430), w(200, 430), w(230, 500), w(170, 500), w(170, 430), w(140, 430) }, .{ .layer = 1, .stroke = true, .width = 120 });
        var star: [5][2]i32 = undefined;
        for (&star, 0..) |*p, k| {
            const a = -std.math.pi / 2.0 + @as(f32, @floatFromInt(k)) * 4 * std.math.pi / 5.0;
            p.* = w(@intFromFloat(@round(340 + 60 * @cos(a))), @intFromFloat(@round(450 + 60 * @sin(a))));
        }
        _ = s.polygon(&star, .{ .layer = 1, .stroke = true });
        // Glyphs in the bitmap font: a label along x and one turned a quarter, 16 px tall.
        const bitmap: Mono = .{};
        _ = bitmap.canvasGlyphs(s, "LCGF canvas 0123", w(420, 330), .{ .px = 16 * 20, .layer = 3 });
        _ = bitmap.canvasGlyphs(s, "turned", w(720, 300), .{ .px = 16 * 20, .layer = 3, .turns = 1 });
        // A dead row and a hidden layer draw nothing; a wire past the clip is cut by it.
        s.kill(s.segment(w(420, 400), w(700, 520), .{ .width = 160 }));
        _ = s.rect(w(420, 400), w(700, 520), .{ .layer = 4 });
        _ = s.segment(w(400, 540), w(900, 580), .{ .width = 160, .cap = .round });
        // The selection: the second dashed edge's chain tinted, drawn as a second range.
        const selection_first = s.len;
        _ = s.polyline(&.{ w(420, 440), w(560, 520), w(700, 440) }, .{ .width = 120, .cap = .square });
        return .{ .{ .first = 0, .count = selection_first }, s.since(selection_first) };
    }

    /// A second canvas node over the first, under its parents' turn of 0.3 rad about its centre
    /// and a clip with rounded corners: the whole batch again, panned to the rects and arcs.
    pub const inset = struct {
        pub const node = [4]f32{ 540, 360, 760, 560 };
        pub const clip = [4]f32{ 550, 370, 750, 550 };
        pub const radii = [4]f32{ 30, 10, 40, 0 };
        const turn: f32 = 0.3;
        const cx: f32 = 650;
        const cy: f32 = 460;
        const ca = @cos(turn);
        const sa = @sin(turn);
        pub const xform = [6]f32{ ca, sa, -sa, ca, cx - (ca * cx - sa * cy), cy - (sa * cx + ca * cy) };
        pub const camera: canvas.Camera = .{
            .origin = .{ far + 380 * 20, -far + 20 * 20 },
            .scale = 0.05,
        };
    };

    /// Rows in their own colours (`Instances.setColor`), -1 for the selection's first.
    pub const marked = [_]i32{ 1, 6, 17, 40, -1 };
    pub const mark_colors = [_]Color{ .rgb(255, 60, 60), .rgb(60, 255, 255), .rgb(255, 0, 200), .rgb(255, 160, 0), .rgb(255, 255, 255) };

    pub const viewport = [2]f32{ 800, 600 };
    /// What the golden is drawn over (sw-play's 0d0d0f).
    pub const clear = Color.rgb(13, 13, 15);
    /// The selection's override colour.
    pub const tint = Color.rgb(80, 255, 120);
    pub const rows = 256;
    pub const verts = 64;
};

/// The canvas scene as a draw list of one canvas command, in caller-owned memory.
pub const CanvasStorage = struct {
    list_buf: [list_bytes]u8 align(mem.column_align) = undefined,
    shape_buf: [shape_bytes]u8 align(mem.column_align) = undefined,
    draw: DrawList = undefined,
    shapes: canvas.Instances = undefined,
    ranges: [2]canvas.Range = undefined,
    inset_ranges: [1]canvas.Range = undefined,
    overrides: [1]canvas.Override = undefined,
    rows: [2]draw_list.CanvasDraw = undefined,

    const shape_bytes = canvas.Instances.requiredBytes(canvas_scene.rows, canvas_scene.verts, 4, .{});
    const list_bytes = blk: {
        var counter: mem.Carver = .{ .buf = null };
        _ = DrawList.init(&counter, 1, 1, 2);
        break :blk counter.off;
    };

    /// Builds the scene; `st` must not move afterwards.
    pub fn load(st: *CanvasStorage) void {
        const sc = canvas_scene;
        var a: mem.Carver = .{ .buf = &st.list_buf };
        st.draw = DrawList.init(&a, 1, 1, 2);
        var b: mem.Carver = .{ .buf = &st.shape_buf };
        st.shapes = canvas.Instances.init(&b, sc.rows, sc.verts, 4, .{});
        st.ranges = sc.build(&st.shapes);
        // Rows in their own colours: two caps' segments, a rect, a glyph, and a selection row
        // whose colour wins over the selection's override.
        for (sc.marked, sc.mark_colors) |i, color| {
            st.shapes.setColor(if (i < 0) st.ranges[1].first else @intCast(i), color);
        }
        st.overrides = .{.{ .range = st.ranges[1], .color = @bitCast(sc.tint) }};
        st.inset_ranges = .{st.ranges[0]};
        st.rows = .{
            .{ .instances = &st.shapes, .camera = sc.camera, .ranges = &st.ranges, .palette = &sc.palette, .overrides = &st.overrides },
            .{ .instances = &st.shapes, .camera = sc.inset.camera, .ranges = &st.inset_ranges, .palette = &sc.palette },
        };
        st.draw.customs[0] = .{ .rect = sc.node, .clip = sc.clip, .data = 0, .id = 0, .node = 0 };
        st.draw.customs[1] = .{ .rect = sc.inset.node, .clip = sc.inset.clip, .data = 0, .id = 0, .node = 1, .xform = sc.inset.xform, .clip_radii = sc.inset.radii };
        st.draw.custom_len = 2;
        st.draw.canvases = &st.rows;
        for (0..2) |k| {
            st.draw.cmd.kind[k] = @backingInt(DrawList.Kind.canvas);
            st.draw.cmd.first[k] = @intCast(k);
            st.draw.cmd.count[k] = 1;
        }
        st.draw.cmd_len = 2;
    }
};

/// Bytes `Storage` needs, from a counting carver over the same `init`.
pub const storage_bytes = blk: {
    var counter: mem.Carver = .{ .buf = null };
    _ = DrawList.init(&counter, max_quads, max_runs, max_customs);
    break :blk counter.off;
};

/// One scene, ready to draw: the draw list and its glyph quads, in caller-owned memory.
pub const Storage = struct {
    buf: [storage_bytes]u8 align(mem.column_align) = undefined,
    glyph_quads: [max_glyphs]Quad = undefined,
    first: [max_runs]u32 = undefined,
    count: [max_runs]u32 = undefined,
    draw: DrawList = undefined,
    glyph_len: u32 = 0,

    /// Fills the draw list and the glyphs for `s`. `st` must not move afterwards.
    pub fn load(st: *Storage, s: *const Scene) void {
        var carver: mem.Carver = .{ .buf = &st.buf };
        st.draw = DrawList.init(&carver, max_quads, max_runs, max_customs);
        fill(s, &st.draw);
        st.glyph_len = font.quads(&st.draw, &st.glyph_quads, .{ .first = &st.first, .count = &st.count });
    }

    pub fn glyphs(st: *const Storage) iface.Glyphs {
        return .{ .quads = st.glyph_quads[0..st.glyph_len], .first = st.first[0..st.draw.run_len], .count = st.count[0..st.draw.run_len] };
    }
};

const testing = std.testing;

const null_backend = @import("null.zig");

test "conformance: the null back end draws every scene as declared" {
    for (&scenes) |*s| {
        try testing.expect(s.quads.len <= max_quads and s.runs.len <= max_runs and s.customs.len <= max_customs);
        var st: Storage = .{};
        st.load(s);
        try testing.expect(st.glyph_len < max_glyphs); // `quads` never hit its last row
        var calls: [64]null_backend.Call = undefined;
        var log: null_backend.Log = .{ .calls = &calls };
        var gfx: null_backend.Null = .{};
        gfx.prepare(&log, &st.draw, st.glyphs(), s.viewport, 1);
        log.len = 0;
        // The host's loop, marking where its own draw ran; full state must be rebound after it.
        var i = iface.drawUntilCustom(&gfx, &log, &st.draw, 0);
        while (i < st.draw.cmd_len) : (i = iface.drawUntilCustom(&gfx, &log, &st.draw, i + 1)) log.push(.host);
        try testing.expect(log.len <= calls.len);
        try testing.expect(null_backend.rebindsAfterHost(log.recorded()));
        // Each draw reads the instance buffer bound last.
        var got: [16]Draw = undefined;
        var n: usize = 0;
        var source: Source = .quads;
        for (log.recorded()) |call| switch (call) {
            .vertex_buffer => |buf| source = if (buf == .glyphs) .glyphs else .quads,
            .draw => |dr| {
                got[n] = .{ .source = source, .first = dr.first_instance, .count = dr.instances };
                n += 1;
            },
            else => {},
        };
        try testing.expectEqualSlices(Draw, s.draws, got[0..n]);
    }
}

test "conformance: fill round-trips commands through the draw-list columns" {
    var st: Storage = .{};
    for (&scenes) |*s| {
        st.load(s);
        for (s.cmds, 0..) |cmd, i| try testing.expectEqual(cmd, st.draw.command(@intCast(i)));
    }
}
