//! Flatten: a comptime `Spec` turned into the same rows the runtime front end builds with
//! `Tree.push`, as read-only tables. Tier 1. Ported from prototype/comptime_ui_probe.zig
//! (`count`, `Ui().flatten`).
//!
//! Rows are in depth-first order, parents before children, exactly as `Tree.push` numbers them,
//! so a tier-0 pass cannot tell a flattened spec from a tree built at run time.

const std = @import("std");
const spec_zig = @import("spec.zig");
const Spec = spec_zig.Spec;

/// Nodes in `s`, itself included: the row count of the flattened spec.
pub fn count(comptime s: Spec) comptime_int {
    var n: comptime_int = 0;
    countFrom(s, &n);
    return n;
}

fn countFrom(comptime s: Spec, comptime n: *comptime_int) void {
    n.* += 1;
    @setEvalBranchQuota(quota(n.*));
    for (s.children) |c| countFrom(c, n);
}

/// Comptime backward branches (loop iterations and calls) the flatten may spend per node.
/// Measured: `count` spends three per node (its call, the `quota` call, a loop iteration) and is
/// the most expensive scope; 2 per node fails at 998 nodes, 3 passes every test here, and 4
/// leaves one spare. `Flat` raises the quota to `quota(n)` in every comptime scope it evaluates
/// (each container-level `const` is a scope of its own and starts at the default 1,000), and
/// `count` raises it as it goes, so no caller sets a quota for the flatten. Branches add up
/// within one evaluation, so a caller that builds a large spec with its own loops in the same
/// expression pays for those loops itself (or declares the spec as a container-level `const`).
///
/// Not a quota but a ceiling: the walks recurse once per level, and the compiler's own stack
/// limits that. Measured on x86-64 Linux: 2,000 levels compile with an 8 MiB stack (ulimit -s
/// 8192), 2,500 crash the compiler with 16 MiB and compile with an unlimited stack. A UI is
/// rarely 50 levels deep; an explicit-stack walk would lift the ceiling if one ever needs it.
const branches_per_node = 4;

/// The quota for evaluating the flatten of `nodes` nodes: the default plus `branches_per_node`
/// per node.
fn quota(comptime nodes: comptime_int) comptime_int {
    return 1000 + branches_per_node * nodes;
}

/// Everything about the structure of `spec` that is known before the program runs.
pub fn Flat(comptime spec: Spec) type {
    const n = count(spec);
    return struct {
        pub const node_count = n;
        /// The smallest integer that can index every node and hold `end`, which reaches `n`:
        /// u4 for the probe's 8 nodes. `tree.TreeOf(Index, .{ .array = n })` takes it as is.
        pub const Index = std.math.IntFittingRange(0, n);

        const Tables = struct {
            parent: [n]Index,
            end: [n]Index,
            depth: [n]Index,
        };

        const tables: Tables = blk: {
            @setEvalBranchQuota(quota(n));
            var t: Tables = undefined;
            var next: comptime_int = 0;
            walk(spec, 0, 0, &next, &t);
            break :blk t;
        };

        /// Numbers `s` and its subtree depth-first from `next`, as `Tree.push` numbers rows.
        fn walk(comptime s: Spec, comptime parent_ix: comptime_int, comptime d: comptime_int, comptime next: *comptime_int, comptime t: *Tables) void {
            const i = next.*;
            next.* += 1;
            t.parent[i] = parent_ix;
            t.depth[i] = d;
            for (s.children) |c| walk(c, i, d + 1, next, t);
            t.end[i] = next.*;
        }

        // Read-only tables: comptime constants, so they live in read-only data, not in RAM the
        // UI owns. Same contents as `Tree.Columns.parent` and `.end` after pushing the spec.
        /// Row of each node's parent; the root is its own parent.
        pub const parent: [n]Index = tables.parent;
        /// One past each node's last descendant: the subtree of i is rows [i, end[i]).
        pub const end: [n]Index = tables.end;
        /// Edges from the root to each node: 0 for the root, depth[parent] + 1 otherwise.
        pub const depth: [n]Index = tables.depth;

        /// Distinct depths: one more than the deepest node's depth.
        pub const levels = blk: {
            @setEvalBranchQuota(quota(n));
            break :blk @as(comptime_int, std.mem.max(Index, &depth)) + 1;
        };
        /// Level d is `level_order[level_start[d]..level_start[d + 1]]`.
        pub const level_start: [levels + 1]Index = start: {
            @setEvalBranchQuota(quota(n));
            var out: [levels + 1]Index = @splat(0);
            for (depth) |d| out[d + 1] += 1;
            for (1..levels + 1) |d| out[d] += out[d - 1];
            break :start out;
        };
        /// Rows ordered by depth, depth-first order within a depth (a stable counting sort by
        /// depth), so a pass that needs every parent done before its children can run one level
        /// at a time.
        pub const level_order: [n]Index = order: {
            @setEvalBranchQuota(quota(n));
            var out: [n]Index = undefined;
            var next: [levels]Index = level_start[0..levels].*;
            for (depth, 0..) |d, i| {
                out[next[d]] = i;
                next[d] += 1;
            }
            break :order out;
        };
    };
}

