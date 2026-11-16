//! List box (tier 2): a column of options, one of them selected, in both front ends. Follows the
//! five-commit recipe of widgets/base.zig and is written against the public API of tiers 0 and 1
//! only.
//!
//! State lives in the application: the options (strings) and the selected row (`u32`, `none` for
//! no selection). Every option row has the same height (`rowHeight`), so the row under the
//! pointer is index arithmetic on the list's last rect, not a hit test per row.
//!
//! The comptime side (`ct.list`, `ComptimeList`) also carries the shared comptime page this
//! file's sibling widgets (vlist, table, tree, progress, spinner, colorpicker) build on:
//! `CtFrame`, the comptime front end's tables and `Frame.end`'s pass sequence, and
//! `CtPointer`, hover, hold and focus exactly as the runtime front end's `Interaction` reports
//! them.

const std = @import("std");
const types = @import("../core/types.zig");
const simd = @import("../core/simd.zig");
const mem = @import("../core/mem.zig");
const Tree = @import("../core/tree.zig").Tree;
const Texts = @import("../core/texts.zig").Texts;
const Customs = @import("../core/customs.zig").Customs;
const Strings = @import("../core/strings.zig").Strings;
const Input = @import("../core/input.zig").Input;
const DrawList = @import("../draw/draw_list.zig").DrawList;
const paint = @import("../draw/paint.zig");
const layout = @import("../layout/layout.zig");
const Mono = @import("../text/protocol.zig").Mono;
const Frame = @import("../runtime/frame.zig").Frame;
const context = @import("../runtime/context.zig");
const spec_zig = @import("../comptime/spec.zig");
const events = @import("../comptime/events.zig");
const signals = @import("../comptime/signals.zig");
const flatten = @import("../comptime/flatten.zig");
const a11y = @import("../a11y/tree.zig");
const Keymap = @import("../interact/focus.zig").Keymap;
const base = @import("base.zig");
const Spec = spec_zig.Spec;
const Theme = base.Theme;
const Id = types.Id;
const Color = types.Color;
const Style = types.Style;
const Response = types.Response;
const none = types.none;

// ---- spec ------------------------------------------------------------------------------------

/// Why `State` cannot back a comptime list bound to `selected` with option fields `items`, or
/// null when it can. `validate` turns the answer into a compile error; tests read it directly.
pub fn check(comptime State: type, comptime selected: []const u8, comptime items: []const []const u8) ?[]const u8 {
    comptime {
        if (!@hasField(State, selected)) return "list: state has no field '" ++ selected ++ "' for the selection";
        if (@FieldType(State, selected) != u32) return "list: selection field '" ++ selected ++ "' must be a u32 (a row, or none)";
        if (items.len == 0) return "list: a list needs at least one option";
        for (items) |f| {
            if (!@hasField(State, f)) return "list: state has no field '" ++ f ++ "' for an option";
            if (@FieldType(State, f) != []const u8) return "list: option field '" ++ f ++ "' must be a []const u8";
        }
        return null;
    }
}

/// `check` as a compile error.
pub fn validate(comptime State: type, comptime selected: []const u8, comptime items: []const []const u8) void {
    if (comptime check(State, selected, items)) |msg| @compileError(msg);
}

// ---- look: one function per part, called by both front ends -------------------------------

/// Height of every option row: one line of text and the theme's padding above and below.
pub fn rowHeight(th: *const Theme) f32 {
    return th.text_px + 2 * th.pad;
}

/// Inset of the option rows inside the list's border.
pub fn inset(th: *const Theme) f32 {
    _ = th;
    return 2;
}

pub fn listStyle(th: *const Theme) Style {
    return .{
        .dir = .y,
        .min = .{ 120, 0 },
        .pad = @splat(inset(th)),
        .role = .group,
    };
}

pub fn optionStyle(th: *const Theme) Style {
    return .{
        .dir = .x,
        .size = .{ .fill, .px(rowHeight(th)) },
        .pad = .{ th.pad, 0, th.pad, 0 },
        .cross = .center,
    };
}

