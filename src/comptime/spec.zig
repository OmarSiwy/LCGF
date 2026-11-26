//! Spec: a UI declared as a compile-time value. A spec is a tree of `Spec` nodes that exists
//! only while compiling; the comptime front end (`Ui(State, spec)`) flattens it into read-only
//! tables. Tier 1. Ported from prototype/comptime_ui_probe.zig ("Spec").
//!
//! A component is a plain function that returns a `Spec`; there is no component type, registry
//! or lifecycle. Its result goes in a child tuple like any builder's, and the flattened tables
//! cannot tell it from the same nodes written inline (Muratori, "components are just functions").
//! Parameters are comptime arguments: ids and fields as enum literals, styles and counts as
//! values, and a list of ids as a tuple of enum literals the component loops over.

const std = @import("std");
const types = @import("../core/types.zig");
const fmt = @import("../core/fmt.zig");
const FlexStyle = @import("../layout/flex.zig").Flex.Style;
const grid_zig = @import("../layout/grid.zig");
const overlay = @import("../layout/overlay.zig");
const Style = types.Style;

/// What a spec node is. One byte, as the flattened `kind` table stores it.
pub const Kind = enum(u8) { col, row, label, checkbox, slider };

/// One node of the declaration. Exists only at compile time.
pub const Spec = struct {
    kind: Kind,
    /// Name of an interactive widget; becomes a tag of the generated `Widget` enum. Builders
    /// take it as an enum literal (`.mute`) and store its name, which is what `@Enum` takes.
    id: ?[:0]const u8 = null,
    /// Name of the state field this node shows; builders take it as an enum literal (`.volume`).
    bind: ?[]const u8 = null,
    /// Literal bytes of a label. A bound label reads its bytes from the state instead.
    text: ?[]const u8 = null,
    /// Fully resolved text style for this label; null inherits the page theme.
    text_style: ?types.TextStyle = null,
    /// Paragraph style of this label (line height, spacing, line clamp, ellipsis; set with
    /// `paragraph`); null for none. A page with none measures with plain `Mono`.
    paragraph: ?@import("../text/layout/stack.zig").Paragraph = null,
    /// Underline, overline or line-through of this label (`decorated`); null for none.
    decoration: ?@import("../text/layout/decorations.zig").Style = null,
    /// Style runs of this label's text (inline runs: `spans`); empty for one style.
    spans: []const @import("../text/protocol.zig").Span = &.{},
    /// Layout, paint and semantics, as the runtime front end takes them (`Tree.push`).
    style: Style = .{},
    /// Flex item and container rules beyond `style` (margins, wrap, align-self, aspect,
    /// baselines; layout/flex.zig), set with `flexed`. A page with none carves no flex columns.
    flex: ?FlexStyle = null,
    /// The tracks a `grid` container lays its children out in (layout/grid.zig). A page with
    /// none carves no grid columns.
    grid: ?grid_zig.Decl = null,
    /// Where a child of a `grid` sits (`cell`); null is the next free cell.
    cell: ?grid_zig.Item = null,
    /// Where a floating node sits against its parent's content box or the viewport
    /// (`anchored`; overlay.Anchors). A page with none carves no anchor rows.
    anchor: ?overlay.Place = null,
    /// Distance from the top of the viewport the node sticks at (`sticky`; scroll.Sticky).
    sticky: ?f32 = null,
    /// Stacking layer (`layer`; overlay.Layers): painted above every row of a lower layer, its
    /// subtree with it. A page with every node in layer 0 paints in row order as before.
    layer: u8 = 0,
    children: []const Spec = &.{},
    /// A widget that builds this node itself, for widgets the kinds above do not cover: a
    /// namespace with `push` (and optionally `step`), which the widgets' comptime front end
    /// calls instead of building the node as its kind (src/widgets/base.zig, `ComptimeUi`).
    /// Null for plain nodes. Being a type, it keeps `Spec` a compile-time-only value.
    widget: ?type = null,
    /// Draw-list payload for a host-rendered leaf (ct_interop.canvas or region).
    custom: ?u64 = null,
    /// Accessible name: what a screen reader says for this node. Interactive widgets need one
    /// (validate.zig); set it with `named`.
    name: ?[]const u8 = null,
    /// Set on a node whose rows are reserved but live only when run-time state says so
    /// (`list`); null for a node that always exists. dynamic.zig reads it.
    region: ?Region = null,
    /// A formatted label's format and the fields it shows (`text`); `bind` is null then.
    format: ?Format = null,
    /// Style fields read from the page's run-time theme tokens when the row is pushed
    /// (`tokened`); empty for a constant node.
    tokens: []const TokenUse = &.{},

    /// The state fields this node shows: its `bind`, or a formatted label's arguments.
    pub fn shows(s: Spec, field: []const u8) bool {
        if (s.bind) |b| if (std.mem.eql(u8, b, field)) return true;
        if (s.format) |f| for (f.args) |a| if (std.mem.eql(u8, a, field)) return true;
        return false;
    }
};

/// A style field that a run-time theme token sets (docs/plans/schemify.md §2): a length of
/// the layout or paint style, a colour, or the text style's size or colour.
pub const TokenTarget = enum(u8) { pad_left, pad_top, pad_right, pad_bottom, gap, width, height, min_width, min_height, max_width, max_height, border, radius, fill, border_color, text_px, text_color };

