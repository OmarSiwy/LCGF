//! Tooltip (tier 2): a short text that appears next to a widget once the pointer has rested on
//! it, the WAI-ARIA APG tooltip pattern. Written against the public API of tiers 0 and 1, after
//! the recipe in base.zig. The bubble floats (`Style.float`) under the root, below the target's
//! rect of the last frame (`Frame.lastRect`, prototype/ui.zig), and takes no pointer input: the
//! pointer stays on the target under it.
//!
//! Its state is a `Tip`, owned by the application: how long the pointer has rested on the
//! target, and whether the tooltip shows.
//!
//! Runtime: build the target, `update(f, &tip, response)`, then under the root after the page
//! `show(f, th, "target", &tip, text)`.
//!
//! Comptime: `const T = Tooltip(th, .save, .tip);` gives the spec builder `T.bubble` and the
//! hooks `popover.ComptimePage(State, spec, th, T)` runs. Or, in `base.ComptimeUi` beside any
//! widget: `ct.tooltip(th, .save, .tip, "text")` last in the root.

const std = @import("std");
const base = @import("base.zig");
const popover = @import("popover.zig");
const types = @import("../core/types.zig");
const simd = @import("../core/simd.zig");
const Input = @import("../core/input.zig").Input;
const Frame = @import("../runtime/frame.zig").Frame;
const context = @import("../runtime/context.zig");
const spec_zig = @import("../comptime/spec.zig");
const a11y = @import("../a11y/tree.zig");
const Spec = spec_zig.Spec;
const Theme = base.Theme;
const Rect = types.Rect;
const Style = types.Style;
const Response = types.Response;
const Part = popover.Part;

// ---- spec: what the tooltip takes and keeps --------------------------------------------------

/// A tooltip's state, owned by the application.
pub const Tip = struct {
    /// Seconds the pointer has rested on the target; 0 while it is elsewhere.
    rested: f32 = 0,
    /// Escape hid the tooltip; it stays hidden until the pointer leaves the target.
    dismissed: bool = false,
    /// The bubble is shown this frame.
    shown: bool = false,

    /// Whether the bubble is shown: what `spec.when` over this field selects by (`ct.tooltip`).
    pub fn visible(t: Tip) bool {
        return t.shown;
    }
};

/// Seconds the pointer rests on the target before the tooltip shows: `Interaction.hover_delay`.
pub const delay: f32 = 0.5;

/// `null` if `State` can hold a tooltip bound to `tip`, else the compile error: `tip` must be a
/// `Tip` field.
pub fn checkTip(comptime State: type, comptime tip: []const u8) ?[]const u8 {
    if (!@hasField(State, tip)) return "tooltip: state " ++ @typeName(State) ++ " has no field '" ++ tip ++ "'";
    if (@FieldType(State, tip) != Tip) return "tooltip: field '" ++ tip ++ "' must be a tooltip.Tip, not " ++ @typeName(@FieldType(State, tip));
    return null;
}

/// The tooltip of the widget named `target`, bound to the `Tip` field `tip`, in theme `th`: its
/// spec builder and the hooks `popover.ComptimePage` calls.
pub fn Tooltip(comptime th: Theme, comptime target: @EnumLiteral(), comptime tip: @EnumLiteral()) type {
    const tip_name = @tagName(tip);
    return struct {
        /// The bubble showing the string field `text`. Put it last in the page's root so it is
        /// drawn above the rest. It has no id, so it takes no pointer input; it is told apart
        /// by its binding to `tip`.
        pub fn bubble(comptime text: anytype) Spec {
            return .{ .kind = .col, .bind = tip_name, .children = &.{base.ct.label(th, text)} };
        }

        pub fn check(comptime State: type) ?[]const u8 {
            return checkTip(State, tip_name);
        }

        /// Rests or resets the timer from the target's hover; Escape hides.
        pub fn step(sig: anytype, v: anytype) void {
            const hovered = v.responseOf(@tagName(target)).hovered;
            sig.set(tip, advance(@field(sig.state, tip_name), hovered, v.in.dt, popover.keyPressed(v.in, popover.keys.escape)));
        }

        pub fn part(comptime n: Spec, st: anytype, v: anytype) ?Part {
            if (comptime n.kind == .col and n.bind != null and std.mem.eql(u8, n.bind.?, tip_name)) {
                if (!@field(st, tip_name).shown) return null;
                return .{ .style = bubbleStyle(&th, v.last.of(@tagName(target))), .role = role };
            }
            return popover.plainPart(th, n, v.response);
        }
    };
}

