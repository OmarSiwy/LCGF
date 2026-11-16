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
//!    produce the same draw list: a page (as `Reference`), a replay file under testdata/, a test
//!    driving `Harness` over it, and golden images of chosen frames (tools/widgetgolden/).
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
const label_zig = @import("label.zig");
const button_zig = @import("button.zig");
const checkbox_zig = @import("checkbox.zig");
const radio_zig = @import("radio.zig");
const switch_zig = @import("switch.zig");
const toggle_zig = @import("toggle.zig");
const slider_zig = @import("slider.zig");
const range_zig = @import("range.zig");
const a11y = @import("../a11y/tree.zig");
const Id = types.Id;
const Node = types.Node;
const Color = types.Color;
const Style = types.Style;
const TextStyle = types.TextStyle;
const Response = types.Response;
const none = types.none;

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

/// Scancodes of the keys widgets answer to: USB HID usage ids, as `focus.Keymap`'s defaults
/// (what SDL and the web's `KeyboardEvent.code` map to).
// ponytail: one fixed table; take a `Keys` per widget call once a host with other codes exists.
pub const keys = struct {
    pub const enter: u8 = 0x28;
    pub const space: u8 = 0x2c;
    pub const right: u8 = 0x4f;
    pub const left: u8 = 0x50;
    pub const down: u8 = 0x51;
    pub const up: u8 = 0x52;
    pub const home: u8 = 0x4a;
    pub const end: u8 = 0x4d;
    pub const page_up: u8 = 0x4b;
    pub const page_down: u8 = 0x4e;
    pub const delete: u8 = 0x4c;
    pub const backspace: u8 = 0x2a;
};

/// How many of this frame's key events are `kind` (`.press` counts auto-repeat too) for key
/// `code` with no modifier held. Widgets read their keys this way while focused.
pub fn keyCount(in: *const Input, code: u8, kind: Input.Event.Kind) u32 {
    var n: u32 = 0;
    for (in.events) |e| {
        const k = simd.orB(e.kind == kind, simd.andB(kind == .press, e.kind == .repeat));
        const plain = @as(u8, @bitCast(e.mods)) & 0xf == 0;
        n += @intFromBool(simd.andB(simd.andB(k, e.code == code), plain));
    }
    return n;
}

/// Why `State`'s field `name` cannot be bound by a `widget` that needs a `T`, or null when it
/// can: the message `ComptimeUi` stops compilation with. Each widget's `bindError` calls it.
pub fn fieldError(comptime State: type, comptime widget: []const u8, comptime name: []const u8, comptime T: type) ?[]const u8 {
    comptime {
        if (!@hasField(State, name)) return widget ++ " '" ++ name ++ "': the state has no such field";
        const FT = @FieldType(State, name);
        if (FT == T) return null;
        return widget ++ " '" ++ name ++ "' needs a " ++ @typeName(T) ++ " field, not " ++ @typeName(FT);
    }
}

/// A compile error for the first node in `n`'s subtree whose binding its widget cannot take.
fn checkBindings(comptime State: type, comptime n: Spec) void {
    comptime {
        if (n.bind) |name| {
            const err: ?[]const u8 = switch (n.kind) {
                .label => label_zig.bindError(State, name),
                .checkbox => checkbox_zig.bindError(State, name),
                .radio, .radio_option => radio_zig.bindError(State, name),
                .@"switch" => switch_zig.bindError(State, name),
                .toggle => toggle_zig.bindError(State, name),
                .slider => slider_zig.bindError(State, name),
                .range, .range_thumb => range_zig.bindError(State, name),
                else => null,
            };
            if (err) |msg| @compileError(msg);
        }
        for (n.children) |c| checkBindings(State, c);
    }
}

// ---- look: one function per part, called by both front ends -------------------------------

pub const labelText = label_zig.labelText;

pub const buttonStyle = button_zig.buttonStyle;
pub const buttonFill = button_zig.buttonFill;

pub const checkboxStyle = checkbox_zig.checkboxStyle;
pub const checkboxBox = checkbox_zig.checkboxBox;

pub const sliderTrack = slider_zig.sliderTrack;
pub const sliderThumb = slider_zig.sliderThumb;

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

pub const label = label_zig.label;

pub const button = button_zig.button;