/// Field `target` takes the token named `token`: a field of the page's `Tokens` struct, read
/// from the caller's `theme_table.ThemeTable(Tokens)`.
pub const TokenUse = struct { target: TokenTarget, token: []const u8 };

/// `s` with some style fields read from run-time tokens when its row is pushed:
/// `tokened(col(.{}, .{...}), &.{ .{ .target = .pad_top, .token = "space" } })`.
pub fn tokened(comptime s: Spec, comptime uses: []const TokenUse) Spec {
    if (s.widget != null) @compileError("tokened: a widget builds its own rows; only containers and labels read tokens");
    var out = s;
    out.tokens = uses;
    return out;
}

/// Writes the token values `values` (a `Tokens`) into the fields `uses` names.
pub inline fn applyTokens(comptime uses: []const TokenUse, style: *Style, text_style: *types.TextStyle, values: anytype) void {
    inline for (uses) |u| {
        const v = @field(values, u.token);
        switch (u.target) {
            .pad_left => style.pad[0] = v,
            .pad_top => style.pad[1] = v,
            .pad_right => style.pad[2] = v,
            .pad_bottom => style.pad[3] = v,
            .gap => style.gap = v,
            .width => style.size[0] = .px(v),
            .height => style.size[1] = .px(v),
            .min_width => style.min[0] = v,
            .min_height => style.min[1] = v,
            .max_width => style.max[0] = v,
            .max_height => style.max[1] = v,
            .border => style.border = v,
            .radius => style.radius = v,
            .fill => style.fill = v,
            .border_color => style.border_color = v,
            .text_px => text_style.px = v,
            .text_color => text_style.color = v,
        }
    }
}

/// A formatted label's text (src/core/fmt.zig's language) and its arguments, state fields.
pub const Format = struct { text: []const u8, args: []const []const u8 };

/// What makes a node's rows dynamic, and the state field that decides which are live.
pub const Region = struct {
    kind: RegionKind,
    /// The state field: a list's count (an integer), a `when`'s condition (a bool), a
    /// `choice`'s alternative (an enum, an integer or a bool).
    bind: []const u8,
    /// A windowed list binds its pixel offset and uses a fixed item height.
    window: ?struct { scroll: []const u8, height: f32 } = null,
};

pub const RegionKind = enum(u8) {
    /// A container with `max` copies of a template; the first `count` are live.
    list,
    /// A subtree, itself included, that is live only while its condition holds.
    when,
    /// A container of alternatives of which only the selected one is live.
    choice,
};

/// A tuple of specs as a slice that outlives the call: the copy into a `const` makes it a
/// comptime-known value the compiler interns, so the returned slice stays valid. A slice
/// (a component's `children`) is already one.
fn kids(comptime tuple: anytype) []const Spec {
    if (@TypeOf(tuple) == []const Spec) return tuple;
    const arr: [tuple.len]Spec = tuple;
    const final = arr;
    return &final;
}

/// A vertical container. `children` is a tuple, array or slice of specs:
/// `col(.{ .pad = @splat(8), .gap = 4 }, .{ label(.a), ... })`. Its `dir` is always `.y`.
pub fn col(comptime style: Style, comptime children: anytype) Spec {
    var s = style;
    s.dir = .y;
    return .{ .kind = .col, .style = s, .children = kids(children) };
}

/// A horizontal container; as `col`, with `dir` always `.x`.
pub fn row(comptime style: Style, comptime children: anytype) Spec {
    var s = style;
    s.dir = .x;
    return .{ .kind = .row, .style = s, .children = kids(children) };
}

/// A literal caption (`label("Save")`) or a bound string field (`label(.title)`).
pub fn label(comptime caption: anytype) Spec {
    if (@TypeOf(caption) == @EnumLiteral()) return .{ .kind = .label, .bind = @tagName(caption) };
    const bytes: []const u8 = caption;
    return .{ .kind = .label, .text = bytes };
}

/// Document containers whose role is independent of their layout direction.
pub const Landmark = enum { group, article, region, banner, navigation, main, complementary, content_info, form, search };

/// Preserve the layout and children while exposing this row's document role.
/// Named landmarks can be labelled through the accessibility tree's labelled_by relation.
pub fn landmark(comptime role: Landmark, comptime style: Style, comptime children: anytype) Spec {
    var s = style;
    s.role = @field(types.Role, @tagName(role));
    return if (s.dir == .x) row(s, children) else col(s, children);
}

/// A document heading whose accessibility name is its displayed literal, bound or formatted
/// text: `heading(1, "Mixer")`, `heading(2, .title)` or `heading(1, text("Gain {.1} dB",
/// .{.g}))`. The level is exported on the same row as the text, independent of its visual size.
pub fn heading(comptime level: u8, comptime caption: anytype) Spec {
    if (level < 1 or level > 6) @compileError("a heading level must be between 1 and 6");
    var s = if (@TypeOf(caption) == Spec) caption else label(caption);
    if (s.kind != .label) @compileError("heading: the caption is a literal, a field or a `text` label");
    s.style.role = .heading;
    s.style.value = @floatFromInt(level);
    return s;
}

