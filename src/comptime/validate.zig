//! Validate: mistakes in a comptime spec become compile errors, before anything is flattened.
//! Tier 1. Ported from prototype/comptime_ui_probe.zig (the `@compileError` checks in
//! `Ui().flatten`), gathered into one walk so every front-end table can assume a valid spec.
//!
//! Each rule has a compile-fail case under src/comptime/compile_fail/; a spec that breaks no rule
//! compiles, which the tests below show for the probe's mixer.

const std = @import("std");
const spec_zig = @import("spec.zig");
const Spec = spec_zig.Spec;

/// Fails compilation with a message naming the first broken rule of `spec` over the state
/// struct `State`. Rules: widget ids are unique; a slider binds an f32 field and a checkbox a
/// bool field; every binding names a field of `State`.
pub fn check(comptime State: type, comptime spec: Spec) void {
    comptime {
        if (@typeInfo(State) != .@"struct") @compileError("state must be a struct, not " ++ @typeName(State));
        var ids: []const [:0]const u8 = &.{};
        walk(State, spec, &ids);
    }
}

/// The state type a widget kind's binding needs; null for kinds that show any field.
fn bindType(comptime kind: spec_zig.Kind) ?type {
    return switch (kind) {
        .slider => f32,
        .checkbox => bool,
        .col, .row, .label => null,
    };
}

/// `@hasField` also accepts a struct's declarations; a binding needs a field.
fn hasField(comptime State: type, comptime name: []const u8) bool {
    for (@typeInfo(State).@"struct".field_names) |f| if (std.mem.eql(u8, f, name)) return true;
    return false;
}

fn walk(comptime State: type, comptime s: Spec, comptime ids: *[]const [:0]const u8) void {
    // ponytail: ids are compared pairwise, O(ids^2) comptime work; a UI has tens of ids.
    @setEvalBranchQuota(1000 + 10 * ids.len * ids.len);
    if (s.id) |name| {
        for (ids.*) |seen| if (std.mem.eql(u8, seen, name)) @compileError("duplicate widget id '" ++ name ++ "'");
        ids.* = ids.* ++ [_][:0]const u8{name};
    }
    if (s.bind) |field| {
        if (!hasField(State, field)) @compileError("state " ++ @typeName(State) ++ " has no field '" ++ field ++ "'");
    }
    if (s.bind) |field| if (bindType(s.kind)) |T| {
        const FT = @FieldType(State, field);
        if (FT != T) @compileError(@tagName(s.kind) ++ " '" ++ field ++ "' needs " ++ (if (T == f32) "an " else "a ") ++ @typeName(T) ++ " field, not " ++ @typeName(FT));
    };
    for (s.children) |c| walk(State, c, ids);
}

// ---- tests -------------------------------------------------------------------------------------

const col = spec_zig.col;
const row = spec_zig.row;
const label = spec_zig.label;
const checkbox = spec_zig.checkbox;
const slider = spec_zig.slider;

/// The probe's state struct and usage spec.
const Mixer = struct { title: []const u8 = "Mixer", volume: f32 = 0.5, muted: bool = false, pan: f32 = 0 };

const mixer = col(.{ .pad = @splat(8), .gap = 4 }, .{
    label(.title),
    row(.{ .gap = 8 }, .{ checkbox(.mute, .muted), slider(.volume, .volume) }),
    row(.{ .gap = 8 }, .{ label(.title), slider(.pan, .pan) }),
});

test "check: the probe's mixer breaks no rule" {
    comptime check(Mixer, mixer);
    // Two labels bound to one field are not a duplicate: only ids must be unique.
    comptime check(Mixer, col(.{}, .{ label(.title), label(.title) }));
    // A label shows a field of any type.
    comptime check(Mixer, col(.{}, .{ label(.volume), label(.muted) }));
}
