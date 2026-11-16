//! Virtual list (tier 2): a list box over any number of options that builds only the rows on
//! screen (docs/TARGETS.md E1: cost scales with the screen, not with the data). Follows the
//! five-commit recipe of widgets/base.zig; the options, their look and their keys are the list
//! box's (widgets/list.zig), reused here.
//!
//! State lives in the application: the options (a slice of strings, any length), the selected
//! row (`u32`, `none` for no selection) and the scroll offset (`f32`, logical pixels from the
//! top). The list shows `visible` rows. Because every row has the same height, the first row
//! on screen is `floor(scroll / rowHeight)` and at most `visible + 1` rows are built, by index
//! arithmetic (as Xilem's virtual_scroll asks the app only for the indices in view); the
//! container is clipped and scrolled by the remainder.
//!
//! In the comptime front end the rows on screen are a bounded dynamic region: the spec holds
//! `visible + 1` template rows, so capacity is exact, and each frame fills as many as the
//! scroll position shows from the options slice in the state.

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
const Style = types.Style;
const Response = types.Response;
const none = types.none;

// ---- spec ------------------------------------------------------------------------------------

/// Why `State` cannot back a comptime virtual list with options field `items`, selection field
/// `selected` and scroll field `scroll`, showing `visible` rows; null when it can. `validate`
/// turns the answer into a compile error; tests read it directly.
pub fn check(comptime State: type, comptime items: []const u8, comptime selected: []const u8, comptime scroll: []const u8, comptime visible: u32) ?[]const u8 {
    comptime {
        if (visible == 0) return "vlist: a virtual list shows at least one row";
        if (!@hasField(State, items)) return "vlist: state has no field '" ++ items ++ "' for the options";
        if (@FieldType(State, items) != []const []const u8) return "vlist: options field '" ++ items ++ "' must be a []const []const u8";
        if (!@hasField(State, selected)) return "vlist: state has no field '" ++ selected ++ "' for the selection";
        if (@FieldType(State, selected) != u32) return "vlist: selection field '" ++ selected ++ "' must be a u32 (a row, or none)";
        if (!@hasField(State, scroll)) return "vlist: state has no field '" ++ scroll ++ "' for the scroll offset";
        if (@FieldType(State, scroll) != f32) return "vlist: scroll field '" ++ scroll ++ "' must be an f32 (pixels from the top)";
        return null;
    }
}

/// `check` as a compile error.
pub fn validate(comptime State: type, comptime items: []const u8, comptime selected: []const u8, comptime scroll: []const u8, comptime visible: u32) void {
    if (comptime check(State, items, selected, scroll, visible)) |msg| @compileError(msg);
}

/// Rows built for a list showing `visible` rows: one more, for the row half scrolled in at the
/// bottom while another is half scrolled out at the top.
pub fn capacity(visible: u32) u32 {
    return visible + 1;
}

/// The rows on screen: the first one and how many, for `count` options scrolled by `scroll`.
pub const Window = struct { first: u32, len: u32 };

pub fn window(th: *const Theme, count: u32, visible: u32, scroll: f32) Window {
    const first: u32 = @min(@as(u32, @intFromFloat(@max(scroll, 0) / list_zig.rowHeight(th))), count);
    return .{ .first = first, .len = @min(capacity(visible), count - first) };
}

// ---- comptime front end ---------------------------------------------------------------------