// ---- tests -------------------------------------------------------------------------------------

const testing = std.testing;
const mem = @import("../core/mem.zig");
const tree = @import("../core/tree.zig");
const Tree = tree.Tree;
const Id = @import("../core/types.zig").Id;
const col = spec_zig.col;
const row = spec_zig.row;
const label = spec_zig.label;
const checkbox = spec_zig.checkbox;
const slider = spec_zig.slider;

/// The runtime front end's tree, built with `Tree.push` from the same spec, in a buffer from the
/// testing allocator (a few thousand nodes are megabytes, too much for the stack). The reference
/// every table here is compared against.
fn Runtime(comptime s: Spec) type {
    return struct {
        buf: []align(mem.column_align) u8,
        tree: Tree,

        const cap = count(s);
        const bytes = blk: {
            @setEvalBranchQuota(20_000);
            var counter: mem.Carver = .{ .buf = null };
            _ = Tree.init(&counter, cap);
            break :blk counter.off;
        };

        fn init() !@This() {
            const buf = try testing.allocator.alignedAlloc(u8, .fromByteUnits(mem.column_align), bytes);
            var carver: mem.Carver = .{ .buf = buf };
            var t = Tree.init(&carver, cap);
            pushSpec(&t, &s, @as(u32, 0));
            return .{ .buf = buf, .tree = t };
        }

        fn deinit(r: *const @This()) void {
            testing.allocator.free(r.buf);
        }
    };
}

/// Pushes `n` and its subtree under `parent` into any `TreeOf` tree, depth-first as `open` /
/// `leaf` / `close` would, sealing every node. A run-time walk over the spec's nodes (a `Spec`
/// is plain data), so large specs do not unroll into code.
fn pushSpec(t: anytype, n: *const Spec, parent: anytype) void {
    const id: Id = if (n.id) |name| .hash(name) else .none;
    const i = t.push(parent, id, &n.style);
    for (n.children) |*c| pushSpec(t, c, i);
    t.seal(i);
}

/// The probe's usage spec.
const mixer = col(.{ .pad = @splat(8), .gap = 4 }, .{
    label(.title),
    row(.{ .gap = 8 }, .{ checkbox(.mute, .muted), slider(.volume, .volume) }),
    row(.{ .gap = 8 }, .{ label(.title), slider(.pan, .pan) }),
});

/// A chain: each node the only child of the one before.
fn chain(comptime depth: comptime_int) Spec {
    return if (depth == 1) label(.x) else col(.{}, .{chain(depth - 1)});
}

/// One root over `n` leaves.
fn wide(comptime n: comptime_int) Spec {
    var leaves: [n]Spec = undefined;
    for (&leaves) |*l| l.* = label(.x);
    return row(.{}, leaves);
}

/// Specs of different shapes, for tests that hold for any spec.
const shapes = .{ mixer, label(.x), col(.{}, .{}), chain(9), wide(17), col(.{}, .{ wide(3), chain(4), mixer }) };

test "count: the node count is the runtime tree's row count for the same UI" {
    try testing.expectEqual(8, count(mixer));
    inline for (shapes) |s| {
        const r = try Runtime(s).init();
        defer r.deinit();
        const t = r.tree;
        try t.check();
        try testing.expect(!t.overflow);
        try testing.expectEqual(count(s), t.len);
    }
}

test "Flat.Index: the smallest index type for the count holds the runtime tree's rows" {
    try testing.expectEqual(u4, Flat(mixer).Index);
    try testing.expectEqual(u1, Flat(label(.x)).Index);
    // 7 nodes: end reaches 7, so u3 is enough; 8 nodes need u4.
    try testing.expectEqual(u3, Flat(wide(6)).Index);
    try testing.expectEqual(u4, Flat(wide(7)).Index);
    try testing.expectEqual(u5, Flat(wide(17)).Index);
    inline for (shapes) |s| {
        const F = Flat(s);
        try testing.expectEqual(count(s), F.node_count);
        const r = try Runtime(s).init();
        defer r.deinit();
        const big = r.tree;
        // The same UI pushed into a tree indexed by F.Index agrees row for row.
        var small: tree.TreeOf(F.Index, .{ .array = F.node_count }) = .empty;
        pushSpec(&small, &s, @as(F.Index, 0));
        try small.check();
        try testing.expect(!small.overflow);
        try testing.expectEqual(big.len, small.len);
        for (0..big.len) |i| {
            try testing.expectEqual(big.c.parent[i], small.c.parent[i]);
            try testing.expectEqual(big.c.end[i], small.c.end[i]);
        }
        try testing.expect(big.len <= std.math.maxInt(F.Index));
    }
}

