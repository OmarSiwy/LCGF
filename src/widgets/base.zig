//! Widgets (tier 2): the base every widget is built on, and the four reference widgets (label,
//! button, checkbox, slider) that prove it in both front ends. Written against the public API of
//! tiers 0 and 1 and nothing else (docs/ARCHITECTURE.md, granularity rule). Ported from
//! prototype/ui.zig ("widgets").
//!
//! Each widget is a handful of lines; copy and change one rather than configuring it. State
//! lives in the application, not in the widget: a widget reads it, draws it, and writes back
//! what the input did to it.
//!
//! ## The recipe: every widget arrives in five commits
//!
//! 1. **spec**: what the widget takes and keeps: its parameters, the application state it binds
//!    (a `*bool`, a `*f32`, a string), and its comptime builder, a function returning a `Spec`
//!    (src/comptime/spec.zig) whose mistakes are compile errors.
//! 2. **look**: how it lays out and paints in the default theme: a `Style` built from theme
//!    tokens, and colours picked by table index from its state, never by branching. Written once
//!    as plain functions (`buttonStyle`, `buttonFill`, ...) that both front ends call.
//! 3. **behaviour**: what input does to its value, as a pure function of the value and what
//!    happened (`toggle`, `slide`). The runtime front end feeds it a `Response`; the comptime
//!    front end feeds it the widget's `Event`. Same function, same result.
//! 4. **accessibility**: its `Role`, accessible name (its label's text) and value (the tree's
//!    `role` and `value` columns, which the accessibility bridge reads).
//! 5. **tests**: scripted input with exact expectations, run through both front ends, which must
//!    produce the same draw list.
//!
//! ## Two front ends, one widget
//!
//! Runtime: `button(f, th, id, "Reset")` builds the widget into a `Frame` every frame and
//! returns its `Response`.
//!
//! Comptime: `ct.button(th, .reset, .reset_text)` is a spec node; `ComptimeUi(State, spec, th)`
//! carries its state in the comptime front end's own tables (`Events` for the widget enum, hit
//! rects and pointer events, `Signals` for the state) and builds the same rows with the same
//! look and behaviour functions. Until the comptime layout and paint lanes (ct-layout, ct-paint)
//! land, its rows are pushed from the spec with `Tree.push`, row for row what `flatten.Flat`
//! numbers (flatten.zig, test "equivalence"), and laid out and painted by the tier-0 passes.

const std = @import("std");
const types = @import("../core/types.zig");
const simd = @import("../core/simd.zig");
const mem = @import("../core/mem.zig");
const Tree = @import("../core/tree.zig").Tree;
const Texts = @import("../core/texts.zig").Texts;
const Customs = @import("../core/customs.zig").Customs;
const Strings = @import("../core/strings.zig").Strings;
const Input = @import("../core/input.zig").Input;
const DrawList = @import("../draw/draw_list.zig").DrawList;
const paint = @import("../draw/paint.zig");
const layout = @import("../layout/layout.zig");
const Mono = @import("../text/protocol.zig").Mono;
const Frame = @import("../runtime/frame.zig").Frame;
const context = @import("../runtime/context.zig");
const spec_zig = @import("../comptime/spec.zig");
const events = @import("../comptime/events.zig");
const signals = @import("../comptime/signals.zig");
const Spec = spec_zig.Spec;
const Id = types.Id;
const Node = types.Node;
const Color = types.Color;
const Style = types.Style;
const TextStyle = types.TextStyle;
const Response = types.Response;

/// Design tokens: every colour and size a widget uses comes from here, so restyling is one
/// value. Plain data with defaults, usable at compile time (the `ct` builders take a comptime
/// `Theme`). The defaults are the prototype's dark theme.
pub const Theme = struct {
    /// Label text.
    text: Color = Color.rgb(230, 230, 235),
    /// Label text size, logical pixels.
    text_px: f32 = 14,
    /// Background of panels and toolbars that hold widgets.
    panel: Color = Color.rgb(30, 31, 36),
    /// A control at rest: button face, slider track, unchecked box.
    control: Color = Color.rgb(58, 60, 70),
    /// A control under the pointer; also the checkbox outline.
    control_hot: Color = Color.rgb(74, 77, 90),
    /// A control held down.
    control_held: Color = Color.rgb(44, 46, 54),
    /// What is on: a checked box, the filled part of a slider.
    accent: Color = Color.rgb(90, 140, 255),
    /// Corner radius of buttons.
    radius: f32 = 4,
    /// Padding inside buttons.
    pad: f32 = 8,
    /// Space between a checkbox's box and its caption.
    gap: f32 = 6,

    /// The default tokens.
    pub const default: Theme = .{};

    /// A control's face by interaction state: rest, hot, held, held and hot. A held control
    /// looks held wherever the pointer is.
    pub fn controlFills(th: *const Theme) StateColors {
        return .{ th.control, th.control_hot, th.control_held, th.control_held };
    }

    /// A mark (a checkbox's box) by value: off, on.
    pub fn marks(th: *const Theme) OnOff {
        return .{ th.control, th.accent };
    }
};

