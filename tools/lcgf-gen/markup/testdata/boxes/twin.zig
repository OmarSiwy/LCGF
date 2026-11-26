//! boxes, written by hand: a <div> with state CSS is a recipe box whose base is its static
//! style and whose rules are its CSS's: `.card:hover` requires `hovered`, `:active` `held`,
//! so the card is a widget (hover and press, no focus). The bar has only `@media`, so it is
//! no widget and follows the viewport. Rules set layout too: padding and a transform while
//! the card is pressed, width and gap on a narrow viewport.

const std = @import("std");
const lcgf = @import("lcgf");
const s = lcgf.spec;
const w = lcgf.widgets_base;
const label = lcgf.widgets_label;
const recipes = lcgf.theme_recipes;
const style = lcgf.style;
const Frame = lcgf.frame.Frame;
const Color = lcgf.types.Color;

pub const theme: w.Theme = .{};

const rest: Color = .rgb(48, 52, 64);
const hot: Color = .rgb(64, 80, 112);
const narrow: Color = .rgb(96, 32, 32);

const recipe_card: recipes.Recipe = .{ .parts = &.{.{ .id = style.Parts.root, .base = .{ .box = .{ .pad = @splat(10), .fill = rest, .border_color = .rgb(80, 88, 104), .border = 1 } } }}, .rules = &[_]style.Rule{
    .{ .part = style.Parts.root, .require = .{ .hovered = true }, .declarations = &.{ style.set(.fill, hot), style.set(.border_color, .rgb(128, 160, 255)) } },
    .{ .part = style.Parts.root, .require = .{ .held = true }, .declarations = &.{ style.set(.opacity, 0.8), style.set(.transform, .{ 1, 0, 0, 1, 0, 2 }), style.set(.padding_left, 14), style.set(.padding_top, 14), style.set(.padding_right, 14), style.set(.padding_bottom, 14) } },
} };
const recipe_bar: recipes.Recipe = .{ .parts = &.{.{ .id = style.Parts.root, .base = .{ .box = .{ .dir = .x, .gap = 4 } } }}, .rules = &[_]style.Rule{
    .{ .part = style.Parts.root, .when = .{ .width = .{ .max = 500 } }, .declarations = &.{ style.set(.fill, narrow), style.set(.width, .pct(1)), style.set(.gap, 12) } },
} };

const body: lcgf.types.Style = .{ .size = .{ .fill, .fill }, .fill = theme.panel };

pub const spec = s.col(body, .{
    recipes.ct.box(.card, .{ .recipe = recipe_card }, .{label.ct.label(theme, "Card")}),
    recipes.ct.box(null, .{ .recipe = recipe_bar }, .{ label.ct.label(theme, "One"), label.ct.label(theme, "Two") }),
});

pub const limits: lcgf.context.Limits = .{ .nodes = 16, .texts = 8, .customs = 2, .strings = 256, .depth = 8 };

/// The same page in the runtime front end, for the draw lists.
pub const App = struct {
    pub fn build(_: *App, f: *Frame) void {
        _ = f.open(.none, body);
        _ = recipes.beginBox(f, .from("card"), true, .{ .recipe = recipe_card }) catch unreachable;
        _ = label.label(f, &theme, "Card");
        recipes.endBox(f);
        _ = recipes.beginBox(f, .none, false, .{ .recipe = recipe_bar }) catch unreachable;
        _ = label.label(f, &theme, "One");
        _ = label.label(f, &theme, "Two");
        recipes.endBox(f);
        f.close();
    }
};

/// Hover and press the card on a wide viewport, then narrow it.
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
    \\viewport 400 600
    \\frame
;

/// The card's fill follows the pointer; the bar's follows the viewport width.
pub fn events(comptime page: type, p: anytype, h: anytype) !void {
    _ = page;
    var in: lcgf.input.Input = .{ .viewport = .{ 800, 600 } };
    var t = p.frame(h, &in).tree;
    const card = t.find(.from("card"));
    const bar = t.c.end[card];
    try std.testing.expectEqual(rest.bitsOf(), t.c.look[card].fill);
    try std.testing.expect(t.c.look[bar].fill != narrow.bitsOf());
    const r = t.rect(card);
    in.pointer = .{ (r.x0 + r.x1) / 2, (r.y0 + r.y1) / 2 };
    t = p.frame(h, &in).tree;
    try std.testing.expectEqual(hot.bitsOf(), t.c.look[card].fill);
    const rest_w = t.rect(card).w();
    in.buttons.left = true;
    t = p.frame(h, &in).tree;
    try std.testing.expectEqual(rest_w + 8, t.rect(card).w());
    in.buttons.left = false;
    _ = p.frame(h, &in);
    in.viewport = .{ 400, 600 };
    t = p.frame(h, &in).tree;
    try std.testing.expectEqual(narrow.bitsOf(), t.c.look[bar].fill);
    try std.testing.expectEqual(@as(f32, 400), t.rect(bar).w());
}

pub fn Handlers(comptime Ui: type) type {
    _ = Ui;
    return struct {};
}
