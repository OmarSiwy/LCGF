//! Slider: a value between two ends, set by dragging along a track. Tier 2, written against
//! the public API of tiers 0 and 1 (the recipe in base.zig).
//!
//! Accessibility: role slider (`sliderTrack`), value the value itself in the tree's value
//! column; the thumb is presentational. The range (`aria-valuemin`, `aria-valuemax` and the
//! step a screen reader's increment moves by) and a name are the application's to set, as a
//! slider has neither in the tree: `semantics` writes the range, and the application labels
//! the slider with `Semantics.labelled_by` or `Semantics.label`.
//!
//! State: the application's `f32`, between `lo` and `hi`. The runtime front end takes a
//! pointer to it and the ends as arguments; the comptime front end binds an `f32` field
//! (checked while compiling) and takes the ends as a `Range`, carried in the spec node
//! (`Spec.lo`, `Spec.hi`), so a comptime slider is no longer fixed to 0..1.

const std = @import("std");
const base = @import("base.zig");
const keys = @import("keys.zig");
const types = @import("../core/types.zig");
const spec_zig = @import("../comptime/spec.zig");
const Frame = @import("../runtime/frame.zig").Frame;
const Spec = spec_zig.Spec;
const Theme = base.Theme;
const Id = types.Id;
const Response = types.Response;
const Style = types.Style;
const Input = @import("../core/input.zig").Input;
const Tree = @import("../core/tree.zig").Tree;
const a11y = @import("../a11y/tree.zig");
/// `semantics`, for `Page.semantics`, whose name hides it.
const rangeOf = semantics;

// ---- spec -----------------------------------------------------------------------------------

/// The type of a slider's bound field.
pub const Bind = f32;

/// The ends of a comptime slider's value.
pub const Range = struct { lo: f32 = 0, hi: f32 = 1 };

/// Why `State`'s field `name` cannot be a slider's value, or null when it can.
pub fn bindError(comptime State: type, comptime name: []const u8) ?[]const u8 {
    return base.fieldError(State, "slider", name, Bind);
}

// ---- behaviour ------------------------------------------------------------------------------

/// The value after this frame's keys on a focused slider over `lo`..`hi`, or null when no key
/// of the slider's went down: Right and Up add a hundredth of the range, Left and Down take
/// one away, Page Up and Page Down a tenth, Home goes to `lo` and End to `hi` (WAI-ARIA APG
/// slider pattern), in event order, clamped to the ends. Auto-repeat moves again.
pub fn keyed(value: f32, lo: f32, hi: f32, in: *const Input) ?f32 {
    const k = keys;
    const step = (hi - lo) / 100;
    var v = value;
    var any = false;
    for (in.events) |e| {
        const down = e.kind == .press or e.kind == .repeat;
        if (!down or @as(u8, @bitCast(e.mods)) & 0xf != 0) continue;
        const before = any;
        any = true;
        v = if (e.code == k.right or e.code == k.up)
            v + step
        else if (e.code == k.left or e.code == k.down)
            v - step
        else if (e.code == k.page_up)
            v + 10 * step
        else if (e.code == k.page_down)
            v - 10 * step
        else if (e.code == k.home)
            lo
        else if (e.code == k.end)
            hi
        else blk: {
            any = before;
            break :blk v;
        };
        v = std.math.clamp(v, lo, hi);
    }
    return if (any) v else null;
}

// ---- look -----------------------------------------------------------------------------------

/// The track: as wide as it is given (at least 40), 8 tall, rounded, the control colour;
/// role slider.
pub fn sliderTrack(th: *const Theme) Style {
    return .{ .dir = .x, .size = .{ .fill, .px(8) }, .min = .{ 40, 0 }, .radius = 4, .fill = th.control, .role = .slider };
}

/// The filled part of the track, `frac` of its width, in the accent.
pub fn sliderThumb(th: *const Theme, frac: f32) Style {
    return .{ .size = .{ .pct(frac), .fill }, .radius = 4, .fill = th.accent };
}

// ---- runtime front end ----------------------------------------------------------------------

