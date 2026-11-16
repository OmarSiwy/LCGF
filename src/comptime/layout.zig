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

pub fn Layout(comptime spec: Spec, comptime options: Options) type {
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
            // `sense` is constant; finalize clears its padding rows, so it is copied each frame.
            scratch.sense = C.pushed.c.sense;
            var v = view(scratch);
            layout.prepare(&v);
            layout.fit(&v, .x);
            layout.resolve(&v, .x, viewport[0]);
            layout.fit(&v, .y);
            layout.resolve(&v, .y, viewport[1]);
            layout.place(&v);
            layout.finalize(&v);
            keep(scratch, ram);
        }

        /// Copies every output `Dynamic` holds from `scratch`, coordinates rounded and clamped
        /// into `Coordinate` (they are already whole pixels: finalize snaps them).
        fn keep(scratch: *const Scratch, ram: *C.Dynamic) void {
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

test "Layout.run: equals the runtime layout of the same UI" {
    // Every example but the custom widget's, whose rows are built at run time.
    inline for (examples.all) |e| if (comptime !std.mem.eql(u8, e.name, "custom")) try expectBoth(e);
}