/// Frame string bytes for all declared literals and accessible names, plus the caller's budget when a bound
/// label or a widget hook can append runtime text. Literal-only pages need exactly their bytes.
pub fn stringCapacity(comptime tree: Spec, comptime dynamic_bytes: u32) u32 {
    var bytes: u32 = 0;
    var dynamic = false;
    countStrings(tree, &bytes, &dynamic);
    return bytes + if (dynamic) dynamic_bytes else 0;
}

fn countStrings(comptime n: Spec, bytes: *u32, dynamic: *bool) void {
    if (n.text) |str| bytes.* += @intCast(str.len);
    // An accessible name is added to the frame's strings too (`ComptimeUi.semantics`).
    if (n.name) |str| bytes.* += @intCast(str.len);
    if (n.widget != null or (n.kind == .label and (n.bind != null or n.format != null))) dynamic.* = true;
    for (n.children) |c| countStrings(c, bytes, dynamic);
}

/// Check the two sources before emitting a label. Custom widget internals may supply their own text.
pub fn labelError(comptime s: Spec) ?[]const u8 {
    const sources = @as(u32, @intFromBool(s.bind != null)) + @intFromBool(s.text != null) + @intFromBool(s.format != null);
    if (sources == 0) return "a label needs a literal, a bound field or a format";
    if (sources > 1) return "a label takes one of literal text, a bound field or a format";
    return null;
}

/// Resolve a label's source at compile time. A literal has no state field or signal mask.
pub inline fn labelBytes(comptime s: Spec, state: anytype) []const u8 {
    if (comptime labelError(s)) |msg| @compileError(msg);
    return if (comptime s.text) |bytes| bytes else @field(state, s.bind.?);
}

/// Text of the state fields `args` written into `format`: `text("Volume {.1} dB", .{.volume})`.
/// `{}` writes a string, bool, u32, u8 or enum field, `{.N}` an f32 with N decimals (0 to 6);
/// `{{` and `}}` are braces (src/core/fmt.zig). Checked while compiling against the state
/// struct. A change of any argument lays the label out again, as a bound label's does.
pub fn text(comptime format: []const u8, comptime args: anytype) Spec {
    var names: [args.len][]const u8 = undefined;
    inline for (args, &names) |a, *n| n.* = @tagName(a);
    const final = names;
    var segs: [fmt.maxSegs(format)]fmt.Seg = undefined;
    _ = fmt.parse(format, &@as([args.len]fmt.Kind, @splat(.str)), &segs) catch |e| switch (e) {
        error.BadFormat => @compileError("text: bad format \"" ++ format ++ "\": use {}, {.N} (N 0 to 6), {{ and }}"),
        // Types are checked against the state struct later; only the count here.
        error.BadArg => {},
    };
    return .{ .kind = .label, .style = .{ .role = .label }, .format = .{ .text = format, .args = &final } };
}

/// A checkbox named `id`, showing and toggling a bool field. The second argument is the field
/// (`checkbox(.mute, .muted)`) or options: `checkbox(.mute, .{ .bind = .muted, .name = "Mute"
/// })`, where `.bind` defaults to the id (`checkbox(.muted, .{ .name = "Muted" })`) and `.name`
/// is the accessible name (as `named`). A misspelt option is a compile error naming it. Size it
/// with `styled`.
pub fn checkbox(comptime id: @EnumLiteral(), comptime bind_or_options: anytype) Spec {
    return widget(.checkbox, id, bind_or_options);
}

/// A slider named `id`, showing and setting an f32 field, 0 to 1: `slider(.volume, .volume)`,
/// or with options as `checkbox`'s, `slider(.volume, .{ .name = "Volume" })`.
pub fn slider(comptime id: @EnumLiteral(), comptime bind_or_options: anytype) Spec {
    return widget(.slider, id, bind_or_options);
}

/// Options a builder reads, with their defaults; any other field is a compile error naming it.
/// A style is not one: in an `anytype` struct a nested `.size = .{ .px(80), ... }` has no type
/// to take its names from, so a style goes through `styled`, whose parameter is a `Style`.
const Options = struct { bind: ?[]const u8 = null, name: ?[]const u8 = null };

fn options(comptime builder: []const u8, comptime o: anytype, comptime allowed: []const []const u8) Options {
    const O = @TypeOf(o);
    if (@typeInfo(O) != .@"struct") @compileError(builder ++ ": expected a field (`.volume`) or options (`.{ .name = ... }`), found " ++ @typeName(O));
    var out: Options = .{};
    for (@typeInfo(O).@"struct".field_names) |f| {
        for (allowed) |a| {
            if (std.mem.eql(u8, a, f)) break;
        } else @compileError(builder ++ ": no option `." ++ f ++ "`; it takes " ++ optionList(allowed));
    }
    if (@hasField(O, "bind")) out.bind = @tagName(o.bind);
    if (@hasField(O, "name")) out.name = o.name;
    return out;
}

fn optionList(comptime names: []const []const u8) []const u8 {
    var out: []const u8 = "";
    for (names, 0..) |n, i| out = out ++ (if (i == 0) "" else ", ") ++ "`." ++ n ++ "`";
    return out;
}

fn widget(comptime kind: Kind, comptime id: @EnumLiteral(), comptime o: anytype) Spec {
    if (@TypeOf(o) == @EnumLiteral()) return .{ .kind = kind, .id = @tagName(id), .bind = @tagName(o) };
    const opt = options(@tagName(kind), o, &.{ "bind", "name" });
    return .{ .kind = kind, .id = @tagName(id), .bind = opt.bind orelse @tagName(id), .name = opt.name };
}

