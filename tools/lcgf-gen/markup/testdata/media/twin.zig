//! media, written by hand: `@media` around a rule that styles a recipe widget is the rule's
//! environment conditions (`Rule.when`), matched against the viewport each frame. Nested
//! queries combine; `screen` and `and` add nothing; `orientation: portrait` holds on a
//! viewport at least as tall as it is wide.

const std = @import("std");
const lcgf = @import("lcgf");
const s = lcgf.spec;
const w = lcgf.widgets_base;
const recipes = lcgf.theme_recipes;
const style = lcgf.style;
const Frame = lcgf.frame.Frame;
const Color = lcgf.types.Color;

pub const theme: w.Theme = .{};

const wide: Color = .rgb(58, 60, 70);
const narrow: Color = .rgb(192, 80, 48);
const gold: Color = .rgb(255, 208, 64);

const recipe_tokens: style.tokens.Table = .{ .scopes = &.{.{ .entries = &recipes.model.tokenRows(.{
    .palette = .{ theme.text, theme.panel, theme.control, theme.control_hot, theme.control_held, theme.accent },
    .space = .{ 2, 4, theme.gap, theme.pad, 12 },
    .radius = .{ 0, 2, theme.radius, 6, 8 },
    .text_size = .{ 11, 12, theme.text_px, 18, 24 },
}, .{}) }} };

const recipe_go: recipes.Recipe = .{ .parts = recipes.model.button.parts, .rules = &(recipes.model.button_rules ++ [_]style.Rule{
    .{ .part = style.Parts.root, .declarations = &.{style.set(.fill, wide)} },
    .{ .part = style.Parts.root, .when = .{ .width = .{ .max = 500 } }, .declarations = &.{style.set(.fill, narrow)} },
    .{ .part = style.Parts.root, .when = .{ .portrait = true }, .declarations = &.{ style.set(.border_color, .rgb(255, 255, 255)), style.set(.border_width, 1) } },
    .{ .part = style.Parts.root, .require = .{ .hovered = true }, .when = .{ .width = .{ .min = 501 }, .height = .{ .min = 300 } }, .declarations = &.{style.set(.text_color, gold)} },
}) };

const body: lcgf.types.Style = .{ .size = .{ .fill, .fill }, .fill = theme.panel };

pub const spec = s.col(body, .{
    recipes.ct.button(.go, "Go", .{ .recipe = recipe_go, .tokens = recipe_tokens }),
});

pub const limits: lcgf.context.Limits = .{ .nodes = 16, .texts = 4, .customs = 2, .strings = 256, .depth = 8 };

/// The same page in the runtime front end, for the draw lists.
pub const App = struct {
    pub fn build(_: *App, f: *Frame) void {
        _ = f.open(.none, body);
        _ = recipes.button(f, .from("go"), "Go", .{ .recipe = recipe_go, .tokens = recipe_tokens }) catch unreachable;
        f.close();
    }
};

/// Two viewports, each at rest and hovered.
pub const replay =
    \\frame
    \\viewport 800 600
    \\pointer 400 300
    \\frame
    \\pointer 14 14
    \\frame
    \\viewport 400 600
    \\frame
    \\pointer 400 300
    \\frame
;

pub fn Handlers(comptime Ui: type) type {
    return struct {
        pub fn go(_: *@This(), _: *Ui) void {}
    };
}

fn textColor(d: *const lcgf.draw_list.DrawList) u32 {
    return d.runs[0].color;
}

/// The face follows the viewport: wide at 800 px, narrow at 400; the hover rule's gold text
/// holds only on the wide viewport.
pub fn events(comptime page: type, p: anytype, h: anytype) !void {
    _ = page;
    var in: lcgf.input.Input = .{ .viewport = .{ 800, 600 } };
    var out = p.frame(h, &in);
    const go = out.tree.find(.from("go"));
    try std.testing.expectEqual(wide.bitsOf(), out.tree.c.look[go].fill);
    const r = out.tree.rect(go);
    in.pointer = .{ (r.x0 + r.x1) / 2, (r.y0 + r.y1) / 2 };
    out = p.frame(h, &in);
    try std.testing.expectEqual(gold.bitsOf(), textColor(out.draw));
    in.viewport = .{ 400, 600 };
    out = p.frame(h, &in);
    try std.testing.expectEqual(narrow.bitsOf(), out.tree.c.look[go].fill);
    try std.testing.expect(textColor(out.draw) != gold.bitsOf());
    try std.testing.expectEqual(@as(u32, 0xffffffff), out.tree.c.look[go].border_color);
}
