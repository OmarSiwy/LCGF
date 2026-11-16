//! Table (tier 2): a grid of text cells under a row of column headers, in both front ends.
//! Follows the five-commit recipe of widgets/base.zig and is written against the public API of
//! tiers 0 and 1 only.
//!
//! State lives in the application: the header strings, the cell strings (row-major, `cols` per
//! row) and a `State(cols)` value: the active cell, the sort column and direction, and every
//! column's width. Clicking a header sorts by it (again: the other way), dragging the handle at
//! a header's right edge resizes its column, and with the body focused the arrow keys, Home
//! and End move the active cell (WAI-ARIA APG grid). Rows have the list box's fixed height, so
//! the cell under the pointer is index arithmetic, not a hit test per cell.

const std = @import("std");
const types = @import("../core/types.zig");
const Tree = @import("../core/tree.zig").Tree;
const Input = @import("../core/input.zig").Input;
const DrawList = @import("../draw/draw_list.zig").DrawList;
const Mono = @import("../text/protocol.zig").Mono;
const Frame = @import("../runtime/frame.zig").Frame;
const context = @import("../runtime/context.zig");
const spec_zig = @import("../comptime/spec.zig");
const events = @import("../comptime/events.zig");
const signals = @import("../comptime/signals.zig");
const flatten = @import("../comptime/flatten.zig");
const a11y = @import("../a11y/tree.zig");
const base = @import("base.zig");
const list_zig = @import("list.zig");
const Spec = spec_zig.Spec;
const Theme = base.Theme;
const Id = types.Id;
const Color = types.Color;
const Style = types.Style;
const Response = types.Response;
const none = types.none;

// ---- spec ------------------------------------------------------------------------------------

/// What a table keeps between frames, owned by the application: the active cell (as shown,
/// after sorting), the sort column (`none` for data order) and direction, and each column's
/// width in logical pixels.
pub fn State(comptime cols: usize) type {
    return struct {
        row: u32 = 0,
        col: u32 = 0,
        sort: u32 = none,
        descending: bool = false,
        widths: [cols]f32 = @splat(96),
    };
}

/// Why `S` cannot back a comptime table bound to the state field `state`, with header strings
/// in `headers` and cell strings in `cells`, `cols` columns by `rows` rows; null when it can.
pub fn check(comptime S: type, comptime state: []const u8, comptime headers: []const u8, comptime cells: []const u8, comptime cols: u32, comptime rows: u32) ?[]const u8 {
    comptime {
        if (cols == 0 or rows == 0) return "table: a table has at least one column and one row";
        if (!@hasField(S, state)) return "table: state has no field '" ++ state ++ "' for the table state";
        if (@FieldType(S, state) != State(cols)) return std.fmt.comptimePrint("table: field '{s}' must be a table.State({d})", .{ state, cols });
        for ([_][]const u8{ headers, cells }) |f| {
            if (!@hasField(S, f)) return "table: state has no field '" ++ f ++ "' for strings";
            if (@FieldType(S, f) != []const []const u8) return "table: strings field '" ++ f ++ "' must be a []const []const u8";
        }
        return null;
    }
}

/// `check` as a compile error.
pub fn validate(comptime S: type, comptime state: []const u8, comptime headers: []const u8, comptime cells: []const u8, comptime cols: u32, comptime rows: u32) void {
    if (comptime check(S, state, headers, cells, cols, rows)) |msg| @compileError(msg);
}

/// Ids of a table's parts, all derived from the table's id: the body is the table's id itself,
/// header `k` and its resize handle are numbered after it.
pub fn headerId(id: Id, k: usize) Id {
    return id.with(@intCast(1 + k));
}
pub fn handleId(id: Id, cols: usize, k: usize) Id {
    return id.with(@intCast(1 + cols + k));
}

// ---- behaviour: pure functions of the value and what happened -------------------------------

/// The data row shown at each position, for `cells` (row-major, `cols` per row) sorted by
/// column `sort` (data order for `none`), into `out` (one entry per row). Stable: equal cells
/// keep data order either way.
// ponytail: insertion sort, O(rows^2) per frame; a table of thousands of rows wants the order
// kept by the application and recomputed only when the sort or the data change.
pub fn order(cells: []const []const u8, cols: usize, sort: u32, descending: bool, out: []u32) void {
    for (out, 0..) |*o, k| o.* = @intCast(k);
    if (sort == none) return;
    for (1..out.len) |i| {
        const v = out[i];
        var j = i;
        while (j > 0 and before(cells[v * cols + sort], cells[out[j - 1] * cols + sort], descending)) : (j -= 1) out[j] = out[j - 1];
        out[j] = v;
    }
}

fn before(a: []const u8, b: []const u8, descending: bool) bool {
    const o = std.mem.order(u8, a, b);
    return if (descending) o == .gt else o == .lt;
}

// ---- comptime front end ---------------------------------------------------------------------

