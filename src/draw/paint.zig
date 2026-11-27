//! paint: tree and side lists in, draw list out, in three linear sweeps. Tier 0: writes only
//! into the caller's `DrawList`. Ported from prototype/ui.zig ("paint").
//!
//!   1. nodes -> quads and an ordered op stream (write always, advance by 0 or 1)
//!   2. side lists -> text runs and custom draws (one row per run or draw that exists)
//!   3. ops -> commands by run-length encoding (equal-key quads merge into one batch)

const std = @import("std");
const simd = @import("../core/simd.zig");
const types = @import("../core/types.zig");
const Tree = @import("../core/tree.zig").Tree;
const Texts = @import("../core/texts.zig").Texts;
const Customs = @import("../core/customs.zig").Customs;
const DrawList = @import("draw_list.zig").DrawList;
const Quad = @import("draw_list.zig").Quad;
/// A rect's four edges, whatever the lane count.
const V4 = @Vector(4, f32); // tidy: allow(fixed-vector-width) four edges, not lanes
/// Size builds (embedded flash) keep the one form where a speed build takes a short path.
const small = @import("builtin").mode == .small;
const Layers = @import("../layout/overlay.zig").Layers;
const geometry = @import("geometry.zig");
const inherit = @import("inherit.zig");
const radiiOf = @import("../core/tree.zig").radiiOf;
const Look = @import("../core/tree.zig").Look;
const features = @import("features.zig");
const W = simd.lanes;
const none = types.none;

/// Tree and side lists in, draw list out. `strings` is the storage `TextRun.start` indexes.
/// Nodes paint in row order. Runs `inherit.all` first: over the few `Extras` rows only.
pub fn emit(t: *Tree, tx: *const Texts, cu: *const Customs, strings: []const u8, d: *DrawList) void {
    inherit.all(t);
    paintIn(t, tx, cu, strings, false, &.{}, d);
}

/// `emit` with nodes painted in stacking-layer order: `ly.c.order` as written by
/// `overlay.order`, so a raised node and its subtree draw over every row of a lower layer.
/// Each node still clips to its parent's clip.
pub fn emitLayered(t: *Tree, tx: *const Texts, cu: *const Customs, strings: []const u8, ly: *const Layers, d: *DrawList) void {
    inherit.all(t);
    paintIn(t, tx, cu, strings, true, ly.c.order[0..t.len], d);
}

inline fn paintIn(t: *const Tree, tx: *const Texts, cu: *const Customs, strings: []const u8, comptime ordered: bool, order: []const u32, d: *DrawList) void {
    const c = &t.c;
    const x = &t.x;
    const sign: V4 = .{ 1, 1, -1, -1 };
    // A tree of long runs of siblings (`Tree.wide`) takes the form of sweep 1 that looks for
    // them: one jump per frame, and the other trees pay nothing for it.
    const wide = (comptime !ordered and !small and W > 1) and t.wide;
    const plain_only = tx.len | cu.len == 0 and
        (if (wide) nodeOps(t, ordered, order, d, false, true) else nodeOps(t, ordered, order, d, false, false));
    if (!plain_only) {
        _ = if (wide) nodeOps(t, ordered, order, d, true, true) else nodeOps(t, ordered, order, d, true, false);
    }

    // 2. Side lists -> geometry. One row per text run or custom draw that
    //    exists; nodes without either cost nothing here.
    for (0..tx.len) |k| {
        const n = tx.c.node[k];
        d.runs[k] = .{
            .rect = .{
                c.rect[0][n] + c.pad_lo[0][n], c.rect[1][n] + c.pad_lo[1][n],
                c.rect[2][n] - c.pad_hi[0][n], c.rect[3][n] - c.pad_hi[1][n],
            },
            .clip = @as(V4, c.child_clip[c.parent[n]]) * sign,
            .start = tx.c.start[k],
            .bytes = tx.c.bytes[k],
            .px = tx.c.px[k],
            .color = fade(tx.c.color[k], x.row[c.scope[n]].alpha),
            .font = tx.c.font[k],
            .opacity = x.row[c.scope[n]].alpha,
            .xform = x.row[c.scope[n]].world,
            .clip_radii = x.row[c.scope[c.parent[n]]].clip_radii,
        };
    }
    d.run_len = tx.len;
    for (0..cu.len) |k| {
        const n = cu.c.node[k];
        d.customs[k] = .{
            .rect = .{ c.rect[0][n], c.rect[1][n], c.rect[2][n], c.rect[3][n] },
            .clip = @as(V4, c.child_clip[c.parent[n]]) * sign,
            .data = cu.c.data[k],
            .id = cu.c.id[k],
            .node = n,
            .xform = x.row[c.scope[n]].world,
            .clip_radii = x.row[c.scope[c.parent[n]]].clip_radii,
            .opacity = x.row[c.scope[n]].alpha,
        };
    }
    d.custom_len = cu.len;
    d.strings = strings;
    encodeOps(d, t.wide);
}

