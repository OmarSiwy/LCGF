//! The page IR: what one HTML page lowers to before any language is written. Plain rows,
//! depth-first, each with its parent and source location; the view state's fields and the
//! handlers the markup names. Styles are the framework's own `Style` and `TextStyle` values,
//! fully resolved; emitters print the difference from the widget's default look.

const std = @import("std");
const lcgf = @import("lcgf");
const diag = @import("diag.zig");

pub const none = diag.none;
pub const Style = lcgf.types.Style;
pub const TextStyle = lcgf.types.TextStyle;
pub const Theme = lcgf.widgets_base.Theme;

/// What a node is: which builder makes it.
pub const Kind = enum(u8) {
    /// `spec.col` / `spec.row` by `dir`.
    container,
    /// `spec.landmark(landmark, style, children)`.
    landmark,
    /// `widgets_label.ct.label(theme, text)`: a literal or a bound string field.
    label,
    /// `spec.text(format, args)`.
    text,
    /// `spec.heading(level, text)`.
    heading,
    button,
    /// `<a href>`: `widgets_link.ct.link(theme, id, text)`, activated by click and Enter.
    link,
    /// `<details>`: `widgets_accordion.ct.section(theme, id, bind, text, children)`, its
    /// `<summary>` the header's text and its other content the panel, shown while `bind` is.
    section,
    checkbox,
    @"switch",
    toggle,
    slider,
    progress,
    spinner,
    separator,
    radio,
    textfield,
    search,
    textarea,
    number,
    /// `spec.when(.bind, child)`: wraps its only child.
    when,
    /// `spec.choice(.bind, style, alternatives)`.
    choice,
    /// `spec.list(.bind, max, style, template)`: its only child is the template.
    list,
    /// `widgets_scroll.ct.scroll(theme, .id, .bind, children)`: the content of a box with
    /// `overflow-y: auto | scroll`, scrolled by the f32 field `bind`.
    scroll,
    /// `widgets_spacer.ct.spacer(axis)`: free space for `justify-content: space-*`.
    spacer,
    /// `<template lcgf-each="item in items">`: a run-time region (`ct_interop.region`) the page
    /// fills with one copy of its content per element of the app's `items`. `bind` is the
    /// list, `text` the item's name, `id` the region's id; `max` and `level` its node and text
    /// capacity.
    each,
    /// `<sfy-name prop="…">`: an app component, `app.components.@"sfy-name"(.{ … })`. `text` is
    /// the tag, `props` its attributes, `id` the widget a click handler names; its children are
    /// the `children` prop. Inside an lcgf-each it is the runtime form, `(f, .{ … })`.
    component,
    /// `<select>`: `widgets_select.ct.select(theme, .id, .bind, .{ .texts = captions, .groups
    /// = groups })`, the button in the flow; `bind` is a `SelectState`.
    select,
    /// Its list: `widgets_select.ct.list` with the same arguments, moved last into the root
    /// (`Lowerer.overlays`).
    select_list,
    /// `<dialog bind:open>`: `widgets_dialog.ct.dialog(theme, .id, .bind, .{ children })`,
    /// moved last into the root.
    dialog,
    /// `<img>`: `widgets_image.ct.image(theme, assets[asset].picture(), image)`.
    image,
    /// `title="text"` on widget `id`: `widgets_tooltip.ct.tooltip(theme, .id, .bind, text)`,
    /// `bind` a `Tip`, moved last into the root.
    tooltip,
    /// `<button popovertarget="id">`: `widgets_popover.ct.button(theme, .id, .bind, caption)`,
    /// `bind` the popover's bool.
    popover_button,
    /// An element with `popover`: `widgets_popover.ct.popover(theme, .id, .bind, .{ children })`,
    /// moved last into the root.
    popover,
    /// `<button popovertarget>` of a `<menu popover>`: `widgets_menu.ct.button(theme, .id,
    /// .bind, def, caption)`, `bind` a `MenuState`, `args` the item names.
    menu_button,
    /// `<menu popover>`: `widgets_menu.ct.list(theme, .id, .bind, def, captions)`, moved
    /// last into the root.
    menu_list,
};

/// Where a caption's text comes from.
/// `counter`: a list marker inside a run-time region, `text` the Zig expression that formats
/// it from the copy index (into a `mark` buffer the statement declares).
pub const TextKind = enum(u8) { none, literal, field, format, counter };

