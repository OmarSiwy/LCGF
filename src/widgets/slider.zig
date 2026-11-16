//! Slider: a value between two ends, set by dragging along a track. Tier 2, written against
//! the public API of tiers 0 and 1 (the recipe in base.zig).
//!
//! State: the application's `f32`, between `lo` and `hi`. The runtime front end takes a
//! pointer to it and the ends as arguments; the comptime front end binds an `f32` field
//! (checked while compiling) and takes the ends as a `Range`, carried in the spec node
//! (`Spec.lo`, `Spec.hi`), so a comptime slider is no longer fixed to 0..1.

const std = @import("std");
const base = @import("base.zig");
const types = @import("../core/types.zig");
const spec_zig = @import("../comptime/spec.zig");
const Frame = @import("../runtime/frame.zig").Frame;
const Spec = spec_zig.Spec;
const Theme = base.Theme;
const Id = types.Id;
const Response = types.Response;
const Style = types.Style;
const Input = @import("../core/input.zig").Input;

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
    const k = base.keys;
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

// ---- comptime front end ---------------------------------------------------------------------

pub const ct = struct {
    /// A slider named `id` over the `f32` field `bind`, running `range.lo` to `range.hi`:
    /// `ct.slider(th, .volume, .volume, .{ .hi = 100 })`. Its event carries where the pointer
    /// is along the track, 0 to 1. Ends that are equal or reversed are a compile error.
    pub fn slider(comptime th: Theme, comptime id: @EnumLiteral(), comptime bind: @EnumLiteral(), comptime range: Range) Spec {
        if (!(range.lo < range.hi)) @compileError(std.fmt.comptimePrint("slider '{s}': lo ({d}) must be below hi ({d})", .{ @tagName(id), range.lo, range.hi }));
        var s = spec_zig.row(sliderTrack(&th), .{Spec{ .kind = .col }});
        s.kind = .slider;
        s.id = @tagName(id);
        s.bind = @tagName(bind);
        s.lo = range.lo;
        s.hi = range.hi;
        return s;
    }
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
    try testing.expectEqual(spec_zig.Kind.slider, s.kind);
    try testing.expectEqual([2]f32{ -12, 12 }, [2]f32{ s.lo, s.hi });
    try testing.expectEqual([2]f32{ 0, 1 }, [2]f32{ (comptime ct.slider(.default, .a, .a, .{})).lo, (comptime ct.slider(.default, .a, .a, .{})).hi });
    const E = events.Events(s);
    try testing.expectEqual(f32, @FieldType(E.Event, "gain"));
    try testing.expectEqualSlices(E.Widget, &.{.gain}, E.focus_order);
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
    const k = base.keys;
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
    const k = base.keys;
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

test {
    testing.refAllDecls(@This());
    testing.refAllDecls(ct);
}