/// `s` laid out by `style`: `styled(slider(.volume, .{ .name = "Volume" }), .{ .size = .{
/// .px(80), .px(10) } })`. A container keeps its axis (`col`, `row`).
pub fn styled(comptime s: Spec, comptime style: Style) Spec {
    var out = s;
    out.style = style;
    if (s.kind == .col or s.kind == .row) out.style.dir = s.style.dir;
    return out;
}

/// Label `s` drawn in `text_style` instead of the page theme's: `textStyled(heading(1,
/// "Mixer"), .{ .px = 28, .color = .rgb(230, 230, 235) })`. Its layout style is unchanged.
pub fn textStyled(comptime s: Spec, comptime text_style: types.TextStyle) Spec {
    if (s.kind != .label) @compileError("textStyled: only a label has a text style");
    var out = s;
    out.text_style = text_style;
    return out;
}

/// Label `s` with paragraph style `p`: `paragraph(label(.a), .{ .line_height = .{ .px = 20 } })`.
/// Measured and wrapped by `protocol.MonoParagraphs`, which honours its line height,
/// letter and word spacing, line clamp and ellipsis.
pub fn paragraph(comptime s: Spec, comptime p: @import("../text/layout/stack.zig").Paragraph) Spec {
    if (s.kind != .label) @compileError("paragraph: only a label has a paragraph style");
    var out = s;
    out.paragraph = p;
    return out;
}

/// Label `s` with text decoration `d`: `decorated(label(.a), .{ .underline = true })`. Drawn
/// by `protocol.MonoParagraphs.decorate` as solid quads after the label's text.
pub fn decorated(comptime s: Spec, comptime d: @import("../text/layout/decorations.zig").Style) Spec {
    if (s.kind != .label) @compileError("decorated: only a label has a text decoration");
    var out = s;
    out.decoration = d;
    return out;
}

/// Label `s` as one paragraph in several styles: from each span's `start` byte on, its text
/// style's size, colour and font: `spans(label("a bold word"), &.{ .{ .start = 2, .style = bold
/// }, .{ .start = 6, .style = plain } })`. Measured and drawn by `protocol.MonoParagraphs`.
pub fn spans(comptime s: Spec, comptime runs: []const @import("../text/protocol.zig").Span) Spec {
    if (s.kind != .label) @compileError("spans: only a label has style runs");
    var out = s;
    out.spans = runs;
    return out;
}

/// `s` laid out with the flex rules `flex` as well as its style: `flexed(label(.a), .{ .margin
/// = .{ 6, 2, 6, 2 } })`. Margins are left, top, right, bottom.
pub fn flexed(comptime s: Spec, comptime flex: FlexStyle) Spec {
    var out = s;
    out.flex = flex;
    return out;
}

/// A grid container: its children in the cells of `decl`'s tracks, one per child unless
/// `cell` places one: `grid(.{}, .{ .columns = &.{ .px(80), .fr(1) } }, .{ label("A"), ... })`.
/// Rows past `decl.rows` are added for the children that need them. Each child floats, so
/// the container's `dir` and `gap` do not apply; `decl.gap` does.
pub fn grid(comptime style: Style, comptime decl: grid_zig.Decl, comptime children: anytype) Spec {
    var s = style;
    s.dir = .y;
    const given = kids(children);
    var items: [given.len]Spec = given[0..given.len].*;
    for (&items) |*c| c.style.float = true;
    const final = items;
    return .{ .kind = .col, .style = s, .grid = decl, .children = &final };
}

/// `s`, a child of a `grid`, placed at `item` (CSS `grid-column`/`grid-row`/`grid-area`):
/// `cell(label("A"), .{ .cell = .{ 1, 0 }, .span = .{ 2, 1 } })`.
pub fn cell(comptime s: Spec, comptime item: grid_zig.Item) Spec {
    var out = s;
    out.cell = item;
    return out;
}

/// `s`, a floating node, placed by `place` instead of at its parent's content origin plus its
/// offset: `anchored(styled(label("New"), .{ .float = true }), .{ .at = .top_right, .pivot =
/// .top_right })`. With `place.viewport` the box is the viewport (CSS `position: fixed`).
pub fn anchored(comptime s: Spec, comptime place: overlay.Place) Spec {
    var out = s;
    out.anchor = place;
    return out;
}

/// `s` held at least `top` pixels below the top of its scroller while its parent's content box
/// has room, as CSS `position: sticky; top: …`. The scroller is the nearest scroll area's
/// viewport (`widgets_scroll`), or the viewport.
pub fn sticky(comptime s: Spec, comptime top: f32) Spec {
    var out = s;
    out.sticky = top;
    return out;
}

/// `s` and its subtree painted in stacking layer `z` (CSS `z-index` on a positioned box):
/// above every row of a lower layer, in row order within one.
pub fn layer(comptime s: Spec, comptime z: u8) Spec {
    var out = s;
    out.layer = z;
    return out;
}

/// The cells `n`'s children ask for, for `grid.implicitTracks`.
pub fn gridItems(comptime n: Spec) []const grid_zig.Item {
    comptime {
        var items: [n.children.len]grid_zig.Item = undefined;
        for (n.children, &items) |c, *it| it.* = c.cell orelse .{};
        const final = items;
        return &final;
    }
}

