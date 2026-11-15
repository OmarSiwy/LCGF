//! damage: which part of the window changed since the last frame. Tier 0: columns come from the
//! caller's buffer, nothing is retained between calls except what the caller keeps.
//!
//!   1. hash each node's paint inputs (rect, visible rect, look, text, custom data) into a column

const std = @import("std");
const types = @import("../core/types.zig");
const Tree = @import("../core/tree.zig").Tree;
const Look = @import("../core/tree.zig").Look;
const Texts = @import("../core/texts.zig").Texts;
const Customs = @import("../core/customs.zig").Customs;

/// Everything sweep 1 of `paint.emit` reads for one node's quad, as one hashed row.
const QuadInputs = extern struct { rect: [4]f32, vis: [4]f32, look: Look };

/// Writes, for every node of `t`, a hash of what painting it reads: its rect, its visible
/// (clipped) rect, its look, and the text run or custom draw it owns. Two frames that paint a
/// node identically give it the same hash. `out` has at least `t.len` rows. `strings` is the
/// storage `tx`'s spans index, as passed to `paint.emit`.
pub fn hashNodes(t: *const Tree, tx: *const Texts, cu: *const Customs, strings: []const u8, out: []u32) void {
    const c = &t.c;
    for (0..t.len) |i| {
        const row: QuadInputs = .{
            .rect = .{ c.rect[0][i], c.rect[1][i], c.rect[2][i], c.rect[3][i] },
            .vis = .{ c.vis[0][i], c.vis[1][i], c.vis[2][i], c.vis[3][i] },
            .look = c.look[i],
        };
        out[i] = @truncate(std.hash.Wyhash.hash(0, std.mem.asBytes(&row)));
    }
    // Side lists: one row per run or draw that exists, folded into its node's hash.
    for (0..tx.len) |k| {
        const n = tx.c.node[k];
        const run = extern struct { pad: [4]f32, px: f32, color: u32, font: u32 }{
            .pad = .{ c.pad_lo[0][n], c.pad_lo[1][n], c.pad_hi[0][n], c.pad_hi[1][n] },
            .px = tx.c.px[k],
            .color = tx.c.color[k],
            .font = tx.c.font[k],
        };
        const text = strings[tx.c.start[k]..][0..tx.c.bytes[k]];
        out[n] ^= @truncate(std.hash.Wyhash.hash(std.hash.Wyhash.hash(1, std.mem.asBytes(&run)), text));
    }
    for (0..cu.len) |k| {
        const draw = extern struct { data: u64, id: u32, _pad: u32 = 0 }{ .data = cu.c.data[k], .id = cu.c.id[k] };
        out[cu.c.node[k]] ^= @truncate(std.hash.Wyhash.hash(2, std.mem.asBytes(&draw)));
    }
}

const testing = std.testing;
const mem = @import("../core/mem.zig");
const simd = @import("../core/simd.zig");
const layout = @import("../layout/layout.zig");
const Strings = @import("../core/strings.zig").Strings;
const Id = types.Id;
const Color = types.Color;

/// A 400x300 window: a toolbar of three buttons, a label, a custom view and a panel, built the
/// same way every frame except for what `Edit` changes.
const Scene = struct {
    t: Tree,
    tx: Texts,
    cu: Customs,
    s: Strings,
    hash: []u32,

    const cap = 16;
    const bytes = blk: {
        @setEvalBranchQuota(10_000);
        var counter: mem.Carver = .{ .buf = null };
        _ = carve(&counter);
        break :blk counter.off;
    };
    fn carve(carver: *mem.Carver) Scene {
        return .{
            .t = Tree.init(carver, cap),
            .tx = Texts.init(carver, 4),
            .cu = Customs.init(carver, 4),
            .s = .{ .buf = carver.slice(u8, 64) },
            .hash = carver.slice(u32, simd.rows(cap)),
        };
    }

    const Edit = struct { ok_fill: Color = .rgb(40, 40, 40), label: []const u8 = "hello", view_data: u64 = 7 };
    const ok = 4;

    fn build(buf: *align(mem.column_align) [bytes]u8, e: Edit) Scene {
        var carver: mem.Carver = .{ .buf = buf };
        var sc = carve(&carver);
        const t = &sc.t;
        const button: types.Style = .{ .size = .{ .px(40), .px(20) }, .fill = .rgb(40, 40, 40), .radius = 3 };
        _ = t.push(0, Id.from("root"), &.{ .size = .{ .px(400), .px(300) }, .clip = true, .fill = .rgb(10, 10, 10) });
        const bar = t.push(0, Id.from("bar"), &.{ .dir = .x, .size = .{ .fill, .fit }, .pad = @splat(4), .gap = 4, .fill = .rgb(30, 30, 30) });
        _ = t.push(bar, Id.from("open"), &button);
        _ = t.push(bar, Id.from("save"), &button);
        var ok_style = button;
        ok_style.fill = e.ok_fill;
        _ = t.push(bar, Id.from("ok"), &ok_style);
        t.seal(bar);
        const label = t.push(0, Id.from("label"), &.{ .pad = @splat(2) });
        t.c.text[label] = sc.tx.push(label, sc.s.add(e.label), &.{ .px = 10 });
        sc.tx.c.w[0] = 40;
        sc.tx.c.h[0] = 10;
        const view = t.push(0, Id.from("view"), &.{ .size = .{ .px(100), .px(100) } });
        t.c.custom[view] = sc.cu.push(view, Id.from("view"), e.view_data);
        _ = t.push(0, Id.from("panel"), &.{ .size = .{ .fill, .fill }, .fill = .rgb(20, 20, 20) });
        t.seal(0);
        layout.run(t, &sc.tx, .{ 400, 300 });
        hashNodes(t, &sc.tx, &sc.cu, sc.s.buf[0..sc.s.len], sc.hash);
        return sc;
    }

    /// Rows whose hash differs between `a` and `b`, as a bit set.
    fn changed(a: *const Scene, b: *const Scene) u32 {
        var set: u32 = 0;
        for (a.hash[0..a.t.len], b.hash[0..b.t.len], 0..) |x, y, i| set |= @as(u32, @intFromBool(x != y)) << @intCast(i);
        return set;
    }
};

test "hashNodes: the same frame hashes the same, one changed node changes one small row" {
    var buf_a: [Scene.bytes]u8 align(mem.column_align) = undefined;
    var buf_b: [Scene.bytes]u8 align(mem.column_align) = undefined;
    const a: Scene = .build(&buf_a, .{});
    const same: Scene = .build(&buf_b, .{});
    try testing.expectEqual(0, Scene.changed(&a, &same));

    const b: Scene = .build(&buf_b, .{ .ok_fill = .rgb(90, 90, 200) });
    try testing.expectEqual(1 << Scene.ok, Scene.changed(&a, &b));
    // The one node to repaint is a 40x20 button in a 400x300 window.
    const r = b.t.rect(Scene.ok);
    try testing.expectEqual(40 * 20, r.w() * r.h());
}

test "hashNodes: text content and custom data count as paint inputs of their node" {
    var buf_a: [Scene.bytes]u8 align(mem.column_align) = undefined;
    var buf_b: [Scene.bytes]u8 align(mem.column_align) = undefined;
    const a: Scene = .build(&buf_a, .{});
    var b: Scene = .build(&buf_b, .{ .label = "hellO" });
    try testing.expectEqual(1 << 5, Scene.changed(&a, &b));
    b = .build(&buf_b, .{ .view_data = 8 });
    try testing.expectEqual(1 << 6, Scene.changed(&a, &b));
}
