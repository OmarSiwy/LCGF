//! Range slider: two values between two ends, low and high, each set by its own thumb. Tier
//! 2, written against the public API of tiers 0 and 1 (the recipe in base.zig).
//!
//! State: the application's `[2]f32`, low then high, `lo <= low <= high <= hi`. The runtime
//! front end takes a pointer to it and the ends as arguments; the comptime front end binds a
//! `[2]f32` field (checked while compiling) and takes the ends as a `slider.Range`.
//!
//! Each thumb is a widget of its own, as the WAI-ARIA multi-thumb slider asks (a hit target
//! and a focus stop, named `<id>.0` and `<id>.1` in the comptime `Widget` enum, `id.with(0)`
//! and `id.with(1)` at run time): the half of the track nearer that thumb, split at the
//! midpoint between them, so a press grabs the nearer thumb.
//!
//! Accessibility: each thumb is a slider (its half has role slider), its value the thumb's
//! value; the track and the pieces are presentational. As for the slider, the application
//! sets each thumb's range with `semantics` (`aria-valuemin`/`max`, as the multi-thumb
//! pattern has them: each thumb stops at the other) and names each thumb
//! (`Semantics.labelled_by` or `Semantics.label`).

const std = @import("std");
const base = @import("base.zig");
const keys = @import("keys.zig");
const slider_zig = @import("slider.zig");
const types = @import("../core/types.zig");
const spec_zig = @import("../comptime/spec.zig");
const Spec = spec_zig.Spec;
const Theme = base.Theme;
const Id = types.Id;
const Style = types.Style;
const Color = types.Color;
const Response = types.Response;
const Tree = @import("../core/tree.zig").Tree;
const Frame = @import("../runtime/frame.zig").Frame;
const Input = @import("../core/input.zig").Input;
const a11y = @import("../a11y/tree.zig");

// ---- spec -----------------------------------------------------------------------------------

/// The type of a range slider's bound field: low, high.
pub const Bind = [2]f32;

/// Why `State`'s field `name` cannot be a range slider's values, or null when it can.
pub fn bindError(comptime State: type, comptime name: []const u8) ?[]const u8 {
    return base.fieldError(State, "range slider", name, Bind);
}

/// The id of thumb `index` (0 low, 1 high) of the range slider named `track`.
pub fn thumbId(track: Id, index: u32) Id {
    return track.with(index);
}

/// Spec (and tree) rows each thumb takes: the thumb's half of the track and its two pieces.
pub const thumb_rows = 3;

// ---- behaviour ------------------------------------------------------------------------------

/// `value` with thumb `i` moved to `to`, kept on its side of the other thumb: the low thumb
/// stops at the high one and the high at the low (APG multi-thumb slider: each thumb's range
/// ends at the other).
pub fn move(value: [2]f32, i: u1, to: f32) [2]f32 {
    var v = value;
    v[i] = if (i == 0) @min(to, value[1]) else @max(to, value[0]);
    return v;
}

/// The values after this frame's input on thumb `i`: while held it follows the pointer at
/// `along` (0 at the track's left end, 1 at its right, clamped); while focused the slider's
/// keys move it (`slider.keyed`, steps of the whole range); either way it stays on its side.
pub fn step(value: [2]f32, i: u1, held: bool, along: f32, focused: bool, lo: f32, hi: f32, in: *const Input) [2]f32 {
    var v = move(value, i, base.slide(value[i], held, along, lo, hi));
    if (focused) {
        if (slider_zig.keyed(v[i], lo, hi, in)) |k| v = move(v, i, k);
    }
    return v;
}

// ---- look -----------------------------------------------------------------------------------

/// The track: as a slider's (`slider.sliderTrack`) but no role of its own; its thumbs carry
/// the semantics.
pub fn trackStyle(th: *const Theme) Style {
    var s = slider_zig.sliderTrack(th);
    s.role = .none;
    return s;
}

