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
    /// `widgets_spacer.ct.spacer(axis)`: free space for `justify-content: space-*`.
    spacer,
    /// `<template lcgf-each="item in items">`: a run-time region (`ct_interop.region`) the page
    /// fills with one copy of its content per element of the app's `items`. `bind` is the
    /// list, `text` the item's name, `id` the region's id; `max` and `level` its node and text
    /// capacity.
    each,
};

/// Where a caption's text comes from.
pub const TextKind = enum(u8) { none, literal, field, format };

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
    /// Radio captions.
    captions: []const []const u8 = &.{},
    /// A list's maximum copy count.
    max: u32 = 0,
    /// Engine API from docs/plans/markup-engine-api.md: flex item margins (F2), or null.
    margin: ?[4]f32 = null,
    /// Style fields read from run-time theme tokens, and the text style's.
    uses: []const TokenUse = &.{},
    text_uses: TextTokens = .{},
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
pub const Event = enum(u8) { click, change, submit };

pub const Handler = struct {
    name: []const u8,
    event: Event,
    /// The widget the event is on (its id) and, for `change`, the field it watches.
    widget: []const u8,
    field: []const u8 = "",
    payload: ?FieldType = null,
    /// The run-time region the widget is repeated in (its handler also gets the item's index).
    each: []const u8 = "",
    loc: diag.Loc,
};

/// A field of an `each` item the page reads (`{file.name}`), checked against the app's type.
pub const ItemField = struct { each: []const u8, field: []const u8, loc: diag.Loc };

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
    theme: Theme = .{},
    /// `<html lcgf-frontend="runtime">`: the page asks for the runtime frontend.
    runtime: bool = false,
};
