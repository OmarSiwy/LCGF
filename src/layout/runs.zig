//! runs: layout passes over runs of siblings. Tier 0, no allocator.
//!
//! The tree is depth-first, so the children of one parent that follow each other in the columns
//! are a run of rows: a row and the next have the same parent exactly when the first is a leaf.
//! Everything a pass reads of the parent is the same for the whole run, so it is loaded once,
//! what the parent accumulates (its cursor) stays in a register until the run ends, and while
//! the next `simd.lanes` rows are all in the run they are read as vectors straight from the
//! columns. Each row's arithmetic is `layout.zig`'s, operation for operation, so the columns
//! come out the same bit for bit: only the order of the loads and stores changes.
//!
//! A run has its own cost, the end of each one, so a tree of short runs is quicker row by row.
//! `survey` looks at the parents once per frame and sets `Tree.wide` when enough rows are in
//! runs of a vector or more; the passes that have a run form take it then, and `layout.zig`'s
//! row-by-row form otherwise.

const std = @import("std");
const simd = @import("../core/simd.zig");
const types = @import("../core/types.zig");
const Tree = @import("../core/tree.zig").Tree;

const W = simd.lanes;

/// `L` rows of an f32 column as one value: a vector, or the scalar for one row.
fn Rows(comptime L: comptime_int) type {
    return if (L == 1) f32 else @Vector(L, f32);
}

inline fn load(comptime L: comptime_int, col: []const f32, i: usize) Rows(L) {
    return if (L == 1) col[i] else col[i..][0..L].*;
}

inline fn store(comptime L: comptime_int, col: []f32, i: usize, v: Rows(L)) void {
    if (L == 1) col[i] = v else col[i..][0..L].* = v;
}

inline fn all(comptime L: comptime_int, x: f32) Rows(L) {
    return if (L == 1) x else @splat(x);
}

/// Whether the `W` rows from `i` are all children of `p` and before `last`: a whole vector of
/// the run. One compare of `W` parents.
pub inline fn whole(parent: []const u32, i: usize, last: usize, p: u32) bool {
    return i + W <= last and @reduce(.And, simd.loadU(parent, i) == simd.u(p));
}

/// Sets `t.wide`: whether at least an eighth of the rows head a whole vector of siblings, `W`
/// rows next to each other with one parent. Two compares per vector of rows: which rows have
/// the next row's parent, then which of those start `W - 1` of them in a row.
pub fn survey(t: *Tree) void {
    const n: usize = t.len;
    std.debug.assert(n <= t.cap);
    t.wide = false;
    if (W == 1) return;
    const Window = @Int(.unsigned, 2 * W);
    const parent = t.c.parent;
    var heads: usize = 0;
    var i: usize = 1;
    // Bit l: rows i + l and i + l + 1 are siblings.
    var here: Window = simd.bits(simd.loadU(parent, i) == simd.loadU(parent, i + 1));
    while (i + 2 * W <= n) : (i += W) {
        const next: Window = simd.bits(simd.loadU(parent, i + W) == simd.loadU(parent, i + W + 1));
        // Bit l of `pairs` on to bit l + W - 2: rows i + l to i + l + W - 1 are all siblings.
        const pairs = here | (next << W);
        var head = pairs;
        inline for (1..W - 1) |shift| head &= pairs >> shift;
        heads += @popCount(@as(simd.Mask, @truncate(head)));
        here = next;
    }
    t.wide = heads * 8 >= n and heads != 0;
}

/// What `place` reads of a parent, the same for each of its children.
const Lead = struct {
    /// Where the parent's content starts: its position, plus padding, less scroll.
    base: [2]f32,
    /// The parent's size inside its padding.
    inner: [2]f32,
    /// Free space ahead of the first child, from the parent's main alignment.
    lead: [2]f32,
    main: [2]f32,
    cross: f32,
    gap: f32,
};

inline fn leadOf(c: *const Tree.Columns, p: usize) Lead {
    var pp: Lead = undefined;
    inline for (0..2) |a| {
        const inner = c.size[a][p] - c.pad_lo[a][p] - c.pad_hi[a][p];
        const free = simd.maxF(inner - c.used[a][p] - c.gap_total[p], 0);
        pp.inner[a] = inner;
        pp.lead[a] = free * c.align_main[p];
        pp.base[a] = c.pos[a][p] + c.pad_lo[a][p] - c.scroll[a][p];
        pp.main[a] = c.main[a][p];
    }
    pp.cross = c.align_cross[p];
    pp.gap = c.gap[p];
    return pp;
}