/// The styles of the rows under the track, in row order, for thumbs at fractions `f0 <= f1`
/// of the track: low half (to the midpoint between the thumbs; role slider, as each thumb is), its outside piece, its part
/// of the span; high half, its part of the span, its outside piece. The span is the accent;
/// the outside pieces are transparent, so the track shows through.
pub fn parts(th: *const Theme, f0: f32, f1: f32) [2 * thumb_rows]Style {
    const mid = (f0 + f1) * 0.5;
    // The floors keep an empty half from dividing by zero; its pieces are then empty too.
    const low = f0 / @max(mid, 1e-6);
    const high = (f1 - mid) / @max(1 - mid, 1e-6);
    // One fraction per pair; its sibling grows into the rest.
    return .{
        .{ .dir = .x, .size = .{ .pct(mid), .fill }, .role = .slider },
        .{ .size = .{ .pct(low), .fill } },
        .{ .size = .{ .fill, .fill }, .fill = th.accent },
        .{ .dir = .x, .size = .{ .fill, .fill }, .role = .slider },
        .{ .size = .{ .pct(high), .fill }, .fill = th.accent },
        .{ .size = .{ .fill, .fill } },
    };
}

/// Writes the thumbs' value columns: each thumb's half holds its value. Both front ends call
/// it after building the track at tree row `track`.
pub fn expose(t: *Tree, track: u32, value: [2]f32) void {
    for (0..2) |i| t.c.value[track + 1 + thumb_rows * i] = value[i];
}

/// Each thumb's range for assistive technology, for the range slider named `id` in `t` over
/// `value` from `lo` to `hi`: the low thumb runs from `lo` to the high thumb's value, the high
/// thumb from the low thumb's value to `hi` (WAI-ARIA multi-thumb slider), both stepped as
/// the slider's keys are. Called by the application after building; thumbs not in `t` are
/// skipped.
pub fn semantics(t: *const Tree, s: *a11y.Semantics, id: Id, value: [2]f32, lo: f32, hi: f32) void {
    const ends = [2][2]f32{ .{ lo, value[1] }, .{ value[0], hi } };
    for (ends, 0..) |e, i| {
        const r = t.find(thumbId(id, @intCast(i)));
        if (r == types.none) continue;
        s.c.range[0][r] = e[0];
        s.c.range[1][r] = e[1];
        s.c.range[2][r] = (hi - lo) / 100;
    }
}

// ---- runtime front end ----------------------------------------------------------------------

/// A range slider named `id` over `value` (low, high), from `lo` at the left end to `hi` at
/// the right. A press grabs the nearer thumb (the half of the track it is in), which then
/// follows the pointer across the whole track; a focused thumb moves by the slider's keys.
pub fn range(f: *Frame, th: *const Theme, id: Id, value: *[2]f32, lo: f32, hi: f32) Response {
    // The thumbs' widths follow the values, so input is read before they are built:
    // `Interaction.response` is what `Frame.interact` returns for the same id this frame.
    const rect = f.lastRect(id);
    const along = (f.in.pointer[0] - rect.x0) / @max(rect.w(), 1);
    for (0..2) |i| {
        const r = f.ctx.inter.response(thumbId(id, @intCast(i)));
        value.* = step(value.*, @intCast(i), r.held, along, r.focused, lo, hi, f.in);
    }
    const track = f.open(id, trackStyle(th));
    const p = parts(th, base.fraction(value[0], lo, hi), base.fraction(value[1], lo, hi));
    var all: u8 = 0;
    for (0..2) |i| {
        const half = f.open(thumbId(id, @intCast(i)), p[thumb_rows * i]);
        all |= @bitCast(f.interact(half, .{ .hover = true, .click = true, .drag = true, .focus = true }));
        _ = f.leaf(.none, p[thumb_rows * i + 1]);
        _ = f.leaf(.none, p[thumb_rows * i + 2]);
        f.close();
    }
    f.close();
    expose(f.tree(), track.ix(), value.*);
    return @bitCast(all);
}

// ---- comptime front end ---------------------------------------------------------------------

