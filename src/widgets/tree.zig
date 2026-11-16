//! Tree view (tier 2): an outline of items, each at a depth, whose parents expand and collapse,
//! in both front ends. Follows the five-commit recipe of widgets/base.zig and is written against
//! the public API of tiers 0 and 1 only.
//!
//! State lives in the application: the items in depth-first order as two parallel slices (the
//! label strings and each item's depth, a parent's children follow it one level deeper) and a
//! `State(n)` value (the selected item and which items are expanded). Only the rows of items
//! whose ancestors are all expanded are built; rows have the list box's fixed height, so the
//! row under the pointer is index arithmetic over the visible items.

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

/// What a tree view keeps between frames, owned by the application: the selected item (an
/// index into the items) and, per item, whether it is expanded (meaningful for parents).
pub fn State(comptime n: usize) type {
    return struct {
        selected: u32 = 0,
        expanded: [n]bool = @splat(false),
    };
}

/// Why `S` cannot back a comptime tree view bound to the state field `state`, with item labels
/// in `labels` and depths in `depths`, `n` items; null when it can.
pub fn check(comptime S: type, comptime state: []const u8, comptime labels: []const u8, comptime depths: []const u8, comptime n: u32) ?[]const u8 {
    comptime {
        if (n == 0) return "tree: a tree view has at least one item";
        if (!@hasField(S, state)) return "tree: state has no field '" ++ state ++ "' for the tree state";
        if (@FieldType(S, state) != State(n)) return std.fmt.comptimePrint("tree: field '{s}' must be a tree.State({d})", .{ state, n });
        if (!@hasField(S, labels)) return "tree: state has no field '" ++ labels ++ "' for the labels";
        if (@FieldType(S, labels) != []const []const u8) return "tree: labels field '" ++ labels ++ "' must be a []const []const u8";
        if (!@hasField(S, depths)) return "tree: state has no field '" ++ depths ++ "' for the depths";
        if (@FieldType(S, depths) != []const u8) return "tree: depths field '" ++ depths ++ "' must be a []const u8";
        return null;
    }
}

/// `check` as a compile error.
pub fn validate(comptime S: type, comptime state: []const u8, comptime labels: []const u8, comptime depths: []const u8, comptime n: u32) void {
    if (comptime check(S, state, labels, depths, n)) |msg| @compileError(msg);
}

/// Whether item `i` has children: the next item is deeper.
pub fn hasChildren(depths: []const u8, i: usize) bool {
    return i + 1 < depths.len and depths[i + 1] > depths[i];
}

/// Item `i`'s parent, or `none` at depth 0: the nearest earlier item one level up.
pub fn parentOf(depths: []const u8, i: u32) u32 {
    var j = i;
    while (j > 0) {
        j -= 1;
        if (depths[j] < depths[i]) return j;
    }
    return none;
}

/// The items whose ancestors are all expanded, in order, into `out`; returns how many. One pass:
/// below a collapsed item everything deeper is skipped.
pub fn visibleItems(depths: []const u8, expanded: []const bool, out: []u32) u32 {
    var len: u32 = 0;
    var hide_below: u16 = std.math.maxInt(u16);
    for (depths, expanded, 0..) |d, e, i| {
        if (d > hide_below) continue;
        hide_below = if (e) std.math.maxInt(u16) else d;
        out[len] = @intCast(i);
        len += 1;
    }
    return len;
}

/// Position of item `item` among the visible items, or `none` when it is hidden.
pub fn positionOf(visible: []const u32, item: u32) u32 {
    for (visible, 0..) |v, k| if (v == item) return @intCast(k);
    return none;
}

// ---- comptime front end ---------------------------------------------------------------------

pub const ct = struct {
    /// A tree view named `id` bound to the `State(n)` field `state`, over the `n` items of the
    /// fields `labels` ([]const []const u8) and `depths` ([]const u8). The spec holds `n` item
    /// rows, the most that can be visible, so capacity is exact; each binds the depths field and
    /// holds a mark and a label bound to the labels.
    pub fn tree(comptime th: Theme, comptime id: @EnumLiteral(), comptime state: @EnumLiteral(), comptime labels: @EnumLiteral(), comptime depths: @EnumLiteral(), comptime n: u32) Spec {
        var rows: [n]Spec = undefined;
        for (&rows) |*r| {
            r.* = spec_zig.row(.{}, .{ Spec{ .kind = .col }, base.ct.label(th, labels) });
            r.bind = @tagName(depths);
        }
        var s = spec_zig.col(.{}, rows);
        s.id = @tagName(id);
        s.bind = @tagName(state);
        return s;
    }

    /// The fields and item count a `ct.tree` node was built with.
    pub fn fields(comptime n: Spec) struct { state: []const u8, labels: []const u8, depths: []const u8, n: u32 } {
        return .{ .state = n.bind.?, .labels = n.children[0].children[1].bind.?, .depths = n.children[0].bind.?, .n = n.children.len };
    }
};