pub const ct = struct {
    /// A virtual list named `id` over the options field `items` ([]const []const u8), selecting
    /// into the u32 field `selected`, scrolled by the f32 field `scroll`, `visible` rows tall.
    /// The spec holds `capacity(visible)` template rows; each binds the scroll field (scrolling
    /// changes which option it shows) and holds a label bound to the options.
    pub fn vlist(comptime th: Theme, comptime id: @EnumLiteral(), comptime items: @EnumLiteral(), comptime selected: @EnumLiteral(), comptime scroll: @EnumLiteral(), comptime visible: u32) Spec {
        var rows: [capacity(visible)]Spec = undefined;
        for (&rows) |*o| {
            o.* = spec_zig.row(list_zig.optionStyle(&th), .{base.ct.label(th, items)});
            o.bind = @tagName(scroll);
        }
        var s = spec_zig.col(list_zig.listStyle(&th), rows);
        s.id = @tagName(id);
        s.bind = @tagName(selected);
        return s;
    }

    /// The fields and row count a `ct.vlist` node was built with.
    pub fn fields(comptime n: Spec) struct { items: []const u8, selected: []const u8, scroll: []const u8, visible: u32 } {
        return .{ .items = n.children[0].children[0].bind.?, .selected = n.bind.?, .scroll = n.children[0].bind.?, .visible = n.children.len - 1 };
    }
};

// ---- tests ----------------------------------------------------------------------------------

const testing = std.testing;
const theme: Theme = .default;
const Replay = @import("../core/input.zig").Replay;

test "check: what a comptime virtual list's state must have" {
    const Good = struct { o: []const []const u8 = &.{}, sel: u32 = none, sc: f32 = 0 };
    const Bad = struct { o: []const u8 = "", sel: f32 = 0, sc: u32 = 0 };
    try testing.expectEqual(null, comptime check(Good, "o", "sel", "sc", 4));
    try testing.expectEqualStrings("vlist: a virtual list shows at least one row", comptime check(Good, "o", "sel", "sc", 0).?);
    try testing.expectEqualStrings("vlist: state has no field 'x' for the options", comptime check(Good, "x", "sel", "sc", 4).?);
    try testing.expectEqualStrings("vlist: options field 'o' must be a []const []const u8", comptime check(Bad, "o", "sel", "sc", 4).?);
    try testing.expectEqualStrings("vlist: selection field 'sel' must be a u32 (a row, or none)", comptime check(struct { o: []const []const u8 = &.{}, sel: f32 = 0 }, "o", "sel", "sc", 4).?);
    try testing.expectEqualStrings("vlist: state has no field 'sc' for the scroll offset", comptime check(struct { o: []const []const u8 = &.{}, sel: u32 = 0 }, "o", "sel", "sc", 4).?);
    try testing.expectEqualStrings("vlist: scroll field 'sc' must be an f32 (pixels from the top)", comptime check(struct { o: []const []const u8 = &.{}, sel: u32 = 0, sc: u32 = 0 }, "o", "sel", "sc", 4).?);
}

test "ct.vlist: capacity(visible) template rows, whatever the option count" {
    const spec = comptime ct.vlist(theme, .items, .options, .selected, .scroll, 5);
    try testing.expectEqual(6, spec.children.len);
    const v = comptime ct.fields(spec);
    try testing.expectEqualStrings("options", v.items);
    try testing.expectEqualStrings("selected", v.selected);
    try testing.expectEqualStrings("scroll", v.scroll);
    try testing.expectEqual(5, v.visible);
    // 1 list + 6 x (row + label): fixed, so the comptime page's capacity is exact.
    try testing.expectEqual(13, flatten.count(spec));
}

test "window: the rows on screen by index arithmetic" {
    const h = list_zig.rowHeight(&theme);
    try testing.expectEqual(Window{ .first = 0, .len = 6 }, window(&theme, 200, 5, 0));
    try testing.expectEqual(Window{ .first = 2, .len = 6 }, window(&theme, 200, 5, 2.5 * h));
    try testing.expectEqual(Window{ .first = 195, .len = 5 }, window(&theme, 200, 5, 195 * h));
    try testing.expectEqual(Window{ .first = 0, .len = 3 }, window(&theme, 3, 5, 0));
    try testing.expectEqual(Window{ .first = 0, .len = 0 }, window(&theme, 0, 5, 0));
    try testing.expectEqual(Window{ .first = 0, .len = 6 }, window(&theme, 200, 5, -10));
}

test {
    std.testing.refAllDecls(@This());
    std.testing.refAllDecls(ct);
}