/// Node `i`'s quad read through its extras rows, its own (`extra`) and the one it inherits
/// from (`scope`; row 0 is the defaults): what sweep 1 writes for a node that has either.
inline fn quadOf(t: *const Tree, i: usize, alpha: f32) Quad {
    const c = &t.c;
    const x = &t.x;
    const look = &c.look[i];
    const own = c.extra[i];
    return .{
        .rect = geometry.nodeRect(t, i),
        .clip = geometry.nodeClip(t, i),
        .params = look.params,
        .uv = x.row[own].uv,
        .fill = look.fill,
        .border_color = look.border_color,
        .radii = @select(f32, @as(@Vector(4, bool), @splat(x.row[own].prepared_texture != 0)), @as(@Vector(4, f32), @splat(0)), @as(@Vector(4, f32), radiiOf(x.row[own].radii, look.radius))),
        // Row 0 (the defaults) has border 0: the row is selected, then loaded. A select on
        // the loaded border compiled to a jump around its load.
        .border = if (comptime @import("builtin").mode == .small) simd.selF(x.row[own].prepared_texture != 0, 0, x.row[own].border) else x.row[simd.selU(x.row[own].prepared_texture != 0, 0, own)].border,
        .opacity = alpha,
        .xform = geometry.nodeWorld(t, i),
        .clip_radii = geometry.nodeClipRadii(t, i),
    };
}

/// The quad of a node that reads row 0 of the extras for everything: its rect, its parent's
/// clip and its look, with no reference or outset, unit UVs, the look's radius, no border,
/// opacity 1, the identity and a square clip.
inline fn plainQuad(rect: [4]f32, look: *const Look, clip: V4) Quad {
    return .{
        // Outset by nothing, as the rows' way does: a -0 edge comes out the same bits.
        .rect = geometry.expand(rect, .{ 0, 0, 0, 0 }),
        .clip = clip,
        .params = look.params,
        .uv = .{ 0, 0, 1, 1 },
        .fill = look.fill,
        .border_color = look.border_color,
        .radii = @splat(look.radius),
        .border = 0,
        .opacity = 1,
    };
}

/// Debug and ReleaseSafe: `quad`, a `plainQuad`, is what the rows give node `i`. Every test in
/// those builds is the differential check.
inline fn checkPlain(t: *const Tree, i: usize, quad: *const Quad) void {
    if (!std.debug.runtime_safety) return;
    const by_rows = quadOf(t, i, geometry.nodeAlpha(t, i));
    std.debug.assert(t.participation(@intCast(i)).paint);
    std.debug.assert(std.mem.eql(u8, std.mem.asBytes(quad), std.mem.asBytes(&by_rows)));
}

/// Where sweep 1 has got to: the next row, and the quads and ops written.
const Painted = struct { row: usize, q: u32, o: u32 };

/// Sweep 1 for whole vectors of plain siblings: from row `first`, while the next `W` rows have
/// `first`'s parent, no extras row of their own or inherited, and no text or custom draw.
/// Their parent's clip is read once and each row is its rect, its look and three op stores,
/// with nothing to test. `at` is the first row and the quads and ops so far, `n` the tree's
/// length; returns the same after the rows it painted. Out of line, so a tree without such
/// runs pays one compare a row.
noinline fn plainQuads(t: *const Tree, d: *DrawList, n: usize, at: Painted) Painted {
    const c = &t.c;
    const first = at.row;
    std.debug.assert(first + W <= n);
    const p = c.parent[first];
    var done = at;
    // A parent under an extras row hands it to its children: they take the rows' way.
    if (c.scope[p] != 0) return done;
    const cols = .{ c.parent, c.extra, c.scope, c.text, c.custom };
    const rect = c.rect;
    const looks = c.look;
    const visible = c.visible;
    const quads = d.quads;
    const op = d.op;
    const sign: V4 = .{ 1, 1, -1, -1 };
    const clip = @as(V4, c.child_clip[p]) * sign;
    const shadow = @backingInt(features.Kind.shadow);
    // Ends at the first vector that is not all plain siblings, or at a stock shadow.
    while (done.row + W <= n) {
        const i = done.row;
        const plain = (simd.loadU(cols[0], i) == simd.u(p)) &
            ((simd.loadU(cols[1], i) | simd.loadU(cols[2], i)) == simd.u(0)) &
            ((simd.loadU(cols[3], i) & simd.loadU(cols[4], i)) == simd.u(none));
        if (!@reduce(.And, plain)) break;
        for (i..i + W) |r| {
            const look = &looks[r];
            const params: [4]u32 = @bitCast(look.params);
            // rare: the stock shadow paints past its rect, so `visible` is not its answer.
            if (params[0] == shadow) return done;
            const edges: [4]f32 = .{ rect[0][r], rect[1][r], rect[2][r], rect[3][r] };
            quads[done.q] = plainQuad(edges, look, clip);
            checkPlain(t, r, &quads[done.q]);
            // Painted when either colour has alpha: the write index advances by 0 or 1.
            const coloured = ((look.fill | look.border_color) >> 24) != 0;
            const has_quad = @as(u32, @intFromBool(visible[r] != 0)) & @intFromBool(coloured);
            op.kind[done.o] = @backingInt(DrawList.Kind.quads);
            op.key[done.o] = (@as(u32, look.texture) << 16) | look.material;
            op.ref[done.o] = done.q;
            done.q += has_quad;
            done.o += has_quad;
            done.row = r + 1;
        }
    }
    return done;
}