// ---- comptime front end ---------------------------------------------------------------------

pub const ct = struct {
    /// A list named `id` selecting into the u32 field `selected`, one option per string field
    /// in `items` (a tuple of enum literals): `ct.list(th, .fruit, .selected, .{ .apple, .pear })`.
    pub fn list(comptime th: Theme, comptime id: @EnumLiteral(), comptime selected: @EnumLiteral(), comptime items: anytype) Spec {
        var opts: [items.len]Spec = undefined;
        for (&opts, items) |*o, item| o.* = spec_zig.row(optionStyle(&th), .{base.ct.label(th, item)});
        var s = spec_zig.col(listStyle(&th), opts);
        s.id = @tagName(id);
        s.bind = @tagName(selected);
        return s;
    }
};

/// The option fields of the list node `n` (built by `ct.list`): each option row's label binding.
pub fn itemFields(comptime n: Spec) [n.children.len][]const u8 {
    var out: [n.children.len][]const u8 = undefined;
    for (&out, n.children) |*o, c| o.* = c.children[0].bind.?;
    return out;
}

/// The spec node at depth-first row `row` of `n`.
pub fn nodeAt(comptime n: Spec, comptime row: comptime_int) Spec {
    comptime {
        var i = 0;
        return nodeWalk(n, row, &i).?;
    }
}

fn nodeWalk(comptime n: Spec, comptime row: comptime_int, comptime next: *comptime_int) ?Spec {
    if (next.* == row) return n;
    next.* += 1;
    for (n.children) |c| if (nodeWalk(c, row, next)) |r| return r;
    return null;
}

// ---- tests ----------------------------------------------------------------------------------

const testing = std.testing;
const theme: Theme = .default;
const Replay = @import("../core/input.zig").Replay;

test "check: what a comptime list's state must have" {
    const Good = struct { sel: u32 = none, a: []const u8 = "A", b: []const u8 = "B" };
    const Bad = struct { sel: i32 = 0, a: u8 = 0 };
    try testing.expectEqual(null, comptime check(Good, "sel", &.{ "a", "b" }));
    try testing.expectEqualStrings("list: state has no field 'x' for the selection", comptime check(Good, "x", &.{"a"}).?);
    try testing.expectEqualStrings("list: selection field 'sel' must be a u32 (a row, or none)", comptime check(Bad, "sel", &.{"a"}).?);
    try testing.expectEqualStrings("list: a list needs at least one option", comptime check(Good, "sel", &.{}).?);
    try testing.expectEqualStrings("list: state has no field 'c' for an option", comptime check(Good, "sel", &.{ "a", "c" }).?);
    const Bad2 = struct { sel: u32 = 0, a: u8 = 0 };
    try testing.expectEqualStrings("list: option field 'a' must be a []const u8", comptime check(Bad2, "sel", &.{"a"}).?);
}

test "ct.list: one widget, a column of option rows each holding a label" {
    const spec = comptime spec_zig.col(.{}, .{
        base.ct.label(theme, .title),
        ct.list(theme, .fruit, .selected, .{ .apple, .banana, .cherry, .damson, .elder }),
    });
    const E = events.Events(spec);
    try testing.expectEqual(1, E.widget_count);
    try testing.expectEqual(@as(usize, 2), @backingInt(E.Widget.fruit));
    const n = comptime nodeAt(spec, 2);
    try testing.expectEqual(5, n.children.len);
    try testing.expectEqualStrings("selected", n.bind.?);
    try testing.expectEqualStrings("cherry", (comptime itemFields(n))[2]);
    try testing.expectEqual(rowHeight(&theme), n.children[0].style.size[1].v);
    // 1 column + 1 caption + 1 list + 5 x (row + label).
    try testing.expectEqual(13, flatten.count(spec));
}

test {
    std.testing.refAllDecls(@This());
    std.testing.refAllDecls(ct);
}
