//! Toast (tier 2): a short message that appears at the bottom of the window for a few seconds,
//! the WAI-ARIA APG alert pattern (a live region that does not take focus). Written against the
//! public API of tiers 0 and 1, after the recipe in base.zig. The toast sits in a layer that
//! floats over the whole viewport (`Style.float`) and puts it at the bottom centre, so its
//! place needs no size known in advance.
//!
//! Its state is a `ToastState`, owned by the application: shown or not, and the seconds left.
//! Time is the frames' `dt`, so the state steps the same in both front ends; the fading out is
//! the toast's opacity, a function of the seconds left (no spring: prototype/ui.zig's
//! `Frame.animate` belongs to the animation lane).
//!
//! Runtime: build the page, then `show(...)` under the root after it.
//!
//! Comptime: `const T = Toast(th, .saved, .toast, .save);` gives the spec builder `T.layer` and
//! the hooks `popover.ComptimePage(State, spec, th, T)` runs.

const std = @import("std");
const base = @import("base.zig");
const popover = @import("popover.zig");
const types = @import("../core/types.zig");
const simd = @import("../core/simd.zig");
const Input = @import("../core/input.zig").Input;
const Tree = @import("../core/tree.zig").Tree;
const Frame = @import("../runtime/frame.zig").Frame;
const context = @import("../runtime/context.zig");
const spec_zig = @import("../comptime/spec.zig");
const a11y = @import("../a11y/tree.zig");
const Spec = spec_zig.Spec;
const Theme = base.Theme;
const Id = types.Id;
const Rect = types.Rect;
const Style = types.Style;
const Response = types.Response;
const Part = popover.Part;

// ---- spec: what the toast takes and keeps ----------------------------------------------------

/// A toast's state, owned by the application.
pub const ToastState = struct {
    shown: bool = false,
    /// Seconds before it goes.
    left: f32 = 0,
};

/// Seconds a toast stays, not counting the time the pointer rests on it.
pub const duration: f32 = 3;

/// `null` if `State` can hold a toast bound to `field`, else the compile error.
pub fn checkToast(comptime State: type, comptime field: []const u8) ?[]const u8 {
    if (!@hasField(State, field)) return "toast: state " ++ @typeName(State) ++ " has no field '" ++ field ++ "'";
    if (@FieldType(State, field) != ToastState) return "toast: field '" ++ field ++ "' must be a toast.ToastState";
    return null;
}

/// Toast `name`, bound to the `ToastState` field `field` and shown when the widget `trigger`
/// is clicked, in theme `th`: its spec builder and the hooks `popover.ComptimePage` calls.
pub fn Toast(comptime th: Theme, comptime name: @EnumLiteral(), comptime field: @EnumLiteral(), comptime trigger: @EnumLiteral()) type {
    const id = @tagName(name);
    const field_name = @tagName(field);
    const trigger_name = @tagName(trigger);
    return struct {
        /// The layer and the toast showing the string field `text`. Put it last in the page's
        /// root so it is drawn above the rest. The layer has no id (it takes no pointer
        /// input); it is told apart by its binding to `field`.
        pub fn layer(comptime text: @EnumLiteral()) Spec {
            var t = spec_zig.row(.{}, .{base.ct.label(th, text)});
            t.id = id;
            return .{ .kind = .col, .bind = field_name, .children = &.{t} };
        }

        pub fn check(comptime State: type) ?[]const u8 {
            return checkToast(State, field_name);
        }

        /// The trigger's click and the toast's hover, through `advance`.
        pub fn step(sig: anytype, v: anytype) void {
            const ts: ToastState = @field(sig.state, field_name);
            sig.set(field, advance(ts, v.responseOf(trigger_name).clicked, v.responseOf(id).hovered, v.in.dt));
        }

        pub fn part(comptime n: Spec, st: anytype, v: anytype) ?Part {
            const ts: ToastState = @field(st, field_name);
            if (comptime n.kind == .col and n.id == null and n.bind != null and std.mem.eql(u8, n.bind.?, field_name))
                return .{ .style = layerStyle(&th, v.in.viewport) };
            if (comptime n.id != null and std.mem.eql(u8, n.id.?, id)) {
                if (!ts.shown) return null;
                return .{ .style = toastStyle(&th, ts), .role = role };
            }
            return popover.plainPart(th, n, v.response);
        }
    };
}

// ---- look -------------------------------------------------------------------------------------

/// The layer: over the whole viewport, the toast at its bottom centre, twice a button's
/// padding from the edge.
pub fn layerStyle(th: *const Theme, viewport: [2]f32) Style {
    return .{ .float = true, .size = .{ .px(viewport[0]), .px(viewport[1]) }, .pad = @splat(th.pad * 2), .main = .end, .cross = .center };
}