pub const checkbox = checkbox_zig.checkbox;

pub const slider = slider_zig.slider;

// ---- comptime front end ---------------------------------------------------------------------

/// The reference widgets as spec nodes. Ids and bound state fields are enum literals; the
/// state struct of `ComptimeUi` must have them, with the types noted (a compile error if not).
pub const ct = struct {
    pub const label = label_zig.ct.label;

    pub const button = button_zig.ct.button;

    pub const checkbox = checkbox_zig.ct.checkbox;

    pub const slider = slider_zig.ct.slider;
};

/// The comptime front end running the reference widgets of `spec`: state in `Signals`, input
/// through `Events`, look and behaviour through the functions above. The caller owns the value
/// and calls `frame` once per frame, as with `Context`. Labels are measured with `Mono`.
pub fn ComptimeUi(comptime State: type, comptime spec: Spec, comptime th: Theme) type {
    const flatten = @import("../comptime/flatten.zig");
    checkBindings(State, spec);
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
        /// The focused widget: a press on a focusable widget focuses it, a press anywhere
        /// else clears it, as `Interaction` does for nodes that sense focus. Keys go to it.
        focus: ?E.Widget = null,
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
            if (in.buttons.left and !ui.pointer.down) ui.focus = focusAt(&ui.rects, in);
            var event = E.pointer(&ui.pointer, &ui.rects, in);
            // A key event has already done its work (`keyEvent`); a pointer event's is below.
            const from_pointer = event != null;
            if (event == null) event = ui.keyEvent(in);
            if (event) |e| switch (e) {
                inline else => |payload, tag| {
                    const k = comptime E.slot(tag);
                    const n = comptime nodeAt(spec, E.widget_nodes[k]);
                    switch (comptime E.widget_kinds[k]) {
                        .checkbox => ui.signals.set(field(n.bind.?), checkbox_zig.flip(@field(ui.signals.state, n.bind.?), true)),
                        .slider => if (from_pointer) ui.signals.set(field(n.bind.?), slide(0, true, payload, n.lo, n.hi)),
                        .radio_option => ui.signals.set(field(n.bind.?), n.index),
                        .@"switch", .toggle => ui.signals.set(field(n.bind.?), toggle(@field(ui.signals.state, n.bind.?), true)),
                        .range_thumb => if (from_pointer) {
                            // Along the whole track, last frame's (the tree still holds it).
                            const r = ui.tables.t.rect(E.widget_nodes[k] - thumbOffset(n.index));
                            const along = (in.pointer[0] - r.x0) / @max(r.w(), 1);
                            const v = range_zig.step(@field(ui.signals.state, n.bind.?), @intCast(n.index), true, along, false, n.lo, n.hi, in);
                            ui.signals.set(field(n.bind.?), v);
                        },
                        .label, .col, .row, .button, .radio, .range => {},
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

        /// The focusable widget under the pointer, or null.
        fn focusAt(r: *const E.Rects, in: *const Input) ?E.Widget {
            const w = E.at(r, in.pointer[0], in.pointer[1]) orelse return null;
            return switch (w) {
                inline else => |tag| if (comptime E.focusable(E.widget_kinds[E.slot(tag)])) tag else null,
            };
        }

        /// The event this frame's keys make on the focused widget, or null.
        /// A key may move focus too (arrows in a radio group). Each arm applies what its keys do;
        /// a slider's event then carries the new value's fraction of its range.
        fn keyEvent(ui: *Self, in: *const Input) ?E.Event {
            const w = ui.focus orelse return null;
            switch (w) {
                inline else => |tag| switch (comptime E.widget_kinds[E.slot(tag)]) {
                    .button, .toggle => if (button_zig.activated(false, true, in)) return @unionInit(E.Event, @tagName(tag), {}),
                    .checkbox, .@"switch" => if (checkbox_zig.toggled(false, true, in)) return @unionInit(E.Event, @tagName(tag), {}),
                    .slider => {
                        const n = comptime nodeAt(spec, E.widget_nodes[E.slot(tag)]);
                        const v = slider_zig.keyed(@field(ui.signals.state, n.bind.?), n.lo, n.hi, in) orelse return null;
                        ui.signals.set(field(n.bind.?), v);
                        return @unionInit(E.Event, @tagName(tag), fraction(v, n.lo, n.hi));
                    },
                    .range_thumb => {
                        const n = comptime nodeAt(spec, E.widget_nodes[E.slot(tag)]);
                        const now = @field(ui.signals.state, n.bind.?);
                        const v = range_zig.step(now, @intCast(n.index), false, 0, true, n.lo, n.hi, in);
                        if (std.meta.eql(v, now) and slider_zig.keyed(now[n.index], n.lo, n.hi, in) == null) return null;
                        ui.signals.set(field(n.bind.?), v);
                        return @unionInit(E.Event, @tagName(tag), fraction(v[n.index], n.lo, n.hi));
                    },
                    .radio_option => {
                        const k = comptime E.slot(tag);
                        const o = comptime nodeAt(spec, E.widget_nodes[k]);
                        const n = comptime nodeAt(spec, E.widget_nodes[k] - optionRows(o.index) - 1).children.len;
                        const s = radio_zig.step(n, none, o.index, in) orelse return null;
                        // The group's options are consecutive in widget order.
                        const to = E.widget(k - o.index + s.value);
                        ui.focus = to;
                        return switch (to) {
                            inline else => |t| if (comptime E.widget_kinds[E.slot(t)] == .radio_option) @unionInit(E.Event, @tagName(t), {}) else unreachable,
                        };
                    },
                    else => {},
                },
            }
            return null;
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
                    const value = checkbox_zig.Check.of(@field(state, n.bind.?));
                    var s = n.style;
                    s.value = value.value();
                    const i = tb.t.push(parent, .hash(n.id.?), &s);
                    next.* += 1;
                    const box = tb.t.push(i, .none, &checkboxBox(&th, value));
                    next.* += 1;
                    _ = tb.t.push(box, .none, &checkbox_zig.checkboxDash(&th, value));
                    tb.t.seal(box);
                    ui.push(n.children[1], i, next, in);
                    tb.t.seal(i);
                },
                .slider => {
                    const value: f32 = @field(state, n.bind.?);
                    var s = n.style;
                    s.value = value;
                    const i = tb.t.push(parent, .hash(n.id.?), &s);
                    next.* += 1;
                    _ = tb.t.push(i, .none, &sliderThumb(&th, fraction(value, n.lo, n.hi)));
                    tb.t.seal(i);
                },
                .radio => {
                    const g = tb.t.push(parent, .hash(radio_zig.groupName(n.children[0].id.?)), &n.style);
                    inline for (n.children) |o| {
                        next.* += 1;
                        const id = radio_zig.optionId(.hash(radio_zig.groupName(o.id.?)), o.index);
                        const i = tb.t.push(g, id, &o.style);
                        next.* += 2;
                        const ring = tb.t.push(i, .none, &radio_zig.ringStyle(&th));
                        _ = tb.t.push(ring, .none, &radio_zig.dotStyle(&th, false));
                        tb.t.seal(ring);
                        ui.push(o.children[1], i, next, in);
                        tb.t.seal(i);
                    }
                    tb.t.seal(g);
                    radio_zig.paintSelection(&tb.t, &th, g, @field(state, n.bind.?), n.children.len);
                },
                .radio_option => unreachable, // pushed by its group
                .range => {
                    const value: [2]f32 = @field(state, n.bind.?);
                    const name = comptime range_zig.ct.trackName(n.children[0].id.?);
                    const track = tb.t.push(parent, .hash(name), &n.style);
                    const p = range_zig.parts(&th, fraction(value[0], n.lo, n.hi), fraction(value[1], n.lo, n.hi));
                    for (0..2) |k| {
                        const half = tb.t.push(track, range_zig.thumbId(.hash(name), @intCast(k)), &p[range_zig.thumb_rows * k]);
                        _ = tb.t.push(half, .none, &p[range_zig.thumb_rows * k + 1]);
                        _ = tb.t.push(half, .none, &p[range_zig.thumb_rows * k + 2]);
                        tb.t.seal(half);
                    }
                    next.* += 2 * range_zig.thumb_rows;
                    tb.t.seal(track);
                    range_zig.expose(&tb.t, track, value);
                },
                .range_thumb => unreachable, // pushed by its track
                .toggle => {
                    const value: bool = @field(state, n.bind.?);
                    var s = n.style;
                    s.fill = toggle_zig.toggleFill(&th, value, ui.response(next.* - 1, in));
                    s.value = simd.b2f(value);
                    const i = tb.t.push(parent, .hash(n.id.?), &s);
                    ui.push(n.children[0], i, next, in);
                    tb.t.seal(i);
                },
                .@"switch" => {
                    const value: bool = @field(state, n.bind.?);
                    const i = tb.t.push(parent, .hash(n.id.?), &n.style);
                    switch_zig.expose(&tb.t, i, value);
                    next.* += 2;
                    const track = tb.t.push(i, .none, &switch_zig.trackStyle(&th, value));
                    _ = tb.t.push(track, .none, &switch_zig.knobStyle(&th));
                    tb.t.seal(track);
                    ui.push(n.children[1], i, next, in);
                    tb.t.seal(i);
                },
                .row, .col, .button => {
                    var s = n.style;
                    // A container with an id is a button (kind `.button` always has one).
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

/// Spec rows before radio option `index` within its group: earlier options and their parts.
fn optionRows(comptime index: u32) u32 {
    return index * radio_zig.option_rows;
}

/// Tree rows from range thumb `index` back to its track: the thumb's spec row plus one (the
/// root) minus this is the track's tree row.
fn thumbOffset(comptime index: u32) u32 {
    return index * range_zig.thumb_rows;
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

// ---- test harness: both front ends, replayed input, golden images ------------------------

/// Whether two draw lists are the same: quad bytes, text runs and commands, in order.
pub fn sameDraw(a: *const DrawList, b: *const DrawList) bool {
    if (a.quad_len != b.quad_len or a.run_len != b.run_len or a.cmd_len != b.cmd_len) return false;
    if (!std.mem.eql(u8, a.quadBytes(), b.quadBytes())) return false;
    if (!std.mem.eql(u8, std.mem.sliceAsBytes(a.runs[0..a.run_len]), std.mem.sliceAsBytes(b.runs[0..b.run_len]))) return false;
    for (0..a.cmd_len) |i| {
        if (!std.meta.eql(a.command(@intCast(i)), b.command(@intCast(i)))) return false;
    }
    return true;
}

/// Runs one UI through both front ends, frame by frame, and checks they agree. `App` is the
/// runtime side: plain data with defaults and `pub fn build(*App, *Frame) void`. `Ui` is the
/// comptime side, a `ComptimeUi`. The harness owns both and the runtime context's buffer, so
/// it must not move after `init`; declare it as a `var` at container level (it is too big for
/// a test's stack) and drive it from replayed input:
///
///     h.init();
///     var replay: Replay = .{ .src = @embedFile("testdata/page.replay") };
///     while (try replay.next(buffers)) |in| { const out = try h.frame(in); ... }
pub fn Harness(comptime App: type, comptime Ui: type, comptime caps: context.Limits) type {
    return struct {
        const Self = @This();

        buffer: [context.Context.requiredBytes(caps)]u8 align(mem.column_align) = undefined,
        ctx: context.Context = undefined,
        app: App = .{},
        ui: Ui = .{},
        frames: u32 = 0,

        /// What one frame produced in each front end.
        pub const Pair = struct { runtime: context.Output, comptime_: Ui.Output };

        /// Carves the runtime context from the harness's buffer and resets both front ends.
        pub fn init(h: *Self) void {
            h.ctx = context.Context.init(&h.buffer, caps) catch unreachable;
            h.app = .{};
            h.ui = .{};
            h.frames = 0;
        }

        /// Builds frame `in` in both front ends. `error.FrontEndsDiffer` when their draw lists,
        /// row counts, or `role` and `value` columns (what accessibility reads) differ.
        pub fn frame(h: *Self, in: *const Input) error{FrontEndsDiffer}!Pair {
            var f = h.ctx.begin(in);
            h.app.build(&f);
            const rt = f.end(h.ui.font);
            const cp = h.ui.frame(in);
            h.frames += 1;
            const a = rt.tree;
            const b = cp.tree;
            if (!sameDraw(rt.draw, cp.draw) or a.len != b.len or
                !std.mem.eql(u8, a.c.role[0..a.len], b.c.role[0..b.len]) or
                !std.mem.eql(f32, a.c.value[0..a.len], b.c.value[0..b.len])) return error.FrontEndsDiffer;
            return .{ .runtime = rt, .comptime_ = cp };
        }
    };
}

/// What assistive technology sees of both front ends' current frame in a `Harness`: each
/// tree run through `names`, `states` and `flatten` (a11y/tree.zig), as a bridge would. For
/// widget tests of role, name, value and states; `cap` is at least either tree's capacity.
pub fn Semantic(comptime cap: u32) type {
    return struct {
        const Self = @This();

        buf: [bytes]u8 align(mem.column_align) = undefined,
        /// Runtime front end, then comptime front end.
        out: [2]a11y.Export = undefined,
        strings: [2][]const u8 = .{ "", "" },

        const Parts = struct { s: [2]a11y.Semantics, out: [2]a11y.Export };
        fn carve(carver: *mem.Carver) Parts {
            const s = [2]a11y.Semantics{ .init(carver, cap), .init(carver, cap) };
            return .{ .s = s, .out = .{ .init(carver, cap), .init(carver, cap) } };
        }
        const bytes = blk: {
            @setEvalBranchQuota(20_000);
            var counter: mem.Carver = .{ .buf = null };
            _ = carve(&counter);
            break :blk counter.off;
        };

        /// Exports the frame harness `h` built last. `error.FrontEndsDiffer` when the two
        /// semantic trees differ in shape, id, role, state, value or name.
        pub fn run(x: *Self, h: anytype) error{FrontEndsDiffer}!void {
            var carver: mem.Carver = .{ .buf = &x.buf };
            var p = carve(&carver);
            const ctx = &h.ctx;
            const tb = &h.ui.tables;
            const trees = [2]*const Tree{ &ctx.trees[ctx.cur], &tb.t };
            const txs = [2]*const Texts{ &ctx.texts[ctx.cur], &tb.tx };
            x.strings = .{ ctx.strings[ctx.cur].buf[0..ctx.strings[ctx.cur].len], tb.strings.buf[0..tb.strings.len] };
            for (0..2) |k| {
                std.debug.assert(trees[k].len <= cap);
                p.s[k].clear();
                a11y.names(trees[k], &p.s[k]);
                a11y.states(trees[k], &p.s[k]);
                a11y.flatten(trees[k], txs[k], x.strings[k], &p.s[k], &p.out[k]);
            }
            x.out = p.out;
            const a = &x.out[0];
            const b = &x.out[1];
            if (a.len != b.len) return error.FrontEndsDiffer;
            for (0..a.len) |r| {
                if (a.c.id[r] != b.c.id[r] or a.c.parent[r] != b.c.parent[r] or a.c.role[r] != b.c.role[r] or
                    a.c.state[r] != b.c.state[r] or a.c.value[r] != b.c.value[r] or
                    !std.mem.eql(u8, x.name(0, @intCast(r)), x.name(1, @intCast(r)))) return error.FrontEndsDiffer;
            }
        }

        /// The accessible name of export row `r` of front end `side` (0 runtime, 1 comptime).
        pub fn name(x: *const Self, side: u1, r: u32) []const u8 {
            const o = &x.out[side].c;
            return x.strings[side][o.name_start[r]..][0..o.name_bytes[r]];
        }

        /// The export row of tree row `node` (the runtime front end's numbering, which the
        /// comptime one shares), or null when the node is not exported.
        pub fn row(x: *const Self, node: u32) ?u32 {
            const o = &x.out[0];
            for (0..o.len) |r| if (o.c.node[r] == node) return @intCast(r);
            return null;
        }
    };
}

/// The reference page: the prototype example's toolbar (a button, a checkbox, a slider and a
/// label on a panel) in both front ends, in theme `th`. The harness's own tests and the golden
/// images (tools/widgetgolden/) run it; a widget lane copies it for its own page.
pub fn Reference(comptime th: Theme) type {
    return struct {
        const toolbar_style: Style = .{ .dir = .x, .size = .{ .fill, .fit }, .pad = @splat(8), .gap = 8, .cross = .center, .fill = th.panel };

        /// Runtime front end: the application owns the values.
        pub const App = struct {
            resets: u32 = 0,
            wireframe: bool = false,
            exposure: f32 = 0.25,
            clicked: bool = false,

            pub fn build(app: *App, f: *Frame) void {
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
        pub const State = struct {
            reset_text: []const u8 = "Reset",
            wireframe: bool = false,
            wire_text: []const u8 = "Wireframe",
            exposure: f32 = 0.25,
            layer: []const u8 = "Layer 0",
        };
        pub const spec = spec_zig.row(toolbar_style, .{
            ct.button(th, .reset, .reset_text),
            ct.checkbox(th, .wire, .wireframe, .wire_text),
            ct.slider(th, .exposure, .exposure, .{}),
            ct.label(th, .layer),
        });
        pub const Ui = ComptimeUi(State, spec, th);
        /// Room for the page in the runtime front end.
        pub const page_limits: context.Limits = .{ .nodes = 64, .texts = 16, .customs = 1, .strings = 1024, .depth = 8 };
        /// Both front ends over this page.
        pub const Run = Harness(App, Ui, page_limits);
    };
}

/// Input for `Reference(.default)` at 800 x 600, one commented line per frame.
pub const reference_replay = @embedFile("testdata/reference.replay");

/// The frames of `reference_replay` kept as golden images, by name
/// (tools/widgetgolden/ref/<name>.png).
pub const golden_frames = .{
    .{ "rest", 0 },
    .{ "hover", 1 },
    .{ "held", 2 },
    .{ "checked", 5 },
    .{ "slide", 6 },
};

// ---- tests ----------------------------------------------------------------------------------

const testing = std.testing;

const limits: context.Limits = .{ .nodes = 64, .texts = 16, .customs = 1, .strings = 1024, .depth = 8 };
var rt_buffer: [context.Context.requiredBytes(Default.page_limits)]u8 align(mem.column_align) = undefined;

const theme: Theme = .default;
const Default = Reference(theme);
var default_harness: Default.Run = .{};

fn center(r: types.Rect) [2]f32 {
    return .{ (r.x0 + r.x1) * 0.5, (r.y0 + r.y1) * 0.5 };
}

test "Harness: the reference replay gives the same frames in both front ends" {
    const Replay = @import("../core/input.zig").Replay;
    const h = &default_harness;
    h.init();
    var text: [16]u8 = undefined;
    var evs: [8]Input.Event = undefined;
    var contacts: [1]Input.Contact = undefined;
    const buf: Replay.Buffers = .{ .text = &text, .events = &evs, .contacts = &contacts };
    var replay: Replay = .{ .src = reference_replay };
    var clicks: [12]bool = undefined;
    var wire: [12]bool = undefined;
    var exposure: [12]f32 = undefined;
    var fills: [12]u32 = undefined;
    while (try replay.next(buf)) |in| {
        const k = h.frames;
        const out = try h.frame(in);
        const t = out.runtime.tree;
        clicks[k] = h.app.clicked;
        wire[k] = h.ui.signals.state.wireframe;
        exposure[k] = h.ui.signals.state.exposure;
        fills[k] = t.c.look[t.find(.from("reset"))].fill;
        try testing.expectEqual(h.app.clicked, if (out.comptime_.event) |e| e == .reset else false);
        try testing.expectEqual(h.app.wireframe, wire[k]);
        try testing.expectEqual(h.app.exposure, exposure[k]);
    }
    try testing.expectEqual(@as(u32, 12), h.frames);
    try testing.expectEqualSlices(bool, &.{ false, false, false, true, false, false, false, false, false, false, false, false }, &clicks);
    try testing.expectEqualSlices(bool, &.{ false, false, false, false, false, true, true, true, true, true, true, false }, &wire);
    try testing.expectApproxEqAbs(@as(f32, 0.75), exposure[6], 1e-5);
    try testing.expectApproxEqAbs(@as(f32, 0.1), exposure[7], 1e-5);
    try testing.expectEqual(@as(f32, 0), exposure[8]);
    const c = theme.controlFills();
    try testing.expectEqualSlices(u32, &.{ c[0].bitsOf(), c[1].bitsOf(), c[3].bitsOf(), c[1].bitsOf() }, fills[0..4]);
    // While the slider is held, the pointer over Reset does not light it up.
    try testing.expectEqual(c[0].bitsOf(), fills[8]);
    try testing.expectEqual(c[1].bitsOf(), fills[9]);
}

test "Harness: a front end that draws differently is caught" {
    // The comptime side in another theme: same layout, other colours.
    const other = comptime blk: {
        var o = theme;
        o.accent = .rgb(1, 2, 3);
        break :blk o;
    };
    const Odd = Harness(Default.App, Reference(other).Ui, Default.page_limits);
    const S = struct {
        var h: Odd = .{};
    };
    S.h.init();
    const in: Input = .{ .viewport = .{ 800, 600 } };
    try testing.expectError(error.FrontEndsDiffer, S.h.frame(&in));
    // And sameDraw itself: equal to itself, not to an empty list.
    default_harness.init();
    const out = try default_harness.frame(&in);
    try testing.expect(sameDraw(out.runtime.draw, out.comptime_.draw));
    var empty = out.runtime.draw.*;
    empty.quad_len = 0;
    try testing.expect(!sameDraw(out.runtime.draw, &empty));
}

test "golden_frames: name frames the reference replay has" {
    inline for (golden_frames) |g| try testing.expect(g[1] < 12);
}

test "reference widgets: the same input gives the same draw list in both front ends" {
    try expectFrontEndsAgree(theme);
}

/// Replays 12 frames of clicks and drags, aimed at last frame's rects so any theme's layout is
/// hit, through both front ends in theme `th`, and requires the same draw list, semantics and
/// state after every frame.
fn expectFrontEndsAgree(comptime th: Theme) !void {
    const R = Reference(th);
    const S = struct {
        var h: R.Run = .{};
    };
    const h = &S.h;
    h.init();
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
    for (script) |step| {
        if (step.target) |name| {
            const t = last.?.tree;
            const r = t.rect(t.find(.hash(name)));
            in.pointer = .{ r.x0 + step.along * r.w(), (r.y0 + r.y1) * 0.5 };
        }
        in.buttons.left = step.left;
        const out = try h.frame(&in);
        last = out.runtime;
        // State: the application's fields and the comptime front end's signals agree.
        try testing.expectEqual(h.app.wireframe, h.ui.signals.state.wireframe);
        try testing.expectEqual(h.app.exposure, h.ui.signals.state.exposure);
        const ct_click = if (out.comptime_.event) |e| e == .reset else false;
        try testing.expectEqual(h.app.clicked, ct_click);
        clicks += @intFromBool(ct_click);
    }
    try testing.expectEqual(@as(u32, 1), clicks);
    try testing.expectEqual(@as(u32, 1), h.app.resets);
    try testing.expect(!h.app.wireframe);
    // Dragged left off the track onto the button while held: clamped to lo.
    try testing.expectEqual(@as(f32, 0), h.app.exposure);
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
    var ctx = try context.Context.init(&rt_buffer, Default.page_limits);
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
    for ([2]bool{ false, true }, th.marks()) |v, c| try testing.expectEqual(c, checkboxBox(&th, .of(v)).fill);
    // A comptime theme gives comptime tables: they can live in read-only data.
    const fills = comptime Theme.default.controlFills();
    try testing.expectEqual(th.control_hot, fills[1]);
}

test "button: hover and hold pick the fill by table index; click on release over it" {
    var ctx = try context.Context.init(&rt_buffer, Default.page_limits);
    var app: Default.App = .{};
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
    var ctx = try context.Context.init(&rt_buffer, Default.page_limits);
    var app: Default.App = .{};
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
    var ctx = try context.Context.init(&rt_buffer, Default.page_limits);
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
    try testing.expectEqual(3, Default.Ui.Events.widget_count);
    try testing.expectEqualSlices(spec_zig.Kind, &.{ .button, .checkbox, .slider }, &Default.Ui.Events.widget_kinds);
    try testing.expectEqual(void, @FieldType(Default.Ui.Events.Event, "reset"));
    try testing.expectEqual(f32, @FieldType(Default.Ui.Events.Event, "exposure"));
    try testing.expectEqualSlices(Default.Ui.Events.Widget, &.{ .reset, .wire, .exposure }, Default.Ui.Events.focus_order);
}

test {
    std.testing.refAllDecls(@This());
    std.testing.refAllDecls(ct);
}
