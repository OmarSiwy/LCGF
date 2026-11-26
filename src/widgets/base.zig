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
//!    driving `Harness` over it, and golden images of chosen frames (tools/golden/).
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
//!
//! A widget the spec kinds do not cover sets `Spec.widget` to a namespace (usually a type
//! its builder generates, which also carries its parameters). `ComptimeUi` then calls its
//! `push(ui, n, parent, next, in)` to build the node, which must push one tree row per spec
//! node of its subtree in row order, and before each frame its optional `step(ui, row, event,
//! in)` to apply input to `ui.signals`. During `step`, once `ui.built` is set, `ui.tables.t`
//! still holds last frame's laid-out tree to measure, and `ui.keep(W)` keeps what the widget
//! measured for its `push`. A `step` may return `@TypeOf(event)` instead of `void`: an event
//! of its own (a key that activated the widget), which the frame reports when the pointer
//! made none.
//!
//! A node with an id is a widget (`Events.Widget`). When it also has a `Spec.widget` `W`, `W`
//! may declare `pub const focusable: bool` (default false): whether a press focuses it and Tab
//! stops on it (`Events.focus_order`). And `pub const Payload: type` (default void): what its
//! `Event` carries; a widget with a payload reports its events from `step`, not on a click.
//! A focusable node that its owner pushes itself has `.widget = FocusStop`.
//! `ctResponse` gives a step what `Frame.interact` gives a runtime widget.

const std = @import("std");
const types = @import("../core/types.zig");
const simd = @import("../core/simd.zig");
const mem = @import("../core/mem.zig");
const Tree = @import("../core/tree.zig").Tree;
const Texts = @import("../core/texts.zig").Texts;
const Customs = @import("../core/customs.zig").Customs;
const Strings = @import("../core/strings.zig").Strings;
const fmt = @import("../core/fmt.zig");
const Input = @import("../core/input.zig").Input;
const DrawList = @import("../draw/draw_list.zig").DrawList;
const paint = @import("../draw/paint.zig");
const layout = @import("../layout/layout.zig");
const Mono = @import("../text/protocol.zig").Mono;
const Frame = @import("../runtime/frame.zig").Frame;
const context = @import("../runtime/context.zig");
const spec_zig = @import("../comptime/spec.zig");
const events = @import("../comptime/events.zig");
const focus = @import("../interact/focus.zig");
const signals = @import("../comptime/signals.zig");
const Spec = spec_zig.Spec;
const Id = types.Id;
const Node = types.Node;
const Color = types.Color;
const Style = types.Style;
const TextStyle = types.TextStyle;
const Response = types.Response;
const a11y = @import("../a11y/tree.zig");

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

/// A compile error for the first node in `n`'s subtree whose binding its widget cannot take:
/// a label needs a string; a custom widget (`Spec.widget`) says by its optional `bindError`,
/// and its subtree is its own (it may bind its nodes differently), so it is not walked.
fn checkBindings(comptime State: type, comptime n: Spec) void {
    comptime {
        if (n.region) |r| if (@import("../comptime/validate.zig").regionError(State, r)) |msg| @compileError(msg);
        if (n.widget == null and n.kind == .label) if (spec_zig.labelError(n)) |msg| @compileError(msg);
        if (n.bind) |name| {
            const err: ?[]const u8 = if (n.widget) |W_|
                (if (@hasDecl(W_, "bindError")) W_.bindError(State, name) else null)
            else if (n.kind == .label)
                fieldError(State, "label", name, []const u8)
            else
                null;
            if (err) |msg| @compileError(msg);
        }
        if (n.widget != null) return;
        for (n.children) |c| checkBindings(State, c);
    }
}

/// What a custom widget at spec row `row` of comptime front end `ui` got this frame, as the
/// runtime front end's `Frame.interact` reports it: hover and held (`response`), clicked
/// (this frame's pointer `event` is on it) and focused (`ui.focus`). For `W.step` and
/// `W.push`, which feed it to the same behaviour functions the runtime widget calls.
pub fn ctResponse(ui: anytype, comptime row: u32, event: anytype, in: *const Input) Response {
    const E = @TypeOf(ui.*).Events;
    const w: E.Widget = @fromBackingInt(@as(E.Index, @intCast(row)));
    var r = ui.response(row, in);
    r.clicked = if (event) |e| std.meta.activeTag(e) == w else false;
    r.focused = ui.focus == w;
    return r;
}

