//! Columns: which of the runtime tree's columns a comptime UI can keep as read-only tables and
//! which it must keep in RAM. Tier 1. The probe (prototype/comptime_ui_probe.zig, `Ui().Runtime`)
//! keeps only state, rects and a dirty mask in RAM and everything structural as constants; this
//! file applies that split to every column of `Tree.Columns` (src/core/tree.zig).
//!
//! A column is **constant** when every row is known from the spec alone, and **dynamic** when a
//! frame writes it. The layout scratch and outputs are always dynamic. Inputs are constant
//! unless the UI writes them at run time: `value` when a checkbox or slider shows a state field,
//! and every input when a custom widget (`Spec.widget`) builds its own rows.

const std = @import("std");
const tree = @import("../core/tree.zig");
const spec_zig = @import("spec.zig");
const flatten = @import("flatten.zig");
const Spec = spec_zig.Spec;
const Id = @import("../core/types.zig").Id;
const RuntimeColumns = tree.Tree.Columns;

pub const Class = enum { constant, dynamic };

/// Columns every frame rewrites, whatever the UI: the layout scratch (`Tree.scratch`), the
/// layout outputs, and the visibility and clip that finalize derives from them.
const outputs = tree.Tree.scratch ++ [_][]const u8{ "size", "pos", "rect", "vis", "child_clip", "visible" };

/// Inputs a bound checkbox or slider writes from its state field each frame.
const bound_inputs = [_][]const u8{"value"};

fn contains(comptime list: []const []const u8, comptime name: []const u8) bool {
    for (list) |s| if (std.mem.eql(u8, s, name)) return true;
    return false;
}

/// Whether some node of `s` satisfies `pred`.
fn any(comptime s: Spec, comptime pred: fn (Spec) bool) bool {
    if (pred(s)) return true;
    for (s.children) |c| if (any(c, pred)) return true;
    return false;
}

fn showsState(comptime s: Spec) bool {
    return s.bind != null and (s.kind == .checkbox or s.kind == .slider);
}

fn isCustom(comptime s: Spec) bool {
    return s.widget != null;
}

/// Bytes one row of a `Tree.Columns` field takes: `[]T` is one T, `[k][]T` is k of them.
fn rowBytes(comptime FT: type) comptime_int {
    return switch (@typeInfo(FT)) {
        .pointer => |p| @sizeOf(p.child),
        .array => |a| a.len * @sizeOf(@typeInfo(a.child).pointer.child),
        else => @compileError("not a column: " ++ @typeName(FT)),
    };
}

/// The row type of a column with `n` rows: `[]T` becomes `[n]T`, `[k][]T` becomes `[k][n]T`.
fn Rows(comptime FT: type, comptime n: comptime_int) type {
    return switch (@typeInfo(FT)) {
        .pointer => |p| [n]p.child,
        .array => |a| [a.len][n]@typeInfo(a.child).pointer.child,
        else => @compileError("not a column: " ++ @typeName(FT)),
    };
}

/// Pushes `s` and its subtree under `parent` depth-first, as the front end's `open` / `leaf` /
/// `close` would; `flatten.Flat` numbers rows the same way.
fn pushAll(t: anytype, comptime s: Spec, parent: u32) void {
    const id: Id = if (s.id) |name| .hash(name) else .none;
    const i = t.push(parent, id, &s.style);
    inline for (s.children) |c| pushAll(t, c, i);
    t.seal(i);
}

/// The column split of the UI declared by `spec`.
pub fn Columns(comptime spec: Spec) type {
    const n = flatten.count(spec);
    const info = @typeInfo(RuntimeColumns).@"struct";
    const custom = any(spec, isCustom);
    const shows = any(spec, showsState);
    return struct {
        pub const node_count = n;
        /// The names of `Tree.Columns`, in declaration order.
        pub const names = info.field_names;

        /// `class[k]` is the class of column `names[k]` in this UI.
        pub const class: [names.len]Class = blk: {
            @setEvalBranchQuota(100 * names.len * outputs.len);
            var out: [names.len]Class = undefined;
            for (names, &out) |name, *c| {
                const written = contains(&outputs, name) or (shows and contains(&bound_inputs, name)) or custom;
                c.* = if (written) .dynamic else .constant;
            }
            break :blk out;
        };

        /// The tree `Tree.push` builds from the spec, built while compiling: the source of every
        /// constant table, so a table equals the runtime column row for row.
        const pushed = blk: {
            @setEvalBranchQuota(100_000 + 5_000 * n);
            var t: tree.TreeOf(u32, .{ .array = n }) = .empty;
            pushAll(&t, spec, 0);
            break :blk t;
        };

        /// The read-only table of the constant column `name`: its `n` rows as `Tree.push` writes
        /// them. A comptime constant, so it lives in read-only data, not in RAM the UI owns.
        pub fn table(comptime name: []const u8) *const Rows(@FieldType(RuntimeColumns, name), n) {
            if (comptime classOf(name) != .constant) @compileError("column '" ++ name ++ "' is dynamic in this UI");
            return &struct {
                const rows: Rows(@FieldType(RuntimeColumns, name), n) = blk: {
                    @setEvalBranchQuota(10_000 + 100 * n);
                    const col = @field(pushed.c, name);
                    var out: Rows(@FieldType(RuntimeColumns, name), n) = undefined;
                    switch (@typeInfo(@FieldType(RuntimeColumns, name))) {
                        .pointer => out = col[0..n].*,
                        else => for (&out, col) |*o, c| {
                            o.* = c[0..n].*;
                        },
                    }
                    break :blk out;
                };
            }.rows;
        }

        pub fn classOf(comptime name: []const u8) Class {
            return class[std.meta.fieldIndex(RuntimeColumns, name) orelse @compileError("no column '" ++ name ++ "'")];
        }

        /// Bytes of `cls` columns at one row per node.
        fn bytesOf(comptime cls: Class) comptime_int {
            var b = 0;
            for (info.field_types, class) |FT, c| {
                if (c == cls) b += n * rowBytes(FT);
            }
            return b;
        }

        /// Read-only bytes: the constant tables (`table`).
        pub const rodata_bytes = blk: {
            var b = 0;
            for (info.field_types, class) |FT, c| {
                if (c == .constant) b += @sizeOf(Rows(FT, n));
            }
            break :blk b;
        };
        /// RAM bytes: the dynamic columns, one row per node.
        pub const ram_bytes = bytesOf(.dynamic);
    };
}

