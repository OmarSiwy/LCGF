//! Layout for a comptime UI: the generic tier-0 layout passes (src/layout/layout.zig) run over the
//! UI's own columns instead of a runtime `Tree`. Tier 1. Ported from prototype/ui.zig
//! (`layout.fit`, `layout.resolve`, ...), which the passes are; only where the columns live is
//! new.
//!
//! The passes take any tree-shaped value. `View` gives them one: `len`, and in `c` one field per
//! column of `Tree.Columns`, each a pointer to an array of `simd.rows(n)` rows (the padding
//! contract), and the border column of `Tree.Extras` in `x`.
//!   - constant columns point at read-only tables, the rows `Tree.push` writes
//!     (`columns.Columns.pushed`); a dropped column at one shared table of its single value;
//!   - columns a frame writes point into `Scratch`, the caller's per-frame memory: the layout
//!     scratch and outputs, padded and in f32 as the passes write them, and `sense`, whose
//!     padding rows `finalize` clears.
//! After the passes, `run` copies the outputs the UI keeps into its `Dynamic` RAM (exact rows,
//! coordinates as `Coordinate`). Scratch is not kept between frames, so it can live on the
//! stack.

const std = @import("std");
const simd = @import("../core/simd.zig");
const tree = @import("../core/tree.zig");
const layout = @import("../layout/layout.zig");
const columns = @import("columns.zig");
const Spec = @import("spec.zig").Spec;
const Options = @import("validate.zig").Options;
const RuntimeColumns = tree.Tree.Columns;

/// A read-only array of `rows` copies of `v`. Generic instantiation memoizes it, so every dropped
/// column with the same type and value shares one table.
fn splat(comptime T: type, comptime rows: usize, comptime v: T) *const [rows]T {
    return &struct {
        const table: [rows]T = @splat(v);
    }.table;
}

/// The column's padded row type: `[R]T` for `[]T`, `[k][R]T` for `[k][]T`.
fn Padded(comptime FT: type, comptime R: usize) type {
    return switch (@typeInfo(FT)) {
        .pointer => |p| [R]p.child,
        .array => |a| [a.len][R]@typeInfo(a.child).pointer.child,
        else => unreachable,
    };
}

/// `View.c`'s field type for a column of `Tree.Columns` type `FT`: a pointer to its padded rows,
/// `const` when the passes only read it.
fn Field(comptime FT: type, comptime R: usize, comptime writable: bool) type {
    return switch (@typeInfo(FT)) {
        .pointer => |p| if (writable) *[R]p.child else *const [R]p.child,
        .array => |a| [a.len](if (writable) *[R]@typeInfo(a.child).pointer.child else *const [R]@typeInfo(a.child).pointer.child),
        else => unreachable,
    };
}

