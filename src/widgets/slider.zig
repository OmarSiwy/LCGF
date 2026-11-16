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

// ---- spec -----------------------------------------------------------------------------------

/// The type of a slider's bound field.
pub const Bind = f32;

/// The ends of a comptime slider's value.
pub const Range = struct { lo: f32 = 0, hi: f32 = 1 };

/// Why `State`'s field `name` cannot be a slider's value, or null when it can.
pub fn bindError(comptime State: type, comptime name: []const u8) ?[]const u8 {
    return base.fieldError(State, "slider", name, Bind);
}

// ---- runtime front end ----------------------------------------------------------------------

/// A slider named `id` over `value`, from `lo` at the left end to `hi` at the right. While
/// held, the value follows the pointer across the track.
pub fn slider(f: *Frame, th: *const Theme, id: Id, value: *f32, lo: f32, hi: f32) Response {
    const track = f.open(id, base.sliderTrack(th));
    const r = f.interact(track, .{ .hover = true, .click = true, .drag = true, .focus = true });
    // `heldRect` is this slider's last rect exactly when `r.held` is set.
    const rect = f.heldRect();
    value.* = base.slide(value.*, r.held, (f.in.pointer[0] - rect.x0) / @max(rect.w(), 1), lo, hi);
    _ = f.leaf(.none, base.sliderThumb(th, base.fraction(value.*, lo, hi)));
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
        var s = spec_zig.row(base.sliderTrack(&th), .{Spec{ .kind = .col }});
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
const Style = types.Style;
const Input = @import("../core/input.zig").Input;

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

test {
    testing.refAllDecls(@This());
    testing.refAllDecls(ct);
}
