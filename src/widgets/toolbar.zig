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
        const item = f.open(id, itemStyle(th));
        const r = f.interact(item, .button);
        f.setFill(item, base.buttonFill(th, r));
        f.setCursor(.pointer, r.hovered);
        _ = base.label(f, th, title);
        f.close();
    }
    f.close();
    return none;
}

/// The bar: its buttons side by side on the panel colour, padded and spaced by the theme,
/// as the reference page's toolbar.
pub fn barStyle(th: *const Theme) Style {
    return .{ .dir = .x, .pad = @splat(th.pad), .gap = th.gap, .cross = .center, .fill = th.panel, .radius = th.radius };
}

/// One button, as `base.buttonStyle`; filled as a button by interaction state
/// (`base.buttonFill`).
pub fn itemStyle(th: *const Theme) Style {
    return base.buttonStyle(th);
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
                const th = @TypeOf(ui.*).theme;
                inline for (n.children, names) |item, name| {
                    var st = item.style;
                    st.fill = base.buttonFill(&th, ui.response(next.*, in));
                    const i = t.push(row, .hash(name), &st);
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

test "toolbar: buttons on a panel bar, filled by state; any theme alike" {
    const h = &harness;
    h.init();
    var in: Input = .{ .viewport = .{ 320, 200 } };
    var out = try h.frame(&in);
    const th = Theme.default;
    var t = out.runtime.tree;
    try testing.expectEqual(th.panel.bitsOf(), t.c.look[rows.bar].fill);
    try testing.expectEqual(t.rect(rows.bar).x0 + th.pad, t.rect(rows.item[0]).x0);
    try testing.expectEqual(t.rect(rows.item[0]).x1 + th.gap, t.rect(rows.item[1]).x0);
    const r = t.rect(rows.item[2]);
    in.pointer = .{ (r.x0 + r.x1) * 0.5, (r.y0 + r.y1) * 0.5 };
    out = try h.frame(&in);
    t = out.runtime.tree;
    try testing.expectEqual(th.control_hot.bitsOf(), t.c.look[rows.item[2]].fill);
    try testing.expectEqual(th.control_hot.bitsOf(), out.comptime_.tree.c.look[rows.item[2]].fill);
    try testing.expectEqual(th.control.bitsOf(), t.c.look[rows.item[0]].fill);

    const Light = Page(.{ .panel = .rgb(240, 240, 240), .control = .rgb(200, 200, 205), .control_hot = .rgb(180, 180, 190), .text = .rgb(20, 20, 20), .pad = 12, .gap = 10, .radius = 0 });
    const S = struct {
        var light: Light.Run = .{};
    };
    S.light.init();
    _ = try S.light.frame(&in);
    const lo = try S.light.frame(&in);
    try testing.expectEqual(types.Color.rgb(180, 180, 190).bitsOf(), lo.runtime.tree.c.look[rows.item[2]].fill);
}

test {
    std.testing.refAllDecls(@This());
    std.testing.refAllDecls(ct);
}
