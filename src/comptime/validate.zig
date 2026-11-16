//! Validate: mistakes in a comptime spec become compile errors, before anything is flattened.
//! Tier 1. Ported from prototype/comptime_ui_probe.zig (the `@compileError` checks in
//! `Ui().flatten`), gathered into one walk so every front-end table can assume a valid spec.
//!
//! Each rule has a compile-fail case under src/comptime/compile_fail/; a spec that breaks no rule
//! compiles, which the tests below show for the probe's mixer.

const std = @import("std");
const spec_zig = @import("spec.zig");
const Spec = spec_zig.Spec;

/// Fails compilation with a message naming the first broken rule. Rules: widget ids are unique.
pub fn check(comptime spec: Spec) void {
    comptime {
        var ids: []const [:0]const u8 = &.{};
        walk(spec, &ids);
    }
}

fn walk(comptime s: Spec, comptime ids: *[]const [:0]const u8) void {
    // ponytail: ids are compared pairwise, O(ids^2) comptime work; a UI has tens of ids.
    @setEvalBranchQuota(1000 + 10 * ids.len * ids.len);
    if (s.id) |name| {
        for (ids.*) |seen| if (std.mem.eql(u8, seen, name)) @compileError("duplicate widget id '" ++ name ++ "'");
        ids.* = ids.* ++ [_][:0]const u8{name};
    }
    for (s.children) |c| walk(c, ids);
}

// ---- tests -------------------------------------------------------------------------------------

const col = spec_zig.col;
const row = spec_zig.row;
const label = spec_zig.label;
const checkbox = spec_zig.checkbox;
const slider = spec_zig.slider;

/// The probe's usage spec.
const mixer = col(.{ .pad = @splat(8), .gap = 4 }, .{
    label(.title),
    row(.{ .gap = 8 }, .{ checkbox(.mute, .muted), slider(.volume, .volume) }),
    row(.{ .gap = 8 }, .{ label(.title), slider(.pan, .pan) }),
});

test "check: the probe's mixer breaks no rule" {
    comptime check(mixer);
    // Two labels bound to one field are not a duplicate: only ids must be unique.
    comptime check(col(.{}, .{ label(.title), label(.title) }));
}
