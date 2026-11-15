//! Draw list: what a renderer consumes. Flat arrays and u32 indices only; every row type that
//! crosses to the GPU is `extern` with `[4]f32` fields, because `@Vector` is not allowed in an
//! extern struct (docs/ZIG_0_17_1.md). Tier 0. Ported from prototype/ui.zig ("Draw list").

const std = @import("std");
const mem = @import("../core/mem.zig");
const types = @import("../core/types.zig");
const Texture = types.Texture;
const Material = types.Material;
const Region = @import("damage.zig").Region;

/// One instance of the quad pipeline. This is the GPU vertex-buffer layout,
/// so the whole array uploads with a single copy.
pub const Quad = extern struct {
    /// x0, y0, x1, y1 in logical pixels.
    rect: [4]f32,
    /// Clipping is per instance, so a clip change never splits a batch.
    clip: [4]f32,
    /// Material uniforms.
    params: [4]f32,
    /// u0, v0, u1, v1.
    uv: [4]f32,
    /// Corner radii: top-left, top-right, bottom-right, bottom-left.
    radii: [4]f32,
    fill: u32,
    border_color: u32,
    border: f32,
    /// Multiplies the whole quad's output: the node's inherited opacity.
    opacity: f32,
    /// Layout space to screen, a, b, c, d, tx, ty: applied to the corners in the vertex shader.
    xform: [6]f32 = .{ 1, 0, 0, 1, 0, 0 },
};

/// One text node's run, for the renderer's text pass.
pub const TextRun = extern struct {
    /// Content box of the text node.
    rect: [4]f32,
    clip: [4]f32,
    /// Byte range in `DrawList.strings`.
    start: u32,
    bytes: u32,
    px: f32,
    color: u32,
    font: u32,
};

/// A rectangle handed back to the host, which draws it with its own pipeline.
pub const CustomDraw = extern struct {
    rect: [4]f32,
    clip: [4]f32,
    /// Whatever the caller passed to `Frame.custom`.
    data: u64,
    id: u32,
    node: u32,
};

/// A run of quads sharing one texture and material: one instanced draw.
pub const Batch = struct { first: u32, count: u32, texture: Texture, material: Material };

/// One step for the renderer, in paint order.
pub const Cmd = union(DrawList.Kind) {
    /// A run of `quads` sharing one texture and material.
    quads: Batch,
    /// Index into `runs`.
    text: u32,
    /// Index into `customs`: the caller draws this one itself.
    custom: u32,
};

/// One frame's paint output. Rows are carved from the caller's buffer by `init`; `paint.emit`
/// rewrites them and the `*_len` counts every frame.
pub const DrawList = struct {
    quads: []Quad,
    quad_len: u32 = 0,
    runs: []TextRun,
    run_len: u32 = 0,
    customs: []CustomDraw,
    custom_len: u32 = 0,
    /// Storage that `TextRun.start` indexes.
    strings: []const u8 = "",
    /// Commands are stored as columns so they can be produced without
    /// branches; `command` gives the tagged-union view.
    cmd: CmdColumns,
    cmd_len: u32 = 0,
    op: OpColumns,
    /// What changed since the last frame (`damage.cull` sets it): a renderer that keeps last
    /// frame's pixels redraws only inside these rects and may leave the rest. `everything`
    /// unless the frame was culled.
    damage: Region = .everything,

    pub const Kind = enum(u8) { quads, text, custom };
    /// `key` is texture << 16 | material for quad batches, 0 otherwise. `first` indexes `quads`,
    /// `runs` or `customs` by kind; `count` is the batch length for quads.
    pub const CmdColumns = struct { kind: []u8, first: []u32, count: []u32, key: []u32 };
    /// Paint's intermediate stream: one op per painted quad, text run or custom draw, in paint
    /// order, before quads with equal keys merge into commands.
    pub const OpColumns = struct { kind: []u8, key: []u32, ref: []u32 };

    pub fn init(carver: *mem.Carver, nodes: u32, texts: u32, customs: u32) DrawList {
        // One spare row everywhere: emitters write first and advance after.
        const ops = nodes + texts + customs + 4;
        return .{
            .quads = carver.slice(Quad, nodes + 1),
            .runs = carver.slice(TextRun, texts + 1),
            .customs = carver.slice(CustomDraw, customs + 1),
            .cmd = carver.columns(CmdColumns, ops),
            .op = carver.columns(OpColumns, ops),
        };
    }

    /// Command `i` as a tagged union, for a renderer's one switch per command.
    pub fn command(d: *const DrawList, i: u32) Cmd {
        const key = d.cmd.key[i];
        return switch (@as(Kind, @fromBackingInt(d.cmd.kind[i]))) {
            .quads => .{ .quads = .{
                .first = d.cmd.first[i],
                .count = d.cmd.count[i],
                .texture = @fromBackingInt(@as(u16, @truncate(key >> 16))),
                .material = @fromBackingInt(@as(u16, @truncate(key))),
            } },
            .text => .{ .text = d.cmd.first[i] },
            .custom => .{ .custom = d.cmd.first[i] },
        };
    }

    /// The instance data, ready for one buffer write.
    pub fn quadBytes(d: *const DrawList) []const u8 {
        return std.mem.sliceAsBytes(d.quads[0..d.quad_len]);
    }
};