/// Appends quads and the ordered ops. Without side lists the quad and op
/// indices advance together, and each node writes one candidate operation.
/// Returns false when directly populated text or custom links need the full path.
inline fn nodeOps(
    t: *const Tree,
    comptime ordered: bool,
    order: []const u32,
    d: *DrawList,
    comptime mixed: bool,
    comptime by_runs: bool,
) bool {
    const c = &t.c;
    // 1. Nodes -> quads and an ordered op stream. Every row writes its
    //    candidate output; the write index advances by 0 or 1.
    const quads = d.quads;
    const op_kind = d.op.kind;
    const op_key = d.op.key;
    const op_ref = d.op.ref;
    const looks = c.look;
    const sign: V4 = .{ 1, 1, -1, -1 };
    var links: u32 = none;
    var q: u32 = 0;
    var o: u32 = 0;
    const n: usize = t.len;
    const parents = c.parent;
    // The row from which whole vectors of plain siblings are looked for again (`by_runs`).
    var again: usize = 0;
    var k: usize = 0;
    // Ends at `n`: a turn paints row `k`, or `plainQuads` moves `k` on by whole vectors.
    while (k < n) : (k += 1) {
        // From `again` on, a row with a sibling after it: are the next `W` rows a vector of
        // plain siblings?
        if (comptime by_runs) {
            if (k >= again and parents[k + 1] == parents[k] and k + W <= n) {
                const p = parents[k];
                const plain = parents[k + W - 1] == p and (c.text[k] & c.custom[k]) == none;
                const here: Painted = .{ .row = k, .q = q, .o = o };
                const at = if (plain) plainQuads(t, d, n, here) else here;
                q = at.q;
                o = at.o;
                // Nothing painted: this vector is not plain, so its rows go one at a time.
                if (at.row == k) again = k + W;
                if (at.row == n) break;
                k = at.row;
            }
        }
        const i = if (ordered) order[k] else k;
        const look = &looks[i];
        const parent = c.parent[i];
        var vis: u32 = undefined;
        var alpha: f32 = 1;
        // A node with no extras row of its own, under none, and with a parent under none reads
        // row 0 for everything: no reference or outset, unit UVs, the look's radius, no border,
        // opacity 1, the identity, a square clip. Its quad is its rect, its parent's clip and
        // its look. One jump on that (nearly every node: well predicted); a size build reads
        // row 0.
        if (!small and (c.extra[i] | c.scope[i] | c.scope[parent]) == 0) {
            vis = @intFromBool(geometry.nodeShown(t, i));
            // A node with neither colour paints nothing, and about half the nodes of a form
            // or a list are such (containers, text leaves): its quad is not written. One jump,
            // where the 136 bytes were written and then left behind.
            if (((look.fill | look.border_color) >> 24) != 0) {
                const rect: [4]f32 = .{ c.rect[0][i], c.rect[1][i], c.rect[2][i], c.rect[3][i] };
                quads[q] = plainQuad(rect, look, @as(V4, c.child_clip[parent]) * sign);
                checkPlain(t, i, &quads[q]);
            }
        } else {
            const paints = t.participation(@intCast(i)).paint;
            vis = @intFromBool(geometry.nodeShown(t, i)) & @intFromBool(paints);
            alpha = geometry.nodeAlpha(t, i);
            quads[q] = quadOf(t, i, alpha);
        }
        // Painted when either colour has alpha and the node is not fully transparent.
        const has_quad = vis & @intFromBool(((look.fill | look.border_color) >> 24) != 0) & @intFromBool(alpha > 0);
        op_kind[o] = @backingInt(DrawList.Kind.quads);
        op_key[o] = (@as(u32, look.texture) << 16) | look.material;
        op_ref[o] = q;
        q += has_quad;
        o += has_quad;

        if (!mixed) {
            links &= c.text[i] & c.custom[i];
            continue;
        }
        op_kind[o] = @backingInt(DrawList.Kind.text);
        op_key[o] = 0;
        op_ref[o] = c.text[i];
        o += vis & @intFromBool(c.text[i] != none);

        op_kind[o] = @backingInt(DrawList.Kind.custom);
        op_key[o] = 0;
        op_ref[o] = c.custom[i];
        o += vis & @intFromBool(c.custom[i] != none);
    }
    d.quad_len = q;
    d.op_len = o;
    return links == none;
}

