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
//! A focusable node that its owner pushes itself has `.widget = FocusStop`. A `W` whose region
//! hides it (`spec.when`) steps only while it is live, unless it declares `pub const
//! steps_hidden = true` (a tooltip decides from its target's hover when to show).
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
const Flex = @import("../layout/flex.zig").Flex;
const grid = @import("../layout/grid.zig");
const overlay = @import("../layout/overlay.zig");
const scroll_zig = @import("../layout/scroll.zig");
const Mono = @import("../text/protocol.zig").Mono;
const text_stack = @import("../text/layout/stack.zig");
const Paragraph = text_stack.Paragraph;
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
/// `Theme`). The defaults are the prototype's dark theme. An extern struct: C, C++ and Rust
/// pass it by pointer as it is (`lcgf_theme`), with nothing to decode per widget call.
pub const Theme = extern struct {
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
/// and its subtree is its own (it may bind its nodes differently), so it is not walked, unless
/// it declares `pub const holds_content = true` (a dialog: its children are the page's).
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
        if (n.widget) |W_| if (!@hasDecl(W_, "holds_content")) return;
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
    return ComptimeUiTokens(State, spec, th, void);
}

/// `ComptimeUi` whose rows also read run-time theme tokens (`spec.tokened`) from a
/// caller-owned `theme_table.ThemeTable(Tokens)` (`ui.tokens`) when they are pushed, so a
/// changed table lays the page out again on the next frame (`themeChanged`). With `Tokens`
/// void it is `ComptimeUi`, with no field and no code for tokens.
pub fn ComptimeUiTokens(comptime State: type, comptime spec: Spec, comptime th: Theme, comptime Tokens: type) type {
    const flatten = @import("../comptime/flatten.zig");
    const Table = if (Tokens == void) void else @import("../theme/table.zig").ThemeTable(Tokens);
    comptime checkBindings(State, spec);
    const E = events.Events(spec);
    const S = signals.Signals(State, spec);
    // One walk, not a `nodeAt` per widget: a spec of many recipe text rows stays in quota.
    const has_input_availability = gatesInput(spec);
    // One root row (the runtime front end's) above the spec's rows.
    const rows: u32 = flatten.count(spec) + 1;
    @setEvalBranchQuota(1000 + 100 * rows);
    const runs: u32 = @max(labelCount(spec), 1);
    const customs = comptime customCapacity(spec);
    const Regions = @import("../comptime/dynamic.zig").Regions(spec);
    const dynamic = Regions.count != 0;
    // Flex columns and passes only for a page with a `spec.flexed` node.
    const has_flex = comptime anyFlex(spec);
    // The flex passes compile in per-line baselines only for a page that has such a row.
    const flex_opts: @import("../layout/flex.zig").FlexOptions = .{ .line_baseline = comptime anyLineBaseline(spec) };
    // Paragraph styles and decorations (`spec.paragraph`, `spec.decorated`): their distinct
    // values, and one slot per label that has either.
    const paragraph_styles = comptime paragraphDistinct(spec);
    const paragraph_table = comptime paragraph_styles.paragraphs[0..paragraph_styles.paragraphs.len].*;
    const decoration_table = comptime paragraph_styles.decorations[0..paragraph_styles.decorations.len].*;
    const span_table = comptime paragraph_styles.spans[0..paragraph_styles.spans.len].*;
    const paragraph_slots = comptime paragraphCount(spec);
    // Grid columns and passes only for a page with a `spec.grid` node.
    const grid_cap = comptime gridCapacity(spec);
    const has_grid = grid_cap.grids > 0;
    // Anchor, sticky and layer columns and passes only for a page that uses them.
    const anchor_rows = comptime countPositioned(spec, .anchor);
    const sticky_rows = comptime countPositioned(spec, .sticky);
    const has_layers = comptime countPositioned(spec, .layer) > 0;
    return struct {
        const Self = @This();
        pub const Events = E;

        pub const Signals = S;
        pub const Springs = @import("../anim/anims.zig").BoundSprings(State);
        /// The theme the page was built with, for widgets that build their own rows.
        pub const theme = th;
        /// The table `tokens` points at until the caller sets it: the defaults.
        pub const default_tokens: Table = if (Tokens == void) {} else .{};

        /// Node `n`'s style and text style with its token fields read from the table.
        fn tokenStyles(ui: *const Self, comptime n: Spec) struct { style: Style, text: TextStyle } {
            var out: @typeInfo(@TypeOf(tokenStyles)).@"fn".return_type.? = .{ .style = n.style, .text = n.text_style orelse labelText(&th) };
            spec_zig.applyTokens(n.tokens, &out.style, &out.text, &ui.tokens.values);
            return out;
        }

        /// Whether the token table changed since the last frame, which lays the page out with
        /// the new values.
        pub fn themeChanged(ui: *const Self) bool {
            if (Tokens == void) return false;
            return ui.tokens.changedSince(ui.seen);
        }

        buf: [bytes]u8 align(mem.column_align) = undefined,
        /// The caller's theme tokens; point it at your table.
        tokens: if (Tokens == void) void else *const Table = if (Tokens == void) {} else &default_tokens,
        /// The table's generation the last frame read.
        seen: if (Tokens == void) void else u32 = if (Tokens == void) {} else 0,
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
        /// This frame's styled labels: texts row and `paragraph_table` index, for
        /// `MonoParagraphs`. Absent on a page without `spec.paragraph`.
        paragraphs: if (paragraph_slots > 0) struct { rows: [paragraph_slots]u32 = undefined, styles: [paragraph_slots]u16 = undefined, len: u32 = 0 } else void = if (paragraph_slots > 0) .{} else {},

        /// The layer column and, for hits in paint order (`Events.Rects.stack`), each widget's
        /// tree row in the frame built last.
        const Stacking = struct { l: overlay.Layers, rows: []u32 };

        const Tables = struct {
            t: Tree,
            tx: Texts,
            cu: Customs,
            strings: Strings,
            d: DrawList,
            fx: if (has_flex) Flex else void,
            gs: if (has_grid) grid.Grids else void,
            an: if (anchor_rows > 0) overlay.Anchors else void,
            st: if (sticky_rows > 0) scroll_zig.Sticky else void,
            ly: if (has_layers) Stacking else void,

            fn carve(carver: *mem.Carver) Tables {
                return .{
                    .t = Tree.init(carver, rows),
                    .tx = Texts.init(carver, runs),
                    .cu = Customs.init(carver, customs),
                    .strings = .{ .buf = carver.slice(u8, string_bytes) },
                    .d = DrawList.init(carver, rows, runs, customs),
                    .fx = if (has_flex) .{ .c = carver.columns(Flex.Columns, simd.rows(rows)) } else {},
                    .gs = if (has_grid) grid.Grids.init(carver, grid_cap) else {},
                    .an = if (anchor_rows > 0) overlay.Anchors.init(carver, anchor_rows) else {},
                    .st = if (sticky_rows > 0) scroll_zig.Sticky.init(carver, sticky_rows) else {},
                    .ly = if (has_layers) .{ .l = overlay.Layers.init(carver, rows), .rows = carver.slice(u32, E.widget_count) } else {},
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
            return ui.frameAs(false, in, settings, presentation, {});
        }

        /// Builds, lays out and paints the frame again from the state as it is now, applying no
        /// input: for a caller that changed what the layout reads after `frame` (a fit region's
        /// kept size, `ct_interop.setFit`), so the frame shows it without waiting for the next.
        /// The event of the frame stays `frame`'s; this one reports none.
        pub fn rebuild(ui: *Self, in: *const Input) Output {
            return ui.frameAs(true, in, &ui.frame_settings, .{}, {}) catch unreachable;
        }

        /// `frame` on a real shaper (`Frame.endText`, or `endTextStyled` when the page has
        /// styled labels): `text.stack` measures and wraps every label, and the page's
        /// paragraph styles, spans and decorations reach it through `text.rows` and
        /// `text.rects`, as a runtime page's `Ui.styled()` does. Styles that do not fit the
        /// rows are dropped (`stack.overflow`) and the labels drawn plain.
        // ponytail: no shaped `rebuild`; add one when a fit-region page runs on a real shaper.
        pub fn frameText(ui: *Self, in: *const Input, text: Shaped) Output {
            return ui.frameAs(false, in, &.{}, .{}, text) catch unreachable;
        }

        /// The frame, with labels measured by `ui.font` (`text` void) or by a `Shaped` stack.
        inline fn frameAs(ui: *Self, comptime replay: bool, in: *const Input, settings: *const @import("../a11y/settings_data.zig").Settings, presentation: @import("../style/locale.zig").Presentation, text: anytype) @import("../style/locale.zig").LayoutError!Output {
            const shaped = comptime @TypeOf(text) == Shaped;
            try presentation.rounding.validate();
            if (presentation.directions) |directions| try @import("../style/locale.zig").validateDirections(directions, rows);
            var event: ?E.Event = null;
            var next_input_mask = if (comptime has_input_availability) ui.previous_input_mask else {};
            _ = .{ &event, &next_input_mask }; // set only when the frame applies input
            if (!replay) {
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
                event = if (comptime has_input_availability)
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
                            if (active[@backingInt(w.?)] != 0 and ((comptime !has_input_availability) or ui.input_mask.allows(w.?))) {
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
                        // `steps_hidden`: a widget whose own region hides it (a tooltip's bubble)
                        // still steps, to decide when to show; it reads only other rows.
                        const hidden_ok = comptime @hasDecl(W_, "steps_hidden") and W_.steps_hidden;
                        if (!dynamic or hidden_ok or (active[row] != 0 and (!ui.built or ui.tree_rows[row] != types.none))) {
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
                next_input_mask = ui.refreshInputAvailability(in);
                if (comptime has_input_availability) {
                    if (ui.focus) |target| if (!ui.input_mask.allows(target)) {
                        ui.focus = null;
                    };
                }

                ui.springs.frame(&ui.signals.state, in.dt, !ui.built, settings.reduced_motion);
            }
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
            if (has_flex) {
                // Rows move between frames on a dynamic page: every row back to the defaults.
                for (0..tb.fx.c.aspect.len) |r| tb.fx.set(@intCast(r), &.{});
                // ponytail: Mono reports no ascent, so text baselines sit at the run's bottom
                // edge; call baseline.apply here when the font gives one.
                @memset(tb.fx.c.text_has, 0);
            }
            if (has_grid) tb.gs.reset();
            if (anchor_rows > 0) tb.an.reset();
            if (sticky_rows > 0) tb.st.reset();
            if (has_layers) tb.ly.l.reset();
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
            if (comptime paragraph_slots > 0) ui.paragraphs.len = 0;
            if (comptime Tokens != void) ui.seen = ui.tokens.generation;
            ui.push(spec, 0, &next, in);
            tb.t.seal(0);

            // `Frame.end`'s pass sequence.
            const t = &tb.t;
            const tx = &tb.tx;
            if (presentation.directions) |directions| {
                @import("../layout/rtl.zig").direction(t, directions);
                @import("../layout/rtl.zig").startEnd(t, directions);
            }
            const mono = if (comptime paragraph_slots > 0) @import("../text/protocol.zig").MonoParagraphsOf(.{ .spans = anySpans(spec), .decorations = decorates(spec) }){
                .mono = ui.font,
                .rows = ui.paragraphs.rows[0..ui.paragraphs.len],
                .styles = ui.paragraphs.styles[0..ui.paragraphs.len],
                .table = &paragraph_table,
                .decorations = if (comptime anyDecoration(spec)) &decoration_table else &.{},
                .spans = if (comptime anySpans(spec)) &span_table else &.{},
                .strings = tb.strings.buf[0..tb.strings.len],
            } else ui.font;
            if (shaped) {
                text.stack.overflow = false;
                if (comptime paragraph_slots > 0) text.stack.style(tx, mono.styled(), text.rows) catch {
                    text.stack.overflow = true;
                    text.stack.paragraphs = &.{};
                    text.stack.rich = &.{};
                };
            }
            const font = if (shaped) StackFont{ .stack = text.stack, .strings = &tb.strings, .ascent = text.ascent } else mono;
            font.measure(tx);
            layout.prepare(t);
            layout.applyText(t, tx, .x);
            if (has_grid) {
                // `grid.run`'s sequence, with the font's measure and wrap and, on a page with
                // flex rules too, `layout.runFlex`'s rules around the grids.
                const gs = &tb.gs;
                const fx = if (has_flex) &tb.fx else {};
                grid.autoPlace(gs);
                grid.fitWithOpts(t, gs, fx, .x, flex_opts);
                grid.resolveWith(t, gs, fx, .x, in.viewport[0]);
                if (has_flex) @import("../layout/wrap.zig").wrapOpts(t, fx, flex_opts);
                layout.textAvail(t, tx);
                font.wrap(tx);
                layout.applyText(t, tx, .y);
                grid.fitWithOpts(t, gs, fx, .y, flex_opts);
                grid.resolveWith(t, gs, fx, .y, in.viewport[1]);
                if (has_flex) layout.placeFlexOpts(t, fx, flex_opts) else layout.place(t);
            } else if (has_flex) {
                // `layout.runFlex`'s sequence.
                const fx = &tb.fx;
                layout.fitFlexOpts(t, fx, .x, flex_opts);
                layout.resolveFlex(t, fx, .x, in.viewport[0]);
                @import("../layout/wrap.zig").wrapOpts(t, fx, flex_opts);
                layout.textAvail(t, tx);
                font.wrap(tx);
                layout.applyText(t, tx, .y);
                layout.fitFlexOpts(t, fx, .y, flex_opts);
                layout.resolveFlex(t, fx, .y, in.viewport[1]);
                layout.placeFlexOpts(t, fx, flex_opts);
            } else {
                layout.fit(t, .x);
                layout.resolve(t, .x, in.viewport[0]);
                layout.textAvail(t, tx);
                font.wrap(tx);
                layout.applyText(t, tx, .y);
                layout.fit(t, .y);
                layout.resolve(t, .y, in.viewport[1]);
                layout.place(t);
            }
            if (shaped) tx.overflow = tx.overflow or text.stack.overflow;
            if (anchor_rows > 0) overlay.anchor(t, &tb.an, .{ .x1 = in.viewport[0], .y1 = in.viewport[1] });
            if (sticky_rows > 0) scroll_zig.stick(t, &tb.st);
            if (presentation.directions) |directions| @import("../layout/rtl.zig").mirror(t, directions);
            try layout.finalizeWith(t, presentation.rounding);
            if (has_layers) {
                overlay.order(t, &tb.ly.l);
                paint.emitLayered(t, tx, &tb.cu, tb.strings.buf[0..tb.strings.len], &tb.ly.l, &tb.d);
            } else paint.emit(t, tx, &tb.cu, tb.strings.buf[0..tb.strings.len], &tb.d);
            if (comptime paragraph_slots > 0) {
                if (shaped) text.stack.decorate(tx, &tb.strings, mono.styled(), &tb.d, text.rects) else mono.decorate(&tb.d, tx);
            }

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
            if (has_layers) {
                for (E.widget_nodes, tb.ly.rows) |node, *row| row.* = ui.treeRow(node);
                ui.rects.stack = .{ .tree = t, .layer = tb.ly.l.c.layer, .row = tb.ly.rows };
            }
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
            // The node's row is the next one pushed, whoever pushes it.
            const at = ui.tables.t.len;
            defer if (comptime n.flex) |fs| ui.tables.fx.set(at, &fs);
            // In row order, before the subtree: a nested anchor sees its parent's final place.
            if (comptime n.anchor) |pl| _ = ui.tables.an.place(at, pl, .{ .x1 = in.viewport[0], .y1 = in.viewport[1] });
            if (comptime n.sticky) |top| _ = ui.tables.st.push(at, @import("scroll.zig").scrollerOf(&ui.tables.t, parent), .{ 0, top }, .{ false, true });
            if (comptime n.layer != 0) ui.tables.ly.l.c.own[at] = n.layer;
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
                    const tokened = comptime Tokens != void and n.tokens.len > 0;
                    const tok = if (comptime tokened) ui.tokenStyles(n) else {};
                    const i = tb.t.push(parent, .none, if (comptime tokened) &tok.style else &n.style);
                    const span = if (comptime n.format) |f| blk: {
                        const segs = comptime fmt.compile(State, f.text, f.args);
                        var sink: fmt.Sink = .{ .buf = tb.strings.buf[tb.strings.len..] };
                        fmt.write(segs, f.text, fmt.Fields(State, f.args){ .state = state }, &sink);
                        const sp: @import("../core/strings.zig").Span = .{ .start = tb.strings.len, .bytes = @intCast(sink.len) };
                        tb.strings.len += sp.bytes;
                        tb.strings.overflow = simd.orB(tb.strings.overflow, sink.cut);
                        break :blk sp;
                    } else tb.strings.add(spec_zig.labelBytes(n, state));
                    tb.t.c.text[i] = tb.tx.push(i, span, if (comptime tokened) &tok.text else &(n.text_style orelse labelText(&th)));
                    if (comptime styledLabel(n)) {
                        const slot = &ui.paragraphs;
                        slot.rows[slot.len] = tb.t.c.text[i];
                        slot.styles[slot.len] = comptime paragraphIndex(paragraph_styles, n);
                        slot.len += 1;
                    }
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
                    if (comptime Tokens != void and n.tokens.len > 0) {
                        var unused: TextStyle = .{};
                        spec_zig.applyTokens(n.tokens, &s, &unused, &ui.tokens.values);
                    }
                    if (comptime n.region != null and n.region.?.window != null) {
                        for (Regions.regions, ui.window_selection) |region, sel| {
                            if (region.row == next.* - 1) s.scroll[1] = sel.offset;
                        }
                    }
                    // A container with an id is a button.
                    if (n.id != null) s.fill = buttonFill(&th, ui.response(next.* - 1, in));
                    const i = tb.t.push(parent, if (n.id) |name| .hash(name) else .none, &s);
                    if (comptime n.grid) |decl| {
                        comptime checkSubgrid(n);
                        const gs = &tb.gs;
                        const k = gs.declare(i, decl, comptime grid.implicitTracks(decl, spec_zig.gridItems(n)));
                        inline for (n.children) |c| {
                            // Placed before it is pushed: its row is the tree's next one.
                            if (!dynamic or ui.tree_rows[next.*] != types.none) _ = gs.place(k, tb.t.len, comptime c.cell orelse .{});
                            ui.push(c, i, next, in);
                        }
                    } else inline for (n.children) |c| ui.push(c, i, next, in);
                    tb.t.seal(i);
                },
            }
        }

        /// Names each live node of this frame that has an accessible name (`Spec.name`, set
        /// with `spec.named`) in `s` (`Semantics.label`), its bytes added to this frame's
        /// strings. A host with an accessibility bridge calls it after `frame`, between
        /// `Semantics.clear` and `a11y.names`, as an app's `semantics` writes what its runtime
        /// tree does not say. A spec without names writes nothing.
        pub fn semantics(ui: *Self, s: *a11y.Semantics) void {
            inline for (comptime namedRows(spec)) |row| {
                const r = ui.treeRow(row);
                if (r != types.none) s.c.label[r] = ui.tables.strings.add(comptime nodeAt(spec, row).name.?);
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

/// A label `MonoParagraphs` measures: one with a paragraph style, a decoration or spans.
fn styledLabel(comptime n: Spec) bool {
    return n.kind == .label and (n.paragraph != null or n.decoration != null or n.spans.len > 0);
}

/// A real shaper for `ComptimeUi.frameText`: the caller's stack, `ascent` scratch (a row per
/// label), and for a page with styled labels the rows `Stack.style` points the stack at and
/// `rects` scratch for `Stack.decorate` (at least the glyph rows), as `Frame.endTextStyled`.
pub const Shaped = struct {
    stack: *text_stack.Stack,
    ascent: []f32,
    rows: text_stack.StyledRows = .{ .paragraphs = &.{}, .rich = &.{}, .spans = &.{}, .start = &.{}, .font = &.{}, .px = &.{}, .color = &.{}, .metrics = &.{} },
    rects: []types.Rect = &.{},
};

/// A `Stack` as a font of the text protocol: `measure` and `wrap` as `Frame.arrangeText`
/// calls them.
const StackFont = struct {
    stack: *text_stack.Stack,
    strings: *const Strings,
    ascent: []f32,

    fn measure(f: StackFont, tx: *Texts) void {
        f.stack.measure(tx, f.strings, f.ascent);
    }

    fn wrap(f: StackFont, tx: *Texts) void {
        f.stack.wrap(tx, f.strings, f.ascent);
    }
};

/// Whether a label of `n` draws a decoration, its own or a span's: only then is
/// `MonoParagraphsOf.decorate` compiled in.
fn decorates(comptime n: Spec) bool {
    return comptime anyDecoration(n) or spanDecoration(n);
}

fn spanDecoration(comptime n: Spec) bool {
    if (n.kind == .label) for (n.spans) |sp| if (sp.decoration.underline or sp.decoration.overline or sp.decoration.strike) return true;
    for (n.children) |c| if (spanDecoration(c)) return true;
    return false;
}

fn anySpans(comptime n: Spec) bool {
    if (n.kind == .label and n.spans.len > 0) return true;
    for (n.children) |c| if (anySpans(c)) return true;
    return false;
}

/// Labels in `n` that `MonoParagraphs` measures.
fn paragraphCount(comptime n: Spec) u32 {
    var k: u32 = @intFromBool(styledLabel(n));
    for (n.children) |c| k += paragraphCount(c);
    return k;
}

fn anyDecoration(comptime n: Spec) bool {
    if (n.kind == .label and n.decoration != null) return true;
    for (n.children) |c| if (anyDecoration(c)) return true;
    return false;
}

const Decoration = @import("../text/layout/decorations.zig").Style;
const Span = @import("../text/protocol.zig").Span;
const ParagraphStyles = struct { paragraphs: []const Paragraph = &.{}, decorations: []const Decoration = &.{}, spans: []const []const Span = &.{} };

/// The distinct (paragraph, decoration, spans) of `n`'s styled labels, in first-use order.
fn paragraphDistinct(comptime n: Spec) ParagraphStyles {
    comptime {
        var out: ParagraphStyles = .{};
        paragraphWalk(n, &out);
        return out;
    }
}

fn paragraphWalk(comptime n: Spec, comptime out: *ParagraphStyles) void {
    if (styledLabel(n)) {
        if (paragraphIndexIn(out.*, n) == null) {
            out.paragraphs = out.paragraphs ++ .{n.paragraph orelse Paragraph{}};
            out.decorations = out.decorations ++ .{n.decoration orelse Decoration{}};
            out.spans = out.spans ++ .{n.spans};
        }
    }
    for (n.children) |c| paragraphWalk(c, out);
}

fn spansEql(comptime a: []const Span, comptime b: []const Span) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| if (!std.meta.eql(x, y)) return false;
    return true;
}

fn paragraphIndex(comptime styles: ParagraphStyles, comptime n: Spec) u16 {
    return paragraphIndexIn(styles, n).?;
}

fn paragraphIndexIn(comptime styles: ParagraphStyles, comptime n: Spec) ?u16 {
    const p = n.paragraph orelse Paragraph{};
    const d = n.decoration orelse Decoration{};
    for (styles.paragraphs, styles.decorations, styles.spans, 0..) |q, e, sp, i| if (std.meta.eql(q, p) and std.meta.eql(e, d) and spansEql(sp, n.spans)) return i;
    return null;
}

/// Whether a node of `n` is a baseline-aligned wrapping row (`FlexOptions.line_baseline`).
fn anyLineBaseline(comptime n: Spec) bool {
    if (n.flex) |f| if (f.wrap and f.baseline) return true;
    for (n.children) |c| if (anyLineBaseline(c)) return true;
    return false;
}

/// The grid rows, track rows, item rows and auto-placement cells `n`'s subtree needs, every
/// grid at its most implicit tracks; zero grids when it has none.
fn gridCapacity(comptime n: Spec) grid.Grids.Capacity {
    comptime {
        var cap: grid.Grids.Capacity = .{ .grids = 0, .tracks = 0, .items = 0, .cells = 1 };
        if (n.grid) |decl| {
            const extra = grid.implicitTracks(decl, spec_zig.gridItems(n));
            var count: [2]u32 = .{ if (decl.repeat) |r| r.max else @max(decl.columns.len, 1), @max(decl.rows.len, 1) };
            count[decl.growAxis()] = @max(count[decl.growAxis()], @as(u32, if (decl.growAxis() == 0) decl.columns.len else decl.rows.len) + extra);
            cap = .{ .grids = 1, .tracks = count[0] + count[1], .items = n.children.len, .cells = count[0] * count[1] };
        }
        for (n.children) |c| {
            const sub = gridCapacity(c);
            cap = .{ .grids = cap.grids + sub.grids, .tracks = cap.tracks + sub.tracks, .items = cap.items + sub.items, .cells = @max(cap.cells, sub.cells) };
        }
        return cap;
    }
}

/// How many nodes of `n`'s subtree set `field` (`anchor`, `sticky`) or a nonzero `layer`.
fn countPositioned(comptime n: Spec, comptime field: enum { anchor, sticky, layer }) u32 {
    comptime {
        var k: u32 = switch (field) {
            .anchor => @intFromBool(n.anchor != null),
            .sticky => @intFromBool(n.sticky != null),
            .layer => @intFromBool(n.layer != 0),
        };
        for (n.children) |c| k += countPositioned(c, field);
        return k;
    }
}

/// A `Decl.subgrid` axis needs the node placed at an explicit cell spanning as many tracks as
/// it has (`grid.Grids.shareAxis`).
fn checkSubgrid(comptime n: Spec) void {
    const d = n.grid.?;
    inline for (0..2) |a| if (d.subgrid[a]) {
        const it = n.cell orelse @compileError("a subgrid needs spec.cell with an explicit cell");
        if (it.cell == null) @compileError("a subgrid needs spec.cell with an explicit cell");
        const count = if (a == 0) d.columns.len else d.rows.len;
        if (it.span[a] != count) @compileError("a subgrid needs as many tracks as the cells it spans");
    };
}

fn anyFlex(comptime n: Spec) bool {
    if (n.flex != null) return true;
    for (n.children) |c| if (anyFlex(c)) return true;
    return false;
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

/// Spec rows (depth first) of the nodes with an accessible name.
fn namedRows(comptime n: Spec) []const u32 {
    comptime {
        var rows: []const u32 = &.{};
        var i: u32 = 0;
        namedWalk(n, &i, &rows);
        const out = rows[0..rows.len].*;
        return &out;
    }
}

fn namedWalk(comptime n: Spec, comptime next: *u32, comptime rows: *[]const u32) void {
    if (n.name != null) rows.* = rows.* ++ .{next.*};
    next.* += 1;
    for (n.children) |c| namedWalk(c, next, rows);
}

/// Whether a widget of `n` (itself included) decides its own input (`inputAvailability`).
fn gatesInput(comptime n: Spec) bool {
    if (n.id != null and n.widget != null and @hasDecl(n.widget.?, "inputAvailability")) return true;
    for (n.children) |c| if (gatesInput(c)) return true;
    return false;
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
        // The walk visits every row before `row`: a page of a few dozen widgets passed the
        // default quota of 1000 backward branches.
        @setEvalBranchQuota(10_000 + 100 * row);
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
/// runtime side: plain data with defaults and `pub fn build(*App, *Frame) void`, and optionally
/// `pub fn end(*App, *Frame, Mono) context.Output` to end the frame itself (`Frame.endFlex`
/// over flex columns the App owns); otherwise the harness calls `Frame.end`. Likewise an
/// optional `pub fn begin(*App, *context.Context, *const Input) Frame` starts it (a hit in
/// layer order, `Context.beginWithHit`). `Ui` is the
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
            var f = if (@hasDecl(App, "begin")) h.app.begin(&h.ctx, in) else h.ctx.begin(in);
            h.app.build(&f);
            const rt = if (@hasDecl(App, "end")) h.app.end(&f, h.ui.font) else f.end(h.ui.font);
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
            for (&p.s) |*s| s.clear();
            // What each tree does not say itself: the runtime app's `semantics`, if it has
            // one, and the comptime page's names.
            if (@hasDecl(@TypeOf(h.app), "semantics")) h.app.semantics(trees[0], &p.s[0], &ctx.strings[ctx.cur]);
            if (@hasDecl(@TypeOf(h.ui), "semantics")) h.ui.semantics(&p.s[1]);
            x.strings = .{ ctx.strings[ctx.cur].buf[0..ctx.strings[ctx.cur].len], tb.strings.buf[0..tb.strings.len] };
            for (0..2) |k| {
                std.debug.assert(trees[k].len <= cap);
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

test "ComptimeUi.semantics: a named node's accessible name reaches the a11y export" {
    const sp = spec_zig.col(.{}, .{spec_zig.named(spec_zig.landmark(.navigation, .{}, .{}), "Primary")});
    const U = ComptimeUi(struct {}, sp, .{});
    const ui = &struct {
        var v: U = .{};
    }.v;
    const in: Input = .{};
    const out = ui.frame(&in);
    var buf: [1 << 14]u8 align(mem.column_align) = undefined;
    var carver: mem.Carver = .{ .buf = &buf };
    var s = a11y.Semantics.init(&carver, 8);
    var ex = a11y.Export.init(&carver, 8);
    s.clear();
    ui.semantics(&s);
    a11y.names(out.tree, &s);
    a11y.states(out.tree, &s);
    const tb = &ui.tables;
    a11y.flatten(out.tree, &tb.tx, tb.strings.buf[0..tb.strings.len], &s, &ex);
    const r = for (0..ex.len) |r| {
        if (ex.c.role[r] == @backingInt(a11y.Role.navigation)) break r;
    } else return error.NoNavigation;
    try testing.expectEqualStrings("Primary", tb.strings.buf[ex.c.name_start[r]..][0..ex.c.name_bytes[r]]);
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

test "fitRegion: the comptime layout gives a region the size its owner last measured" {
    const interop = @import("../comptime/interop.zig");
    const page = comptime spec_zig.col(.{}, .{
        interop.fitRegion(.menu, .{ .size = .{ .fit, .px(20) } }),
        spec_zig.label("after"),
    });
    const S = struct {
        var ui: ComptimeUi(struct {}, page, .default) = .{};
    };
    const in: Input = .{};
    var t = S.ui.frame(&in).tree;
    // root, col, region, label
    try testing.expectEqual(0, t.rect(2).x1 - t.rect(2).x0);
    try testing.expect(interop.setFit(&S.ui, .menu, .{ 50, 30 }));
    try testing.expect(!interop.setFit(&S.ui, .menu, .{ 50, 30 }));
    t = S.ui.frame(&in).tree;
    // Width from the measure; height stays the style's px.
    try testing.expectEqual(50, t.rect(2).x1 - t.rect(2).x0);
    try testing.expectEqual(20, t.rect(2).y1 - t.rect(2).y0);
    try testing.expectEqual(20, t.rect(3).y0 - t.rect(2).y0);
    try testing.expectEqual(1, S.ui.frame(&in).draw.custom_len);
}

test "ComptimeUi.rebuild: a grid page with side tables lays out again around a measured region" {
    const interop = @import("../comptime/interop.zig");
    // A fit column holding a fit region and a label anchored to its right edge, then a
    // fraction column, in a 200 px grid.
    const page = comptime spec_zig.grid(.{ .size = .{ .px(200), .fit } }, .{ .columns = &.{ .fit, .fr(1) }, .gap = .{ 4, 0 } }, .{
        spec_zig.col(.{}, .{
            interop.fitRegion(.menu, .{ .size = .{ .fit, .px(20) } }),
            spec_zig.layer(spec_zig.anchored(spec_zig.styled(spec_zig.label("n"), .{ .float = true }), .{ .at = .top_right, .pivot = .top_right }), 1),
        }),
        spec_zig.label("b"),
    });
    const S = struct {
        var ui: ComptimeUi(struct {}, page, .default) = .{};
    };
    const in: Input = .{};
    _ = S.ui.frame(&in);
    try testing.expect(interop.setFit(&S.ui, .menu, .{ 50, 30 }));
    const again = S.ui.rebuild(&in).tree;
    // root, grid, col, region, anchored label, label
    try testing.expectEqual(50, again.rect(2).x1 - again.rect(2).x0);
    try testing.expectEqual(50, again.rect(4).x1);
    try testing.expectEqual(54, again.rect(5).x0);
    // The next frame lays the page out as the rebuild did.
    const next = S.ui.frame(&in).tree;
    for (0..6) |row| try testing.expectEqual(again.rect(@intCast(row)), next.rect(@intCast(row)));
}

test "ComptimeUi: a baseline-aligned wrapping row in a grid cell takes a baseline per line" {
    const big = spec_zig.textStyled(spec_zig.label("Big"), .{ .px = 24 });
    const row = comptime spec_zig.flexed(spec_zig.row(.{ .size = .{ .px(90), .fit } }, .{ big, spec_zig.label("small"), spec_zig.label("next") }), .{ .wrap = true, .baseline = true });
    const S = struct {
        var flex: ComptimeUi(struct {}, spec_zig.col(.{}, .{row}), .default) = .{};
        var grid: ComptimeUi(struct {}, spec_zig.grid(.{}, .{ .columns = &.{.px(90)} }, .{row}), .default) = .{};
    };
    const in: Input = .{};
    const a = S.flex.frame(&in).tree;
    const b = S.grid.frame(&in).tree;
    // root, col or grid, row, Big, small, next: the labels sit in the row as on a flex page.
    for (3..6) |r| {
        const ra = a.rect(@intCast(r));
        const rb = b.rect(@intCast(r));
        try testing.expectEqual(ra.x0 - a.rect(2).x0, rb.x0 - b.rect(2).x0);
        try testing.expectEqual(ra.y0 - a.rect(2).y0, rb.y0 - b.rect(2).y0);
    }
    // "Big" and "small" share the first line on one baseline (bottom edges, Mono has no
    // ascent), and "next" wrapped to a second line.
    try testing.expectEqual(b.rect(3).y1, b.rect(4).y1);
    try testing.expect(b.rect(4).y0 > b.rect(3).y0);
    try testing.expect(b.rect(5).y0 >= b.rect(3).y1);
}

test "ComptimeUiTokens: rows read the token table when pushed; a change lays out again" {
    const Tokens = struct { space: f32 = 4, size: f32 = 14, ink: Color = .rgb(1, 2, 3) };
    const page = comptime spec_zig.col(.{}, .{
        spec_zig.tokened(spec_zig.col(.{ .pad = @splat(4) }, .{
            spec_zig.tokened(spec_zig.label("A"), &.{ .{ .target = .text_px, .token = "size" }, .{ .target = .text_color, .token = "ink" } }),
        }), &.{ .{ .target = .pad_top, .token = "space" }, .{ .target = .pad_left, .token = "space" } }),
    });
    const UiT = ComptimeUiTokens(struct {}, page, theme, Tokens);
    const S = struct {
        var ui: UiT = .{};
        var table: @import("../theme/table.zig").ThemeTable(Tokens) = .{};
    };
    S.ui.tokens = &S.table;
    const in: Input = .{};
    var t = S.ui.frame(&in).tree;
    // root, page col, tokened col, label
    try testing.expectEqual(4, t.rect(3).x0 - t.rect(2).x0);
    const h0 = t.rect(3).y1 - t.rect(3).y0;
    try testing.expect(!S.ui.themeChanged());
    S.table.set(.space, 10);
    S.table.set(.size, 28);
    try testing.expect(S.ui.themeChanged());
    t = S.ui.frame(&in).tree;
    try testing.expect(!S.ui.themeChanged());
    try testing.expectEqual(10, t.rect(3).x0 - t.rect(2).x0);
    try testing.expectEqual(10, t.rect(3).y0 - t.rect(2).y0);
    try testing.expect(t.rect(3).y1 - t.rect(3).y0 > h0);
    // A page without tokens has no token field.
    try testing.expectEqual(void, @FieldType(ComptimeUi(struct {}, page, theme), "tokens"));
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

test "flexed: margins, wrap and align-self lay out the same in both front ends" {
    const th: Theme = .default;
    const box: Style = comptime .{ .size = .{ .px(70), .px(20) }, .fill = .rgb(200, 0, 0) };
    const spec = comptime spec_zig.col(.{}, .{
        spec_zig.flexed(spec_zig.row(.{ .gap = 4, .size = .{ .px(160), .fit } }, .{
            spec_zig.flexed(spec_zig.styled(spec_zig.row(.{}, .{}), box), .{ .margin = .{ 6, 2, 6, 2 } }),
            spec_zig.styled(spec_zig.row(.{}, .{}), box),
            spec_zig.flexed(spec_zig.styled(spec_zig.row(.{}, .{}), box), .{ .cross = .end }),
        }), .{ .wrap = true }),
        spec_zig.flexed(spec_zig.label("A"), .{ .margin = .{ 10, 3, 0, 0 } }),
    });
    const Ui = ComptimeUi(struct {}, spec, th);
    const App = struct {
        buf: [32 * 1024]u8 align(mem.column_align) = undefined,
        fx: ?Flex = null,
        pub fn build(app: *@This(), f: *Frame) void {
            if (app.fx == null) {
                var c: mem.Carver = .{ .buf = &app.buf };
                app.fx = Flex.init(&c, 16);
            }
            const fx = &app.fx.?;
            var b = box;
            b.dir = .x;
            _ = f.open(.none, .{});
            const r = f.open(.none, .{ .dir = .x, .gap = 4, .size = .{ .px(160), .fit } });
            fx.set(@backingInt(r), &.{ .wrap = true });
            fx.set(@backingInt(f.leaf(.none, b)), &.{ .margin = .{ 6, 2, 6, 2 } });
            _ = f.leaf(.none, b);
            fx.set(@backingInt(f.leaf(.none, b)), &.{ .cross = .end });
            f.close();
            fx.set(@backingInt(f.textStyled("A", labelText(&th), .{})), &.{ .margin = .{ 10, 3, 0, 0 } });
            f.close();
        }
        pub fn end(app: *@This(), f: *Frame, font: Mono) context.Output {
            return f.endFlex(font, &app.fx.?);
        }
    };
    var h: Harness(App, Ui, .{ .nodes = 16, .texts = 4, .strings = 64, .depth = 8 }) = undefined;
    h.init();
    const in: Input = .{ .viewport = .{ 320, 180 } };
    for (0..2) |_| {
        const out = (try h.frame(&in)).comptime_.tree;
        // Root, col, row, then the three boxes: the first past its margins, the third wrapped.
        try std.testing.expectEqual(types.Rect{ .x0 = 6, .y0 = 2, .x1 = 76, .y1 = 22 }, out.rect(3));
        try std.testing.expectEqual(@as(f32, 86), out.rect(4).x0);
        try std.testing.expect(out.rect(5).y0 >= 24);
        try std.testing.expectEqual(@as(f32, 10), out.rect(6).x0);
    }
}

test "grid and flex on one page: margins inside a cell and beside the grid, in both front ends" {
    const th: Theme = .default;
    const box: Style = comptime .{ .size = .{ .px(30), .px(20) }, .fill = .rgb(200, 0, 0) };
    const decl: grid.Decl = comptime .{ .columns = &.{ .px(80), .fit }, .gap = .{ 4, 0 } };
    const spec = comptime spec_zig.col(.{}, .{
        spec_zig.flexed(spec_zig.grid(.{}, decl, .{
            spec_zig.row(.{}, .{spec_zig.flexed(spec_zig.styled(spec_zig.row(.{}, .{}), box), .{ .margin = .{ 5, 3, 0, 0 } })}),
            spec_zig.styled(spec_zig.row(.{}, .{}), box),
        }), .{ .margin = .{ 10, 6, 0, 0 } }),
        spec_zig.flexed(spec_zig.label("after"), .{ .margin = .{ 2, 2, 0, 0 } }),
    });
    const Ui = ComptimeUi(struct {}, spec, th);
    const App = struct {
        buf: [48 * 1024]u8 align(mem.column_align) = undefined,
        gs: grid.Grids = undefined,
        fx: ?Flex = null,
        pub fn build(app: *@This(), f: *Frame) void {
            if (app.fx == null) {
                var c: mem.Carver = .{ .buf = &app.buf };
                app.fx = Flex.init(&c, 16);
                app.gs = grid.Grids.init(&c, .{ .grids = 1, .tracks = 4, .items = 2, .cells = 4 });
            }
            const fx = &app.fx.?;
            var b = box;
            b.dir = .x;
            var fb = b;
            fb.float = true;
            _ = f.open(.none, .{});
            const g = f.open(.none, .{});
            fx.set(@backingInt(g), &.{ .margin = .{ 10, 6, 0, 0 } });
            const k = app.gs.declare(@backingInt(g), decl, grid.implicitTracks(decl, &.{ .{}, .{} }));
            _ = app.gs.place(k, @intCast(f.tree().len), .{});
            _ = f.open(.none, .{ .dir = .x, .float = true });
            fx.set(@backingInt(f.leaf(.none, b)), &.{ .margin = .{ 5, 3, 0, 0 } });
            f.close();
            _ = app.gs.place(k, @intCast(f.tree().len), .{});
            _ = f.leaf(.none, fb);
            f.close();
            fx.set(@backingInt(f.textStyled("after", labelText(&th), .{})), &.{ .margin = .{ 2, 2, 0, 0 } });
            f.close();
        }
        pub fn end(app: *@This(), f: *Frame, font: Mono) context.Output {
            return f.endSides(font, .{ .grids = &app.gs, .flex = &app.fx.? });
        }
    };
    var h: Harness(App, Ui, .{ .nodes = 16, .texts = 4, .strings = 64, .depth = 8 }) = undefined;
    h.init();
    const in: Input = .{ .viewport = .{ 320, 180 } };
    for (0..2) |_| {
        const out = (try h.frame(&in)).comptime_.tree;
        // Root, col, grid (10, 6), cell 0 { box past its margin }, cell 1, after.
        try std.testing.expectEqual(@as(f32, 10), out.rect(2).x0);
        try std.testing.expectEqual(types.Rect{ .x0 = 15, .y0 = 9, .x1 = 45, .y1 = 29 }, out.rect(4));
        try std.testing.expectEqual(@as(f32, 94), out.rect(5).x0);
        try std.testing.expectEqual(@as(f32, 2), out.rect(6).x0);
    }
}

test "grid: tracks, spans, placed cells and implicit rows lay out the same in both front ends" {
    const th: Theme = .default;
    const box: Style = comptime .{ .size = .{ .fit, .px(20) }, .fill = .rgb(200, 0, 0) };
    const decl: grid.Decl = comptime .{ .columns = &.{ .px(60), .fr(1) }, .gap = .{ 4, 2 }, .justify = .{ .stretch, .start } };
    const spec = comptime spec_zig.col(.{}, .{
        spec_zig.grid(.{ .size = .{ .px(200), .fit }, .pad = @splat(3) }, decl, .{
            spec_zig.label("A"),
            spec_zig.styled(spec_zig.row(.{}, .{}), box),
            spec_zig.cell(spec_zig.styled(spec_zig.row(.{}, .{}), box), .{ .span = .{ 2, 1 } }),
            spec_zig.cell(spec_zig.label("B"), .{ .cell = .{ 1, 3 } }),
        }),
        spec_zig.label("after"),
    });
    const Ui = ComptimeUi(struct {}, spec, th);
    const App = struct {
        buf: [32 * 1024]u8 align(mem.column_align) = undefined,
        gs: ?grid.Grids = null,
        pub fn build(app: *@This(), f: *Frame) void {
            if (app.gs == null) {
                var c: mem.Carver = .{ .buf = &app.buf };
                app.gs = grid.Grids.init(&c, .{ .grids = 1, .tracks = 9, .items = 4, .cells = 14 });
            }
            const gs = &app.gs.?;
            var b = box;
            b.dir = .x;
            b.float = true;
            const items = [_]grid.Item{ .{}, .{}, .{ .span = .{ 2, 1 } }, .{ .cell = .{ 1, 3 } } };
            _ = f.open(.none, .{});
            const g = f.open(.none, .{ .size = .{ .px(200), .fit }, .pad = @splat(3) });
            const k = gs.declare(@backingInt(g), decl, grid.implicitTracks(decl, &items));
            _ = gs.place(k, @intCast(f.tree().len), items[0]);
            _ = f.textStyled("A", labelText(&th), .{ .float = true });
            _ = gs.place(k, @intCast(f.tree().len), items[1]);
            _ = f.leaf(.none, b);
            _ = gs.place(k, @intCast(f.tree().len), items[2]);
            _ = f.leaf(.none, b);
            _ = gs.place(k, @intCast(f.tree().len), items[3]);
            _ = f.textStyled("B", labelText(&th), .{ .float = true });
            f.close();
            _ = f.textStyled("after", labelText(&th), .{});
            f.close();
        }
        pub fn end(app: *@This(), f: *Frame, font: Mono) context.Output {
            return f.endGrid(font, &app.gs.?);
        }
    };
    var h: Harness(App, Ui, .{ .nodes = 16, .texts = 4, .strings = 64, .depth = 8 }) = undefined;
    h.init();
    const in: Input = .{ .viewport = .{ 320, 180 } };
    for (0..2) |_| {
        const out = (try h.frame(&in)).comptime_.tree;
        // Root, col, grid, then A, the box, the spanning box, B, after.
        try std.testing.expectEqual(@as(f32, 3), out.rect(3).x0);
        try std.testing.expectEqual(types.Rect{ .x0 = 67, .y0 = 3, .x1 = 197, .y1 = 23 }, out.rect(4));
        try std.testing.expectEqual(types.Rect{ .x0 = 3, .y0 = 25, .x1 = 197, .y1 = 45 }, out.rect(5));
        try std.testing.expectEqual(@as(f32, 67), out.rect(6).x0);
        try std.testing.expect(out.rect(7).y0 >= out.rect(6).y1);
    }
}

test "anchored, sticky, layer: placed and painted the same in both front ends" {
    const th: Theme = .default;
    const box: Style = comptime .{ .size = .{ .px(100), .px(60) }, .pad = @splat(4), .fill = .rgb(0, 0, 200) };
    const dot: Style = comptime .{ .size = .{ .px(10), .px(10) }, .float = true, .fill = .rgb(200, 0, 0) };
    const corner: overlay.Place = comptime .{ .at = .bottom_right, .pivot = .bottom_right, .offset = .{ -2, -3 } };
    const fixed: overlay.Place = comptime .{ .at = .top_right, .pivot = .top_right, .offset = .{ -5, 5 }, .viewport = true };
    const spec = comptime spec_zig.col(.{}, .{
        spec_zig.layer(spec_zig.styled(spec_zig.row(.{}, .{
            spec_zig.anchored(spec_zig.styled(spec_zig.row(.{}, .{}), dot), corner),
            spec_zig.anchored(spec_zig.styled(spec_zig.row(.{}, .{}), dot), fixed),
        }), box), 2),
        spec_zig.sticky(spec_zig.label("stuck"), 70),
        spec_zig.styled(spec_zig.row(.{}, .{}), .{ .size = .{ .px(40), .px(40) }, .fill = .rgb(0, 200, 0) }),
    });
    const Ui = ComptimeUi(struct {}, spec, th);
    const App = struct {
        buf: [16 * 1024]u8 align(mem.column_align) = undefined,
        an: ?overlay.Anchors = null,
        st: scroll_zig.Sticky = undefined,
        ly: overlay.Layers = undefined,
        pub fn build(app: *@This(), f: *Frame) void {
            if (app.an == null) {
                var c: mem.Carver = .{ .buf = &app.buf };
                app.an = overlay.Anchors.init(&c, 2);
                app.st = scroll_zig.Sticky.init(&c, 1);
                app.ly = overlay.Layers.init(&c, 16);
                app.ly.reset();
            }
            const vp: types.Rect = .{ .x1 = f.in.viewport[0], .y1 = f.in.viewport[1] };
            var d = dot;
            d.dir = .x;
            var b = box;
            b.dir = .x;
            _ = f.open(.none, .{});
            const raised = f.open(.none, b);
            app.ly.c.own[@backingInt(raised)] = 2;
            _ = app.an.?.place(@backingInt(f.leaf(.none, d)), corner, vp);
            _ = app.an.?.place(@backingInt(f.leaf(.none, d)), fixed, vp);
            f.close();
            _ = app.st.push(@backingInt(f.textStyled("stuck", labelText(&th), .{})), 0, .{ 0, 70 }, .{ false, true });
            _ = f.leaf(.none, .{ .dir = .x, .size = .{ .px(40), .px(40) }, .fill = .rgb(0, 200, 0) });
            f.close();
        }
        pub fn end(app: *@This(), f: *Frame, font: Mono) context.Output {
            return f.endSides(font, .{ .anchors = &app.an.?, .sticky = &app.st, .layers = &app.ly });
        }
    };
    var h: Harness(App, Ui, .{ .nodes = 16, .texts = 4, .strings = 64, .depth = 8 }) = undefined;
    h.init();
    const in: Input = .{ .viewport = .{ 320, 180 } };
    for (0..2) |_| {
        const out = (try h.frame(&in)).comptime_.tree;
        // Root, col, box, the two dots, the sticky label, the green box.
        try std.testing.expectEqual(types.Rect{ .x0 = 84, .y0 = 43, .x1 = 94, .y1 = 53 }, out.rect(3));
        try std.testing.expectEqual(types.Rect{ .x0 = 305, .y0 = 5, .x1 = 315, .y1 = 15 }, out.rect(4));
        try std.testing.expectEqual(@as(f32, 70), out.rect(5).y0);
    }
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

test "paragraph: line height, spacing and an ellipsis lay out the same in both front ends" {
    const th: Theme = .default;
    const tall: Paragraph = .{ .line_height = .{ .px = 30 }, .letter_spacing = 2 };
    const cut: Paragraph = .{ .ellipsis = true };
    const spec = comptime spec_zig.col(.{ .size = .{ .px(60), .fit } }, .{
        spec_zig.paragraph(spec_zig.label("Tall"), tall),
        spec_zig.label("Plain"),
        spec_zig.paragraph(spec_zig.styled(spec_zig.label("a long line cut short"), .{ .size = .{ .fill, .fit }, .clip = true, .role = .label }), cut),
        spec_zig.paragraph(spec_zig.label("Tall"), tall),
    });
    const Ui = ComptimeUi(struct {}, spec, th);
    const App = struct {
        rows: [3]u32 = undefined,
        const table = [_]Paragraph{ tall, cut };
        pub fn build(app: *@This(), f: *Frame) void {
            _ = f.open(.none, .{ .size = .{ .px(60), .fit } });
            _ = f.textStyled("Tall", labelText(&th), .{});
            app.rows[0] = f.texts().len - 1;
            _ = f.textStyled("Plain", labelText(&th), .{});
            _ = f.textStyled("a long line cut short", labelText(&th), .{ .size = .{ .fill, .fit }, .clip = true, .role = .label });
            app.rows[1] = f.texts().len - 1;
            _ = f.textStyled("Tall", labelText(&th), .{});
            app.rows[2] = f.texts().len - 1;
            f.close();
        }
        pub fn end(app: *@This(), f: *Frame, font: Mono) context.Output {
            return f.endParagraphs(@import("../text/protocol.zig").MonoParagraphs{ .mono = font, .rows = &app.rows, .styles = &.{ 0, 1, 0 }, .table = &table });
        }
    };
    var h: Harness(App, Ui, .{ .nodes = 16, .texts = 8, .strings = 128, .depth = 8 }) = undefined;
    h.init();
    const in: Input = .{ .viewport = .{ 320, 180 } };
    const out = (try h.frame(&in)).comptime_.tree;
    // 4 bytes of 8.4 + 2 px (snapped to whole pixels), one 30 px line; the plain label keeps
    // Mono's line.
    const adv = th.text_px * (Mono{}).advance;
    try std.testing.expectApproxEqAbs(4 * (adv + 2), out.rect(2).w(), 1);
    try std.testing.expectEqual(@as(f32, 30), out.rect(2).h());
    try std.testing.expectApproxEqAbs(th.text_px * (Mono{}).line, out.rect(3).h(), 1);
    // The ellipsis run is cut to the column's 60 px.
    try std.testing.expectEqual(@as(f32, 60), out.rect(4).w());
}

test "decorated: one bar per line, painted right after its run, in both front ends" {
    const th: Theme = .default;
    const under: @import("../text/layout/decorations.zig").Style = .{ .underline = true, .color = 0xff0000ff };
    const wrapping: TextStyle = .{ .px = th.text_px, .color = th.text, .wrap = true };
    const spec = comptime spec_zig.col(.{ .size = .{ .px(60), .fit } }, .{
        spec_zig.decorated(spec_zig.textStyled(spec_zig.styled(spec_zig.label("twelve bytes"), .{ .shrink = true }), wrapping), under),
    });
    const Ui = ComptimeUi(struct {}, spec, th);
    const App = struct {
        rows: [1]u32 = undefined,
        pub fn build(app: *@This(), f: *Frame) void {
            _ = f.open(.none, .{ .size = .{ .px(60), .fit } });
            _ = f.textStyled("twelve bytes", wrapping, .{ .shrink = true });
            app.rows[0] = f.texts().len - 1;
            f.close();
        }
        pub fn end(app: *@This(), f: *Frame, font: Mono) context.Output {
            return f.endParagraphs(@import("../text/protocol.zig").MonoParagraphs{ .mono = font, .rows = &app.rows, .styles = &.{0}, .table = &.{.{}}, .decorations = &.{under} });
        }
    };
    var h: Harness(App, Ui, .{ .nodes = 8, .texts = 2, .strings = 64, .depth = 4 }) = undefined;
    h.init();
    const in: Input = .{ .viewport = .{ 320, 180 } };
    const d = (try h.frame(&in)).comptime_.draw;
    // 60 px holds 7 bytes of 8.4: "twelve " and "bytes", two bars of 7 and 5 bytes.
    const adv = th.text_px * (Mono{}).advance;
    var bars: [2][4]f32 = undefined;
    var n: usize = 0;
    for (d.quads[0..d.quad_len]) |q| if (q.fill == 0xff0000ff) {
        bars[n] = q.rect;
        n += 1;
    };
    try std.testing.expectEqual(2, n);
    try std.testing.expectApproxEqAbs(7 * adv, bars[0][2] - bars[0][0], 0.01);
    try std.testing.expectApproxEqAbs(5 * adv, bars[1][2] - bars[1][0], 0.01);
    try std.testing.expect(bars[1][1] > bars[0][1]);
    // The text command, then the bars' quads command.
    var text_at: ?usize = null;
    for (0..d.cmd_len) |i| switch (d.command(@intCast(i))) {
        .text => text_at = i,
        .quads => |b| if (text_at) |t| {
            try std.testing.expectEqual(t + 1, i);
            try std.testing.expectEqual(2, b.count);
        },
        else => {},
    };
    try std.testing.expect(text_at != null);
}

test "frameText: styled labels on a real shaper lay out and draw the same in both front ends" {
    const protocol = @import("../text/protocol.zig");
    const golden = @import("../text/layout/golden.zig");
    const shape = @import("../text/shape/shape.zig");
    const lines = @import("../text/layout/lines.zig");
    const span_rows = @import("../text/layout/spans.zig");
    const th: Theme = .default;
    const tall: Paragraph = .{ .line_height = .{ .px = 30 } };
    const under: @import("../text/layout/decorations.zig").Style = .{ .underline = true };
    const big = comptime [_]protocol.Span{.{ .start = 2, .style = .{ .px = 40, .color = .rgb(255, 0, 0) }, .decoration = .{ .strike = true } }};
    const spec = comptime spec_zig.col(.{}, .{
        spec_zig.paragraph(spec_zig.label("AVTa"), tall),
        spec_zig.decorated(spec_zig.spans(spec_zig.label("AVTa"), &big), under),
    });
    const Ui = ComptimeUi(struct {}, spec, th);
    const face = try @import("../text/font/opentype.zig").Face.parse(golden.font, 0);
    const shapers = [_]shape.Shaper{.init(face)};
    var para: golden.Para = .{};
    para.bind();
    var cols: golden.RunCols = .{};
    var stack: text_stack.Stack = .{ .shapers = &shapers, .run = cols.run(), .g = para.g, .l = para.l };
    var ascent: [4]f32 = undefined;
    var p_rows: [4]Paragraph = undefined;
    var rich: [4]?text_stack.Rich = undefined;
    var sp: [2]span_rows.Spans = undefined;
    var start: [8]u32 = undefined;
    var font: [8]u16 = undefined;
    var px: [8]f32 = undefined;
    var color: [8]u32 = undefined;
    var metrics: [8]lines.Metrics = undefined;
    var rects: [64]types.Rect = undefined;
    const rows: text_stack.StyledRows = .{ .paragraphs = &p_rows, .rich = &rich, .spans = &sp, .start = &start, .font = &font, .px = &px, .color = &color, .metrics = &metrics };
    const in: Input = .{ .viewport = .{ 300, 200 } };

    const caps: context.Limits = .{ .nodes = 8, .texts = 4, .strings = 64, .depth = 4 };
    var buf: [context.Context.requiredBytes(caps)]u8 align(mem.column_align) = undefined;
    var ctx = try context.Context.init(&buf, caps);
    var f = ctx.begin(&in);
    _ = f.open(.none, .{});
    _ = f.textStyled("AVTa", labelText(&th), .{});
    _ = f.textStyled("AVTa", labelText(&th), .{});
    f.close();
    const styled: protocol.Styled = .{ .rows = &.{ 0, 1 }, .styles = &.{ 0, 1 }, .table = &.{ tall, .{} }, .decorations = &.{ .{}, under }, .spans = &.{ &.{}, &big } };
    const rt = f.endTextStyled(&stack, &ascent, styled, rows, &rects);
    try std.testing.expect(!stack.overflow);

    var ui: Ui = .{};
    const cp = ui.frameText(&in, .{ .stack = &stack, .ascent = &ascent, .rows = rows, .rects = &rects });
    try std.testing.expect(!stack.overflow);
    try std.testing.expect(sameDraw(rt.draw, cp.draw));
    try std.testing.expectEqual(rt.tree.len, cp.tree.len);
    for (0..rt.tree.len) |r| try std.testing.expectEqual(rt.tree.rect(@intCast(r)), cp.tree.rect(@intCast(r)));
    // The stack laid the labels out, not Mono: the first is one 30 px line, and the
    // decorations (an underline and the span's strike) are in the draw list.
    try std.testing.expectEqual(@as(f32, 30), cp.tree.rect(2).h());
    try std.testing.expect(cp.draw.quad_len >= 2);
}

test "spans: one paragraph in two sizes and colours lays out the same in both front ends" {
    const th: Theme = .default;
    const runs = comptime [_]@import("../text/protocol.zig").Span{ .{ .start = 4, .style = .{ .px = 28, .color = .rgb(255, 0, 0) }, .decoration = .{ .underline = true } }, .{ .start = 7, .style = labelText(&Theme.default) } };
    const spec = comptime spec_zig.col(.{}, .{spec_zig.spans(spec_zig.label("one two three"), &runs)});
    const Ui = ComptimeUi(struct {}, spec, th);
    const App = struct {
        rows: [1]u32 = undefined,
        pub fn build(app: *@This(), f: *Frame) void {
            _ = f.open(.none, .{});
            _ = f.textStyled("one two three", labelText(&th), .{});
            app.rows[0] = f.texts().len - 1;
            f.close();
        }
        pub fn end(app: *@This(), f: *Frame, font: Mono) context.Output {
            return f.endParagraphs(@import("../text/protocol.zig").MonoParagraphs{ .mono = font, .rows = &app.rows, .styles = &.{0}, .table = &.{.{}}, .spans = &.{&runs} });
        }
    };
    var h: Harness(App, Ui, .{ .nodes = 8, .texts = 2, .strings = 64, .depth = 4 }) = undefined;
    h.init();
    const in: Input = .{ .viewport = .{ 320, 180 } };
    const out = (try h.frame(&in)).comptime_;
    const t = out.tree;
    // Ten bytes at 14 px and "two" at 28: 10 * 8.4 + 3 * 16.8.
    try std.testing.expectApproxEqAbs(10 * 8.4 + 3 * 16.8, t.rect(2).w(), 1);
    // "two" alone is underlined: one bar from after "one " for its three wide bytes.
    var bars: u32 = 0;
    for (out.draw.quads[0..out.draw.quad_len]) |q| if (q.rect[3] - q.rect[1] <= 2) {
        bars += 1;
        try std.testing.expectApproxEqAbs(t.rect(2).x0 + 4 * 8.4, q.rect[0], 0.01);
        try std.testing.expectApproxEqAbs(3 * 16.8, q.rect[2] - q.rect[0], 0.01);
    };
    try std.testing.expectEqual(1, bars);
}
