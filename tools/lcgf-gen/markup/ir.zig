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
};

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

pub const Event = enum(u8) { click, change };

pub const Handler = struct {
    name: []const u8,
    event: Event,
    /// The widget the event is on (its id) and, for `change`, the field it watches.
    widget: []const u8,
    field: []const u8 = "",
    payload: ?FieldType = null,
    loc: diag.Loc,
};

pub const Page = struct {
    /// `<html lcgf-page>`, or the file's stem.
    name: []const u8,
    title: []const u8 = "",
    source: []const u8,
    nodes: std.MultiArrayList(Node) = .empty,
    fields: std.ArrayList(Field) = .empty,
    handlers: std.ArrayList(Handler) = .empty,
    theme: Theme = .{},
};