/// Layout of `spec` over its own columns, every row through every pass (see the file comment).
/// `Layout` adds folding on top.
pub fn Plain(comptime spec: Spec, comptime options: Options) type {
    const C = columns.Columns(spec, options);
    const n = C.node_count;
    const R = simd.rows(n);
    const info = @typeInfo(RuntimeColumns).@"struct";
    for (C.class) |c| if (c != .dynamic) break else @compileError("every column is dynamic (a custom widget builds its rows at run time): lay it out with the runtime tree");
    // Columns a frame writes: the dynamic ones, and `sense` (finalize clears its padding rows).
    const writes = blk: {
        var w: [info.field_names.len]bool = undefined;
        for (info.field_names, C.class, &w) |name, c, *x| x.* = c == .dynamic or std.mem.eql(u8, name, "sense");
        break :blk w;
    };
    return struct {
        pub const Cols = C;

        /// The caller's per-frame memory for `run`: one padded f32 array per written column.
        pub const Scratch = blk: {
            @setEvalBranchQuota(20_000);
            var names: []const []const u8 = &.{};
            var types: []const type = &.{};
            for (info.field_names, info.field_types, writes) |name, FT, w| if (w) {
                names = names ++ [_][]const u8{name};
                types = types ++ [_]type{Padded(FT, R)};
            };
            const nm = names[0..names.len].*;
            const ty = types[0..types.len].*;
            break :blk @Struct(.auto, null, &nm, &ty, &@splat(.{}));
        };

        const ViewColumns = blk: {
            @setEvalBranchQuota(20_000);
            var types: [info.field_names.len]type = undefined;
            for (info.field_types, writes, &types) |FT, w, *T| T.* = Field(FT, R, w);
            break :blk @Struct(.auto, null, info.field_names, &types, &@splat(.{}));
        };
        const ViewExtras = struct { border: *const [simd.rows(n + 1)]f32 };

        /// What the layout passes take as their tree.
        pub const View = struct { len: u32, c: ViewColumns, x: ViewExtras };

        /// The view over `scratch` for this UI: every column the passes read, constant ones from
        /// read-only tables.
        pub fn view(scratch: *Scratch) View {
            @setEvalBranchQuota(100_000);
            var v: View = .{ .len = n, .c = undefined, .x = .{ .border = &C.pushed.x.border } };
            inline for (info.field_names, writes) |name, w| {
                if (w) {
                    const dst = &@field(scratch, name);
                    if (comptime @typeInfo(@FieldType(RuntimeColumns, name)) == .array) {
                        inline for (0..dst.len) |k| @field(v.c, name)[k] = &dst[k];
                    } else @field(v.c, name) = dst;
                } else {
                    const src = comptime table(name);
                    @field(v.c, name) = src;
                }
            }
            return v;
        }

        /// The read-only rows of a constant column, as the view's field holds them.
        fn table(comptime name: []const u8) @FieldType(ViewColumns, name) {
            @setEvalBranchQuota(100_000);
            const FT = @FieldType(RuntimeColumns, name);
            if (C.isDropped(name)) {
                const u = C.uniform(name);
                return switch (@typeInfo(FT)) {
                    .pointer => |p| splat(p.child, R, u),
                    .array => |a| blk: {
                        var out: [a.len]*const [R]@typeInfo(a.child).pointer.child = undefined;
                        for (&out, u) |*o, x| o.* = splat(@TypeOf(x), R, x);
                        break :blk out;
                    },
                    else => unreachable,
                };
            }
            const col = &@field(C.pushed.c, name);
            return switch (@typeInfo(FT)) {
                .pointer => col,
                .array => |a| blk: {
                    var out: [a.len]*const [R]@typeInfo(a.child).pointer.child = undefined;
                    for (&out, 0..) |*o, k| o.* = &col[k];
                    break :blk out;
                },
                else => unreachable,
            };
        }

        /// Lays the UI out in a `viewport`-sized area: `layout.run`'s pass sequence without text
        /// (labels measure zero until text measurement reaches the comptime front end), then the
        /// kept outputs into `ram`.
        pub fn run(scratch: *Scratch, ram: *C.Dynamic, viewport: [2]f32) void {
            passes(scratch, viewport);
            var v = view(scratch);
            layout.finalize(&v);
            keep(scratch, ram);
        }

        /// Every pass but `finalize`, which leaves sizes and positions in `scratch`.
        pub fn passes(scratch: *Scratch, viewport: [2]f32) void {
            // `sense` is constant; finalize clears its padding rows, so it is copied each frame.
            scratch.sense = C.pushed.c.sense;
            var v = view(scratch);
            layout.prepare(&v);
            layout.fit(&v, .x);
            layout.resolve(&v, .x, viewport[0]);
            layout.fit(&v, .y);
            layout.resolve(&v, .y, viewport[1]);
            layout.place(&v);
        }

        /// Copies every output `Dynamic` holds from `scratch`, coordinates rounded and clamped
        /// into `Coordinate` (they are already whole pixels: finalize snaps them).
        pub fn keep(scratch: *const Scratch, ram: *C.Dynamic) void {
            @setEvalBranchQuota(100_000);
            inline for (@typeInfo(C.Dynamic).@"struct".field_names) |name| {
                if (comptime std.mem.eql(u8, name, "value")) continue; // state writes it, not layout
                const src = &@field(scratch, name);
                const dst = &@field(ram.*, name);
                if (comptime @typeInfo(@FieldType(RuntimeColumns, name)) == .array) {
                    inline for (0..dst.len) |k| convert(&dst[k], src[k][0..n]);
                } else convert(dst, src[0..n]);
            }
        }

        fn convert(dst: anytype, src: anytype) void {
            const T = @typeInfo(@TypeOf(dst.*)).array.child;
            if (comptime T == C.Coordinate and @typeInfo(T) == .int) {
                const lo: f32 = std.math.minInt(T);
                const hi: f32 = std.math.maxInt(T);
                for (dst, src) |*d, s| d.* = @intFromFloat(@min(@max(s, lo), hi));
            } else dst.* = src.*;
        }
    };
}

