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
//!
//! Table-driven, not unrolled, at every node count (C0165, `zig build ct-layout-size`,
//! ReleaseFast x86-64). Each UI already instantiates the passes for its own view type, so the
//! optimizer knows the row count; making it a compile-time constant of the view (`PlainOf`'s
//! `unroll`) changed no function's size by more than 16 bytes, and the loops stay rolled. A
//! fully unrolled `place` (one copy of the body per row, parents as constants) ran 2.4 to 4.3x
//! faster (3 nodes: 19 against 81 ns; 129 nodes: 679 against 1,630 ns) but grew by about 215
//! bytes per row (28 KB at 129 rows, against 617 bytes rolled), and every sweep would need the
//! same: a second copy of each tier-0 pass to keep equal. Code size is the comptime front
//! end's budget on microcontrollers, so the rolled passes stay; unrolling below a node count is
//! for the budget lane (ct-budget) to take up with a flash limit to weigh it against.

const std = @import("std");
const simd = @import("../core/simd.zig");
const tree = @import("../core/tree.zig");
const layout = @import("../layout/layout.zig");
const columns = @import("columns.zig");
const Spec = @import("spec.zig").Spec;
const Options = @import("validate.zig").Options;
const RuntimeColumns = tree.Tree.Columns;
const Texts = @import("../core/texts.zig").Texts;
const Span = @import("../core/strings.zig").Span;
const TextStyle = @import("../core/types.zig").TextStyle;
const Mono = @import("../text/protocol.zig").Mono;

/// Rows of the labels of `s`, depth-first: label k of the UI is node `labelRows(s)[k]`.
pub fn labelRows(comptime s: Spec) []const u32 {
    comptime {
        @setEvalBranchQuota(10_000 + 100 * @import("flatten.zig").count(s));
        var out: []const u32 = &.{};
        var next: u32 = 0;
        labelWalk(s, &next, &out);
        return out;
    }
}

/// The field label row `row` of `s` shows.
fn labelBind(comptime s: Spec, comptime row: u32) []const u8 {
    var next: u32 = 0;
    return bindWalk(s, row, &next).?;
}

fn bindWalk(comptime s: Spec, comptime row: u32, comptime next: *u32) ?[]const u8 {
    if (next.* == row) return s.bind;
    next.* += 1;
    for (s.children) |c| if (bindWalk(c, row, next)) |b| return b;
    return null;
}

fn labelWalk(comptime s: Spec, comptime next: *u32, comptime out: *[]const u32) void {
    if (s.kind == .label) out.* = out.* ++ [_]u32{next.*};
    next.* += 1;
    for (s.children) |c| labelWalk(c, next, out);
}

/// Layout scratch columns whose every row the spec fixes, so the comptime front end keeps them
/// as read-only tables instead of having `prepare` derive them each frame: `gap_total`, the gap
/// times the in-flow child count less one. (`nkids`, the child count, is a constant column
/// already.) `grow_sum` and its reciprocal `grow_inv` are constant too, but `fit` accumulates
/// and writes them in the same loop as the sizes, and the tier-0 pass has no form that reads
/// them instead.
fn isPrecomputed(comptime name: []const u8) bool {
    return std.mem.eql(u8, name, "gap_total");
}

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
    return PlainOf(spec, options, false);
}

