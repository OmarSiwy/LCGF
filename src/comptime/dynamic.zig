//! Dynamic regions: the parts of a comptime UI whose rows exist only when run-time state says
//! so (`spec.list`, `spec.when`, `spec.choice`). Tier 1.
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
    /// Rows of one list copy; 0 for other kinds.
    stride: u32,
    /// List copies or choice alternatives reserved; 0 for a `when`.
    max: u32,
};

/// One region's run-time input: a list's count, a `when`'s condition as 0 or 1, a `choice`'s
/// alternative.
pub const Select = struct { n: u32 = 0 };

fn collect(comptime s: Spec, comptime next: *comptime_int, comptime out: *[]const Info) void {
    const i = next.*;
    next.* += 1;
    if (s.region) |r| out.* = out.* ++ [_]Info{.{
        .kind = r.kind,
        .bind = r.bind,
        .row = i,
        .end = i + flatten.count(s),
        .stride = if (r.kind != .list or s.children.len == 0) 0 else flatten.count(s.children[0]),
        .max = if (r.kind == .when) 0 else s.children.len,
    }};
    for (s.children) |c| collect(c, next, out);
}

/// Assign each descriptor a retained row. Alternatives start at the same row and the
/// next sibling follows the largest alternative (including any nested choices).
fn assignSlots(comptime s: Spec, base: u32, next: *usize, slots: []u32) u32 {
    slots[next.*] = base;
    next.* += 1;
    const shared = if (s.region) |r| r.kind == .choice else false;
    var end = base + 1;
    for (s.children) |c| {
        const child = if (shared) base + 1 else end;
        end = @max(end, assignSlots(c, child, next, slots));
    }
    return end;
}

pub fn Slots(comptime spec: Spec) type {
    const n = flatten.count(spec);
    return struct {
        const table = blk: {
            @setEvalBranchQuota(10_000 + 100 * n);
            var slots: [n]u32 = undefined;
            var next: usize = 0;
            const end = assignSlots(spec, 0, &next, &slots);
            break :blk .{ slots, end };
        };
        pub const by_node = table[0];
        pub const count = table[1];
        /// A valid descriptor even when every alternative using a slot is inactive.
        pub const defaults: [count]u32 = blk: {
            var out: [count]u32 = undefined;
            for (by_node, 0..) |slot, node| out[slot] = node;
            break :blk out;
        };
    };
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

        /// A choice's windows: the first row and row count of each alternative, then an empty
        /// window for a selection past the last.
        fn alternatives(comptime r: Info) *const [r.max + 1][2]u32 {
            return &struct {
                const table: [r.max + 1][2]u32 = blk: {
                    const end = flatten.Flat(spec).end;
                    var out: [r.max + 1][2]u32 = undefined;
                    var at: u32 = r.row + 1;
                    for (out[0..r.max]) |*w| {
                        w.* = .{ at, end[at] - at };
                        at = end[at];
                    }
                    out[r.max] = .{ 0, 0 };
                    break :blk out;
                };
            }.table;
        }

        /// The selection `state` makes: each region's bound field as a number (a count past
        /// u32 saturates).
        pub fn select(comptime State: type, state: *const State) Selection {
            var out: Selection = undefined;
            inline for (regions, &out) |r, *o| {
                const v = @field(state, r.bind);
                o.n = if (r.kind == .choice and @typeInfo(@TypeOf(v)) == .int)
                    std.math.cast(u32, v) orelse std.math.maxInt(u32)
                else
                    number(v);
            }
            return out;
        }

        /// The live mask of `sel`. Rows outside every region are always live; a row inside
        /// regions is live when each of them keeps it.
        pub fn mask(sel: Selection) Mask {
            var m: Mask = @splat(~@as(u32, 0));
            inline for (regions, sel) |r, s| {
                // The rows the region may hide, [first, end), and the live window among them,
                // `len` rows from `lo`.
                const first = switch (r.kind) {
                    .list, .choice => r.row + 1,
                    .when => r.row,
                };
                var lo: u32 = first;
                var len: u32 = undefined;
                switch (r.kind) {
                    .list => len = @min(s.n, r.max) * r.stride,
                    .when => len = @min(s.n, 1) * (r.end - r.row),
                    .choice => {
                        const w = alternatives(r)[@min(s.n, r.max)];
                        lo = w[0];
                        len = w[1];
                    },
                }
                for (first..r.end) |j| m[j] &= 0 -% @as(u32, @intFromBool(@as(u32, @intCast(j)) -% lo < len));
            }
            return m;
        }
    };
}

/// A bound selector field as a number: integers saturate into u32, a bool is 0 or 1.
fn number(v: anytype) u32 {
    return switch (@typeInfo(@TypeOf(v))) {
        .int => std.math.cast(u32, v) orelse if (v < 0) 0 else std.math.maxInt(u32),
        .bool => @intFromBool(v),
        .@"enum" => std.math.cast(u32, @backingInt(v)) orelse std.math.maxInt(u32),
        else => @compileError("a region selects by an integer or bool field, not " ++ @typeName(@TypeOf(v))),
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
        const in_list = if (s.region) |r| switch (r.kind) {
            .list => ci < sel[k].n,
            .choice => ci == sel[k].n,
            .when => true,
        } else true;
        // A `when` child's region is the next one numbered.
        const cond = if (c.region) |r| r.kind != .when or sel[next.*].n != 0 else true;
        if (in_list and cond) pushLive(t, c, i, sel, next) else next.* += regionsIn(c);
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
            try testing.expectEqual(0, ram.visible[i]);
            continue;
        }
        const slot = C.slot(i);
        inline for (0..2) |a| {
            try testing.expectEqual(t.c.size[a][r], ram.size[a][slot]);
            try testing.expectEqual(t.c.pos[a][r], ram.pos[a][slot]);
        }
        inline for (0..4) |k| {
            try testing.expectEqual(t.c.rect[k][r], toF32(ram.rect[k][slot]));
            try testing.expectEqual(t.c.vis[k][r], toF32(ram.vis[k][slot]));
        }
        try testing.expectEqual(t.c.visible[r], ram.visible[i]);
        r += 1;
    }
    try testing.expectEqual(t.len, r);
}