// ---- look -------------------------------------------------------------------------------------

/// The bubble, floating `th.gap` below the target's rect `at` (last frame's), left edges
/// aligned: a small dark plate (the held-control colour) with the control outline.
pub fn bubbleStyle(th: *const Theme, at: Rect) Style {
    return .{
        .float = true,
        .offset = .{ at.x0, at.y1 + th.gap },
        .pad = .{ th.pad, th.gap, th.pad, th.gap },
        .fill = th.control_held,
        .border = 1,
        .border_color = th.control_hot,
        .radius = th.radius,
    };
}

// ---- behaviour: a pure function of the state and what happened --------------------------------

/// One frame of a tooltip: while the target is hovered the timer runs, and the tooltip shows
/// once it reaches `delay`; leaving the target resets it. Escape hides a shown tooltip until
/// the pointer leaves the target (APG: Escape dismisses the tooltip).
pub fn advance(tip: Tip, hovered: bool, dt: f32, escape: bool) Tip {
    const rested = simd.selF(hovered, tip.rested + dt, 0);
    const dismissed = simd.andB(hovered, simd.orB(tip.dismissed, simd.andB(escape, tip.shown)));
    return .{ .rested = rested, .dismissed = dismissed, .shown = simd.andB(simd.andB(hovered, !dismissed), rested >= delay) };
}

// ---- accessibility ------------------------------------------------------------------------------

/// The bubble's role. A tooltip takes its name from its content (`a11y.from_content`), so it
/// reads as its text; its value is 0 and it has no states. The bubble exists only while it is
/// shown, so its presence in the tree is its visibility.
pub const role: a11y.Role = .tooltip;

// ---- runtime front end ------------------------------------------------------------------------

/// Steps `tip` by one frame from the target's response `r`.
pub fn update(f: *const Frame, tip: *Tip, r: Response) void {
    tip.* = advance(tip.*, r.hovered, f.in.dt, popover.keyPressed(f.in, popover.keys.escape));
}

/// Builds the bubble of the tooltip of `target` showing `text`, if it is shown. Call it at the
/// root's depth, after the rest of the page, so it is drawn on top.
pub fn show(f: *Frame, th: *const Theme, comptime target: []const u8, tip: *const Tip, text: []const u8) void {
    showFace(f, th, target, tip, text, bubbleStyle(th, .{}), base.labelText(th));
}

/// `show` with the bubble laid out by `face` instead of `bubbleStyle` and its text drawn in
/// `ts`; it still floats below the target (`popover.anchored`).
pub fn showFace(f: *Frame, th: *const Theme, comptime target: []const u8, tip: *const Tip, text: []const u8, face: Style, ts: types.TextStyle) void {
    if (!tip.shown) return;
    const b = f.open(.none, popover.anchored(face, bubbleStyle(th, f.lastRect(.from(target)))));
    f.tree().c.role[b.ix()] = @backingInt(role);
    _ = f.text(text, ts);
    f.close();
}

// ---- comptime front end in base.ComptimeUi ----------------------------------------------------

pub const ct = struct {
    /// The tooltip of the widget named `target` (elsewhere on the page), bound to the `Tip`
    /// field `tip`, showing `text`. Put it last in the page's root so it is drawn above the rest;
    /// it is live while the tip is shown (`spec.when`, `Tip.visible`). Its runtime twin:
    /// `update(f, &tip, f.ctx.inter.response(.from("target")))` and `show(...)` there;
    /// `spec.styled` and `spec.textStyled` restyle the bubble as `showFace` does.
    pub fn tooltip(comptime th: Theme, comptime target: @EnumLiteral(), comptime tip: @EnumLiteral(), comptime text: []const u8) Spec {
        return spec_zig.when(tip, .{ .kind = .col, .style = bubbleStyle(&th, .{}), .bind = @tagName(tip), .widget = Bubble(th, @tagName(target), @tagName(tip), text), .children = &.{.{ .kind = .label }} });
    }
};

