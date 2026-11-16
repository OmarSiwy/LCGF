//! Spacer (tier 2): empty space that pushes its siblings apart, as a flexible gap in a row or
//! column: `[Open] [Save] <spacer> [Close]` puts Close at the far end. One leaf node, no state,
//! nothing painted. Written against the public API of tiers 0 and 1 (src/widgets/base.zig has
//! the recipe).
//!
//! Runtime: `spacer.spacer(f, .x)`. Comptime: `spacer.ct.spacer(.x)`.

const std = @import("std");
const base = @import("base.zig");
const types = @import("../core/types.zig");
const Frame = @import("../runtime/frame.zig").Frame;
const spec_zig = @import("../comptime/spec.zig");
const Spec = spec_zig.Spec;
const Style = types.Style;
const Node = types.Node;
const Axis = types.Axis;
const Theme = base.Theme;

// ---- spec ---------------------------------------------------------------------------------

/// Space along `axis`, the axis of the row (`.x`) or column (`.y`) it sits in.
pub fn spacer(f: *Frame, axis: Axis) Node {
    return f.leaf(.none, style(axis));
}

/// The spacer's node: it fills what is left along `axis` (`Size.fill`), so siblings after it
/// go to the far end, and is 0 across, so it never widens its parent. Unpainted in every
/// theme; the axis picks the size by table index.
pub fn style(axis: Axis) Style {
    const sizes = [2][2]types.Size{ .{ .fill, .px(0) }, .{ .px(0), .fill } };
    return .{ .size = sizes[@backingInt(axis)], .role = .none };
}

// ---- accessibility ------------------------------------------------------------------------

// A spacer is presentational: role `none` (the style's), so `a11y.flatten` leaves it out of
// the exported tree. It has no name, value 0 and no states.

/// The spacer as a spec node.
pub const ct = struct {
    /// Space along `axis`. It binds no state and takes no input, so it has no id or field;
    /// `axis` must be an `Axis` literal (a compile error otherwise).
    pub fn spacer(comptime axis: Axis) Spec {
        return .{ .kind = .col, .style = style(axis) };
    }
};

// ---- tests --------------------------------------------------------------------------------

const testing = std.testing;
const Input = @import("../core/input.zig").Input;
const check = @import("check.zig");

/// The example page: a toolbar row of two buttons, a spacer and a third button, and a column
/// with a label, a spacer and a label at its foot, in both front ends, in theme `th`.
pub fn Page(comptime th: Theme) type {
    const bar: Style = .{ .dir = .x, .size = .{ .fill, .fit }, .pad = @splat(8), .gap = 8, .fill = th.panel };
    const side: Style = .{ .dir = .y, .size = .{ .px(120), .fill }, .pad = @splat(8) };
    const page: Style = .{ .dir = .y, .size = .{ .fill, .fill } };
    return struct {
        pub const App = struct {
            closes: u32 = 0,
            pub fn build(app: *App, f: *Frame) void {
                _ = f.open(.none, page);
                _ = f.open(.none, bar);
                _ = base.button(f, &th, .from("open"), "Open");
                _ = base.button(f, &th, .from("save"), "Save");
                _ = spacer(f, .x);
                app.closes += @intFromBool(base.button(f, &th, .from("close"), "Close").clicked);
                f.close();
                _ = f.open(.none, side);
                _ = base.label(f, &th, "Top");
                _ = spacer(f, .y);
                _ = base.label(f, &th, "Foot");
                f.close();
                f.close();
            }
        };
        pub const State = struct {
            open_text: []const u8 = "Open",
            save_text: []const u8 = "Save",
            close_text: []const u8 = "Close",
            top: []const u8 = "Top",
            foot: []const u8 = "Foot",
        };
        pub const spec = spec_zig.col(page, .{
            spec_zig.row(bar, .{ base.ct.button(th, .open, .open_text), base.ct.button(th, .save, .save_text), ct.spacer(.x), base.ct.button(th, .close, .close_text) }),
            spec_zig.col(side, .{ base.ct.label(th, .top), ct.spacer(.y), base.ct.label(th, .foot) }),
        });
        pub const Ui = base.ComptimeUi(State, spec, th);
        pub const Run = base.Harness(App, Ui, .{ .nodes = 32, .texts = 8, .customs = 1, .strings = 256, .depth = 8 });
    };
}

/// Input for `Page(.default)` at 320 x 200, one commented line per frame.
pub const replay = @embedFile("testdata/spacer.replay");

/// The frames of `replay` kept as golden images (tools/widgetgolden/ref/spacer-<name>.png).
pub const golden_frames = .{
    .{ "rest", 0 },
    .{ "hover", 3 },
};

const Default = Page(.default);
var harness: Default.Run = .{};

test "spacer: both front ends build one empty leaf where it is placed" {
    const h = &harness;
    h.init();
    const in: Input = .{ .viewport = .{ 320, 200 } };
    const out = try h.frame(&in);
    const t = out.runtime.tree;
    // root, page, bar, open+label, save+label, spacer, close+label, side, top, spacer, foot
    try testing.expectEqual(@as(u32, 14), t.len);
    try testing.expectEqual(t.c.end[7], 8);
    try testing.expectEqual(t.c.end[12], 13);
}