/// Sweep 3 alone: `d.op[0..op_len]` -> commands by run-length encoding. Consecutive quads with
/// the same texture and material merge; text and custom ops stand alone. Consecutive quad ops
/// must reference consecutive quads, as sweep 1 writes them. For passes that reorder ops
/// (`order.mergeAcrossText`) and then encode again.
pub fn encode(d: *DrawList) void {
    encodeOps(d, false);
}

/// `encode`. `long` says the ops have long stretches of quads with one key (a tree of long
/// runs of siblings, `Tree.wide`): a whole vector of them then only makes the batch longer, so
/// it is one compare, and the count the one store. The same commands either way.
fn encodeOps(d: *DrawList, long: bool) void {
    const o: usize = d.op_len;
    std.debug.assert(o <= d.op.kind.len);
    const kinds = d.op.kind;
    const keys = d.op.key;
    const quads = @backingInt(DrawList.Kind.quads);
    const wide = W > 1 and long;
    var n: u32 = 0;
    var first: u32 = 0;
    var count: u32 = 0;
    var prev_kind: u8 = 0xff;
    var prev_key: u32 = 0;
    var j: usize = 0;
    // Ends at `o`: a turn takes one op, or a whole vector of them.
    while (j < o) {
        if (wide and prev_kind == quads and j + W <= o and keys[j + W - 1] == prev_key) {
            const kind: simd.Bytes = kinds[j..][0..W].*;
            const more = @reduce(.And, kind == @as(simd.Bytes, @splat(quads))) and
                @reduce(.And, simd.loadU(keys, j) == simd.u(prev_key));
            if (more) {
                count += W;
                d.cmd.count[n - 1] = count;
                j += W;
                continue;
            }
        }
        const kind = kinds[j];
        const key = keys[j];
        const brk: u32 = @intFromBool(kind != 0) | @intFromBool(kind != prev_kind) | @intFromBool(key != prev_key);
        n += brk;
        const k = n - 1; // the first op always breaks, so n >= 1 here
        d.cmd.kind[k] = kind;
        d.cmd.key[k] = key;
        first = simd.selU(brk != 0, d.op.ref[j], first);
        count = simd.selU(brk != 0, 0, count) + 1;
        d.cmd.first[k] = first;
        d.cmd.count[k] = count;
        prev_kind = kind;
        prev_key = key;
        j += 1;
    }
    d.cmd_len = n;
}

/// `color` (rgba8, alpha in the top byte) with its alpha times `alpha`, rounded. Exact for 1.
pub inline fn fade(color: u32, alpha: f32) u32 {
    // Nearly every node is opaque, and 1 gives the colour back: one jump on that, where the
    // rounding was a call per text run.
    if (alpha == 1) return color;
    const a: f32 = @floatFromInt(color >> 24);
    const scaled: u32 = @intFromFloat(@round(a * std.math.clamp(alpha, 0, 1)));
    return (color & 0x00ff_ffff) | (scaled << 24);
}

const testing = std.testing;
const mem = @import("../core/mem.zig");
const layout = @import("../layout/layout.zig");
const check = @import("../layout/check.zig");
const Strings = @import("../core/strings.zig").Strings;
const Id = types.Id;
const Color = types.Color;
const Cmd = @import("draw_list.zig").Cmd;