/// One colour per interaction state, indexed by `hovered | held << 1`. A widget picks its colour
/// by indexing, never by branching on its state, so the choice is one load whatever the state.
pub const StateColors = [4]Color;

/// One colour per value of a two-state widget, indexed by the value (false 0, true 1).
pub const OnOff = [2]Color;

// ---- shared helpers: public, so a widget written outside this file uses the same ones ------

/// `x` clamped to 0..1: a position along a track, a fraction of a range.
pub inline fn unit(x: f32) f32 {
    return @min(@max(x, 0), 1);
}

/// The row of a `StateColors` table for response `r`: `hovered | held << 1`. Other bits of the
/// response do not move it.
pub inline fn stateIndex(r: Response) u2 {
    return @as(u2, @intFromBool(r.hovered)) | (@as(u2, @intFromBool(r.held)) << 1);
}

// ---- look: one function per part, called by both front ends -------------------------------

pub fn labelText(th: *const Theme) TextStyle {
    return .{ .px = th.text_px, .color = th.text };
}

pub fn buttonStyle(th: *const Theme) Style {
    return .{ .dir = .x, .pad = @splat(th.pad), .radius = th.radius, .main = .center, .cross = .center, .role = .button };
}

/// State selects the colour by table index.
pub fn buttonFill(th: *const Theme, r: Response) Color {
    return th.controlFills()[stateIndex(r)];
}

pub fn checkboxStyle(th: *const Theme) Style {
    return .{ .dir = .x, .gap = th.gap, .cross = .center, .role = .checkbox };
}

pub fn checkboxBox(th: *const Theme, value: bool) Style {
    return .{ .size = .{ .px(16), .px(16) }, .radius = 3, .fill = th.marks()[@intFromBool(value)], .border = 1, .border_color = th.control_hot };
}

pub fn sliderTrack(th: *const Theme) Style {
    return .{ .dir = .x, .size = .{ .fill, .px(8) }, .min = .{ 40, 0 }, .radius = 4, .fill = th.control, .role = .slider };
}

/// The filled part of the track, `frac` of its width.
pub fn sliderThumb(th: *const Theme, frac: f32) Style {
    return .{ .size = .{ .pct(frac), .fill }, .radius = 4, .fill = th.accent };
}

// ---- behaviour: pure functions of the value and what happened -------------------------------

/// Toggling is an xor with "clicked".
pub fn toggle(value: bool, clicked: bool) bool {
    return value != clicked;
}

/// While held, the value follows the pointer: `along` is its position across the track, 0 at
/// the left edge to 1 at the right (clamped).
pub fn slide(value: f32, held: bool, along: f32, lo: f32, hi: f32) f32 {
    return simd.selF(held, lo + unit(along) * (hi - lo), value);
}

/// Where `value` sits between `lo` and `hi`, 0 to 1.
pub fn fraction(value: f32, lo: f32, hi: f32) f32 {
    return unit((value - lo) / @max(hi - lo, 1e-6));
}

// ---- runtime front end ----------------------------------------------------------------------

pub fn label(f: *Frame, th: *const Theme, str: []const u8) Node {
    return f.text(str, labelText(th));
}

pub fn button(f: *Frame, th: *const Theme, id: Id, str: []const u8) Response {
    const node = f.open(id, buttonStyle(th));
    const r = f.interact(node, .button);
    f.setFill(node, buttonFill(th, r));
    f.setCursor(.pointer, r.hovered);
    _ = label(f, th, str);
    f.close();
    return r;
}

