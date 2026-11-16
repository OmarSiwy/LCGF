//! Draw batches and overdraw of the application's part of a frame, for the inspector. Reads a
//! `DrawList` as paint left it and the tree and side lists it was painted from. The inspector's
//! own rows paint after the application's (it builds last and paint goes in row order), so the
//! application's quads are a prefix of `quads`, found by counting the rows paint gave a quad
//! with paint's own test.

const std = @import("std");
const Tree = @import("../core/tree.zig").Tree;
const DrawList = @import("../draw/draw_list.zig").DrawList;
const Quad = @import("../draw/draw_list.zig").Quad;

pub const Stats = struct {
    quads: u32 = 0,
    /// Quad commands: one instanced draw each.
    batches: u32 = 0,
    texts: u32 = 0,
    customs: u32 = 0,
    /// Commands in paint order, the application's only: `cmds[0..]` of the draw list.
    cmds: u32 = 0,
    /// Quad area drawn, clipped, over the viewport's area: 1.0 is every pixel once.
    overdraw: f32 = 0,
};

/// Quads paint emitted for rows `0..rows` of `t`: rows visible, with a fill or border colour
/// that has alpha, and not fully transparent (src/draw/paint.zig, sweep 1).
pub fn quadsOf(t: *const Tree, rows: u32) u32 {
    var q: u32 = 0;
    for (0..rows) |i| {
        const look = t.c.look[i];
        q += @intFromBool(t.c.visible[i] != 0 and ((look.fill | look.border_color) >> 24) != 0 and t.c.alpha[i] > 0);
    }
    return q;
}

/// A quad's rect cut to its clip; zero when the clip removes it.
pub fn clipped(q: *const Quad) [4]f32 {
    const x0 = @max(q.rect[0], q.clip[0]);
    const y0 = @max(q.rect[1], q.clip[1]);
    return .{ x0, y0, @max(@min(q.rect[2], q.clip[2]), x0), @max(@min(q.rect[3], q.clip[3]), y0) };
}

/// The application's share of `d`, painted from `t`: its first `rows` rows. Text and custom
/// commands are the application's when their node is; `text_node` and `custom_node` are the
/// `node` columns of the `Texts` and `Customs` `d` was painted from.
pub fn stats(d: *const DrawList, t: *const Tree, rows: u32, text_node: []const u32, custom_node: []const u32, viewport: [2]f32) Stats {
    var s: Stats = .{ .quads = quadsOf(t, rows) };
    var area: f32 = 0;
    for (d.quads[0..s.quads]) |*q| {
        const r = clipped(q);
        area += (r[2] - r[0]) * (r[3] - r[1]);
    }
    s.overdraw = area / @max(viewport[0] * viewport[1], 1);
    for (0..d.cmd_len) |k| {
        const mine = switch (d.command(@intCast(k))) {
            .quads => |b| b.first < s.quads,
            .text => |r| text_node[r] < rows,
            .custom => |c| custom_node[c] < rows,
        };
        if (!mine) break;
        s.cmds += 1;
        switch (d.command(@intCast(k))) {
            .quads => s.batches += 1,
            .text => s.texts += 1,
            .custom => s.customs += 1,
        }
    }
    return s;
}