/// A laid-out scene of every op kind: root (clips, filled), a bordered quad, a text leaf, a
/// custom leaf, a quad on another texture, a quad back on the root's texture, and a filled
/// float pushed outside the root's clip, which paints nothing.
const Scene = struct {
    t: Tree,
    tx: Texts,
    cu: Customs,
    s: Strings,
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
            .d = DrawList.init(carver, cap, 4, 4),
        };
    }

    // Node rows, in push order.
    const root = 0;
    const box = 1;
    const label = 2;
    const view = 3;
    const tinted = 4;
    const plain = 5;
    const away = 6;

    /// Builds, lays out and paints the scene in `buf`.
    fn build(buf: *align(mem.column_align) [bytes]u8) Scene {
        var carver: mem.Carver = .{ .buf = buf };
        var sc = carve(&carver);
        const t = &sc.t;
        const fill: Color = .rgb(200, 0, 0);
        _ = t.push(0, Id.from("root"), &.{ .size = .{ .px(400), .px(300) }, .clip = true, .fill = .rgb(10, 10, 10) });
        _ = t.push(root, Id.from("box"), &.{ .size = .{ .px(100), .px(50) }, .fill = fill, .border = 2, .border_color = .white, .radius = 4 });
        _ = t.push(root, Id.from("label"), &.{ .pad = @splat(2) });
        t.c.text[label] = sc.tx.push(label, sc.s.add("hello"), &.{ .px = 10 });
        sc.tx.c.w[0] = 40;
        sc.tx.c.h[0] = 10;
        _ = t.push(root, Id.from("view"), &.{ .size = .{ .px(50), .px(50) } });
        t.c.custom[view] = sc.cu.push(view, Id.from("view"), 77);
        _ = t.push(root, Id.from("tinted"), &.{ .size = .{ .px(20), .px(20) }, .fill = fill, .texture = @fromBackingInt(3) });
        _ = t.push(root, Id.from("plain"), &.{ .size = .{ .px(20), .px(20) }, .fill = fill });
        _ = t.push(root, Id.from("away"), &.{ .size = .{ .px(10), .px(10) }, .float = true, .offset = .{ 1000, 0 }, .fill = fill });
        t.seal(root);
        layout.run(t, &sc.tx, .{ 400, 300 });
        emit(t, &sc.tx, &sc.cu, sc.s.buf[0..sc.s.len], &sc.d);
        return sc;
    }
};

test "sweep 1: visible painted nodes become quads, every node its ops in paint order" {
    var buf: [Scene.bytes]u8 align(mem.column_align) = undefined;
    const sc: Scene = .build(&buf);
    const d = &sc.d;
    // root, box, tinted, plain; `away` is filled but clipped out, label and view are unfilled.
    try testing.expectEqual(4, d.quad_len);
    try testing.expectEqual([4]f32{ 0, 0, 100, 50 }, d.quads[1].rect);
    try testing.expectEqual([4]f32{ 0, 0, 400, 300 }, d.quads[1].clip);
    try testing.expectEqual([4]f32{ 0, 0, 1, 1 }, d.quads[1].uv);
    try testing.expectEqual(Color.rgb(200, 0, 0).bitsOf(), d.quads[1].fill);
    try testing.expectEqual(Color.white.bitsOf(), d.quads[1].border_color);
    try testing.expectEqual([4]f32{ 4, 4, 4, 4 }, d.quads[1].radii);
    try testing.expectEqual(2, d.quads[1].border);
    try testing.expectEqual(sc.t.rect(Scene.plain).array(), d.quads[3].rect);
    // The op stream: quad, quad, text, custom, quad on texture 3, quad.
    try testing.expectEqualSlices(u8, &.{ 0, 0, 1, 2, 0, 0 }, d.op.kind[0..6]);
    try testing.expectEqualSlices(u32, &.{ 0, 0, 0, 0, 3 << 16, 0 }, d.op.key[0..6]);
    try testing.expectEqualSlices(u32, &.{ 0, 1, 0, 0, 2, 3 }, d.op.ref[0..6]);
}

