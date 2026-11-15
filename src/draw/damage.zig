//! damage: which part of the window changed since the last frame. Tier 0: columns come from the
//! caller's buffer, nothing is retained between calls except what the caller keeps.
//!
//!   1. hash each node's paint inputs (rect, visible rect, look, text, custom data) into a column
//!   2. compare the column against last frame's, `lanes` rows per step: a row is dirty when its
//!      hash changed or it exists in only one of the two frames
//!   3. union the old and new visible rects of the dirty rows into a `Region` of a few rects
//!   4. after `paint.emit`, keep only the quads that touch the region (`cull`)

const std = @import("std");
const types = @import("../core/types.zig");
const Tree = @import("../core/tree.zig").Tree;
const Look = @import("../core/tree.zig").Look;
const Texts = @import("../core/texts.zig").Texts;
const Customs = @import("../core/customs.zig").Customs;
const DrawList = @import("draw_list.zig").DrawList;
const mem = @import("../core/mem.zig");
const simd = @import("../core/simd.zig");
const W = simd.lanes;
const inf = types.inf;

/// Rects a `Region` holds. Four keeps a region one vector wide per edge.
pub const max_rects = 4;
const R = @Vector(max_rects, f32);

/// The part of the window to repaint: up to `max_rects` rects, stored as one vector per edge.
/// An empty slot has x0 = y0 = inf and x1 = y1 = -inf, so a union with it is the other rect and
/// its area is 0.
pub const Region = struct {
    x0: R = @splat(inf),
    y0: R = @splat(inf),
    x1: R = @splat(-inf),
    y1: R = @splat(-inf),

    pub const empty: Region = .{};

    /// Adds `box` (x0, y0, x1, y1) to the slot whose area grows least by it, the lowest such slot
    /// on a tie: a box inside or overlapping a slot joins it, a distant one takes an empty slot
    /// while there is one. An empty box (x0 >= x1 or y0 >= y1) changes nothing. No branch.
    pub fn add(g: *Region, box: [4]f32) void {
        const has = (box[0] < box[2]) & (box[1] < box[3]);
        const b: [4]f32 = .{
            simd.selF(has, box[0], inf),  simd.selF(has, box[1], inf),
            simd.selF(has, box[2], -inf), simd.selF(has, box[3], -inf),
        };
        // Union is min of the low edges and max of the high ones (Rect.intersect with the signs
        // the other way round).
        const ux0 = @min(g.x0, @as(R, @splat(b[0])));
        const uy0 = @min(g.y0, @as(R, @splat(b[1])));
        const ux1 = @max(g.x1, @as(R, @splat(b[2])));
        const uy1 = @max(g.y1, @as(R, @splat(b[3])));
        const grow = area(ux0, uy0, ux1, uy1) - area(g.x0, g.y0, g.x1, g.y1);
        const best = @as(u32, @ctz(@as(@Int(.unsigned, max_rects), @bitCast(grow == @as(R, @splat(@reduce(.Min, grow)))))));
        const pick = std.simd.iota(u32, max_rects) == @as(@Vector(max_rects, u32), @splat(best));
        g.x0 = @select(f32, pick, ux0, g.x0);
        g.y0 = @select(f32, pick, uy0, g.y0);
        g.x1 = @select(f32, pick, ux1, g.x1);
        g.y1 = @select(f32, pick, uy1, g.y1);
    }

    /// Slot `k` as (x0, y0, x1, y1); empty slots have x0 > x1.
    pub fn rect(g: *const Region, k: u32) [4]f32 {
        const x0: [max_rects]f32 = g.x0;
        const y0: [max_rects]f32 = g.y0;
        const x1: [max_rects]f32 = g.x1;
        const y1: [max_rects]f32 = g.y1;
        return .{ x0[k], y0[k], x1[k], y1[k] };
    }

    /// True when `box` (x0, y0, x1, y1) overlaps a slot by some area. Empty slots overlap
    /// nothing.
    pub fn touches(g: *const Region, box: [4]f32) bool {
        const in = (g.x0 < @as(R, @splat(box[2]))) & (@as(R, @splat(box[0])) < g.x1) &
            (g.y0 < @as(R, @splat(box[3]))) & (@as(R, @splat(box[1])) < g.y1);
        return @reduce(.Or, in);
    }

    /// Number of non-empty slots. Slots fill in order, so they are slots [0, count).
    pub fn count(g: *const Region) u32 {
        return @reduce(.Add, @as(@Vector(max_rects, u32), @intFromBool(g.x0 < g.x1)));
    }

    /// Pixels covered, counting an overlap of two slots twice.
    pub fn pixels(g: *const Region) f32 {
        return @reduce(.Add, area(g.x0, g.y0, g.x1, g.y1));
    }

    inline fn area(x0: R, y0: R, x1: R, y1: R) R {
        const zero: R = @splat(0);
        return @max(x1 - x0, zero) * @max(y1 - y0, zero);
    }
};

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
    /// The dirty rows, in order, `dirty_len` of them (one spare row for the filtering write).
    list: []u32,
    dirty_len: u32 = 0,
    /// The old and new visible rects of every dirty row, unioned.
    region: Region = .empty,

    /// One frame: its row count, per-row hash and visible rect (`Tree.Columns.vis`).
    pub const Gen = struct { len: u32 = 0, hash: []u32, vis: [4][]f32 };

    /// Carves `simd.rows(cap)` rows per column. The first frame after `init` is all dirty.
    pub fn init(carver: *mem.Carver, cap: u32) Damage {
        const rows = simd.rows(cap);
        return .{
            .cap = cap,
            .gen = .{ carveGen(carver, rows), carveGen(carver, rows) },
            .dirty = carver.slice(u32, rows),
            .list = carver.slice(u32, rows),
        };
    }

    fn carveGen(carver: *mem.Carver, rows: usize) Gen {
        return .{ .hash = carver.slice(u32, rows), .vis = .{
            carver.slice(f32, rows), carver.slice(f32, rows),
            carver.slice(f32, rows), carver.slice(f32, rows),
        } };
    }

    /// Records this frame's paint inputs, marks in `dirty` the rows that differ from the last
    /// frame recorded and sets `region` to what they covered then and cover now. Returns the
    /// number of dirty rows.
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

        // The dirty rows as a list, then their rects into the region. A row that exists in one
        // frame only adds that frame's rect; the other is masked to an empty box.
        inline for (0..4) |k| @memcpy(now.vis[k][0..t.len], t.c.vis[k][0..t.len]);
        var w: u32 = 0;
        for (0..@max(now.len, last.len)) |r| w = simd.emit(u32, dm.list, w, @intCast(r), dm.dirty[r] != 0);
        dm.dirty_len = w;
        std.debug.assert(w == @reduce(.Add, count));
        dm.region = .empty;
        for (dm.list[0..w]) |r| {
            inline for (.{ last, now }) |g| {
                const in = r < g.len;
                dm.region.add(.{
                    simd.selF(in, g.vis[0][r], inf),  simd.selF(in, g.vis[1][r], inf),
                    simd.selF(in, g.vis[2][r], -inf), simd.selF(in, g.vis[3][r], -inf),
                });
            }
        }
        dm.cur ^= 1;
        return w;
    }
};

