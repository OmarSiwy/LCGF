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
///
/// Every message about a node starts with its spec path: the root's kind, then the kind and
/// child position of each node down to it, as in `col > row[1] > slider[0]: ...` (the first
/// child of the root's second child). Positions count from 0, as in `children[i]`.
pub fn check(comptime State: type, comptime spec: Spec) void {
    comptime {
        if (@typeInfo(State) != .@"struct") @compileError("state must be a struct, not " ++ @typeName(State));
        var ids: []const Named = &.{};
        walk(State, spec, @tagName(spec.kind), &ids);
    }
}

/// A widget id seen so far and the path of the node that has it.
const Named = struct { id: [:0]const u8, path: []const u8 };

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

fn walk(comptime State: type, comptime s: Spec, comptime path: []const u8, comptime ids: *[]const Named) void {
    // ponytail: ids are compared pairwise, O(ids^2) comptime work; a UI has tens of ids.
    @setEvalBranchQuota(1000 + 10 * ids.len * ids.len);
    const at = path ++ ": ";
    if (s.id) |name| {
        for (ids.*) |seen| if (std.mem.eql(u8, seen.id, name)) @compileError(at ++ "duplicate widget id '" ++ name ++ "', first used at " ++ seen.path);
        ids.* = ids.* ++ [_]Named{.{ .id = name, .path = path }};
    }
    if (s.bind) |field| {
        if (!hasField(State, field)) @compileError(at ++ "state " ++ @typeName(State) ++ " has no field '" ++ field ++ "'");
    }
    if (s.bind) |field| if (bindType(s.kind)) |T| {
        const FT = @FieldType(State, field);
        if (FT != T) @compileError(at ++ @tagName(s.kind) ++ " '" ++ field ++ "' needs " ++ (if (T == f32) "an " else "a ") ++ @typeName(T) ++ " field, not " ++ @typeName(FT));
    };
    for (s.children, 0..) |c, i| walk(State, c, std.fmt.comptimePrint("{s} > {t}[{d}]", .{ path, c.kind, i }), ids);
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
