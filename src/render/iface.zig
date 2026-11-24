//! The back-end contract: what every renderer (software, Vulkan, Metal, D3D12, GL ES, web, wgpu)
//! provides so one `DrawList` draws on any of them. Ported from the public surface of
//! prototype/ui_wgpu.zig `Renderer(gpu)`: `prepare`, `drawBatch`, `drawText`, `render`.
//!
//! No vtable and no callback: a back end is any type `B` with the declarations below, checked at
//! compile time by `check`, and the command loop is generic over it. The host owns the device,
//! the queue, the pass and the loop (docs/DESIGN.md); a back end owns only the objects it created
//! from the host's device.
//!
//!   B.Queue   what `prepare` uploads through (a wgpu queue; `void` for a back end with none)
//!   B.Pass    what draws are recorded into (a render pass, a command list, a framebuffer)
//!   fn prepare(*B, B.Queue, *const DrawList, Glyphs, viewport: [2]f32, scale: f32) void
//!        Uploads the frame, once, before the pass begins.
//!   fn drawBatch(*const B, B.Pass, Batch) void
//!        One instanced draw of `batch.count` quads from `batch.first`.
//!   fn drawText(*const B, B.Pass, run: u32) void
//!        One instanced draw of run `run`'s glyph quads (`Glyphs.first[run]`, `count[run]`).
//!   fn drawGlyphSpan(*const B, B.Pass, span: [2]u32) void      (optional)
//!        One instanced draw of `span[1]` glyph quads from `span[0]`: the command loop gives it
//!        consecutive runs whose glyphs are adjacent, so they cost one draw, not one each.
//!
//! Full state rebinding (required). `drawBatch` and `drawText` set every piece of pass state
//! they depend on, on every call: pipeline, every bind group, the vertex buffer, and scissor or
//! viewport if they use them. A back end must not skip a bind because it set the same object
//! for the previous draw: the host's draws between two UI draws (route 2 below) may have changed
//! anything, and the back end is not told when. Ported from prototype `Renderer.bind`, which
//! rebinds per draw for this reason. The cost is four state calls per draw, and draws are one
//! per command, not per node. `null.rebindsAfterHost` checks a recorded call stream for it.
//!
//! Custom commands are not a back-end call: the back end never sees them. The host draws them
//! with its own pipeline, between the UI's draws, by stopping at each one (`drawUntilCustom`).
//! `render` is the diagonal for frames with no custom draws, or ones the host skips.
//!
//! ## Three routes for custom rendering
//!
//! All three follow from the host owning the pass; none needs a callback or a back-end hook.
//! The names are Qt Quick's (custom render node example: underlay, inline, texture).
//!
//!   1. Underlay / overlay. The host records its own draws into the pass before or after the
//!      UI's (`render` or the `drawUntilCustom` loop). Under: a 3D scene behind the UI, the UI
//!      drawn on top with premultiplied blending. Over: debug lines or a cursor above it. Cheapest
//!      route; the host's draws are not clipped or ordered with UI nodes.
//!   2. Inline. A custom node (a `Customs` row) puts a `custom` command in paint order. `drawUntilCustom`
//!      stops there; the host draws into `customs[k].rect` (scissor to `customs[k].clip`, the
//!      host's own pipeline, `customs[k].data` to say what), then continues. UI nodes painted
//!      later cover it, earlier ones lie under it. Conformance scene `custom` checks this route.
//!      Uploads the host needs happen before the pass, next to `prepare`: egui-wgpu splits its
//!      `CallbackTrait` the same way (`prepare` with the queue, `paint` inside the pass), but
//!      as a callback the framework calls; here the host's loop simply does both.
//!   3. Texture. The host renders into its own texture in an earlier pass, registers the view
//!      with the back end (the wgpu back end's `addTexture`) and shows it with `Style.texture` on
//!      any node. It is then an ordinary quad: clipped, rounded, batched, layered like the rest.
//!      Costs a texture and a pass; the only route whose output the UI can transform or reuse.
//!
//! After an inline draw the pass may be in any state; full state rebinding above makes that safe.

const std = @import("std");
const types = @import("../core/types.zig");
const draw_list = @import("../draw/draw_list.zig");
const DrawList = draw_list.DrawList;
const Quad = draw_list.Quad;
const Batch = draw_list.Batch;