test "Flat.parent, Flat.end: the probe's tables for its mixer" {
    try testing.expectEqualSlices(u4, &.{ 0, 0, 0, 2, 2, 0, 5, 5 }, &Flat(mixer).parent);
    try testing.expectEqualSlices(u4, &.{ 8, 2, 5, 4, 5, 8, 7, 8 }, &Flat(mixer).end);
}

test "Flat.depth, Flat.level_order, Flat.level_start: the mixer's levels" {
    const M = Flat(mixer);
    try testing.expectEqualSlices(u4, &.{ 0, 1, 1, 2, 2, 1, 2, 2 }, &M.depth);
    try testing.expectEqual(3, M.levels);
    try testing.expectEqualSlices(u4, &.{ 0, 1, 2, 5, 3, 4, 6, 7 }, &M.level_order);
    try testing.expectEqualSlices(u4, &.{ 0, 1, 4, 8 }, &M.level_start);
}

/// Every table of `Flat(s)` equals what `Tree.push` builds from the same spec: the row count,
/// parent and end row for row, the depth derived from the runtime parent column, and the level
/// order read off that depth.
fn expectSameTree(comptime s: Spec) !void {
    const F = Flat(s);
    const r = try Runtime(s).init();
    defer r.deinit();
    const t = r.tree;
    try t.check();
    try testing.expect(!t.overflow);
    try testing.expectEqual(F.node_count, t.len);
    for (0..t.len) |i| {
        try testing.expectEqual(t.c.parent[i], F.parent[i]);
        try testing.expectEqual(t.c.end[i], F.end[i]);
    }
    // Depth from the runtime parent column; parents come before children.
    var d: [F.node_count]u32 = undefined;
    d[0] = 0;
    for (1..t.len) |i| d[i] = d[t.c.parent[i]] + 1;
    for (0..t.len) |i| try testing.expectEqual(d[i], F.depth[i]);
    // Level order: every row of depth 0, then depth 1, ..., each level in row order.
    var k: usize = 0;
    for (0..F.levels) |level| {
        try testing.expectEqual(k, F.level_start[level]);
        for (0..t.len) |i| if (d[i] == level) {
            try testing.expectEqual(i, F.level_order[k]);
            k += 1;
        };
    }
    try testing.expectEqual(t.len, k);
    try testing.expectEqual(t.len, F.level_start[F.levels]);
}

/// A spec of `n` nodes whose shape follows `seed`: each node splits what is left of its subtree
/// into children of pseudo-random sizes, alternating rows and columns, ids and bindings.
fn randomSpec(comptime seed: u64, comptime n: comptime_int) Spec {
    @setEvalBranchQuota(1000 + 100 * n);
    if (n == 1) return if (seed & 1 == 0) label(.x) else slider(.s, .s);
    var children: []const Spec = &.{};
    var rest = n - 1;
    var x = seed;
    while (rest > 0) {
        x = x *% 6364136223846793005 +% 1442695040888963407;
        const size = 1 + (x >> 33) % rest;
        children = children ++ [_]Spec{randomSpec(x, size)};
        rest -= size;
    }
    const style: @import("../core/types.zig").Style = .{ .gap = @floatFromInt(seed % 7), .pad = @splat(@floatFromInt(n % 5)) };
    return if (seed & 2 == 0) .{ .kind = .col, .style = style, .children = children } else .{ .kind = .row, .style = style, .children = children };
}

test "equivalence: every flatten table equals the tree Tree.push builds from the same UI" {
    inline for (shapes) |s| try expectSameTree(s);
    inline for (0..24) |k| try expectSameTree(comptime randomSpec(k * 7919 + 1, 1 + k * 3));
    try expectSameTree(comptime randomSpec(42, 300));
}

/// A row over `n` leaves, built without recursion (a tuple of thousands would be slow to write).
fn bigWide(comptime n: comptime_int) Spec {
    @setEvalBranchQuota(quota(n));
    var leaves: [n]Spec = undefined;
    for (&leaves) |*l| l.* = label(.x);
    return row(.{}, leaves);
}

/// `chain(n)` built in a loop, so building it does not recurse.
fn bigChain(comptime n: comptime_int) Spec {
    @setEvalBranchQuota(quota(n));
    var s = label(.x);
    for (0..n - 1) |_| s = col(.{}, .{s});
    return s;
}

// Container-level, so building each spec is an evaluation of its own: branches spent inside one
// evaluation add up, and the flatten's quota covers the flatten, not the caller's own loops.
const wide_5000 = bigWide(5000);
const chain_1000 = bigChain(1000);
const random_2000 = randomSpec(7, 2000);

test "quotas: large specs flatten without the caller raising a quota, and equal the runtime tree" {
    // 5,001 nodes, one level: the widest loops (count, walk, the level tables).
    try expectSameTree(wide_5000);
    try testing.expectEqual(u13, Flat(wide_5000).Index);
    // 1,000 levels: the deepest comptime recursion this test keeps (see `branches_per_node`).
    try expectSameTree(chain_1000);
    try expectSameTree(random_2000);
}