test "spacer: takes the space left, pushing later siblings to the far end; paints nothing" {
    const h = &harness;
    h.init();
    const in: Input = .{ .viewport = .{ 320, 200 } };
    const out = try h.frame(&in);
    const t = out.runtime.tree;
    const bar = t.rect(2);
    const close = t.rect(t.find(.from("close")));
    const gap = t.rect(7);
    try testing.expectEqual(bar.x1 - 8, close.x1);
    try testing.expectEqual(t.rect(t.find(.from("save"))).x1 + 8, gap.x0);
    try testing.expectEqual(close.x0 - 8, gap.x1);
    try testing.expectEqual(@as(f32, 0), gap.h());
    const side = t.rect(10);
    try testing.expectEqual(side.y1 - 8, t.rect(13).y1);
    try testing.expectEqual(@as(f32, 0), t.rect(12).w());
    // Drawn: the bar and three buttons; neither spacer has a quad.
    try testing.expectEqual(@as(u32, 4), out.runtime.draw.quad_len);
    try testing.expectEqual(types.Color.transparent.bitsOf(), t.c.look[7].fill);
}

test "spacer: takes no input; hit testing and the tab order skip it" {
    const h = &harness;
    h.init();
    var in: Input = .{ .viewport = .{ 320, 200 } };
    var out = try h.frame(&in);
    // Press and release in the middle of the bar's gap: nothing is held, focused or clicked.
    const g = out.runtime.tree.rect(7);
    in.pointer = .{ (g.x0 + g.x1) * 0.5, 20 };
    in.buttons.left = true;
    _ = try h.frame(&in);
    try testing.expectEqual(@as(u32, 0), h.ctx.inter.active);
    try testing.expectEqual(@as(?Default.Ui.Events.Widget, null), h.ui.pointer.pressed);
    in.buttons.left = false;
    out = try h.frame(&in);
    try testing.expectEqual(@as(u32, 0), h.ctx.inter.focus);
    try testing.expectEqual(@as(u32, 0), h.app.closes);
    try check.expectInert(out.runtime.tree, &.{ 7, 12 });
    // Only the three buttons are widgets in the comptime front end.
    try testing.expectEqual(3, Default.Ui.Events.widget_count);
}

test "spacer: role none, so not exported; no name, value 0, no states, in both front ends" {
    const a11y = @import("../a11y/tree.zig");
    const mem = @import("../core/mem.zig");
    const h = &harness;
    h.init();
    const in: Input = .{ .viewport = .{ 320, 200 } };
    const out = try h.frame(&in);
    const Buf = struct {
        const bytes = blk: {
            var counter: mem.Carver = .{ .buf = null };
            _ = a11y.Export.init(&counter, 32);
            break :blk counter.off;
        };
        var buf: [bytes]u8 align(mem.column_align) = undefined;
    };
    var sb: check.SemBuf = undefined;
    const trees = [2]*const @import("../core/tree.zig").Tree{ out.runtime.tree, out.comptime_.tree };
    const texts = [2]*const @import("../core/texts.zig").Texts{ out.runtime.texts, &h.ui.tables.tx };
    const strings = [2][]const u8{ h.ctx.strings[h.ctx.cur].buf, h.ui.tables.strings.buf };
    for (trees, texts, strings) |t, tx, str| {
        var sem = sb.init();
        a11y.names(t, &sem);
        a11y.states(t, &sem);
        var carver: mem.Carver = .{ .buf = &Buf.buf };
        var ex = a11y.Export.init(&carver, 32);
        a11y.flatten(t, tx, str, &sem, &ex);
        for ([2]u32{ 7, 12 }) |r| {
            try testing.expectEqual(@backingInt(a11y.Role.none), t.c.role[r]);
            try testing.expectEqual(types.none, sem.c.name[r]);
            try testing.expectEqual(@as(f32, 0), t.c.value[r]);
            try testing.expectEqual(@as(u8, 0), sem.c.state[r]);
            for (ex.c.node[0..ex.len]) |node| try testing.expect(node != r);
        }
        // The buttons and labels around them are exported.
        try testing.expect(ex.len >= 8);
    }
}

test "spacer: the example replay gives the same frames in both front ends" {
    const Replay = @import("../core/input.zig").Replay;
    const h = &harness;
    h.init();
    var text: [16]u8 = undefined;
    var evs: [8]Input.Event = undefined;
    var contacts: [1]Input.Contact = undefined;
    const buf: Replay.Buffers = .{ .text = &text, .events = &evs, .contacts = &contacts };
    var rp: Replay = .{ .src = replay };
    var clicks: [6]bool = undefined;
    var fills: [6]u32 = undefined;
    while (try rp.next(buf)) |in| {
        const k = h.frames;
        const out = try h.frame(in);
        const t = out.runtime.tree;
        clicks[k] = if (out.comptime_.event) |e| e == .close else false;
        fills[k] = t.c.look[t.find(.from("close"))].fill;
        // Close stays at the far end every frame.
        try testing.expectEqual(t.rect(2).x1 - 8, t.rect(t.find(.from("close"))).x1);
    }
    try testing.expectEqual(@as(u32, 6), h.frames);
    try testing.expectEqualSlices(bool, &.{ false, false, false, false, false, true }, &clicks);
    try testing.expectEqual(@as(u32, 1), h.app.closes);
    const c = Theme.default.controlFills();
    try testing.expectEqualSlices(u32, &.{ c[0].bitsOf(), c[0].bitsOf(), c[0].bitsOf(), c[1].bitsOf(), c[3].bitsOf(), c[1].bitsOf() }, &fills);
}

test "golden_frames: name frames the spacer replay has" {
    inline for (golden_frames) |g| try testing.expect(g[1] < 6);
}

test {
    std.testing.refAllDecls(@This());
    std.testing.refAllDecls(ct);
}
