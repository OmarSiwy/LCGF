//! inputs, written by hand: a range and a text field with state CSS are recipe widgets, the
//! stock slider and input recipes followed by their rules; on:change and on:submit reach
//! the handlers as on the theme widgets. `required` and `maxlength` are the field's
//! validation: `:required:invalid` holds while it is empty, `:valid` once it has text (and
//! on the range, which is always valid).

const std = @import("std");
const lcgf = @import("lcgf");
const s = lcgf.spec;
const w = lcgf.widgets_base;
const recipes = lcgf.theme_recipes;
const style = lcgf.style;
const textfield = lcgf.widgets_textfield;
const Frame = lcgf.frame.Frame;
const Color = lcgf.types.Color;

pub const theme: w.Theme = .{};

pub const State = struct { level: f32 = 0, name: textfield.Text(256) = .{} };

const recipe_tokens: style.tokens.Table = .{ .scopes = &.{.{ .entries = &recipes.model.tokenRows(.{
    .palette = .{ theme.text, theme.panel, theme.control, theme.control_hot, theme.control_held, theme.accent },
    .space = .{ 2, 4, theme.gap, theme.pad, 12 },
    .radius = .{ 0, 2, theme.radius, 6, 8 },
    .text_size = .{ 11, 12, theme.text_px, 18, 24 },
}, .{}) }} };

const hot: Color = .rgb(80, 120, 200);
const gold: Color = .rgb(255, 208, 64);

const valid: Color = .rgb(32, 48, 32);
const invalid: Color = .rgb(64, 32, 32);

const recipe_level: recipes.Recipe = .{ .parts = recipes.model.slider.parts, .rules = &(recipes.model.slider_rules ++ [_]style.Rule{
    .{ .part = style.Parts.root, .forbid = .{ .invalid = true }, .declarations = &.{style.set(.fill, valid)} },
    .{ .part = style.Parts.root, .require = .{ .hovered = true }, .declarations = &.{style.set(.fill, hot)} },
    .{ .part = style.Parts.root, .require = .{ .invalid = true, .required = true }, .declarations = &.{style.set(.fill, invalid)} },
}) };
const recipe_name: recipes.Recipe = .{ .parts = recipes.model.input.parts, .rules = &(recipes.model.input_rules ++ [_]style.Rule{
    .{ .part = style.Parts.root, .forbid = .{ .invalid = true }, .declarations = &.{style.set(.fill, valid)} },
    .{ .part = style.Parts.root, .require = .{ .focused = true }, .declarations = &.{style.set(.border_color, gold)} },
    .{ .part = style.Parts.root, .require = .{ .invalid = true, .required = true }, .declarations = &.{style.set(.fill, invalid)} },
}) };
const validation: recipes.controls.Validation = .{ .required = true, .max_length = 8 };

const body: lcgf.types.Style = .{ .size = .{ .fill, .fill }, .fill = theme.panel };

pub const spec = s.col(body, .{
    recipes.ct.slider(.level, .level, .{}, .{ .recipe = recipe_level, .tokens = recipe_tokens }),
    recipes.ct.textfield(.name, .name, "Your name", .{ .recipe = recipe_name, .tokens = recipe_tokens, .validation = validation }),
});

pub const limits: lcgf.context.Limits = .{ .nodes = 64, .texts = 16, .customs = 4, .strings = 1024, .depth = 8 };

/// The same page in the runtime front end, for the draw lists.
pub const App = struct {
    level: f32 = 0,
    name: textfield.Text(256) = .{},

    pub fn build(app: *App, f: *Frame) void {
        _ = f.open(.none, body);
        _ = recipes.slider(f, .from("level"), &app.level, 0, 1, .{ .recipe = recipe_level, .tokens = recipe_tokens }) catch unreachable;
        _ = recipes.textfield(f, .from("name"), &app.name, "Your name", .{ .recipe = recipe_name, .tokens = recipe_tokens, .validation = validation }) catch unreachable;
        f.close();
    }
};

/// Hover and drag the range, then click into the field and type.
pub const replay =
    \\frame
    \\viewport 800 600
    \\pointer 400 300
    \\frame
    \\pointer 40 10
    \\frame
    \\buttons left
    \\frame
    \\pointer 120 10
    \\frame
    \\buttons
    \\frame
    \\pointer 40 40
    \\buttons left
    \\frame
    \\buttons
    \\frame
    \\text ab
    \\frame
    \\frame
;

pub fn Handlers(comptime Ui: type) type {
    return struct {
        moves: u32 = 0,
        dones: u32 = 0,
        pub fn moved(h: *@This(), _: *Ui, _: f32) void {
            h.moves += 1;
        }
        pub fn done(h: *@This(), _: *Ui) void {
            h.dones += 1;
        }
    };
}

fn center(r: lcgf.types.Rect) [2]f32 {
    return .{ (r.x0 + r.x1) / 2, (r.y0 + r.y1) / 2 };
}

/// The range takes the hover fill and reports a drag; the field's border turns gold once it
/// has focus, and Enter submits.
pub fn events(comptime page: type, p: anytype, h: anytype) !void {
    _ = page;
    var in: lcgf.input.Input = .{ .viewport = .{ 800, 600 } };
    var t = p.frame(h, &in).tree;
    const level = t.find(.from("level"));
    const r = t.rect(level);
    in.pointer = center(r);
    t = p.frame(h, &in).tree;
    try std.testing.expectEqual(hot.bitsOf(), t.c.look[level].fill);
    in.buttons.left = true;
    _ = p.frame(h, &in);
    in.pointer[0] = r.x0 + (r.x1 - r.x0) * 0.9;
    _ = p.frame(h, &in);
    in.buttons.left = false;
    _ = p.frame(h, &in);
    try std.testing.expect(h.moves > 0);
    const name = t.find(.from("name"));
    try std.testing.expectEqual(invalid.bitsOf(), t.c.look[name].fill);
    in.pointer = center(t.rect(name));
    in.buttons.left = true;
    _ = p.frame(h, &in);
    in.buttons.left = false;
    t = p.frame(h, &in).tree;
    try std.testing.expectEqual(gold.bitsOf(), t.c.look[name].border_color);
    in.text = "ab";
    const typed = [_]lcgf.input.Input.Event{.{ .kind = .text, .at = 0, .len = 2 }};
    in.events = &typed;
    t = p.frame(h, &in).tree;
    in.text = "";
    try std.testing.expectEqual(valid.bitsOf(), t.c.look[name].fill);
    const enter = [_]lcgf.input.Input.Event{.{ .kind = .press, .code = 0x28 }};
    in.events = &enter;
    _ = p.frame(h, &in);
    in.events = &.{};
    _ = p.frame(h, &in);
    try std.testing.expectEqual(1, h.dones);
}
