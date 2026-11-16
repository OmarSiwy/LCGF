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
            .text, .custom => |k| {
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
        .draws = &.{
            .{ .source = .quads, .first = 0, .count = 1 },
            .{ .source = .glyphs, .first = 0, .count = 3 },
            .{ .source = .glyphs, .first = 3, .count = 5 },
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