pub const ct = struct {
    /// A range slider named `id` over the `[2]f32` field `bind`, running `range.lo` to
    /// `range.hi`: `ct.range(th, .band, .band, .{ .hi = 20_000 })`. Its thumbs are the widgets
    /// `<id>.0` and `<id>.1`; the track's `Spec.widget` type carries the range and applies the
    /// input. Equal or reversed ends are a compile error.
    pub fn range(comptime th: Theme, comptime id: @EnumLiteral(), comptime bind: @EnumLiteral(), comptime r: slider_zig.Range) Spec {
        if (!(r.lo < r.hi)) @compileError(std.fmt.comptimePrint("range slider '{s}': lo ({d}) must be below hi ({d})", .{ @tagName(id), r.lo, r.hi }));
        // Each half holds two pieces (what lies outside the span, and the span's part).
        const pieces = [2]Spec{ .{ .kind = .col }, .{ .kind = .col } };
        var thumbs: [2]Spec = undefined;
        for (&thumbs, 0..) |*t, i| t.* = .{
            .kind = .row,
            .id = thumbName(@tagName(id), i),
            .children = &pieces,
            .widget = base.FocusStop,
        };
        const final = thumbs;
        return .{
            .kind = .row,
            .bind = @tagName(bind),
            .style = trackStyle(&th),
            .children = &final,
            .widget = Comptime(@tagName(id), @tagName(bind), r),
        };
    }
};

/// The comptime name of thumb `index` of the range slider named `track`.
fn thumbName(comptime track: []const u8, comptime index: u32) [:0]const u8 {
    return std.fmt.comptimePrint("{s}.{d}", .{ track, index });
}

/// The comptime range slider named `name` over field `bind`, running `r` (`Spec.widget`): the
/// same rows as `range`, and the same input (`step`) applied to the comptime front end's
/// state, a held thumb following the pointer across the track's last rect.
pub fn Comptime(comptime name: [:0]const u8, comptime bind: []const u8, comptime r: slider_zig.Range) type {
    return struct {
        pub fn bindError(comptime State: type, comptime field: []const u8) ?[]const u8 {
            return base.fieldError(State, "range slider", field, Bind);
        }

        pub fn push(ui: anytype, comptime n: Spec, parent: u32, next: *u32, in: *const Input) void {
            _ = in;
            const t = &ui.tables.t;
            const value: [2]f32 = @field(ui.signals.state, bind);
            const track = t.push(parent, .hash(name), &n.style);
            const p = parts(&@TypeOf(ui.*).theme, base.fraction(value[0], r.lo, r.hi), base.fraction(value[1], r.lo, r.hi));
            for (0..2) |k| {
                const half = t.push(track, thumbId(.hash(name), @intCast(k)), &p[thumb_rows * k]);
                _ = t.push(half, .none, &p[thumb_rows * k + 1]);
                _ = t.push(half, .none, &p[thumb_rows * k + 2]);
                t.seal(half);
            }
            next.* += 1 + 2 * thumb_rows;
            t.seal(track);
            expose(t, track, value);
        }

        pub fn step(ui: anytype, comptime row: u32, event: anytype, in: *const Input) void {
            const Ui = @TypeOf(ui.*);
            const now: [2]f32 = @field(ui.signals.state, bind);
            var v = now;
            inline for (0..2) |i| {
                const res = base.ctResponse(ui, row + 1 + thumb_rows * i, event, in);
                var along: f32 = 0;
                if (res.held and ui.built) {
                    // Last frame's tree is still in the tables while input is applied.
                    const rect = ui.tables.t.rect(row + 1);
                    along = (in.pointer[0] - rect.x0) / @max(rect.w(), 1);
                }
                v = step_(v, i, res.held, along, res.focused, r.lo, r.hi, in);
            }
            if (!std.meta.eql(v, now)) ui.signals.set(Ui.field(bind), v);
        }
    };
}

const step_ = step;

// ---- example page -------------------------------------------------------------------------

