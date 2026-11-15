//! Spec: a UI declared as a compile-time value. A spec is a tree of `Spec` nodes that exists
//! only while compiling; the comptime front end (`Ui(State, spec)`) flattens it into read-only
//! tables. Tier 1. Ported from prototype/comptime_ui_probe.zig ("Spec").

const std = @import("std");

/// What a spec node is. One byte, as the flattened `kind` table stores it.
pub const Kind = enum(u8) { col, row, label, checkbox, slider };

/// One node of the declaration. Exists only at compile time.
pub const Spec = struct {
    kind: Kind,
    /// Name of an interactive widget; becomes a tag of the generated `Widget` enum.
    id: ?[:0]const u8 = null,
    /// Name of the state field this node shows.
    bind: ?[]const u8 = null,
    pad: u8 = 0,
    gap: u8 = 0,
    children: []const Spec = &.{},
};

/// A tuple of specs as a slice that outlives the call: the copy into a `const` makes it a
/// comptime-known value the compiler interns, so the returned slice stays valid.
fn kids(comptime tuple: anytype) []const Spec {
    const arr: [tuple.len]Spec = tuple;
    const final = arr;
    return &final;
}

/// A vertical container. `children` is a tuple of specs: `col(.{ .pad = 8 }, .{ label("a"), ... })`.
pub fn col(comptime s: struct { pad: u8 = 0, gap: u8 = 0 }, comptime children: anytype) Spec {
    return .{ .kind = .col, .pad = s.pad, .gap = s.gap, .children = kids(children) };
}

/// A horizontal container; as `col`.
pub fn row(comptime s: struct { pad: u8 = 0, gap: u8 = 0 }, comptime children: anytype) Spec {
    return .{ .kind = .row, .pad = s.pad, .gap = s.gap, .children = kids(children) };
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

test "Spec: defaults are an unnamed, unbound, unpadded leaf" {
    const s: Spec = comptime .{ .kind = .label };
    try std.testing.expectEqual(1, @sizeOf(Kind));
    try std.testing.expectEqual(null, s.id);
    try std.testing.expectEqual(null, s.bind);
    try std.testing.expectEqual(0, s.pad);
    try std.testing.expectEqual(0, s.gap);
    try std.testing.expectEqual(0, s.children.len);
}

test "Spec: the probe's mixer, written as literals, has 8 nodes" {
    const mixer: Spec = comptime .{ .kind = .col, .pad = 8, .gap = 4, .children = &.{
        .{ .kind = .label, .bind = "title" },
        .{ .kind = .row, .gap = 8, .children = &.{
            .{ .kind = .checkbox, .id = "mute", .bind = "muted" },
            .{ .kind = .slider, .id = "volume", .bind = "volume" },
        } },
        .{ .kind = .row, .gap = 8, .children = &.{
            .{ .kind = .label, .bind = "title" },
            .{ .kind = .slider, .id = "pan", .bind = "pan" },
        } },
    } };
    try std.testing.expectEqual(8, comptime nodeCount(mixer));
    try std.testing.expectEqualStrings("volume", mixer.children[1].children[1].id.?);
    try std.testing.expectEqual(Kind.slider, mixer.children[2].children[1].kind);
}

test "col, row: the probe's mixer flattens to the probe's parent and end tables" {
    const mixer = comptime col(.{ .pad = 8, .gap = 4 }, .{
        Spec{ .kind = .label, .bind = "title" },
        row(.{ .gap = 8 }, .{ Spec{ .kind = .checkbox, .id = "mute", .bind = "muted" }, Spec{ .kind = .slider, .id = "volume", .bind = "volume" } }),
        row(.{ .gap = 8 }, .{ Spec{ .kind = .label, .bind = "title" }, Spec{ .kind = .slider, .id = "pan", .bind = "pan" } }),
    });
    const t = comptime flatTables(mixer);
    try std.testing.expectEqualSlices(u32, &.{ 0, 0, 0, 2, 2, 0, 5, 5 }, &t[0]);
    try std.testing.expectEqualSlices(u32, &.{ 8, 2, 5, 4, 5, 8, 7, 8 }, &t[1]);
    try std.testing.expectEqual(Kind.col, mixer.kind);
    try std.testing.expectEqual(8, mixer.pad);
    try std.testing.expectEqual(4, mixer.gap);
    try std.testing.expectEqual(Kind.row, mixer.children[1].kind);
    try std.testing.expectEqual(8, mixer.children[1].gap);
}

test "col, row: an empty tuple is a childless container" {
    const s = comptime row(.{}, .{});
    try std.testing.expectEqual(0, s.children.len);
    try std.testing.expectEqual(0, s.pad);
}
