//! Spinner (tier 2): an indeterminate progress indicator, a ring of dots whose bright head
//! goes round while the application is busy, in both front ends. Follows the five-commit recipe
//! of widgets/base.zig and is written against the public API of tiers 0 and 1 only.
//!
//! State lives in the application: whether it is busy (`bool`). The animation is a pure
//! function of `Input.time`, so a replay draws the same frames every run and both front ends
//! agree; the runtime front end arms a repeating timer while busy so an idle host still wakes
//! for each step. The spinner takes no input: it has no widget id and senses nothing.

const std = @import("std");
const types = @import("../core/types.zig");
const Tree = @import("../core/tree.zig").Tree;
const Input = @import("../core/input.zig").Input;
const DrawList = @import("../draw/draw_list.zig").DrawList;
const Mono = @import("../text/protocol.zig").Mono;
const Frame = @import("../runtime/frame.zig").Frame;
const context = @import("../runtime/context.zig");
const spec_zig = @import("../comptime/spec.zig");
const events = @import("../comptime/events.zig");
const signals = @import("../comptime/signals.zig");
const flatten = @import("../comptime/flatten.zig");
const a11y = @import("../a11y/tree.zig");
const hit = @import("../interact/hit.zig");
const base = @import("base.zig");
const list_zig = @import("list.zig");
const Spec = spec_zig.Spec;
const Theme = base.Theme;
const Id = types.Id;
const Node = types.Node;
const Color = types.Color;
const Style = types.Style;
const none = types.none;

// ---- spec ------------------------------------------------------------------------------------

/// Dots in the ring.
pub const dots = 8;
/// Steps the head takes per second.
pub const steps_per_second = 12;

/// Why `State` cannot back a comptime spinner shown while the field `busy` is set; null when it
/// can.
pub fn check(comptime State: type, comptime busy: []const u8) ?[]const u8 {
    comptime {
        if (!@hasField(State, busy)) return "spinner: state has no field '" ++ busy ++ "' for busy";
        if (@FieldType(State, busy) != bool) return "spinner: field '" ++ busy ++ "' must be a bool";
        return null;
    }
}

/// `check` as a compile error.
pub fn validate(comptime State: type, comptime busy: []const u8) void {
    if (comptime check(State, busy)) |msg| @compileError(msg);
}

/// The dot the head is on at `time` seconds.
pub fn phase(time: f64) u32 {
    const step: u64 = @intFromFloat(@floor(@max(time, 0) * steps_per_second));
    return @intCast(step % dots);
}

// ---- comptime front end ---------------------------------------------------------------------

pub const ct = struct {
    /// A spinner turning while the bool field `busy` is set. No id: it is not a widget.
    pub fn spinner(comptime th: Theme, comptime busy: @EnumLiteral()) Spec {
        _ = th;
        const ring: [dots]Spec = @splat(.{ .kind = .col });
        var s = spec_zig.col(.{}, ring);
        s.bind = @tagName(busy);
        return s;
    }
};

/// Whether spec node `n` is a spinner made by `ct.spinner`: a column bound to a field.
fn isSpinner(comptime n: Spec) bool {
    return n.kind == .col and n.bind != null;
}

// ---- tests ----------------------------------------------------------------------------------

const testing = std.testing;
const theme: Theme = .default;
const Replay = @import("../core/input.zig").Replay;

test "check: what a comptime spinner's state must have" {
    const Good = struct { b: bool = false };
    const Bad = struct { b: u8 = 0 };
    try testing.expectEqual(null, comptime check(Good, "b"));
    try testing.expectEqualStrings("spinner: state has no field 'x' for busy", comptime check(Good, "x").?);
    try testing.expectEqualStrings("spinner: field 'b' must be a bool", comptime check(Bad, "b").?);
}

test "ct.spinner: a ring of dots bound to busy, and not a widget" {
    const spec = comptime spec_zig.row(.{}, .{ct.spinner(theme, .busy)});
    try testing.expectEqual(0, events.Events(spec).widget_count);
    try testing.expectEqual(2 + dots, flatten.count(spec));
    try testing.expectEqualStrings("busy", spec.children[0].bind.?);
}

test "phase: 12 steps a second, around the ring" {
    try testing.expectEqual(@as(u32, 0), phase(0));
    try testing.expectEqual(@as(u32, 0), phase(0.08));
    try testing.expectEqual(@as(u32, 1), phase(0.09));
    try testing.expectEqual(@as(u32, 7), phase(7.0 / 12.0 + 0.001));
    try testing.expectEqual(@as(u32, 0), phase(8.0 / 12.0 + 0.001));
    try testing.expectEqual(@as(u32, 0), phase(-5));
}

test {
    std.testing.refAllDecls(@This());
    std.testing.refAllDecls(ct);
}
