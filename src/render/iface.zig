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
//!
//! Custom commands are not a back-end call: the back end never sees them. The host draws them
//! with its own pipeline, between the UI's draws, by stopping at each one (`drawUntilCustom`).
//! `render` is the diagonal for frames with no custom draws, or ones the host skips.

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
pub fn drawUntilCustom(b: anytype, pass: @TypeOf(b.*).Pass, draw: *const DrawList, from: u32) u32 {
    comptime check(@TypeOf(b.*));
    var i = from;
    while (i < draw.cmd_len) : (i += 1) switch (draw.command(i)) {
        .quads => |batch| b.drawBatch(pass, batch),
        .text => |run| b.drawText(pass, run),
        .custom => return i,
    };
    return i;
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
        l.rows[l.len] = .{ 1, t.glyphs.first[run], t.glyphs.count[run] };
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