/// A slider named `id` over `value`, from `lo` at the left end to `hi` at the right. While
/// held, the value follows the pointer across the track; while focused, keys move it
/// (`keyed`).
pub fn slider(f: *Frame, th: *const Theme, id: Id, value: *f32, lo: f32, hi: f32) Response {
    const track = f.open(id, sliderTrack(th));
    const r = f.interact(track, .{ .hover = true, .click = true, .drag = true, .focus = true });
    // `heldRect` is this slider's last rect exactly when `r.held` is set.
    const rect = f.heldRect();
    value.* = base.slide(value.*, r.held, (f.in.pointer[0] - rect.x0) / @max(rect.w(), 1), lo, hi);
    if (r.focused) value.* = keyed(value.*, lo, hi, f.in) orelse value.*;
    _ = f.leaf(.none, sliderThumb(th, base.fraction(value.*, lo, hi)));
    f.close();
    f.tree().c.value[track.ix()] = value.*;
    return r;
}

/// The range of the slider named `id` in `t`, for assistive technology: `lo` to `hi`, stepped
/// by a hundredth of it as its arrow keys are (`keyed`). The application calls it after
/// building either front end's tree, with the slider's ends; a slider not in `t` is skipped.
pub fn semantics(t: *const Tree, s: *a11y.Semantics, id: Id, lo: f32, hi: f32) void {
    const r = t.find(id);
    if (r == types.none) return;
    s.c.range[0][r] = lo;
    s.c.range[1][r] = hi;
    s.c.range[2][r] = (hi - lo) / 100;
}

// ---- comptime front end ---------------------------------------------------------------------

pub const ct = struct {
    /// A slider named `id` over the `f32` field `bind`, running `range.lo` to `range.hi`:
    /// `ct.slider(th, .volume, .volume, .{ .hi = 100 })`; the range rides in its
    /// `Spec.widget` type. Ends that are equal or reversed are a compile error.
    pub fn slider(comptime th: Theme, comptime id: @EnumLiteral(), comptime bind: @EnumLiteral(), comptime range: Range) Spec {
        if (!(range.lo < range.hi)) @compileError(std.fmt.comptimePrint("slider '{s}': lo ({d}) must be below hi ({d})", .{ @tagName(id), range.lo, range.hi }));
        var s = spec_zig.row(sliderTrack(&th), .{Spec{ .kind = .col }});
        s.id = @tagName(id);
        s.bind = @tagName(bind);
        s.widget = Comptime(@tagName(id), @tagName(bind), range);
        return s;
    }
};

/// The comptime slider named `name` over field `bind`, running `range` (`Spec.widget`): the
/// same rows as `slider`, and the same input applied to the comptime front end's state: while
/// held the value follows the pointer across the track's last rect (`base.slide`), while
/// focused the keys move it (`keyed`).
pub fn Comptime(comptime name: [:0]const u8, comptime bind: []const u8, comptime range: Range) type {
    return struct {
        pub const focusable = true;

        pub fn bindError(comptime State: type, comptime field: []const u8) ?[]const u8 {
            return base.fieldError(State, "slider", field, Bind);
        }

        pub fn push(ui: anytype, comptime n: Spec, parent: u32, next: *u32, in: *const Input) void {
            _ = in;
            const t = &ui.tables.t;
            const value: f32 = @field(ui.signals.state, bind);
            var s = n.style;
            s.value = value;
            next.* += 2; // the track and its filled part
            const i = t.push(parent, .hash(name), &s);
            _ = t.push(i, .none, &sliderThumb(&@TypeOf(ui.*).theme, base.fraction(value, range.lo, range.hi)));
            t.seal(i);
        }

        pub fn step(ui: anytype, comptime row: u32, event: anytype, in: *const Input) void {
            const Ui = @TypeOf(ui.*);
            const r = base.ctResponse(ui, row, event, in);
            var v: f32 = @field(ui.signals.state, bind);
            if (r.held and ui.built) {
                // Last frame's tree is still in the tables while input is applied.
                const rect = ui.tables.t.rect(row + 1);
                v = base.slide(v, true, (in.pointer[0] - rect.x0) / @max(rect.w(), 1), range.lo, range.hi);
            }
            if (r.focused) v = keyed(v, range.lo, range.hi, in) orelse v;
            if (v != @field(ui.signals.state, bind)) ui.signals.set(Ui.field(bind), v);
        }
    };
}

