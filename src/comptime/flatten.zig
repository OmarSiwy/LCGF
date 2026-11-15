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
    var n = 1;
    for (s.children) |c| n += count(c);
    return n;
}

/// Everything about the structure of `spec` that is known before the program runs.
pub fn Flat(comptime spec: Spec) type {
    const n = count(spec);
    return struct {
        pub const node_count = n;
        /// The smallest integer that can index every node and hold `end`, which reaches `n`:
        /// u4 for the probe's 8 nodes. `tree.TreeOf(Index, .{ .array = n })` takes it as is.
        pub const Index = std.math.IntFittingRange(0, n);
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

/// The runtime front end's tree, built with `Tree.push` from the same spec, in a buffer it owns.
/// The reference every table here is compared against.
fn Runtime(comptime s: Spec) type {
    return struct {
        buf: [bytes]u8 align(mem.column_align) = undefined,

        const cap = count(s);
        const bytes = blk: {
            @setEvalBranchQuota(20_000);
            var counter: mem.Carver = .{ .buf = null };
            _ = Tree.init(&counter, cap);
            break :blk counter.off;
        };

        /// Pushes `s` depth-first, as `open` / `leaf` / `close` would, and seals every node.
        fn build(r: *@This()) Tree {
            var carver: mem.Carver = .{ .buf = &r.buf };
            var t = Tree.init(&carver, cap);
            pushSpec(&t, s, 0);
            return t;
        }
    };
}

/// Pushes `n` and its subtree under `parent` into any `TreeOf` tree, sealing every node.
fn pushSpec(t: anytype, comptime n: Spec, parent: anytype) void {
    const id: Id = if (n.id) |name| .from(name) else .none;
    const i = t.push(parent, id, &n.style);
    inline for (n.children) |c| pushSpec(t, c, i);
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
        var r: Runtime(s) = .{};
        const t = r.build();
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
        var r: Runtime(s) = .{};
        const big = r.build();
        // The same UI pushed into a tree indexed by F.Index agrees row for row.
        var small: tree.TreeOf(F.Index, .{ .array = F.node_count }) = .empty;
        pushSpec(&small, s, @as(F.Index, 0));
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