/// `s` with the accessible name `name`: `named(slider(.volume, .volume), "Volume")`.
pub fn named(comptime s: Spec, comptime name: []const u8) Spec {
    var out = s;
    out.name = name;
    return out;
}

/// A container (laid out by `style`, `dir` included) of `max` copies of `template`, of which
/// the first `count` are live, `count` being the run-time value of the integer state field
/// bound here: `list(.len, 8, .{ .gap = 2 }, row(...))`. Every copy's rows are reserved, so the
/// tables stay read-only and the row count exact; a dead copy takes no space, is not drawn and
/// is not hit (dynamic.zig). A count past `max` shows `max`. Every copy shows the same fields:
/// what differs per item is run-time data the caller keeps by copy index.
pub fn list(comptime count: @EnumLiteral(), comptime max: comptime_int, comptime style: Style, comptime template: Spec) Spec {
    const copies: [max]Spec = @splat(template);
    return .{ .kind = if (style.dir == .x) .row else .col, .style = style, .children = kids(copies), .region = .{ .kind = .list, .bind = @tagName(count) } };
}

/// A clipped vertical list of `visible` fixed-height items. One extra copy holds a
/// partially visible item. For each copy the selection exposes its index in the data
/// as `first + copy`; only the remainder of the scroll offset moves the retained rows.
pub fn virtualList(comptime count: @EnumLiteral(), comptime scroll: @EnumLiteral(), comptime visible: u32, comptime height: f32, comptime template: Spec) Spec {
    if (visible == 0 or visible == std.math.maxInt(u32)) @compileError("virtualList needs a positive visible row count with room for one extra copy");
    const view_height = @as(f32, @floatFromInt(visible)) * height;
    if (!(height > 0) or !std.math.isFinite(view_height)) @compileError("virtualList needs a positive finite item and viewport height");
    // A conditional root may disappear. Its enclosing item still occupies one logical row.
    const conditional = if (template.region) |r| r.kind == .when else false;
    var item = if (conditional) col(.{ .size = .{ .fill, .fit } }, .{template}) else template;
    item.style.size[1] = .px(height);
    item.style.min[1] = height;
    item.style.max[1] = height;
    item.style.float = false;
    var out = list(count, visible + 1, .{ .clip = true, .size = .{ .fill, .px(view_height) } }, item);
    out.region.?.window = .{ .scroll = @tagName(scroll), .height = height };
    return out;
}

/// `subtree`, live only while the bool state field `condition` is true: `when(.advanced,
/// col(...))`. The field may also be a widget's state struct with `pub fn visible(s) bool`
/// (an overlay's open flag, as `widgets_select.SelectState` has). Its rows are reserved
/// either way; while the condition is false they take no space, are not drawn and are not
/// hit, and the parent lays out as if it had no such child.
/// A node has one region: to make a list conditional, wrap it in a `col`.
pub fn when(comptime condition: @EnumLiteral(), comptime subtree: Spec) Spec {
    if (subtree.region != null) @compileError("when: the subtree already has a region; wrap it in a col");
    var out = subtree;
    out.region = .{ .kind = .when, .bind = @tagName(condition) };
    return out;
}

/// A container (laid out by `style`) of `alternatives`, of which only the one at the index of
/// the state field `selector` (an enum, by its value, an integer, or a bool, false selecting the
/// first) is live: `choice(.mode, .{}, .{ compact, detailed })`, or an if/else as `choice(.on,
/// .{}, .{ otherwise, then })`. The alternatives share the container's place in its parent:
/// the parent always has one child there, sized as the live alternative. Static tables describe all
/// alternatives. Their retained geometry shares the space of the largest alternative. A
/// selector past the last alternative shows none.
pub fn choice(comptime selector: @EnumLiteral(), comptime style: Style, comptime alternatives: anytype) Spec {
    return .{ .kind = if (style.dir == .x) .row else .col, .style = style, .children = kids(alternatives), .region = .{ .kind = .choice, .bind = @tagName(selector) } };
}

// ---- tests -------------------------------------------------------------------------------------

const flatten = @import("flatten.zig");
const nodeCount = flatten.count;

/// Parent and end tables of `s` (flatten.Flat), widened to u32 for the tests below.
fn flatTables(comptime s: Spec) [2][nodeCount(s)]u32 {
    comptime {
        const F = flatten.Flat(s);
        var t: [2][nodeCount(s)]u32 = undefined;
        for (&t[0], &t[1], F.parent, F.end) |*p, *e, fp, fe| {
            p.* = fp;
            e.* = fe;
        }
        return t;
    }
}

/// Bit per node of every node bound to `field` and of its ancestors: the probe's dirty mask.
/// Test helper; the real masks are lane ct-signals'.
fn bindMask(comptime s: Spec, comptime field: []const u8) u64 {
    comptime {
        var next: u6 = 0;
        return bindWalk(s, field, 0, &next);
    }
}

fn bindWalk(comptime s: Spec, comptime field: []const u8, comptime path: u64, comptime next: *u6) u64 {
    const here = path | (@as(u64, 1) << next.*);
    next.* += 1;
    var m: u64 = if (s.bind != null and std.mem.eql(u8, s.bind.?, field)) here else 0;
    for (s.children) |c| m |= bindWalk(c, field, here, next);
    return m;
}