/// The columns `place` reads and writes for each row, held as locals so a loop indexes them
/// directly instead of reloading each slice from the tree.
const PlaceCols = struct {
    flow: []const f32,
    size: [2][]const f32,
    offset: [2][]const f32,
    pos: [2][]f32,

    inline fn of(c: *const Tree.Columns) PlaceCols {
        return .{ .flow = c.flow, .size = c.size, .offset = c.offset, .pos = c.pos };
    }
};

/// Places rows [i, i + L), children of the parent `pp` describes, with `cursor` the parent's
/// running sum before the first of them. Returns the cursor after the last.
inline fn placeRows(comptime L: comptime_int, k: PlaceCols, i: usize, pp: Lead, cursor: f32) f32 {
    std.debug.assert(i + L <= k.flow.len);
    const V = Rows(L);
    const fl = load(L, k.flow, i);
    const size: [2]V = .{ load(L, k.size[0], i), load(L, k.size[1], i) };
    const step = size[0] * all(L, pp.main[0]) + size[1] * all(L, pp.main[1]);
    const advance = (step + all(L, pp.gap)) * fl;
    // The cursor is a sum in sibling order, so it is one add per row whatever `L` is: the
    // rows of a vector take their turns, and only the rest of the arithmetic is shared.
    // sums[l] is the cursor before row l.
    var sums: [L + 1]f32 = undefined;
    sums[0] = cursor;
    const each: [L]f32 = if (L == 1) .{advance} else advance;
    inline for (0..L) |l| sums[l + 1] = sums[l] + each[l];
    const before: V = if (L == 1) sums[0] else sums[0..L].*;
    inline for (0..2) |a| {
        // `+ 0` twice: where the flex pass adds a margin. Kept so a -0 comes out as it does there.
        const room = simd.maxF(all(L, pp.inner[a]) - size[a], all(L, 0));
        const across = room * all(L, pp.cross) + all(L, 0);
        const along = all(L, pp.lead[a]) + before + all(L, 0);
        const in_flow = across + all(L, pp.main[a]) * (along - across);
        store(L, k.pos[a], i, all(L, pp.base[a]) + fl * in_flow + load(L, k.offset[a], i));
    }
    return sums[L];
}

/// A row and the parent's cursor before it: where a pass over a run has got to.
const At = struct { row: usize, cursor: f32 };

/// The whole vectors of a run, from `first`. Out of line, and it reads the parent again, so a
/// short run pays for none of it and keeps its own copy of the parent in registers.
noinline fn placeWide(c: *const Tree.Columns, first: usize, n: usize, p: u32, cursor: f32) At {
    const k: PlaceCols = .of(c);
    const pp = leadOf(c, p);
    const parent = c.parent;
    var i = first;
    var cur = cursor;
    while (whole(parent, i, n, p)) : (i += W) cur = placeRows(W, k, i, pp, cur);
    return .{ .row = i, .cursor = cur };
}

/// `layout.place` over the whole tree, run by run.
pub fn place(t: *Tree) void {
    const n: usize = t.len;
    if (n == 0) return;
    std.debug.assert(n <= t.cap);
    const c = &t.c;
    c.pos[0][0] = 0;
    c.pos[1][0] = 0;
    const k: PlaceCols = .of(c);
    const parent = c.parent;
    const cursor = c.cursor;
    var i: usize = 1;
    // Ends when every row is placed: each turn places at least row `i`.
    while (i < n) {
        const p = parent[i];
        var cur = cursor[p];
        // A run of `W` rows or more goes by whole vectors; what is left of it is under `W` rows.
        const wide = W > 1 and i + W <= n and parent[i + W - 1] == p and parent[i + 1] == p;
        if (wide) {
            const at = placeWide(c, i, n, p, cur);
            i = at.row;
            cur = at.cursor;
        }
        const pp = leadOf(c, p);
        while (i < n and parent[i] == p) : (i += 1) cur = placeRows(1, k, i, pp, cur);
        cursor[p] = cur;
    }
}

/// The columns `fit` reads and writes for each row on one axis, as locals.
const FitCols = struct {
    parent: []const u32,
    fit: []f32,
    nat: []f32,
    main: []const f32,
    gap_total: []const f32,
    lo: []const f32,
    hi: []const f32,
    min: []const f32,
    max: []const f32,
    flow: []const f32,
    grow: []const f32,
    grow_sum: []f32,

    inline fn of(c: *const Tree.Columns, a: usize) FitCols {
        return .{
            .parent = c.parent,
            .fit = c.fit[a],
            .nat = c.nat[a],
            .main = c.main[a],
            .gap_total = c.gap_total,
            .lo = c.pad_lo[a],
            .hi = c.pad_hi[a],
            .min = c.min[a],
            .max = c.max[a],
            .flow = c.flow,
            .grow = c.grow[a],
            .grow_sum = c.grow_sum[a],
        };
    }
};

