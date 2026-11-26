//! Runtime selections for a compile-time UI.
//!
//! The spec fixes the hierarchy, styles, list capacities and the descriptions of all choice
//! alternatives. These live in read-only tables indexed by descriptor. State supplies the
//! list length, condition, choice index and virtual scroll offset for a frame:
//!
//!     const sel = L.Regions.select(State, &state);
//!     L.runLive(&scratch, &ram, viewport, sel);
//!
//! Each region restricts a contiguous range of descriptors. Nested restrictions intersect.
//! A hidden row's maximum size, flow and hit senses become zero; the layout pass recomputes
//! the number of live children for spacing. A conditional root also releases its viewport.
//! The reusable, SIMD-padded layout scratch covers every descriptor so the same tier-0
//! passes can follow the original parent indices. Geometry in and above regions can change
//! with the selection; independent static siblings can still fold at compile time.
//!
//! Choice alternatives use overlapping slots in retained geometry, starting at the same slot.
//! The next sibling follows the largest alternative. Input values, visibility and signal dirty
//! bits remain descriptor-indexed. To paint a descriptor `i`, first check `ram.visible[i]`,
//! then read its geometry at `L.Cols.slot(i)`. Several descriptors can name the same slot,
//! but at most one of them is live in a frame.
//!
//! A bounded list reserves its maximum number of template copies. A virtual list reserves
//! the number of fixed-height rows on screen plus one for fractional scrolling. The feed
//! example displays four rows: its enclosing root, list and five item slots total seven
//! descriptors for 100,000 items. The application owns the data; live copy `k` of region
//! `r` shows data item `sel[r].first + k`. Only `sel[r].offset` pixels are scrolled inside
//! the clipped container, so each frame lays out small coordinates even far into the list.

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
    window: @FieldType(spec_zig.Region, "window") = null,
};

/// One region's run-time input: a list's count, a `when`'s condition as 0 or 1, a `choice`'s
/// alternative.
pub const Select = struct {
    n: u32 = 0,
    /// The first logical item and pixel offset within it for a virtual list.
    first: u32 = 0,
    offset: f32 = 0,
};

/// The live copies of a windowed list of `count` items, `visible` on screen, `height` px each,
/// scrolled `scroll` px.
pub fn selectWindow(count: u32, visible: u32, height: f32, scroll: f32) Select {
    // f64 represents every u32 row index exactly, including the end of a very large list.
    const h: f64 = height;
    const max_scroll = @as(f64, @floatFromInt(count -| visible)) * h;
    const px = @min(@max(@as(f64, scroll), 0), max_scroll);
    const first: u32 = @intFromFloat(@floor(px / h));
    const offset: f32 = @floatCast(px - @as(f64, @floatFromInt(first)) * h);
    return .{ .first = first, .offset = offset, .n = @min(count - first, visible + @intFromBool(offset > 0)) };
}

fn collect(comptime s: Spec, comptime next: *comptime_int, comptime out: *[]const Info) void {
    const i = next.*;
    next.* += 1;
    if (s.region) |r| out.* = out.* ++ [_]Info{.{
        .kind = r.kind,
        .bind = r.bind,
        .window = r.window,
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
        pub const has_windows = for (regions) |r| {
            if (r.window != null) break true;
        } else false;
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
                const value = if (r.kind == .choice and @typeInfo(@TypeOf(v)) == .int)
                    std.math.cast(u32, v) orelse std.math.maxInt(u32)
                else
                    number(v);
                o.* = if (r.window) |w|
                    selectWindow(value, r.max - 1, w.height, @field(state, w.scroll))
                else
                    .{ .n = value };
            }
            return out;
        }

        /// The live mask of `sel`. Rows outside every region are always live; a row inside
        /// regions is live when each of them keeps it.
        pub fn mask(sel: Selection) Mask {
            var m: Mask = @splat(~@as(u32, 0));
            inline for (regions, sel) |r, s| maskRegion(&m, r.kind, r.row, r.end, r.stride, r.max, alternatives(r), s);
            return m;
        }
    };
}

