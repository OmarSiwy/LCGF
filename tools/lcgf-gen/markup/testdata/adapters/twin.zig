//! adapters, written by hand: widgets beyond the button, checkbox, switch, range and text field
//! with state CSS are recipe widgets too, over their stock recipes (`recipes.model.link`,
//! `toggle`, …) followed by their rules. A link keeps its Enter-only activation and its
//! on:click; a toggle button flips its bound field; a radio group's state rules style each
//! option under that option's own states; a search field's root is the box around its field and
//! Clear button, which still clears it.

const std = @import("std");
const lcgf = @import("lcgf");
const s = lcgf.spec;
const w = lcgf.widgets_base;
const recipes = lcgf.theme_recipes;
const style = lcgf.style;
const Frame = lcgf.frame.Frame;
const Color = lcgf.types.Color;

pub const theme: w.Theme = .{};

pub const State = struct { bold: bool = false, size: u32 = 1, find: lcgf.widgets_textfield.Text(256) = .{} };

const recipe_tokens: style.tokens.Table = .{ .scopes = &.{.{ .entries = &recipes.model.tokenRows(.{
    .palette = .{ theme.text, theme.panel, theme.control, theme.control_hot, theme.control_held, theme.accent },
    .space = .{ 2, 4, theme.gap, theme.pad, 12 },
    .radius = .{ 0, 2, theme.radius, 6, 8 },
    .text_size = .{ 11, 12, theme.text_px, 18, 24 },
}, .{}) }} };

const blue: Color = .rgb(80, 120, 200);
const red: Color = .rgb(200, 80, 80);
const green: Color = .rgb(80, 200, 120);
const sand: Color = .rgb(200, 180, 80);

const recipe_docs: recipes.Recipe = .{ .parts = recipes.model.link.parts, .rules = &(recipes.model.link_rules ++ [_]style.Rule{
    .{ .part = style.Parts.root, .require = .{ .hovered = true }, .declarations = &.{style.set(.fill, blue)} },
}) };
const recipe_bold: recipes.Recipe = .{ .parts = recipes.model.toggle.parts, .rules = &(recipes.model.toggle_rules ++ [_]style.Rule{
    .{ .part = style.Parts.root, .require = .{ .hovered = true }, .declarations = &.{style.set(.fill, red)} },
}) };

const recipe_size: recipes.Recipe = .{ .parts = recipes.model.radio.parts, .rules = &(recipes.model.radio_rules ++ [_]style.Rule{
    .{ .part = style.Parts.row, .require = .{ .hovered = true }, .declarations = &.{style.set(.fill, green)} },
}) };

const recipe_find: recipes.Recipe = .{ .parts = recipes.model.search.parts, .rules = &(recipes.model.input_rules ++ [_]style.Rule{
    .{ .part = style.Parts.root, .require = .{ .hovered = true }, .declarations = &.{style.set(.fill, sand)} },
}) };

const body: lcgf.types.Style = .{ .size = .{ .fill, .fill }, .fill = theme.panel };

pub const spec = s.col(body, .{
    recipes.ct.link(.docs, "Read the docs", .{ .recipe = recipe_docs, .tokens = recipe_tokens }),
    recipes.ct.toggle(.bold, .bold, "Bold", .{ .recipe = recipe_bold, .tokens = recipe_tokens }),
    recipes.ct.radio(.size, .size, .{ "Small", "Large" }, .{ .recipe = recipe_size, .tokens = recipe_tokens }),
    recipes.ct.search(.find, .find, "Find", .{ .recipe = recipe_find, .tokens = recipe_tokens }),
});

pub const limits: lcgf.context.Limits = .{ .nodes = 64, .texts = 16, .customs = 4, .strings = 1024, .depth = 8 };

/// The same page in the runtime front end, for the draw lists.
pub const App = struct {
    bold: bool = false,
    size: u32 = 1,
    find: lcgf.widgets_textfield.Text(256) = .{},
    finds: u32 = 0,

    pub fn build(app: *App, f: *Frame) void {
        _ = f.open(.none, body);
        _ = recipes.link(f, .from("docs"), "Read the docs", .{ .recipe = recipe_docs, .tokens = recipe_tokens }) catch unreachable;
        _ = recipes.toggle(f, .from("bold"), &app.bold, "Bold", .{ .recipe = recipe_bold, .tokens = recipe_tokens }) catch unreachable;
        _ = recipes.radio(f, .from("size"), &app.size, &.{ "Small", "Large" }, .{ .recipe = recipe_size, .tokens = recipe_tokens }) catch unreachable;
        _ = recipes.search(f, .from("find"), &app.find, "Find", .{ .recipe = recipe_find, .tokens = recipe_tokens }) catch unreachable;
        f.close();
    }
};