/// What a run folds into its parent: the parent's `fit`, a sum along its main axis or a max
/// across it, and its `grow_sum`.
const Fold = struct { fit: f32, grow: f32 };

/// Natural sizes of rows [i, i + L), stored, and each folded into `into`, their parent's sums,
/// last row first as `layout.fit` folds them. `stacked` is whether the parent stacks its
/// children along this axis.
inline fn fitRows(comptime L: comptime_int, k: FitCols, i: usize, stacked: bool, into: Fold) Fold {
    std.debug.assert(i + L <= k.fit.len);
    // All descendants have larger rows, so `fit` of these rows is complete here.
    const content = load(L, k.fit, i) + load(L, k.main, i) * load(L, k.gap_total, i);
    var nat = content + load(L, k.lo, i) + load(L, k.hi, i);
    nat = simd.minF(simd.maxF(nat, load(L, k.min, i)), load(L, k.max, i));
    store(L, k.nat, i, nat);
    const fl = load(L, k.flow, i);
    const contrib: [L]f32 = if (L == 1) .{nat * fl} else nat * fl;
    const grown: [L]f32 = if (L == 1) .{load(L, k.grow, i) * fl} else load(L, k.grow, i) * fl;
    return fold(L, stacked, contrib, grown, into);
}

/// `into` with what each of `L` rows gives its parent folded in, last row first: `contrib` by
/// a sum along the parent's main axis or a max across it, `grown` by a sum.
inline fn fold(
    comptime L: comptime_int,
    stacked: bool,
    contrib: [L]f32,
    grown: [L]f32,
    into: Fold,
) Fold {
    comptime std.debug.assert(L >= 1);
    var f = into;
    if (L == 1) {
        // One row: sum and max side by side, then a select, as the row-by-row pass has it.
        const sum = f.fit + contrib[0];
        const mx = simd.selF(f.fit < contrib[0], contrib[0], f.fit);
        return .{ .fit = simd.selF(stacked, sum, mx), .grow = f.grow + grown[0] };
    }
    // A vector of rows: the same sum or max, one row after another in a register. Which of
    // the two is the parent's, so it is one jump for the vector and none for the rows.
    if (stacked) {
        inline for (0..L) |r| f.fit += contrib[L - 1 - r];
    } else {
        inline for (0..L) |r| {
            const given = contrib[L - 1 - r];
            f.fit = simd.selF(f.fit < given, given, f.fit);
        }
    }
    inline for (0..L) |r| f.grow += grown[L - 1 - r];
    return f;
}

/// A row and its parent's sums after it: where the fold over a run has got to.
const Folded = struct { row: usize, into: Fold };

/// The whole vectors of a run, downwards from `from`. Out of line, with its own copy of the
/// columns, so a short run pays for none of it.
noinline fn fitWide(
    c: *const Tree.Columns,
    a: usize,
    first: usize,
    from: usize,
    p: u32,
    into: Fold,
) Folded {
    std.debug.assert(from > first + W);
    const k: FitCols = .of(c, a);
    const stacked = k.main[p] != 0;
    var i = from;
    var f = into;
    // Ends at the run's first row, or at the span's: `i` goes down by a vector a turn.
    while (i > first + W and @reduce(.And, simd.loadU(k.parent, i - W) == simd.u(p))) {
        i -= W;
        f = fitRows(W, k, i, stacked, f);
    }
    return .{ .row = i, .into = f };
}

/// `layout.fit`'s fold over the rows after `first` up to `last`, last row first: each row's
/// natural size on axis `a`, summed or maxed into its parent, a run of siblings at a time. Row
/// `first` itself and the reciprocals are the caller's, as in `layout.fit`.
pub fn fit(t: *Tree, a: usize, first: usize, last: usize) void {
    std.debug.assert(first < last);
    std.debug.assert(last <= t.len);
    const k: FitCols = .of(&t.c, a);
    const parent = k.parent;
    var i: usize = last;
    // Ends when every row after `first` is folded: each turn folds at least row `i - 1`.
    while (i > first + 1) {
        const p = parent[i - 1];
        var into: Fold = .{ .fit = k.fit[p], .grow = k.grow_sum[p] };
        const wide = W > 1 and i > first + W and parent[i - W] == p and parent[i - 2] == p;
        if (wide) {
            const at = fitWide(&t.c, a, first, i, p, into);
            i = at.row;
            into = at.into;
        }
        const stacked = k.main[p] != 0;
        while (i > first + 1 and parent[i - 1] == p) {
            i -= 1;
            into = fitRows(1, k, i, stacked, into);
        }
        k.fit[p] = into.fit;
        k.grow_sum[p] = into.grow;
    }
}

