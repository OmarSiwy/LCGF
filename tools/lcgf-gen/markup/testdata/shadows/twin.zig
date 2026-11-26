//! shadows, written by hand: box-shadow and margins under :hover. A box's shadow is drawn by a node of its
//! own before it (`decorate`); with a state rule that node is a recipe box that follows the
//! box's states (`Config.follows`, `Options.follows`), so its fill, radius, paint outset and
//! blur change with them. A widget without a shadow of its own gets one that paints nothing
//! until the rule holds. A box with margin rules writes its flex entry itself, from its recipe
//! (`Computed.margin`). The generated runtime page is checked against this spec (parity.zig).

const std = @import("std");
const lcgf = @import("lcgf");
const s = lcgf.spec;
const w = lcgf.widgets_base;
const label = lcgf.widgets_label;
const recipes = lcgf.theme_recipes;
const style = lcgf.style;
const Color = lcgf.types.Color;

pub const theme: w.Theme = .{};

const recipe_tokens: style.tokens.Table = .{ .scopes = &.{.{ .entries = &recipes.model.tokenRows(.{
    .palette = .{ theme.text, theme.panel, theme.control, theme.control_hot, theme.control_held, theme.accent },
    .space = .{ 2, 4, theme.gap, theme.pad, 12 },
    .radius = .{ 0, 2, theme.radius, 6, 8 },
    .text_size = .{ 11, 12, theme.text_px, 18, 24 },
}, .{}) }} };

const deep: Color = .rgb(16, 32, 64);
const ring: Color = .rgb(128, 160, 255);

const recipe_tile_shadow: recipes.Recipe = .{ .parts = &.{.{ .id = style.Parts.root, .base = .{ .box = .{ .size = @splat(.pct(1)), .float = true, .fill = .rgb(0, 0, 0), .params = lcgf.features.shadow(2), .paint_outset = .{ 0, -2, 0, 2 } } } }}, .rules = &[_]style.Rule{
    .{ .part = style.Parts.root, .require = .{ .hovered = true }, .declarations = &.{ style.set(.fill, deep), style.set(.radius, 2), style.set(.radii, @splat(-1)), style.set(.paint_outset, .{ 2, -4, 2, 8 }), style.set(.params, lcgf.features.shadow(6)) } },
} };
const recipe_tile: recipes.Recipe = .{ .parts = &.{.{ .id = style.Parts.root, .base = .{ .box = .{ .size = @splat(.fill), .pad = @splat(8), .fill = .rgb(48, 52, 64) } } }}, .rules = &[_]style.Rule{} };
const recipe_go_shadow: recipes.Recipe = .{ .parts = &.{.{ .id = style.Parts.root, .base = .{ .box = .{ .size = @splat(.pct(1)), .float = true, .radius = 4, .params = lcgf.features.shadow(0) } } }}, .rules = &[_]style.Rule{
    .{ .part = style.Parts.root, .require = .{ .hovered = true }, .declarations = &.{ style.set(.fill, ring), style.set(.radius, 7), style.set(.radii, @splat(-1)), style.set(.paint_outset, @splat(3)), style.set(.params, lcgf.features.shadow(0)) } },
} };
const recipe_go: recipes.Recipe = .{ .parts = recipes.model.button.parts, .rules = &(recipes.model.button_rules ++ [_]style.Rule{
    .{ .part = style.Parts.root, .declarations = &.{ style.set(.width, .fill), style.set(.height, .fill) } },
}) };

const recipe_chip: recipes.Recipe = .{ .parts = &.{.{ .id = style.Parts.root, .base = .{ .box = .{ .pad = @splat(4), .fill = .rgb(64, 72, 80) }, .margin = .{ 4, 0, 0, 0 } } }}, .rules = &[_]style.Rule{
    .{ .part = style.Parts.root, .require = .{ .hovered = true }, .declarations = &.{style.set(.margin_left, 16)} },
} };

const body: lcgf.types.Style = .{ .size = @splat(.fill), .pad = @splat(20), .gap = 20, .fill = theme.panel };

pub const spec = s.col(body, .{
    s.col(.{}, .{
        recipes.ct.box(null, .{ .recipe = recipe_tile_shadow, .follows = "tile" }, .{}),
        recipes.ct.box(.tile, .{ .recipe = recipe_tile }, .{label.ct.label(theme, "Tile")}),
    }),
    s.col(.{}, .{
        recipes.ct.box(null, .{ .recipe = recipe_go_shadow, .follows = "go" }, .{}),
        recipes.ct.button(.go, "Go", .{ .recipe = recipe_go, .tokens = recipe_tokens }),
    }),
    s.flexed(recipes.ct.box(.chip, .{ .recipe = recipe_chip }, .{label.ct.label(theme, "Chip")}), .{ .margin = .{ 4, 0, 0, 0 } }),
});

/// Over the tile, then over the button, then the chip, then away.
pub const replay =
    \\frame
    \\viewport 400 300
    \\pointer 40 30
    \\frame
    \\frame
    \\pointer 30 70
    \\frame
    \\frame
    \\pointer 40 110
    \\frame
    \\frame
    \\pointer 390 290
    \\frame
;

pub fn Handlers(comptime Ui: type) type {
    return struct {
        goes: u32 = 0,
        pub fn go(h: *@This(), _: *Ui) void {
            h.goes += 1;
        }
    };
}

fn center(r: lcgf.types.Rect) [2]f32 {
    return .{ (r.x0 + r.x1) / 2, (r.y0 + r.y1) / 2 };
}

/// Over the tile its shadow (the row before it) takes the deep fill and the wider outset; over
/// the button, the button's ring shows while the tile's shadow is back at rest.
pub fn events(comptime page: type, p: anytype, h: anytype) !void {
    _ = page;
    var in: lcgf.input.Input = .{ .viewport = .{ 400, 300 } };
    var t = p.frame(h, &in).tree;
    const tile = t.find(.from("tile"));
    const go = t.find(.from("go"));
    try std.testing.expectEqual(Color.transparent.bitsOf(), t.c.look[go - 1].fill);
    in.pointer = center(t.rect(tile));
    t = p.frame(h, &in).tree;
    try std.testing.expectEqual(deep.bitsOf(), t.c.look[tile - 1].fill);
    in.pointer = center(t.rect(go));
    t = p.frame(h, &in).tree;
    try std.testing.expectEqual(ring.bitsOf(), t.c.look[go - 1].fill);
    try std.testing.expect(deep.bitsOf() != t.c.look[tile - 1].fill);
    // The chip moves 12 px right while hovered, and back.
    const chip = t.find(.from("chip"));
    const rest = t.rect(chip).x0;
    in.pointer = center(t.rect(chip));
    _ = p.frame(h, &in);
    t = p.frame(h, &in).tree;
    try std.testing.expectEqual(rest + 12, t.rect(chip).x0);
    in.pointer = .{ 390, 290 };
    _ = p.frame(h, &in);
    t = p.frame(h, &in).tree;
    try std.testing.expectEqual(rest, t.rect(chip).x0);
}