/// The custom widget (`Spec.widget`) of `ct.tooltip`: its `step` runs while the bubble is
/// hidden too (`steps_hidden`), advancing the tip from the target's hover, and keeps the
/// target's rect for `push`.
pub fn Bubble(comptime th: Theme, comptime target: []const u8, comptime tip: []const u8, comptime text: []const u8) type {
    return struct {
        pub const steps_hidden = true;

        pub fn bindError(comptime State: type, comptime bound: []const u8) ?[]const u8 {
            return base.fieldError(State, "tooltip", bound, Tip);
        }

        pub fn step(ui: anytype, comptime row: u32, event: anytype, in: *const Input) void {
            _ = row;
            _ = event;
            const U = @TypeOf(ui.*);
            const at_row: u32 = comptime @backingInt(@field(U.Events.Widget, target));
            const at = ui.lastRect(at_row);
            ui.keep(@This()).* = .{ at.x0, at.y0, at.x1, at.y1 };
            const hovered = ui.response(at_row, in).hovered;
            ui.signals.set(comptime U.field(tip), advance(@field(ui.signals.state, tip), hovered, in.dt, popover.keyPressed(in, popover.keys.escape)));
        }

        pub fn push(ui: anytype, comptime n: Spec, parent: u32, next: *u32, in: *const Input) void {
            _ = in;
            const tb = &ui.tables;
            const k = ui.keep(@This()).*;
            // The bubble's face is the spec's (`spec.styled`), placed below the target.
            const b = tb.t.push(parent, .none, &popover.anchored(n.style, bubbleStyle(&th, .{ .x0 = k[0], .y0 = k[1], .x1 = k[2], .y1 = k[3] })));
            tb.t.c.role[b] = @backingInt(role);
            const l = tb.t.push(b, .none, &.{ .role = .label });
            tb.t.c.text[l] = tb.tx.push(l, tb.strings.add(text), &(comptime n.text_style orelse base.labelText(&th)));
            tb.t.seal(l);
            tb.t.seal(b);
            next.* += comptime @import("../comptime/flatten.zig").count(n);
        }
    };
}

// ---- example page, replay and golden frames ---------------------------------------------------

/// The example page: a toolbar with a button and a label, and the button's tooltip, in both
/// front ends, in theme `th`. The tests and the golden images (tools/golden/) run it.
pub fn Example(comptime th: Theme) type {
    return struct {
        pub const toolbar_style: Style = .{ .dir = .x, .size = .{ .fill, .fit }, .pad = @splat(8), .gap = 8, .cross = .center, .fill = th.panel };

        pub const App = struct {
            tip: Tip = .{},

            pub fn build(app: *App, f: *Frame) void {
                _ = f.open(.none, .{});
                _ = f.open(.none, toolbar_style);
                const r = base.button(f, &th, .from("save"), "Save");
                update(f, &app.tip, r);
                _ = base.label(f, &th, "Scene 1");
                f.close();
                show(f, &th, "save", &app.tip, "Save the scene (Ctrl+S)");
                f.close();
            }
        };

        pub const State = struct {
            tip: Tip = .{},
            save_text: []const u8 = "Save",
            scene: []const u8 = "Scene 1",
            save_tip: []const u8 = "Save the scene (Ctrl+S)",
        };
        pub const T = Tooltip(th, .save, .tip);
        pub const spec = spec_zig.col(.{}, .{
            spec_zig.row(toolbar_style, .{ base.ct.button(th, .save, .save_text), base.ct.label(th, .scene) }),
            T.bubble(.save_tip),
        });
        pub const Ui = popover.ComptimePage(State, spec, th, T);
        pub const limits: context.Limits = .{ .nodes = 64, .texts = 16, .customs = 1, .strings = 1024, .depth = 8 };
        pub const Run = base.Harness(App, Ui, limits);
    };
}

/// Input for `Example(.default)` at 800 x 600, one commented line per frame.
pub const replay = @embedFile("testdata/tooltip.replay");

/// The frames of `replay` kept as golden images, by name (tools/golden/ref/widgets/<name>.png).
pub const golden_frames = .{
    .{ "tooltip-resting", 2 },
    .{ "tooltip-shown", 3 },
    .{ "tooltip-dismissed", 9 },
};