pub fn checkbox(f: *Frame, th: *const Theme, id: Id, value: *bool, str: []const u8) Response {
    const row = f.open(id, checkboxStyle(th));
    const r = f.interact(row, .button);
    value.* = toggle(value.*, r.clicked);
    _ = f.leaf(.none, checkboxBox(th, value.*));
    _ = label(f, th, str);
    f.close();
    f.tree().c.value[row.ix()] = simd.b2f(value.*);
    return r;
}

pub fn slider(f: *Frame, th: *const Theme, id: Id, value: *f32, lo: f32, hi: f32) Response {
    const track = f.open(id, sliderTrack(th));
    const r = f.interact(track, .{ .hover = true, .click = true, .drag = true, .focus = true });
    // `heldRect` is this slider's last rect exactly when `r.held` is set.
    const rect = f.heldRect();
    value.* = slide(value.*, r.held, (f.in.pointer[0] - rect.x0) / @max(rect.w(), 1), lo, hi);
    _ = f.leaf(.none, sliderThumb(th, fraction(value.*, lo, hi)));
    f.close();
    f.tree().c.value[track.ix()] = value.*;
    return r;
}

// ---- comptime front end ---------------------------------------------------------------------

/// The reference widgets as spec nodes. Ids and bound state fields are enum literals; the
/// state struct of `ComptimeUi` must have them, with the types noted (a compile error if not).
/// A comptime slider's value runs 0 to 1, the range of its `Event` payload.
pub const ct = struct {
    /// Text showing the string field `text`.
    pub fn label(comptime th: Theme, comptime text: @EnumLiteral()) Spec {
        _ = th;
        return .{ .kind = .label, .bind = @tagName(text), .style = .{ .role = .label } };
    }

    /// A button named `id` showing the string field `text`; its click is its event.
    pub fn button(comptime th: Theme, comptime id: @EnumLiteral(), comptime text: @EnumLiteral()) Spec {
        var s = spec_zig.row(buttonStyle(&th), .{ct.label(th, text)});
        s.id = @tagName(id);
        return s;
    }

    /// A checkbox named `id` toggling the bool field `bind`, captioned by the string field `text`.
    pub fn checkbox(comptime th: Theme, comptime id: @EnumLiteral(), comptime bind: @EnumLiteral(), comptime text: @EnumLiteral()) Spec {
        var s = spec_zig.row(checkboxStyle(&th), .{ Spec{ .kind = .col }, ct.label(th, text) });
        s.kind = .checkbox;
        s.id = @tagName(id);
        s.bind = @tagName(bind);
        return s;
    }

    /// A slider named `id` setting the f32 field `bind`, 0 to 1.
    pub fn slider(comptime th: Theme, comptime id: @EnumLiteral(), comptime bind: @EnumLiteral()) Spec {
        var s = spec_zig.row(sliderTrack(&th), .{Spec{ .kind = .col }});
        s.kind = .slider;
        s.id = @tagName(id);
        s.bind = @tagName(bind);
        return s;
    }
};

