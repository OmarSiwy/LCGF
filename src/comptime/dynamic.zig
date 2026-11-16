//! Dynamic regions: the parts of a comptime UI whose rows exist only when run-time state says
//! so (`spec.list`). Tier 1.
//!
//! A region's rows are all reserved: the flattened tables hold every row it could ever need,
//! so they stay read-only and the row count exact. Each frame a selection (`Selection`, read
//! from the state with `select`) gives every region a number, and `mask` turns it into one
//! mask per row: all ones for a live row, zero for a dead one. Layout ANDs the mask into the
//! rows it reads (src/comptime/layout.zig): a dead row is out of flow, at most 0 px on both
//! axes, and senses nothing, so it takes no space, is not drawn (zero area is not visible) and
//! is not hit. The live rows then lay out exactly as a runtime tree built with only them
//! (the tests below). This is `Frame.reuse`'s idea turned around: instead of copying a
//! subtree's rows from last frame, every row a subtree can have is already there, and a frame
//! only decides which of them count.

const std = @import("std");
const simd = @import("../core/simd.zig");
const spec_zig = @import("spec.zig");
const flatten = @import("flatten.zig");
const Spec = spec_zig.Spec;
const RegionKind = spec_zig.RegionKind;

/// One region of a flattened spec.
pub const Info = struct {
    kind: RegionKind,
    /// State field that selects the live rows.
    bind: []const u8,
    /// The region's node.
    row: u32,
    /// One past its last descendant.
    end: u32,
    /// Rows of one list copy.
    stride: u32,
    /// List copies reserved.
    max: u32,
};

/// One region's run-time input: a list's count.
pub const Select = struct { n: u32 = 0 };

fn collect(comptime s: Spec, comptime next: *comptime_int, comptime out: *[]const Info) void {
    const i = next.*;
    next.* += 1;
    if (s.region) |r| out.* = out.* ++ [_]Info{.{
        .kind = r.kind,
        .bind = r.bind,
        .row = i,
        .end = i + flatten.count(s),
        .stride = if (s.children.len == 0) 0 else flatten.count(s.children[0]),
        .max = s.children.len,
    }};
    for (s.children) |c| collect(c, next, out);
}

/// The regions of `spec`, in depth-first order of their nodes.
pub fn Regions(comptime spec: Spec) type {
    const n = flatten.count(spec);
    const R = simd.rows(n);
    const found = blk: {
        @setEvalBranchQuota(10_000 + 100 * n);
        var out: []const Info = &.{};
        var next: comptime_int = 0;
        collect(spec, &next, &out);
        break :blk out;
    };
    return struct {
        pub const count = found.len;
        pub const regions: [count]Info = found[0..count].*;
        /// One `Select` per region, in `regions` order.
        pub const Selection = [count]Select;
        /// One word per padded row: all ones live, zero dead.
        pub const Mask = [R]u32;

        /// `volatile_rows[i]`: row i's layout depends on a selection, being in a region or
        /// above one. Layout never folds these at compile time.
        pub const volatile_rows: [n]bool = blk: {
            @setEvalBranchQuota(10_000 + 100 * n);
            const parent = flatten.Flat(spec).parent;
            var out: [n]bool = @splat(false);
            for (regions) |r| {
                for (r.row..r.end) |j| out[j] = true;
                var p: usize = r.row;
                while (p != 0) : (p = parent[p]) out[parent[p]] = true;
            }
            break :blk out;
        };

        /// The selection `state` makes: each region's bound field as a number (a count past
        /// u32 saturates).
        pub fn select(comptime State: type, state: *const State) Selection {
            var out: Selection = undefined;
            inline for (regions, &out) |r, *o| o.n = number(@field(state, r.bind));
            return out;
        }

        /// The live mask of `sel`. Rows outside every region are always live; a row inside
        /// regions is live when each of them keeps it.
        pub fn mask(sel: Selection) Mask {
            var m: Mask = @splat(~@as(u32, 0));
            inline for (regions, sel) |r, s| {
                const first = r.row + 1;
                const len = switch (r.kind) {
                    .list => @min(s.n, r.max) * r.stride,
                };
                for (first..r.end) |j| m[j] &= 0 -% @as(u32, @intFromBool(@as(u32, @intCast(j)) - first < len));
            }
            return m;
        }
    };
}

/// A bound selector field as a count: integers saturate into u32.
fn number(v: anytype) u32 {
    return switch (@typeInfo(@TypeOf(v))) {
        .int => @intCast(std.math.clamp(v, 0, std.math.maxInt(u32))),
        else => @compileError("a list count is an integer field, not " ++ @typeName(@TypeOf(v))),
    };
}

// ---- tests -------------------------------------------------------------------------------------

const testing = std.testing;
const examples = @import("examples.zig");
const ct_layout = @import("layout.zig");
const tree = @import("../core/tree.zig");
const layout = @import("../layout/layout.zig");
const mem = @import("../core/mem.zig");
const Texts = @import("../core/texts.zig").Texts;
const Id = @import("../core/types.zig").Id;

