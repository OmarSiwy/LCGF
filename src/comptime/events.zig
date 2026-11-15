//! Events: the comptime front end's input side. Interactive widgets (spec nodes with an id)
//! become a generated `Widget` enum, so handling them is an exhaustive switch. Tier 1. Ported
//! from prototype/comptime_ui_probe.zig (`Ui().Widget` via `@Enum`).

const std = @import("std");
const spec_zig = @import("spec.zig");
const Spec = spec_zig.Spec;
const Kind = spec_zig.Kind;
const flatten = @import("flatten.zig");

/// The interactive widgets of `spec` and how input reaches them.
pub fn Events(comptime spec: Spec) type {
    const F = flatten.Flat(spec);
    const count = blk: {
        @setEvalBranchQuota(1000 + 8 * F.node_count);
        break :blk widgetCount(spec);
    };
    return struct {
        pub const Index = F.Index;
        /// Widgets: spec nodes with an id.
        pub const widget_count = count;

        const Ids = struct { names: [count][:0]const u8, nodes: [count]Index, kinds: [count]Kind };
        const ids: Ids = blk: {
            @setEvalBranchQuota(1000 + 8 * F.node_count);
            var out: Ids = undefined;
            var row: usize = 0;
            var k: usize = 0;
            idsWalk(spec, &row, &k, &out);
            break :blk out;
        };

        fn idsWalk(comptime node: Spec, comptime row: *usize, comptime k: *usize, comptime out: *Ids) void {
            if (node.id) |name| {
                out.names[k.*] = name;
                out.nodes[k.*] = row.*;
                out.kinds[k.*] = node.kind;
                k.* += 1;
            }
            row.* += 1;
            for (node.children) |c| idsWalk(c, row, k, out);
        }

        /// One tag per widget, in row order; a tag's value is its node's row, as in the probe
        /// (`@backingInt(Widget.volume) == 4`). A duplicate id is a compile error. Without
        /// widgets it is an empty enum.
        pub const Widget = if (count == 0) enum {} else @Enum(Index, .exhaustive, &ids.names, &ids.nodes);

        /// Row of each widget, in widget order (the order of `Widget`'s tags).
        pub const widget_nodes: [count]Index = ids.nodes;
        /// Kind of each widget, in widget order.
        pub const widget_kinds: [count]Kind = ids.kinds;

        /// The widget's position in widget order: its index into the per-widget tables.
        pub fn slot(comptime w: Widget) usize {
            return comptime std.mem.indexOfScalar(Index, &widget_nodes, @backingInt(w)).?;
        }

        /// The widget at position `k` of widget order.
        pub fn widget(k: usize) Widget {
            return @fromBackingInt(widget_nodes[k]);
        }
    };
}

/// Spec nodes in `node`'s subtree with an id.
fn widgetCount(comptime node: Spec) comptime_int {
    var k: comptime_int = @intFromBool(node.id != null);
    for (node.children) |c| k += widgetCount(c);
    return k;
}

// ---- tests -------------------------------------------------------------------------------------

const testing = std.testing;
const s = spec_zig;

/// The probe's usage spec.
const mixer = s.col(.{ .pad = @splat(8), .gap = 4 }, .{
    s.label(.title),
    s.row(.{ .gap = 8 }, .{ s.checkbox(.mute, .muted), s.slider(.volume, .volume) }),
    s.row(.{ .gap = 8 }, .{ s.label(.title), s.slider(.pan, .pan) }),
});
const App = Events(mixer);

test "Widget: one tag per id, valued by its node's row" {
    try testing.expectEqual(3, App.widget_count);
    try testing.expectEqual(u4, @typeInfo(App.Widget).@"enum".tag_type);
    try testing.expectEqual(3, @backingInt(App.Widget.mute));
    try testing.expectEqual(4, @backingInt(App.Widget.volume));
    try testing.expectEqual(7, @backingInt(App.Widget.pan));
    try testing.expectEqualSlices(u4, &.{ 3, 4, 7 }, &App.widget_nodes);
    try testing.expectEqualSlices(Kind, &.{ .checkbox, .slider, .slider }, &App.widget_kinds);
    try testing.expectEqual(1, App.slot(.volume));
    try testing.expectEqual(App.Widget.pan, App.widget(2));
    try testing.expectEqual(0, Events(s.label(.x)).widget_count);
}

/// The probe's exhaustive-switch example: what a click on each widget does.
fn onClick(w: App.Widget, muted: *bool, touched: *u32) void {
    switch (w) { // forgetting a widget here is a compile error
        .mute => muted.* = !muted.*,
        .volume, .pan => touched.* += 1,
    }
}

test "Widget: event handling is an exhaustive switch" {
    var muted = false;
    var touched: u32 = 0;
    onClick(.mute, &muted, &touched);
    onClick(.volume, &muted, &touched);
    onClick(App.widget(2), &muted, &touched);
    try testing.expect(muted);
    try testing.expectEqual(2, touched);
}

/// One root over `n` sliders, each with an id: a large widget enum.
fn manySliders(comptime n: comptime_int) Spec {
    @setEvalBranchQuota(2000 * n); // comptimePrint's format parsing
    var leaves: [n]Spec = undefined;
    for (&leaves, 0..) |*l, k| l.* = .{ .kind = .slider, .id = std.fmt.comptimePrint("s{d}", .{k}), .bind = "x" };
    return s.row(.{}, leaves);
}
const many = manySliders(2000);

test "Widget: large specs need no quota from the caller" {
    const M = Events(many);
    try testing.expectEqual(2000, M.widget_count);
    try testing.expectEqual(2000, @backingInt(@field(M.Widget, "s1999")));
}