/// The range slider's example page: a frequency band (20..200) under its label on a panel, in
/// both front ends. Its replay (testdata/range.replay) drags each thumb and uses the keys; its
/// golden images (tools/widgetgolden/ref/range-*.png) show the span moving.
pub const Page = struct {
    const th = Theme.default;
    const panel: Style = .{ .dir = .y, .size = .{ .fill, .fill }, .pad = @splat(12), .gap = 8, .fill = th.panel };

    pub const App = struct {
        band: [2]f32 = .{ 60, 140 },
        pub fn build(app: *App, f: *Frame) void {
            _ = f.open(.from("panel"), panel);
            _ = base.label(f, &th, "Frequency");
            _ = range(f, &th, .from("band"), &app.band, 20, 200);
            f.close();
        }
    };
    pub const State = struct { band_text: []const u8 = "Frequency", band: [2]f32 = .{ 60, 140 } };
    pub const spec = spec_zig.col(panel, .{ base.ct.label(th, .band_text), ct.range(th, .band, .band, .{ .lo = 20, .hi = 200 }) });
    pub const Ui = base.ComptimeUi(State, spec, th);
    pub const Run = base.Harness(App, Ui, .{ .nodes = 16, .texts = 4, .customs = 1, .strings = 256, .depth = 8 });
    pub const replay = @embedFile("testdata/range.replay");
    /// Frames kept as golden images, by name: tools/widgetgolden/ref/range-<name>.png.
    pub const golden_frames = .{ .{ "rest", 0 }, .{ "dragged", 2 }, .{ "keys", 6 } };
};

// ---- tests ----------------------------------------------------------------------------------

const testing = std.testing;

test "bindError: a range slider binds a [2]f32" {
    const State = struct { band: [2]f32 = .{ 0, 1 }, v: f32 = 0 };
    try testing.expectEqual(null, comptime bindError(State, "band"));
    try testing.expectEqualStrings("range slider 'v' needs a [2]f32 field, not f32", comptime bindError(State, "v").?);
}

test "ct.range: two thumb widgets, focus stops of their own; the track binds the field" {
    const events = @import("../comptime/events.zig");
    const s = comptime ct.range(.default, .band, .band, .{ .lo = 20, .hi = 200 });
    try testing.expect(s.widget != null);
    try testing.expectEqual(null, s.id);
    try testing.expectEqualStrings("band", s.bind.?);
    inline for (s.children, 0..) |t, i| {
        try testing.expectEqualStrings(comptime thumbName("band", i), t.id.?);
        try testing.expect(t.widget.?.focusable);
        try testing.expectEqual(@as(usize, thumb_rows - 1), t.children.len);
    }
    const E = events.Events(s);
    try testing.expectEqual(2, E.widget_count);
}

test "thumbId: the two thumbs and the track have distinct ids" {
    const t = Id.from("band");
    try testing.expect(thumbId(t, 0) != thumbId(t, 1));
    try testing.expect(thumbId(t, 0) != t and thumbId(t, 1) != t);
}

/// A band over 0..100 in both front ends, in theme `th`: the tests' page until the example
/// page (C0565).
fn Band(comptime th: Theme) type {
    return struct {
        const row: Style = .{ .dir = .x, .size = .{ .fill, .fit }, .pad = @splat(8) };
        pub const App = struct {
            band: [2]f32 = .{ 20, 60 },
            pub fn build(app: *App, f: *Frame) void {
                _ = f.open(.from("row"), row);
                _ = range(f, &th, .from("band"), &app.band, 0, 100);
                f.close();
            }
        };
        pub const State = struct { band: [2]f32 = .{ 20, 60 } };
        pub const Ui = base.ComptimeUi(State, spec_zig.row(row, .{ct.range(th, .band, .band, .{ .hi = 100 })}), th);
        pub const Run = base.Harness(App, Ui, .{ .nodes = 16, .texts = 4, .customs = 1, .strings = 256, .depth = 8 });
    };
}

var band: Band(.default).Run = .{};

test "range look: the track split at the thumbs' midpoint, the span between them in the accent, in both front ends" {
    const h = &band;
    h.init();
    const th = Theme.default;
    const in: Input = .{ .viewport = .{ 216, 40 } };
    const out = try h.frame(&in);
    const t = out.runtime.tree;
    // Rows: root, row, track (2), low half (3) and its pieces, high half (6) and its pieces.
    const track = t.rect(2);
    try testing.expectEqual(types.Rect{ .x0 = 8, .y0 = 8, .x1 = 208, .y1 = 16 }, track);
    try testing.expectEqual(th.control.bitsOf(), t.c.look[2].fill);
    // Thumbs at 20 and 60 of 0..100: x 48 and 128; the halves meet at 88.
    try testing.expectEqual([2]f32{ 8, 88 }, [2]f32{ t.rect(3).x0, t.rect(3).x1 });
    try testing.expectEqual([2]f32{ 88, 208 }, [2]f32{ t.rect(6).x0, t.rect(6).x1 });
    try testing.expectEqual([2]f32{ 48, 88 }, [2]f32{ t.rect(5).x0, t.rect(5).x1 });
    try testing.expectEqual([2]f32{ 88, 128 }, [2]f32{ t.rect(7).x0, t.rect(7).x1 });
    try testing.expectEqual(th.accent.bitsOf(), t.c.look[5].fill);
    try testing.expectEqual(th.accent.bitsOf(), t.c.look[7].fill);
    try testing.expectEqual(Color.transparent.bitsOf(), t.c.look[4].fill);
    // Quads: the track and the span's two parts.
    try testing.expectEqual(@as(u32, 3), out.runtime.draw.quad_len);
}

