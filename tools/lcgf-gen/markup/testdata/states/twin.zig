//! states, written by hand: buttons and a checkbox with state CSS are recipe widgets. Each
//! recipe is the stock one with a rule per CSS rule: `button:hover` requires `hovered`,
//! `:active` `held`, `:focus-visible` `focus_visible`, `:checked` `checked`. `#keep`'s
//! background outranks `button:hover`'s, so its hover rule only sets the text colour.

const std = @import("std");
const lcgf = @import("lcgf");
const s = lcgf.spec;
const w = lcgf.widgets_base;
const recipes = lcgf.theme_recipes;
const style = lcgf.style;
const Frame = lcgf.frame.Frame;
const Color = lcgf.types.Color;

pub const theme: w.Theme = .{};

pub const State = struct { on: bool = false };

const rest: Color = .rgb(58, 60, 70);
const hot: Color = .rgb(80, 120, 200);
const held: Color = .rgb(40, 48, 74);
const white: Color = .rgb(255, 255, 255);

const recipe_go: recipes.Recipe = .{ .parts = recipes.model.button.parts, .rules = &(recipes.model.button_rules ++ [_]style.Rule{
    .{ .part = style.Parts.root, .declarations = &.{style.set(.fill, rest)} },
    .{ .part = style.Parts.root, .require = .{ .hovered = true }, .declarations = &.{ style.set(.fill, hot), style.set(.text_color, white) } },
    .{ .part = style.Parts.root, .require = .{ .held = true }, .declarations = &.{style.set(.fill, held)} },
    .{ .part = style.Parts.root, .require = .{ .focus_visible = true }, .declarations = &.{ style.set(.border_color, .rgb(255, 208, 64)), style.set(.border_width, 2) } },
}) };
const recipe_keep: recipes.Recipe = .{ .parts = recipes.model.button.parts, .rules = &(recipes.model.button_rules ++ [_]style.Rule{
    .{ .part = style.Parts.root, .declarations = &.{style.set(.fill, .rgb(96, 32, 32))} },
    .{ .part = style.Parts.root, .require = .{ .hovered = true }, .declarations = &.{style.set(.text_color, white)} },
    .{ .part = style.Parts.root, .require = .{ .focus_visible = true }, .declarations = &.{ style.set(.border_color, .rgb(255, 208, 64)), style.set(.border_width, 2) } },
}) };
const recipe_on: recipes.Recipe = .{ .parts = recipes.model.checkbox.parts, .rules = &(recipes.model.checkbox_rules ++ [_]style.Rule{
    .{ .part = style.Parts.background, .require = .{ .checked = true }, .declarations = &.{style.set(.fill, .rgb(64, 160, 96))} },
}) };

const body: lcgf.types.Style = .{ .size = .{ .fill, .fill }, .fill = theme.panel };

pub const spec = s.col(body, .{
    recipes.ct.button(.go, "Go", .{ .recipe = recipe_go }),
    recipes.ct.button(.keep, "Keep", .{ .recipe = recipe_keep }),
    recipes.ct.checkbox(.on, .on, "On", .{ .recipe = recipe_on }),
});

pub const limits: lcgf.context.Limits = .{ .nodes = 32, .texts = 8, .customs = 4, .strings = 1024, .depth = 8 };

/// The same page in the runtime front end, for the draw lists.
pub const App = struct {
    on: bool = false,

    pub fn build(app: *App, f: *Frame) void {
        _ = f.open(.none, body);
        _ = recipes.button(f, .from("go"), "Go", .{ .recipe = recipe_go }) catch unreachable;
        _ = recipes.button(f, .from("keep"), "Keep", .{ .recipe = recipe_keep }) catch unreachable;
        _ = recipes.checkbox(f, .from("on"), &app.on, "On", .{ .recipe = recipe_on }) catch unreachable;
        f.close();
    }
};

/// Hover and press Go, hover Keep, then check the box.
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
    \\pointer 20 48
    \\frame
    \\pointer 12 80
    \\frame
    \\buttons left
    \\frame
    \\buttons
    \\frame
;

pub fn Handlers(comptime Ui: type) type {
    return struct {
        clicks: u32 = 0,
        pub fn go(h: *@This(), _: *Ui) void {
            h.clicks += 1;
        }
    };
}

fn center(r: lcgf.types.Rect) [2]f32 {
    return .{ (r.x0 + r.x1) / 2, (r.y0 + r.y1) / 2 };
}

/// Real input moves the states: Go's face is the hover colour under the pointer and the held
/// one while pressed; Keep keeps its background; checking the box turns it green.
pub fn events(comptime page: type, p: anytype, h: anytype) !void {
    _ = page;
    var in: lcgf.input.Input = .{};
    var t = p.frame(h, &in).tree;
    const go = t.find(.from("go"));
    const keep = t.find(.from("keep"));
    try std.testing.expectEqual(rest.bitsOf(), t.c.look[go].fill);
    in.pointer = center(t.rect(go));
    t = p.frame(h, &in).tree;
    try std.testing.expectEqual(hot.bitsOf(), t.c.look[go].fill);
    in.buttons.left = true;
    t = p.frame(h, &in).tree;
    try std.testing.expectEqual(held.bitsOf(), t.c.look[go].fill);
    in.buttons.left = false;
    _ = p.frame(h, &in);
    try std.testing.expectEqual(1, h.clicks);
    in.pointer = center(t.rect(keep));
    t = p.frame(h, &in).tree;
    try std.testing.expectEqual(Color.rgb(96, 32, 32).bitsOf(), t.c.look[keep].fill);
    const on = t.find(.from("on"));
    in.pointer = center(t.rect(on));
    in.buttons.left = true;
    _ = p.frame(h, &in);
    in.buttons.left = false;
    t = p.frame(h, &in).tree;
    try std.testing.expect(p.ui.signals.state.on);
    // The box is the checkbox row's first child.
    try std.testing.expectEqual(Color.rgb(64, 160, 96).bitsOf(), t.c.look[on + 1].fill);
}
