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

// ---- tests -------------------------------------------------------------------------------------

/// Nodes in `s`, itself included. Test helper; the front end's own count is lane ct-flatten's.
fn nodeCount(comptime s: Spec) comptime_int {
    var n = 1;
    for (s.children) |c| n += nodeCount(c);
    return n;
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