const testing = std.testing;

test "layout: Quad is the 120-byte instance row the quad pipeline declares" {
    // Renderers declare vertex attributes at these offsets (src/render/shaders/quad.wgsl). The
    // prototype's 80-byte row had one `radius` after the colours; per-corner `radii` replaced it,
    // and `opacity` and `xform` were added.
    try testing.expectEqual(120, @sizeOf(Quad));
    try testing.expectEqual(4, @alignOf(Quad));
    inline for (.{ "rect", "clip", "params", "uv", "radii", "fill", "border_color", "border", "opacity", "xform" }, .{ 0, 16, 32, 48, 64, 80, 84, 88, 92, 96 }) |name, off|
        try testing.expectEqual(off, @offsetOf(Quad, name));
}

test "layout: TextRun and CustomDraw rows" {
    try testing.expectEqual(52, @sizeOf(TextRun));
    try testing.expectEqual(4, @alignOf(TextRun));
    inline for (.{ "rect", "clip", "start", "bytes", "px", "color", "font" }, .{ 0, 16, 32, 36, 40, 44, 48 }) |name, off|
        try testing.expectEqual(off, @offsetOf(TextRun, name));
    try testing.expectEqual(48, @sizeOf(CustomDraw));
    try testing.expectEqual(8, @alignOf(CustomDraw));
    inline for (.{ "rect", "clip", "data", "id", "node" }, .{ 0, 16, 32, 40, 44 }) |name, off|
        try testing.expectEqual(off, @offsetOf(CustomDraw, name));
}

test "DrawList.init carves one spare row per table and sizes like a counting carver" {
    const bytes = comptime blk: {
        var counter: mem.Carver = .{ .buf = null };
        _ = DrawList.init(&counter, 10, 3, 2);
        break :blk counter.off;
    };
    var buf: [bytes]u8 align(mem.column_align) = undefined;
    var carver: mem.Carver = .{ .buf = &buf };
    var d = DrawList.init(&carver, 10, 3, 2);
    try testing.expectEqual(bytes, carver.off);
    try testing.expectEqual(11, d.quads.len);
    try testing.expectEqual(4, d.runs.len);
    try testing.expectEqual(3, d.customs.len);
    inline for (.{ d.cmd.kind, d.cmd.first, d.cmd.count, d.cmd.key, d.op.kind, d.op.key, d.op.ref }) |col|
        try testing.expectEqual(19, col.len);
    try testing.expectEqual(0, d.quad_len + d.run_len + d.custom_len + d.cmd_len);
    try testing.expectEqual(0, d.quadBytes().len);
    d.quads[1].fill = 0xdead_beef;
    d.quad_len = 2;
    const raw = d.quadBytes();
    try testing.expectEqual(2 * @sizeOf(Quad), raw.len);
    try testing.expectEqual(0xdead_beef, std.mem.bytesToValue(u32, raw[@sizeOf(Quad) + @offsetOf(Quad, "fill") ..][0..4]));
}

test "command: the columns read back as tagged unions, key split into texture and material" {
    const bytes = comptime blk: {
        var counter: mem.Carver = .{ .buf = null };
        _ = DrawList.init(&counter, 4, 1, 1);
        break :blk counter.off;
    };
    var buf: [bytes]u8 align(mem.column_align) = undefined;
    var carver: mem.Carver = .{ .buf = &buf };
    var d = DrawList.init(&carver, 4, 1, 1);
    const kinds = [_]DrawList.Kind{ .quads, .text, .custom, .quads };
    const firsts = [_]u32{ 0, 5, 6, 3 };
    const counts = [_]u32{ 3, 1, 1, 1 };
    const keys = [_]u32{ 0, 0, 0, (7 << 16) | 2 };
    for (kinds, firsts, counts, keys, 0..) |kind, first, count, key, i| {
        d.cmd.kind[i] = @backingInt(kind);
        d.cmd.first[i] = first;
        d.cmd.count[i] = count;
        d.cmd.key[i] = key;
    }
    d.cmd_len = kinds.len;
    try testing.expectEqual(Cmd{ .quads = .{ .first = 0, .count = 3, .texture = .white, .material = .solid } }, d.command(0));
    try testing.expectEqual(Cmd{ .text = 5 }, d.command(1));
    try testing.expectEqual(Cmd{ .custom = 6 }, d.command(2));
    try testing.expectEqual(Cmd{ .quads = .{ .first = 3, .count = 1, .texture = @fromBackingInt(7), .material = @fromBackingInt(2) } }, d.command(3));
}