/// Glyph quads for the frame's text runs, produced by `protocol.Mono.quads` or by your own
/// shaper. `first[k]`, `count[k]` locate run k in `quads`. Must stay valid until the pass has
/// been recorded.
pub const Glyphs = struct {
    quads: []const Quad = &.{},
    first: []const u32 = &.{},
    count: []const u32 = &.{},
    /// The glyph atlas, as the back end registered it.
    texture: types.Texture = .white,

    /// Run `k`'s quads as `{ first, count }`; `{ 0, 0 }` for a run past `first`, so a frame with
    /// text runs and empty `Glyphs` (no shaper yet) draws its quads and no text. Every back end's
    /// `drawText` reads the run through this.
    pub fn span(g: Glyphs, k: u32) [2]u32 {
        if (k >= g.first.len) return .{ 0, 0 };
        return .{ g.first[k], g.count[k] };
    }
};

/// The declarations `check` requires of a back end.
pub const required = [_][]const u8{ "Queue", "Pass", "prepare", "drawBatch", "drawText" };

/// Compile error unless `B` declares everything in `required`.
pub fn check(comptime B: type) void {
    for (required) |name| {
        if (!@hasDecl(B, name)) @compileError(@typeName(B) ++ " is not a render back end: missing `" ++ name ++ "` (src/render/iface.zig)");
    }
}

/// Draws commands `from`, `from + 1`, ... up to the next custom command and returns its index,
/// or `draw.cmd_len` when there is none. The host draws the custom one and continues at the
/// returned index + 1:
///
///     var i = iface.drawUntilCustom(&gfx, pass, draw, 0);
///     while (i < draw.cmd_len) : (i = iface.drawUntilCustom(&gfx, pass, draw, i + 1))
///         scene.draw(pass, draw.customs[draw.command(i).custom]);
///
/// Consecutive text commands whose glyphs follow each other in the glyph buffer (the shaper
/// writes runs in order) go to a back end that declares `drawGlyphSpan(pass, span: [2]u32)` as
/// one draw: with `order.mergeAcrossText` most of a frame's text is then a draw or two.
pub fn drawUntilCustom(b: anytype, pass: @TypeOf(b.*).Pass, draw: *const DrawList, from: u32) u32 {
    const B = @TypeOf(b.*);
    comptime check(B);
    var i = from;
    while (i < draw.cmd_len) : (i += 1) switch (draw.command(i)) {
        .quads => |batch| b.drawBatch(pass, batch),
        .text => |run| if (comptime @hasDecl(B, "drawGlyphSpan"))
            b.drawGlyphSpan(pass, glyphSpan(b.glyphs, draw, &i, run))
        else
            b.drawText(pass, run),
        .custom => return i,
    };
    return i;
}

/// Text command `i.*`'s glyphs (run `run`) and those of the text commands after it, while each
/// run's glyphs start where the last one's end; `i.*` is left at the last command taken. `list`
/// is a `DrawList` or anything with its `cmd_len` and `command`.
pub fn glyphSpan(g: Glyphs, list: anytype, i: *u32, run: u32) [2]u32 {
    var span = g.span(run);
    while (i.* + 1 < list.cmd_len) {
        const next = switch (list.command(i.* + 1)) {
            .text => |r| g.span(r),
            else => break,
        };
        if (next[0] != span[0] + span[1]) break;
        span[1] += next[1];
        i.* += 1;
    }
    return span;
}

/// Diagonal: the whole list, skipping custom draws.
pub fn render(b: anytype, pass: @TypeOf(b.*).Pass, draw: *const DrawList) void {
    var i = drawUntilCustom(b, pass, draw, 0);
    while (i < draw.cmd_len) i = drawUntilCustom(b, pass, draw, i + 1);
}

const testing = std.testing;
const mem = @import("../core/mem.zig");