/// Seconds over which a toast fades out at the end of its time.
pub const fade: f32 = 0.3;

/// The toast: a control-coloured plate with the control outline, padded like a wide button,
/// fading out over its last `fade` seconds.
pub fn toastStyle(th: *const Theme, t: ToastState) Style {
    return .{
        .dir = .x,
        .pad = .{ th.pad * 2, th.pad, th.pad * 2, th.pad },
        .cross = .center,
        .fill = th.control,
        .border = 1,
        .border_color = th.control_hot,
        .radius = th.radius,
        .opacity = base.unit(t.left / fade),
    };
}

// ---- behaviour: a pure function of the state and what happened --------------------------------

/// One frame of a toast: `trigger` shows it for `duration` seconds (again from the start if it
/// is shown); time runs by `dt` except while the pointer rests on it (`hovered`), so a reader
/// keeps it; it goes when its time is up. It never takes focus (APG alert).
pub fn advance(t: ToastState, trigger: bool, hovered: bool, dt: f32) ToastState {
    if (trigger) return .{ .shown = true, .left = duration };
    const left = @max(t.left - simd.selF(simd.andB(t.shown, !hovered), dt, 0), 0);
    return .{ .shown = simd.andB(t.shown, left > 0), .left = left };
}

// ---- accessibility ------------------------------------------------------------------------------

/// The toast's role: an alert, which assistive technology announces when it appears without
/// moving focus (APG alert). Its value is 0; it is in the tree only while shown.
pub const role: a11y.Role = .alert;

/// The semantics of toast `name` the tree's columns cannot hold, written into `s` after
/// `Semantics.clear` and before `a11y.names`: the alert is named by its message, its only
/// child (alert does not take its name from content). Works on either front end's tree.
pub fn semantics(t: *const Tree, s: *a11y.Semantics, comptime name: []const u8) void {
    const k = t.find(.from(name));
    if (k != types.none) s.c.labelled_by[k] = k + 1;
}

// ---- runtime front end ------------------------------------------------------------------------

/// Builds the layer of toast `name` and, while it is shown, the toast showing `text`. Call it
/// at the root's depth, after the rest of the page, so it is drawn on top. `trigger` is the
/// click that shows it (`advance`).
pub fn show(f: *Frame, th: *const Theme, comptime name: []const u8, t: *ToastState, trigger: bool, text: []const u8) void {
    const id: Id = .from(name);
    t.* = advance(t.*, trigger, f.ctx.inter.response(id).hovered, f.in.dt);
    _ = f.open(.none, layerStyle(th, f.in.viewport));
    if (t.shown) {
        const n = f.open(id, toastStyle(th, t.*));
        _ = f.interact(n, .{ .hover = true });
        f.tree().c.role[n.ix()] = @backingInt(role);
        _ = base.label(f, th, text);
        f.close();
    }
    f.close();
}

// ---- example page, replay and golden frames ---------------------------------------------------

/// The example page: a toolbar with a Save button and a label, and the toast Save shows, in
/// both front ends, in theme `th`. The tests and the golden images (tools/widgetgolden/) run
/// it.
pub fn Example(comptime th: Theme) type {
    return struct {
        const toolbar_style: Style = .{ .dir = .x, .size = .{ .fill, .fit }, .pad = @splat(8), .gap = 8, .cross = .center, .fill = th.panel };
        const page_style: Style = .{ .size = .{ .fill, .fill } };

        pub const App = struct {
            toast: ToastState = .{},

            pub fn build(app: *App, f: *Frame) void {
                _ = f.open(.none, page_style);
                _ = f.open(.none, toolbar_style);
                const save = base.button(f, &th, .from("save"), "Save");
                _ = base.label(f, &th, "Scene 1");
                f.close();
                show(f, &th, "saved", &app.toast, save.clicked, "Scene saved");
                f.close();
            }
        };

        pub const State = struct {
            toast: ToastState = .{},
            save_text: []const u8 = "Save",
            scene: []const u8 = "Scene 1",
            saved_text: []const u8 = "Scene saved",
        };
        pub const T = Toast(th, .saved, .toast, .save);
        pub const spec = spec_zig.col(page_style, .{
            spec_zig.row(toolbar_style, .{ base.ct.button(th, .save, .save_text), base.ct.label(th, .scene) }),
            T.layer(.saved_text),
        });
        pub const Ui = popover.ComptimePage(State, spec, th, T);
        pub const limits: context.Limits = .{ .nodes = 64, .texts = 16, .customs = 1, .strings = 1024, .depth = 8 };
        pub const Run = base.Harness(App, Ui, limits);
    };
}

/// Input for `Example(.default)` at 800 x 600, one commented line per frame.
pub const replay = @embedFile("testdata/toast.replay");