test "a tree of long runs paints the same quads, ops and commands by runs as row by row" {
    const Lists = struct {
        var raw: [4 * 1024 * 1024]u8 align(mem.column_align) = undefined;
    };
    var carver: mem.Carver = .{ .buf = &Lists.raw };
    var t = Tree.init(&carver, 1000);
    var tx = Texts.init(&carver, 4);
    const cu = Customs.init(&carver, 4);
    var s: Strings = .{ .buf = carver.slice(u8, 64) };
    var d: [2]DrawList = .{ .init(&carver, 1000, 4, 4), .init(&carver, 1000, 4, 4) };
    var prng: std.Random.DefaultPrng = .init(0x9a17);
    const r = prng.random();
    for (0..100) |round| {
        check.randomRuns(&t, r, 1 + r.uintLessThan(u32, t.cap));
        tx.reset();
        s.len = 0;
        // Most rows painted, a few on another texture, a few with the stock shadow; every
        // other tree has a text run, so both forms of sweep 1 are held to the row-by-row one.
        for (t.c.look[0..t.len]) |*look| {
            look.fill = if (r.uintLessThan(u32, 8) == 0) 0 else 0xff20_4060;
            if (r.uintLessThan(u32, 16) == 0) look.texture = 3;
        }
        if (round % 2 == 0) {
            const node = r.uintLessThan(u32, t.len);
            t.c.text[node] = tx.push(node, s.add("hello"), &.{ .px = 10 });
        }
        layout.run(&t, &tx, .{ 1280, 800 });
        for (&d, [2]bool{ false, true }) |*list, wide| {
            t.wide = wide;
            emit(&t, &tx, &cu, s.buf[0..s.len], list);
        }
        try testing.expectEqual(d[0].quad_len, d[1].quad_len);
        try testing.expectEqual(d[0].op_len, d[1].op_len);
        try testing.expectEqual(d[0].cmd_len, d[1].cmd_len);
        const quads = [2][]const u8{
            std.mem.sliceAsBytes(d[0].quads[0..d[0].quad_len]),
            std.mem.sliceAsBytes(d[1].quads[0..d[1].quad_len]),
        };
        try testing.expectEqualSlices(u8, quads[0], quads[1]);
        const ops = d[0].op_len;
        try testing.expectEqualSlices(u8, d[0].op.kind[0..ops], d[1].op.kind[0..ops]);
        try testing.expectEqualSlices(u32, d[0].op.key[0..ops], d[1].op.key[0..ops]);
        try testing.expectEqualSlices(u32, d[0].op.ref[0..ops], d[1].op.ref[0..ops]);
        const cmds = d[0].cmd_len;
        try testing.expectEqualSlices(u8, d[0].cmd.kind[0..cmds], d[1].cmd.kind[0..cmds]);
        try testing.expectEqualSlices(u32, d[0].cmd.key[0..cmds], d[1].cmd.key[0..cmds]);
        try testing.expectEqualSlices(u32, d[0].cmd.first[0..cmds], d[1].cmd.first[0..cmds]);
        try testing.expectEqualSlices(u32, d[0].cmd.count[0..cmds], d[1].cmd.count[0..cmds]);
    }
}

test "sweep 2: text runs get the content box, custom draws the node rect, both the parent clip" {
    var buf: [Scene.bytes]u8 align(mem.column_align) = undefined;
    const sc: Scene = .build(&buf);
    const d = &sc.d;
    const label = sc.t.rect(Scene.label);
    try testing.expectEqual(1, d.run_len);
    try testing.expectEqual([4]f32{ label.x0 + 2, label.y0 + 2, label.x1 - 2, label.y1 - 2 }, d.runs[0].rect);
    try testing.expectEqual([4]f32{ 2, 52, 42, 62 }, d.runs[0].rect);
    try testing.expectEqual([4]f32{ 0, 0, 400, 300 }, d.runs[0].clip);
    try testing.expectEqualStrings("hello", d.strings[d.runs[0].start..][0..d.runs[0].bytes]);
    try testing.expectEqual(10, d.runs[0].px);
    try testing.expectEqual(Color.white.bitsOf(), d.runs[0].color);
    try testing.expectEqual(0, d.runs[0].font);
    try testing.expectEqual(1, d.custom_len);
    try testing.expectEqual(sc.t.rect(Scene.view).array(), d.customs[0].rect);
    try testing.expectEqual([4]f32{ 0, 0, 400, 300 }, d.customs[0].clip);
    try testing.expectEqual(77, d.customs[0].data);
    try testing.expectEqual(@backingInt(Id.from("view")), d.customs[0].id);
    try testing.expectEqual(Scene.view, d.customs[0].node);
}

test "sweep 3: equal-key quads merge, a key change or a text or custom op breaks the batch" {
    var buf: [Scene.bytes]u8 align(mem.column_align) = undefined;
    const sc: Scene = .build(&buf);
    const d = &sc.d;
    try testing.expectEqual(5, d.cmd_len);
    try testing.expectEqual(Cmd{ .quads = .{ .first = 0, .count = 2, .texture = .white, .material = .solid } }, d.command(0));
    try testing.expectEqual(Cmd{ .text = 0 }, d.command(1));
    try testing.expectEqual(Cmd{ .custom = 0 }, d.command(2));
    try testing.expectEqual(Cmd{ .quads = .{ .first = 2, .count = 1, .texture = @fromBackingInt(3), .material = .solid } }, d.command(3));
    try testing.expectEqual(Cmd{ .quads = .{ .first = 3, .count = 1, .texture = .white, .material = .solid } }, d.command(4));
}