// ---- tests -------------------------------------------------------------------------------------

const testing = std.testing;
const examples = @import("examples.zig");

test "Columns: the probe's mixer keeps structure and style constant, layout and value dynamic" {
    const C = Columns(examples.mixer);
    inline for (.{ "id", "parent", "end", "nkids", "min", "max", "grow", "pad_lo", "gap", "main", "look", "role", "clips", "sense", "text" }) |name|
        try testing.expectEqual(Class.constant, C.classOf(name));
    inline for (.{ "fit", "nat", "used", "size", "pos", "rect", "vis", "child_clip", "visible", "value" }) |name|
        try testing.expectEqual(Class.dynamic, C.classOf(name));
}

test "Columns: value is constant when nothing shows a state field in it" {
    const C = Columns(examples.static_card);
    try testing.expectEqual(Class.constant, C.classOf("value"));
    try testing.expectEqual(Class.dynamic, C.classOf("rect"));
}

test "Columns: a custom widget builds its own rows, so every column is dynamic" {
    const C = Columns(examples.custom);
    for (C.class) |c| try testing.expectEqual(Class.dynamic, c);
    try testing.expectEqual(0, C.rodata_bytes);
}

/// The constant table `name` of `C` equals the column of the runtime tree `t`, row for row.
fn expectTable(comptime C: type, comptime name: []const u8, t: *const tree.Tree) !void {
    const rows = C.table(name);
    const col = @field(t.c, name);
    if (comptime @typeInfo(@TypeOf(col)) == .pointer) {
        try testing.expectEqualSlices(@typeInfo(@TypeOf(col)).pointer.child, rows, col[0..C.node_count]);
    } else for (rows, col) |r, c| try testing.expectEqualSlices(f32, &r, c[0..C.node_count]);
}

test "Columns.table: every constant table equals the column Tree.push builds at run time" {
    inline for (examples.all) |e| {
        const C = Columns(e.spec);
        var buf: [1 << 16]u8 align(64) = undefined;
        var carver: @import("../core/mem.zig").Carver = .{ .buf = &buf };
        var t = tree.Tree.init(&carver, C.node_count);
        pushAll(&t, e.spec, 0);
        try testing.expect(!t.overflow);
        inline for (C.names, 0..) |name, k| {
            if (comptime C.class[k] == .constant) try expectTable(C, name, &t);
        }
    }
}

test "Columns.table: the mixer's tables hold the probe's structure and its style" {
    const C = Columns(examples.mixer);
    try testing.expectEqualSlices(u32, &.{ 0, 0, 0, 2, 2, 0, 5, 5 }, C.table("parent"));
    try testing.expectEqualSlices(u32, &.{ 8, 2, 5, 4, 5, 8, 7, 8 }, C.table("end"));
    try testing.expectEqualSlices(f32, &.{ 3, 0, 2, 0, 0, 2, 0, 0 }, C.table("nkids"));
    try testing.expectEqualSlices(f32, &.{ 4, 0, 8, 0, 0, 8, 0, 0 }, C.table("gap"));
    try testing.expectEqual(@backingInt(Id.hash("volume")), C.table("id")[4]);
}

test "Columns: every column is classified, and the two classes add up to the runtime row" {
    inline for (examples.all) |e| {
        const C = Columns(e.spec);
        var row: usize = 0;
        inline for (@typeInfo(RuntimeColumns).@"struct".field_types) |FT| row += rowBytes(FT);
        try testing.expectEqual(C.node_count * row, C.rodata_bytes + C.ram_bytes);
        try testing.expectEqual(@typeInfo(RuntimeColumns).@"struct".field_names.len, C.class.len);
    }
}