/// `Plain`, with the row count a compile-time constant of the view when `unroll`: every pass
/// loop then has a constant trip count the optimizer may unroll (C0165 measures it).
pub fn PlainOf(comptime spec: Spec, comptime options: Options, comptime unroll: bool) type {
    const C = columns.Columns(spec, options);
    const n = C.node_count;
    const R = simd.rows(n);
    const info = @typeInfo(RuntimeColumns).@"struct";
    for (C.class) |c| if (c != .dynamic) break else @compileError("every column is dynamic (a custom widget builds its rows at run time): lay it out with the runtime tree");
    // Columns a frame writes: the dynamic ones but those precomputed below, and `sense`
    // (finalize clears its padding rows).
    const writes = blk: {
        var w: [info.field_names.len]bool = undefined;
        for (info.field_names, C.class, &w) |name, c, *x|
            x.* = (c == .dynamic and !isPrecomputed(name)) or std.mem.eql(u8, name, "sense");
        break :blk w;
    };
    const labels = labelRows(spec);
    const RT = simd.rows(@max(labels.len, 1));
    const tx_info = @typeInfo(Texts.Columns).@"struct";
    return struct {
        pub const Cols = C;
        /// Label k is node `label_rows[k]`; its text is span k of `run`'s `spans`.
        pub const label_rows = labels;
        pub const label_count = labels.len;

        /// The caller's per-frame memory for `run`: one padded array per written column, in
        /// f32 as the passes write them, and the label text runs (`tx_` + a `Texts` column).
        pub const Scratch = blk: {
            @setEvalBranchQuota(20_000);
            var names: []const []const u8 = &.{};
            var types: []const type = &.{};
            for (info.field_names, info.field_types, writes) |name, FT, w| if (w) {
                names = names ++ [_][]const u8{name};
                types = types ++ [_]type{Padded(FT, R)};
            };
            for (tx_info.field_names, tx_info.field_types) |name, FT| {
                names = names ++ [_][]const u8{"tx_" ++ name};
                types = types ++ [_]type{[RT]@typeInfo(FT).pointer.child};
            }
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
        const ViewExtras = struct { row: *const [simd.rows(n + 1)]tree.Extra };

        /// What the layout passes take as their tree.
        pub const View = if (unroll)
            struct { comptime len: u32 = n, c: ViewColumns, x: ViewExtras }
        else
            struct { len: u32, c: ViewColumns, x: ViewExtras };

        /// The view over `scratch` for this UI: every column the passes read, constant ones from
        /// read-only tables.
        pub fn view(scratch: *Scratch) View {
            @setEvalBranchQuota(100_000);
            var v: View = .{ .len = n, .c = undefined, .x = .{ .row = &C.pushed.x.row } };
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
            if (comptime isPrecomputed(name)) return &gap_total;
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

        /// `prepare`'s gap totals, computed while compiling with its formula.
        pub const gap_total: [R]f32 = blk: {
            @setEvalBranchQuota(10_000 + 100 * n);
            var out: [R]f32 = @splat(0);
            for (0..n) |i| out[i] = C.pushed.c.gap[i] * @max(C.pushed.c.nkids[i] - 1, 0);
            break :blk out;
        };

        /// `prepare` without what is precomputed: clears the accumulators `fit`, `resolve` and
        /// `place` add into.
        fn clear(scratch: *Scratch) void {
            inline for (0..2) |a| {
                scratch.fit[a] = @splat(0);
                scratch.grow_sum[a] = @splat(0);
                scratch.used[a] = @splat(0);
            }
            scratch.cursor = @splat(0);
        }

        /// Which optional passes this UI runs, decided while compiling. `text`: measure and
        /// applyText, for a UI with labels. `wrap`: textAvail and the font's wrap, for a UI with
        /// a run that may wrap; labels use the default `TextStyle`, which does not, so no
        /// comptime UI wraps yet. Grow, percentages and shrink have no pass of their own: `fit`
        /// and `resolve` carry their terms in the loops every UI needs, so there is no grow pass
        /// to skip (C0161 folds the subtrees without them instead).
        pub const needs = struct {
            pub const text = label_count > 0;
            pub const wrap = text and (TextStyle{}).wrap;
        };

        /// The label text runs over `scratch`, as the text protocol (src/text/protocol.zig)
        /// reads and writes them: run k is label k, with the default `TextStyle` and the bytes of
        /// `spans[k]`, as `Frame.text` would push it.
        pub fn texts(scratch: *Scratch, spans: *const [label_count]Span) Texts {
            var tx: Texts = .{ .len = label_count, .cap = @max(label_count, 1), .c = undefined };
            inline for (tx_info.field_names) |name| @field(tx.c, name) = &@field(scratch, "tx_" ++ name);
            const ts: TextStyle = .{};
            for (0..label_count) |k| {
                tx.c.node[k] = label_rows[k];
                tx.c.start[k] = spans[k].start;
                tx.c.bytes[k] = spans[k].bytes;
                tx.c.px[k] = ts.px;
                tx.c.color[k] = ts.color.bitsOf();
                tx.c.font[k] = @backingInt(ts.font);
                tx.c.wrap[k] = @floatFromInt(@intFromBool(ts.wrap));
                tx.c.w[k] = 0;
                tx.c.h[k] = 0;
                tx.c.avail[k] = 0;
            }
            return tx;
        }

        /// Lays the UI out in a `viewport`-sized area, `Frame.end`'s sequence: `font` measures
        /// the labels' text (`spans[k]` is label k's bytes in the caller's strings), the passes
        /// run with the text extents, `font` wraps, then finalize, and the kept outputs go to
        /// `ram`. `font` is anything with the text protocol's `measure` and `wrap` (`Mono`).
        pub fn run(scratch: *Scratch, ram: *C.Dynamic, viewport: [2]f32, spans: *const [label_count]Span, font: anytype) void {
            passes(scratch, viewport, spans, font);
            var v = view(scratch);
            layout.finalize(&v);
            keep(scratch, ram);
        }

        /// The relayout boundary of each label: its nearest ancestor (or itself) whose size is
        /// fixed on both axes (`min == max`, a px size), else the root. A fixed-size node's size
        /// does not depend on its content, so a change of text below it moves nothing outside its
        /// subtree.
        const boundary_of_label: [label_count]u32 = blk: {
            @setEvalBranchQuota(10_000 + 100 * n * (label_count + 1));
            const c = C.pushed.c;
            var out: [label_count]u32 = undefined;
            for (label_rows, &out) |l, *b| {
                var i: u32 = l;
                while (i != 0 and !(c.min[0][i] == c.max[0][i] and c.min[1][i] == c.max[1][i])) i = c.parent[i];
                b.* = i;
            }
            break :blk out;
        };

        /// The rows to lay out again when the state field `field` changes: the subtree of the
        /// common boundary of every label bound to it. Null when no label shows it (a checkbox's
        /// or slider's value moves no box): nothing to do. Ancestor of several boundaries: the
        /// lowest row whose subtree holds them all.
        pub fn dirtySpan(comptime field: []const u8) ?[2]u32 {
            return comptime blk: {
                @setEvalBranchQuota(10_000 + 100 * n * (label_count + 1));
                const c = C.pushed.c;
                var root: ?u32 = null;
                for (label_rows, boundary_of_label) |l, b| {
                    if (!std.mem.eql(u8, labelBind(spec, l), field)) continue;
                    var r = root orelse b;
                    // Climb until the subtree of r holds b.
                    while (!(r <= b and b < c.end[r])) r = c.parent[r];
                    root = r;
                }
                break :blk if (root) |r| .{ r, c.end[r] } else null;
            };
        }

        /// Lays out again only what the state field `field` moves, after a frame of `run` with
        /// the same `scratch` (it keeps last frame's layout): the partial routine for that
        /// field's dirty mask, decided while compiling (`dirtySpan`). Within the span, the same
        /// passes as `run` in their subtree forms (`fitSpan`, `resolveSpan`, `placeSpan`,
        /// `finalizeSpan`); every label is measured again (one SIMD sweep), and only its own
        /// leaf row takes the extent. `ram` gets every kept output again.
        pub fn relayout(comptime field: []const u8, scratch: *Scratch, ram: *C.Dynamic, spans: *const [label_count]Span, font: anytype) void {
            const span = comptime dirtySpan(field);
            if (span == null) return;
            const first = span.?[0];
            const last = span.?[1];
            // The whole tree: the routine for a field shown above every fixed-size box.
            if (first == 0) {
                const vp: [2]f32 = .{ scratch.size[0][0], scratch.size[1][0] };
                return run(scratch, ram, vp, spans, font);
            }
            var v = view(scratch);
            var tx = texts(scratch, spans);
            if (needs.text) font.measure(&tx);
            inline for (0..2) |a| {
                @memset(scratch.fit[a][first..last], 0);
                @memset(scratch.grow_sum[a][first..last], 0);
                @memset(scratch.used[a][first..last], 0);
            }
            @memset(scratch.cursor[first..last], 0);
            if (needs.text) layout.applyText(&v, &tx, .x);
            layout.fitSpan(&v, .x, first, last);
            layout.resolveSpan(&v, .x, first, last);
            if (needs.wrap) layout.textAvail(&v, &tx);
            if (needs.wrap) font.wrap(&tx);
            if (needs.text) layout.applyText(&v, &tx, .y);
            layout.fitSpan(&v, .y, first, last);
            layout.resolveSpan(&v, .y, first, last);
            layout.placeSpan(&v, first, last);
            layout.finalizeSpan(&v, first, last);
            keep(scratch, ram);
        }

        /// Every pass but `finalize`, which leaves sizes and positions in `scratch`.
        pub fn passes(scratch: *Scratch, viewport: [2]f32, spans: *const [label_count]Span, font: anytype) void {
            // `sense` is constant; finalize clears its padding rows, so it is copied each frame.
            scratch.sense = C.pushed.c.sense;
            var v = view(scratch);
            var tx = texts(scratch, spans);
            // Passes the UI cannot need are not compiled in (`needs`).
            if (needs.text) font.measure(&tx);
            clear(scratch);
            if (needs.text) layout.applyText(&v, &tx, .x);
            layout.fit(&v, .x);
            layout.resolve(&v, .x, viewport[0]);
            if (needs.wrap) layout.textAvail(&v, &tx);
            if (needs.wrap) font.wrap(&tx);
            if (needs.text) layout.applyText(&v, &tx, .y);
            layout.fit(&v, .y);
            layout.resolve(&v, .y, viewport[1]);
            layout.place(&v);
        }

        /// Copies every output `Dynamic` holds from `scratch`, coordinates rounded and clamped
        /// into `Coordinate` (they are already whole pixels: finalize snaps them).
        pub fn keep(scratch: *const Scratch, ram: *C.Dynamic) void {
            @setEvalBranchQuota(100_000);
            inline for (@typeInfo(C.Dynamic).@"struct".field_names) |name| {
                // `value` is state's, not layout's; precomputed columns are not in `scratch`.
                if (comptime !std.mem.eql(u8, name, "value") and @hasField(Scratch, name)) {
                    const src = &@field(scratch, name);
                    const dst = &@field(ram.*, name);
                    if (comptime @typeInfo(@FieldType(RuntimeColumns, name)) == .array) {
                        inline for (0..dst.len) |k| convert(&dst[k], src[k][0..n]);
                    } else convert(dst, src[0..n]);
                }
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
fn FoldPlan(comptime C: type, comptime labels: []const u32) type {
    const n = C.node_count;
    const c = C.pushed.c;
    return struct {
        /// A label's size is its text's, which comes from state at run time: no row with a
        /// label in its subtree folds.
        const has_label: [n]bool = blk: {
            @setEvalBranchQuota(10_000 + 100 * n);
            var out: [n]bool = @splat(false);
            for (labels) |l| out[l] = true;
            var i = n;
            while (i > 1) {
                i -= 1;
                if (out[i]) out[c.parent[i]] = true;
            }
            break :blk out;
        };
        const indep: [n]bool = blk: {
            @setEvalBranchQuota(10_000 + 100 * n);
            var out: [n]bool = undefined;
            out[0] = false;
            for (1..n) |i| {
                const own = c.grow[0][i] == 0 and c.grow[1][i] == 0 and c.pct[0][i] < 0 and c.pct[1][i] < 0 and
                    (c.shrink[i] == 0 or c.flow[i] == 0);
                out[i] = !has_label[i] and (out[c.parent[i]] or own);
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
    const plan = FoldPlan(C, P.label_rows);
    if (plan.folded_rows == 0) return struct {
        pub const Cols = C;
        pub const Scratch = P.Scratch;
        pub const label_count = P.label_count;
        pub const folded_rows = 0;
        pub const run = P.run;
        pub const relayout = P.relayout;
        pub const dirtySpan = P.dirtySpan;
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
            // No folded row is a label or holds one, so the label text does not matter here.
            const none: [P.label_count]Span = @splat(.{ .start = 0, .bytes = 0 });
            P.passes(&scratch, .{ 1000, 1000 }, &none, Mono{});
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

        /// Labels never fold, so the skeleton has the same labels, in the same order.
        pub const label_count = P.label_count;

        /// A folded UI lays out again in full when a label's text changes (the partial routines
        /// are `Plain`'s; the skeleton's rows are not the UI's).
        pub fn relayout(comptime field: []const u8, scratch: *Scratch, ram: *C.Dynamic, spans: *const [label_count]Span, font: anytype) void {
            if (comptime P.dirtySpan(field) == null) return;
            run(scratch, ram, .{ scratch.full.size[0][0], scratch.full.size[1][0] }, spans, font);
        }

        pub fn run(scratch: *Scratch, ram: *C.Dynamic, viewport: [2]f32, spans: *const [label_count]Span, font: anytype) void {
            comptime std.debug.assert(S.label_count == label_count);
            S.passes(&scratch.skel, viewport, spans, font);
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
const Id = @import("../core/types.zig").Id;

fn pushAll(t: anytype, comptime s: Spec, parent: u32) void {
    const id: Id = if (s.id) |name| .hash(name) else .none;
    const i = t.push(parent, id, &s.style);
    inline for (s.children) |c| pushAll(t, c, i);
    t.seal(i);
}

/// Text of label k in the tests: lengths 0 to 30 bytes, different for neighbouring labels.
const sample = "the quick brown fox jumps over the lazy dog";
fn labelBytes(k: usize) u32 {
    return @intCast((k * 7 + 3) % 31);
}

/// Spans of every label of a UI with `count` labels, all starting at 0 in `sample`.
fn labelSpans(comptime count: usize) [count]Span {
    var out: [count]Span = undefined;
    for (&out, 0..) |*sp, k| sp.* = .{ .start = 0, .bytes = labelBytes(k) };
    return out;
}

/// Pushes `s` like `pushAll`, and a text run for every label (`Frame.text`'s run).
fn pushWithText(t: anytype, tx: *Texts, comptime s: Spec, parent: u32, next_label: *usize) void {
    const id: Id = if (s.id) |name| .hash(name) else .none;
    const i = t.push(parent, id, &s.style);
    if (s.kind == .label) {
        t.c.text[i] = tx.push(i, .{ .start = 0, .bytes = labelBytes(next_label.*) }, &.{});
        next_label.* += 1;
    }
    inline for (s.children) |c| pushWithText(t, tx, c, i, next_label);
    t.seal(i);
}

const test_font: Mono = .{ .advance = 0.5, .line = 1.2 };

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
    var tx = Texts.init(&carver, @max(L.label_count, 1));
    var next_label: usize = 0;
    pushWithText(&t, &tx, e.spec, 0, &next_label);
    test_font.measure(&tx);
    layout.run(&t, &tx, viewport);

    var scratch: L.Scratch = undefined;
    var ram: C.Dynamic = undefined;
    const spans = labelSpans(L.label_count);
    L.run(&scratch, &ram, viewport, &spans, test_font);
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
    // The mixer's root takes the viewport; its rows are fit-sized, but a label's size is its
    // text, which is state: only the row without a label folds (its checkbox and slider).
    try testing.expectEqual(2, Layout(examples.mixer, .{}).folded_rows);
    // The settings rows fill the width, so nothing below them is fixed but their leaves.
    try testing.expectEqual(0, Layout(examples.settings, .{ .viewport = .{ 320, 240 } }).folded_rows);
    // Folded results equal the runtime layout in any viewport, however small.
    inline for (.{ [2]f32{ 1, 1 }, [2]f32{ 5000, 20 }, [2]f32{ 123.5, 77.25 } }) |vp|
        try expectSameLayout(examples.all[0], vp);
}

test "Plain.needs: text passes only for a UI with labels, wrap for none yet" {
    try testing.expect(Plain(examples.mixer, .{}).needs.text);
    try testing.expect(!Plain(examples.mixer, .{}).needs.wrap);
    const s = spec_zig;
    const bars = comptime s.row(.{}, .{ s.col(.{ .size = .{ .px(10), .px(10) } }, .{}), s.col(.{ .size = .{ .fill, .px(4) } }, .{}) });
    const B = Plain(bars, .{});
    try testing.expect(!B.needs.text and !B.needs.wrap);
    // Without its text passes it still equals the runtime layout.
    try expectSameLayout(.{ .name = "bars", .State = struct {}, .spec = bars }, .{ 300, 50 });
}

const dash = examples.dash;

test "Plain.dirtySpan: a field's partial routine covers its labels' relayout boundary" {
    const P = Plain(dash, .{});
    // Rows: 0 col, 1 title, 2 row, 3 tile a, 4 label a, 5 bar, 6 tile b, ...
    try testing.expectEqual([2]u32{ 3, 6 }, P.dirtySpan("a").?);
    try testing.expectEqual([2]u32{ 6, 9 }, P.dirtySpan("b").?);
    try testing.expectEqual([2]u32{ 0, P.Cols.node_count }, P.dirtySpan("title").?);
    // A slider's value moves no box.
    try testing.expectEqual(null, P.dirtySpan("level"));
}

test "Plain.relayout: after a text change, the partial routine equals a full layout" {
    const P = Plain(dash, .{});
    const vp: [2]f32 = .{ 400, 200 };
    const before: [P.label_count]Span = .{ .{ .bytes = 5 }, .{ .bytes = 3 }, .{ .bytes = 9 }, .{ .bytes = 1 } };
    inline for (.{ "a", "b", "c", "title", "level" }, 0..) |field, k| {
        var after = before;
        // The label showing `field` (label k: title is label 0) gets new text.
        if (k < 3) after[k + 1].bytes = 17 else if (k == 3) after[0].bytes = 22;
        var scratch: P.Scratch = undefined;
        var ram: P.Cols.Dynamic = undefined;
        P.run(&scratch, &ram, vp, &before, test_font);
        P.relayout(field, &scratch, &ram, &after, test_font);
        var scratch2: P.Scratch = undefined;
        var full: P.Cols.Dynamic = undefined;
        P.run(&scratch2, &full, vp, &after, test_font);
        inline for (.{ "size", "pos", "rect", "vis" }) |col|
            try testing.expectEqualDeep(@field(full, col), @field(ram, col));
        try testing.expectEqualSlices(u8, &full.visible, &ram.visible);
    }
    // The new text does change the tile's label, so the test is not trivially equal.
    var s1: P.Scratch = undefined;
    var r1: P.Cols.Dynamic = undefined;
    var after = before;
    after[1].bytes = 17;
    P.run(&s1, &r1, vp, &before, test_font);
    const w0 = r1.size[0][4];
    P.relayout("a", &s1, &r1, &after, test_font);
    try testing.expect(r1.size[0][4] != w0);
}

test "Plain.gap_total: equals what prepare computes for the runtime tree" {
    inline for (.{ examples.mixer, examples.settings, examples.static_card }) |sp| {
        const P = Plain(sp, .{});
        var buf: [1 << 17]u8 align(64) = undefined;
        var carver: mem.Carver = .{ .buf = &buf };
        var t = tree.Tree.init(&carver, P.Cols.node_count);
        pushAll(&t, sp, 0);
        layout.prepare(&t);
        try testing.expectEqualSlices(f32, t.c.gap_total[0..P.Cols.node_count], P.gap_total[0..P.Cols.node_count]);
        try testing.expect(!@hasField(P.Scratch, "gap_total"));
    }
}

test "Layout.run: equals the runtime layout of the same UI" {
    // Every example but the custom widget's, whose rows are built at run time.
    inline for (examples.all) |e| if (comptime !std.mem.eql(u8, e.name, "custom")) try expectBoth(e);
}

// ---- equivalence with the runtime front end ----------------------------------------------------

const Context = @import("../runtime/context.zig").Context;
const Frame = @import("../runtime/frame.zig").Frame;
const Input = @import("../core/input.zig").Input;
const spec_zig = @import("spec.zig");

/// Builds `s` with the runtime front end's open / close, as an application would write it.
fn build(f: *Frame, comptime s: Spec, next_label: *usize) void {
    if (s.kind == .label) {
        // Frame.text's run on the spec node's own style.
        _ = f.textStyled(sample[0..labelBytes(next_label.*)], .{}, s.style);
        next_label.* += 1;
        return;
    }
    const id: Id = if (s.id) |name| .hash(name) else .none;
    _ = f.open(id, s.style);
    inline for (s.children) |c| build(f, c, next_label);
    f.close();
}

/// `e` through a runtime `Context` frame (`begin`, `open` / `close`, `end`: level-by-level
/// resolve, incremental place, finalize, paint) against the comptime `Layout` of the same UI
/// under the root `Context.begin` opens: a viewport-sized group that clips.
fn expectSameAsContext(comptime e: examples.Example, viewport: [2]f32) !void {
    const limits: @import("../runtime/context.zig").Limits = .{ .nodes = 64, .texts = 32, .customs = 1, .strings = 1024, .anims = 1, .tweens = 1, .flips = 1, .signals = 1, .depth = 8, .timers = 1, .memos = 1 };
    const S = struct {
        var buffer: [Context.requiredBytes(limits)]u8 align(mem.column_align) = undefined;
    };
    var ctx = try Context.init(&S.buffer, limits);
    const in: Input = .{ .viewport = viewport };
    var f = ctx.begin(&in);
    var next_label: usize = 0;
    build(&f, e.spec, &next_label);
    const out = f.end(test_font);
    try testing.expect(out.status.ok());
    const t = out.tree;

    const wrapped = comptime spec_zig.col(.{ .clip = true, .role = .group }, .{e.spec});
    const L = Layout(wrapped, e.options);
    try testing.expectEqual(L.Cols.node_count, t.len);
    var scratch: L.Scratch = undefined;
    var ram: L.Cols.Dynamic = undefined;
    const spans = labelSpans(L.label_count);
    L.run(&scratch, &ram, viewport, &spans, test_font);
    for (0..t.len) |i| {
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

test "Layout: equals the runtime front end (Context frame) for every example and viewport" {
    // Viewports up to an example's declared one, whose size its coordinate type is chosen for.
    inline for (examples.all) |e| if (comptime !std.mem.eql(u8, e.name, "custom")) {
        inline for (.{ [2]f32{ 800, 600 }, [2]f32{ 320, 240 }, [2]f32{ 96, 64 }, [2]f32{ 1, 1 }, [2]f32{ 333.5, 21.25 }, [2]f32{ 50.5, 63 } }) |vp| {
            const max = e.options.viewport orelse .{ std.math.inf(f32), std.math.inf(f32) };
            if (vp[0] <= max[0] and vp[1] <= max[1]) try expectSameAsContext(e, vp);
        }
    };
}
