//! Spinner (tier 2): an indeterminate progress indicator, a ring of dots whose bright head
//! goes round while the application is busy, in both front ends. Follows the five-commit recipe
//! of widgets/base.zig and is written against the public API of tiers 0 and 1 only.
//!
//! State lives in the application: whether it is busy (`bool`). The animation is a pure
//! function of `Input.time`, so a replay draws the same frames every run and both front ends
//! agree; the runtime front end arms a repeating timer while busy so an idle host still wakes
//! for each step. The spinner takes no input: it has no widget id and senses nothing.

const std = @import("std");
const types = @import("../core/types.zig");
const Tree = @import("../core/tree.zig").Tree;
const Input = @import("../core/input.zig").Input;
const Frame = @import("../runtime/frame.zig").Frame;
const context = @import("../runtime/context.zig");
const spec_zig = @import("../comptime/spec.zig");
const events = @import("../comptime/events.zig");
const signals = @import("../comptime/signals.zig");
const flatten = @import("../comptime/flatten.zig");
const a11y = @import("../a11y/tree.zig");
const hit = @import("../interact/hit.zig");
const base = @import("base.zig");
const Spec = spec_zig.Spec;
const Theme = base.Theme;
const Id = types.Id;
const Node = types.Node;
const Color = types.Color;
const Style = types.Style;
const none = types.none;

// ---- spec ------------------------------------------------------------------------------------

/// Dots in the ring.
pub const dots = 8;
/// Steps the head takes per second.
pub const steps_per_second = 12;

/// Why `State` cannot back a comptime spinner shown while the field `busy` is set; null when it
/// can.
pub fn check(comptime State: type, comptime busy: []const u8) ?[]const u8 {
    comptime {
        if (!@hasField(State, busy)) return "spinner: state has no field '" ++ busy ++ "' for busy";
        if (@FieldType(State, busy) != bool) return "spinner: field '" ++ busy ++ "' must be a bool";
        return null;
    }
}

/// `check` as a compile error.
pub fn validate(comptime State: type, comptime busy: []const u8) void {
    if (comptime check(State, busy)) |msg| @compileError(msg);
}

/// The dot the head is on at `time` seconds.
pub fn phase(time: f64) u32 {
    const step: u64 = @intFromFloat(@floor(@max(time, 0) * steps_per_second));
    return @intCast(step % dots);
}

// ---- look: one function per part, called by both front ends -------------------------------

/// Side of the spinner's square, and of each dot.
pub const size_px: f32 = 24;
pub const dot_px: f32 = 4;

pub fn spinnerStyle(th: *const Theme) Style {
    _ = th;
    return .{ .size = .{ .px(size_px), .px(size_px) }, .role = .group };
}

/// Where dot `k` sits: on a circle inside the square, dot 0 at the top, going clockwise.
const offsets: [dots][2]f32 = blk: {
    var out: [dots][2]f32 = undefined;
    const r = (size_px - dot_px) / 2;
    for (&out, 0..) |*o, k| {
        const a = 2 * std.math.pi * @as(f32, @floatFromInt(k)) / dots;
        o.* = .{ @round(r + r * @sin(a)), @round(r - r * @cos(a)) };
    }
    break :blk out;
};

/// Dot `k`'s fill at head position `head`: the accent, fading with each step behind the head,
/// and nothing while not busy.
pub fn dotFill(th: *const Theme, k: u32, head: u32, busy: bool) Color {
    const behind = (head + dots - k) % dots;
    const alpha: u32 = (255 * (dots - behind)) / dots * @intFromBool(busy);
    return .rgba(th.accent.r, th.accent.g, th.accent.b, @intCast(alpha));
}

pub fn dotStyle(th: *const Theme, k: u32, head: u32, busy: bool) Style {
    return .{ .size = .{ .px(dot_px), .px(dot_px) }, .float = true, .offset = offsets[k], .radius = dot_px / 2, .fill = dotFill(th, k, head, busy) };
}

