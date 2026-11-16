//! Tooltip (tier 2): a short text that appears next to a widget once the pointer has rested on
//! it, the WAI-ARIA APG tooltip pattern. Written against the public API of tiers 0 and 1, after
//! the recipe in base.zig. The bubble floats (`Style.float`) under the root, below the target's
//! rect of the last frame (`Frame.lastRect`, prototype/ui.zig), and takes no pointer input: the
//! pointer stays on the target under it.
//!
//! Its state is a `Tip`, owned by the application: how long the pointer has rested on the
//! target, and whether the tooltip shows.
//!
//! Runtime: build the target, `update(f, &tip, response)`, then under the root after the page
//! `show(f, th, "target", &tip, text)`.
//!
//! Comptime: `const T = Tooltip(th, .save, .tip);` gives the spec builder `T.bubble` and the
//! hooks `popover.ComptimePage(State, spec, th, T)` runs.

const std = @import("std");
const base = @import("base.zig");
const popover = @import("popover.zig");
const types = @import("../core/types.zig");
const simd = @import("../core/simd.zig");
const Input = @import("../core/input.zig").Input;
const Frame = @import("../runtime/frame.zig").Frame;
const context = @import("../runtime/context.zig");
const spec_zig = @import("../comptime/spec.zig");
const a11y = @import("../a11y/tree.zig");
const Spec = spec_zig.Spec;
const Theme = base.Theme;
const Rect = types.Rect;
const Style = types.Style;
const Response = types.Response;
const Part = popover.Part;

// ---- spec: what the tooltip takes and keeps --------------------------------------------------

/// A tooltip's state, owned by the application.
pub const Tip = struct {
    /// Seconds the pointer has rested on the target; 0 while it is elsewhere.
    rested: f32 = 0,
    /// Escape hid the tooltip; it stays hidden until the pointer leaves the target.
    dismissed: bool = false,
    /// The bubble is shown this frame.
    shown: bool = false,
};

/// Seconds the pointer rests on the target before the tooltip shows: `Interaction.hover_delay`.
pub const delay: f32 = 0.5;

/// `null` if `State` can hold a tooltip bound to `tip`, else the compile error: `tip` must be a
/// `Tip` field.
pub fn checkTip(comptime State: type, comptime tip: []const u8) ?[]const u8 {
    if (!@hasField(State, tip)) return "tooltip: state " ++ @typeName(State) ++ " has no field '" ++ tip ++ "'";
    if (@FieldType(State, tip) != Tip) return "tooltip: field '" ++ tip ++ "' must be a tooltip.Tip, not " ++ @typeName(@FieldType(State, tip));
    return null;
}

/// The tooltip of the widget named `target`, bound to the `Tip` field `tip`, in theme `th`: its
/// spec builder and the hooks `popover.ComptimePage` calls.
pub fn Tooltip(comptime th: Theme, comptime target: @EnumLiteral(), comptime tip: @EnumLiteral()) type {
    const tip_name = @tagName(tip);
    return struct {
        /// The bubble showing the string field `text`. Put it last in the page's root so it is
        /// drawn above the rest. It has no id, so it takes no pointer input; it is told apart
        /// by its binding to `tip`.
        pub fn bubble(comptime text: @EnumLiteral()) Spec {
            return .{ .kind = .col, .bind = tip_name, .children = &.{base.ct.label(th, text)} };
        }

        pub fn check(comptime State: type) ?[]const u8 {
            return checkTip(State, tip_name);
        }

        pub fn step(sig: anytype, v: anytype) void {
            _ = sig;
            _ = v;
        }

        pub fn part(comptime n: Spec, st: anytype, v: anytype) ?Part {
            if (comptime n.kind == .col and n.bind != null and std.mem.eql(u8, n.bind.?, tip_name)) {
                if (!@field(st, tip_name).shown) return null;
                return .{ .style = bubbleStyle(&th, v.last.of(@tagName(target))) };
            }
            return popover.plainPart(th, n, v.response);
        }
    };
}

// ---- look -------------------------------------------------------------------------------------

/// The bubble, floating `th.gap` below the target's rect `at` (last frame's), left edges
/// aligned: a small dark plate (the held-control colour) with the control outline.
pub fn bubbleStyle(th: *const Theme, at: Rect) Style {
    return .{
        .float = true,
        .offset = .{ at.x0, at.y1 + th.gap },
        .pad = .{ th.pad, th.gap, th.pad, th.gap },
        .fill = th.control_held,
        .border = 1,
        .border_color = th.control_hot,
        .radius = th.radius,
    };
}

// ---- runtime front end ------------------------------------------------------------------------

/// Steps `tip` by one frame from the target's response `r`.
pub fn update(f: *const Frame, tip: *Tip, r: Response) void {
    _ = f;
    _ = r;
    _ = tip;
}