test "sweep 3: a repaint into a used draw list gives the same commands" {
    // A reused list holds the preceding frame's batch counts. Repainting must overwrite them.
    var buf: [Scene.bytes]u8 align(mem.column_align) = undefined;
    var sc: Scene = .build(&buf);
    const first = sc.d.command(0);
    emit(&sc.t, &sc.tx, &sc.cu, sc.d.strings, &sc.d);
    try testing.expectEqual(5, sc.d.cmd_len);
    try testing.expectEqual(first, sc.d.command(0));
    try testing.expectEqual(Cmd{ .quads = .{ .first = 3, .count = 1, .texture = .white, .material = .solid } }, sc.d.command(4));
}

test "children of a clipping node are clipped inside its border; a non-clipping border passes the clip on" {
    // The inset itself is computed by layout.finalize into `child_clip`; paint must hand that
    // clip, not the parent's outer rect, to every quad, run and custom draw of the children.
    var buf: [Scene.bytes]u8 align(mem.column_align) = undefined;
    var carver: mem.Carver = .{ .buf = &buf };
    var sc = Scene.carve(&carver);
    const t = &sc.t;
    const fill: Color = .rgb(0, 0, 200);
    _ = t.push(0, Id.from("root"), &.{ .size = .{ .px(400), .px(300) }, .clip = true });
    const framed = t.push(0, Id.from("framed"), &.{ .size = .{ .px(200), .px(100) }, .clip = true, .border = 3, .border_color = .white });
    _ = t.push(framed, Id.from("inner"), &.{ .size = .{ .px(300), .px(20) }, .fill = fill });
    const caption = t.push(framed, Id.from("caption"), &.{});
    t.c.text[caption] = sc.tx.push(caption, sc.s.add("x"), &.{});
    const view = t.push(framed, Id.from("view"), &.{ .size = .{ .px(10), .px(10) } });
    t.c.custom[view] = sc.cu.push(view, Id.from("view"), 0);
    t.seal(framed);
    const open = t.push(0, Id.from("open"), &.{ .size = .{ .px(200), .px(100) }, .border = 3, .border_color = .white });
    const loose = t.push(open, Id.from("loose"), &.{ .size = .{ .px(10), .px(10) }, .fill = fill });
    t.seal(open);
    t.seal(0);
    layout.run(t, &sc.tx, .{ 400, 300 });
    emit(t, &sc.tx, &sc.cu, sc.s.buf[0..sc.s.len], &sc.d);
    const d = &sc.d;

    // Quads: framed (border only), inner, open, loose.
    try testing.expectEqual(4, d.quad_len);
    try testing.expectEqual([4]f32{ 0, 0, 400, 300 }, d.quads[0].clip);
    try testing.expectEqual([4]f32{ 0, 0, 300, 20 }, d.quads[1].rect);
    try testing.expectEqual([4]f32{ 3, 3, 197, 97 }, d.quads[1].clip);
    try testing.expectEqual([4]f32{ 3, 3, 197, 97 }, d.runs[0].clip);
    try testing.expectEqual([4]f32{ 3, 3, 197, 97 }, d.customs[0].clip);
    try testing.expectEqual(sc.t.rect(loose).array(), d.quads[3].rect);
    try testing.expectEqual([4]f32{ 0, 0, 400, 300 }, d.quads[3].clip);
}

test "a renderer's one switch per command draws every quad, run and custom once, in order" {
    // The host loop of prototype/example.zig: one switch per command.
    var buf: [Scene.bytes]u8 align(mem.column_align) = undefined;
    const sc: Scene = .build(&buf);
    const d = &sc.d;
    var next_quad: u32 = 0;
    var batches: u32 = 0;
    var runs: u32 = 0;
    var customs: u32 = 0;
    for (0..d.cmd_len) |i| switch (d.command(@intCast(i))) {
        .quads => |batch| {
            try testing.expectEqual(next_quad, batch.first);
            next_quad += batch.count;
            batches += 1;
        },
        .text => |k| {
            try testing.expectEqual(runs, k);
            runs += 1;
        },
        .canvas => return error.TestUnexpectedResult,
        .custom => |k| {
            try testing.expectEqual(customs, k);
            try testing.expectEqual(sc.t.rect(Scene.view).array(), d.customs[k].rect);
            customs += 1;
        },
    };
    try testing.expectEqual(d.quad_len, next_quad);
    try testing.expect(batches < d.quad_len);
    try testing.expectEqual(d.run_len, runs);
    try testing.expectEqual(d.custom_len, customs);
    try testing.expectEqual(d.quad_len * @sizeOf(@import("draw_list.zig").Quad), d.quadBytes().len);
}