/// The comptime front end running the reference widgets of `spec`: state in `Signals`, input
/// through `Events`, look and behaviour through the functions above. The caller owns the value
/// and calls `frame` once per frame, as with `Context`. Labels are measured with `Mono`.
pub fn ComptimeUi(comptime State: type, comptime spec: Spec, comptime th: Theme) type {
    const flatten = @import("../comptime/flatten.zig");
    const E = events.Events(spec);
    const S = signals.Signals(State, spec);
    // One root row (the runtime front end's) above the spec's rows.
    const rows: u32 = flatten.count(spec) + 1;
    const runs: u32 = @max(labelCount(spec), 1);
    return struct {
        const Self = @This();
        pub const Events = E;
        pub const Signals = S;

        buf: [bytes]u8 align(mem.column_align) = undefined,
        tables: Tables = undefined,
        signals: S.Runtime = .{},
        pointer: E.Pointer = .{},
        /// Last frame's widget rects, which this frame's input is judged against.
        rects: E.Rects = .{},
        font: Mono = .{},

        const Tables = struct {
            t: Tree,
            tx: Texts,
            cu: Customs,
            strings: Strings,
            d: DrawList,

            fn carve(carver: *mem.Carver) Tables {
                return .{
                    .t = Tree.init(carver, rows),
                    .tx = Texts.init(carver, runs),
                    .cu = Customs.init(carver, 1),
                    .strings = .{ .buf = carver.slice(u8, string_bytes) },
                    .d = DrawList.init(carver, rows, runs, 1),
                };
            }
        };
        const string_bytes = 1024;
        const bytes = blk: {
            @setEvalBranchQuota(20_000);
            var counter: mem.Carver = .{ .buf = null };
            _ = Tables.carve(&counter);
            break :blk counter.off;
        };

        pub const Output = struct { draw: *const DrawList, tree: *const Tree, event: ?E.Event };

        /// Steps input against last frame's rects, applies each widget's behaviour to the state,
        /// then builds, lays out and paints the frame. A button's click is returned as `event`
        /// for the caller to act on; checkboxes and sliders have already written their field.
        pub fn frame(ui: *Self, in: *const Input) Output {
            const event = E.pointer(&ui.pointer, &ui.rects, in);
            if (event) |e| switch (e) {
                inline else => |payload, tag| {
                    const k = comptime E.slot(tag);
                    const n = comptime nodeAt(spec, E.widget_nodes[k]);
                    switch (comptime E.widget_kinds[k]) {
                        .checkbox => ui.signals.set(field(n.bind.?), toggle(@field(ui.signals.state, n.bind.?), true)),
                        .slider => ui.signals.set(field(n.bind.?), slide(0, true, payload, 0, 1)),
                        .label, .col, .row => {},
                    }
                },
            };

            var carver: mem.Carver = .{ .buf = &ui.buf };
            ui.tables = Tables.carve(&carver);
            const tb = &ui.tables;
            tb.t.reset();
            tb.tx.reset();
            tb.cu.reset();
            tb.strings.reset();
            // The runtime front end's root (`Context.begin`).
            _ = tb.t.push(0, context.root_id, &.{ .size = .{ .px(in.viewport[0]), .px(in.viewport[1]) }, .clip = true, .role = .group });
            var next: u32 = 0;
            ui.push(spec, 0, &next, in);
            tb.t.seal(0);

            // `Frame.end`'s pass sequence.
            const t = &tb.t;
            const tx = &tb.tx;
            ui.font.measure(tx);
            layout.prepare(t);
            layout.applyText(t, tx, .x);
            layout.fit(t, .x);
            layout.resolve(t, .x, in.viewport[0]);
            layout.textAvail(t, tx);
            ui.font.wrap(tx);
            layout.applyText(t, tx, .y);
            layout.fit(t, .y);
            layout.resolve(t, .y, in.viewport[1]);
            layout.place(t);
            layout.finalize(t);
            paint.emit(t, tx, &tb.cu, tb.strings.buf[0..tb.strings.len], &tb.d);

            ui.rects = .{};
            for (0..4) |side| {
                for (E.widget_nodes, 0..) |node, k| ui.rects.c[side][k] = t.c.vis[side][@as(usize, node) + 1];
            }
            return .{ .draw = &tb.d, .tree = t, .event = event };
        }

        /// Pushes `n` (spec row `next.*`) and its subtree under tree row `parent`.
        fn push(ui: *Self, comptime n: Spec, parent: u32, next: *u32, in: *const Input) void {
            const tb = &ui.tables;
            const state = &ui.signals.state;
            next.* += 1;
            switch (n.kind) {
                .label => {
                    const i = tb.t.push(parent, .none, &n.style);
                    const span = tb.strings.add(@field(state, n.bind.?));
                    tb.t.c.text[i] = tb.tx.push(i, span, &labelText(&th));
                },
                .checkbox => {
                    const value: bool = @field(state, n.bind.?);
                    var s = n.style;
                    s.value = simd.b2f(value);
                    const i = tb.t.push(parent, .hash(n.id.?), &s);
                    next.* += 1;
                    _ = tb.t.push(i, .none, &checkboxBox(&th, value));
                    ui.push(n.children[1], i, next, in);
                    tb.t.seal(i);
                },
                .slider => {
                    const value: f32 = @field(state, n.bind.?);
                    var s = n.style;
                    s.value = value;
                    const i = tb.t.push(parent, .hash(n.id.?), &s);
                    next.* += 1;
                    _ = tb.t.push(i, .none, &sliderThumb(&th, fraction(value, 0, 1)));
                    tb.t.seal(i);
                },
                .row, .col => {
                    var s = n.style;
                    // A container with an id is a button.
                    if (n.id != null) s.fill = buttonFill(&th, ui.response(next.* - 1, in));
                    const i = tb.t.push(parent, if (n.id) |name| .hash(name) else .none, &s);
                    inline for (n.children) |c| ui.push(c, i, next, in);
                    tb.t.seal(i);
                },
            }
        }

        /// Hover and held for the widget at spec row `row`, as `Interaction.response` reports
        /// them: while a widget is held, only it shows hover.
        fn response(ui: *const Self, row: u32, in: *const Input) Response {
            const w: E.Widget = @fromBackingInt(@as(E.Index, @intCast(row)));
            const held = ui.pointer.pressed == w;
            const owned = ui.pointer.pressed == null or held;
            const under = E.at(&ui.rects, in.pointer[0], in.pointer[1]) == w;
            return .{ .hovered = under and owned, .held = held };
        }

        fn field(comptime name: []const u8) S.Field {
            return comptime std.meta.stringToEnum(S.Field, name).?;
        }
    };
}

