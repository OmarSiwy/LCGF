//! damage: which part of the window changed since the last frame. Tier 0: columns come from the
//! caller's buffer, nothing is retained between calls except what the caller keeps.
//!
//!   1. hash each node's paint inputs (rect, visible rect, look, text, custom data) into a column
//!   2. compare the column against last frame's, `lanes` rows per step: a row is dirty when its
//!      hash changed or it exists in only one of the two frames

const std = @import("std");
const types = @import("../core/types.zig");
const Tree = @import("../core/tree.zig").Tree;
const Look = @import("../core/tree.zig").Look;
const Texts = @import("../core/texts.zig").Texts;
const Customs = @import("../core/customs.zig").Customs;
const mem = @import("../core/mem.zig");
const simd = @import("../core/simd.zig");
const W = simd.lanes;

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

/// Damage state across frames: two generations of the per-node hash, written alternately, as
/// prototype/ui.zig `Context.trees` keeps two trees. Rows are compared by index, so a node that
/// moves to another row counts as changed in both rows.
pub const Damage = struct {
    cap: u32,
    gen: [2]Gen,
    /// The generation the next `frame` writes; the other one is last frame's.
    cur: u1 = 0,
    /// 1 for a row to repaint, 0 otherwise, for rows [0, padded(max(len, last len))).
    dirty: []u32,

    pub const Gen = struct { len: u32 = 0, hash: []u32 };

    /// Carves `simd.rows(cap)` rows per column. The first frame after `init` is all dirty.
    pub fn init(carver: *mem.Carver, cap: u32) Damage {
        const rows = simd.rows(cap);
        return .{
            .cap = cap,
            .gen = .{ .{ .hash = carver.slice(u32, rows) }, .{ .hash = carver.slice(u32, rows) } },
            .dirty = carver.slice(u32, rows),
        };
    }

    /// Records this frame's paint inputs and marks in `dirty` the rows that differ from the last
    /// frame recorded. Returns the number of dirty rows.
    pub fn frame(dm: *Damage, t: *const Tree, tx: *const Texts, cu: *const Customs, strings: []const u8) u32 {
        std.debug.assert(t.len <= dm.cap);
        const now = &dm.gen[dm.cur];
        const last = &dm.gen[dm.cur ^ 1];
        now.len = t.len;
        hashNodes(t, tx, cu, strings, now.hash);
        const both = simd.u(@min(now.len, last.len));
        const either = simd.u(@max(now.len, last.len));
        var count: simd.U = @splat(0);
        var i: usize = 0;
        while (i < simd.padded(@max(now.len, last.len))) : (i += W) {
            const row = simd.iota + simd.u(@intCast(i));
            const changed = (simd.loadU(now.hash, i) != simd.loadU(last.hash, i)) | !(row < both);
            const d: simd.U = @intFromBool(changed & (row < either));
            simd.storeU(dm.dirty, i, d);
            count += d;
        }
        dm.cur ^= 1;
        return @reduce(.Add, count);
    }
};

const testing = std.testing;
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

test "Damage.frame: first frame all dirty, a repeat none, a one-node change that one row" {
    var dm_buf: [
        blk: {
            var counter: mem.Carver = .{ .buf = null };
            _ = Damage.init(&counter, Scene.cap);
            break :blk counter.off;
        }
    ]u8 align(mem.column_align) = undefined;
    var carver: mem.Carver = .{ .buf = &dm_buf };
    var dm = Damage.init(&carver, Scene.cap);
    var buf: [Scene.bytes]u8 align(mem.column_align) = undefined;

    var sc: Scene = .build(&buf, .{});
    try testing.expectEqual(8, dm.frame(&sc.t, &sc.tx, &sc.cu, sc.s.buf[0..sc.s.len]));
    sc = .build(&buf, .{});
    try testing.expectEqual(0, dm.frame(&sc.t, &sc.tx, &sc.cu, sc.s.buf[0..sc.s.len]));
    sc = .build(&buf, .{ .ok_fill = .rgb(90, 90, 200) });
    try testing.expectEqual(1, dm.frame(&sc.t, &sc.tx, &sc.cu, sc.s.buf[0..sc.s.len]));
    try testing.expectEqual(1, dm.dirty[Scene.ok]);
    // The one dirty row is a 40x20 button in a 400x300 window.
    const r = sc.t.rect(Scene.ok);
    try testing.expectEqual(40 * 20, r.w() * r.h());
    // Back to the first look: the same row again, compared with the frame before.
    sc = .build(&buf, .{});
    try testing.expectEqual(1, dm.frame(&sc.t, &sc.tx, &sc.cu, sc.s.buf[0..sc.s.len]));
    try testing.expectEqual(1, dm.dirty[Scene.ok]);
}

test "Damage.frame: rows only one frame has are dirty, padding rows never are" {
    var dm_buf: [
        blk: {
            var counter: mem.Carver = .{ .buf = null };
            _ = Damage.init(&counter, Scene.cap);
            break :blk counter.off;
        }
    ]u8 align(mem.column_align) = undefined;
    var carver: mem.Carver = .{ .buf = &dm_buf };
    var dm = Damage.init(&carver, Scene.cap);
    var buf: [Scene.bytes]u8 align(mem.column_align) = undefined;
    var sc: Scene = .build(&buf, .{});
    _ = dm.frame(&sc.t, &sc.tx, &sc.cu, sc.s.buf[0..sc.s.len]);
    // Drop the last node (the panel): its row disappears.
    sc.t.len -= 1;
    try testing.expectEqual(1, dm.frame(&sc.t, &sc.tx, &sc.cu, sc.s.buf[0..sc.s.len]));
    try testing.expectEqual(1, dm.dirty[7]);
    for (dm.dirty[8..simd.padded(8)]) |d| try testing.expectEqual(0, d);
    // And back: it reappears.
    sc.t.len += 1;
    try testing.expectEqual(1, dm.frame(&sc.t, &sc.tx, &sc.cu, sc.s.buf[0..sc.s.len]));
    try testing.expectEqual(1, dm.dirty[7]);
}