// ---- accessibility ---------------------------------------------------------------------------

/// The spinner's `value` column: -1 while busy (an indeterminate progress bar has no current
/// value), 0 when idle.
pub fn spinnerValue(busy: bool) f32 {
    return -@as(f32, @floatFromInt(@intFromBool(busy)));
}

/// The spinner is a progress bar (`a11y.Role.progress_bar`, past `types.Role`).
pub fn setRole(t: *Tree, node: u32) void {
    t.c.role[node] = @backingInt(a11y.Role.progress_bar);
}

/// Names the spinner after the text of `label` (a caption's row), as `aria-labelledby`.
pub fn setName(s: *a11y.Semantics, node: u32, label: u32) void {
    s.c.labelled_by[node] = label;
}

// ---- runtime front end ----------------------------------------------------------------------

/// A spinner, turning while `busy`. `id` names its timer, not a widget: it takes no input.
pub fn spinner(f: *Frame, th: *const Theme, id: Id, busy: bool) Node {
    // Wakes the host for the next step while busy; the frame drawn then reads the time.
    if (busy) _ = f.timer(id, 1.0 / @as(f32, steps_per_second), .repeat);
    const head = phase(f.in.time);
    var s = spinnerStyle(th);
    s.value = spinnerValue(busy);
    const node = f.open(.none, s);
    for (0..dots) |k| _ = f.leaf(.none, dotStyle(th, @intCast(k), head, busy));
    f.close();
    setRole(f.tree(), node.ix());
    return node;
}

// ---- comptime front end ---------------------------------------------------------------------

pub const ct = struct {
    /// A spinner turning while the bool field `busy` is set. No id: it is not a widget.
    pub fn spinner(comptime th: Theme, comptime busy: @EnumLiteral()) Spec {
        _ = th;
        const ring: [dots]Spec = @splat(.{ .kind = .col });
        var s = spec_zig.col(.{}, ring);
        s.bind = @tagName(busy);
        s.widget = SpinnerWidget(@tagName(busy));
        return s;
    }
};

/// A spinner in `base.ComptimeUi`, turning while the field `busy` is set: `push` builds the
/// rows `spinner` builds. It takes no input, so it has no `step`.
fn SpinnerWidget(comptime busy: []const u8) type {
    return struct {
        pub fn push(ui: anytype, comptime n: Spec, parent: u32, next: *u32, in: *const Input) void {
            comptime validate(@TypeOf(ui.signals.state), busy);
            const th = &@TypeOf(ui.*).theme;
            const tb = &ui.tables;
            next.* += comptime flatten.count(n);
            const on: bool = @field(ui.signals.state, busy);
            const head = phase(in.time);
            var s = spinnerStyle(th);
            s.value = spinnerValue(on);
            const node = tb.t.push(parent, .none, &s);
            for (0..dots) |k| _ = tb.t.push(node, .none, &dotStyle(th, @intCast(k), head, on));
            tb.t.seal(node);
            setRole(&tb.t, node);
        }
    };
}

// ---- example page -----------------------------------------------------------------------------

/// The example page: a busy spinner beside its caption on a panel, in both front ends, in
/// theme `th`. Its tests and golden images run it.
pub fn Example(comptime th: Theme) type {
    return struct {
        const panel: Style = .{ .dir = .x, .size = .{ .fill, .fill }, .pad = @splat(16), .gap = 8, .fill = th.panel };

        /// Runtime front end: the application owns whether it is busy.
        pub const App = struct {
            busy: bool = true,

            pub fn build(app: *App, f: *Frame) void {
                _ = f.open(.none, panel);
                _ = spinner(f, &th, .from("loading"), app.busy);
                _ = base.label(f, &th, "Loading");
                f.close();
            }
        };

        /// Comptime front end: the same page as a spec over a state struct.
        pub const State = struct {
            busy: bool = true,
            caption: []const u8 = "Loading",
        };
        pub const spec = spec_zig.row(panel, .{
            ct.spinner(th, .busy),
            base.ct.label(th, .caption),
        });
        pub const Ui = base.ComptimeUi(State, spec, th);
        pub const limits: context.Limits = .{ .nodes = 32, .texts = 8, .customs = 1, .strings = 256, .depth = 8 };
        pub const Run = base.Harness(App, Ui, limits);
    };
}

