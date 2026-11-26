//! The tables of a comptime UI as pure functions over arrays. Tier 1. They run in two places:
//!
//! - in the Zig compiler, at comptime, where `ct_layout.Layout` and `ct_paint.Paint` call them
//!   over the tree `Tree.push` built from the spec (`columns.Columns.pushed`);
//! - in `lcgf-gen` (tools/lcgf-gen/), at run time, over the same tree pushed from a `.zon`
//!   spec, for the static UIs C++ and Rust programs link (src/abi/ct.zig).
//!
//! `p` is a pushed tree: anything with the columns of `Tree.Columns` in `c` (indexable rows)
//! and the extras in `x` and `xlen`. Outputs go to slices the caller sizes, so the functions
//! allocate nothing and run the same at comptime and at run time.

const std = @import("std");
const tree = @import("../core/tree.zig");
const types = @import("../core/types.zig");
const Quad = @import("../draw/draw_list.zig").Quad;
const fade = @import("../draw/paint.zig").fade;
const shadow = @backingInt(@import("../draw/features.zig").Kind.shadow);

pub const none = types.none;
const V4 = @Vector(4, f32);
const identity: [6]f32 = .{ 1, 0, 0, 1, 0, 0 };

/// `prepare`'s gap totals: the gap times the in-flow child count less one.
pub fn gapTotal(p: anytype, n: usize, out: []f32) void {
    for (0..n) |i| out[i] = p.c.gap[i] * @import("../core/simd.zig").maxF(p.c.nkids[i] - 1, 0);
}

/// What a fold plan decides: see `foldPlan`.
pub const Fold = struct { folded_rows: usize };

/// Which rows fold (ct_layout.FoldPlan). `has_label[i]`: row i is a label or holds one (filled
/// here from `labels`); `volatile_rows`, rows a dynamic region can change, or null. Writes
/// `indep`, `root` and `inside` (n rows each).
pub fn foldPlan(p: anytype, n: usize, labels: []const u32, volatile_rows: ?[]const bool, has_label: []bool, indep: []bool, root: []bool, inside: []bool) Fold {
    const c = p.c;
    @memset(has_label[0..n], false);
    for (labels) |l| has_label[l] = true;
    var i = n;
    while (i > 1) {
        i -= 1;
        if (has_label[i]) has_label[c.parent[i]] = true;
    }
    indep[0] = false;
    for (1..n) |j| {
        const own = c.grow[0][j] == 0 and c.grow[1][j] == 0 and c.pct[0][j] < 0 and c.pct[1][j] < 0 and
            (c.shrink[j] == 0 or c.flow[j] == 0);
        const vol = if (volatile_rows) |v| v[j] else false;
        indep[j] = !vol and !has_label[j] and (indep[c.parent[j]] or own);
    }
    for (0..n) |j| root[j] = indep[j] and !indep[c.parent[j]] and c.end[j] - j > 1;
    @memset(inside[0..n], false);
    var folded: usize = 0;
    for (0..n) |j| if (root[j]) for (j + 1..c.end[j]) |k| {
        inside[k] = true;
    };
    for (inside[0..n]) |x| folded += @intFromBool(x);
    return .{ .folded_rows = folded };
}

/// The skeleton rows of a fold: row j of the UI is skeleton row `skel_row[j]`, or `none` for a
/// row inside a fold root. Returns the skeleton's row count.
pub fn skeletonRows(n: usize, inside: []const bool, skel_row: []u32) u32 {
    var k: u32 = 0;
    for (0..n) |j| {
        skel_row[j] = if (inside[j]) none else k;
        k += @intFromBool(!inside[j]);
    }
    return k;
}

/// The style a fold root becomes in the skeleton: a leaf of its laid-out size.
pub fn foldedLeaf(s: types.Style, size: [2]f32) types.Style {
    var leaf = s;
    leaf.size = .{ .px(size[0]), .px(size[1]) };
    leaf.min = .{ 0, 0 };
    leaf.max = .{ std.math.inf(f32), std.math.inf(f32) };
    return leaf;
}

/// For each row: the skeleton row its position starts from (itself, or its fold root), the
/// constant offset from there, and, for folded rows, its constant size and 0 in `keep_size`
/// (1 for skeleton rows, whose size comes from the passes). `pos` and `size` are the full
/// tree's layout from the compiler's passes. Returns the skeleton's row count.
pub fn expand(n: usize, root: []const bool, inside: []const bool, pos: [2][]const f32, size: [2][]const f32, base: []u32, rel: [2][]f32, out_size: [2][]f32, keep_size: []f32) u32 {
    var k: u32 = 0;
    var root_k: u32 = 0;
    var root_row: usize = 0;
    for (0..n) |j| {
        if (inside[j]) {
            base[j] = root_k;
            keep_size[j] = 0;
            for (0..2) |a| {
                rel[a][j] = pos[a][j] - pos[a][root_row];
                out_size[a][j] = size[a][j];
            }
        } else {
            base[j] = k;
            keep_size[j] = 1;
            for (0..2) |a| {
                rel[a][j] = 0;
                out_size[a][j] = 0;
            }
            if (root[j]) {
                root_k = k;
                root_row = j;
            }
            k += 1;
        }
    }
    return k;
}