const testing = std.testing;
const mem = @import("../core/mem.zig");
const layout = @import("layout.zig");
const check = @import("check.zig");

test "survey: wide for a tree of long runs of siblings, not for one of short runs" {
    var raw: [256 * 1024]u8 align(mem.column_align) = undefined;
    var carver: mem.Carver = .{ .buf = &raw };
    var t = Tree.init(&carver, 256);
    // Four parents of `2 * W` leaves each.
    const root = t.push(0, .none, &.{});
    for (0..4) |_| {
        const box = t.push(root, .none, &.{});
        for (0..2 * W) |_| _ = t.push(box, .none, &.{});
        t.seal(box);
    }
    t.seal(root);
    survey(&t);
    try testing.expectEqual(W > 1, t.wide);
    // Twelve parents of one leaf less than a vector each.
    t.reset();
    _ = t.push(0, .none, &.{});
    for (0..12) |_| {
        const box = t.push(root, .none, &.{});
        for (0..W - 1) |_| _ = t.push(box, .none, &.{});
        t.seal(box);
    }
    t.seal(root);
    t.wide = true;
    survey(&t);
    try testing.expect(!t.wide);
}

test "fit: the row-by-row fold's sizes and sums, bit for bit, on random trees with runs" {
    var raw: [1024 * 1024]u8 align(mem.column_align) = undefined;
    var carver: mem.Carver = .{ .buf = &raw };
    var t = Tree.init(&carver, 1000);
    var prng: std.Random.DefaultPrng = .init(0xf17);
    var want: [3][1000]f32 = undefined;
    for (0..200) |_| {
        check.randomRuns(&t, prng.random(), 1 + prng.random().uintLessThan(u32, t.cap));
        const n = t.len;
        for (0..2) |a| {
            // Reference: row by row.
            layout.prepare(&t);
            check.fitRef(&t, a, 0, n);
            const cols = [3][]f32{ t.c.fit[a], t.c.nat[a], t.c.grow_sum[a] };
            for (cols, 0..) |col, k| @memcpy(want[k][0..n], col[0..n]);
            // Run by run, from the same inputs.
            layout.prepare(&t);
            @memset(t.c.nat[a], std.math.nan(f32));
            fit(&t, a, 0, n);
            for (cols, 0..) |col, k| {
                // Row 0's natural size is the caller's to set.
                const from: usize = if (k == 1) 1 else 0;
                const got: []const u32 = @ptrCast(col[from..n]);
                try testing.expectEqualSlices(u32, @ptrCast(want[k][from..n]), got);
            }
        }
    }
}

test "place: layout.place's positions and cursors, bit for bit, on random trees with runs" {
    var raw: [1024 * 1024]u8 align(mem.column_align) = undefined;
    var carver: mem.Carver = .{ .buf = &raw };
    var t = Tree.init(&carver, 1000);
    var prng: std.Random.DefaultPrng = .init(0x51b1);
    var want: [3][1000]f32 = undefined;
    for (0..200) |_| {
        check.randomRuns(&t, prng.random(), 1 + prng.random().uintLessThan(u32, t.cap));
        const n = t.len;
        layout.prepare(&t);
        for ([2]types.Axis{ .x, .y }, [2]f32{ 1280, 800 }) |axis, viewport| {
            layout.fit(&t, axis);
            layout.resolve(&t, axis, viewport);
        }
        // Reference: row by row.
        layout.place(&t);
        for (0..2) |a| @memcpy(want[a][0..n], t.c.pos[a][0..n]);
        @memcpy(want[2][0..n], t.c.cursor[0..n]);
        // Run by run, from the same sizes.
        @memset(t.c.cursor, 0);
        for (0..2) |a| @memset(t.c.pos[a], std.math.nan(f32));
        place(&t);
        for ([3][]const f32{ t.c.pos[0], t.c.pos[1], t.c.cursor }, 0..) |col, k| {
            const got: []const u32 = @ptrCast(col[0..n]);
            try testing.expectEqualSlices(u32, @ptrCast(want[k][0..n]), got);
        }
    }
}