/// Depth-first row of the node named `id`: the probe's `Widget` enum value.
fn nodeOf(comptime s: Spec, comptime id: []const u8) comptime_int {
    comptime {
        var i = 0;
        return nodeWalk(s, id, &i) orelse @compileError("no widget '" ++ id ++ "'");
    }
}

fn nodeWalk(comptime s: Spec, comptime id: []const u8, comptime next: *comptime_int) ?comptime_int {
    const i = next.*;
    next.* += 1;
    if (s.id != null and std.mem.eql(u8, s.id.?, id)) return i;
    for (s.children) |c| if (nodeWalk(c, id, next)) |r| return r;
    return null;
}

test "Spec: defaults are an unnamed, unbound, unpadded leaf" {
    const s: Spec = comptime .{ .kind = .label };
    try std.testing.expectEqual(1, @sizeOf(Kind));
    try std.testing.expectEqual(null, s.id);
    try std.testing.expectEqual(null, s.bind);
    try std.testing.expectEqual(Style{}, s.style);
    try std.testing.expectEqual(0, s.children.len);
}

test "Spec: the probe's mixer, written as literals, has 8 nodes" {
    const mixer: Spec = comptime .{ .kind = .col, .style = .{ .pad = @splat(8), .gap = 4 }, .children = &.{
        .{ .kind = .label, .bind = "title" },
        .{ .kind = .row, .style = .{ .dir = .x, .gap = 8 }, .children = &.{
            .{ .kind = .checkbox, .id = "mute", .bind = "muted" },
            .{ .kind = .slider, .id = "volume", .bind = "volume" },
        } },
        .{ .kind = .row, .style = .{ .dir = .x, .gap = 8 }, .children = &.{
            .{ .kind = .label, .bind = "title" },
            .{ .kind = .slider, .id = "pan", .bind = "pan" },
        } },
    } };
    try std.testing.expectEqual(8, comptime nodeCount(mixer));
    try std.testing.expectEqualStrings("volume", mixer.children[1].children[1].id.?);
    try std.testing.expectEqual(Kind.slider, mixer.children[2].children[1].kind);
}

test "col, row: the probe's mixer flattens to the probe's parent and end tables" {
    const mixer = comptime col(.{ .pad = @splat(8), .gap = 4 }, .{
        Spec{ .kind = .label, .bind = "title" },
        row(.{ .gap = 8 }, .{ Spec{ .kind = .checkbox, .id = "mute", .bind = "muted" }, Spec{ .kind = .slider, .id = "volume", .bind = "volume" } }),
        row(.{ .gap = 8 }, .{ Spec{ .kind = .label, .bind = "title" }, Spec{ .kind = .slider, .id = "pan", .bind = "pan" } }),
    });
    const t = comptime flatTables(mixer);
    try std.testing.expectEqualSlices(u32, &.{ 0, 0, 0, 2, 2, 0, 5, 5 }, &t[0]);
    try std.testing.expectEqualSlices(u32, &.{ 8, 2, 5, 4, 5, 8, 7, 8 }, &t[1]);
    try std.testing.expectEqual(Kind.col, mixer.kind);
    try std.testing.expectEqual([4]f32{ 8, 8, 8, 8 }, mixer.style.pad);
    try std.testing.expectEqual(4, mixer.style.gap);
    try std.testing.expectEqual(Kind.row, mixer.children[1].kind);
    try std.testing.expectEqual(8, mixer.children[1].style.gap);
}

test "col, row: an empty tuple is a childless container" {
    const s = comptime row(.{}, .{});
    try std.testing.expectEqual(0, s.children.len);
    try std.testing.expectEqual([4]f32{ 0, 0, 0, 0 }, s.style.pad);
}

/// The probe's usage spec, built as the probe builds it.
const probe_mixer = col(.{ .pad = @splat(8), .gap = 4 }, .{
    label(.title),
    row(.{ .gap = 8 }, .{ checkbox(.mute, .muted), slider(.volume, .volume) }),
    row(.{ .gap = 8 }, .{ label(.title), slider(.pan, .pan) }),
});

test "label, checkbox, slider: the probe's mixer gives the probe's tables, masks and widget rows" {
    const t = comptime flatTables(probe_mixer);
    try std.testing.expectEqual(8, comptime nodeCount(probe_mixer));
    try std.testing.expectEqualSlices(u32, &.{ 0, 0, 0, 2, 2, 0, 5, 5 }, &t[0]);
    try std.testing.expectEqualSlices(u32, &.{ 8, 2, 5, 4, 5, 8, 7, 8 }, &t[1]);
    // volume -> slider (4), its row (2), root (0)
    try std.testing.expectEqual(0b0001_0101, comptime bindMask(probe_mixer, "volume"));
    // title is shown twice: nodes 1 and 6, row 5, root
    try std.testing.expectEqual(0b0110_0011, comptime bindMask(probe_mixer, "title"));
    try std.testing.expectEqual(0b0000_1101, comptime bindMask(probe_mixer, "muted"));
    try std.testing.expectEqual(3, comptime nodeOf(probe_mixer, "mute"));
    try std.testing.expectEqual(4, comptime nodeOf(probe_mixer, "volume"));
    try std.testing.expectEqual(7, comptime nodeOf(probe_mixer, "pan"));
}

