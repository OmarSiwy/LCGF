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
const mem = @import("../core/mem.zig");
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

const Look = tree.Look;

/// A `Look` whose two colours are indices into the UI's palette (`Columns.palette`): 28 bytes
/// instead of 32. `extern` for a fixed layout, as `Look` is.
pub const PalettedLook = extern struct {
    params: [4]f32,
    radius: f32,
    texture: u16,
    material: u16,
    fill: u8,
    border_color: u8,
};

fn collectStrings(comptime s: Spec, comptime all: *[]const []const u8) void {
    if (s.name) |x| all.* = all.* ++ [_][]const u8{x};
    if (s.id) |x| all.* = all.* ++ [_][]const u8{x};
    for (s.children) |c| collectStrings(c, all);
}

fn longerFirst(_: void, a: []const u8, b: []const u8) bool {
    return a.len > b.len;
}

/// The row type of a column with `n` rows: `[]T` becomes `[n]T`, `[k][]T` becomes `[k][n]T`.
fn Rows(comptime FT: type, comptime n: comptime_int) type {
    return switch (@typeInfo(FT)) {
        .pointer => |p| [n]p.child,
        .array => |a| [a.len][n]@typeInfo(a.child).pointer.child,
        else => @compileError("not a column: " ++ @typeName(FT)),
    };
}