// ---- example page -------------------------------------------------------------------------

/// The slider's example page: Volume (0..100) and Gain (-12..12), each under its label, on a
/// panel, in both front ends. Its replay (testdata/slider.replay) drags and uses the keys;
/// its golden images (tools/widgetgolden/ref/slider-*.png) show the fill following.
pub const Page = struct {
    const th = Theme.default;
    const panel: Style = .{ .dir = .y, .size = .{ .fill, .fill }, .pad = @splat(12), .gap = 8, .fill = th.panel };

    pub const App = struct {
        volume: f32 = 50,
        gain: f32 = 0,
        pub fn build(app: *App, f: *Frame) void {
            _ = f.open(.from("panel"), panel);
            _ = base.label(f, &th, "Volume");
            _ = slider(f, &th, .from("volume"), &app.volume, 0, 100);
            _ = base.label(f, &th, "Gain");
            _ = slider(f, &th, .from("gain"), &app.gain, -12, 12);
            f.close();
        }
    };
    pub const State = struct {
        volume_text: []const u8 = "Volume",
        volume: f32 = 50,
        gain_text: []const u8 = "Gain",
        gain: f32 = 0,
    };
    pub const spec = spec_zig.col(panel, .{
        base.ct.label(th, .volume_text),
        ct.slider(th, .volume, .volume, .{ .hi = 100 }),
        base.ct.label(th, .gain_text),
        ct.slider(th, .gain, .gain, .{ .lo = -12, .hi = 12 }),
    });
    pub const Ui = base.ComptimeUi(State, spec, th);
    pub const Run = base.Harness(App, Ui, .{ .nodes = 16, .texts = 4, .customs = 1, .strings = 256, .depth = 8 });

    /// The page's accessibility beyond the tree, for either front end's tree `t`: each slider
    /// labelled by the caption above it, and its range.
    pub fn semantics(t: *const Tree, s: *a11y.Semantics) void {
        const ends = [2][2]f32{ .{ 0, 100 }, .{ -12, 12 } };
        for ([2]Id{ .from("volume"), .from("gain") }, ends) |id, e| {
            const r = t.find(id);
            if (r == types.none) continue;
            s.c.labelled_by[r] = r - 1; // the caption is the row before
            rangeOf(t, s, id, e[0], e[1]);
        }
    }
    pub const replay = @embedFile("testdata/slider.replay");
    /// Frames kept as golden images, by name: tools/widgetgolden/ref/slider-<name>.png.
    pub const golden_frames = .{ .{ "rest", 0 }, .{ "pressed", 1 }, .{ "keys", 6 } };
};

// ---- tests ----------------------------------------------------------------------------------

const testing = std.testing;

test "bindError: a slider binds an f32" {
    const State = struct { v: f32 = 0, n: u32 = 0 };
    try testing.expectEqual(null, comptime bindError(State, "v"));
    try testing.expectEqualStrings("slider 'n' needs a f32 field, not u32", comptime bindError(State, "n").?);
}

test "ct.slider: a focusable widget whose f32 event is the pointer along the track; its range in the spec" {
    const events = @import("../comptime/events.zig");
    const s = comptime ct.slider(.default, .gain, .gain, .{ .lo = -12, .hi = 12 });
    try testing.expect(s.widget != null);
    const E = events.Events(s);
    try testing.expectEqual(1, E.widget_count);
}

