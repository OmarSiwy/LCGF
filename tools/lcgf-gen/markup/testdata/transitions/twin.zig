//! transitions, written by hand: `transition` on a widget makes it a recipe widget that
//! eases its root (`controls.Transition`), its leg kept in a generated `<id>_fade` field;
//! Plain has no state CSS of its own, so the stock hover fill eases. On a box with state CSS
//! the transition eases the box. Both frontends step by the input's dt.

const std = @import("std");
const lcgf = @import("lcgf");
const s = lcgf.spec;
const w = lcgf.widgets_base;
const label = lcgf.widgets_label;
const recipes = lcgf.theme_recipes;
const style = lcgf.style;
const Fade = recipes.controls.Fade;
const Frame = lcgf.frame.Frame;
const Color = lcgf.types.Color;

pub const theme: w.Theme = .{};

pub const State = struct { go_fade: Fade = .{}, plain_fade: Fade = .{}, card_fade: Fade = .{} };

const recipe_tokens: style.tokens.Table = .{ .scopes = &.{.{ .entries = &recipes.model.tokenRows(.{
    .palette = .{ theme.text, theme.panel, theme.control, theme.control_hot, theme.control_held, theme.accent },
    .space = .{ 2, 4, theme.gap, theme.pad, 12 },
    .radius = .{ 0, 2, theme.radius, 6, 8 },
    .text_size = .{ 11, 12, theme.text_px, 18, 24 },
}, .{}) }} };

const hot: Color = .rgb(200, 100, 0);
const recipe_go: recipes.Recipe = .{ .parts = recipes.model.button.parts, .rules = &(recipes.model.button_rules ++ [_]style.Rule{
    .{ .part = style.Parts.root, .require = .{ .hovered = true }, .declarations = &.{style.set(.fill, hot)} },
}) };
const recipe_plain: recipes.Recipe = .{ .parts = recipes.model.button.parts, .rules = &(recipes.model.button_rules ++ [_]style.Rule{}) };
const recipe_card: recipes.Recipe = .{ .parts = &.{.{ .id = style.Parts.root, .base = .{ .box = .{ .pad = @splat(8), .fill = .rgb(48, 52, 64) } } }}, .rules = &[_]style.Rule{
    .{ .part = style.Parts.root, .require = .{ .hovered = true }, .declarations = &.{style.set(.opacity, 0.5)} },
} };

const button_transition: recipes.controls.Transition = .{ .seconds = 0.1, .ease = .linear, .fill = true, .text_color = true };
const card_transition: recipes.controls.Transition = .{ .seconds = 0.2, .opacity = true };

const body: lcgf.types.Style = .{ .size = .{ .fill, .fill }, .fill = theme.panel };

pub const spec = s.col(body, .{
    recipes.ct.button(.go, "Go", .{ .recipe = recipe_go, .tokens = recipe_tokens, .transition = button_transition, .fade_field = "go_fade" }),
    recipes.ct.button(.plain, "Plain", .{ .recipe = recipe_plain, .tokens = recipe_tokens, .transition = button_transition, .fade_field = "plain_fade" }),
    recipes.ct.box(.card, .{ .recipe = recipe_card, .transition = card_transition, .fade_field = "card_fade" }, .{label.ct.label(theme, "Card")}),
});

pub const limits: lcgf.context.Limits = .{ .nodes = 32, .texts = 8, .customs = 4, .strings = 256, .depth = 8 };

/// The same page in the runtime front end, for the draw lists.
pub const App = struct {
    state: State = .{},

    pub fn build(app: *App, f: *Frame) void {
        _ = f.open(.none, body);
        _ = recipes.button(f, .from("go"), "Go", .{ .recipe = recipe_go, .tokens = recipe_tokens, .transition = button_transition, .fade = &app.state.go_fade }) catch unreachable;
        _ = recipes.button(f, .from("plain"), "Plain", .{ .recipe = recipe_plain, .tokens = recipe_tokens, .transition = button_transition, .fade = &app.state.plain_fade }) catch unreachable;
        _ = recipes.beginBox(f, .from("card"), true, .{ .recipe = recipe_card, .transition = card_transition, .fade = &app.state.card_fade }) catch unreachable;
        _ = label.label(f, &theme, "Card");
        recipes.endBox(f);
        f.close();
    }
};

/// Hover Go for a few frames, move to Plain, then the card.
pub const replay =
    \\frame
    \\viewport 800 600
    \\dt 0.025
    \\pointer 400 300
    \\frame
    \\pointer 14 14
    \\frame
    \\frame
    \\pointer 20 48
    \\frame
    \\frame
    \\frame
    \\pointer 20 80
    \\frame
    \\frame
    \\frame
    \\frame
    \\frame
    \\frame
    \\frame
    \\frame
    \\frame
;

pub fn Handlers(comptime Ui: type) type {
    return struct {
        pub fn go(_: *@This(), _: *Ui) void {}
    };
}

fn center(r: lcgf.types.Rect) [2]f32 {
    return .{ (r.x0 + r.x1) / 2, (r.y0 + r.y1) / 2 };
}

/// Go's face reaches the hover fill a quarter at a time over four 25 ms frames.
pub fn events(comptime page: type, p: anytype, h: anytype) !void {
    _ = page;
    var in: lcgf.input.Input = .{ .viewport = .{ 800, 600 }, .dt = 0.025 };
    var t = p.frame(h, &in).tree;
    const go = t.find(.from("go"));
    const rest = t.c.look[go].fill;
    in.pointer = center(t.rect(go));
    t = p.frame(h, &in).tree;
    try std.testing.expect(t.c.look[go].fill != rest and t.c.look[go].fill != hot.bitsOf());
    for (0..3) |_| t = p.frame(h, &in).tree;
    try std.testing.expectEqual(hot.bitsOf(), t.c.look[go].fill);
}