/// What tools/golden/ dumps: the page's harness over `replay`.
pub const golden = struct {
    pub const Run = Example(.default).Run;
    pub const src = replay;
    pub const frames = golden_frames;
};

// ---- tests ------------------------------------------------------------------------------------

const testing = std.testing;
const Page = Example;

const Default = Page(.default);
var harness: Default.Run = .{};

/// Starts harness `h`, then rests the pointer on the button for a frame as long as the delay:
/// the tree of the frame the bubble shows in.
fn showTip(h: anytype) !*const @import("../core/tree.zig").Tree {
    h.init();
    var in: Input = .{ .viewport = .{ 400, 300 }, .dt = delay };
    const first = (try h.frame(&in)).runtime.tree;
    try testing.expectEqual(@as(u32, 6), first.len);
    const r = first.rect(first.find(.from("save")));
    in.pointer = .{ (r.x0 + r.x1) * 0.5, (r.y0 + r.y1) * 0.5 };
    const t = (try h.frame(&in)).runtime.tree;
    try testing.expect(h.app.tip.shown);
    return t;
}

test "showFace: the theme's styles draw as show" {
    const S = struct {
        const tip: Tip = .{ .rested = 1, .shown = true };
        fn build(f: *Frame, k: u1) void {
            const th: *const Theme = &.default;
            _ = base.button(f, th, .from("save"), "Save");
            if (k == 0) show(f, th, "save", &tip, "Save the file") else showFace(f, th, "save", &tip, "Save the file", bubbleStyle(th, .{}), base.labelText(th));
        }
    };
    try base.expectSameFace(.{ .nodes = 16, .texts = 4, .customs = 1, .strings = 64, .depth = 8 }, S.build, .{ 10, 10 });
}

test "Tooltip: the page agrees in both front ends, hidden and shown" {
    const h = &harness;
    h.init();
    const t = try showTip(h);
    try testing.expectEqual(@as(u32, 8), t.len);
    // The bubble hangs below the button.
    const at = t.rect(t.find(.from("save")));
    try testing.expectEqual(at.x0, t.rect(6).x0);
    try testing.expectEqual(at.y1 + Theme.default.gap, t.rect(6).y0);
}

/// The example page with the tooltip as `ct.tooltip` in `base.ComptimeUi`; the runtime side
/// is `Example`'s app.
const CtPage = struct {
    const th: Theme = .default;
    const E = Example(th);
    pub const State = struct { tip: Tip = .{} };
    pub const spec = spec_zig.col(.{}, .{
        spec_zig.row(E.toolbar_style, .{ base.ct.button(th, .save, "Save"), base.ct.label(th, "Scene 1") }),
        ct.tooltip(th, .save, .tip, "Save the scene (Ctrl+S)"),
    });
    pub const Ui = base.ComptimeUi(State, spec, th);
    pub const Run = base.Harness(E.App, Ui, E.limits);
};
var ct_harness: CtPage.Run = .{};

test "ct.tooltip: the example replay in base.ComptimeUi gives the runtime tooltip's frames" {
    const Replay = @import("../core/input.zig").Replay;
    const h = &ct_harness;
    h.init();
    var text: [16]u8 = undefined;
    var evs: [8]Input.Event = undefined;
    var contacts: [1]Input.Contact = undefined;
    var r: Replay = .{ .src = replay };
    var shown: u32 = 0;
    while (try r.next(.{ .text = &text, .events = &evs, .contacts = &contacts })) |in| {
        _ = try h.frame(in);
        try testing.expectEqual(h.app.tip, h.ui.signals.state.tip);
        shown += @intFromBool(h.app.tip.shown);
    }
    try testing.expect(shown > 0);
}