/// Spec nodes in `n`'s subtree that show text.
fn labelCount(comptime n: Spec) u32 {
    var k: u32 = @intFromBool(n.kind == .label);
    for (n.children) |c| k += labelCount(c);
    return k;
}

/// The spec node at depth-first row `row` of `n`.
fn nodeAt(comptime n: Spec, comptime row: comptime_int) Spec {
    comptime {
        var i = 0;
        return nodeWalk(n, row, &i).?;
    }
}

fn nodeWalk(comptime n: Spec, comptime row: comptime_int, comptime next: *comptime_int) ?Spec {
    if (next.* == row) return n;
    next.* += 1;
    for (n.children) |c| if (nodeWalk(c, row, next)) |r| return r;
    return null;
}

// ---- tests ----------------------------------------------------------------------------------

const testing = std.testing;

const limits: context.Limits = .{ .nodes = 64, .texts = 16, .customs = 1, .strings = 1024, .depth = 8 };
var rt_buffer: [context.Context.requiredBytes(limits)]u8 align(mem.column_align) = undefined;

const theme: Theme = .default;

/// The prototype example's toolbar in both front ends, in theme `th`.
fn Toolbar(comptime th: Theme) type {
    return struct {
        const toolbar_style: Style = .{ .dir = .x, .size = .{ .fill, .fit }, .pad = @splat(8), .gap = 8, .cross = .center, .fill = th.panel };

        /// Runtime front end: the application owns the values.
        const RtApp = struct {
            resets: u32 = 0,
            wireframe: bool = false,
            exposure: f32 = 0.25,
            clicked: bool = false,

            fn build(app: *@This(), f: *Frame) void {
                _ = f.open(.from("toolbar"), toolbar_style);
                app.clicked = button(f, &th, .from("reset"), "Reset").clicked;
                app.resets += @intFromBool(app.clicked);
                _ = checkbox(f, &th, .from("wire"), &app.wireframe, "Wireframe");
                _ = slider(f, &th, .from("exposure"), &app.exposure, 0, 1);
                _ = label(f, &th, "Layer 0");
                f.close();
            }
        };

        /// Comptime front end: the same toolbar as a spec over a state struct.
        const CtState = struct {
            reset_text: []const u8 = "Reset",
            wireframe: bool = false,
            wire_text: []const u8 = "Wireframe",
            exposure: f32 = 0.25,
            layer: []const u8 = "Layer 0",
        };
        const spec = spec_zig.row(toolbar_style, .{
            ct.button(th, .reset, .reset_text),
            ct.checkbox(th, .wire, .wireframe, .wire_text),
            ct.slider(th, .exposure, .exposure),
            ct.label(th, .layer),
        });
        const CtUi = ComptimeUi(CtState, spec, th);
    };
}
const Default = Toolbar(theme);

fn center(r: types.Rect) [2]f32 {
    return .{ (r.x0 + r.x1) * 0.5, (r.y0 + r.y1) * 0.5 };
}

fn expectSameDraw(a: *const DrawList, b: *const DrawList) !void {
    try testing.expectEqual(a.quad_len, b.quad_len);
    try testing.expectEqualSlices(u8, a.quadBytes(), b.quadBytes());
    try testing.expectEqual(a.run_len, b.run_len);
    try testing.expectEqualSlices(u8, std.mem.sliceAsBytes(a.runs[0..a.run_len]), std.mem.sliceAsBytes(b.runs[0..b.run_len]));
    try testing.expectEqual(a.cmd_len, b.cmd_len);
    for (0..a.cmd_len) |i| try testing.expectEqual(a.command(@intCast(i)), b.command(@intCast(i)));
}

