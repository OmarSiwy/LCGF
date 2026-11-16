//! Progress bar (tier 2): how far a task has come, as a filled part of a track, in both front
//! ends. Follows the five-commit recipe of widgets/base.zig and is written against the public
//! API of tiers 0 and 1 only.
//!
//! State lives in the application: the fraction done (`f32`, 0 to 1, clamped when shown). The
//! bar takes no input: it has no id and senses nothing, so hit testing passes through it and
//! keyboard focus never stops on it.

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
const Node = types.Node;
const Style = types.Style;
const none = types.none;

// ---- spec ------------------------------------------------------------------------------------

/// Why `State` cannot back a comptime progress bar showing the field `value`; null when it can.
pub fn check(comptime State: type, comptime value: []const u8) ?[]const u8 {
    comptime {
        if (!@hasField(State, value)) return "progress: state has no field '" ++ value ++ "' for the fraction done";
        if (@FieldType(State, value) != f32) return "progress: field '" ++ value ++ "' must be an f32 (0 to 1)";
        return null;
    }
}

/// `check` as a compile error.
pub fn validate(comptime State: type, comptime value: []const u8) void {
    if (comptime check(State, value)) |msg| @compileError(msg);
}

// ---- comptime front end ---------------------------------------------------------------------

pub const ct = struct {
    /// A progress bar showing the f32 field `value`. No id: it is not a widget, so it is not in
    /// the comptime front end's `Widget` enum, hit table or focus order.
    pub fn progress(comptime th: Theme, comptime value: @EnumLiteral()) Spec {
        _ = th;
        var s = spec_zig.row(.{}, .{Spec{ .kind = .col }});
        s.bind = @tagName(value);
        return s;
    }
};

/// Whether spec node `n` is a progress bar made by `ct.progress`: a row bound to a field.
fn isProgress(comptime n: Spec) bool {
    return n.kind == .row and n.bind != null;
}

// ---- tests ----------------------------------------------------------------------------------

const testing = std.testing;
const theme: Theme = .default;
const Replay = @import("../core/input.zig").Replay;

test "check: what a comptime progress bar's state must have" {
    const Good = struct { v: f32 = 0 };
    const Bad = struct { v: u32 = 0 };
    try testing.expectEqual(null, comptime check(Good, "v"));
    try testing.expectEqualStrings("progress: state has no field 'x' for the fraction done", comptime check(Good, "x").?);
    try testing.expectEqualStrings("progress: field 'v' must be an f32 (0 to 1)", comptime check(Bad, "v").?);
}

test "ct.progress: a track and its bar, bound to the value, and not a widget" {
    const spec = comptime spec_zig.col(.{}, .{ ct.progress(theme, .done), ct.progress(theme, .other) });
    const E = events.Events(spec);
    try testing.expectEqual(0, E.widget_count);
    try testing.expectEqual(0, E.focus_order.len);
    try testing.expectEqualStrings("done", spec.children[0].bind.?);
    try testing.expectEqual(5, flatten.count(spec));
}

test {
    std.testing.refAllDecls(@This());
    std.testing.refAllDecls(ct);
}