/// Which rows of a UI fold: `root[j]` is true for a row whose subtree is laid out while
/// compiling. A row's size is independent of the viewport when its parent's is, or when its
/// own sizing never reads the parent's box: no `grow`, no `pct`, and no `shrink` while in flow
/// (the terms `resolve` multiplies by the parent's inner size or free space). The root always
/// takes the viewport. Positions inside such a subtree, relative to its root, are fixed too. A
/// fold root is a maximal such row with at least one descendant: folding a leaf saves nothing.
fn FoldPlan(comptime C: type) type {
    const n = C.node_count;
    const c = C.pushed.c;
    return struct {
        const indep: [n]bool = blk: {
            @setEvalBranchQuota(10_000 + 100 * n);
            var out: [n]bool = undefined;
            out[0] = false;
            for (1..n) |i| {
                const own = c.grow[0][i] == 0 and c.grow[1][i] == 0 and c.pct[0][i] == 0 and c.pct[1][i] == 0 and
                    (c.shrink[i] == 0 or c.flow[i] == 0);
                out[i] = out[c.parent[i]] or own;
            }
            break :blk out;
        };
        const root: [n]bool = blk: {
            @setEvalBranchQuota(10_000 + 100 * n);
            var out: [n]bool = undefined;
            for (0..n) |i| out[i] = indep[i] and !indep[c.parent[i]] and c.end[i] - i > 1;
            break :blk out;
        };
        /// Rows inside a fold root's subtree, the root not counted: they leave the skeleton.
        const inside: [n]bool = blk: {
            @setEvalBranchQuota(10_000 + 100 * n);
            var out: [n]bool = @splat(false);
            for (0..n) |i| if (root[i]) for (i + 1..c.end[i]) |j| {
                out[j] = true;
            };
            break :blk out;
        };
        const folded_rows = std.mem.count(bool, &inside, &.{true});
    };
}

/// `s` with every fold root (`plan.root`) replaced by a leaf of its laid-out size: the skeleton
/// the passes run over.
fn skeleton(comptime s: Spec, comptime plan: type, comptime size: anytype, comptime next: *usize) Spec {
    const i = next.*;
    next.* += 1;
    if (plan.root[i]) {
        next.* = i + @import("flatten.zig").count(s);
        var leaf = s;
        leaf.children = &.{};
        leaf.style.size = .{ .px(size[0][i]), .px(size[1][i]) };
        leaf.style.min = .{ 0, 0 };
        leaf.style.max = .{ std.math.inf(f32), std.math.inf(f32) };
        return leaf;
    }
    var kids: [s.children.len]Spec = undefined;
    for (&kids, s.children) |*k, c| k.* = skeleton(c, plan, size, next);
    var out = s;
    const final = kids;
    out.children = &final;
    return out;
}

/// Layout of `spec`: as `Plain`, except that subtrees whose layout does not depend on the
/// viewport (`FoldPlan`) are laid out while compiling. The passes run over a skeleton in which
/// each such subtree is one leaf of its fixed size; then every folded row's position is its
/// fold root's plus a constant offset, and its size a constant (one select per row, no branch),
/// and `finalize` runs over the whole tree for rects, clips and visibility.
pub fn Layout(comptime spec: Spec, comptime options: Options) type {
    const P = Plain(spec, options);
    const C = P.Cols;
    const n = C.node_count;
    const plan = FoldPlan(C);
    if (plan.folded_rows == 0) return struct {
        pub const Cols = C;
        pub const Scratch = P.Scratch;
        pub const folded_rows = 0;
        pub const run = P.run;
    };
    const R = simd.rows(n);
    return struct {
        pub const Cols = C;
        /// Rows laid out while compiling.
        pub const folded_rows = plan.folded_rows;

        /// Sizes and positions of the whole tree in any viewport, from the passes run by the
        /// compiler: only the folded rows' are used, and those do not depend on the viewport.
        const Reference = struct { size: [2][R]f32, pos: [2][R]f32 };
        const reference: Reference = blk: {
            @setEvalBranchQuota(2_000_000 + 100_000 * n);
            var scratch: P.Scratch = undefined;
            P.passes(&scratch, .{ 1000, 1000 });
            break :blk .{ .size = scratch.size, .pos = scratch.pos };
        };

        const skel_spec = blk: {
            @setEvalBranchQuota(10_000 + 1_000 * n);
            var next: usize = 0;
            break :blk skeleton(spec, plan, reference.size, &next);
        };
        const S = Plain(skel_spec, options);

        /// For each row: the skeleton row its position starts from (itself, or its fold root),
        /// the constant offset from there, and, for folded rows, its constant size and 0 in
        /// `keep_size` (1 for skeleton rows, whose size comes from the passes).
        const Expand = struct { base: [R]u32, rel: [2][R]f32, size: [2][R]f32, keep_size: [R]f32 };
        const expand: Expand = blk: {
            @setEvalBranchQuota(10_000 + 200 * n);
            var base: [R]u32 = @splat(0);
            var rel: [2][R]f32 = @splat(@splat(0));
            var size: [2][R]f32 = @splat(@splat(0));
            var keep_size: [R]f32 = @splat(1);
            var k: u32 = 0;
            var root_k: u32 = 0;
            var root_row: usize = 0;
            for (0..n) |j| {
                if (plan.inside[j]) {
                    base[j] = root_k;
                    keep_size[j] = 0;
                    for (0..2) |a| {
                        rel[a][j] = reference.pos[a][j] - reference.pos[a][root_row];
                        size[a][j] = reference.size[a][j];
                    }
                } else {
                    base[j] = k;
                    if (plan.root[j]) {
                        root_k = k;
                        root_row = j;
                    }
                    k += 1;
                }
            }
            std.debug.assert(k == S.Cols.node_count);
            break :blk .{ .base = base, .rel = rel, .size = size, .keep_size = keep_size };
        };

        /// Per-frame memory: the skeleton's and the whole tree's.
        pub const Scratch = struct { skel: S.Scratch, full: P.Scratch };

        pub fn run(scratch: *Scratch, ram: *C.Dynamic, viewport: [2]f32) void {
            S.passes(&scratch.skel, viewport);
            const sk = &scratch.skel;
            const full = &scratch.full;
            for (0..n) |j| {
                const b = expand.base[j];
                inline for (0..2) |a| {
                    full.pos[a][j] = sk.pos[a][b] + expand.rel[a][j];
                    full.size[a][j] = sk.size[a][b] * expand.keep_size[j] + expand.size[a][j];
                }
            }
            full.sense = C.pushed.c.sense;
            var v = P.view(full);
            layout.finalize(&v);
            P.keep(full, ram);
        }
    };
}

