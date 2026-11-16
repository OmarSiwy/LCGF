//! Progress bar (tier 2): how far a task has come, as a filled part of a track, in both front
//! ends. Follows the five-commit recipe of widgets/base.zig and is written against the public
//! API of tiers 0 and 1 only.
//!
//! State lives in the application: the fraction done (`f32`, 0 to 1, clamped when shown). The
//! bar takes no input: it has no id and senses nothing, so hit testing passes through it and
//! keyboard focus never stops on it.

const std = @import("std");
const types = @import("../core/types.zig");
const Tree = @import("../core/tree.zig").Tree;
const Input = @import("../core/input.zig").Input;
const DrawList = @import("../draw/draw_list.zig").DrawList;
const Mono = @import("../text/protocol.zig").Mono;
const Frame = @import("../runtime/frame.zig").Frame;
const context = @import("../runtime/context.zig");
const spec_zig = @import("../comptime/spec.zig");
const events = @import("../comptime/events.zig");
const signals = @import("../comptime/signals.zig");
const flatten = @import("../comptime/flatten.zig");
const a11y = @import("../a11y/tree.zig");
const hit = @import("../interact/hit.zig");
const base = @import("base.zig");
const list_zig = @import("list.zig");
const Spec = spec_zig.Spec;
const Theme = base.Theme;
const Node = types.Node;
const Style = types.Style;
const none = types.none;

// ---- spec ------------------------------------------------------------------------------------

/// Why `State` cannot back a comptime progress bar showing the field `value`; null when it can.
pub fn check(comptime State: type, comptime value: []const u8) ?[]const u8 {
    comptime {
        if (!@hasField(State, value)) return "progress: state has no field '" ++ value ++ "' for the fraction done";
        if (@FieldType(State, value) != f32) return "progress: field '" ++ value ++ "' must be an f32 (0 to 1)";
        return null;
    }
}

/// `check` as a compile error.
pub fn validate(comptime State: type, comptime value: []const u8) void {
    if (comptime check(State, value)) |msg| @compileError(msg);
}

// ---- look: one function per part, called by both front ends -------------------------------

/// The track: the full width it is given (at least 80 px), 8 px tall, rounded.
pub fn trackStyle(th: *const Theme) Style {
    return .{ .dir = .x, .size = .{ .fill, .px(8) }, .min = .{ 80, 0 }, .radius = 4, .fill = th.control, .role = .group };
}

/// The filled part: `value` of the track's width, clamped to 0..1, in the accent.
pub fn barStyle(th: *const Theme, value: f32) Style {
    return .{ .size = .{ .pct(base.unit(value)), .fill }, .radius = 4, .fill = th.accent };
}

// ---- runtime front end ----------------------------------------------------------------------

/// A progress bar showing `value` (0 to 1). Anonymous and insensitive: it takes no input.
pub fn progress(f: *Frame, th: *const Theme, value: f32) Node {
    var s = trackStyle(th);
    _ = &s;
    const track = f.open(.none, s);
    _ = f.leaf(.none, barStyle(th, value));
    f.close();
    return track;
}

// ---- comptime front end ---------------------------------------------------------------------

pub const ct = struct {
    /// A progress bar showing the f32 field `value`. No id: it is not a widget, so it is not in
    /// the comptime front end's `Widget` enum, hit table or focus order.
    pub fn progress(comptime th: Theme, comptime value: @EnumLiteral()) Spec {
        _ = th;
        var s = spec_zig.row(.{}, .{Spec{ .kind = .col }});
        s.bind = @tagName(value);
        return s;
    }
};

/// Whether spec node `n` is a progress bar made by `ct.progress`: a row bound to a field.
fn isProgress(comptime n: Spec) bool {
    return n.kind == .row and n.bind != null;
}

/// The comptime front end for a page of progress bars: rows, columns and labels as in
/// `base.ComptimeUi`, every row bound to a field a progress bar made by `ct.progress`. The page
/// has no widgets, so there is no input to step.
pub fn ComptimeProgress(comptime State: type, comptime spec: Spec, comptime th: Theme) type {
    const E = events.Events(spec);
    const S = signals.Signals(State, spec);
    const Tables = list_zig.CtFrame(flatten.count(spec) + 1, @max(list_zig.labelCount(spec), 1));
    comptime checkAll(State, spec);
    return struct {
        const Self = @This();
        pub const Events = E;
        pub const Signals = S;

        page: Tables = .{},
        signals: S.Runtime = .{},
        font: Mono = .{},

        pub const Output = struct { draw: *const DrawList, tree: *const Tree, event: ?E.Event };

        pub fn frame(ui: *Self, in: *const Input) Output {
            const tb = ui.page.begin(in);
            ui.push(spec, 0);
            const t = ui.page.end(in);
            return .{ .draw = &tb.d, .tree = t, .event = null };
        }

        fn push(ui: *Self, comptime n: Spec, parent: u32) void {
            const tb = &ui.page.tables;
            const state = &ui.signals.state;
            if (n.kind == .label) {
                list_zig.pushLabel(tb, parent, &n.style, @field(state, n.bind.?), &th);
                return;
            }
            if (comptime !isProgress(n)) {
                const i = tb.t.push(parent, .none, &n.style);
                inline for (n.children) |c| ui.push(c, i);
                tb.t.seal(i);
                return;
            }
            const value: f32 = @field(state, n.bind.?);
            var s = trackStyle(&th);
            _ = &s;
            const track = tb.t.push(parent, .none, &s);
            _ = tb.t.push(track, .none, &barStyle(&th, value));
            tb.t.seal(track);
        }
    };
}