pub const Node = struct {
    kind: Kind,
    parent: u32,
    loc: diag.Loc,
    /// Containers: `.x` for a row.
    dir: lcgf.types.Axis = .y,
    /// `spec.Landmark` tag for `.landmark`.
    landmark: []const u8 = "",
    /// The node's resolved style, and what its builder gives on its own: `spec.styled` wraps
    /// the builder when they differ.
    style: Style = .{},
    base_style: Style = .{},
    /// Expression for `style.params` (a gradient or dashed border), printed instead of words.
    params_expr: []const u8 = "",
    text_style: TextStyle = .{},
    base_text: TextStyle = .{},
    id: []const u8 = "",
    bind: []const u8 = "",
    text_kind: TextKind = .none,
    /// Literal bytes, the field name, or the format string.
    text: []const u8 = "",
    args: []const []const u8 = &.{},
    /// Accessible name (`aria-label`), or "".
    name: []const u8 = "",
    /// Heading level; separator orientation (0 horizontal); textarea rows.
    level: u8 = 0,
    /// Slider and number ranges: lo, hi, step.
    range: [3]f32 = .{ 0, 1, 0 },
    /// Radio and select captions.
    captions: []const []const u8 = &.{},
    /// An image's entry in `Page.assets`, and how it is shown.
    asset: u32 = none,
    image: lcgf.widgets_image.Options = .{},
    /// A select's group headers (`<optgroup label>`), each before the option at `at`.
    groups: []const lcgf.widgets_select.Group = &.{},
    /// A list's maximum copy count.
    max: u32 = 0,
    /// Engine API from docs/plans/markup-engine-api.md: flex item margins (F2), or null.
    margin: ?[4]f32 = null,
    /// The node's other flex rules (align-self, wrap, baseline, lines, aspect): `spec.flexed`
    /// with `margin` when either differs from the default.
    flex: lcgf.flex.Flex.Style = .{},
    /// Engine spec F17: positioning (`Placed`).
    placed: Placed = .{},
    /// Inside an lcgf-each: the control shows the item's field (`checked="{row.done}"`) and
    /// reports changes (on:change) without writing it.
    one_way: bool = false,
    /// Style fields read from run-time theme tokens, and the text style's.
    uses: []const TokenUse = &.{},
    text_uses: TextTokens = .{},
    /// A label's paragraph style (`spec.paragraph`), or null for none.
    paragraph: ?lcgf.text_stack.Paragraph = null,
    /// A label's text decoration (`spec.decorated`), or null for none.
    decoration: ?lcgf.text_decorations.Style = null,
    /// A label's style runs (inline runs, `spec.spans`), or empty.
    spans: []const lcgf.protocol.Span = &.{},
    /// A text field that is `<input type=password>`: `widgets_textfield.password`.
    secure: bool = false,
    /// A component's props, in attribute order.
    props: []const Prop = &.{},
    /// A part of the widget that CSS restyles apart from its root; none for the theme's.
    part: Part = .none,
    /// A widget with state CSS (`button:hover`) is a recipe widget: these rules follow the
    /// stock recipe's, in cascade order. Empty for the theme widget.
    recipe: []const RecipeRule = &.{},
    /// HTML disabled (its attribute or a `<fieldset disabled>`): the recipe's `States.disabled`.
    disabled: bool = false,
    /// A text field's `required`, `minlength` and `maxlength`, for `:invalid` and `:valid`.
    validation: lcgf.theme_recipes.controls.Validation = .{},
};

/// One node field for every widget's restyled part: one more field per part would exceed
/// `std.MultiArrayList(Node)`'s comptime branch quota.
pub const Part = union(enum) {
    none,
    /// A `<details>`'s header, as CSS on its `<summary>` restyles it.
    header: Style,
    /// A `<dialog>`'s backdrop fill, as `::backdrop`'s background-color sets it (else `dim`).
    backdrop: lcgf.types.Color,
    /// A `<select>`'s option rows and their text, as CSS on its `<option>`s restyles them
    /// (`widgets_select.Options.option`, `.option_text`).
    option: struct { face: Style, text: TextStyle },
};

/// Engine spec F7 and F17: grid tracks and cells, `right`/`bottom` insets and `position: fixed` (`spec.anchored`), the top
/// inset of `position: sticky` (`spec.sticky`), and `z-index` (`spec.layer`). `below` is a
/// negative z-index on a floating box: it is moved before its siblings, so it paints below them
/// and above its parent's background (`Lowerer.stackBelow`).
pub const Placed = struct {
    /// F7: the tracks of a `display: grid` container, and where a grid's child sits
    /// (`grid-column`, `grid-row`, `grid-area`; null for the next free cell).
    grid: ?lcgf.grid.Decl = null,
    cell: ?lcgf.grid.Item = null,
    anchor: ?lcgf.overlay.Place = null,
    sticky: ?f32 = null,
    layer: u8 = 0,
    below: i16 = 0,
};

/// One rule of a widget's recipe: the states and environment it requires (none for the
/// widget's static CSS) and the values it sets; null sets nothing.
pub const RecipeRule = struct {
    require: lcgf.style.States = .{},
    /// `:enabled` forbids `disabled`.
    forbid: lcgf.style.States = .{},
    /// `@media` around the rule, as the environment conditions the recipe matches.
    when: lcgf.style.environment.Conditions = .{},
    fill: ?lcgf.types.Color = null,
    text_color: ?lcgf.types.Color = null,
    border_color: ?lcgf.types.Color = null,
    border: ?f32 = null,
    opacity: ?f32 = null,
};