/// The tooltip restyled as a page does from data: `showFace` against `spec.styled` and
/// `spec.textStyled` on `ct.tooltip`.
const restyled = struct {
    const th: Theme = .default;
    const E = Example(th);
    const face: Style = blk: {
        var s = bubbleStyle(&th, .{});
        s.pad = @splat(9);
        s.fill = .rgb(20, 40, 60);
        s.radius = 9;
        break :blk s;
    };
    const text: types.TextStyle = .{ .px = 17, .color = .rgb(250, 220, 120) };
    const App = struct {
        tip: Tip = .{},
        pub fn build(app: *App, f: *Frame) void {
            _ = f.open(.none, .{});
            _ = f.open(.none, E.toolbar_style);
            update(f, &app.tip, base.button(f, &th, .from("save"), "Save"));
            _ = base.label(f, &th, "Scene 1");
            f.close();
            showFace(f, &th, "save", &app.tip, "Save the scene (Ctrl+S)", face, text);
            f.close();
        }
    };
    const spec = spec_zig.col(.{}, .{
        spec_zig.row(E.toolbar_style, .{ base.ct.button(th, .save, "Save"), base.ct.label(th, "Scene 1") }),
        spec_zig.styled(spec_zig.textStyled(ct.tooltip(th, .save, .tip, "Save the scene (Ctrl+S)"), text), face),
    });
    var h: base.Harness(App, base.ComptimeUi(CtPage.State, spec, th), E.limits) = .{};
};

test "ct.tooltip restyled: the same frames as showFace over the replay" {
    _ = try base.expectReplayAgrees(&restyled.h, replay);
    try testing.expectEqual(restyled.h.app.tip, restyled.h.ui.signals.state.tip);
}

test "bubbleStyle: the theme's tokens, below the target" {
    const th: Theme = .default;
    const s = bubbleStyle(&th, .{ .x0 = 10, .y0 = 20, .x1 = 60, .y1 = 40 });
    try testing.expect(s.float);
    try testing.expectEqual([2]f32{ 10, 40 + th.gap }, s.offset);
    try testing.expectEqual(th.control_held, s.fill);
    try testing.expectEqual(th.control_hot, s.border_color);
    try testing.expectEqual(th.radius, s.radius);
    try testing.expectEqual([4]f32{ th.pad, th.gap, th.pad, th.gap }, s.pad);
}

const light: Theme = .{ .control_held = .rgb(250, 250, 220), .control_hot = .rgb(180, 180, 190), .text = .rgb(20, 20, 20), .pad = 12, .gap = 10, .radius = 0 };

test "Tooltip: another theme restyles both front ends alike" {
    const S = struct {
        var h: Page(light).Run = .{};
    };
    const t = try showTip(&S.h);
    try testing.expectEqual(light.control_held.bitsOf(), t.c.look[6].fill);
    try testing.expectEqual(t.rect(t.find(.from("save"))).y1 + 10, t.rect(6).y0);
}

test "Tooltip: the example replay gives the same frames in both front ends" {
    const Replay = @import("../core/input.zig").Replay;
    const h = &harness;
    h.init();
    var text: [16]u8 = undefined;
    var evs: [8]Input.Event = undefined;
    var contacts: [1]Input.Contact = undefined;
    const buf: Replay.Buffers = .{ .text = &text, .events = &evs, .contacts = &contacts };
    var r: Replay = .{ .src = replay };
    var shown: [12]bool = undefined;
    var rows: [12]u32 = undefined;
    while (try r.next(buf)) |in| {
        const k = h.frames;
        const out = try h.frame(in);
        const t = out.runtime.tree;
        try testing.expectEqual(h.app.tip, h.ui.signals.state.tip);
        shown[k] = h.app.tip.shown;
        rows[k] = t.len;
        if (k == 3) {
            // The rects the replay's comments give.
            try testing.expectEqual(Rect{ .x0 = 8, .y0 = 8, .x1 = 58, .y1 = 42 }, t.rect(t.find(.from("save"))));
            try testing.expectEqual(Rect{ .x0 = 8, .y0 = 48, .x1 = 217, .y1 = 78 }, t.rect(t.len - 2));
        }
    }
    try testing.expectEqual(@as(u32, 12), h.frames);
    try testing.expectEqualSlices(bool, &.{ false, false, false, true, true, false, false, false, true, false, false, false }, &shown);
    try testing.expectEqualSlices(u32, &.{ 6, 6, 6, 8, 8, 6, 6, 6, 8, 6, 6, 6 }, &rows);
    try testing.expect(h.app.tip.rested == 0 and !h.app.tip.dismissed);
}

test "golden_frames: name frames the replay has" {
    inline for (golden_frames) |g| try testing.expect(g[1] < 12);
}