/// The example page in the default theme, its replay and the frames kept as golden images
/// (tools/widgetgolden/ref/spinner-<name>.png), as tools/widgetgolden/dump.zig takes a page.
pub const Page = struct {
    pub const Run = Example(.default).Run;
    pub const replay = @embedFile("testdata/spinner.replay");
    pub const golden_frames = .{
        .{ "start", 0 },
        .{ "turned", 3 },
    };
};

// ---- tests ----------------------------------------------------------------------------------

const testing = std.testing;
const theme: Theme = .default;
const Replay = @import("../core/input.zig").Replay;

var harness: Example(theme).Run = .{};

/// Row of the example page's spinner: root, panel, spinner.
const node_row = 2;

/// The dot with the brightest fill in `t`: where the head is drawn.
fn headDrawn(t: *const Tree) u32 {
    var best: u32 = 0;
    var alpha: u32 = 0;
    for (0..dots) |k| {
        const a = (t.c.look[node_row + 1 + k].fill >> 24) & 0xff;
        if (a > alpha) {
            alpha = a;
            best = @intCast(k);
        }
    }
    return best;
}

test "spinner: the replay gives the same frames in both front ends" {
    const h = &harness;
    h.init();
    var text: [64]u8 = undefined;
    var evs: [16]Input.Event = undefined;
    var contacts: [1]Input.Contact = undefined;
    const buf: Replay.Buffers = .{ .text = &text, .events = &evs, .contacts = &contacts };
    var replay: Replay = .{ .src = Page.replay };
    var heads: [6]u32 = undefined;
    while (try replay.next(buf)) |in| {
        const k = h.frames;
        const out = try h.frame(in);
        heads[k] = headDrawn(out.runtime.tree);
        try testing.expect(h.app.busy);
    }
    try testing.expectEqual(@as(u32, 6), h.frames);
    // 0, 0.1, 0.25, 0.5 and 0.7 s (a press on it changes nothing), then 1.0 s: 12 steps a
    // second around 8 dots.
    try testing.expectEqualSlices(u32, &.{ 0, 1, 3, 6, 0, 4 }, &heads);
}

test "spinner: role, value and a name from its caption" {
    const h = &harness;
    h.init();
    const in: Input = .{ .viewport = .{ 320, 240 } };
    var out = try h.frame(&in);
    var t = out.runtime.tree;
    try testing.expectEqual(@backingInt(a11y.Role.progress_bar), t.c.role[node_row]);
    try testing.expectEqual(@as(f32, -1), t.c.value[node_row]);
    h.app.busy = false;
    h.ui.signals.state.busy = false;
    out = try h.frame(&in);
    t = out.runtime.tree;
    try testing.expectEqual(@as(f32, 0), t.c.value[node_row]);

    var sbuf: [4096]u8 align(@import("../core/mem.zig").column_align) = undefined;
    var carver: @import("../core/mem.zig").Carver = .{ .buf = &sbuf };
    var sem = a11y.Semantics.init(&carver, t.cap);
    sem.clear();
    const caption = node_row + 1 + dots;
    setName(&sem, node_row, caption);
    a11y.names(t, &sem);
    try testing.expectEqual(t.c.text[caption], sem.c.name[node_row]);
}

test "check: what a comptime spinner's state must have" {
    const Good = struct { b: bool = false };
    const Bad = struct { b: u8 = 0 };
    try testing.expectEqual(null, comptime check(Good, "b"));
    try testing.expectEqualStrings("spinner: state has no field 'x' for busy", comptime check(Good, "x").?);
    try testing.expectEqualStrings("spinner: field 'b' must be a bool", comptime check(Bad, "b").?);
}