/// Drops from `d`, as `paint.emit` wrote it, every quad whose painted area (rect inside its
/// clip) misses `g`, so a renderer that redraws only the region uploads and draws only what can
/// reach it. Kept quads stay in paint order; a batch left empty is removed, text and custom
/// commands are kept. Two batches with the same key that a removed batch used to separate are
/// left as two commands. Rewrites `d` in place: every write lands at or before the row it reads.
pub fn cull(d: *DrawList, g: *const Region) void {
    const quads_kind = @backingInt(DrawList.Kind.quads);
    var q: u32 = 0;
    var n: u32 = 0;
    for (0..d.cmd_len) |i| {
        const is_quads = d.cmd.kind[i] == quads_kind;
        const first = d.cmd.first[i];
        const q0 = q;
        for (0..d.cmd.count[i] * @intFromBool(is_quads)) |j| {
            const quad = d.quads[first + j];
            d.quads[q] = quad;
            const box: [4]f32 = .{
                @max(quad.rect[0], quad.clip[0]), @max(quad.rect[1], quad.clip[1]),
                @min(quad.rect[2], quad.clip[2]), @min(quad.rect[3], quad.clip[3]),
            };
            q += @intFromBool(g.touches(box));
        }
        d.cmd.kind[n] = d.cmd.kind[i];
        d.cmd.key[n] = d.cmd.key[i];
        d.cmd.first[n] = simd.selU(is_quads, q0, first);
        d.cmd.count[n] = simd.selU(is_quads, q - q0, d.cmd.count[i]);
        n += @intFromBool(simd.orB(!is_quads, q > q0));
    }
    d.quad_len = q;
    d.cmd_len = n;
}

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
    d: DrawList,

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
            .d = DrawList.init(carver, cap, 4, 4),
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

test "Region.add: overlapping boxes merge, distant ones take free slots, then the cheapest" {
    var g: Region = .empty;
    try testing.expectEqual(0, g.count());
    g.add(.{ 5, 5, 5, 9 }); // empty: no change
    try testing.expectEqual(0, g.count());
    g.add(.{ 0, 0, 10, 10 });
    g.add(.{ 5, 5, 15, 10 }); // overlaps slot 0
    try testing.expectEqual(1, g.count());
    try testing.expectEqual([4]f32{ 0, 0, 15, 10 }, g.rect(0));
    g.add(.{ 2, 2, 4, 4 }); // inside slot 0: grows nothing
    try testing.expectEqual(1, g.count());
    g.add(.{ 100, 100, 110, 110 });
    g.add(.{ 200, 0, 210, 10 });
    g.add(.{ 0, 200, 10, 210 });
    try testing.expectEqual(4, g.count());
    try testing.expectEqual(150 + 100 * 3, g.pixels());
    // Full: a fifth box joins the slot it grows least, here slot 1 at (100, 100).
    g.add(.{ 112, 100, 120, 110 });
    try testing.expectEqual(4, g.count());
    try testing.expectEqual([4]f32{ 100, 100, 120, 110 }, g.rect(1));
}