pub const ct = struct {
    /// A table named `id` (its body; headers and handles are named after it), bound to the
    /// `State(cols)` field `table`, showing the strings fields `headers` (one per column) and
    /// `cells` (row-major), `cols` columns by `rows` rows. Every header and handle is a widget
    /// of its own.
    pub fn table(comptime th: Theme, comptime id: @EnumLiteral(), comptime state: @EnumLiteral(), comptime headers: @EnumLiteral(), comptime cells: @EnumLiteral(), comptime cols: u32, comptime rows: u32) Spec {
        @setEvalBranchQuota(10_000 + 100 * cols * rows);
        // The rows are styled when pushed, from the state's widths and sort, so the spec
        // carries only the structure.
        const name = @tagName(id);
        var hs: [cols]Spec = undefined;
        for (&hs, 0..) |*h, k| {
            h.* = spec_zig.row(.{}, .{
                base.ct.label(th, headers),
                Spec{ .kind = .col },
                Spec{ .kind = .col, .id = std.fmt.comptimePrint("{s}_r{d}", .{ name, k }) },
            });
            h.id = std.fmt.comptimePrint("{s}_h{d}", .{ name, k });
        }
        var cell_row: [cols]Spec = undefined;
        for (&cell_row) |*c| c.* = spec_zig.row(.{}, .{base.ct.label(th, cells)});
        var body_rows: [rows]Spec = undefined;
        for (&body_rows) |*r| r.* = spec_zig.row(.{}, cell_row);
        var body = spec_zig.col(.{}, body_rows);
        body.id = name;
        var s = spec_zig.col(.{}, .{ spec_zig.row(.{}, hs), body });
        s.bind = @tagName(state);
        return s;
    }

    /// The fields and size a `ct.table` node was built with.
    pub fn fields(comptime n: Spec) struct { name: [:0]const u8, state: []const u8, headers: []const u8, cells: []const u8, cols: u32, rows: u32 } {
        const head = n.children[0];
        const body = n.children[1];
        return .{
            .name = body.id.?,
            .state = n.bind.?,
            .headers = head.children[0].children[0].bind.?,
            .cells = body.children[0].children[0].children[0].bind.?,
            .cols = head.children.len,
            .rows = body.children.len,
        };
    }
};

/// Whether spec node `n` is a table made by `ct.table`: a column bound to a field.
fn isTable(comptime n: Spec) bool {
    return n.kind == .col and n.bind != null;
}

// ---- tests ----------------------------------------------------------------------------------

const testing = std.testing;
const theme: Theme = .default;
const Replay = @import("../core/input.zig").Replay;

test "check: what a comptime table's state must have" {
    const Good = struct { t: State(2) = .{}, h: []const []const u8 = &.{}, c: []const []const u8 = &.{} };
    try testing.expectEqual(null, comptime check(Good, "t", "h", "c", 2, 3));
    try testing.expectEqualStrings("table: a table has at least one column and one row", comptime check(Good, "t", "h", "c", 0, 3).?);
    try testing.expectEqualStrings("table: state has no field 'x' for the table state", comptime check(Good, "x", "h", "c", 2, 3).?);
    try testing.expectEqualStrings("table: field 't' must be a table.State(3)", comptime check(Good, "t", "h", "c", 3, 3).?);
    try testing.expectEqualStrings("table: state has no field 'y' for strings", comptime check(Good, "t", "y", "c", 2, 3).?);
    const Bad = struct { t: State(2) = .{}, h: []const []const u8 = &.{}, c: []const u8 = "" };
    try testing.expectEqualStrings("table: strings field 'c' must be a []const []const u8", comptime check(Bad, "t", "h", "c", 2, 3).?);
}

test "ct.table: headers and handles are widgets, then the body" {
    const spec = comptime ct.table(theme, .files, .table, .headers, .cells, 3, 5);
    const E = events.Events(spec);
    try testing.expectEqual(7, E.widget_count);
    try testing.expectEqualSlices(E.Widget, &.{ .files_h0, .files_r0, .files_h1, .files_r1, .files_h2, .files_r2, .files }, &.{ E.widget(0), E.widget(1), E.widget(2), E.widget(3), E.widget(4), E.widget(5), E.widget(6) });
    const v = comptime ct.fields(spec);
    try testing.expectEqualStrings("files", v.name);
    try testing.expectEqualStrings("table", v.state);
    try testing.expectEqualStrings("headers", v.headers);
    try testing.expectEqualStrings("cells", v.cells);
    try testing.expectEqual(3, v.cols);
    try testing.expectEqual(5, v.rows);
    // Table, header row, 3 x (header, label, mark, handle), body, 5 x (row + 3 x (cell, label)).
    try testing.expectEqual(2 + 12 + 1 + 35, flatten.count(spec));
}

test {
    std.testing.refAllDecls(@This());
    std.testing.refAllDecls(ct);
}
