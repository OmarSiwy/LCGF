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
const Style = types.Style;

/// What a spec node is. One byte, as the flattened `kind` table stores it.
pub const Kind = enum(u8) {
    col,
    row,
    label,
    checkbox,
    slider,
    /// A horizontal container that is clicked as a whole (src/widgets/button.zig).
    button,
    /// A group of `radio_option`s choosing one value of its bound field (src/widgets/radio.zig).
    radio,
    /// One choice of a `radio` group; `index` is the value it selects.
    radio_option,
    /// An on/off switch over a bool field (src/widgets/switch.zig).
    @"switch",
    /// A button that stays pressed, over a bool field (src/widgets/toggle.zig).
    toggle,
};

/// One node of the declaration. Exists only at compile time.
pub const Spec = struct {
    kind: Kind,
    /// Name of an interactive widget; becomes a tag of the generated `Widget` enum. Builders
    /// take it as an enum literal (`.mute`) and store its name, which is what `@Enum` takes.
    id: ?[:0]const u8 = null,
    /// Name of the state field this node shows; builders take it as an enum literal (`.volume`).
    bind: ?[]const u8 = null,
    /// Layout, paint and semantics, as the runtime front end takes them (`Tree.push`).
    style: Style = .{},
    children: []const Spec = &.{},
    /// Which of several a node is, for widgets made of numbered parts: a radio option's value.
    index: u32 = 0,
    /// The range of a value widget (a slider): its value runs `lo` to `hi`.
    lo: f32 = 0,
    hi: f32 = 1,
};

/// A tuple of specs as a slice that outlives the call: the copy into a `const` makes it a
/// comptime-known value the compiler interns, so the returned slice stays valid.
fn kids(comptime tuple: anytype) []const Spec {
    const arr: [tuple.len]Spec = tuple;
    const final = arr;
    return &final;
}

/// A vertical container. `children` is a tuple (or array) of specs:
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

/// Text showing the state field `bind`: `label(.title)`.
pub fn label(comptime bind: @EnumLiteral()) Spec {
    return .{ .kind = .label, .bind = @tagName(bind) };
}

/// A checkbox named `id`, showing and toggling the bool field `bind`: `checkbox(.mute, .muted)`.
pub fn checkbox(comptime id: @EnumLiteral(), comptime bind: @EnumLiteral()) Spec {
    return .{ .kind = .checkbox, .id = @tagName(id), .bind = @tagName(bind) };
}

/// A slider named `id`, showing and setting the f32 field `bind`: `slider(.volume, .volume)`.
pub fn slider(comptime id: @EnumLiteral(), comptime bind: @EnumLiteral()) Spec {
    return .{ .kind = .slider, .id = @tagName(id), .bind = @tagName(bind) };
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
    try std.testing.expectEqualDeep(probe_mixer.children[1], composed.children[1]);
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
    try std.testing.expectEqualDeep(probe_mixer, s);
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
