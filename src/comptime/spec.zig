//! Spec: a UI declared as a compile-time value. A spec is a tree of `Spec` nodes that exists
//! only while compiling; the comptime front end (`Ui(State, spec)`) flattens it into read-only
//! tables. Tier 1. Ported from prototype/comptime_ui_probe.zig ("Spec").

const std = @import("std");
const types = @import("../core/types.zig");
const Style = types.Style;

/// What a spec node is. One byte, as the flattened `kind` table stores it.
pub const Kind = enum(u8) { col, row, label, checkbox, slider };

/// One node of the declaration. Exists only at compile time.
pub const Spec = struct {
    kind: Kind,
    /// Name of an interactive widget; becomes a tag of the generated `Widget` enum.
    id: ?[:0]const u8 = null,
    /// Name of the state field this node shows.
    bind: ?[]const u8 = null,
    /// Layout, paint and semantics, as the runtime front end takes them (`Tree.push`).
    style: Style = .{},
    children: []const Spec = &.{},
};

/// A tuple of specs as a slice that outlives the call: the copy into a `const` makes it a
/// comptime-known value the compiler interns, so the returned slice stays valid.
fn kids(comptime tuple: anytype) []const Spec {
    const arr: [tuple.len]Spec = tuple;
    const final = arr;
    return &final;
}

/// A vertical container. `children` is a tuple of specs:
/// `col(.{ .pad = @splat(8), .gap = 4 }, .{ label("a"), ... })`. Its `dir` is always `.y`.
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

/// Text showing the state field `bind`.
pub fn label(comptime bind: []const u8) Spec {
    return .{ .kind = .label, .bind = bind };
}

/// A checkbox named `id`, showing and toggling the bool field `bind`.
pub fn checkbox(comptime id: [:0]const u8, comptime bind: []const u8) Spec {
    return .{ .kind = .checkbox, .id = id, .bind = bind };
}

/// A slider named `id`, showing and setting the f32 field `bind`.
pub fn slider(comptime id: [:0]const u8, comptime bind: []const u8) Spec {
    return .{ .kind = .slider, .id = id, .bind = bind };
}

// ---- tests -------------------------------------------------------------------------------------

/// Nodes in `s`, itself included. Test helper; the front end's own count is lane ct-flatten's.
fn nodeCount(comptime s: Spec) comptime_int {
    var n = 1;
    for (s.children) |c| n += nodeCount(c);
    return n;
}

/// Parent and end tables of `s` in depth-first order, as the probe's `Ui` computes them.
/// Test helper: lets the probe's table expectations run before lane ct-flatten ports `Ui`.
fn flatTables(comptime s: Spec) [2][nodeCount(s)]u32 {
    comptime {
        var t: [2][nodeCount(s)]u32 = undefined;
        var next: u32 = 0;
        flatWalk(s, 0, &next, &t);
        return t;
    }
}

fn flatWalk(comptime s: Spec, comptime parent: u32, comptime next: *u32, comptime t: anytype) void {
    const i = next.*;
    next.* += 1;
    t[0][i] = parent;
    for (s.children) |c| flatWalk(c, i, next, t);
    t[1][i] = next.*;
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
    const here = path | @as(u64, 1) << next.*;
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
    label("title"),
    row(.{ .gap = 8 }, .{ checkbox("mute", "muted"), slider("volume", "volume") }),
    row(.{ .gap = 8 }, .{ label("title"), slider("pan", "pan") }),
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
    const l = comptime label("title");
    const c = comptime checkbox("mute", "muted");
    const s = comptime slider("volume", "volume");
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