/// Hover the link and click it, click the toggle button twice, pick Small, then type into the
/// search field and clear it.
pub const replay =
    \\frame
    \\viewport 800 600
    \\pointer 30 10
    \\frame
    \\buttons left
    \\frame
    \\buttons
    \\frame
    \\pointer 20 40
    \\buttons left
    \\frame
    \\buttons
    \\frame
    \\buttons left
    \\frame
    \\buttons
    \\frame
    \\pointer 20 75
    \\frame
    \\buttons left
    \\frame
    \\buttons
    \\frame
    \\pointer 40 120
    \\buttons left
    \\frame
    \\buttons
    \\frame
    \\text zig
    \\frame
    \\press 41
    \\frame
;

pub fn Handlers(comptime Ui: type) type {
    return struct {
        opens: u32 = 0,
        finds: u32 = 0,
        pub fn open_docs(h: *@This(), _: *Ui) void {
            h.opens += 1;
        }
        pub fn found(h: *@This(), _: *Ui, _: []const u8) void {
            h.finds += 1;
        }
    };
}

fn center(r: lcgf.types.Rect) [2]f32 {
    return .{ (r.x0 + r.x1) / 2, (r.y0 + r.y1) / 2 };
}

/// The link takes its hover fill and its click reaches open_docs; the toggle button takes
/// its hover fill and flips `bold`; the Small option alone takes its hover fill, and its click
/// selects it; the search field takes its hover fill on the box, Escape empties it and reaches
/// found, and the Clear button empties it.
pub fn events(comptime page: type, p: anytype, h: anytype) !void {
    _ = page;
    var in: lcgf.input.Input = .{ .viewport = .{ 800, 600 } };
    var t = p.frame(h, &in).tree;
    const docs = t.find(.from("docs"));
    const bold = t.find(.from("bold"));
    in.pointer = center(t.rect(docs));
    t = p.frame(h, &in).tree;
    try std.testing.expectEqual(blue.bitsOf(), t.c.look[docs].fill);
    in.buttons.left = true;
    _ = p.frame(h, &in);
    in.buttons.left = false;
    _ = p.frame(h, &in);
    try std.testing.expectEqual(1, h.opens);
    in.pointer = center(t.rect(bold));
    t = p.frame(h, &in).tree;
    try std.testing.expectEqual(red.bitsOf(), t.c.look[bold].fill);
    in.buttons.left = true;
    _ = p.frame(h, &in);
    in.buttons.left = false;
    _ = p.frame(h, &in);
    try std.testing.expect(p.ui.signals.state.bold);
    const small = t.find(lcgf.types.Id.from("size").with(0));
    const large = t.find(lcgf.types.Id.from("size").with(1));
    in.pointer = center(t.rect(small));
    t = p.frame(h, &in).tree;
    try std.testing.expectEqual(green.bitsOf(), t.c.look[small].fill);
    try std.testing.expect(green.bitsOf() != t.c.look[large].fill);
    in.buttons.left = true;
    _ = p.frame(h, &in);
    in.buttons.left = false;
    _ = p.frame(h, &in);
    try std.testing.expectEqual(0, p.ui.signals.state.size);
    const find = t.find(.from("find"));
    in.pointer = center(t.rect(find));
    t = p.frame(h, &in).tree;
    try std.testing.expectEqual(sand.bitsOf(), t.c.look[find - 1].fill);
    in.buttons.left = true;
    _ = p.frame(h, &in);
    in.buttons.left = false;
    _ = p.frame(h, &in);
    const typed = [_]lcgf.input.Input.Event{.{ .kind = .text, .at = 0, .len = 3 }};
    in.events = &typed;
    in.text = "zig";
    _ = p.frame(h, &in);
    in.text = "";
    in.events = &.{};
    try std.testing.expectEqualStrings("zig", p.ui.signals.state.find.text());
    const escape = [_]lcgf.input.Input.Event{.{ .kind = .press, .code = lcgf.widgets_search.escape }};
    in.events = &escape;
    _ = p.frame(h, &in);
    try std.testing.expectEqualStrings("", p.ui.signals.state.find.text());
    try std.testing.expectEqual(2, h.finds);
    in.events = &typed;
    in.text = "zig";
    _ = p.frame(h, &in);
    in.text = "";
    in.events = &.{};
    t = p.frame(h, &in).tree;
    in.pointer = center(t.rect(t.find(lcgf.widgets_search.clearId(.from("find")))));
    in.buttons.left = true;
    _ = p.frame(h, &in);
    in.buttons.left = false;
    _ = p.frame(h, &in);
    try std.testing.expectEqualStrings("", p.ui.signals.state.find.text());
}