test "advance: the timer, the delay and Escape" {
    var t: Tip = .{};
    t = advance(t, true, 0.25, false);
    try testing.expect(!t.shown);
    t = advance(t, true, 0.25, false);
    try testing.expect(t.shown);
    try testing.expectEqual(@as(f32, 0.5), t.rested);
    t = advance(t, true, 0.25, true);
    try testing.expect(!t.shown and t.dismissed);
    t = advance(t, true, 0.25, false);
    try testing.expect(!t.shown and t.dismissed);
    t = advance(t, false, 0.25, false);
    try testing.expectEqual(Tip{}, t);
    // Escape before it shows does nothing.
    t = advance(t, true, 0.25, true);
    t = advance(t, true, 0.25, false);
    try testing.expect(t.shown);
}

/// Runs `script` (pointer on the button or away, Escape or not, `dt` per frame) through both
/// front ends and requires the tooltip's state after each step in both.
fn expectScript(script: []const struct { on: bool, esc: bool = false, shown: bool }) !void {
    const h = &harness;
    h.init();
    var in: Input = .{ .viewport = .{ 400, 300 }, .dt = 0.2 };
    var ev: [1]Input.Event = .{.{ .kind = .press, .code = popover.keys.escape }};
    const t = (try h.frame(&in)).runtime.tree;
    const r = t.rect(t.find(.from("save")));
    for (script) |st| {
        in.pointer = if (st.on) .{ (r.x0 + r.x1) * 0.5, (r.y0 + r.y1) * 0.5 } else .{ 390, 290 };
        in.events = if (st.esc) &ev else &.{};
        _ = try h.frame(&in);
        try testing.expectEqual(h.app.tip, h.ui.signals.state.tip);
        try testing.expectEqual(st.shown, h.app.tip.shown);
    }
}

test "Tooltip: shows after resting on the target, hides on leaving and on Escape" {
    try expectScript(&.{
        .{ .on = true, .shown = false }, // 0.2 s
        .{ .on = true, .shown = false }, // 0.4 s
        .{ .on = true, .shown = true }, // 0.6 s: past the delay
        .{ .on = true, .shown = true },
        .{ .on = false, .shown = false }, // left: hidden, timer reset
        .{ .on = true, .shown = false },
        .{ .on = true, .shown = false },
        .{ .on = true, .shown = true },
        .{ .on = true, .esc = true, .shown = false }, // Escape
        .{ .on = true, .shown = false }, // stays hidden while on the target
        .{ .on = false, .shown = false },
        .{ .on = true, .shown = false },
    });
}

var sem: [2]popover.Semantic(64) = .{ .{}, .{} };

test "Tooltip: the bubble is a tooltip named by its text, the same in both front ends" {
    const h = &harness;
    _ = try showTip(h);
    const in: Input = .{ .viewport = .{ 400, 300 }, .dt = delay, .pointer = h.ctx.inter.pointer };
    const pair = try h.frame(&in);
    try testing.expect(h.app.tip.shown);
    const rt = pair.runtime;
    const cp = pair.comptime_;
    _ = sem[0].begin();
    _ = sem[1].begin();
    const e = sem[0].finish(rt.tree, rt.texts, h.ctx.strings[h.ctx.cur].buf);
    try testing.expect(popover.sameSemantics(e, sem[1].finish(cp.tree, &h.ui.tables.tx, h.ui.tables.strings.buf)));
    // The bubble and its label are the last two rows.
    const k = popover.exportRow(e, rt.tree.len - 2);
    try testing.expectEqual(@backingInt(a11y.Role.tooltip), e.c.role[k]);
    try testing.expectEqual(std.hash.Fnv1a_32.hash("Save the scene (Ctrl+S)"), e.c.name_hash[k]);
    try testing.expectEqual(@as(f32, 0), e.c.value[k]);
    try testing.expectEqual(@as(u8, 0), e.c.state[k]);
    try testing.expectEqual(std.hash.Fnv1a_32.hash("Save"), e.c.name_hash[popover.exportRow(e, rt.tree.find(.from("save")))]);
}

test "checkTip: the tip field must be a Tip" {
    try testing.expectEqual(null, comptime checkTip(Default.State, "tip"));
    try testing.expectEqualStrings("tooltip: field 'tip' must be a tooltip.Tip, not bool", comptime checkTip(struct { tip: bool }, "tip").?);
    try testing.expect(comptime checkTip(struct {}, "tip") != null);
}

test {
    std.testing.refAllDecls(@This());
}