test "Damage.frame: one changed node gives a region of one rect, that node's" {
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
    try testing.expectEqual(400 * 300, dm.region.rect(0)[2] * dm.region.rect(0)[3]); // first frame: everything
    sc = .build(&buf, .{});
    _ = dm.frame(&sc.t, &sc.tx, &sc.cu, sc.s.buf[0..sc.s.len]);
    try testing.expectEqual(0, dm.region.count());

    sc = .build(&buf, .{ .ok_fill = .rgb(90, 90, 200) });
    try testing.expectEqual(1, dm.frame(&sc.t, &sc.tx, &sc.cu, sc.s.buf[0..sc.s.len]));
    try testing.expectEqual(1, dm.region.count());
    try testing.expectEqual(sc.t.rect(Scene.ok).array(), dm.region.rect(0));
    try testing.expectEqual(40 * 20, dm.region.pixels());
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

const paint = @import("paint.zig");

test "cull: one changed node repaints the quads under one small rect" {
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

    // First frame: the region is the window and every quad is kept.
    var sc: Scene = .build(&buf, .{});
    _ = dm.frame(&sc.t, &sc.tx, &sc.cu, sc.s.buf[0..sc.s.len]);
    paint.emit(&sc.t, &sc.tx, &sc.cu, sc.s.buf[0..sc.s.len], &sc.d);
    const all = sc.d.quad_len;
    const all_cmds = sc.d.cmd_len;
    try testing.expectEqual(6, all); // root, bar, three buttons, panel
    cull(&sc.d, &dm.region);
    try testing.expectEqual(all, sc.d.quad_len);
    try testing.expectEqual(all_cmds, sc.d.cmd_len);

    // One button changes: the region is that button, and only the quads under it are drawn:
    // the root's background, the toolbar and the button itself, in paint order, one batch.
    sc = .build(&buf, .{ .ok_fill = .rgb(90, 90, 200) });
    _ = dm.frame(&sc.t, &sc.tx, &sc.cu, sc.s.buf[0..sc.s.len]);
    paint.emit(&sc.t, &sc.tx, &sc.cu, sc.s.buf[0..sc.s.len], &sc.d);
    cull(&sc.d, &dm.region);
    try testing.expectEqual(1, dm.region.count());
    try testing.expectEqual(40 * 20, dm.region.pixels());
    try testing.expectEqual(3, sc.d.quad_len);
    try testing.expectEqual(sc.t.rect(0).array(), sc.d.quads[0].rect);
    try testing.expectEqual(sc.t.rect(1).array(), sc.d.quads[1].rect);
    try testing.expectEqual(sc.t.rect(Scene.ok).array(), sc.d.quads[2].rect);
    try testing.expectEqual(Color.rgb(90, 90, 200).bitsOf(), sc.d.quads[2].fill);
    // Text and custom commands stay; the batch after them (the panel) is gone.
    try testing.expectEqual(3, sc.d.cmd_len);
    try testing.expectEqual(@import("draw_list.zig").Cmd{ .quads = .{ .first = 0, .count = 3, .texture = .white, .material = .solid } }, sc.d.command(0));
    try testing.expectEqual(@import("draw_list.zig").Cmd{ .text = 0 }, sc.d.command(1));
    try testing.expectEqual(@import("draw_list.zig").Cmd{ .custom = 0 }, sc.d.command(2));
}

test "cull: a quad clipped away from the region is dropped even when its rect reaches it" {
    var buf: [Scene.bytes]u8 align(mem.column_align) = undefined;
    var sc: Scene = .build(&buf, .{});
    paint.emit(&sc.t, &sc.tx, &sc.cu, sc.s.buf[0..sc.s.len], &sc.d);
    // Clip the first quad to its left half and damage only its right half.
    const r = sc.d.quads[0].rect;
    sc.d.quads[0].clip = .{ r[0], r[1], (r[0] + r[2]) / 2, r[3] };
    var g: Region = .empty;
    g.add(.{ (r[0] + r[2]) / 2 + 1, r[1], r[2], r[3] });
    const before = sc.d.quad_len;
    cull(&sc.d, &g);
    // The root is dropped; the quads drawn over the damaged half stay.
    try testing.expect(sc.d.quad_len < before);
    for (sc.d.quads[0..sc.d.quad_len]) |quad| try testing.expect(!std.meta.eql(quad.rect, r));
}