/// ANDs region `kind` (its node `row`, one past its last row `end`, a list's copy `stride`, its
/// copies or alternatives `max` and a choice's windows `alts`) under selection `s` into the
/// live mask `m`: the rows it may hide, [first, end), keep only the live window among them,
/// `len` rows from `lo`.
pub inline fn maskRegion(m: anytype, kind: RegionKind, row: u32, end: u32, stride: u32, max: u32, alts: anytype, s: Select) void {
    const first = switch (kind) {
        .list, .choice => row + 1,
        .when => row,
    };
    var lo: u32 = first;
    var len: u32 = undefined;
    switch (kind) {
        .list => len = @min(s.n, max) * stride,
        .when => len = @min(s.n, 1) * (end - row),
        .choice => {
            const w = alts[@min(s.n, max)];
            lo = w[0];
            len = w[1];
        },
    }
    for (first..end) |j| m[j] &= 0 -% @as(u32, @intFromBool(@as(u32, @intCast(j)) -% lo < len));
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
    if (s.region) |region| {
        if (region.window != null) t.c.scroll[1][i] = sel[k].offset;
        next.* += 1;
    }
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

/// The whole tree's per-frame rows of a layout's `scratch`: a folded layout's are in `full`.
fn rowsOf(scratch: anytype) *const Rows(@TypeOf(scratch.*)) {
    return if (comptime @hasField(@TypeOf(scratch.*), "full")) &scratch.full else scratch;
}

fn Rows(comptime S: type) type {
    return if (@hasField(S, "full")) @FieldType(S, "full") else S;
}

fn toF32(x: anytype) f32 {
    return if (@TypeOf(x) == f32) x else @floatFromInt(x);
}

/// `L.runLive` under `sel` against the runtime tree of the live rows: the live rows, in order,
/// get the runtime rows' sizes, positions, rects and visibility; every dead row is 0 px and
/// not visible.
fn expectLive(comptime L: type, comptime s: Spec, sel: L.Regions.Selection, viewport: [2]f32) !void {
    var scratch: L.Scratch = undefined;
    var ram: L.Cols.Dynamic = undefined;
    return expectLiveFrame(L, s, sel, viewport, &scratch, &ram);
}

fn expectLiveFrame(comptime L: type, comptime s: Spec, sel: L.Regions.Selection, viewport: [2]f32, scratch: *L.Scratch, ram: *L.Cols.Dynamic) !void {
    const C = L.Cols;
    var buf: [1 << 17]u8 align(64) = undefined;
    var carver: mem.Carver = .{ .buf = &buf };
    var t = tree.Tree.init(&carver, C.node_count);
    var tx = Texts.init(&carver, 1);
    var next: u32 = 0;
    pushLive(&t, s, 0, &sel, &next);
    layout.run(&t, &tx, viewport);

    L.runLive(scratch, ram, viewport, sel);
    const m = L.Regions.mask(sel);
    const rows = rowsOf(scratch);
    var r: u32 = 0;
    for (0..C.node_count) |i| {
        if (m[i] == 0) {
            inline for (0..2) |a| try testing.expectEqual(0, rows.size[a][i]);
            try testing.expectEqual(0, ram.visible[i]);
            continue;
        }
        const slot = C.slot(i);
        inline for (0..2) |a| {
            try testing.expectEqual(t.c.size[a][r], rows.size[a][i]);
            try testing.expectEqual(t.c.pos[a][r], rows.pos[a][i]);
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
    // The heading contains a measured label. Its geometry, like the selected regions, is runtime data.
    try testing.expectEqual(0, L.folded_rows);
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

test "choice: a bool selector is an if/else, false the first alternative, true the second" {
    const s = @import("spec.zig");
    const ui = comptime s.col(.{}, .{s.choice(.on, .{}, .{ s.label("off"), s.label("on") })});
    const State = struct { on: bool = false };
    comptime std.debug.assert(@import("validate.zig").regionError(State, ui.children[0].region.?) == null);
    const D = Regions(ui);
    const r = D.regions[0];
    for ([_]bool{ false, true }) |on| {
        const m = D.mask(D.select(State, &.{ .on = on }));
        try testing.expectEqual(!on, m[r.row + 1] != 0);
        try testing.expectEqual(on, m[r.row + 2] != 0);
    }
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

test "virtual list maps a bounded window onto a large data set and clips fractional rows" {
    const P = ct_layout.Plain(examples.feed, .{});
    const L = ct_layout.Layout(examples.feed, .{});
    try testing.expectEqual(2 + 4 + 1, L.Cols.node_count);
    const Case = struct { count: u32, scroll: f32, first: u32, n: u32, offset: f32 };
    for ([_]Case{
        .{ .count = 100_000, .scroll = -12, .first = 0, .n = 4, .offset = 0 },
        .{ .count = 100_000, .scroll = 600_004.5, .first = 50_000, .n = 5, .offset = 4.5 },
        .{ .count = 100_000, .scroll = 1_200_000, .first = 99_996, .n = 4, .offset = 0 },
        .{ .count = 2, .scroll = 88, .first = 0, .n = 2, .offset = 0 },
        .{ .count = 0, .scroll = 99, .first = 0, .n = 0, .offset = 0 },
        .{ .count = 0xffffffff, .scroll = std.math.inf(f32), .first = 0xfffffffb, .n = 4, .offset = 0 },
    }) |c| {
        const sel = P.Regions.select(examples.Feed, &.{ .count = c.count, .scroll = c.scroll });
        try testing.expectEqual(Select{ .n = c.n, .first = c.first, .offset = c.offset }, sel[0]);
        const viewport = [2]f32{ 80, 72 };
        try expectLive(P, examples.feed, sel, viewport);
        try expectLive(L, examples.feed, sel, viewport);
        if (c.offset > 0) {
            var scratch: L.Scratch = undefined;
            var ram: L.Cols.Dynamic = undefined;
            L.runLive(&scratch, &ram, viewport, sel);
            try testing.expectEqual(-c.offset, rowsOf(&scratch).pos[1][2]);
            try testing.expectEqual(0, ram.vis[1][2]);
            try testing.expectEqual(48, ram.vis[3][6]);
        }
    }
}

test "reusing frame storage across growth, removal, and choice changes matches rebuilding" {
    inline for (.{ ct_layout.Plain(examples.todo, .{}), ct_layout.Layout(examples.todo, .{}) }) |L| {
        var scratch: L.Scratch = undefined;
        var ram: L.Cols.Dynamic = undefined;
        for ([_]examples.Todo{
            .{ .len = 8, .footer = true, .mode = .detailed },
            .{ .len = 0, .footer = false, .mode = .brief },
            .{ .len = 1, .footer = true, .mode = .detailed },
            .{ .len = 99, .footer = false, .mode = .brief },
            .{ .len = 4, .footer = true, .mode = .detailed },
        }) |state| {
            try expectLiveFrame(L, examples.todo, L.Regions.select(examples.Todo, &state), .{ 240, 180 }, &scratch, &ram);
        }
    }
}

test "a conditional root releases its viewport when hidden, then reuses it" {
    const s = spec_zig;
    const ui = s.when(.show, s.col(.{}, .{s.col(.{ .size = .{ .px(20), .px(12) } }, .{})}));
    const P = ct_layout.Plain(ui, .{});
    var scratch: P.Scratch = undefined;
    var ram: P.Cols.Dynamic = undefined;
    for ([_]bool{ true, false, true }) |show| {
        P.runLive(&scratch, &ram, .{ 80, 60 }, .{.{ .n = @intFromBool(show) }});
        try testing.expectEqual(if (show) @as(f32, 80) else 0, scratch.size[0][0]);
        try testing.expectEqual(if (show) @as(f32, 60) else 0, scratch.size[1][0]);
        for (ram.visible) |v| try testing.expectEqual(show, v != 0);
    }
}

test "measured and updated text in a shared choice matches a static tree of its live branch" {
    const s = spec_zig;
    const Span = @import("../core/strings.zig").Span;
    const Mono = @import("../text/protocol.zig").Mono;
    const fixed = s.col(.{ .size = .{ .px(24), .px(20) } }, .{s.col(.{ .size = .{ .px(8), .px(4) } }, .{})});
    const ui = s.col(.{ .gap = 2 }, .{ fixed, s.choice(.mode, .{}, .{ s.label(.a), s.label(.b) }) });
    const single = s.col(.{ .gap = 2 }, .{ fixed, s.col(.{}, .{s.label(.b)}) });
    const oracle = ct_layout.Plain(single, .{});
    const viewport = [2]f32{ 320, 120 };
    try testing.expect(ct_layout.Layout(ui, .{}).folded_rows != 0);
    inline for (.{ ct_layout.Plain(ui, .{}), ct_layout.Layout(ui, .{}) }) |L| {
        var scratch: L.Scratch = undefined;
        var ram: L.Cols.Dynamic = undefined;
        var ref_scratch: oracle.Scratch = undefined;
        var ref_ram: oracle.Cols.Dynamic = undefined;
        var spans = [2]Span{ .{ .bytes = 16 }, .{ .bytes = 2 } };
        L.runLiveText(&scratch, &ram, viewport, .{.{ .n = 1 }}, &spans, Mono{});
        for ([_]u32{ 2, 7 }) |bytes| {
            spans[1].bytes = bytes;
            L.relayout("b", &scratch, &ram, &spans, Mono{});
            oracle.runText(&ref_scratch, &ref_ram, viewport, &.{spans[1]}, Mono{});
            const slot = L.Cols.slot(5);
            for (0..2) |axis| {
                try testing.expectEqual(ref_scratch.size[axis][4], rowsOf(&scratch).size[axis][5]);
                try testing.expectEqual(ref_scratch.pos[axis][4], rowsOf(&scratch).pos[axis][5]);
            }
            inline for (0..4) |k| try testing.expectEqual(ref_ram.rect[k][4], ram.rect[k][slot]);
            try testing.expectEqual(@as(u8, 0), ram.visible[4]);
            try testing.expectEqual(ref_ram.visible[4], ram.visible[5]);
        }
    }
}
