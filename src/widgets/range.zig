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

const std = @import("std");
const base = @import("base.zig");
const slider_zig = @import("slider.zig");
const types = @import("../core/types.zig");
const spec_zig = @import("../comptime/spec.zig");
const Spec = spec_zig.Spec;
const Theme = base.Theme;
const Id = types.Id;

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

// ---- comptime front end ---------------------------------------------------------------------

pub const ct = struct {
    /// A range slider named `id` over the `[2]f32` field `bind`, running `range.lo` to
    /// `range.hi`: `ct.range(th, .band, .band, .{ .hi = 20_000 })`. Its thumbs are the widgets
    /// `<id>.0` and `<id>.1`; their `f32` events carry the pointer along the thumb's half.
    /// Equal or reversed ends are a compile error.
    pub fn range(comptime th: Theme, comptime id: @EnumLiteral(), comptime bind: @EnumLiteral(), comptime r: slider_zig.Range) Spec {
        _ = th;
        if (!(r.lo < r.hi)) @compileError(std.fmt.comptimePrint("range slider '{s}': lo ({d}) must be below hi ({d})", .{ @tagName(id), r.lo, r.hi }));
        // Each half holds two pieces (what lies outside the span, and the span's part).
        const pieces = [2]Spec{ .{ .kind = .col }, .{ .kind = .col } };
        var thumbs: [2]Spec = undefined;
        for (&thumbs, 0..) |*t, i| t.* = .{
            .kind = .range_thumb,
            .id = std.fmt.comptimePrint("{s}.{d}", .{ @tagName(id), i }),
            .bind = @tagName(bind),
            .index = i,
            .lo = r.lo,
            .hi = r.hi,
            .children = &pieces,
        };
        const final = thumbs;
        return .{ .kind = .range, .id = null, .bind = @tagName(bind), .lo = r.lo, .hi = r.hi, .children = &final };
    }

    /// The track's name from a thumb's comptime name `<id>.<index>`.
    pub fn trackName(comptime thumb: []const u8) []const u8 {
        return thumb[0..comptime std.mem.lastIndexOfScalar(u8, thumb, '.').?];
    }
};

// ---- tests ----------------------------------------------------------------------------------

const testing = std.testing;

test "bindError: a range slider binds a [2]f32" {
    const State = struct { band: [2]f32 = .{ 0, 1 }, v: f32 = 0 };
    try testing.expectEqual(null, comptime bindError(State, "band"));
    try testing.expectEqualStrings("range slider 'v' needs a [2]f32 field, not f32", comptime bindError(State, "v").?);
}

test "ct.range: two focusable thumb widgets with f32 events, the range in every node" {
    const events = @import("../comptime/events.zig");
    const s = comptime ct.range(.default, .band, .band, .{ .lo = 20, .hi = 200 });
    try testing.expectEqual(spec_zig.Kind.range, s.kind);
    try testing.expectEqual(null, s.id);
    try testing.expectEqual([2]f32{ 20, 200 }, [2]f32{ s.lo, s.hi });
    inline for (s.children, 0..) |t, i| {
        try testing.expectEqual(spec_zig.Kind.range_thumb, t.kind);
        try testing.expectEqual(@as(u32, i), t.index);
        try testing.expectEqualStrings("band", t.bind.?);
        try testing.expectEqualStrings("band", comptime ct.trackName(t.id.?));
        try testing.expectEqual(@as(usize, thumb_rows - 1), t.children.len);
    }
    const E = events.Events(s);
    try testing.expectEqual(f32, @FieldType(E.Event, "band.0"));
    try testing.expectEqualSlices(E.Widget, &.{ .@"band.0", .@"band.1" }, E.focus_order);
}

test "thumbId: the two thumbs and the track have distinct ids" {
    const t = Id.from("band");
    try testing.expect(thumbId(t, 0) != thumbId(t, 1));
    try testing.expect(thumbId(t, 0) != t and thumbId(t, 1) != t);
}

test {
    testing.refAllDecls(@This());
    testing.refAllDecls(ct);
}
