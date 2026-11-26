//! disabled, written by hand: `disabled` and `<fieldset disabled>` make recipe widgets with
//! `States.disabled`, so they take no input and no Tab stop, and `:disabled` and `:enabled`
//! (which forbids `disabled`) are recipe rules. `:focus-within` on a box holds while the
//! focused widget is inside it; `:indeterminate` never holds on a bool checkbox.

const std = @import("std");
const lcgf = @import("lcgf");
const s = lcgf.spec;
const w = lcgf.widgets_base;
const recipes = lcgf.theme_recipes;
const style = lcgf.style;
const Frame = lcgf.frame.Frame;
const Color = lcgf.types.Color;

pub const theme: w.Theme = .{};

pub const State = struct { agree: bool = false };

const recipe_tokens: style.tokens.Table = .{ .scopes = &.{.{ .entries = &recipes.model.tokenRows(.{
    .palette = .{ theme.text, theme.panel, theme.control, theme.control_hot, theme.control_held, theme.accent },
    .space = .{ 2, 4, theme.gap, theme.pad, 12 },
    .radius = .{ 0, 2, theme.radius, 6, 8 },
    .text_size = .{ 11, 12, theme.text_px, 18, 24 },
}, .{}) }} };

const off_fill: Color = .rgb(32, 32, 32);
const hot: Color = .rgb(80, 120, 200);
const within: Color = .rgb(40, 48, 64);

const button_recipe: recipes.Recipe = .{ .parts = recipes.model.button.parts, .rules = &(recipes.model.button_rules ++ [_]style.Rule{
    .{ .part = style.Parts.root, .require = .{ .disabled = true }, .declarations = &.{style.set(.fill, off_fill)} },
    .{ .part = style.Parts.root, .require = .{ .hovered = true }, .forbid = .{ .disabled = true }, .declarations = &.{style.set(.fill, hot)} },
}) };
const recipe_agree: recipes.Recipe = .{ .parts = recipes.model.checkbox.parts, .rules = &(recipes.model.checkbox_rules ++ [_]style.Rule{
    .{ .part = style.Parts.background, .require = .{ .indeterminate = true }, .declarations = &.{style.set(.fill, .rgb(255, 0, 0))} },
}) };
const recipe_group: recipes.Recipe = .{ .parts = &.{.{ .id = style.Parts.root, .base = .{ .box = .{ .pad = @splat(4) } } }}, .rules = &[_]style.Rule{
    .{ .part = style.Parts.root, .require = .{ .focus_within = true }, .declarations = &.{style.set(.fill, within)} },
} };

const body: lcgf.types.Style = .{ .size = .{ .fill, .fill }, .fill = theme.panel };
const off_config: recipes.ct.Config = .{ .recipe = button_recipe, .tokens = recipe_tokens, .states = .{ .disabled = true } };
const on_config: recipes.ct.Config = .{ .recipe = button_recipe, .tokens = recipe_tokens };

pub const spec = s.col(body, .{
    recipes.ct.button(.off, "Off", off_config),
    recipes.ct.button(.on, "On", on_config),
    s.col(.{}, .{recipes.ct.checkbox(.agree, .agree, "Agree", .{ .recipe = recipe_agree, .tokens = recipe_tokens, .states = .{ .disabled = true } })}),
    recipes.ct.box(null, .{ .recipe = recipe_group }, .{recipes.ct.button(.inner, "Inner", on_config)}),
});

pub const limits: lcgf.context.Limits = .{ .nodes = 64, .texts = 16, .customs = 8, .strings = 512, .depth = 8 };

/// The same page in the runtime front end, for the draw lists.
pub const App = struct {
    agree: bool = false,

    pub fn build(app: *App, f: *Frame) void {
        _ = f.open(.none, body);
        _ = recipes.button(f, .from("off"), "Off", .{ .recipe = button_recipe, .tokens = recipe_tokens, .states = .{ .disabled = true } }) catch unreachable;
        _ = recipes.button(f, .from("on"), "On", .{ .recipe = button_recipe, .tokens = recipe_tokens }) catch unreachable;
        _ = f.open(.none, .{});
        _ = recipes.checkbox(f, .from("agree"), &app.agree, "Agree", .{ .recipe = recipe_agree, .tokens = recipe_tokens, .states = .{ .disabled = true } }) catch unreachable;
        f.close();
        const box1 = recipes.beginBox(f, .from("group"), false, .{ .recipe = recipe_group }) catch unreachable;
        _ = recipes.button(f, .from("inner"), "Inner", .{ .recipe = button_recipe, .tokens = recipe_tokens }) catch unreachable;
        recipes.endBox(f, box1);
        f.close();
    }
};

/// Hover and press Off, hover On, click the checkbox, then Tab twice.
pub const replay =
    \\frame
    \\viewport 800 600
    \\pointer 400 300
    \\frame
    \\pointer 14 14
    \\frame
    \\buttons left
    \\frame
    \\buttons
    \\frame
    \\pointer 14 48
    \\frame
    \\pointer 12 80
    \\buttons left
    \\frame
    \\buttons
    \\frame
    \\press 43
    \\frame
    \\frame
    \\press 43
    \\frame
    \\frame
;

pub fn Handlers(comptime Ui: type) type {
    return struct {
        offs: u32 = 0,
        ons: u32 = 0,
        pub fn off(h: *@This(), _: *Ui) void {
            h.offs += 1;
        }
        pub fn on(h: *@This(), _: *Ui) void {
            h.ons += 1;
        }
    };
}

fn center(r: lcgf.types.Rect) [2]f32 {
    return .{ (r.x0 + r.x1) / 2, (r.y0 + r.y1) / 2 };
}

/// Off ignores the pointer and keeps its :disabled fill; the disabled checkbox does not
/// toggle; Tab skips both and the group lights while Inner has focus.
pub fn events(comptime page: type, p: anytype, h: anytype) !void {
    _ = page;
    var in: lcgf.input.Input = .{ .viewport = .{ 800, 600 } };
    var t = p.frame(h, &in).tree;
    const off = t.find(.from("off"));
    in.pointer = center(t.rect(off));
    t = p.frame(h, &in).tree;
    try std.testing.expectEqual(off_fill.bitsOf(), t.c.look[off].fill);
    in.buttons.left = true;
    _ = p.frame(h, &in);
    in.buttons.left = false;
    _ = p.frame(h, &in);
    try std.testing.expectEqual(0, h.offs);
    const on = t.find(.from("on"));
    in.pointer = center(t.rect(on));
    t = p.frame(h, &in).tree;
    try std.testing.expectEqual(hot.bitsOf(), t.c.look[on].fill);
    in.pointer = center(t.rect(t.find(.from("agree"))));
    in.buttons.left = true;
    _ = p.frame(h, &in);
    in.buttons.left = false;
    _ = p.frame(h, &in);
    try std.testing.expect(!p.ui.signals.state.agree);
    in.pointer = .{ 790, 590 };
    const tab = [_]lcgf.input.Input.Event{.{ .kind = .press, .code = (lcgf.focus.Keymap{}).tab }};
    var stops: u32 = 0;
    while (stops < 2) : (stops += 1) {
        in.events = &tab;
        _ = p.frame(h, &in);
        in.events = &.{};
        t = p.frame(h, &in).tree;
    }
    const inner = t.find(.from("inner"));
    try std.testing.expectEqual(within.bitsOf(), t.c.look[inner - 1].fill);
}
