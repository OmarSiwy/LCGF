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
/// bool field; every binding names a field of `State`; and, unless `options.require_names` is
/// false, every interactive widget (checkbox, slider) has a non-empty accessible name
/// (`spec.named`), which the accessibility tree reports for it.
///
/// Every message about a node starts with its spec path: the root's kind, then the kind and
/// child position of each node down to it, as in `col > row[1] > slider[0]: ...` (the first
/// child of the root's second child). Positions count from 0, as in `children[i]`.
pub fn check(comptime State: type, comptime spec: Spec, comptime options: Options) void {
    comptime {
        // Formatting each node's path is the costly part; ids are compared pairwise (O(ids^2),
        // a UI has tens of ids). The tests below pass a 501-node and a 101-node, 61-deep spec.
        const n = @import("flatten.zig").count(spec);
        @setEvalBranchQuota(1000 + branches_per_node * n + 4 * n * n);
        if (@typeInfo(State) != .@"struct") @compileError("state must be a struct, not " ++ @typeName(State));
        var ids: []const Named = &.{};
        walk(State, spec, options, @tagName(spec.kind), &ids);
        if (options.viewport) |vp| {
            const need = minSize(spec, @tagName(spec.kind));
            if (need[0] > vp[0] or need[1] > vp[1]) @compileError(std.fmt.comptimePrint(
                "{s}: needs at least {d}x{d} px, the viewport is {d}x{d}",
                .{ @tagName(spec.kind), need[0], need[1], vp[0], vp[1] },
            ));
        }
    }
}

/// Which optional rules `check` applies.
pub const Options = struct {
    /// Lint: interactive widgets have an accessible name. Off only for UIs that are never shown
    /// to an assistive technology (a kiosk demo, a test).
    require_names: bool = true,
    /// The fixed screen the UI runs on, in px (a microcontroller's display). When set, the
    /// fixed sizes in the spec must fit it: see `minSize`. Null for a resizable window.
    viewport: ?[2]f32 = null,
};

/// Comptime backward branches `check` may spend per node, besides the pairwise id compare.
/// The default quota (1,000 in all) ran out on a 32-node spec.
const branches_per_node = 1000;

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

fn walk(comptime State: type, comptime s: Spec, comptime options: Options, comptime path: []const u8, comptime ids: *[]const Named) void {
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
    const interactive = switch (s.kind) {
        .checkbox, .slider => true,
        .col, .row, .label => false,
    };
    if (options.require_names and interactive and (s.name orelse "").len == 0)
        @compileError(at ++ @tagName(s.kind) ++ " '" ++ (s.id orelse "") ++ "' has no accessible name; give it one with spec.named(..., \"Name\")");
    for (s.children, 0..) |c, i| walk(State, c, options, std.fmt.comptimePrint("{s} > {t}[{d}]", .{ path, c.kind, i }), ids);
}

/// The smallest size `s` can take, in px per axis, from what the spec fixes: `px` sizes, `min`,
/// `pad` and `gap`. A container that fits its content sums its in-flow children along its axis
/// and takes the largest across it; `float` children are out of flow. A node that clips or may
/// shrink can be smaller than its content. A px-sized node whose content does not fit it, and
/// does not clip, is an error at that node.
///
/// ponytail: text is measured at run time, so labels count as 0 px and the check only catches
/// overflow from fixed sizes; borders are ignored (layout draws them inside the padding).
fn minSize(comptime s: Spec, comptime path: []const u8) [2]f32 {
    var content: [2]f32 = .{ 0, 0 };
    const main = @backingInt(s.style.dir);
    var flow: usize = 0;
    for (s.children, 0..) |c, i| {
        const m = minSize(c, std.fmt.comptimePrint("{s} > {t}[{d}]", .{ path, c.kind, i }));
        if (c.style.float) continue;
        flow += 1;
        content[main] += m[main];
        content[1 - main] = @max(content[1 - main], m[1 - main]);
    }
    if (flow > 1) content[main] += s.style.gap * @as(f32, @floatFromInt(flow - 1));
    content[0] += s.style.pad[0] + s.style.pad[2];
    content[1] += s.style.pad[1] + s.style.pad[3];
    var out: [2]f32 = undefined;
    for (0..2) |a| {
        const size = s.style.size[a];
        const loose = s.style.clip or s.style.shrink;
        out[a] = switch (size.kind) {
            .px => px: {
                if (content[a] > size.v and !s.style.clip) @compileError(std.fmt.comptimePrint(
                    "{s}: content needs {d} px along {s}, the node is {d} px and does not clip",
                    .{ path, content[a], if (a == 0) "x" else "y", size.v },
                ));
                break :px size.v;
            },
            .fit, .grow, .pct => if (loose) s.style.min[a] else @max(content[a], s.style.min[a]),
        };
    }
    return out;
}