test "named: sets the accessible name and nothing else" {
    const s = comptime named(slider(.volume, .volume), "Volume");
    try std.testing.expectEqualStrings("Volume", s.name.?);
    const plain = comptime slider(.volume, .volume);
    try std.testing.expectEqual(null, plain.name);
    try std.testing.expectEqual(plain.kind, s.kind);
    try std.testing.expectEqualStrings(plain.id.?, s.id.?);
    try std.testing.expectEqualStrings(plain.bind.?, s.bind.?);
    try std.testing.expectEqual(plain.style, s.style);
}

test "textStyled: sets the label's text style and nothing else" {
    comptime {
        const plain = heading(1, "Mixer");
        const big = textStyled(plain, .{ .px = 28 });
        std.debug.assert(big.text_style.?.px == 28 and plain.text_style == null);
        std.debug.assert(big.style.role == .heading and std.mem.eql(u8, big.text.?, "Mixer"));
    }
}

test "flexed: sets the flex rules and nothing else" {
    comptime {
        const plain = label("A");
        const m = flexed(plain, .{ .margin = .{ 6, 2, 6, 2 }, .wrap = true });
        std.debug.assert(plain.flex == null and m.flex.?.margin[0] == 6 and m.flex.?.wrap);
        std.debug.assert(std.mem.eql(u8, m.text.?, "A") and std.meta.eql(m.style, plain.style));
    }
}

test "grid, cell: children float in a grid container; cell places one" {
    comptime {
        const g = grid(.{ .pad = @splat(4) }, .{ .columns = &.{ .px(10), .fr(1) } }, .{ label("A"), cell(label("B"), .{ .cell = .{ 1, 0 } }) });
        std.debug.assert(g.grid.?.columns.len == 2 and g.style.pad[0] == 4);
        std.debug.assert(g.children[0].style.float and g.children[1].style.float);
        std.debug.assert(g.children[0].cell == null and g.children[1].cell.?.cell.?[0] == 1);
        std.debug.assert(gridItems(g).len == 2 and gridItems(g)[1].cell.?[0] == 1);
    }
}

test "anchored, sticky, layer: set their field and nothing else" {
    comptime {
        const plain = label("A");
        const a = layer(sticky(anchored(plain, .{ .at = .bottom, .pivot = .top }), 8), 3);
        std.debug.assert(a.anchor.?.at == .bottom and a.sticky.? == 8 and a.layer == 3);
        std.debug.assert(plain.anchor == null and plain.sticky == null and plain.layer == 0);
        std.debug.assert(std.meta.eql(a.style, plain.style));
    }
}

test "options, styled: the same nodes as the positional builders with `named`; bind defaults to the id" {
    comptime {
        const old = named(checkbox(.mute, .muted), "Mute");
        const new = checkbox(.mute, .{ .bind = .muted, .name = "Mute" });
        std.debug.assert(std.meta.eql(old.kind, new.kind));
        std.debug.assert(std.mem.eql(u8, new.id.?, "mute") and std.mem.eql(u8, new.bind.?, "muted") and std.mem.eql(u8, new.name.?, "Mute"));
        const v = styled(slider(.volume, .{ .name = "Volume" }), .{ .size = .{ .px(80), .px(10) } });
        std.debug.assert(std.mem.eql(u8, v.bind.?, "volume") and std.mem.eql(u8, v.name.?, "Volume"));
        std.debug.assert(v.style.size[0].v == 80);
        const r = styled(row(.{}, .{}), .{ .gap = 3 });
        std.debug.assert(r.style.dir == .x and r.style.gap == 3);
        // The tables do not tell the two forms apart.
        const a = flatTables(col(.{}, .{ label(.title), old }));
        const b = flatTables(col(.{}, .{ label(.title), new }));
        std.debug.assert(std.meta.eql(a, b));
    }
}

test "label, checkbox, slider: leaves carry kind, id and binding, no children" {
    const l = comptime label(.title);
    const c = comptime checkbox(.mute, .muted);
    const s = comptime slider(.volume, .volume);
    try std.testing.expectEqual(Kind.label, l.kind);
    try std.testing.expectEqual(null, l.id);
    try std.testing.expectEqualStrings("title", l.bind.?);
    try std.testing.expectEqual(Kind.checkbox, c.kind);
    try std.testing.expectEqualStrings("mute", c.id.?);
    try std.testing.expectEqualStrings("muted", c.bind.?);
    try std.testing.expectEqual(Kind.slider, s.kind);
    try std.testing.expectEqual(0, s.children.len);
}

test "col, row: take the full Style; the container kind fixes the axis" {
    const s = comptime row(.{ .dir = .y, .size = .{ .fill, .px(40) }, .cross = .center, .fill = .rgb(1, 2, 3), .radius = 4, .role = .group }, .{});
    try std.testing.expectEqual(types.Axis.x, s.style.dir);
    try std.testing.expectEqual(types.Size.fill, s.style.size[0]);
    try std.testing.expectEqual(types.Size.px(40), s.style.size[1]);
    try std.testing.expectEqual(types.Align.center, s.style.cross);
    try std.testing.expectEqual(types.Color.rgb(1, 2, 3), s.style.fill);
    try std.testing.expectEqual(4, s.style.radius);
    try std.testing.expectEqual(types.Role.group, s.style.role);
    try std.testing.expectEqual(types.Axis.y, (comptime col(.{ .dir = .x }, .{})).style.dir);
}

