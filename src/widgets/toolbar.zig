//! Toolbar (tier 2): a row of buttons that is one stop in the tab order. Which button holds
//! that stop is application state (`current`, a `u32`), as is the button activated this
//! frame (`activated`, a `u32`, `none` for none). Written against the public API of tiers 0
//! and 1 (src/widgets/base.zig has the recipe).
//!
//! Runtime: `toolbar.bar(f, th, &ids, &titles, &current)` returns the activated button.
//! Comptime: `toolbar.ct.toolbar(th, .current, .activated, .{ .{ .id, .title }, ... })`.

const std = @import("std");
const base = @import("base.zig");
const types = @import("../core/types.zig");
const Frame = @import("../runtime/frame.zig").Frame;
const Input = @import("../core/input.zig").Input;
const spec_zig = @import("../comptime/spec.zig");
const Spec = spec_zig.Spec;
const Style = types.Style;
const Id = types.Id;
const Theme = base.Theme;
const none = types.none;

// ---- spec ---------------------------------------------------------------------------------

/// A toolbar of one button per title: button `k` has the identity `ids[k]` and shows
/// `titles[k]`. `current.*` (the button that is the toolbar's tab stop) is clamped into
/// range. Returns the index of the button activated this frame, or `none`.
pub fn bar(f: *Frame, th: *const Theme, ids: []const Id, titles: []const []const u8, current: *u32) u32 {
    std.debug.assert(ids.len == titles.len and ids.len > 0);
    current.* = @min(current.*, @as(u32, @intCast(ids.len - 1)));
    _ = f.open(.none, barStyle(th));
    for (ids, titles) |id, title| {
        _ = f.open(id, itemStyle(th));
        _ = base.label(f, th, title);
        f.close();
    }
    f.close();
    return none;
}

/// The bar: its buttons side by side.
pub fn barStyle(th: *const Theme) Style {
    _ = th;
    return .{ .dir = .x };
}

/// One button.
pub fn itemStyle(th: *const Theme) Style {
    _ = th;
    return .{ .dir = .x, .cross = .center };
}

/// The toolbar as a spec node.
pub const ct = struct {
    /// A toolbar whose tab stop is the u32 field `current` and which writes the button it
    /// activates each frame to the u32 field `activated` (`none` for none). `items` is a
    /// tuple of `.{ id, title }`: the button's widget name and the string field it shows.
    /// Mistakes are compile errors: no items, an item without two parts, or fields of the
    /// wrong type.
    pub fn toolbar(comptime th: Theme, comptime current: @EnumLiteral(), comptime activated: @EnumLiteral(), comptime items: anytype) Spec {
        if (items.len == 0) @compileError("toolbar over '" ++ @tagName(current) ++ "' has no buttons");
        var kids: [items.len]Spec = undefined;
        var names: [items.len][:0]const u8 = undefined;
        for (items, &kids, &names) |it, *k, *name| {
            if (it.len != 2) @compileError("a toolbar button is .{ id, title }");
            k.* = spec_zig.row(itemStyle(&th), .{base.ct.label(th, it[1])});
            k.id = @tagName(it[0]);
            name.* = @tagName(it[0]);
        }
        const final_names = names;
        var s = spec_zig.row(barStyle(&th), kids);
        s.widget = Toolbar(@tagName(current), @tagName(activated), &final_names);
        return s;
    }

    /// How the comptime front end builds and drives one toolbar.
    fn Toolbar(comptime current: []const u8, comptime activated: []const u8, comptime names: []const [:0]const u8) type {
        return struct {
            /// Clamps `current`; nothing is activated yet.
            pub fn step(ui: anytype, comptime row: u32, event: anytype, in: *const Input) void {
                _ = row;
                _ = event;
                _ = in;
                const U = @TypeOf(ui.*);
                const cur: u32 = @field(ui.signals.state, current);
                ui.signals.set(comptime U.field(current), @min(cur, names.len - 1));
                ui.signals.set(comptime U.field(activated), none);
            }

            pub fn push(ui: anytype, comptime n: Spec, parent: u32, next: *u32, in: *const Input) void {
                const t = &ui.tables.t;
                const row = t.push(parent, .none, &n.style);
                next.* += 1;
                inline for (n.children, names) |item, name| {
                    const i = t.push(row, .hash(name), &item.style);
                    next.* += 1;
                    ui.push(item.children[0], i, next, in);
                    t.seal(i);
                }
                t.seal(row);
            }
        };
    }
};

// ---- tests --------------------------------------------------------------------------------

const testing = std.testing;

/// A toolbar of Bold, Italic and Underline above a checkbox.
fn Page(comptime th: Theme) type {
    const column: Style = .{ .dir = .y, .pad = @splat(8), .gap = 8 };
    return struct {
        pub const ids = [_]Id{ .from("bold"), .from("italic"), .from("under") };
        pub const App = struct {
            current: u32 = 0,
            activated: u32 = none,
            wire: bool = false,
            pub fn build(app: *App, f: *Frame) void {
                _ = f.open(.none, column);
                app.activated = bar(f, &th, &ids, &.{ "Bold", "Italic", "Underline" }, &app.current);
                _ = base.checkbox(f, &th, .from("wire"), &app.wire, "Wireframe");
                f.close();
            }
        };
        pub const State = struct {
            current: u32 = 0,
            activated: u32 = none,
            bold_text: []const u8 = "Bold",
            italic_text: []const u8 = "Italic",
            under_text: []const u8 = "Underline",
            wire: bool = false,
            wire_text: []const u8 = "Wireframe",
        };
        pub const spec = spec_zig.col(column, .{
            ct.toolbar(th, .current, .activated, .{ .{ .bold, .bold_text }, .{ .italic, .italic_text }, .{ .under, .under_text } }),
            base.ct.checkbox(th, .wire, .wire, .wire_text),
        });
        pub const Ui = base.ComptimeUi(State, spec, th);
        pub const Run = base.Harness(App, Ui, .{ .nodes = 32, .texts = 8, .customs = 1, .strings = 256, .depth = 8 });
    };
}

const Default = Page(.default);
var harness: Default.Run = .{};

/// Tree rows: root 0, column 1, bar 2, buttons 3/5/7 (labels after each), checkbox 9..11.
const rows = struct {
    const bar = 2;
    const item = [3]u32{ 3, 5, 7 };
};

test "toolbar: both front ends build one row of buttons" {
    const h = &harness;
    h.init();
    const in: Input = .{ .viewport = .{ 320, 200 } };
    const out = try h.frame(&in);
    const t = out.runtime.tree;
    try testing.expectEqual(@as(u32, 12), t.len);
    for (rows.item, Default.ids) |r, id| try testing.expectEqual(r, t.find(id));
    try testing.expect(t.rect(rows.item[1]).x0 >= t.rect(rows.item[0]).x1);
    try testing.expectEqual(none, h.app.activated);
    try testing.expectEqual(none, h.ui.signals.state.activated);
}

test {
    std.testing.refAllDecls(@This());
    std.testing.refAllDecls(ct);
}