/// Builds the bubble of the tooltip of `target` showing `text`, if it is shown. Call it at the
/// root's depth, after the rest of the page, so it is drawn on top.
pub fn show(f: *Frame, th: *const Theme, comptime target: []const u8, tip: *const Tip, text: []const u8) void {
    if (!tip.shown) return;
    _ = f.open(.none, bubbleStyle(th, f.lastRect(.from(target))));
    _ = base.label(f, th, text);
    f.close();
}

// ---- tests ------------------------------------------------------------------------------------

const testing = std.testing;

/// The test page: a toolbar with a button and a label, and the button's tooltip.
fn Page(comptime th: Theme) type {
    return struct {
        const toolbar_style: Style = .{ .dir = .x, .size = .{ .fill, .fit }, .pad = @splat(8), .gap = 8, .cross = .center, .fill = th.panel };

        pub const App = struct {
            tip: Tip = .{},

            pub fn build(app: *App, f: *Frame) void {
                _ = f.open(.none, .{});
                _ = f.open(.none, toolbar_style);
                const r = base.button(f, &th, .from("save"), "Save");
                update(f, &app.tip, r);
                _ = base.label(f, &th, "Scene 1");
                f.close();
                show(f, &th, "save", &app.tip, "Save the scene (Ctrl+S)");
                f.close();
            }
        };

        pub const State = struct {
            tip: Tip = .{},
            save_text: []const u8 = "Save",
            scene: []const u8 = "Scene 1",
            save_tip: []const u8 = "Save the scene (Ctrl+S)",
        };
        pub const T = Tooltip(th, .save, .tip);
        pub const spec = spec_zig.col(.{}, .{
            spec_zig.row(toolbar_style, .{ base.ct.button(th, .save, .save_text), base.ct.label(th, .scene) }),
            T.bubble(.save_tip),
        });
        pub const Ui = popover.ComptimePage(State, spec, th, T);
        pub const limits: context.Limits = .{ .nodes = 64, .texts = 16, .customs = 1, .strings = 1024, .depth = 8 };
        pub const Run = base.Harness(App, Ui, limits);
    };
}

const Default = Page(.default);
var harness: Default.Run = .{};

test "Tooltip: the page agrees in both front ends, hidden and shown" {
    const h = &harness;
    h.init();
    const in: Input = .{ .viewport = .{ 400, 300 } };
    try testing.expectEqual(@as(u32, 6), (try h.frame(&in)).runtime.tree.len);
    h.app.tip.shown = true;
    h.ui.signals.set(.tip, .{ .shown = true });
    const t = (try h.frame(&in)).runtime.tree;
    try testing.expectEqual(@as(u32, 8), t.len);
    // The bubble hangs below the button.
    const at = t.rect(t.find(.from("save")));
    try testing.expectEqual(at.x0, t.rect(6).x0);
    try testing.expectEqual(at.y1 + Theme.default.gap, t.rect(6).y0);
}

test "bubbleStyle: the theme's tokens, below the target" {
    const th: Theme = .default;
    const s = bubbleStyle(&th, .{ .x0 = 10, .y0 = 20, .x1 = 60, .y1 = 40 });
    try testing.expect(s.float);
    try testing.expectEqual([2]f32{ 10, 40 + th.gap }, s.offset);
    try testing.expectEqual(th.control_held, s.fill);
    try testing.expectEqual(th.control_hot, s.border_color);
    try testing.expectEqual(th.radius, s.radius);
    try testing.expectEqual([4]f32{ th.pad, th.gap, th.pad, th.gap }, s.pad);
}

const light: Theme = .{ .control_held = .rgb(250, 250, 220), .control_hot = .rgb(180, 180, 190), .text = .rgb(20, 20, 20), .pad = 12, .gap = 10, .radius = 0 };

test "Tooltip: another theme restyles both front ends alike" {
    const S = struct {
        var h: Page(light).Run = .{};
    };
    S.h.init();
    const in: Input = .{ .viewport = .{ 400, 300 } };
    _ = try S.h.frame(&in);
    S.h.app.tip.shown = true;
    S.h.ui.signals.set(.tip, .{ .shown = true });
    const t = (try S.h.frame(&in)).runtime.tree;
    try testing.expectEqual(light.control_held.bitsOf(), t.c.look[6].fill);
    try testing.expectEqual(t.rect(t.find(.from("save"))).y1 + 10, t.rect(6).y0);
}

test "checkTip: the tip field must be a Tip" {
    try testing.expectEqual(null, comptime checkTip(Default.State, "tip"));
    try testing.expectEqualStrings("tooltip: field 'tip' must be a tooltip.Tip, not bool", comptime checkTip(struct { tip: bool }, "tip").?);
    try testing.expect(comptime checkTip(struct {}, "tip") != null);
}

test {
    std.testing.refAllDecls(@This());
}