/// The `Spec.widget` of a node inside a custom widget that is a focus stop of its own (a radio
/// option, a range slider's thumb, a chip's remove button): its owner pushes and steps it, so
/// it only says `focusable`.
pub const FocusStop = struct {
    pub const focusable = true;

    pub fn push(ui: anytype, comptime n: Spec, parent: u32, next: *u32, in: *const Input) void {
        _ = .{ ui, n, parent, next, in };
        unreachable; // pushed by the widget that owns it
    }
};

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
    /// A literal string or the value of a string field.
    pub fn label(comptime th: Theme, comptime text: anytype) Spec {
        _ = th;
        var node = spec_zig.label(text);
        node.style = .{ .role = .label };
        return node;
    }

    /// A button named `id` showing the string field `text`; its click is its event.
    pub fn button(comptime th: Theme, comptime id: @EnumLiteral(), comptime text: anytype) Spec {
        var s = spec_zig.row(buttonStyle(&th), .{ct.label(th, text)});
        s.id = @tagName(id);
        return s;
    }

    /// A checkbox named `id` toggling the bool field `bind`, captioned by the string field `text`.
    pub fn checkbox(comptime th: Theme, comptime id: @EnumLiteral(), comptime bind: @EnumLiteral(), comptime text: anytype) Spec {
        var s = spec_zig.row(checkboxStyle(&th), .{ Spec{ .kind = .col }, ct.label(th, text) });
        s.kind = .checkbox;
        s.id = @tagName(id);
        s.bind = @tagName(bind);
        return s;
    }

    /// A slider named `id` setting the f32 field `bind`, 0 to 1.
    /// A node named `id` that the host draws itself: its rect comes back as a custom command
    /// carrying `data`.
    pub fn custom(comptime id: @EnumLiteral(), comptime style: Style, comptime data: u64) Spec {
        return .{ .kind = .col, .id = @tagName(id), .style = style, .custom = data };
    }

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
    comptime checkBindings(State, spec);
    const E = events.Events(spec);
    const S = signals.Signals(State, spec);
    const has_input_availability = blk: {
        var found = false;
        for (customRows(spec)) |row| {
            const n = nodeAt(spec, row);
            if (n.id != null and @hasDecl(n.widget.?, "inputAvailability")) found = true;
        }
        break :blk found;
    };
    // One root row (the runtime front end's) above the spec's rows.
    const rows: u32 = flatten.count(spec) + 1;
    @setEvalBranchQuota(1000 + 100 * rows);
    const runs: u32 = @max(labelCount(spec), 1);
    const customs = comptime customCapacity(spec);
    const Regions = @import("../comptime/dynamic.zig").Regions(spec);
    const dynamic = Regions.count != 0;
    return struct {
        const Self = @This();
        pub const Events = E;

        pub const Signals = S;
        pub const Springs = @import("../anim/anims.zig").BoundSprings(State);
        /// The theme the page was built with, for widgets that build their own rows.
        pub const theme = th;

        buf: [bytes]u8 align(mem.column_align) = undefined,
        tables: Tables = undefined,
        signals: S.Runtime = .{},
        springs: Springs = .{},
        pointer: E.Pointer = .{},
        /// Last frame's widget rects, which this frame's input is judged against.
        rects: E.Rects = .{},
        /// The focused widget: set by every left press to the widget under it, and cleared by
        /// a press over no widget. Unlike `Interaction.focus`, a press on a widget that is not
        /// focusable also focuses it (the widgets on main read their keys this way). Custom
        /// widgets read it for their keys, and a `step` may move it (arrow keys inside a
        /// composite widget). `focusable` decides the Tab order (`Events.focus_order`).
        focus: ?E.Widget = null,
        /// Mirrors Focus.visible: key presses reveal focus, pointer presses hide it.
        focus_visible: bool = false,
        /// The current frame's explicitly supplied preferences, available to custom widgets.
        frame_settings: @import("../a11y/settings_data.zig").Settings = .{},
        /// First error reported by a custom widget during this frame; no exception or callback.
        failure: ?anyerror = null,
        /// Omitted entirely when no custom widget declares inputAvailability(ui, in).
        input_mask: if (has_input_availability) E.InputMask else void = if (has_input_availability) .{} else {},
        /// Eligibility of the geometry in `rects`, like the runtime tree's previous `sense`.
        /// Current state may disable it immediately; re-enabling takes effect after rebuilding.
        previous_input_mask: if (has_input_availability) E.InputMask else void = if (has_input_availability) .{} else {},
        /// Exact previous-geometry hit captured before this single-buffer UI rebuilds its
        /// tree. Rects may borrow that tree, so build-time response cannot query it again.
        build_hit: ?E.Widget = null,
        building: bool = false,
        platform_cursor: types.Cursor = .arrow,
        cursor_set: bool = false,
        /// Four floats per custom widget (`Spec.widget`, in row order) that it keeps from frame
        /// to frame, such as what its `step` measured in last frame's tree for its `push`.
        /// Zero until it writes them.
        kept: [customRows(spec).len][4]f32 = @splat(@splat(0)),
        /// A frame has been built: from then on, during `step`, `tables.t` is last frame's
        /// laid-out tree.
        built: bool = false,
        /// A dynamic page omits inactive subtrees; each live descriptor maps to its packed tree row.
        tree_rows: [if (dynamic) rows - 1 else 0]u32 = @splat(types.none),
        window_selection: [if (Regions.has_windows) Regions.count else 0]@import("../comptime/dynamic.zig").Select = undefined,
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
                    .cu = Customs.init(carver, customs),
                    .strings = .{ .buf = carver.slice(u8, string_bytes) },
                    .d = DrawList.init(carver, rows, runs, customs),
                };
            }
        };
        const string_bytes = spec_zig.stringCapacity(spec, 1024);
        const bytes = blk: {
            @setEvalBranchQuota(20_000);
            var counter: mem.Carver = .{ .buf = null };
            _ = Tables.carve(&counter);
            break :blk counter.off;
        };

        pub const Output = struct { draw: *const DrawList, tree: *const Tree, event: ?E.Event, wake: f32 = types.inf, failure: ?anyerror = null, cursor: types.Cursor = .arrow };

        /// True while a declared spring moves or its target has changed since the last frame.
        pub fn needsAnimationFrame(ui: *const Self) bool {
            return ui.springs.pending(&ui.signals.state);
        }

        /// The displayed value of a bool/f32 field, interpolated if State declares a spring for it.
        pub fn animated(ui: *const Self, comptime target: S.Field) f32 {
            return ui.springs.value(&ui.signals.state, @tagName(target));
        }

        /// Steps input against last frame's rects, applies each widget's behaviour to the state,
        /// then builds, lays out and paints the frame. A button's click is returned as `event`
        /// for the caller to act on; checkboxes and sliders have already written their field.
        pub fn frame(ui: *Self, in: *const Input) Output {
            return ui.frameWithSettings(in, &.{});
        }

        /// Uses the same accessibility settings as the runtime context.
        pub fn frameWithSettings(ui: *Self, in: *const Input, settings: *const @import("../a11y/settings_data.zig").Settings) Output {
            return ui.frameWithPresentation(in, settings, .{}) catch unreachable;
        }

        /// Optional caller-owned direction rows and device grid, sequenced at the same
        /// points as style.locale.end. Tree/keyboard/semantic order is never reversed.
        pub fn frameWithPresentation(ui: *Self, in: *const Input, settings: *const @import("../a11y/settings_data.zig").Settings, presentation: @import("../style/locale.zig").Presentation) @import("../style/locale.zig").LayoutError!Output {
            try presentation.rounding.validate();
            if (presentation.directions) |directions| try @import("../style/locale.zig").validateDirections(directions, rows);
            const active = if (dynamic) Regions.mask(Regions.select(State, &ui.signals.state)) else {};
            if (dynamic and E.widget_count > 0) {
                for (E.widget_nodes, 0..) |row, slot| if (active[row] == 0) {
                    for (&ui.rects.c) |*side| side[slot] = 0;
                };
                if (ui.focus) |w| if (active[@backingInt(w)] == 0) {
                    ui.focus = null;
                };
                if (ui.pointer.pressed) |w| if (active[@backingInt(w)] == 0) {
                    ui.pointer.pressed = null;
                };
            }
            const press = in.buttons.left and !ui.pointer.down;
            ui.frame_settings = settings.*;
            ui.failure = null;
            ui.platform_cursor = .arrow;
            ui.cursor_set = false;
            var key = false;
            for (in.events) |e| key = key or e.kind == .press;
            ui.focus_visible = ((ui.focus_visible or key) and !press) or settings.always_show_focus;
            _ = ui.refreshInputAvailability(in);
            var event = if (comptime has_input_availability)
                E.pointerEnabled(&ui.pointer, &ui.rects, &ui.input_mask, in)
            else
                E.pointer(&ui.pointer, &ui.rects, in);
            if (press) ui.focus = ui.pointer.pressed;
            // Tab and Shift+Tab, as `Context.begin` moves `Interaction.focus`.
            if (dynamic and E.focus_order.len > 0) {
                for (in.events) |e| {
                    if (e.code != (focus.Keymap{}).tab or (e.kind != .press and e.kind != .repeat)) continue;
                    var w = ui.focus;
                    ui.focus = null;
                    for (0..E.focus_order.len) |_| {
                        w = E.nextFocus(w, e.mods.shift);
                        if (active[@backingInt(w.?)] != 0 and (comptime !has_input_availability or ui.input_mask.allows(w.?))) {
                            ui.focus = w;
                            break;
                        }
                    }
                }
            } else if (comptime has_input_availability)
                E.focusKeysEnabled(&ui.focus, in, (focus.Keymap{}).tab, &ui.input_mask)
            else
                E.focusKeys(&ui.focus, in, (focus.Keymap{}).tab);
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
            // Custom widgets (`Spec.widget`) apply this frame's input to their state.
            inline for (comptime customRows(spec)) |row| {
                const W_ = comptime nodeAt(spec, row).widget.?;
                // A step may return an event of its own (a key that activates the widget),
                // which the frame reports when the pointer made none.
                if (comptime @hasDecl(W_, "step")) {
                    if (!dynamic or (active[row] != 0 and (!ui.built or ui.tree_rows[row] != types.none))) {
                        const got = W_.step(ui, row, event, in);
                        if (@TypeOf(got) == ?E.Event) {
                            const accepted = if (comptime has_input_availability) ui.allowedEvent(got) else got;
                            event = event orelse accepted;
                        }
                    }
                }
            }
            // A step may have disabled another control. Update hover/focus for the build
            // without retroactively canceling an activation that legitimately caused it.
            const next_input_mask = ui.refreshInputAvailability(in);
            if (comptime has_input_availability) {
                if (ui.focus) |target| if (!ui.input_mask.allows(target)) {
                    ui.focus = null;
                };
            }

            ui.springs.frame(&ui.signals.state, in.dt, !ui.built, settings.reduced_motion);
            ui.build_hit = ui.hitAt(in);
            ui.building = true;
            defer ui.building = false;
            var carver: mem.Carver = .{ .buf = &ui.buf };
            ui.tables = Tables.carve(&carver);
            const tb = &ui.tables;
            tb.t.reset();
            tb.tx.reset();
            tb.cu.reset();
            tb.strings.reset();
            // The runtime front end's root (`Context.begin`).
            _ = tb.t.push(0, context.root_id, &.{ .size = .{ .px(in.viewport[0]), .px(in.viewport[1]) }, .clip = true, .role = .group });
            if (dynamic) {
                // Input handlers can change selectors. Use their final values to build this frame.
                const selection = Regions.select(State, &ui.signals.state);
                const live = Regions.mask(selection);
                if (Regions.has_windows) ui.window_selection = selection;
                var tree_row: u32 = 1;
                for (&ui.tree_rows, live[0 .. rows - 1]) |*dest, bit| {
                    dest.* = if (bit != 0) tree_row else types.none;
                    tree_row += @intFromBool(bit != 0);
                }
                if (E.widget_count > 0) {
                    if (ui.focus) |w| if (live[@backingInt(w)] == 0) {
                        ui.focus = null;
                    };
                    if (ui.pointer.pressed) |w| if (live[@backingInt(w)] == 0) {
                        ui.pointer.pressed = null;
                    };
                }
            }
            var next: u32 = 0;
            ui.push(spec, 0, &next, in);
            tb.t.seal(0);

            // `Frame.end`'s pass sequence.
            const t = &tb.t;
            const tx = &tb.tx;
            if (presentation.directions) |directions| {
                @import("../layout/rtl.zig").direction(t, directions);
                @import("../layout/rtl.zig").startEnd(t, directions);
            }
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
            if (presentation.directions) |directions| @import("../layout/rtl.zig").mirror(t, directions);
            try layout.finalizeWith(t, presentation.rounding);
            paint.emit(t, tx, &tb.cu, tb.strings.buf[0..tb.strings.len], &tb.d);

            if (dynamic) {
                // ponytail: no exact (transformed) hits on dynamic pages; Rects maps rows by a
                // fixed offset. Give Rects a row map if a dynamic page needs transformed hits.
                ui.rects = .{};
                for (E.widget_nodes, 0..) |node, k| {
                    const row = ui.treeRow(node);
                    if (row == types.none or !t.x.row[t.c.scope[row]].active_participation.hit) continue;
                    inline for (0..4) |side| ui.rects.c[side][k] = t.c.vis[side][row];
                }
            } else ui.rects = E.Rects.fromTreeOffset(t, 1);
            if (!ui.cursor_set) {
                if (ui.build_hit) |target| {
                    const owned = ui.pointer.pressed == null or ui.pointer.pressed == target;
                    const row = ui.treeRow(@backingInt(target));
                    if (owned and row != types.none and t.participation(row).hit) ui.platform_cursor = t.cursor(row) orelse .arrow;
                }
            }
            if (comptime has_input_availability) ui.previous_input_mask = next_input_mask;
            ui.built = true;
            var wake = simd.selF(ui.needsAnimationFrame(), 0, types.inf);
            // An optional custom widget can request its next visual update as returned
            // deadline data. Hidden/collapsed subtrees do not request visual updates;
            // static controls add no hook or timer storage.
            inline for (comptime customRows(spec)) |row| {
                const Widget = comptime nodeAt(spec, row).widget.?;
                if (comptime @hasDecl(Widget, "wakeAfter")) {
                    const node = ui.treeRow(row);
                    if (node < t.len and t.participation(node).paint) wake = @min(wake, Widget.wakeAfter(ui, in));
                }
            }
            return .{ .draw = &tb.d, .tree = t, .event = event, .wake = wake, .failure = ui.failure, .cursor = ui.platform_cursor };
        }

        /// Pushes `n` (spec row `next.*`) and its subtree under tree row `parent`. A custom
        /// widget pushes its own rows, one per node of its subtree in row order, and advances
        /// `next` past them.
        pub fn push(ui: *Self, comptime n: Spec, parent: u32, next: *u32, in: *const Input) void {
            if (dynamic and ui.tree_rows[next.*] == types.none) {
                next.* += comptime flatten.count(n);
                return;
            }
            if (comptime n.widget) |W_| return W_.push(ui, n, parent, next, in);
            if (comptime n.custom) |data| {
                const id = Id.hash(n.id orelse @compileError("a custom draw needs an id"));
                const tb = &ui.tables;
                next.* += 1;
                const i = tb.t.push(parent, id, &n.style);
                tb.t.c.custom[i] = tb.cu.push(i, id, data);
                tb.t.seal(i);
                return;
            }
            const tb = &ui.tables;
            const state = &ui.signals.state;
            next.* += 1;
            switch (n.kind) {
                .label => {
                    const i = tb.t.push(parent, .none, &n.style);
                    const span = if (comptime n.format) |f| blk: {
                        const segs = comptime fmt.compile(State, f.text, f.args);
                        var sink: fmt.Sink = .{ .buf = tb.strings.buf[tb.strings.len..] };
                        fmt.write(segs, f.text, fmt.Fields(State, f.args){ .state = state }, &sink);
                        const sp: @import("../core/strings.zig").Span = .{ .start = tb.strings.len, .bytes = @intCast(sink.len) };
                        tb.strings.len += sp.bytes;
                        tb.strings.overflow = simd.orB(tb.strings.overflow, sink.cut);
                        break :blk sp;
                    } else tb.strings.add(spec_zig.labelBytes(n, state));
                    tb.t.c.text[i] = tb.tx.push(i, span, &(n.text_style orelse labelText(&th)));
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
                    const value = ui.animated(field(n.bind.?));
                    var s = n.style;
                    s.value = value;
                    const i = tb.t.push(parent, .hash(n.id.?), &s);
                    next.* += 1;
                    _ = tb.t.push(i, .none, &sliderThumb(&th, fraction(value, 0, 1)));
                    tb.t.seal(i);
                },
                .row, .col => {
                    var s = n.style;
                    if (comptime n.region != null and n.region.?.window != null) {
                        for (Regions.regions, ui.window_selection) |region, sel| {
                            if (region.row == next.* - 1) s.scroll[1] = sel.offset;
                        }
                    }
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
        /// The floats the custom widget `W` (its `Spec.widget`) keeps (`kept`).
        pub fn keep(ui: *Self, comptime W: type) *[4]f32 {
            const k = comptime blk: {
                for (customRows(spec), 0..) |row, k| if (nodeAt(spec, row).widget == W) break :blk k;
                @compileError("no custom widget " ++ @typeName(W) ++ " in this spec");
            };
            return &ui.kept[k];
        }

        /// Current tree row of a spec descriptor, or types.none when its subtree is inactive.
        pub inline fn treeRow(ui: *const Self, row: u32) u32 {
            return if (dynamic) ui.tree_rows[row] else row + 1;
        }

        /// During a widget step, geometry of a descriptor in the last completed frame.
        pub fn lastRect(ui: *const Self, row: u32) types.Rect {
            if (!ui.built) return .{};
            const tree_row = ui.treeRow(row);
            if (dynamic and tree_row == types.none) return .{};
            return ui.tables.t.rect(tree_row);
        }

        /// Custom widgets keep the existing non-error-returning frame API and report failure
        /// as output data. The caller decides whether to display, retry or reject that frame.
        pub fn fail(ui: *Self, err: anyerror) void {
            ui.failure = ui.failure orelse err;
        }

        /// Explicit override as on Frame. A caller can pass its actual hover response; the
        /// default at frame end otherwise comes from the hovered node's inherited style.
        pub fn setCursor(ui: *Self, cursor: types.Cursor, when: bool) void {
            if (when) {
                ui.platform_cursor = cursor;
                ui.cursor_set = true;
            }
        }

        /// Optional custom-widget contract, statically dispatched like push/step:
        /// inputAvailability(ui, in) returns events.Availability from authoritative state.
        fn refreshInputAvailability(ui: *Self, in: *const Input) if (has_input_availability) E.InputMask else void {
            if (comptime has_input_availability) {
                var current: E.InputMask = .{};
                inline for (comptime customRows(spec)) |row| {
                    const n = comptime nodeAt(spec, row);
                    if (comptime n.id != null and @hasDecl(n.widget.?, "inputAvailability")) {
                        const target = @field(E.Widget, n.id.?);
                        current.set(target, n.widget.?.inputAvailability(ui, in));
                    }
                }
                ui.input_mask = current;
                if (ui.built) {
                    for (&ui.input_mask.enabled, ui.previous_input_mask.enabled) |*enabled, previous| enabled.* &= previous;
                }
                return current;
            }
        }

        fn allowedEvent(ui: *const Self, event: ?E.Event) ?E.Event {
            if (comptime !has_input_availability or E.widget_count == 0) return event;
            if (event) |e| switch (e) {
                inline else => |_, target| if (ui.input_mask.activates[E.slot(target)] == 0) return null,
            };
            return event;
        }

        pub fn response(ui: *const Self, row: u32, in: *const Input) Response {
            const w: E.Widget = @fromBackingInt(@as(E.Index, @intCast(row)));
            if (comptime has_input_availability) if (!ui.input_mask.allows(w)) return .{};
            const held = ui.pointer.pressed == w;
            const owned = ui.pointer.pressed == null or held;
            const under = (if (ui.building) ui.build_hit else ui.hitAt(in)) == w;
            return .{ .hovered = under and owned, .held = held };
        }

        fn hitAt(ui: *const Self, in: *const Input) ?E.Widget {
            return if (comptime has_input_availability)
                E.atEnabled(&ui.rects, &ui.input_mask, in.pointer[0], in.pointer[1])
            else
                E.at(&ui.rects, in.pointer[0], in.pointer[1]);
        }

        pub fn field(comptime name: []const u8) S.Field {
            return comptime std.meta.stringToEnum(S.Field, name).?;
        }
    };
}

/// Depth-first rows of the nodes in `n`'s subtree that are custom widgets (`Spec.widget`).
fn customRows(comptime n: Spec) []const u32 {
    comptime {
        var rows: []const u32 = &.{};
        var i: u32 = 0;
        customWalk(n, &i, &rows);
        const out = rows[0..rows.len].*;
        return &out;
    }
}

fn customWalk(comptime n: Spec, comptime next: *u32, comptime rows: *[]const u32) void {
    if (n.widget != null) rows.* = rows.* ++ .{next.*};
    next.* += 1;
    for (n.children) |c| customWalk(c, next, rows);
}

/// Built-in markers reserve exactly one command. Widget hooks can declare their own
/// `custom_slots`; unannotated hooks share the original single spare slot on a page.
fn customCapacity(comptime n: Spec) u32 {
    var known: u32 = 0;
    var spare = false;
    countCustoms(n, &known, &spare);
    return @max(1, known + @intFromBool(spare));
}

fn countCustoms(comptime n: Spec, known: *u32, spare: *bool) void {
    if (n.custom != null) known.* += 1;
    if (n.widget) |W_| {
        if (@hasDecl(W_, "custom_slots")) known.* += W_.custom_slots else spare.* = true;
    }
    for (n.children) |child| countCustoms(child, known, spare);
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
/// images (tools/golden/) run it; a widget lane copies it for its own page.
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
            ct.slider(th, .exposure, .exposure),
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
/// (tools/golden/ref/widgets/<name>.png).
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
    for ([2]bool{ false, true }, th.marks()) |v, c| try testing.expectEqual(c, checkboxBox(&th, v).fill);
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
    try testing.expectEqualSlices(spec_zig.Kind, &.{ .row, .checkbox, .slider }, &Default.Ui.Events.widget_kinds);
    try testing.expectEqual(void, @FieldType(Default.Ui.Events.Event, "reset"));
    try testing.expectEqual(f32, @FieldType(Default.Ui.Events.Event, "exposure"));
    try testing.expectEqualSlices(Default.Ui.Events.Widget, &.{ .wire, .exposure }, Default.Ui.Events.focus_order);
}

/// A custom widget declaring all three optional parts of the `Spec.widget` contract: it is
/// focusable, its events carry a `u32`, and its `step` reports one (the number of Enter
/// presses) while it has focus.
const Knob = struct {
    pub const focusable = true;
    pub const Payload = u32;

    pub fn step(ui: anytype, comptime row: u32, event: anytype, in: *const Input) @TypeOf(event) {
        _ = row;
        const E = @TypeOf(ui.*).Events;
        var presses: u32 = 0;
        for (in.events) |e| presses += @intFromBool(e.kind == .press and e.code == 0x28);
        if (ui.focus != E.Widget.knob or presses == 0) return null;
        return @unionInit(E.Event, "knob", presses);
    }

    pub fn push(ui: anytype, comptime n: Spec, parent: u32, next: *u32, in: *const Input) void {
        _ = in;
        _ = ui.tables.t.push(parent, .hash(n.id.?), &n.style);
        next.* += 1;
    }
};

test "Spec.widget: a custom widget's focusable, Payload and step event, end to end" {
    const knob: Spec = comptime .{ .kind = .col, .id = "knob", .style = .{ .size = .{ .px(40), .px(20) } }, .widget = Knob };
    const page = comptime spec_zig.row(.{}, .{ knob, ct.checkbox(theme, .wire, .wire, .wire_text) });
    const Ui = ComptimeUi(struct { wire: bool = false, wire_text: []const u8 = "Wire" }, page, theme);
    const E = Ui.Events;
    try testing.expectEqual(u32, @FieldType(E.Event, "knob"));
    try testing.expectEqualSlices(E.Widget, &.{ .knob, .wire }, E.focus_order);
    const S = struct {
        var ui: Ui = .{};
    };
    const ui = &S.ui;
    var in: Input = .{ .viewport = .{ 200, 100 } };
    _ = ui.frame(&in);
    // A click on the knob focuses it but is not an event: its events carry a payload.
    in.pointer = .{ 10, 10 };
    in.buttons.left = true;
    try testing.expectEqual(@as(?E.Event, null), ui.frame(&in).event);
    try testing.expectEqual(@as(?E.Widget, .knob), ui.focus);
    in.buttons.left = false;
    try testing.expectEqual(@as(?E.Event, null), ui.frame(&in).event);
    // Enter twice while it has focus: its step reports an event carrying 2.
    const keys2 = [2]Input.Event{ .{ .kind = .press, .code = 0x28 }, .{ .kind = .press, .code = 0x28 } };
    in.events = &keys2;
    const out = ui.frame(&in);
    try testing.expectEqual(@as(u32, 2), out.event.?.knob);
    // A press over nothing clears focus; Enter then reports nothing.
    in.events = &.{};
    in.pointer = .{ 190, 90 };
    in.buttons.left = true;
    _ = ui.frame(&in);
    in.buttons.left = false;
    try testing.expectEqual(@as(?E.Widget, null), ui.focus);
    in.events = &keys2;
    try testing.expectEqual(@as(?E.Event, null), ui.frame(&in).event);
}

test {
    std.testing.refAllDecls(@This());
    std.testing.refAllDecls(ct);
}

test "multiple host draw markers keep their ids, clip and paint order" {
    const interop = @import("../comptime/interop.zig");
    const size: Style = comptime .{ .size = .{ .px(60), .px(20) } };
    const page = comptime spec_zig.col(.{ .size = .{ .px(40), .px(50) }, .clip = true }, .{
        interop.region(.list, size),
        interop.canvas(.preview, size, 17),
    });
    var ui: ComptimeUi(struct {}, page, .default) = .{};
    const out = ui.frame(&.{ .viewport = .{ 100, 100 } });
    try std.testing.expectEqual(2, ui.tables.cu.cap);
    try std.testing.expectEqual(2, out.draw.custom_len);
    try std.testing.expectEqual(2, out.draw.cmd_len);
    for ([_][]const u8{ "list", "preview" }, 0..) |name, k| {
        const cmd = out.draw.command(@intCast(k));
        const item = out.draw.customs[cmd.custom];
        try std.testing.expectEqual(@backingInt(Id.hash(name)), item.id);
        try std.testing.expectEqual(@as(u64, if (k == 0) 0 else 17), item.data);
        try std.testing.expectEqual(@as(f32, 40), item.clip[2]);
        try std.testing.expectEqual(@as(f32, @floatFromInt(k * 20)), item.rect[1]);
    }
}

test "dynamic widget pages compact inactive when, list and choice subtrees" {
    const th: Theme = .default;
    const button_zig = @import("button.zig");
    const spec = comptime spec_zig.col(.{}, .{
        spec_zig.when(.show, button_zig.ct.button(th, .first, "First")),
        spec_zig.list(.count, 3, .{}, spec_zig.label("item")),
        spec_zig.choice(.tab, .{}, .{ spec_zig.label("A"), spec_zig.label("B") }),
        button_zig.ct.button(th, .last, "Last"),
    });
    const State = struct { show: bool = true, count: i8 = 2, tab: u8 = 0 };
    const Ui = ComptimeUi(State, spec, th);
    const App = struct {
        state: State = .{},
        pub fn build(app: *@This(), f: *Frame) void {
            _ = f.open(.none, .{});
            if (app.state.show) _ = button_zig.button(f, &th, .from("first"), "First");
            _ = f.open(.none, .{});
            for (0..@intCast(std.math.clamp(app.state.count, 0, 3))) |_| _ = f.textStyled("item", labelText(&th), .{});
            f.close();
            _ = f.open(.none, .{});
            if (app.state.tab < 2) _ = f.textStyled(if (app.state.tab == 0) "A" else "B", labelText(&th), .{});
            f.close();
            _ = button_zig.button(f, &th, .from("last"), "Last");
            f.close();
        }
    };
    var h: Harness(App, Ui, .{ .nodes = 32, .texts = 16, .strings = 256, .depth = 8 }) = undefined;
    h.init();
    const in: Input = .{ .viewport = .{ 320, 180 } };
    _ = try h.frame(&in);
    for ([_]State{ .{ .show = false, .count = -1, .tab = 1 }, .{ .show = true, .count = 7, .tab = 9 }, .{} }) |state| {
        h.app.state = state;
        h.ui.signals.state = state;
        _ = try h.frame(&in);
    }
    h.ui.focus = .first;
    h.ui.signals.set(.show, false);
    const out = h.ui.frame(&.{ .viewport = in.viewport, .events = &.{.{ .code = (focus.Keymap{}).tab, .kind = .press }} });
    try std.testing.expectEqual(Ui.Events.Widget.last, h.ui.focus.?);
    try std.testing.expectEqualStrings("itemitemALast", out.draw.strings);
    const last = out.tree.rect(out.tree.find(.from("last")));
    try std.testing.expectEqual(Ui.Events.Widget.last, Ui.Events.at(&h.ui.rects, last.x0 + 1, last.y0 + 1).?);
}

test "a widget page virtual list keeps the clipped fractional row" {
    const spec = comptime spec_zig.virtualList(.count, .scroll, 2, 20, spec_zig.label("row"));
    const State = struct { count: u32 = 10, scroll: f32 = 65 };
    var ui: ComptimeUi(State, spec, .default) = .{};
    const out = ui.frame(&.{ .viewport = .{ 200, 120 } });
    try std.testing.expectEqual(3, ui.window_selection[0].first);
    try std.testing.expectEqual(3, out.draw.run_len);
    try std.testing.expectEqual(@as(f32, -5), out.draw.runs[0].rect[1]);
    try std.testing.expectEqual(@as(f32, 40), out.draw.runs[0].clip[3]);
}