fn checkAll(comptime State: type, comptime n: Spec) void {
    if (isProgress(n)) validate(State, n.bind.?);
    for (n.children) |c| checkAll(State, c);
}

// ---- example page -----------------------------------------------------------------------------

/// The example page: two captioned progress bars on a panel (a download 40% done, an install
/// finished), in both front ends, in theme `th`. Its tests and golden images run it.
pub fn Example(comptime th: Theme) type {
    return struct {
        const panel: Style = .{ .dir = .y, .size = .{ .fill, .fill }, .pad = @splat(16), .gap = 8, .fill = th.panel };

        /// Runtime front end: the application owns the fractions.
        pub const App = struct {
            download: f32 = 0.4,
            install: f32 = 1,

            pub fn build(app: *App, f: *Frame) void {
                _ = f.open(.none, panel);
                _ = base.label(f, &th, "Download");
                _ = progress(f, &th, app.download);
                _ = base.label(f, &th, "Install");
                _ = progress(f, &th, app.install);
                f.close();
            }
        };

        /// Comptime front end: the same page as a spec over a state struct.
        pub const State = struct {
            download_text: []const u8 = "Download",
            download: f32 = 0.4,
            install_text: []const u8 = "Install",
            install: f32 = 1,
        };
        pub const spec = spec_zig.col(panel, .{
            base.ct.label(th, .download_text),
            ct.progress(th, .download),
            base.ct.label(th, .install_text),
            ct.progress(th, .install),
        });
        pub const Ui = ComptimeProgress(State, spec, th);
        pub const limits: context.Limits = .{ .nodes = 32, .texts = 8, .customs = 1, .strings = 256, .depth = 8 };
        pub const Run = base.Harness(App, Ui, limits);
    };
}

// ---- tests ----------------------------------------------------------------------------------

const testing = std.testing;
const theme: Theme = .default;
const Replay = @import("../core/input.zig").Replay;

var harness: Example(theme).Run = .{};

/// Rows of the example page's two tracks: panel, caption, track, bar, caption, track, bar.
const tracks = [2]u32{ 3, 6 };

test "check: what a comptime progress bar's state must have" {
    const Good = struct { v: f32 = 0 };
    const Bad = struct { v: u32 = 0 };
    try testing.expectEqual(null, comptime check(Good, "v"));
    try testing.expectEqualStrings("progress: state has no field 'x' for the fraction done", comptime check(Good, "x").?);
    try testing.expectEqualStrings("progress: field 'v' must be an f32 (0 to 1)", comptime check(Bad, "v").?);
}

test "ct.progress: a track and its bar, bound to the value, and not a widget" {
    const spec = comptime spec_zig.col(.{}, .{ ct.progress(theme, .done), ct.progress(theme, .other) });
    const E = events.Events(spec);
    try testing.expectEqual(0, E.widget_count);
    try testing.expectEqual(0, E.focus_order.len);
    try testing.expectEqualStrings("done", spec.children[0].bind.?);
    try testing.expectEqual(5, flatten.count(spec));
}

test "progress: both front ends agree; the bar is the value's share of the track" {
    const h = &harness;
    h.init();
    const in: Input = .{ .viewport = .{ 320, 240 } };
    const out = try h.frame(&in);
    const t = out.runtime.tree;
    try testing.expectApproxEqAbs(0.4 * t.rect(tracks[0]).w(), t.rect(tracks[0] + 1).w(), 0.5);
    try testing.expectApproxEqAbs(t.rect(tracks[1]).w(), t.rect(tracks[1] + 1).w(), 0.5);
    try testing.expectEqual(theme.accent.bitsOf(), t.c.look[tracks[0] + 1].fill);
    try testing.expectEqual(theme.control.bitsOf(), t.c.look[tracks[0]].fill);
    try testing.expectEqual(@as(f32, 0), barStyle(&theme, -2).size[0].v);
    try testing.expectEqual(@as(f32, 1), barStyle(&theme, 9).size[0].v);
}

test "progress: takes no input; hit testing and the focus order skip it" {
    const h = &harness;
    h.init();
    var in: Input = .{ .viewport = .{ 320, 240 } };
    var out = try h.frame(&in);
    const r = out.runtime.tree.rect(tracks[0]);
    in.pointer = .{ (r.x0 + r.x1) / 2, (r.y0 + r.y1) / 2 };
    in.buttons.left = true;
    out = try h.frame(&in);
    // Nothing on the page senses the pointer: the hit test finds no node over the bar.
    try testing.expectEqual(none, hit.at(out.runtime.tree, in.pointer[0], in.pointer[1], .any));
    try testing.expectEqual(@as(u8, 0), out.runtime.tree.c.sense[tracks[0]]);
    // A press on it focuses nothing, in either front end.
    try testing.expectEqual(@as(u32, 0), h.ctx.inter.focus);
    try testing.expectEqual(0, @TypeOf(h.ui).Events.focus_order.len);
    in.buttons.left = false;
    _ = try h.frame(&in);
    try testing.expectEqual(@as(u32, 0), h.ctx.inter.clicked);
    try testing.expectEqual(@as(f32, 0.4), h.app.download);
}

test {
    std.testing.refAllDecls(@This());
    std.testing.refAllDecls(ct);
}