/// A slider over -12..12 in both front ends: the comptime slider honours its range.
const Gain = struct {
    const th = Theme.default;
    const row: Style = .{ .dir = .x, .size = .{ .fill, .fit }, .pad = @splat(8) };
    pub const App = struct {
        gain: f32 = 6,
        pub fn build(app: *App, f: *Frame) void {
            _ = f.open(.from("row"), row);
            _ = slider(f, &th, .from("gain"), &app.gain, -12, 12);
            f.close();
        }
    };
    pub const State = struct { gain: f32 = 6 };
    pub const Ui = base.ComptimeUi(State, spec_zig.row(row, .{ct.slider(th, .gain, .gain, .{ .lo = -12, .hi = 12 })}), th);
    pub const Run = base.Harness(App, Ui, .{ .nodes = 16, .texts = 4, .customs = 1, .strings = 256, .depth = 8 });
};

var gain: Gain.Run = .{};

test "slider state: a comptime slider over -12..12 sets the same value as the runtime one" {
    const h = &gain;
    h.init();
    var in: Input = .{ .viewport = .{ 216, 40 } };
    var out = try h.frame(&in);
    // Track x 8..208; 6 dB is three quarters along.
    const track = out.runtime.tree.rect(2);
    try testing.expectEqual([2]f32{ 8, 208 }, [2]f32{ track.x0, track.x1 });
    try testing.expectApproxEqAbs(@as(f32, 150), out.runtime.tree.rect(3).w(), 0.5);
    in.pointer = .{ 58, (track.y0 + track.y1) * 0.5 };
    in.buttons.left = true;
    out = try h.frame(&in);
    try testing.expectEqual(@as(f32, -6), h.app.gain);
    try testing.expectEqual(@as(f32, -6), h.ui.signals.state.gain);
    try testing.expectEqual(@as(f32, -6), out.runtime.tree.c.value[2]);
}

test "slider look: an 8 px track filled to the value's fraction, in both front ends" {
    const h = &gain;
    h.init();
    const th = Theme.default;
    const in: Input = .{ .viewport = .{ 216, 40 } };
    const out = try h.frame(&in);
    const t = out.runtime.tree;
    const track = t.rect(2);
    try testing.expectEqual(@as(f32, 8), track.h());
    try testing.expectEqual(th.control.bitsOf(), t.c.look[2].fill);
    try testing.expectEqual(@as(f32, 4), t.c.look[2].radius);
    const thumb = t.rect(3);
    try testing.expectEqual(track.x0, thumb.x0);
    try testing.expectEqual(track.h(), thumb.h());
    try testing.expectApproxEqAbs(0.75 * track.w(), thumb.w(), 0.5);
    try testing.expectEqual(th.accent.bitsOf(), t.c.look[3].fill);
    // Too narrow a row still gives the track its minimum width.
    const S = struct {
        var small: Gain.Run = .{};
    };
    S.small.init();
    const narrow = try S.small.frame(&.{ .viewport = .{ 30, 40 } });
    try testing.expectEqual(@as(f32, 40), narrow.runtime.tree.rect(2).w());
}

test "keyed: arrows a hundredth, pages a tenth, Home and End the ends, clamped, in order" {
    const k = keys;
    const ev = struct {
        fn of(comptime codes: []const u8) Input {
            const list = comptime blk: {
                var l: [codes.len]Input.Event = undefined;
                for (&l, codes) |*e, c| e.* = .{ .kind = .press, .code = c };
                break :blk l;
            };
            return .{ .events = &list };
        }
    };
    try testing.expectEqual(null, keyed(5, 0, 10, &.{}));
    try testing.expectEqual(null, keyed(5, 0, 10, &ev.of(&.{k.enter})));
    try testing.expectEqual(@as(f32, 5.1), keyed(5, 0, 10, &ev.of(&.{k.right})).?);
    try testing.expectEqual(@as(f32, 5.1), keyed(5, 0, 10, &ev.of(&.{k.up})).?);
    try testing.expectEqual(@as(f32, 4.9), keyed(5, 0, 10, &ev.of(&.{k.left})).?);
    try testing.expectEqual(@as(f32, 6), keyed(5, 0, 10, &ev.of(&.{k.page_up})).?);
    try testing.expectEqual(@as(f32, 0), keyed(5, 0, 10, &ev.of(&.{k.home})).?);
    try testing.expectEqual(@as(f32, 10), keyed(9.95, 0, 10, &ev.of(&.{k.right})).?);
    try testing.expectEqual(@as(f32, 0.1), keyed(5, 0, 10, &ev.of(&.{ k.home, k.right })).?);
    try testing.expectEqual(@as(f32, 9), keyed(5, 0, 10, &ev.of(&.{ k.end, k.page_down })).?);
    const shifted = [_]Input.Event{.{ .kind = .press, .code = k.right, .mods = .{ .shift = true } }};
    try testing.expectEqual(null, keyed(5, 0, 10, &.{ .events = &shifted }));
}