test "label, checkbox, slider: enum literals name widgets and fields" {
    const c = comptime checkbox(.mute, .muted);
    try std.testing.expectEqualStrings("mute", c.id.?);
    try std.testing.expectEqualStrings("muted", c.bind.?);
    // The stored id is sentinel-terminated, as `@Enum` takes field names.
    const id: [:0]const u8 = c.id.?;
    try std.testing.expectEqual(0, id[id.len]);
    // Field and Widget tags round-trip: a binding names a field of the state struct.
    const Mixer = struct { title: []const u8 = "", volume: f32 = 0.5, muted: bool = false, pan: f32 = 0 };
    try std.testing.expectEqual(std.meta.FieldEnum(Mixer).muted, std.meta.stringToEnum(std.meta.FieldEnum(Mixer), c.bind.?).?);
}

/// A component: a function that returns a Spec. Used by the composition tests.
fn volumeRow() Spec {
    return row(.{ .gap = 8 }, .{ checkbox(.mute, .muted), slider(.volume, .volume) });
}

/// A component built from another component.
fn mixerBody() Spec {
    return col(.{ .pad = @splat(8), .gap = 4 }, .{ label(.title), volumeRow(), row(.{ .gap = 8 }, .{ label(.title), slider(.pan, .pan) }) });
}

test "composition: a function returning Spec flattens exactly like the nodes written inline" {
    const composed = comptime mixerBody();
    const a = comptime flatTables(composed);
    const b = comptime flatTables(probe_mixer);
    try std.testing.expectEqualDeep(b, a);
    inline for (.{ "title", "volume", "muted", "pan" }) |f|
        try std.testing.expectEqual(comptime bindMask(probe_mixer, f), comptime bindMask(composed, f));
    inline for (.{ "mute", "volume", "pan" }) |w|
        try std.testing.expectEqual(comptime nodeOf(probe_mixer, w), comptime nodeOf(composed, w));
    // Compared while compiling: a `Spec` can hold a type (`widget`), so it has no run-time form.
    comptime {
        @setEvalBranchQuota(10_000);
        std.testing.expectEqualDeep(probe_mixer.children[1], composed.children[1]) catch unreachable;
    }
}

/// A component with parameters: which widgets and fields it uses, and how it is spaced.
fn channel(comptime mute: @EnumLiteral(), comptime muted: @EnumLiteral(), comptime level: @EnumLiteral(), comptime gap: f32) Spec {
    return row(.{ .gap = gap }, .{ checkbox(mute, muted), slider(level, level) });
}

/// A component whose child count is a parameter: one slider per id in `levels`.
fn faders(comptime levels: anytype) Spec {
    var children: [levels.len]Spec = undefined;
    for (&children, levels) |*c, l| c.* = slider(l, l);
    return col(.{}, children);
}

test "parameters: comptime arguments choose ids, fields and style" {
    const s = comptime col(.{ .pad = @splat(8), .gap = 4 }, .{ label(.title), channel(.mute, .muted, .volume, 8), row(.{ .gap = 8 }, .{ label(.title), slider(.pan, .pan) }) });
    comptime {
        @setEvalBranchQuota(10_000);
        std.testing.expectEqualDeep(probe_mixer, s) catch unreachable;
    }
    const other = comptime channel(.solo, .soloed, .gain, 2);
    try std.testing.expectEqualStrings("solo", other.children[0].id.?);
    try std.testing.expectEqualStrings("soloed", other.children[0].bind.?);
    try std.testing.expectEqualStrings("gain", other.children[1].id.?);
    try std.testing.expectEqual(2, other.style.gap);
}

test "parameters: a tuple of ids sets the child count" {
    const s = comptime faders(.{ .a, .b, .c });
    try std.testing.expectEqual(4, comptime nodeCount(s));
    try std.testing.expectEqualSlices(u32, &.{ 0, 0, 0, 0 }, &(comptime flatTables(s))[0]);
    try std.testing.expectEqual(3, comptime nodeOf(s, "c"));
    try std.testing.expectEqual(0b1001, comptime bindMask(s, "c"));
    try std.testing.expectEqual(0, (comptime faders(.{})).children.len);
}

test "document semantics: landmark roles share existing row kinds and headings accept bound or literal text" {
    inline for (std.enums.values(Landmark)) |role| {
        const tree = comptime landmark(role, .{ .dir = .x }, .{});
        try std.testing.expectEqual(@field(types.Role, @tagName(role)), tree.style.role);
        try std.testing.expectEqual(Kind.row, tree.kind);
    }
    const h1 = comptime heading(1, "Start");
    const h6 = comptime heading(6, .title);
    try std.testing.expectEqual(Kind.label, h1.kind);
    try std.testing.expectEqual(types.Role.heading, h1.style.role);
    try std.testing.expectEqual(1, h1.style.value);
    try std.testing.expectEqual(6, h6.style.value);
    try std.testing.expectEqualStrings("Start", h1.text.?);
    try std.testing.expectEqualStrings("title", h6.bind.?);
    const g = comptime heading(2, text("Gain {.1} dB", .{.g}));
    try std.testing.expectEqual(types.Role.heading, g.style.role);
    try std.testing.expectEqual(2, g.style.value);
    try std.testing.expectEqualStrings("Gain {.1} dB", g.format.?.text);
    try std.testing.expectEqualStrings("g", g.format.?.args[0]);
}