test "parts: thumbs together at an end leave no division by zero" {
    const th = Theme.default;
    for ([_][2]f32{ .{ 0, 0 }, .{ 1, 1 }, .{ 0, 1 } }) |f| {
        const p = parts(&th, f[0], f[1]);
        for (p) |s| for (s.size) |z| try testing.expect(std.math.isFinite(z.v));
    }
}

test "move, step: thumbs follow the pointer or the keys and never cross" {
    const k = keys;
    try testing.expectEqual([2]f32{ 30, 60 }, move(.{ 20, 60 }, 0, 30));
    try testing.expectEqual([2]f32{ 60, 60 }, move(.{ 20, 60 }, 0, 90));
    try testing.expectEqual([2]f32{ 20, 20 }, move(.{ 20, 60 }, 1, 5));
    const none: Input = .{};
    try testing.expectEqual([2]f32{ 50, 60 }, step(.{ 20, 60 }, 0, true, 0.5, false, 0, 100, &none));
    try testing.expectEqual([2]f32{ 20, 60 }, step(.{ 20, 60 }, 0, false, 0.5, false, 0, 100, &none));
    const end = [_]Input.Event{.{ .kind = .press, .code = k.end }};
    try testing.expectEqual([2]f32{ 60, 60 }, step(.{ 20, 60 }, 0, false, 0, true, 0, 100, &.{ .events = &end }));
    try testing.expectEqual([2]f32{ 20, 100 }, step(.{ 20, 60 }, 1, false, 0, true, 0, 100, &.{ .events = &end }));
    const left = [_]Input.Event{.{ .kind = .press, .code = k.left }};
    try testing.expectEqual([2]f32{ 19, 60 }, step(.{ 20, 60 }, 0, false, 0, true, 0, 100, &.{ .events = &left }));
}

test "range input: a press grabs the nearer thumb, drags across the track; arrows per thumb, in both front ends" {
    const h = &band;
    h.init();
    const k = keys;
    var in: Input = .{ .viewport = .{ 216, 40 } };
    _ = try h.frame(&in);
    const Step = struct { x: f32, left: bool, key: ?u8 = null, band: [2]f32 };
    const steps = [_]Step{
        .{ .x = 28, .left = true, .band = .{ 10, 60 } }, // press in the low half: low thumb to 10
        .{ .x = 108, .left = true, .band = .{ 50, 60 } }, // dragged right
        .{ .x = 200, .left = true, .band = .{ 60, 60 } }, // past the high thumb: stops at it
        .{ .x = 200, .left = false, .band = .{ 60, 60 } },
        .{ .x = 200, .left = false, .key = k.left, .band = .{ 59, 60 } }, // the focused low thumb
        .{ .x = 188, .left = true, .band = .{ 59, 90 } }, // press in the high half
        .{ .x = 188, .left = false, .key = k.home, .band = .{ 59, 59 } }, // Home: down to the low thumb
        .{ .x = 188, .left = false, .key = k.end, .band = .{ 59, 100 } },
    };
    for (steps) |st| {
        in.pointer = .{ st.x, 12 };
        in.buttons.left = st.left;
        const e = [_]Input.Event{.{ .kind = .press, .code = st.key orelse 0 }};
        in.events = if (st.key != null) &e else &.{};
        const out = try h.frame(&in);
        for (0..2) |i| {
            try testing.expectApproxEqAbs(st.band[i], h.app.band[i], 1e-4);
            try testing.expectEqual(h.app.band[i], h.ui.signals.state.band[i]);
            try testing.expectEqual(h.app.band[i], out.runtime.tree.c.value[3 + thumb_rows * i]);
        }
    }
}