test "an empty tree paints nothing" {
    var buf: [Scene.bytes]u8 align(mem.column_align) = undefined;
    var carver: mem.Carver = .{ .buf = &buf };
    var sc = Scene.carve(&carver);
    emit(&sc.t, &sc.tx, &sc.cu, "", &sc.d);
    try testing.expectEqual(0, sc.d.quad_len + sc.d.run_len + sc.d.custom_len + sc.d.cmd_len);
}

test "a textured node with no fill paints its texture untinted" {
    var buf: [Scene.bytes]u8 align(mem.column_align) = undefined;
    var carver: mem.Carver = .{ .buf = &buf };
    var sc = Scene.carve(&carver);
    const t = &sc.t;
    _ = t.push(0, Id.from("root"), &.{ .size = .{ .px(100), .px(100) } });
    _ = t.push(0, Id.from("photo"), &.{ .size = .{ .px(20), .px(20) }, .texture = @fromBackingInt(3) });
    _ = t.push(0, Id.from("framed"), &.{ .size = .{ .px(20), .px(20) }, .texture = @fromBackingInt(3), .border = 1, .border_color = .black });
    t.seal(0);
    layout.run(t, &sc.tx, .{ 100, 100 });
    emit(t, &sc.tx, &sc.cu, "", &sc.d);
    // The unfilled root paints nothing; both textured leaves are white-tinted quads on texture 3.
    try testing.expectEqual(2, sc.d.quad_len);
    for (sc.d.quads[0..2]) |q| try testing.expectEqual(Color.white.bitsOf(), q.fill);
    try testing.expectEqual(Cmd{ .quads = .{ .first = 0, .count = 2, .texture = @fromBackingInt(3), .material = .solid } }, sc.d.command(0));
}

test "quad-only frames preserve the general op stream on reused, reordered and directly linked rows" {
    var live_buf: [Scene.bytes]u8 align(mem.column_align) = undefined;
    var expected_buf: [Scene.bytes]u8 align(mem.column_align) = undefined;
    var sc = Scene.build(&live_buf);
    var expected = Scene.build(&expected_buf);
    const t = &sc.t;
    sc.tx.reset();
    sc.cu.reset();
    @memset(t.c.text[0..t.len], none);
    @memset(t.c.custom[0..t.len], none);
    // Stale links just beyond the last node cannot affect the specialization.
    t.c.text[t.len] = 12;
    t.c.custom[t.len] = 13;
    const reverse = [_]u32{ 6, 5, 4, 3, 2, 1, 0 };
    for (0..3) |kind| {
        if (kind == 1) t.c.text[Scene.box] = 12;
        if (kind == 2) {
            t.c.text[Scene.box] = none;
            t.c.custom[Scene.box] = 13;
        }
        inline for (.{ false, true }) |ordered| {
            _ = nodeOps(t, ordered, &reverse, &expected.d, true, false);
            encode(&expected.d);
            paintIn(t, &sc.tx, &sc.cu, "storage", ordered, &reverse, &sc.d);
            const want = &expected.d;
            const got = &sc.d;
            try testing.expectEqualSlices(@import("draw_list.zig").Quad, want.quads[0..want.quad_len], got.quads[0..got.quad_len]);
            try testing.expectEqualSlices(u8, want.op.kind[0..want.op_len], got.op.kind[0..got.op_len]);
            try testing.expectEqualSlices(u32, want.op.key[0..want.op_len], got.op.key[0..got.op_len]);
            try testing.expectEqualSlices(u32, want.op.ref[0..want.op_len], got.op.ref[0..got.op_len]);
            try testing.expectEqual(want.cmd_len, got.cmd_len);
            for (0..got.cmd_len) |i| try testing.expectEqual(want.command(@intCast(i)), got.command(@intCast(i)));
            try testing.expectEqual(0, got.run_len);
            try testing.expectEqual(0, got.custom_len);
            try testing.expectEqualStrings("storage", got.strings);
        }
    }
    t.reset();
    emit(t, &sc.tx, &sc.cu, "", &sc.d);
    try testing.expectEqual(0, sc.d.quad_len);
    try testing.expectEqual(0, sc.d.cmd_len);
    try testing.expectEqual(0, sc.d.op_len);
}