// ---- tests ----------------------------------------------------------------------------------

const testing = std.testing;
const theme: Theme = .default;
const Replay = @import("../core/input.zig").Replay;

const test_labels = [_][]const u8{ "src", "core", "tree.zig", "types.zig", "widgets", "list.zig", "docs", "DESIGN.md" };
const test_depths = [_]u8{ 0, 1, 2, 2, 1, 2, 0, 1 };

test "check: what a comptime tree view's state must have" {
    const Good = struct { st: State(3) = .{}, l: []const []const u8 = &.{}, d: []const u8 = &.{} };
    try testing.expectEqual(null, comptime check(Good, "st", "l", "d", 3));
    try testing.expectEqualStrings("tree: a tree view has at least one item", comptime check(Good, "st", "l", "d", 0).?);
    try testing.expectEqualStrings("tree: state has no field 'x' for the tree state", comptime check(Good, "x", "l", "d", 3).?);
    try testing.expectEqualStrings("tree: field 'st' must be a tree.State(4)", comptime check(Good, "st", "l", "d", 4).?);
    try testing.expectEqualStrings("tree: state has no field 'y' for the labels", comptime check(Good, "st", "y", "d", 3).?);
    try testing.expectEqualStrings("tree: labels field 'd' must be a []const []const u8", comptime check(Good, "st", "d", "d", 3).?);
    try testing.expectEqualStrings("tree: state has no field 'z' for the depths", comptime check(Good, "st", "l", "z", 3).?);
    try testing.expectEqualStrings("tree: depths field 'l' must be a []const u8", comptime check(Good, "st", "l", "l", 3).?);
}

test "ct.tree: one widget holding a row per item" {
    const spec = comptime ct.tree(theme, .outline, .outline, .labels, .depths, 8);
    try testing.expectEqual(1, events.Events(spec).widget_count);
    const v = comptime ct.fields(spec);
    try testing.expectEqualStrings("outline", v.state);
    try testing.expectEqualStrings("labels", v.labels);
    try testing.expectEqualStrings("depths", v.depths);
    try testing.expectEqual(8, v.n);
    try testing.expectEqual(1 + 8 * 3, flatten.count(spec));
}

test "visibleItems, parentOf, hasChildren: the outline's structure" {
    var out: [8]u32 = undefined;
    var e: [8]bool = @splat(false);
    try testing.expectEqualSlices(u32, &.{ 0, 6 }, out[0..visibleItems(&test_depths, &e, &out)]);
    e[0] = true;
    try testing.expectEqualSlices(u32, &.{ 0, 1, 4, 6 }, out[0..visibleItems(&test_depths, &e, &out)]);
    e[4] = true;
    try testing.expectEqualSlices(u32, &.{ 0, 1, 4, 5, 6 }, out[0..visibleItems(&test_depths, &e, &out)]);
    // An expanded item under a collapsed one stays hidden.
    e[0] = false;
    try testing.expectEqualSlices(u32, &.{ 0, 6 }, out[0..visibleItems(&test_depths, &e, &out)]);
    try testing.expectEqual(none, parentOf(&test_depths, 0));
    try testing.expectEqual(@as(u32, 1), parentOf(&test_depths, 3));
    try testing.expectEqual(@as(u32, 0), parentOf(&test_depths, 4));
    try testing.expectEqual(@as(u32, 6), parentOf(&test_depths, 7));
    try testing.expect(hasChildren(&test_depths, 1));
    try testing.expect(!hasChildren(&test_depths, 2));
    try testing.expect(!hasChildren(&test_depths, 7));
    try testing.expectEqual(@as(u32, 1), positionOf(&.{ 0, 6 }, 6));
    try testing.expectEqual(none, positionOf(&.{ 0, 6 }, 3));
}

test {
    std.testing.refAllDecls(@This());
    std.testing.refAllDecls(ct);
}