// ---- tests -------------------------------------------------------------------------------------

const testing = std.testing;
const examples = @import("examples.zig");
const mem = @import("../core/mem.zig");
const Texts = @import("../core/texts.zig").Texts;
const Id = @import("../core/types.zig").Id;

fn pushAll(t: anytype, comptime s: Spec, parent: u32) void {
    const id: Id = if (s.id) |name| .hash(name) else .none;
    const i = t.push(parent, id, &s.style);
    inline for (s.children) |c| pushAll(t, c, i);
    t.seal(i);
}

fn toF32(x: anytype) f32 {
    return if (@TypeOf(x) == f32) x else @floatFromInt(x);
}

/// Lays `e` out with the runtime tree and with `Layout`, and requires the same outputs.
fn expectSameLayout(comptime e: examples.Example, viewport: [2]f32) !void {
    const L = Layout(e.spec, e.options);
    const C = L.Cols;
    var buf: [1 << 17]u8 align(64) = undefined;
    var carver: mem.Carver = .{ .buf = &buf };
    var t = tree.Tree.init(&carver, C.node_count);
    var tx = Texts.init(&carver, 1);
    pushAll(&t, e.spec, 0);
    layout.run(&t, &tx, viewport);

    var scratch: L.Scratch = undefined;
    var ram: C.Dynamic = undefined;
    L.run(&scratch, &ram, viewport);
    for (0..C.node_count) |i| {
        inline for (0..2) |a| {
            try testing.expectEqual(t.c.size[a][i], ram.size[a][i]);
            try testing.expectEqual(t.c.pos[a][i], ram.pos[a][i]);
        }
        inline for (0..4) |k| {
            try testing.expectEqual(t.c.rect[k][i], toF32(ram.rect[k][i]));
            try testing.expectEqual(t.c.vis[k][i], toF32(ram.vis[k][i]));
        }
        try testing.expectEqual(t.c.visible[i], ram.visible[i]);
    }
}

/// The declared viewport when there is one; a larger and a smaller window otherwise.
fn expectBoth(comptime e: examples.Example) !void {
    if (e.options.viewport) |vp| return expectSameLayout(e, vp);
    try expectSameLayout(e, .{ 800, 600 });
    try expectSameLayout(e, .{ 40, 30 });
}

test "Layout: subtrees that do not depend on the viewport are laid out while compiling" {
    // The mixer's root takes the viewport; its label and its two fit-sized rows do not, so the
    // rows' children (4 of 8 nodes) fold.
    try testing.expectEqual(4, Layout(examples.mixer, .{}).folded_rows);
    // The settings rows fill the width, so nothing below them is fixed but their leaves.
    try testing.expectEqual(0, Layout(examples.settings, .{ .viewport = .{ 320, 240 } }).folded_rows);
    // Folded results equal the runtime layout in any viewport, however small.
    inline for (.{ [2]f32{ 1, 1 }, [2]f32{ 5000, 20 }, [2]f32{ 123.5, 77.25 } }) |vp|
        try expectSameLayout(examples.all[0], vp);
}

test "Layout.run: equals the runtime layout of the same UI" {
    // Every example but the custom widget's, whose rows are built at run time.
    inline for (examples.all) |e| if (comptime !std.mem.eql(u8, e.name, "custom")) try expectBoth(e);
}
