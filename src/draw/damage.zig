//! damage: which part of the window changed since the last frame. Tier 0: columns come from the
//! caller's buffer, nothing is retained between calls except what the caller keeps.
//!
//!   1. hash each node's paint inputs (rect, visible rect, look, text, custom data) into a column
//!   2. compare the column against last frame's, `lanes` rows per step: a row is dirty when its
//!      hash changed or it exists in only one of the two frames
//!   3. union the old and new visible rects of the dirty rows into a `Region` of a few rects
//!   4. after `paint.emit`, keep only the quads that touch the region (`cull`)
//!   5. hand the region to the renderer in `DrawList.damage`, with the scissor rects to clip to

const std = @import("std");
const geometry = @import("geometry.zig");
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
const V4 = @Vector(4, f32);
/// The empty box (x0, y0, x1, y1): the identity of a union.
const no_box: V4 = .{ inf, inf, -inf, -inf };

/// The part of the window to repaint: up to `max_rects` rects, stored as one vector per edge.
/// An empty slot has x0 = y0 = inf and x1 = y1 = -inf, so a union with it is the other rect and
/// its area is 0.
pub const Region = struct {
    x0: R = @splat(inf),
    y0: R = @splat(inf),
    x1: R = @splat(-inf),
    y1: R = @splat(-inf),

    pub const empty: Region = .{};
    /// One unbounded slot: repaint the whole target.
    pub const everything: Region = .{
        .x0 = .{ -inf, inf, inf, inf },
        .y0 = .{ -inf, inf, inf, inf },
        .x1 = .{ inf, -inf, -inf, -inf },
        .y1 = .{ inf, -inf, -inf, -inf },
    };

    /// Adds `box` (x0, y0, x1, y1) to the slot whose area grows least by it, the lowest such slot
    /// on a tie: a box inside or overlapping a slot joins it, a distant one takes an empty slot
    /// while there is one. An empty box (x0 >= x1 or y0 >= y1) changes nothing. No branch.
    pub fn add(g: *Region, box: [4]f32) void {
        const has: @Vector(4, bool) = @splat((box[0] < box[2]) & (box[1] < box[3]));
        const b: [4]f32 = @select(f32, has, @as(V4, box), no_box);
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

    /// The smallest rect holding every slot, for a back end with one scissor rect.
    pub fn bounds(g: *const Region) [4]f32 {
        return .{ @reduce(.Min, g.x0), @reduce(.Min, g.y0), @reduce(.Max, g.x1), @reduce(.Max, g.y1) };
    }

    /// `box` as a scissor rect (x, y, w, h) on a target of `size` physical pixels, with
    /// `scale` physical pixels per logical one: rounded outwards to whole pixels and clamped to
    /// the target, so an empty box gives w = h = 0 and `everything` the whole target.
    pub fn scissor(box: [4]f32, size: [2]u32, scale: f32) [4]u32 {
        const lo = @Vector(2, f32){ box[0], box[1] } * @as(@Vector(2, f32), @splat(scale));
        const hi = @Vector(2, f32){ box[2], box[3] } * @as(@Vector(2, f32), @splat(scale));
        const top: @Vector(2, f32) = .{ @floatFromInt(size[0]), @floatFromInt(size[1]) };
        const zero: @Vector(2, f32) = @splat(0);
        const a = @min(@max(@floor(lo), zero), top);
        const b = @max(@min(@ceil(hi), top), a);
        const p: @Vector(2, u32) = @intFromFloat(a);
        const e: @Vector(2, u32) = @intFromFloat(b - a);
        return .{ p[0], p[1], e[0], e[1] };
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
const QuadInputs = extern struct { rect: [4]f32, vis: [4]f32, look: Look, border: f32, uv: [4]f32, radii: [4]f32, alpha: f32, world: [6]f32, clip_radii: [4]f32, prepared_texture: u32, paint_revision: u32 };

/// Writes, for every node of `t`, a hash of what painting it reads: its rect, its visible
/// (clipped) rect, its look, and the text run or custom draw it owns. Two frames that paint a
/// node identically give it the same hash. `out` has at least `t.len` rows. `strings` is the
/// storage `tx`'s spans index, as passed to `paint.emit`.
pub fn hashNodes(t: *const Tree, tx: *const Texts, cu: *const Customs, strings: []const u8, out: []u32) void {
    hashInto(t, tx, cu, strings, out, null);
}

/// `hashNodes`, also writing each node's paint bounds into `bounds` (`[4][]f32`, or null for
/// none) in the same row loop.
inline fn hashInto(t: *const Tree, tx: *const Texts, cu: *const Customs, strings: []const u8, out: []u32, bounds: anytype) void {
    const c = &t.c;
    for (0..t.len) |i| {
        if (@TypeOf(bounds) != @TypeOf(null)) {
            const b = geometry.nodeBounds(t, i);
            inline for (0..4) |k| bounds[k][i] = b[k];
        }
        const x = &t.x;
        const own = c.extra[i];
        const row: QuadInputs = .{
            .rect = geometry.nodeRect(t, i),
            .vis = .{ c.vis[0][i], c.vis[1][i], c.vis[2][i], c.vis[3][i] },
            .look = c.look[i],
            .border = x.row[own].border,
            .uv = x.row[own].uv,
            .radii = @import("../core/tree.zig").radiiOf(x.row[own].radii, c.look[i].radius),
            .alpha = geometry.nodeAlpha(t, i),
            .world = geometry.nodeWorld(t, i),
            .clip_radii = geometry.nodeClipRadii(t, i),
            .prepared_texture = x.row[own].prepared_texture,
            .paint_revision = x.row[own].paint_revision,
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
        if (@TypeOf(bounds) != @TypeOf(null)) {
            // A run is clipped by its parent, not its node (`paint.emit`): its measured extent,
            // from the content box's corner, may reach past the node, and repaints with it.
            const x0 = c.rect[0][n] + c.pad_lo[0][n];
            const y0 = c.rect[1][n] + c.pad_lo[1][n];
            const box = geometry.paintBounds(
                .{ x0, y0, x0 + tx.c.w[k], y0 + tx.c.h[k] },
                @splat(0),
                geometry.nodeWorld(t, n),
                geometry.nodeClip(t, n),
            );
            const node: V4 = .{ bounds[0][n], bounds[1][n], bounds[2][n], bounds[3][n] };
            const lo = @min(node, @as(V4, box));
            const hi = @max(node, @as(V4, box));
            const both: V4 = .{ lo[0], lo[1], hi[2], hi[3] };
            // A union only of what has area: an empty side's corners are not a box.
            const has_node: @Vector(4, bool) = @splat(geometry.hasArea(node));
            const has_box: @Vector(4, bool) = @splat(geometry.hasArea(box));
            const either = @select(f32, has_node, both, @as(V4, box));
            const pick: [4]f32 = @select(f32, has_box, either, node);
            inline for (0..4) |e| bounds[e][n] = pick[e];
        }
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

    /// No rows: for a context that does not track damage.
    pub const none: Damage = .{ .cap = 0, .gen = @splat(.{ .hash = &.{}, .vis = @splat(&.{}) }), .dirty = &.{}, .list = &.{} };

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
        hashInto(t, tx, cu, strings, now.hash, &now.vis);
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

        // The dirty rows as a list, then their rects (`now.vis`, written by `hashInto`) into the
        // region. A row that exists in one frame only adds that frame's rect; the other is
        // masked to an empty box.
        var w: u32 = 0;
        for (0..@max(now.len, last.len)) |r| w = simd.emit(u32, dm.list, w, @intCast(r), dm.dirty[r] != 0);
        dm.dirty_len = w;
        std.debug.assert(w == @reduce(.Add, count));
        dm.region = .empty;
        for (dm.list[0..w]) |r| {
            inline for (.{ last, now }) |g| {
                // Loaded whether or not the row exists (the columns have `cap` rows), so the
                // select is a blend: a select whose operand is loaded only for it compiles to
                // branches (docs/CHECKS.md section 2).
                const box: V4 = .{ g.vis[0][r], g.vis[1][r], g.vis[2][r], g.vis[3][r] };
                const in: @Vector(4, bool) = @splat(r < g.len);
                dm.region.add(@select(f32, in, box, no_box));
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
/// Sets `d.damage` to `g`, which is how the renderer learns what to redraw.
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
            const box = geometry.quadBounds(quad);
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
    d.damage = g.*;
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

    const Edit = struct {
        ok_fill: Color = .rgb(40, 40, 40),
        ok_width: f32 = 40,
        open_fill: Color = .rgb(40, 40, 40),
        label: []const u8 = "hello",
        /// The label run's measured width; past 40 its glyphs overflow the label's node.
        label_w: f32 = 40,
        view_data: u64 = 7,
        panel_fill: Color = .rgb(20, 20, 20),
    };
    const ok = 4;

    fn build(buf: *align(mem.column_align) [bytes]u8, e: Edit) Scene {
        var carver: mem.Carver = .{ .buf = buf };
        var sc = carve(&carver);
        const t = &sc.t;
        const button: types.Style = .{ .size = .{ .px(40), .px(20) }, .fill = .rgb(40, 40, 40), .radius = 3 };
        _ = t.push(0, Id.from("root"), &.{ .size = .{ .px(400), .px(300) }, .clip = true, .fill = .rgb(10, 10, 10) });
        const bar = t.push(0, Id.from("bar"), &.{ .dir = .x, .size = .{ .fill, .fit }, .pad = @splat(4), .gap = 4, .fill = .rgb(30, 30, 30) });
        var open_style = button;
        open_style.fill = e.open_fill;
        _ = t.push(bar, Id.from("open"), &open_style);
        _ = t.push(bar, Id.from("save"), &button);
        var ok_style = button;
        ok_style.fill = e.ok_fill;
        ok_style.size[0] = .px(e.ok_width);
        _ = t.push(bar, Id.from("ok"), &ok_style);
        t.seal(bar);
        const label = t.push(0, Id.from("label"), &.{
            .size = .{ .px(44), .px(14) },
            .pad = @splat(2),
        });
        t.c.text[label] = sc.tx.push(label, sc.s.add(e.label), &.{ .px = 10 });
        sc.tx.c.w[0] = e.label_w;
        sc.tx.c.h[0] = 10;
        const view = t.push(0, Id.from("view"), &.{ .size = .{ .px(100), .px(100) } });
        t.c.custom[view] = sc.cu.push(view, Id.from("view"), e.view_data);
        _ = t.push(0, Id.from("panel"), &.{ .size = .{ .fill, .fill }, .fill = e.panel_fill });
        t.seal(0);
        layout.run(t, &sc.tx, .{ 400, 300 });
        @import("inherit.zig").all(t);
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

test "DrawList.damage: a renderer scissors one small rect after a one-node change" {
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
    const target: [2]u32 = .{ 800, 600 }; // 400x300 at scale 2

    // A frame that was not culled says "everything"; so does the first culled one.
    var sc: Scene = .build(&buf, .{});
    paint.emit(&sc.t, &sc.tx, &sc.cu, sc.s.buf[0..sc.s.len], &sc.d);
    try testing.expectEqual([4]u32{ 0, 0, 800, 600 }, Region.scissor(sc.d.damage.bounds(), target, 2));
    _ = dm.frame(&sc.t, &sc.tx, &sc.cu, sc.s.buf[0..sc.s.len]);
    cull(&sc.d, &dm.region);
    try testing.expectEqual([4]u32{ 0, 0, 800, 600 }, Region.scissor(sc.d.damage.bounds(), target, 2));

    // The host's loop over the damage rects: one scissor, the changed button's, in pixels.
    sc = .build(&buf, .{ .ok_fill = .rgb(90, 90, 200) });
    _ = dm.frame(&sc.t, &sc.tx, &sc.cu, sc.s.buf[0..sc.s.len]);
    paint.emit(&sc.t, &sc.tx, &sc.cu, sc.s.buf[0..sc.s.len], &sc.d);
    cull(&sc.d, &dm.region);
    const ok = sc.t.rect(Scene.ok);
    var scissors: u32 = 0;
    for (0..sc.d.damage.count()) |k| {
        const s = Region.scissor(sc.d.damage.rect(@intCast(k)), target, 2);
        try testing.expectEqual([4]u32{ @intFromFloat(ok.x0 * 2), @intFromFloat(ok.y0 * 2), 80, 40 }, s);
        scissors += 1;
    }
    try testing.expectEqual(1, scissors);
    try testing.expectEqual(sc.d.damage.rect(0), sc.d.damage.bounds());
}

test "Region.scissor: rounds outwards, clamps to the target, empty stays empty" {
    try testing.expectEqual([4]u32{ 1, 2, 3, 3 }, Region.scissor(.{ 1.5, 2.2, 3.1, 4.9 }, .{ 10, 10 }, 1));
    try testing.expectEqual([4]u32{ 0, 0, 10, 10 }, Region.scissor(.{ -5, -5, 50, 50 }, .{ 10, 10 }, 1));
    try testing.expectEqual(0, Region.scissor(Region.empty.bounds(), .{ 10, 10 }, 1)[2]);
    try testing.expectEqual(0, Region.scissor(.{ 20, 20, 30, 30 }, .{ 10, 10 }, 1)[3]);
}

/// A damage state for `Scene`, in its own buffer so it outlives every frame's scene.
const Tracker = struct {
    buf: [bytes]u8 align(mem.column_align) = undefined,
    dm: Damage = undefined,

    const bytes = blk: {
        var counter: mem.Carver = .{ .buf = null };
        _ = Damage.init(&counter, Scene.cap);
        break :blk counter.off;
    };
    fn init(tr: *Tracker) void {
        var carver: mem.Carver = .{ .buf = &tr.buf };
        tr.dm = Damage.init(&carver, Scene.cap);
    }
    /// One frame: build, record, paint, cull.
    fn frame(tr: *Tracker, buf: *align(mem.column_align) [Scene.bytes]u8, e: Scene.Edit) Scene {
        var sc: Scene = .build(buf, e);
        _ = tr.dm.frame(&sc.t, &sc.tx, &sc.cu, sc.s.buf[0..sc.s.len]);
        paint.emit(&sc.t, &sc.tx, &sc.cu, sc.s.buf[0..sc.s.len], &sc.d);
        cull(&sc.d, &tr.dm.region);
        return sc;
    }
};

/// True when some slot of `g` holds all of `box`, or `box` is empty.
fn covered(g: *const Region, box: [4]f32) bool {
    if (!(box[0] < box[2] and box[1] < box[3])) return true;
    for (0..max_rects) |k| {
        const r = g.rect(@intCast(k));
        if (r[0] <= box[0] and r[1] <= box[1] and r[2] >= box[2] and r[3] >= box[3]) return true;
    }
    return false;
}

test "damage: an idle frame repaints nothing" {
    var tr: Tracker = .{};
    tr.init();
    var buf: [Scene.bytes]u8 align(mem.column_align) = undefined;
    _ = tr.frame(&buf, .{});
    const sc = tr.frame(&buf, .{});
    try testing.expectEqual(0, tr.dm.dirty_len);
    try testing.expectEqual(0, tr.dm.region.count());
    try testing.expectEqual(0, sc.d.quad_len);
    try testing.expectEqual(0, Region.scissor(sc.d.damage.bounds(), .{ 400, 300 }, 1)[2]);
}

test "damage: a resized node repaints the union of its old and new rect, one rect" {
    var tr: Tracker = .{};
    tr.init();
    var buf: [Scene.bytes]u8 align(mem.column_align) = undefined;
    const before = tr.frame(&buf, .{});
    const old = before.t.rect(Scene.ok);
    const sc = tr.frame(&buf, .{ .ok_width = 60 });
    const new = sc.t.rect(Scene.ok);
    try testing.expectEqual(1, tr.dm.dirty_len);
    try testing.expectEqual(1, tr.dm.region.count());
    try testing.expectEqual([4]f32{ old.x0, old.y0, @max(old.x1, new.x1), old.y1 }, tr.dm.region.rect(0));
    try testing.expectEqual(60 * 20, tr.dm.region.pixels());
}

test "damage: scattered changes stay within four rects that cover every changed node" {
    var tr: Tracker = .{};
    tr.init();
    var buf: [Scene.bytes]u8 align(mem.column_align) = undefined;
    _ = tr.frame(&buf, .{});
    const sc = tr.frame(&buf, .{ .open_fill = .white, .ok_fill = .white, .label = "bye", .view_data = 1, .panel_fill = .white });
    try testing.expectEqual(5, tr.dm.dirty_len);
    try testing.expect(tr.dm.region.count() <= max_rects);
    for (tr.dm.list[0..tr.dm.dirty_len]) |r| try testing.expect(covered(&tr.dm.region, sc.t.rect(r).array()));
    // Still less than the window.
    try testing.expect(tr.dm.region.pixels() < 400 * 300);
}

test "damage: a text run that overflows its node repaints where its glyphs were and are" {
    var tr: Tracker = .{};
    tr.init();
    var buf: [Scene.bytes]u8 align(mem.column_align) = undefined;
    _ = tr.frame(&buf, .{ .label_w = 140 });
    const sc = tr.frame(&buf, .{ .label = "hellO", .label_w = 140 });
    // The run starts inside the node's padding and runs 100 px past the node's right edge:
    // its parent (the window) clips it, not the node.
    const node = sc.t.rect(5);
    try testing.expect(covered(&tr.dm.region, .{
        node.x0 + 2,
        node.y0 + 2,
        node.x0 + 142,
        node.y0 + 12,
    }));
}

test "damage: random edits over many frames, every changed node's old and new rect is covered" {
    var tr: Tracker = .{};
    tr.init();
    var bufs: [2][Scene.bytes]u8 align(mem.column_align) = undefined;
    var prng: std.Random.DefaultPrng = .init(0x5eed);
    const rand = prng.random();
    const fills = [_]Color{ .rgb(40, 40, 40), .white, .rgb(200, 0, 0) };
    const labels = [_][]const u8{ "hello", "hi", "a longer label" };
    var last = tr.frame(&bufs[0], .{});
    for (1..200) |f| {
        const e: Scene.Edit = .{
            .ok_fill = fills[rand.uintLessThan(usize, fills.len)],
            .ok_width = @floatFromInt(20 + 20 * rand.uintLessThan(u32, 3)),
            .open_fill = fills[rand.uintLessThan(usize, fills.len)],
            .label = labels[rand.uintLessThan(usize, labels.len)],
            .view_data = rand.uintLessThan(u64, 3),
            .panel_fill = fills[rand.uintLessThan(usize, fills.len)],
        };
        const sc = tr.frame(&bufs[f % 2], e);
        // Reference: a node needs repainting when anything paint reads from it differs.
        for (0..sc.t.len) |i| {
            const same = std.meta.eql(sc.t.rect(@intCast(i)), last.t.rect(@intCast(i))) and
                std.meta.eql(sc.t.c.look[i], last.t.c.look[i]) and sc.t.border(@intCast(i)) == last.t.border(@intCast(i)) and
                sc.hash[i] == last.hash[i];
            if (!same) {
                try testing.expectEqual(1, tr.dm.dirty[i]);
                try testing.expect(covered(&tr.dm.region, sc.t.rect(@intCast(i)).array()));
                try testing.expect(covered(&tr.dm.region, last.t.rect(@intCast(i)).array()));
            }
        }
        // Every quad that reaches the region is drawn: count the reference set by brute force.
        var want: u32 = 0;
        for (0..sc.t.len) |i| {
            const r = sc.t.rect(@intCast(i)).array();
            const v = sc.t.c.look[i];
            want += @intFromBool(sc.t.c.visible[i] != 0 and ((v.fill | v.border_color) >> 24) != 0 and tr.dm.region.touches(r));
        }
        try testing.expectEqual(want, sc.d.quad_len);
        last = sc;
    }
}