var range_semantics: base.Semantic(16) = .{};

test "range a11y: two sliders, each with its thumb's value, in both front ends" {
    const h = &band;
    h.init();
    const in: Input = .{ .viewport = .{ 216, 40 } };
    _ = try h.frame(&in);
    const x = &range_semantics;
    try x.run(h);
    for (0..2, [2]f32{ 20, 60 }) |i, v| {
        const r = x.row(3 + thumb_rows * @as(u32, @intCast(i))).?;
        try testing.expectEqual(@backingInt(a11y.Role.slider), x.out[0].c.role[r]);
        try testing.expectEqual(@backingInt(thumbId(.from("band"), @intCast(i))), x.out[0].c.id[r]);
        try testing.expectEqual(v, x.out[0].c.value[r]);
        try testing.expectEqual(@as(u8, 0), x.out[0].c.state[r]);
    }
    // The track and pieces are presentational: the root and two thumbs.
    try testing.expectEqual(null, x.row(2));
    try testing.expectEqual(@as(u32, 3), x.out[0].len);
}

var range_ranges: [2]@import("popover.zig").Semantic(16) = .{ .{}, .{} };

test "range a11y: each thumb's range ends at the other thumb, in both front ends" {
    const popover = @import("popover.zig");
    const h = &band;
    h.init();
    _ = try h.frame(&.{ .viewport = .{ 216, 40 } });
    const trees = [2]*const Tree{ &h.ctx.trees[h.ctx.cur], &h.ui.tables.t };
    for (trees, &range_ranges) |t, *x| semantics(t, x.begin(), .from("band"), .{ 20, 60 }, 0, 100);
    const e = range_ranges[0].finish(trees[0], &h.ctx.texts[h.ctx.cur], h.ctx.strings[h.ctx.cur].buf);
    const c = range_ranges[1].finish(trees[1], &h.ui.tables.tx, h.ui.tables.strings.buf);
    try testing.expect(popover.sameSemantics(e, c));
    const want = [2][3]f32{ .{ 0, 60, 1 }, .{ 20, 100, 1 } };
    for (want, 0..) |w, i| {
        const r = popover.exportRow(e, trees[0].find(thumbId(.from("band"), @intCast(i))));
        try testing.expectEqual(w, [3]f32{ e.c.range[0][r], e.c.range[1][r], e.c.range[2][r] });
        try testing.expectEqual(w, [3]f32{ c.c.range[0][r], c.c.range[1][r], c.c.range[2][r] });
    }
}

var page: Page.Run = .{};

test "Page: the range replay drags each thumb and steps by keys, in both front ends" {
    const Replay = @import("../core/input.zig").Replay;
    const h = &page;
    h.init();
    var text: [16]u8 = undefined;
    var evs: [8]Input.Event = undefined;
    var contacts: [1]Input.Contact = undefined;
    const buf: Replay.Buffers = .{ .text = &text, .events = &evs, .contacts = &contacts };
    var replay: Replay = .{ .src = Page.replay };
    var got: [8][2]f32 = undefined;
    while (try replay.next(buf)) |in| {
        const k = h.frames;
        _ = try h.frame(in);
        try testing.expectEqual(h.app.band, h.ui.signals.state.band);
        got[k] = h.app.band;
    }
    try testing.expectEqual(@as(u32, 8), h.frames);
    const want = [8][2]f32{ .{ 60, 140 }, .{ 65, 140 }, .{ 110, 140 }, .{ 110, 140 }, .{ 111.8, 140 }, .{ 111.8, 155 }, .{ 111.8, 200 }, .{ 111.8, 111.8 } };
    for (want, got) |w, g| for (w, g) |a, b| try testing.expectApproxEqAbs(a, b, 1e-3);
    const t = &h.ctx.trees[h.ctx.cur];
    try testing.expectEqual(types.Rect{ .x0 = 12, .y0 = 38, .x1 = 308, .y1 = 46 }, t.rect(t.find(.from("band"))));
    inline for (Page.golden_frames) |g| try testing.expect(g[1] < 8);
}

test {
    testing.refAllDecls(@This());
    testing.refAllDecls(ct);
}