// ---- tests -------------------------------------------------------------------------------------

const col = spec_zig.col;
const row = spec_zig.row;
const label = spec_zig.label;
const checkbox = spec_zig.checkbox;
const slider = spec_zig.slider;
const named = spec_zig.named;

/// The probe's state struct and usage spec, with accessible names.
const Mixer = struct { title: []const u8 = "Mixer", volume: f32 = 0.5, muted: bool = false, pan: f32 = 0 };

const mixer = col(.{ .pad = @splat(8), .gap = 4 }, .{
    label(.title),
    row(.{ .gap = 8 }, .{ named(checkbox(.mute, .muted), "Mute"), named(slider(.volume, .volume), "Volume") }),
    row(.{ .gap = 8 }, .{ label(.title), named(slider(.pan, .pan), "Pan") }),
});

test "check: the probe's mixer breaks no rule" {
    comptime check(Mixer, mixer, .{});
    // Two labels bound to one field are not a duplicate: only ids must be unique.
    comptime check(Mixer, col(.{}, .{ label(.title), label(.title) }), .{});
    // A label shows a field of any type.
    comptime check(Mixer, col(.{}, .{ label(.volume), label(.muted) }), .{});
}

test "check: a UI whose fixed sizes fit the viewport compiles" {
    const panel = col(.{ .size = .{ .px(320), .px(240) }, .pad = @splat(8), .gap = 4 }, .{
        label(.title),
        row(.{ .size = .{ .fill, .px(40) }, .gap = 8 }, .{ named(checkbox(.mute, .muted), "Mute"), named(slider(.volume, .volume), "Volume") }),
    });
    comptime check(Mixer, panel, .{ .viewport = .{ 320, 240 } });
    // Exactly full: 2 x 100 + gap 20 + pad 10 + 10 = 240 wide.
    const full = row(.{ .pad = .{ 10, 0, 10, 0 }, .gap = 20 }, .{ col(.{ .size = .{ .px(100), .px(50) } }, .{}), col(.{ .size = .{ .px(100), .px(50) } }, .{}) });
    comptime check(Mixer, full, .{ .viewport = .{ 240, 50 } });
    // A float is out of flow; a clipping or shrinking node may be smaller than its content.
    const loose = col(.{}, .{
        col(.{ .float = true, .size = .{ .px(999), .px(999) } }, .{}),
        col(.{ .clip = true }, .{col(.{ .size = .{ .px(500), .px(10) } }, .{})}),
        col(.{ .shrink = true, .size = .{ .px(10), .px(10) }, .clip = true }, .{col(.{ .size = .{ .px(500), .px(10) } }, .{})}),
    });
    comptime check(Mixer, loose, .{ .viewport = .{ 100, 100 } });
    // Without a viewport the sizes are not checked.
    comptime check(Mixer, row(.{}, .{col(.{ .size = .{ .px(5000), .px(5000) } }, .{})}), .{});
}

test "minSize: sums along the axis, takes the largest across, adds pad and gap" {
    const s = comptime row(.{ .pad = .{ 1, 2, 3, 4 }, .gap = 5 }, .{
        col(.{ .size = .{ .px(10), .px(20) } }, .{}),
        col(.{ .size = .{ .px(30), .px(7) } }, .{}),
        col(.{ .min = .{ 6, 0 } }, .{}),
    });
    try std.testing.expectEqual([2]f32{ 1 + 10 + 5 + 30 + 5 + 6 + 3, 2 + 20 + 4 }, comptime minSize(s, "row"));
}

/// `n` named sliders in a row, each with its own id and field `x`.
fn manySliders(comptime n: comptime_int) Spec {
    @setEvalBranchQuota(1000 + 500 * n);
    var kids: [n]Spec = undefined;
    for (&kids, 0..) |*k, i| k.* = .{ .kind = .slider, .id = std.fmt.comptimePrint("s{d}", .{i}), .bind = "volume", .name = "Level" };
    return row(.{ .size = .{ .px(10), .px(10) }, .clip = true }, kids);
}

const many_500 = manySliders(500);

test "check: a 501-node spec with 500 ids validates without the caller raising a quota" {
    comptime check(Mixer, many_500, .{ .viewport = .{ 10, 10 } });
    // Deep: long paths cost more to format.
    comptime check(Mixer, blk: {
        var deep = manySliders(40);
        for (0..60) |_| deep = col(.{}, .{deep});
        break :blk deep;
    }, .{});
}

test "check: require_names = false lets unnamed widgets through" {
    comptime check(Mixer, row(.{}, .{ checkbox(.mute, .muted), slider(.volume, .volume) }), .{ .require_names = false });
}