test "reference widgets: the same input gives the same draw list in both front ends" {
    try expectFrontEndsAgree(theme);
}

/// Replays 12 frames of clicks and drags through both front ends in theme `th` and requires the
/// same draw list, semantics and state after every frame.
fn expectFrontEndsAgree(comptime th: Theme) !void {
    const T = Toolbar(th);
    var ctx = try context.Context.init(&rt_buffer, limits);
    var app: T.RtApp = .{};
    var ui: T.CtUi = .{};
    var in: Input = .{ .viewport = .{ 400, 100 } };

    const Step = struct { target: ?[]const u8, along: f32 = 0.5, left: bool };
    const script = [_]Step{
        .{ .target = null, .left = false }, // first frame: nothing laid out yet
        .{ .target = "reset", .left = false }, // hover the button
        .{ .target = "reset", .left = true }, // hold it
        .{ .target = "reset", .left = false }, // click
        .{ .target = "wire", .left = true },
        .{ .target = "wire", .left = false }, // toggle on
        .{ .target = "exposure", .along = 0.75, .left = true }, // press at 75%
        .{ .target = "exposure", .along = 0.1, .left = true }, // drag to 10%
        .{ .target = "reset", .left = true }, // dragged off the track, still held
        .{ .target = "reset", .left = false }, // released over the button: no click
        .{ .target = "wire", .left = true },
        .{ .target = "wire", .left = false }, // toggle off
    };
    var clicks: u32 = 0;
    var last: ?context.Output = null;
    for (script, 0..) |step, frame_no| {
        if (step.target) |name| {
            const t = last.?.tree;
            const r = t.rect(t.find(.hash(name)));
            in.pointer = .{ r.x0 + step.along * r.w(), (r.y0 + r.y1) * 0.5 };
        }
        in.buttons.left = step.left;

        var f = ctx.begin(&in);
        app.build(&f);
        const rt_out = f.end(.{});
        const ct_out = ui.frame(&in);
        last = rt_out;

        expectSameDraw(rt_out.draw, ct_out.draw) catch |err| {
            std.debug.print("frame {d} differs\n", .{frame_no});
            return err;
        };
        // Same semantics: role and value per row (the comptime rows sit under the same root).
        try testing.expectEqual(rt_out.tree.len, ct_out.tree.len);
        try testing.expectEqualSlices(u8, rt_out.tree.c.role[0..rt_out.tree.len], ct_out.tree.c.role[0..ct_out.tree.len]);
        try testing.expectEqualSlices(f32, rt_out.tree.c.value[0..rt_out.tree.len], ct_out.tree.c.value[0..ct_out.tree.len]);
        // State: the application's fields and the comptime front end's signals agree.
        try testing.expectEqual(app.wireframe, ui.signals.state.wireframe);
        try testing.expectEqual(app.exposure, ui.signals.state.exposure);
        const ct_click = if (ct_out.event) |e| e == .reset else false;
        try testing.expectEqual(app.clicked, ct_click);
        clicks += @intFromBool(ct_click);
    }
    try testing.expectEqual(@as(u32, 1), clicks);
    try testing.expectEqual(@as(u32, 1), app.resets);
    try testing.expect(!app.wireframe);
    // Dragged left off the track onto the button while held: clamped to lo.
    try testing.expectEqual(@as(f32, 0), app.exposure);
}

test "Theme: the default tokens are the prototype's dark theme" {
    const d = Theme.default;
    try testing.expectEqual(Theme{}, d);
    try testing.expectEqual(Color.rgb(230, 230, 235), d.text);
    try testing.expectEqual(@as(f32, 14), d.text_px);
    try testing.expectEqual(Color.rgb(30, 31, 36), d.panel);
    try testing.expectEqual(Color.rgb(58, 60, 70), d.control);
    try testing.expectEqual(Color.rgb(74, 77, 90), d.control_hot);
    try testing.expectEqual(Color.rgb(44, 46, 54), d.control_held);
    try testing.expectEqual(Color.rgb(90, 140, 255), d.accent);
    try testing.expectEqual([3]f32{ 4, 8, 6 }, [3]f32{ d.radius, d.pad, d.gap });
}