test "ct.spinner: a ring of dots bound to busy, and not a widget" {
    const spec = comptime spec_zig.row(.{}, .{ct.spinner(theme, .busy)});
    try testing.expectEqual(0, events.Events(spec).widget_count);
    try testing.expectEqual(2 + dots, flatten.count(spec));
    try testing.expectEqualStrings("busy", spec.children[0].bind.?);
}

test "phase: 12 steps a second, around the ring" {
    try testing.expectEqual(@as(u32, 0), phase(0));
    try testing.expectEqual(@as(u32, 0), phase(0.08));
    try testing.expectEqual(@as(u32, 1), phase(0.09));
    try testing.expectEqual(@as(u32, 7), phase(7.0 / 12.0 + 0.001));
    try testing.expectEqual(@as(u32, 0), phase(8.0 / 12.0 + 0.001));
    try testing.expectEqual(@as(u32, 0), phase(-5));
}

test "spinner: both front ends agree; the head is brightest and fades behind" {
    const h = &harness;
    h.init();
    var in: Input = .{ .viewport = .{ 320, 240 }, .time = 0.25 };
    var out = try h.frame(&in);
    var t = out.runtime.tree;
    try testing.expectEqual(@as(u32, 3), headDrawn(t));
    try testing.expectEqual(dotFill(&theme, 3, 3, true).bitsOf(), t.c.look[node_row + 4].fill);
    try testing.expectEqual(@as(u8, 255), dotFill(&theme, 3, 3, true).a);
    try testing.expectEqual(@as(u8, 223), dotFill(&theme, 2, 3, true).a);
    try testing.expectEqual(@as(u8, 31), dotFill(&theme, 4, 3, true).a);
    // The ring: dot 0 at the top centre, dot 2 at the right.
    const box = t.rect(node_row);
    try testing.expectApproxEqAbs(box.x0 + (size_px - dot_px) / 2, t.rect(node_row + 1).x0, 0.5);
    try testing.expectApproxEqAbs(box.x1 - dot_px, t.rect(node_row + 3).x0, 0.5);
    // Not busy: every dot clear.
    h.app.busy = false;
    h.ui.signals.state.busy = false;
    in.time = 0.5;
    out = try h.frame(&in);
    t = out.runtime.tree;
    for (0..dots) |k| try testing.expectEqual(@as(u32, 0), t.c.look[node_row + 1 + k].fill >> 24);
}

test "spinner: takes no input; hit testing and the focus order skip it" {
    const h = &harness;
    h.init();
    var in: Input = .{ .viewport = .{ 320, 240 } };
    var out = try h.frame(&in);
    const r = out.runtime.tree.rect(node_row);
    in.pointer = .{ (r.x0 + r.x1) / 2, (r.y0 + r.y1) / 2 };
    in.buttons.left = true;
    out = try h.frame(&in);
    try testing.expectEqual(none, hit.at(out.runtime.tree, in.pointer[0], in.pointer[1], .any));
    for (0..1 + dots) |k| try testing.expectEqual(@as(u8, 0), out.runtime.tree.c.sense[node_row + k]);
    try testing.expectEqual(@as(u32, 0), h.ctx.inter.focus);
    try testing.expectEqual(0, @TypeOf(h.ui).Events.focus_order.len);
    in.buttons.left = false;
    _ = try h.frame(&in);
    try testing.expectEqual(@as(u32, 0), h.ctx.inter.clicked);
    try testing.expect(h.app.busy);
    // While busy, the runtime front end asks the host back for the next step.
    try testing.expect(out.runtime.wake <= 1.0 / @as(f32, steps_per_second) + 1e-6);
}

test {
    std.testing.refAllDecls(@This());
    std.testing.refAllDecls(ct);
}