/// Regions in `s`'s subtree, itself included.
fn regionsIn(comptime s: Spec) comptime_int {
    var k: comptime_int = @intFromBool(s.region != null);
    for (s.children) |c| k += regionsIn(c);
    return k;
}

/// Pushes only the live rows of `s` under `sel`, as an application would build the same UI
/// with the runtime front end. `next` counts regions in depth-first order, dead ones included,
/// as `Regions` numbers them.
fn pushLive(t: anytype, comptime s: Spec, parent: u32, sel: []const Select, next: *u32) void {
    const id: Id = if (s.id) |name| .hash(name) else .none;
    const i = t.push(parent, id, &s.style);
    const k = next.*;
    if (s.region != null) next.* += 1;
    inline for (s.children, 0..) |c, ci| {
        const shown = if (s.region) |r| switch (r.kind) {
            .list => ci < sel[k].n,
        } else true;
        if (shown) pushLive(t, c, i, sel, next) else next.* += regionsIn(c);
    }
    t.seal(i);
}

fn toF32(x: anytype) f32 {
    return if (@TypeOf(x) == f32) x else @floatFromInt(x);
}

/// `L.runLive` under `sel` against the runtime tree of the live rows: the live rows, in order,
/// get the runtime rows' sizes, positions, rects and visibility; every dead row is 0 px and
/// not visible.
fn expectLive(comptime L: type, comptime s: Spec, sel: L.Regions.Selection, viewport: [2]f32) !void {
    const C = L.Cols;
    var buf: [1 << 17]u8 align(64) = undefined;
    var carver: mem.Carver = .{ .buf = &buf };
    var t = tree.Tree.init(&carver, C.node_count);
    var tx = Texts.init(&carver, 1);
    var next: u32 = 0;
    pushLive(&t, s, 0, &sel, &next);
    layout.run(&t, &tx, viewport);

    var scratch: L.Scratch = undefined;
    var ram: C.Dynamic = undefined;
    L.runLive(&scratch, &ram, viewport, sel);
    const m = L.Regions.mask(sel);
    var r: u32 = 0;
    for (0..C.node_count) |i| {
        if (m[i] == 0) {
            inline for (0..2) |a| try testing.expectEqual(0, ram.size[a][i]);
            try testing.expectEqual(0, ram.visible[i]);
            continue;
        }
        inline for (0..2) |a| {
            try testing.expectEqual(t.c.size[a][r], ram.size[a][i]);
            try testing.expectEqual(t.c.pos[a][r], ram.pos[a][i]);
        }
        inline for (0..4) |k| {
            try testing.expectEqual(t.c.rect[k][r], toF32(ram.rect[k][i]));
            try testing.expectEqual(t.c.vis[k][r], toF32(ram.vis[k][i]));
        }
        try testing.expectEqual(t.c.visible[r], ram.visible[i]);
        r += 1;
    }
    try testing.expectEqual(t.len, r);
}

test "list: the to-do example lays out its live copies as the runtime tree of them, at every count" {
    const e = examples.dynamic[0];
    const P = ct_layout.Plain(e.spec, e.options);
    const L = ct_layout.Layout(e.spec, e.options);
    const D = P.Regions;
    try testing.expectEqual(1, D.count);
    // 1 + 8 copies of 3 rows + the footer's 3: the template is bounded, rows are reserved.
    try testing.expectEqual(1 + 1 + 1 + 8 * 3 + 3, P.Cols.node_count);
    try testing.expectEqual(Info{ .kind = .list, .bind = "len", .row = 2, .end = 27, .stride = 3, .max = 8 }, D.regions[0]);
    // The footer row folds even beside a dynamic region; nothing in or above the list does.
    try testing.expectEqual(2, L.folded_rows);
    for (0..11) |count| {
        var state: examples.Todo = .{ .len = @intCast(count) };
        const sel = D.select(examples.Todo, &state);
        try testing.expectEqual(@min(count, 10), sel[0].n);
        inline for (.{ [2]f32{ 800, 600 }, [2]f32{ 120, 90 }, [2]f32{ 1, 1 } }) |vp| {
            try expectLive(P, e.spec, sel, vp);
            try expectLive(L, e.spec, sel, vp);
        }
    }
}

test "Regions.mask: live rows are the first count copies; a count past max shows max" {
    const D = Regions(examples.todo);
    const r = D.regions[0];
    inline for (.{ 0, 1, 5, 8, 9, 1 << 31 }) |k| {
        const m = D.mask(.{.{ .n = k }});
        for (0..r.row + 1) |j| try testing.expectEqual(~@as(u32, 0), m[j]);
        for (r.row + 1..r.end) |j| try testing.expectEqual(j - (r.row + 1) < @min(k, 8) * 3, m[j] != 0);
        for (r.end..m.len) |j| try testing.expectEqual(~@as(u32, 0), m[j]);
    }
}