test "Theme: other tokens restyle both front ends alike" {
    try expectFrontEndsAgree(.{
        .text = .rgb(20, 20, 20),
        .text_px = 18,
        .panel = .rgb(240, 240, 240),
        .control = .rgb(200, 200, 205),
        .control_hot = .rgb(180, 180, 190),
        .control_held = .rgb(160, 160, 170),
        .accent = .rgb(0, 120, 60),
        .radius = 0,
        .pad = 12,
        .gap = 10,
    });
    // The tokens reach the widgets: a bigger pad makes a bigger button.
    var ctx = try context.Context.init(&rt_buffer, limits);
    const in: Input = .{ .viewport = .{ 400, 100 } };
    var widths: [2]f32 = undefined;
    for (&widths, [2]f32{ 8, 16 }) |*w, pad| {
        var th: Theme = .default;
        th.pad = pad;
        var f = ctx.begin(&in);
        _ = button(&f, &th, .from("b"), "Go");
        const out = f.end(.{});
        w.* = out.tree.rect(out.tree.find(.from("b"))).w();
    }
    try testing.expectEqual(widths[0] + 16, widths[1]);
}

test "unit, stateIndex: the shared helpers" {
    try testing.expectEqual(@as(f32, 0), unit(-3));
    try testing.expectEqual(@as(f32, 0.25), unit(0.25));
    try testing.expectEqual(@as(f32, 1), unit(7));
    try testing.expectEqual(@as(f32, 1), unit(types.inf));
    try testing.expectEqual(@as(f32, 0), unit(-types.inf));
    try testing.expectEqual(@as(u2, 0), stateIndex(.{}));
    try testing.expectEqual(@as(u2, 1), stateIndex(.{ .hovered = true }));
    try testing.expectEqual(@as(u2, 2), stateIndex(.{ .held = true }));
    try testing.expectEqual(@as(u2, 3), stateIndex(.{ .hovered = true, .held = true }));
    try testing.expectEqual(@as(u2, 0), stateIndex(.{ .pressed = true, .released = true, .clicked = true, .focused = true }));
    // The value helpers are built on unit: out-of-range input clamps to the ends.
    try testing.expectEqual(@as(f32, 4), slide(1, true, 1.5, 0, 4));
    try testing.expectEqual(@as(f32, 1), slide(1, false, 0.5, 0, 4));
    try testing.expectEqual(@as(f32, 0), fraction(-2, 0, 4));
    try testing.expectEqual(@as(f32, 0.75), fraction(3, 0, 4));
}

test "StateColors, OnOff: the theme's tables, indexed by state and value" {
    const th = Theme.default;
    try testing.expectEqual(StateColors{ th.control, th.control_hot, th.control_held, th.control_held }, th.controlFills());
    try testing.expectEqual(OnOff{ th.control, th.accent }, th.marks());
    // Every state picks its row of the table, for buttons in both front ends (`buttonFill`).
    for (0..4) |k| {
        const r: Response = .{ .hovered = k & 1 != 0, .held = k & 2 != 0 };
        try testing.expectEqual(th.controlFills()[k], buttonFill(&th, r));
    }
    // Other bits of the response do not move the index.
    try testing.expectEqual(th.control, buttonFill(&th, .{ .pressed = true, .released = true, .clicked = true, .focused = true }));
    for ([2]bool{ false, true }, th.marks()) |v, c| try testing.expectEqual(c, checkboxBox(&th, v).fill);
    // A comptime theme gives comptime tables: they can live in read-only data.
    const fills = comptime Theme.default.controlFills();
    try testing.expectEqual(th.control_hot, fills[1]);
}

test "button: hover and hold pick the fill by table index; click on release over it" {
    var ctx = try context.Context.init(&rt_buffer, limits);
    var app: Default.RtApp = .{};
    var in: Input = .{ .viewport = .{ 400, 100 } };
    var f = ctx.begin(&in);
    app.build(&f);
    var out = f.end(.{});
    const row = out.tree.find(.from("reset"));
    const fill = struct {
        fn of(o: context.Output, i: u32) u32 {
            return o.tree.c.look[i].fill;
        }
    }.of;
    try testing.expectEqual(theme.control.bitsOf(), fill(out, row));
    in.pointer = center(out.tree.rect(row));
    f = ctx.begin(&in);
    app.build(&f);
    out = f.end(.{});
    try testing.expectEqual(theme.control_hot.bitsOf(), fill(out, row));
    try testing.expectEqual(context.Cursor.pointer, out.platform.cursor);
    in.buttons.left = true;
    f = ctx.begin(&in);
    app.build(&f);
    out = f.end(.{});
    try testing.expectEqual(theme.control_held.bitsOf(), fill(out, row));
    try testing.expect(!app.clicked);
    in.buttons.left = false;
    f = ctx.begin(&in);
    app.build(&f);
    out = f.end(.{});
    try testing.expect(app.clicked);
    try testing.expectEqual(theme.control_hot.bitsOf(), fill(out, row));
    try testing.expectEqual(@backingInt(types.Role.button), out.tree.c.role[row]);
}