/// The frames of `replay` kept as golden images, by name (tools/widgetgolden/ref/<name>.png).
pub const golden_frames = .{
    .{ "toast-shown", 2 },
    .{ "toast-hover", 4 },
    .{ "toast-fading", 10 },
    .{ "toast-gone", 11 },
};

/// What tools/widgetgolden/ dumps: the page's harness over `replay`.
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

/// Sets the toast's state in both front ends of `h` and builds a frame; returns its tree.
fn setState(h: anytype, st: ToastState) !*const Tree {
    const in: Input = .{ .viewport = .{ 400, 300 }, .dt = 0 };
    h.app.toast = st;
    h.ui.signals.set(.toast, st);
    return (try h.frame(&in)).runtime.tree;
}

test "Toast: the page agrees in both front ends, hidden and shown" {
    const h = &harness;
    h.init();
    var t = try setState(h, .{});
    try testing.expectEqual(@as(u32, 7), t.len);
    t = try setState(h, .{ .shown = true, .left = duration });
    try testing.expectEqual(@as(u32, 9), t.len);
    // At the bottom centre of the viewport.
    const r = t.rect(t.find(.from("saved")));
    try testing.expectEqual(@as(f32, 300 - 2 * Theme.default.pad), r.y1);
    try testing.expectApproxEqAbs(@as(f32, 200), (r.x0 + r.x1) * 0.5, 1);
}

test "layerStyle, toastStyle: the theme's tokens and the fade" {
    const th: Theme = .default;
    const s = toastStyle(&th, .{ .shown = true, .left = 2 });
    try testing.expectEqual(th.control, s.fill);
    try testing.expectEqual(th.control_hot, s.border_color);
    try testing.expectEqual(@as(f32, 1), s.opacity);
    try testing.expectApproxEqAbs(@as(f32, 0.5), toastStyle(&th, .{ .shown = true, .left = 0.15 }).opacity, 1e-6);
    try testing.expectEqual(@as(f32, 0), toastStyle(&th, .{}).opacity);
    const l = layerStyle(&th, .{ 400, 300 });
    try testing.expect(l.float);
    try testing.expectEqual(types.Align.end, l.main);
    try testing.expectEqual(types.Align.center, l.cross);
}

const light: Theme = .{ .control = .rgb(200, 200, 205), .control_hot = .rgb(180, 180, 190), .text = .rgb(20, 20, 20), .pad = 12, .gap = 10, .radius = 0 };

test "Toast: another theme restyles both front ends alike" {
    const S = struct {
        var h: Page(light).Run = .{};
    };
    S.h.init();
    _ = try setState(&S.h, .{});
    const t = try setState(&S.h, .{ .shown = true, .left = 0.1 });
    const k = t.find(.from("saved"));
    try testing.expectEqual(light.control.bitsOf(), t.c.look[k].fill);
    try testing.expectEqual(@as(f32, 300 - 24), t.rect(k).y1);
}

test "Toast: the example replay gives the same frames in both front ends" {
    const Replay = @import("../core/input.zig").Replay;
    const h = &harness;
    h.init();
    var text: [16]u8 = undefined;
    var evs: [8]Input.Event = undefined;
    var contacts: [1]Input.Contact = undefined;
    const buf: Replay.Buffers = .{ .text = &text, .events = &evs, .contacts = &contacts };
    var r: Replay = .{ .src = replay };
    var left: [12]f32 = undefined;
    var shown: [12]bool = undefined;
    var opacity: [12]u8 = undefined;
    while (try r.next(buf)) |in| {
        const k = h.frames;
        const out = try h.frame(in);
        const t = out.runtime.tree;
        try testing.expectEqual(h.app.toast, h.ui.signals.state.toast);
        left[k] = h.app.toast.left;
        shown[k] = h.app.toast.shown;
        const row = t.find(.from("saved"));
        opacity[k] = if (row == types.none) 0 else @intFromFloat(@round(toastStyle(&Theme.default, h.app.toast).opacity * 100));
        if (k == 2) {
            // The rects the replay's comments give.
            try testing.expectEqual(Rect{ .x0 = 8, .y0 = 8, .x1 = 58, .y1 = 42 }, t.rect(t.find(.from("save"))));
            try testing.expectEqual(Rect{ .x0 = 338, .y0 = 551, .x1 = 462, .y1 = 584 }, t.rect(row));
        }
    }
    try testing.expectEqual(@as(u32, 12), h.frames);
    try testing.expectEqualSlices(bool, &.{ false, false, true, true, true, true, true, true, true, true, true, false }, &shown);
    try testing.expectEqualSlices(f32, &.{ 3, 2.5, 2.5, 2.5, 2, 1.5, 1, 0.5 }, left[2..10]);
    try testing.expectApproxEqAbs(@as(f32, 0.1), left[10], 1e-6);
    try testing.expectEqual(@as(u8, 33), opacity[10]);
    try testing.expectEqual(@as(u8, 100), opacity[9]);
}