test "slider input: drag, then arrows, Page Up, Home and End while focused, in both front ends" {
    const h = &gain;
    h.init();
    const k = keys;
    var in: Input = .{ .viewport = .{ 216, 40 } };
    _ = try h.frame(&in);
    // Press at a quarter (-6), drag to the right end and beyond (12), release.
    in.pointer = .{ 58, 12 }; // the track is y 8..16
    in.buttons.left = true;
    _ = try h.frame(&in);
    try testing.expectEqual(@as(f32, -6), h.app.gain);
    in.pointer = .{ 300, 12 };
    _ = try h.frame(&in);
    try testing.expectEqual(@as(f32, 12), h.app.gain);
    in.buttons.left = false;
    _ = try h.frame(&in);
    const Step = struct { code: u8, gain: f32 };
    for ([_]Step{
        .{ .code = k.left, .gain = 11.76 },
        .{ .code = k.page_down, .gain = 9.36 },
        .{ .code = k.home, .gain = -12 },
        .{ .code = k.down, .gain = -12 },
        .{ .code = k.end, .gain = 12 },
    }) |st| {
        const e = [_]Input.Event{.{ .kind = .press, .code = st.code }};
        in.events = &e;
        const out = try h.frame(&in);
        try testing.expectApproxEqAbs(st.gain, h.app.gain, 1e-4);
        try testing.expectEqual(h.app.gain, h.ui.signals.state.gain);
        try testing.expectEqual(h.app.gain, out.runtime.tree.c.value[2]);
    }
}

var slider_semantics: base.Semantic(16) = .{};

test "slider a11y: role slider, its value as the value, no states, in both front ends" {
    const h = &gain;
    h.init();
    const in: Input = .{ .viewport = .{ 216, 40 } };
    _ = try h.frame(&in);
    const x = &slider_semantics;
    try x.run(h);
    const r = x.row(2).?;
    try testing.expectEqual(@backingInt(a11y.Role.slider), x.out[0].c.role[r]);
    try testing.expectEqual(@backingInt(Id.from("gain")), x.out[0].c.id[r]);
    try testing.expectEqual(@as(f32, 6), x.out[0].c.value[r]);
    try testing.expectEqual(@as(u8, 0), x.out[0].c.state[r]);
    try testing.expectEqualStrings("", x.name(0, r));
    // The thumb is presentational: the root and the slider.
    try testing.expectEqual(null, x.row(3));
    try testing.expectEqual(@as(u32, 2), x.out[0].len);
}

var slider_range: [2]@import("popover.zig").Semantic(16) = .{ .{}, .{} };

test "slider a11y: its ends and key step as the exported range, in both front ends" {
    const popover = @import("popover.zig");
    const h = &gain;
    h.init();
    _ = try h.frame(&.{ .viewport = .{ 216, 40 } });
    const trees = [2]*const Tree{ &h.ctx.trees[h.ctx.cur], &h.ui.tables.t };
    for (trees, &slider_range) |t, *x| semantics(t, x.begin(), .from("gain"), -12, 12);
    const e = slider_range[0].finish(trees[0], &h.ctx.texts[h.ctx.cur], h.ctx.strings[h.ctx.cur].buf);
    const c = slider_range[1].finish(trees[1], &h.ui.tables.tx, h.ui.tables.strings.buf);
    try testing.expect(popover.sameSemantics(e, c));
    const r = popover.exportRow(e, trees[0].find(.from("gain")));
    for (0..3) |k| try testing.expectEqual(e.c.range[k][r], c.c.range[k][r]);
    try testing.expectEqual([3]f32{ -12, 12, 0.24 }, [3]f32{ e.c.range[0][r], e.c.range[1][r], e.c.range[2][r] });
    // Only the slider has one.
    try testing.expectEqual(@as(f32, 0), e.c.range[1][0]);
}