test "list, when, choice: the to-do example lays out its live rows as the runtime tree of them, at every count" {
    const e = examples.dynamic[0];
    const P = ct_layout.Plain(e.spec, e.options);
    const L = ct_layout.Layout(e.spec, e.options);
    const D = P.Regions;
    try testing.expectEqual(3, D.count);
    try testing.expectEqual(37, P.Cols.slot_count);
    try testing.expectEqual(P.Cols.slot(33), P.Cols.slot(34));
    try testing.expectEqual([4][37]f32, @FieldType(P.Cols.Dynamic, "rect"));
    try expectLive(L, e.spec, .{ .{ .n = 3 }, .{}, .{ .n = 200 } }, .{ 320, 240 });
    // Root, heading 3, list 1 + 8 copies of 3 rows, footer 3, choice 1 + 1 + 4: the template is
    // bounded and every row a region could need is reserved.
    try testing.expectEqual(1 + 3 + 1 + 8 * 3 + 3 + 6, P.Cols.node_count);
    try testing.expectEqual(Info{ .kind = .list, .bind = "len", .row = 4, .end = 29, .stride = 3, .max = 8 }, D.regions[0]);
    try testing.expectEqual(Info{ .kind = .when, .bind = "footer", .row = 29, .end = 32, .stride = 0, .max = 0 }, D.regions[1]);
    try testing.expectEqual(Info{ .kind = .choice, .bind = "mode", .row = 32, .end = 38, .stride = 0, .max = 2 }, D.regions[2]);
    // The heading folds beside the dynamic regions; nothing in or above them does.
    try testing.expectEqual(2, L.folded_rows);
    for (0..11) |count| for ([_]bool{ false, true }) |footer| for ([_]examples.Mode{ .brief, .detailed }) |mode| {
        var state: examples.Todo = .{ .len = @intCast(count), .footer = footer, .mode = mode };
        const sel = D.select(examples.Todo, &state);
        try testing.expectEqual(count, sel[0].n);
        try testing.expectEqual(@intFromBool(footer), sel[1].n);
        try testing.expectEqual(@backingInt(mode), sel[2].n);
        inline for (.{ [2]f32{ 800, 600 }, [2]f32{ 120, 90 }, [2]f32{ 1, 1 } }) |vp| {
            try expectLive(P, e.spec, sel, vp);
            try expectLive(L, e.spec, sel, vp);
        }
    };
}

test "Regions.mask: a list keeps its first count copies (max past max); a when its whole subtree or nothing; a choice one alternative" {
    const D = Regions(examples.todo);
    const list = D.regions[0];
    const cond = D.regions[1];
    const alt = D.regions[2];
    // The choice's alternatives: row 33 alone, rows 34..37; a selector past them shows none.
    const live_alt = [_][]const bool{
        &.{ true, false, false, false, false },
        &.{ false, true, true, true, true },
        &.{ false, false, false, false, false },
        &.{ false, false, false, false, false },
    };
    inline for (.{ 0, 1, 5, 8, 9, 1 << 31 }) |k| for ([_]u32{ 0, 1, 7 }) |c| for (0..4) |a| {
        const m = D.mask(.{ .{ .n = k }, .{ .n = c }, .{ .n = @intCast(a) } });
        for (0..list.row + 1) |j| try testing.expectEqual(~@as(u32, 0), m[j]);
        for (list.row + 1..list.end) |j| try testing.expectEqual(j - (list.row + 1) < @min(k, 8) * 3, m[j] != 0);
        for (cond.row..cond.end) |j| try testing.expectEqual(c != 0, m[j] != 0);
        try testing.expect(m[alt.row] != 0);
        for (alt.row + 1..alt.end, live_alt[a]) |j, want| try testing.expectEqual(want, m[j] != 0);
        for (alt.end..m.len) |j| try testing.expectEqual(~@as(u32, 0), m[j]);
    };
}

test "nested choices share geometry, and the following sibling has its own row" {
    const s = spec_zig;
    const item = s.col(.{ .size = .{ .px(6), .px(10) } }, .{});
    const branch = s.choice(.inner, .{}, .{ item, s.row(.{}, .{ item, item }) });
    const ui = s.col(.{}, .{ s.choice(.outer, .{}, .{ branch, item }), item });
    const C = ct_layout.Plain(ui, .{}).Cols;
    try testing.expectEqualSlices(u32, &.{ 0, 1, 2, 3, 3, 4, 5, 2, 6 }, &C.slots.by_node);
    try testing.expectEqual(7, C.slot_count);
    const State = struct { outer: i8, inner: u8 };
    comptime @import("validate.zig").check(State, ui, .{ .viewport = .{ 16, 20 } });
    const L = ct_layout.Layout(ui, .{ .viewport = .{ 16, 20 } });
    for ([_]i8{ -1, 0, 1, 2 }) |outer| for ([_]u8{ 0, 1, 255 }) |inner| {
        const sel = L.Regions.select(State, &.{ .outer = outer, .inner = inner });
        try expectLive(L, ui, sel, .{ 16, 20 });
    };
}