test "checkbox, slider: value columns and the slider's held-rect mapping" {
    var ctx = try context.Context.init(&rt_buffer, limits);
    var app: Default.RtApp = .{};
    var in: Input = .{ .viewport = .{ 400, 100 } };
    var f = ctx.begin(&in);
    app.build(&f);
    var out = f.end(.{});
    const box = out.tree.find(.from("wire"));
    const track = out.tree.rect(out.tree.find(.from("exposure")));
    try testing.expectEqual(@as(f32, 0), out.tree.c.value[box]);
    try testing.expectEqual(@as(f32, 0.25), out.tree.c.value[out.tree.find(.from("exposure"))]);
    // The thumb is a quarter of the track, to the pixel layout snaps it to.
    const thumb = out.tree.find(.from("exposure")) + 1;
    try testing.expectApproxEqAbs(0.25 * track.w(), out.tree.rect(thumb).w(), 0.5);

    in.pointer = center(out.tree.rect(box));
    in.buttons.left = true;
    f = ctx.begin(&in);
    app.build(&f);
    _ = f.end(.{});
    in.buttons.left = false;
    f = ctx.begin(&in);
    app.build(&f);
    out = f.end(.{});
    try testing.expect(app.wireframe);
    try testing.expectEqual(@as(f32, 1), out.tree.c.value[box]);
    try testing.expectEqual(theme.accent.bitsOf(), out.tree.c.look[box + 1].fill);

    // Pressed past the right end: clamped to hi.
    in.pointer = .{ track.x1 + 50, (track.y0 + track.y1) * 0.5 };
    f = ctx.begin(&in);
    app.build(&f);
    _ = f.end(.{});
    in.pointer[0] = track.x0 + 0.5 * track.w();
    in.buttons.left = true;
    f = ctx.begin(&in);
    app.build(&f);
    _ = f.end(.{});
    try testing.expectApproxEqAbs(@as(f32, 0.5), app.exposure, 1e-5);
    in.pointer[0] = track.x1 + 50;
    f = ctx.begin(&in);
    app.build(&f);
    out = f.end(.{});
    try testing.expectEqual(@as(f32, 1), app.exposure);
    try testing.expectEqual(@backingInt(types.Role.slider), out.tree.c.role[out.tree.find(.from("exposure"))]);
}

test "label: a text leaf in the theme's size and colour" {
    var ctx = try context.Context.init(&rt_buffer, limits);
    const in: Input = .{ .viewport = .{ 400, 100 } };
    var f = ctx.begin(&in);
    const n = label(&f, &theme, "hi");
    const out = f.end(.{});
    const k = out.tree.c.text[n.ix()];
    try testing.expectEqual(theme.text_px, out.texts.c.px[k]);
    try testing.expectEqual(theme.text.bitsOf(), out.texts.c.color[k]);
    try testing.expectEqual(@backingInt(types.Role.label), out.tree.c.role[n.ix()]);
}

test "ct: spec builders give the comptime front end's widget enum, kinds and focus order" {
    try testing.expectEqual(3, Default.CtUi.Events.widget_count);
    try testing.expectEqualSlices(spec_zig.Kind, &.{ .row, .checkbox, .slider }, &Default.CtUi.Events.widget_kinds);
    try testing.expectEqual(void, @FieldType(Default.CtUi.Events.Event, "reset"));
    try testing.expectEqual(f32, @FieldType(Default.CtUi.Events.Event, "exposure"));
    try testing.expectEqualSlices(Default.CtUi.Events.Widget, &.{ .wire, .exposure }, Default.CtUi.Events.focus_order);
}

test {
    std.testing.refAllDecls(@This());
    std.testing.refAllDecls(ct);
}