/// One attribute of an app component: a literal string, a view-state field (`{f}`, passed as
/// `.f` in the spec, its value in a region) or a field of the region's item (`{x.f}`).
pub const Prop = struct {
    name: []const u8,
    kind: enum(u8) { literal, field, item },
    /// The literal bytes, the field's name, or `x.f`.
    value: []const u8,
    /// A literal that names a run-time token's `Tokens` field (`var(--t-x)`): the runtime
    /// form gets the token's value.
    token: bool = false,
    loc: diag.Loc,
};

/// A run-time theme token (`--t-*` under `--runtime-vars=t-`): a field of the generated
/// `Tokens`, read from the caller's `ThemeTable` while the page builds.
pub const Token = struct {
    /// The custom property without its leading dashes (`t-space-m`), and the Zig field.
    css: []const u8,
    field: []const u8,
    kind: enum(u8) { length, color },
    default_px: f32 = 0,
    default_color: lcgf.types.Color = .transparent,
    loc: diag.Loc,
};

/// The style field a token sets.
pub const Target = enum(u8) { pad_left, pad_top, pad_right, pad_bottom, gap, width, height, min_width, min_height, max_width, max_height, border, radius, fill, border_color };

pub const TokenUse = struct { target: Target, token: u32 };

/// Tokens behind a label's text style: its colour and size, inherited as the values are.
pub const TextTokens = struct { color: u32 = none, px: u32 = none };

pub const FieldType = enum(u8) {
    str,
    bool,
    f32,
    u32,
    /// `widgets_textfield.Text(cap)`.
    text,
    /// `widgets_number.Number`.
    number,
    /// `[2]f32`.
    pair,
    /// An enum of `Field.cases` (`lcgf-switch`).
    @"enum",
    /// `widgets_select.SelectState`; its value is `.selected`.
    select,
    /// `widgets_tooltip.Tip`.
    tip,
    /// `widgets_menu.MenuState`.
    menu,
};

pub const Field = struct {
    name: []const u8,
    type: FieldType,
    /// Zig literal of the default; "" for the type's zero.
    default: []const u8 = "",
    cap: u32 = 0,
    /// The tags of an `enum` field, in markup order.
    cases: []const []const u8 = &.{},
    loc: diag.Loc,
    /// Where the type was fixed, and by what, for conflict messages.
    why: []const u8,
};

/// `submit`: Enter in a one-line text control, Ctrl+Enter (Cmd+Enter) in a text area.
/// `choose`: item `item` of a menu was chosen (a click, or Enter on it).
pub const Event = enum(u8) { click, change, submit, choose };

pub const Handler = struct {
    name: []const u8,
    event: Event,
    /// The widget the event is on (its id) and, for `change`, the field it watches.
    widget: []const u8,
    field: []const u8 = "",
    /// The member of `field` that holds the value (`selected` of a select's state), or "".
    member: []const u8 = "",
    payload: ?FieldType = null,
    /// The run-time region the widget is repeated in (its handler also gets the item's index).
    each: []const u8 = "",
    /// A menu's item, for `choose`.
    item: u8 = 0,
    loc: diag.Loc,
};

/// A field of an `each` item the page reads (`{file.name}`), checked against the app's type.
pub const ItemField = struct {
    each: []const u8,
    field: []const u8,
    loc: diag.Loc,
    /// Set when a control or a template reads the field as a value: the type it must have.
    bound: ?FieldType = null,
    /// A two-way binding writes the field: the item list must then be mutable.
    writes: bool = false,
};

/// A local image the page draws (`<img src>`, `background-image: url()`), or the ramp row of
/// a gradient of more than two colours: asset k is texture k + 1. Lowering finds an image and
/// the driver (main.zig) reads and decodes it; lowering makes a ramp itself (no `path`).
pub const Asset = struct {
    /// As written, and resolved against the file that names it.
    src: []const u8,
    path: []const u8,
    loc: diag.Loc,
    /// An SVG's raster size in px: where it is drawn; a side of 0 follows the other by the
    /// SVG's shape, and both 0 is its own size.
    raster: [2]f32 = .{ 0, 0 },
    w: u32 = 0,
    h: u32 = 0,
    /// Premultiplied RGBA8 rows, `w * h * 4` bytes.
    pixels: []const u8 = "",
};

pub const Page = struct {
    /// `<html lcgf-page>`, or the file's stem.
    name: []const u8,
    title: []const u8 = "",
    source: []const u8,
    nodes: std.MultiArrayList(Node) = .empty,
    fields: std.ArrayList(Field) = .empty,
    handlers: std.ArrayList(Handler) = .empty,
    tokens: std.ArrayList(Token) = .empty,
    item_fields: std.ArrayList(ItemField) = .empty,
    assets: std.ArrayList(Asset) = .empty,
    theme: Theme = .{},
    /// The font table from `@font-face`: row k is `Font` k + 1 (0 is the theme's font). Paths
    /// are relative to the page's directory.
    fonts: std.ArrayList(lcgf.font_match.Face) = .empty,
    /// `@font-face` rules' locations, one per row of `fonts`.
    font_locs: std.ArrayList(diag.Loc) = .empty,
    /// `<html lcgf-frontend="runtime">`: the page asks for the runtime frontend.
    runtime: bool = false,
};