/// One row of a column: `T` for `[]T`, `[k]T` for `[k][]T`.
fn Element(comptime FT: type) type {
    return switch (@typeInfo(FT)) {
        .pointer => |p| p.child,
        .array => |a| [a.len]@typeInfo(a.child).pointer.child,
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
    @setEvalBranchQuota(1000 + 100 * n);
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

        /// `dropped[k]`: column `names[k]` is kept neither as a table nor in `Dynamic`, because
        /// the UI does not use the feature it serves. A constant column whose rows are all equal
        /// is one value (`uniform`): the defaults for a feature no node sets (`scroll`, `offset`,
        /// `grow`...), and any style every node shares. `child_clip`, the clip a node hands its
        /// children, is not kept when no node clips.
        pub const dropped: [names.len]bool = blk: {
            @setEvalBranchQuota(10_000 + 200 * n * names.len);
            var out: [names.len]bool = undefined;
            for (names, class, &out) |name, c, *d| d.* = switch (c) {
                .constant => allEqual(name),
                .dynamic => std.mem.eql(u8, name, "child_clip") and classOf("clips") == .constant and
                    allEqual("clips") and pushed.c.clips[0] == 0,
            };
            break :blk out;
        };

        fn allEqual(comptime name: []const u8) bool {
            const col = @field(pushed.c, name);
            // `[k][]T` in Tree.Columns: k axis columns, each must be uniform.
            if (@typeInfo(@FieldType(RuntimeColumns, name)) == .array) {
                for (col) |axis| for (axis[0..n]) |r| if (!std.meta.eql(r, axis[0])) return false;
                return true;
            }
            for (col[0..n]) |r| if (!std.meta.eql(r, col[0])) return false;
            return true;
        }

        pub fn isDropped(comptime name: []const u8) bool {
            return dropped[std.meta.fieldIndex(RuntimeColumns, name).?];
        }

        /// The one row value of a dropped constant column: every node's row (for `[k]` axis
        /// columns, the k values of a row).
        pub fn uniform(comptime name: []const u8) Element(@FieldType(RuntimeColumns, name)) {
            if (comptime !isDropped(name) or classOf(name) != .constant) @compileError("column '" ++ name ++ "' is not a dropped constant");
            const col = @field(pushed.c, name);
            return comptime switch (@typeInfo(@FieldType(RuntimeColumns, name))) {
                .pointer => col[0],
                else => blk: {
                    var r: Element(@FieldType(RuntimeColumns, name)) = undefined;
                    for (&r, col) |*x, axis| x.* = axis[0];
                    break :blk r;
                },
            };
        }

        /// The tree `Tree.push` builds from the spec, built while compiling: the source of every
        /// constant table, so a table equals the runtime column row for row.
        const pushed = blk: {
            @setEvalBranchQuota(100_000 + 5_000 * n);
            var t: tree.TreeOf(u32, .{ .array = n }) = .empty;
            pushAll(&t, spec, 0);
            break :blk t;
        };

        /// Every distinct colour of the constant `look` column (`fill` and `border_color`), in
        /// order of first use. Empty when `look` is dynamic.
        pub const palette: []const u32 = blk: {
            if (classOf("look") != .constant) break :blk &.{};
            @setEvalBranchQuota(10_000 + 600 * n);
            var out: []const u32 = &.{};
            for (pushed.c.look[0..n]) |l| for ([_]u32{ l.fill, l.border_color }) |c| {
                if (std.mem.indexOfScalar(u32, out, c) == null) out = out ++ [_]u32{c};
            };
            break :blk out;
        };
        /// `look` stores palette indices (`PalettedLook`) when the palette fits a byte.
        pub const paletted = classOf("look") == .constant and !isDropped("look") and palette.len <= 256;
        /// The palette, as the read-only table `PalettedLook` rows index.
        pub const palette_table: [palette.len]u32 = palette[0..palette.len].*;

        /// The rows of the read-only table of `name`: as `Rows`, except `look` when paletted.
        fn TableRows(comptime name: []const u8) type {
            return if (paletted and std.mem.eql(u8, name, "look")) [n]PalettedLook else Rows(@FieldType(RuntimeColumns, name), n);
        }

        /// The read-only table of the constant column `name`: its `n` rows as `Tree.push` writes
        /// them, `look` with its colours as palette indices when `paletted`. A comptime constant,
        /// so it lives in read-only data, not in RAM the UI owns.
        pub fn table(comptime name: []const u8) *const TableRows(name) {
            if (comptime classOf(name) != .constant) @compileError("column '" ++ name ++ "' is dynamic in this UI");
            return &struct {
                const rows: TableRows(name) = blk: {
                    @setEvalBranchQuota(10_000 + 100 * n + 10 * n * palette.len);
                    const col = @field(pushed.c, name);
                    var out: TableRows(name) = undefined;
                    if (TableRows(name) == [n]PalettedLook) {
                        for (&out, col[0..n]) |*o, l| o.* = .{
                            .params = l.params,
                            .radius = l.radius,
                            .texture = l.texture,
                            .material = l.material,
                            .fill = @intCast(std.mem.indexOfScalar(u32, palette, l.fill).?),
                            .border_color = @intCast(std.mem.indexOfScalar(u32, palette, l.border_color).?),
                        };
                    } else switch (@typeInfo(@FieldType(RuntimeColumns, name))) {
                        .pointer => out = col[0..n].*,
                        else => for (&out, col) |*o, c| {
                            o.* = c[0..n].*;
                        },
                    }
                    break :blk out;
                };
            }.rows;
        }

        /// Row `i` of the constant `look` column as paint reads it, from the palette when
        /// `paletted`: two loads more than reading the full row.
        pub fn look(i: usize) Look {
            const l = table("look")[i];
            if (!paletted) return l;
            return .{
                .params = l.params,
                .fill = palette_table[l.fill],
                .border_color = palette_table[l.border_color],
                .radius = l.radius,
                .texture = l.texture,
                .material = l.material,
            };
        }

        pub fn classOf(comptime name: []const u8) Class {
            return class[std.meta.fieldIndex(RuntimeColumns, name) orelse @compileError("no column '" ++ name ++ "'")];
        }

        /// Every accessible name (`Spec.name`) and widget id (`Spec.id`) of the UI in one
        /// read-only byte table, each stored once: a string equal to, or contained in, one
        /// already in the table points into it (longest strings are placed first). Labels show
        /// state at run time, so their text is not here.
        pub const strings: []const u8 = blk: {
            @setEvalBranchQuota(10_000 + 2_000 * n);
            var all: []const []const u8 = &.{};
            collectStrings(spec, &all);
            // Longest first, so a shorter string can land inside one already placed.
            var sorted: [all.len][]const u8 = all[0..all.len].*;
            std.mem.sort([]const u8, &sorted, {}, longerFirst);
            var out: []const u8 = &.{};
            for (sorted) |str| if (std.mem.indexOf(u8, out, str) == null) {
                out = out ++ str;
            };
            break :blk out;
        };
        /// The string table as an array, the form that lands in read-only data.
        pub const string_table: [strings.len]u8 = strings[0..strings.len].*;
        /// The smallest of u8, u16 and u32 that holds every offset into `strings` and its end.
        pub const Offset = if (strings.len <= 0xff) u8 else if (strings.len <= 0xffff) u16 else u32;
        /// Bytes `start..start + bytes` of `strings`, as `Strings.Span` in the runtime front end.
        pub const Span = struct { start: Offset = 0, bytes: Offset = 0 };

        /// Row i: node i's accessible name in `strings`; empty for a node without one.
        pub const name_span: [n]Span = spans(.name);
        /// Row i: node i's widget id in `strings`; empty for a node without one.
        pub const id_span: [n]Span = spans(.id);

        fn spans(comptime which: enum { name, id }) [n]Span {
            @setEvalBranchQuota(10_000 + 2_000 * n);
            var out: [n]Span = undefined;
            var next: usize = 0;
            spanWalk(spec, which == .name, &next, &out);
            return out;
        }

        fn spanWalk(comptime s: Spec, comptime names_: bool, comptime next: *usize, comptime out: *[n]Span) void {
            const str: ?[]const u8 = if (names_) s.name else s.id;
            out[next.*] = if (str) |x| .{ .start = std.mem.indexOf(u8, strings, x).?, .bytes = x.len } else .{};
            next.* += 1;
            for (s.children) |c| spanWalk(c, names_, next, out);
        }

        /// Node i's accessible name, or "".
        pub fn accessibleName(i: usize) []const u8 {
            const sp = name_span[i];
            return string_table[sp.start..][0..sp.bytes];
        }

        /// Read-only bytes: the constant tables (`table`).
        pub const rodata_bytes = blk: {
            var b = 0;
            for (names, class, dropped) |name, c, d| {
                if (c == .constant and !d) b += @sizeOf(TableRows(name));
            }
            if (paletted) b += @sizeOf(@TypeOf(palette_table));
            // A UI without strings needs no spans: every one is empty.
            if (strings.len > 0) b += @sizeOf(@TypeOf(string_table)) + @sizeOf(@TypeOf(name_span)) + @sizeOf(@TypeOf(id_span));
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
            for (names, info.field_types, class, dropped) |name, FT, c, d| {
                if (c != .dynamic or d) continue;
                dyn_names = dyn_names ++ [_][]const u8{name};
                dyn_types = dyn_types ++ [_]type{if (contains(&coordinate_columns, name)) [4][n]Coordinate else Rows(FT, n)};
            }
            const nm = dyn_names[0..dyn_names.len].*;
            const ty = dyn_types[0..dyn_types.len].*;
            break :blk @Struct(.auto, null, &nm, &ty, &@splat(.{}));
        };

        /// RAM bytes: one `Dynamic`.
        pub const ram_bytes = @sizeOf(Dynamic);

        /// RAM the runtime front end's tree takes for the same UI at a capacity of exactly its
        /// node count: every column of `Tree.Columns` and `Tree.Extras`, padded and aligned as
        /// `Tree.init` carves them from the caller's buffer. The comptime UI replaces it with
        /// `ram_bytes` of RAM and `rodata_bytes` of read-only data.
        pub const runtime_bytes = blk: {
            @setEvalBranchQuota(20_000);
            var counter: mem.Carver = .{ .buf = null };
            _ = tree.Tree.init(&counter, n);
            break :blk counter.off;
        };
        /// RAM saved against the runtime tree. Read-only data is not RAM on a microcontroller
        /// (it stays in flash), so it is not subtracted.
        pub const ram_saved = runtime_bytes - ram_bytes;
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
    if (comptime C.isDropped(name)) {
        const u = C.uniform(name);
        const col = @field(t.c, name);
        if (comptime @typeInfo(@TypeOf(col)) == .pointer) {
            for (col[0..C.node_count]) |r| try testing.expectEqual(u, r);
        } else for (col, u) |axis, v| for (axis[0..C.node_count]) |r| try testing.expectEqual(v, r);
        return;
    }
    if (comptime std.mem.eql(u8, name, "look")) {
        for (0..C.node_count) |i| try testing.expectEqual(t.c.look[i], C.look(i));
        return;
    }
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
        var carver: mem.Carver = .{ .buf = &buf };
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

test "Columns: every column is kept exactly once: a table, a Dynamic field or one value" {
    inline for (examples.all) |e| {
        const C = Columns(e.spec, e.options);
        try testing.expectEqual(@typeInfo(RuntimeColumns).@"struct".field_names.len, C.class.len);
        inline for (C.names, C.class, C.dropped) |name, c, d| {
            try testing.expectEqual(c == .dynamic and !d, @hasField(C.Dynamic, name));
        }
    }
}

test "Columns.dropped: a column every node shares is one value, and equals the runtime rows" {
    const C = Columns(examples.mixer, .{});
    inline for (.{ "scroll", "offset", "grow", "pct", "flow", "shrink", "clips", "role", "look" }) |name|
        try testing.expect(comptime C.isDropped(name));
    inline for (.{ "parent", "end", "nkids", "gap", "pad_lo", "main", "id", "rect", "size" }) |name|
        try testing.expect(comptime !C.isDropped(name));
    try testing.expectEqual([2]f32{ 0, 0 }, C.uniform("scroll"));
    try testing.expectEqual(@as(f32, 1), C.uniform("flow"));
    // No node clips: no child clip in RAM. The badge clips, and keeps it.
    try testing.expect(!@hasField(C.Dynamic, "child_clip"));
    try testing.expect(@hasField(Columns(examples.badge, .{}).Dynamic, "child_clip"));
}

test "Columns.runtime_bytes: the bytes Tree.init carves for the same node count" {
    inline for (examples.all) |e| {
        const C = Columns(e.spec, e.options);
        var buf: [1 << 16]u8 align(64) = undefined;
        var carver: mem.Carver = .{ .buf = &buf };
        _ = tree.Tree.init(&carver, C.node_count);
        try testing.expectEqual(carver.off, C.runtime_bytes);
        // Every example needs less RAM, and less RAM and read-only data together.
        try testing.expect(C.ram_bytes < C.runtime_bytes);
        try testing.expect(C.ram_bytes + C.rodata_bytes < C.runtime_bytes);
    }
}

test "PalettedLook: 28 bytes, 4 fewer than Look" {
    try testing.expectEqual(28, @sizeOf(PalettedLook));
    try testing.expectEqual(32, @sizeOf(Look));
}

test "Columns.palette: every look reads back as Tree.push wrote it" {
    inline for (examples.all) |e| {
        const C = Columns(e.spec, e.options);
        if (comptime C.paletted) {
            const pushed_look = C.pushed.c.look;
            for (0..C.node_count) |i| try testing.expectEqual(pushed_look[i], C.look(i));
            try testing.expect(C.palette.len <= 256);
        }
    }
    // The card: transparent, its fill and its border colour.
    const Card = Columns(examples.static_card, .{});
    try testing.expect(Card.paletted);
    try testing.expectEqual(3, Card.palette.len);
    try testing.expectEqual([5]PalettedLook, @TypeOf(Card.table("look").*));
    // A custom widget makes look dynamic: no palette.
    try testing.expect(!Columns(examples.custom, .{}).paletted);
}

/// `n` labels with `n` different fills.
fn rainbow(comptime n: comptime_int) Spec {
    @setEvalBranchQuota(1000 + 100 * n);
    var kids: [n]Spec = undefined;
    for (&kids, 0..) |*k, i| k.* = .{ .kind = .label, .bind = "x", .style = .{ .fill = .rgb(@intCast(i % 256), @intCast(i / 256), 1) } };
    return spec_zig.row(.{}, kids);
}

// Container-level, so each is built in an evaluation of its own.
const rainbow_255 = rainbow(255);
const rainbow_256 = rainbow(256);

test "Columns.palette: more than 256 colours keep full looks" {
    // n fills and transparent (the root's fill, every border): n + 1 colours.
    try testing.expect(!Columns(rainbow_256, .{}).paletted);
    try testing.expect(Columns(rainbow_255, .{}).paletted);
    try testing.expectEqual(256, Columns(rainbow_255, .{}).palette.len);
}

test "Columns.strings: names and ids stored once, shared when one contains another" {
    const C = Columns(examples.mixer, .{});
    // "Volume" holds the id "volume"? No: case differs. "Mute"/"mute", "Pan"/"pan" too: six
    // strings, and none inside another.
    try testing.expectEqual(u8, C.Offset);
    try testing.expectEqual("Volume".len + "volume".len + "Mute".len + "mute".len + "Pan".len + "pan".len, C.strings.len);
    try testing.expectEqualStrings("Volume", C.accessibleName(4));
    try testing.expectEqualStrings("Mute", C.accessibleName(3));
    try testing.expectEqualStrings("", C.accessibleName(0));
    try testing.expectEqualStrings("pan", C.string_table[C.id_span[7].start..][0..C.id_span[7].bytes]);
    // The settings page names each control after its id: one copy of each.
    const S = Columns(examples.settings, .{ .viewport = .{ 320, 240 } });
    var total: usize = 0;
    inline for (@typeInfo(examples.Settings).@"struct".field_names[1..]) |f| total += f.len;
    try testing.expect(S.strings.len <= total);
    for (0..S.node_count) |i| {
        const id = S.string_table[S.id_span[i].start..][0..S.id_span[i].bytes];
        try testing.expectEqualStrings(id, S.accessibleName(i));
    }
}

test "Columns.strings: a string inside a longer one points into it" {
    const sp = spec_zig;
    const s = comptime sp.row(.{}, .{ sp.named(sp.slider(.vol, .x), "Master volume"), sp.named(sp.slider(.v, .x), "volume") });
    const C = Columns(s, .{});
    // "volume", the id "vol" and the id "v" all lie inside "Master volume".
    try testing.expectEqualStrings("Master volume", C.strings);
    try testing.expectEqualStrings("volume", C.accessibleName(2));
    try testing.expectEqual(7, C.name_span[2].start);
    try testing.expectEqual(7, C.id_span[1].start);
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
    try testing.expectEqual([8]f32, @FieldType(D, "value"));
    try testing.expect(!@hasField(D, "parent") and !@hasField(D, "look"));
    // A frame writes it like the runtime columns, one row per node.
    var d: D = undefined;
    for (&d.rect, 0..) |*side, k| side.* = @splat(@floatFromInt(k));
    try testing.expectEqual(3, d.rect[3][7]);
}