/// `draw.inherit`'s opacity and clip sweeps over the extras rows: `alpha[r]` and
/// `clip_radii[r]` for extras row r (`p.xlen` rows).
pub fn inherit(p: anytype, alpha: []f32, clip_radii: [][4]f32) void {
    alpha[0] = tree.Extra.defaults.alpha;
    clip_radii[0] = tree.Extra.defaults.clip_radii;
    for (1..p.xlen) |r| {
        const i = p.x.node[r];
        const x = p.x.row[r];
        const up = if (i == 0) 0 else p.c.scope[p.c.parent[i]];
        alpha[r] = x.opacity * alpha[up];
        const own: [4]f32 = @max(@as(V4, x.radii) - @as(V4, @splat(x.border)), @as(V4, @splat(0)));
        clip_radii[r] = if (p.c.clips[i] != 0) own else clip_radii[up];
    }
}

pub fn keyOf(look: tree.Look) u32 {
    return (@as(u32, look.texture) << 16) | look.material;
}

/// The rows that paint a quad, in row order: `paint.emit`'s condition without `visible`.
/// Returns how many.
pub fn paintRows(p: anytype, n: usize, alpha: []const f32, out: []u32) usize {
    var m: usize = 0;
    for (0..n) |i| {
        const look = p.c.look[i];
        if (((look.fill | look.border_color) >> 24) != 0 and alpha[p.c.scope[i]] > 0 and p.x.row[p.c.scope[i]].active_participation.paint) {
            out[m] = @intCast(i);
            m += 1;
        }
    }
    return m;
}

/// The fold root each row lies under (itself for a root), or `none`.
pub fn foldGroups(p: anytype, n: usize, root: []const bool, group: []u32) void {
    @memset(group[0..n], none);
    for (0..n) |i| if (root[i]) for (i..p.c.end[i]) |j| {
        group[j] = @intCast(i);
    };
}

/// Whether the quads of rows a and b never overlap in any viewport (ct_paint's sort).
fn apart(p: anytype, a: u32, b: u32, group: []const u32, pos: [2][]const f32, size: [2][]const f32) bool {
    if (group[a] == none or group[a] != group[b]) return false;
    for ([_]u32{ a, b }) |i| {
        if (@as(u32, @bitCast(p.c.look[i].params[0])) == shadow) return false;
    }
    for (0..2) |ax| {
        const a0 = pos[ax][a];
        const b0 = pos[ax][b];
        if (a0 + size[ax][a] + 1 <= b0 or b0 + size[ax][b] + 1 <= a0) return true;
    }
    return false;
}

/// `rows` (the nodes that paint, in row order) reordered so that equal batch keys follow each
/// other where that cannot change the picture (see ct_paint's `sortByKey`). `group` is
/// `foldGroups`', `pos` and `size` the compiler's layout of the whole tree. `done` is scratch,
/// `rows.len` long.
pub fn sortByKey(p: anytype, rows: []const u32, group: []const u32, pos: [2][]const f32, size: [2][]const f32, out: []u32, done: []bool) void {
    const m = rows.len;
    @memcpy(out[0..m], rows);
    if (m < 3) return;
    // Layout-space disjointness cannot authorize reordering transformed or expanded paint.
    for (p.x.row[1..p.xlen]) |x| if (!std.mem.eql(f32, &x.transform, &identity) or x.paint_reference != none or !std.mem.eql(f32, &x.paint_outset, &@as([4]f32, @splat(0)))) return;
    // With one batch key the input is already in its final order.
    if (for (rows[1..]) |r| {
        if (keyOf(p.c.look[r]) != keyOf(p.c.look[rows[0]])) break false;
    } else true) return;
    @memset(done[0..m], false);
    var last: u32 = none;
    for (out[0..m]) |*o| {
        var pick: u32 = none;
        var first_ready: u32 = none;
        for (0..m) |k| {
            if (done[k]) continue;
            const ready = for (0..k) |j| {
                if (!done[j] and !apart(p, rows[j], rows[k], group, pos, size)) break false;
            } else true;
            if (!ready) continue;
            if (first_ready == none) first_ready = @intCast(k);
            if (keyOf(p.c.look[rows[k]]) == last) {
                pick = @intCast(k);
                break;
            }
        }
        if (pick == none) pick = first_ready;
        done[pick] = true;
        o.* = rows[pick];
        last = keyOf(p.c.look[rows[pick]]);
    }
}