var page: Page.Run = .{};
var page_semantics: [2]@import("popover.zig").Semantic(16) = .{ .{}, .{} };

test "Page a11y: each slider named by its caption, with its range, in both front ends" {
    const popover = @import("popover.zig");
    const h = &page;
    h.init();
    _ = try h.frame(&.{ .viewport = .{ 320, 240 } });
    const trees = [2]*const Tree{ &h.ctx.trees[h.ctx.cur], &h.ui.tables.t };
    for (trees, &page_semantics) |t, *x| Page.semantics(t, x.begin());
    const strs = [2][]const u8{ h.ctx.strings[h.ctx.cur].buf, h.ui.tables.strings.buf };
    const e = page_semantics[0].finish(trees[0], &h.ctx.texts[h.ctx.cur], strs[0]);
    const c = page_semantics[1].finish(trees[1], &h.ui.tables.tx, strs[1]);
    try testing.expect(popover.sameSemantics(e, c));
    for ([2]Id{ .from("volume"), .from("gain") }, [2][]const u8{ "Volume", "Gain" }, [2]f32{ 100, 12 }) |id, want, hi| {
        const r = popover.exportRow(e, trees[0].find(id));
        try testing.expectEqualStrings(want, strs[0][e.c.name_start[r]..][0..e.c.name_bytes[r]]);
        try testing.expectEqualStrings(want, strs[1][c.c.name_start[r]..][0..c.c.name_bytes[r]]);
        try testing.expectEqual(hi, e.c.range[1][r]);
    }
}

test "Page: the slider replay drags and steps by keys, in both front ends" {
    const Replay = @import("../core/input.zig").Replay;
    const h = &page;
    h.init();
    var text: [16]u8 = undefined;
    var evs: [8]Input.Event = undefined;
    var contacts: [1]Input.Contact = undefined;
    const buf: Replay.Buffers = .{ .text = &text, .events = &evs, .contacts = &contacts };
    var replay: Replay = .{ .src = Page.replay };
    var volume: [11]f32 = undefined;
    var gain_: [11]f32 = undefined;
    while (try replay.next(buf)) |in| {
        const k = h.frames;
        _ = try h.frame(in);
        try testing.expectEqual(h.app.volume, h.ui.signals.state.volume);
        try testing.expectEqual(h.app.gain, h.ui.signals.state.gain);
        volume[k] = h.app.volume;
        gain_[k] = h.app.gain;
    }
    const t = &h.ctx.trees[h.ctx.cur];
    // The rects the replay's comment gives.
    try testing.expectEqual(types.Rect{ .x0 = 12, .y0 = 38, .x1 = 308, .y1 = 46 }, t.rect(t.find(.from("volume"))));
    try testing.expectEqual(types.Rect{ .x0 = 12, .y0 = 79, .x1 = 308, .y1 = 87 }, t.rect(t.find(.from("gain"))));
    try testing.expectEqual(@as(u32, 11), h.frames);
    const want_v = [11]f32{ 50, 25, 75, 100, 100, 99, 0, 0, 0, 0, 0 };
    const want_g = [11]f32{ 0, 0, 0, 0, 0, 0, 0, 0, 12, 9.6, 9.6 };
    for (want_v, volume, want_g, gain_) |wv, v, wg, g| {
        try testing.expectApproxEqAbs(wv, v, 1e-4);
        try testing.expectApproxEqAbs(wg, g, 1e-4);
    }
    inline for (Page.golden_frames) |g| try testing.expect(g[1] < 11);
}

test {
    testing.refAllDecls(@This());
    testing.refAllDecls(ct);
}
