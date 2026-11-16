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
const Options = @import("validate.zig").Options;
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

/// Columns that hold screen coordinates snapped to whole pixels: the layout outputs `rect` and
/// `vis`. With a declared viewport they are stored as `Coord` instead of f32.
const coordinate_columns = [_][]const u8{ "rect", "vis" };

/// The integer type for coordinates on a screen of at most `viewport` px: the smallest of
/// i8, i16 and i32 that holds -m..m for the larger side m, so a rect may start as far left
/// or above the screen as the screen is wide or high. f32 without a viewport. The probe's
/// `Runtime.rect` is i16, enough for the screens it targets.
pub fn Coord(comptime viewport: ?[2]f32) type {
    const vp = viewport orelse return f32;
    const m: comptime_int = @intFromFloat(@ceil(@max(vp[0], vp[1])));
    for ([_]type{ i8, i16, i32 }) |T| if (m <= std.math.maxInt(T)) return T;
    @compileError(std.fmt.comptimePrint("viewport side {d} px does not fit i32", .{m}));
}

/// The column split of the UI declared by `spec`. `options.viewport`, the fixed screen the UI
/// runs on (validate.Options), picks the coordinate type.
pub fn Columns(comptime spec: Spec, comptime options: Options) type {
    const n = flatten.count(spec);
    const info = @typeInfo(RuntimeColumns).@"struct";
    const custom = any(spec, isCustom);
    const shows = any(spec, showsState);
    return struct {
        pub const node_count = n;
        /// The type of `rect` and `vis` rows in `Dynamic`: `Coord(options.viewport)`.
        pub const Coordinate = Coord(options.viewport);
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

        /// Read-only bytes: the constant tables (`table`).
        pub const rodata_bytes = blk: {
            var b = 0;
            for (info.field_types, class) |FT, c| {
                if (c == .constant) b += @sizeOf(Rows(FT, n));
            }
            break :blk b;
        };
        /// The dynamic columns: one field per dynamic column of `Tree.Columns`, of the same name,
        /// with exactly one row per node (`[n]T`, `[k][n]T`), as the probe's `Runtime.rect` is
        /// `[n][4]i16`. No capacity and no overflow path: the node count is exact. Not padded to
        /// whole vectors (`simd.rows`); a pass that reads them with vectors needs the padding.
        pub const Dynamic = blk: {
            @setEvalBranchQuota(10_000);
            var dyn_names: []const []const u8 = &.{};
            var dyn_types: []const type = &.{};
            for (names, info.field_types, class) |name, FT, c| {
                if (c != .dynamic) continue;
                dyn_names = dyn_names ++ [_][]const u8{name};
                dyn_types = dyn_types ++ [_]type{if (contains(&coordinate_columns, name)) [4][n]Coordinate else Rows(FT, n)};
            }
            const nm = dyn_names[0..dyn_names.len].*;
            const ty = dyn_types[0..dyn_types.len].*;
            break :blk @Struct(.auto, null, &nm, &ty, &@splat(.{}));
        };

        /// RAM bytes: one `Dynamic`.
        pub const ram_bytes = @sizeOf(Dynamic);
    };
}

// ---- tests -------------------------------------------------------------------------------------

const testing = std.testing;
const examples = @import("examples.zig");

test "Columns: the probe's mixer keeps structure and style constant, layout and value dynamic" {
    const C = Columns(examples.mixer, .{});
    inline for (.{ "id", "parent", "end", "nkids", "min", "max", "grow", "pad_lo", "gap", "main", "look", "role", "clips", "sense", "text" }) |name|
        try testing.expectEqual(Class.constant, C.classOf(name));
    inline for (.{ "fit", "nat", "used", "size", "pos", "rect", "vis", "child_clip", "visible", "value" }) |name|
        try testing.expectEqual(Class.dynamic, C.classOf(name));
}