/// Every descriptor in paint order: sorted quads occupy the original quad positions; other
/// rows keep theirs.
pub fn paintOrder(n: usize, in_row_order: []const u32, painted: []const u32, out: []u32) void {
    var k: usize = 0;
    for (out[0..n], 0..) |*row, i| {
        row.* = @intCast(i);
        if (k < in_row_order.len and in_row_order[k] == i) {
            row.* = painted[k];
            k += 1;
        }
    }
}

/// How a label's run is placed among the sorted quads.
pub const Label = extern struct { node: u32, parent: u32, quad_end: u32, padding: [4]f32, color: u32 };

/// The labels' runs: each a boundary in the sorted quad stream, after the quads painted before
/// it (its own background included).
pub fn labelPlans(p: anytype, order: []const u32, painted: []const u32, labels: []const u32, alpha: []const f32, out: []Label) void {
    var k: u32 = 0;
    var l: usize = 0;
    for (order) |row| {
        if (k < painted.len and painted[k] == row) k += 1;
        if (l < labels.len and row == labels[l]) {
            out[l] = .{
                .node = row,
                .parent = p.c.parent[row],
                .quad_end = k,
                .padding = .{ p.c.pad_lo[0][row], p.c.pad_lo[1][row], -p.c.pad_hi[0][row], -p.c.pad_hi[1][row] },
                .color = fade((types.TextStyle{}).color.bitsOf(), alpha[p.c.scope[row]]),
            };
            l += 1;
        }
    }
    std.debug.assert(l == labels.len);
}

/// Template k: the quad `painted[k]` paints, `rect` and `clip` zero.
pub fn templates(p: anytype, painted: []const u32, alpha: []const f32, clip_radii: []const [4]f32, out: []Quad) void {
    for (out[0..painted.len], painted) |*q, i| {
        const look = p.c.look[i];
        const own = p.x.row[p.c.extra[i]];
        const source = if (own.paint_reference == none) i else own.paint_reference;
        q.* = .{
            .rect = @splat(0),
            .clip = @splat(0),
            .params = look.params,
            .uv = own.uv,
            .fill = look.fill,
            .border_color = look.border_color,
            .radii = tree.radiiOf(own.radii, look.radius),
            .border = own.border,
            .opacity = alpha[p.c.scope[source]] * (if (source == i) @as(f32, 1) else own.opacity),
            .xform = identity,
            .clip_radii = clip_radii[p.c.scope[p.c.parent[source]]],
        };
    }
}

/// Batch keys of the templates, and the commands when every template is visible: consecutive
/// templates with equal keys form one batch. Returns the batch count.
pub fn batches(p: anytype, painted: []const u32, keys: []u32, first: []u32, count: []u32, key: []u32) usize {
    for (keys[0..painted.len], painted) |*o, i| o.* = keyOf(p.c.look[i]);
    var b: usize = 0;
    for (keys[0..painted.len], 0..) |k_, k| {
        if (k == 0 or k_ != keys[k - 1]) {
            first[b] = @intCast(k);
            count[b] = 0;
            key[b] = k_;
            b += 1;
        }
        count[b - 1] += 1;
    }
    return b;
}

/// Batch count of `painted` without writing the batches.
pub fn batchCount(p: anytype, painted: []const u32) usize {
    var b: usize = 0;
    for (painted, 0..) |i, k| {
        if (k == 0 or keyOf(p.c.look[i]) != keyOf(p.c.look[painted[k - 1]])) b += 1;
    }
    return b;
}

/// The relayout boundary of each label (ct_layout.Plain): its nearest ancestor, or itself,
/// fixed on both axes (`min == max`), else the root. A fixed-size node's size does not depend
/// on its content, so a change of text below it moves nothing outside its subtree.
pub fn boundaries(p: anytype, labels: []const u32, out: []u32) void {
    const c = p.c;
    for (labels, out[0..labels.len]) |l, *b| {
        var i: u32 = l;
        while (i != 0 and !(c.min[0][i] == c.max[0][i] and c.min[1][i] == c.max[1][i])) i = c.parent[i];
        b.* = i;
    }
}

/// The rows to lay out again when the labels marked in `changed` change: the subtree of the
/// lowest row whose subtree holds every one of their boundaries. Null when none is marked.
pub fn dirtySpan(p: anytype, bounds: []const u32, changed: []const bool) ?[2]u32 {
    const c = p.c;
    var root: ?u32 = null;
    for (bounds, changed) |b, on| {
        if (!on) continue;
        var r = root orelse b;
        // Climb until the subtree of r holds b.
        while (!(r <= b and b < c.end[r])) r = c.parent[r];
        root = r;
    }
    return if (root) |r| .{ r, c.end[r] } else null;
}