test "golden_frames: name frames the replay has" {
    inline for (golden_frames) |g| try testing.expect(g[1] < 12);
}

test "advance: shows on the trigger, counts down, pauses on hover, goes" {
    var t = advance(.{}, false, false, 1);
    try testing.expectEqual(ToastState{}, t);
    t = advance(t, true, false, 1);
    try testing.expectEqual(ToastState{ .shown = true, .left = duration }, t);
    t = advance(t, false, false, 1);
    try testing.expectEqual(@as(f32, 2), t.left);
    t = advance(t, false, true, 1);
    try testing.expectEqual(@as(f32, 2), t.left); // paused
    t = advance(t, true, false, 1);
    try testing.expectEqual(duration, t.left); // shown again: from the start
    t = advance(advance(advance(t, false, false, 1), false, false, 1), false, false, 1);
    try testing.expectEqual(ToastState{}, t); // time up
}

/// Steps through both front ends, clicking Save or resting on the toast, `dt` per frame; the
/// toast's state after each step, equal in both.
fn runScript(comptime n: usize, script: [n]struct { save: bool = false, on_toast: bool = false }, dt: f32) ![n]ToastState {
    const h = &harness;
    h.init();
    var in: Input = .{ .viewport = .{ 400, 300 }, .dt = dt };
    var last = (try h.frame(&in)).runtime.tree;
    var out: [n]ToastState = undefined;
    var k: usize = 0;
    while (k < n) : (k += 1) {
        const st = script[k];
        const target: []const u8 = if (st.on_toast) "saved" else "save";
        const r = last.rect(last.find(.hash(target)));
        in.pointer = if (st.save or st.on_toast) .{ (r.x0 + r.x1) * 0.5, (r.y0 + r.y1) * 0.5 } else .{ 390, 10 };
        // A click is a press frame and a release frame; the release is the step.
        if (st.save) {
            in.buttons.left = true;
            _ = try h.frame(&in);
            in.buttons.left = false;
        }
        last = (try h.frame(&in)).runtime.tree;
        try testing.expectEqual(h.app.toast, h.ui.signals.state.toast);
        out[k] = h.app.toast;
    }
    return out;
}

test "Toast: Save shows it; it pauses under the pointer and goes after its time" {
    const s = try runScript(9, .{
        .{ .save = true }, // shown (the press frame ran 0.5 s before, while it was hidden)
        .{},
        .{ .on_toast = true }, // paused
        .{ .on_toast = true },
        .{},
        .{},
        .{},
        .{},
        .{},
    }, 0.5);
    try testing.expect(s[0].shown);
    try testing.expectEqual(@as(f32, 3), s[0].left);
    try testing.expectEqual(@as(f32, 2.5), s[1].left);
    try testing.expectEqual(@as(f32, 2.5), s[3].left);
    try testing.expectEqual(@as(f32, 1), s[6].left);
    try testing.expectEqual(@as(f32, 0.5), s[7].left);
    try testing.expectEqual(ToastState{}, s[8]);
}

var sem: [2]popover.Semantic(64) = .{ .{}, .{} };

test "Toast: an alert named by its message; the same in both front ends" {
    const h = &harness;
    h.init();
    const t = try setState(h, .{ .shown = true, .left = duration });
    const cp = &h.ui.tables.t;
    semantics(t, sem[0].begin(), "saved");
    semantics(cp, sem[1].begin(), "saved");
    const e = sem[0].finish(t, &h.ctx.texts[h.ctx.cur], h.ctx.strings[h.ctx.cur].buf);
    try testing.expect(popover.sameSemantics(e, sem[1].finish(cp, &h.ui.tables.tx, h.ui.tables.strings.buf)));
    const k = popover.exportRow(e, t.find(.from("saved")));
    try testing.expectEqual(@backingInt(a11y.Role.alert), e.c.role[k]);
    try testing.expectEqual(std.hash.Fnv1a_32.hash("Scene saved"), e.c.name_hash[k]);
    try testing.expectEqual(@as(f32, 0), e.c.value[k]);
    try testing.expectEqual(@as(u8, 0), e.c.state[k]);
    // Hidden, it is not in the tree at all.
    const gone = try setState(h, .{});
    try testing.expectEqual(types.none, gone.find(.from("saved")));
}

test "checkToast: the state field" {
    try testing.expectEqual(null, comptime checkToast(Default.State, "toast"));
    try testing.expectEqualStrings("toast: field 'toast' must be a toast.ToastState", comptime checkToast(struct { toast: f32 }, "toast").?);
    try testing.expect(comptime checkToast(struct {}, "toast") != null);
}

test {
    std.testing.refAllDecls(@This());
}