/// Smallest back end that meets the contract: it writes what it was asked to draw into the
/// pass, a list of (kind, first, count).
const Tally = struct {
    pub const Queue = void;
    pub const Pass = *Log;
    const Log = struct { rows: [8][3]u32 = undefined, len: u32 = 0 };

    glyphs: Glyphs = .{},
    uploaded: usize = 0,

    pub fn prepare(t: *Tally, _: void, draw: *const DrawList, glyphs: Glyphs, _: [2]f32, _: f32) void {
        t.glyphs = glyphs;
        t.uploaded = draw.quadBytes().len;
    }
    pub fn drawBatch(_: *const Tally, l: Pass, batch: Batch) void {
        l.rows[l.len] = .{ 0, batch.first, batch.count };
        l.len += 1;
    }
    pub fn drawText(t: *const Tally, l: Pass, run: u32) void {
        const g = t.glyphs.span(run);
        l.rows[l.len] = .{ 1, g[0], g[1] };
        l.len += 1;
    }
};

test "contract: quads and text go to the back end, customs stop the loop for the host" {
    const bytes = comptime blk: {
        var counter: mem.Carver = .{ .buf = null };
        _ = DrawList.init(&counter, 4, 1, 1);
        break :blk counter.off;
    };
    var buf: [bytes]u8 align(mem.column_align) = undefined;
    var carver: mem.Carver = .{ .buf = &buf };
    var d = DrawList.init(&carver, 4, 1, 1);
    // batch of 2 | text 0 | custom 0 | batch of 1
    const kinds = [_]DrawList.Kind{ .quads, .text, .custom, .quads };
    const firsts = [_]u32{ 0, 0, 0, 2 };
    const counts = [_]u32{ 2, 1, 1, 1 };
    for (kinds, firsts, counts, 0..) |kind, first, count, i| {
        d.cmd.kind[i] = @backingInt(kind);
        d.cmd.first[i] = first;
        d.cmd.count[i] = count;
    }
    d.cmd_len = kinds.len;
    d.quad_len = 3;
    d.customs[0].data = 42;

    var gfx: Tally = .{};
    gfx.prepare({}, &d, .{ .first = &.{5}, .count = &.{3} }, .{ 100, 100 }, 1);
    try testing.expectEqual(3 * @sizeOf(Quad), gfx.uploaded);

    var log: Tally.Log = .{};
    var customs: u32 = 0;
    var i = drawUntilCustom(&gfx, &log, &d, 0);
    while (i < d.cmd_len) : (i = drawUntilCustom(&gfx, &log, &d, i + 1)) {
        try testing.expectEqual(42, d.customs[d.command(i).custom].data);
        try testing.expectEqual(2, log.len); // everything before the custom draw, nothing after
        customs += 1;
    }
    try testing.expectEqual(1, customs);
    try testing.expectEqual(3, log.len);
    try testing.expectEqualSlices(u32, &.{ 0, 0, 2, 1, 5, 3, 0, 2, 1 }, @ptrCast(log.rows[0..3]));

    // The diagonal issues the same draws and skips the custom one.
    var all: Tally.Log = .{};
    render(&gfx, &all, &d);
    try testing.expectEqualSlices(u32, @ptrCast(log.rows[0..3]), @ptrCast(all.rows[0..all.len]));
}

test "contract: check accepts a back end" {
    comptime check(Tally);
}

test "glyphSpan: adjacent text runs join, a gap or another command ends the span" {
    const Cmd = draw_list.Cmd;
    const List = struct {
        cmds: []const Cmd,
        cmd_len: u32,
        pub fn command(l: *const @This(), i: u32) Cmd {
            return l.cmds[i];
        }
    };
    // Runs 0 and 1 adjacent, 2 after a gap, then a batch, then run 3 adjacent to 2.
    const g: Glyphs = .{ .first = &.{ 0, 4, 10, 12 }, .count = &.{ 4, 3, 2, 5 } };
    const cmds = [_]Cmd{ .{ .text = 0 }, .{ .text = 1 }, .{ .text = 2 }, .{ .quads = .{ .first = 0, .count = 1, .texture = .white, .material = @fromBackingInt(0) } }, .{ .text = 3 } };
    const list: List = .{ .cmds = &cmds, .cmd_len = cmds.len };
    var i: u32 = 0;
    try testing.expectEqual([2]u32{ 0, 7 }, glyphSpan(g, &list, &i, 0));
    try testing.expectEqual(1, i);
    i = 2;
    try testing.expectEqual([2]u32{ 10, 2 }, glyphSpan(g, &list, &i, 2));
    try testing.expectEqual(2, i);
    i = 4;
    try testing.expectEqual([2]u32{ 12, 5 }, glyphSpan(g, &list, &i, 3));
    try testing.expectEqual(4, i);
}