test "Columns: value is constant when nothing shows a state field in it" {
    const C = Columns(examples.static_card, .{});
    try testing.expectEqual(Class.constant, C.classOf("value"));
    try testing.expectEqual(Class.dynamic, C.classOf("rect"));
}

test "Columns: a custom widget builds its own rows, so every column is dynamic" {
    const C = Columns(examples.custom, .{});
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
        const C = Columns(e.spec, e.options);
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
    const C = Columns(examples.mixer, .{});
    try testing.expectEqualSlices(u32, &.{ 0, 0, 0, 2, 2, 0, 5, 5 }, C.table("parent"));
    try testing.expectEqualSlices(u32, &.{ 8, 2, 5, 4, 5, 8, 7, 8 }, C.table("end"));
    try testing.expectEqualSlices(f32, &.{ 3, 0, 2, 0, 0, 2, 0, 0 }, C.table("nkids"));
    try testing.expectEqualSlices(f32, &.{ 4, 0, 8, 0, 0, 8, 0, 0 }, C.table("gap"));
    try testing.expectEqual(@backingInt(Id.hash("volume")), C.table("id")[4]);
}

test "Columns: every column is classified, and the two classes hold the runtime rows" {
    inline for (examples.all) |e| {
        const C = Columns(e.spec, e.options);
        var row: usize = 0;
        inline for (@typeInfo(RuntimeColumns).@"struct".field_types) |FT| row += rowBytes(FT);
        // Equal up to the padding @sizeOf adds to Dynamic's end, and the bytes integer
        // coordinates save in `rect` and `vis`.
        const saved = 2 * 4 * C.node_count * (4 - @sizeOf(C.Coordinate));
        try testing.expect(C.rodata_bytes + C.ram_bytes + saved >= C.node_count * row);
        try testing.expect(C.rodata_bytes + C.ram_bytes + saved < C.node_count * row + 16);
        try testing.expectEqual(@typeInfo(RuntimeColumns).@"struct".field_names.len, C.class.len);
    }
}

test "Coord: the smallest signed integer that holds the viewport, f32 without one" {
    try testing.expectEqual(f32, Coord(null));
    try testing.expectEqual(i8, Coord(.{ 96, 64 }));
    try testing.expectEqual(i8, Coord(.{ 127, 127 }));
    try testing.expectEqual(i16, Coord(.{ 128, 64 }));
    try testing.expectEqual(i16, Coord(.{ 320, 240 }));
    try testing.expectEqual(i16, Coord(.{ 1920, 32767 }));
    try testing.expectEqual(i32, Coord(.{ 32768, 10 }));
    // The probe's i16, for a 320x240 settings page.
    const S = Columns(examples.settings, .{ .viewport = .{ 320, 240 } });
    try testing.expectEqual([4][S.node_count]i16, @FieldType(S.Dynamic, "rect"));
    try testing.expectEqual([4][S.node_count]i16, @FieldType(S.Dynamic, "vis"));
    // Other layout outputs stay f32: they feed the next frame's arithmetic.
    try testing.expectEqual([2][S.node_count]f32, @FieldType(S.Dynamic, "size"));
}

test "Columns.Dynamic: one exact array per dynamic column, nothing for constant ones" {
    const C = Columns(examples.mixer, .{});
    const D = C.Dynamic;
    try testing.expectEqual([2][8]f32, @FieldType(D, "size"));
    try testing.expectEqual([4][8]f32, @FieldType(D, "rect"));
    try testing.expectEqual([8][4]f32, @FieldType(D, "child_clip"));
    try testing.expectEqual([8]f32, @FieldType(D, "value"));
    try testing.expect(!@hasField(D, "parent") and !@hasField(D, "look"));
    inline for (C.names, C.class) |name, c| try testing.expectEqual(c == .dynamic, @hasField(D, name));
    // A frame writes it like the runtime columns, one row per node.
    var d: D = undefined;
    for (&d.rect, 0..) |*side, k| side.* = @splat(@floatFromInt(k));
    try testing.expectEqual(3, d.rect[3][7]);
}
