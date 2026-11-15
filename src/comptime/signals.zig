//! Signals: the comptime front end's signal graph, resolved by the compiler. Each state field is
//! a signal; what it affects is a constant, so a setter needs no subscriber list. Tier 1. Ported
//! from prototype/comptime_ui_probe.zig (`Ui().Field`, `Ui().dirty_masks`, `Runtime.set`).

const std = @import("std");
const Spec = @import("spec.zig").Spec;
const flatten = @import("flatten.zig");

/// The signals of a UI over `State` declared by `spec`.
pub fn Signals(comptime State: type, comptime spec: Spec) type {
    if (@typeInfo(State) != .@"struct") @compileError("state must be a struct, not " ++ @typeName(State));
    const F = flatten.Flat(spec);
    const n = F.node_count;
    const field_count = @typeInfo(State).@"struct".field_names.len;
    return struct {
        /// One tag per state field, in declaration order: tag k is field k, so a field's
        /// tables are indexed by `@backingInt(field)`.
        pub const Field = std.meta.FieldEnum(State);

        /// The type a setter of `field` takes.
        pub fn FieldType(comptime field: Field) type {
            return @FieldType(State, @tagName(field));
        }

        /// One bit per node, bit i for row i of the flattened spec.
        pub const Mask = @Int(.unsigned, n);

        /// For each state field: the nodes to lay out and paint again when it changes, which are
        /// every node bound to it and their ancestors. Read-only data, indexed by
        /// `@backingInt(field)`.
        pub const dirty_masks: [field_count]Mask = blk: {
            @setEvalBranchQuota(1000 + 8 * n);
            var masks: [field_count]Mask = @splat(0);
            var next: usize = 0;
            bindWalk(spec, &next, &masks);
            break :blk masks;
        };

        /// Visits `node` and its subtree depth-first from row `next.*`, as `Flat` numbers rows,
        /// and ORs each bound node and its ancestors into its field's mask.
        fn bindWalk(comptime node: Spec, comptime next: *usize, comptime masks: *[field_count]Mask) void {
            const i = next.*;
            next.* += 1;
            if (node.bind) |name| {
                const f = std.meta.stringToEnum(Field, name) orelse
                    @compileError("state " ++ @typeName(State) ++ " has no field '" ++ name ++ "'");
                var a: usize = i;
                while (true) : (a = F.parent[a]) {
                    masks[@backingInt(f)] |= @as(Mask, 1) << a;
                    if (a == 0) break;
                }
            }
            for (node.children) |c| bindWalk(c, next, masks);
        }

        /// The run-time half of the signals: the state and the nodes it has made dirty. The
        /// caller owns it; no allocator, no subscriber lists.
        pub const Runtime = struct {
            state: State = .{},
            /// Every node starts dirty, so the first frame lays out and paints everything.
            dirty: Mask = std.math.maxInt(Mask),

            /// The whole signal graph: one store and one OR with a constant mask.
            pub fn set(rt: *Runtime, comptime field: Field, value: FieldType(field)) void {
                @field(rt.state, @tagName(field)) = value;
                rt.dirty |= dirty_masks[@backingInt(field)];
            }
        };
    };
}

// ---- tests -------------------------------------------------------------------------------------

const testing = std.testing;
const s = @import("spec.zig");

/// The probe's state and usage spec.
const Mixer = struct { title: []const u8 = "Mixer", volume: f32 = 0.5, muted: bool = false, pan: f32 = 0 };
const mixer = s.col(.{ .pad = @splat(8), .gap = 4 }, .{
    s.label(.title),
    s.row(.{ .gap = 8 }, .{ s.checkbox(.mute, .muted), s.slider(.volume, .volume) }),
    s.row(.{ .gap = 8 }, .{ s.label(.title), s.slider(.pan, .pan) }),
});
const App = Signals(Mixer, mixer);

test "Field: one tag per state field, in declaration order" {
    const info = @typeInfo(App.Field).@"enum";
    try testing.expectEqual(4, info.field_names.len);
    inline for (@typeInfo(Mixer).@"struct".field_names, 0..) |name, k| {
        try testing.expectEqualStrings(name, info.field_names[k]);
        try testing.expectEqual(k, @backingInt(@field(App.Field, name)));
    }
    try testing.expectEqual(App.Field.volume, std.meta.stringToEnum(App.Field, "volume").?);
    try testing.expectEqual(f32, App.FieldType(.volume));
    try testing.expectEqual(bool, App.FieldType(.muted));
    try testing.expectEqual([]const u8, App.FieldType(.title));
}

test "dirty_masks: each field marks its bound nodes and their ancestors" {
    try testing.expectEqual(u8, App.Mask);
    // volume -> slider (4), its row (2), root (0)
    try testing.expectEqual(0b0001_0101, App.dirty_masks[@backingInt(App.Field.volume)]);
    // title is shown twice: nodes 1 and 6, row 5, root
    try testing.expectEqual(0b0110_0011, App.dirty_masks[@backingInt(App.Field.title)]);
    try testing.expectEqual(0b0000_1101, App.dirty_masks[@backingInt(App.Field.muted)]);
    try testing.expectEqual(0b1010_0001, App.dirty_masks[@backingInt(App.Field.pan)]);
    // A field nothing shows marks nothing.
    const Extra = struct { title: []const u8 = "", volume: f32 = 0, muted: bool = false, pan: f32 = 0, hidden: u32 = 0 };
    const E = Signals(Extra, mixer);
    try testing.expectEqual(0, E.dirty_masks[@backingInt(E.Field.hidden)]);
    try testing.expectEqual(App.dirty_masks[0..4].*, E.dirty_masks[0..4].*);
}

/// Specs of different shapes, for tests that hold for any spec.
const shapes = .{ mixer, s.label(.x), s.col(.{}, .{ s.row(.{}, .{ s.label(.x), s.label(.y) }), s.col(.{}, .{s.col(.{}, .{s.label(.x)})}) }) };

test "dirty_masks: equal the ancestor walk over the runtime parent column" {
    const XY = struct { title: []const u8 = "", volume: f32 = 0, muted: bool = false, pan: f32 = 0, x: u8 = 0, y: u8 = 0 };
    inline for (shapes) |sp| {
        const S = Signals(XY, sp);
        const F = flatten.Flat(sp);
        // Reference: bit i set when some node in i's subtree [i, end[i]) is bound to the field.
        const binds = comptime bindsOf(sp);
        inline for (@typeInfo(XY).@"struct".field_names, 0..) |name, k| {
            var want: u64 = 0;
            for (0..F.node_count) |i| {
                for (i..F.end[i]) |j| if (binds[j]) |b| if (std.mem.eql(u8, b, name)) {
                    want |= @as(u64, 1) << @intCast(i);
                };
            }
            try testing.expectEqual(want, S.dirty_masks[k]);
        }
    }
}

/// Each row's binding, depth-first.
fn bindsOf(comptime sp: Spec) [flatten.count(sp)]?[]const u8 {
    var out: [flatten.count(sp)]?[]const u8 = undefined;
    var next: usize = 0;
    bindsWalk(sp, &next, &out);
    return out;
}
fn bindsWalk(comptime sp: Spec, comptime next: *usize, comptime out: anytype) void {
    out[next.*] = sp.bind;
    next.* += 1;
    for (sp.children) |c| bindsWalk(c, next, out);
}

test "Runtime.set: stores the value and ORs in the field's mask" {
    var rt: App.Runtime = .{};
    try testing.expectEqual(0xff, rt.dirty);
    rt.dirty = 0;
    rt.set(.volume, 0.9);
    try testing.expectEqual(0.9, rt.state.volume);
    try testing.expectEqual(0b0001_0101, rt.dirty);
    const hit: enum { mute, volume, pan } = .mute;
    switch (hit) {
        .mute => rt.set(.muted, true),
        .volume, .pan => {},
    }
    try testing.expect(rt.state.muted);
    try testing.expectEqual(0b0001_1101, rt.dirty);
    rt.set(.title, "Desk");
    try testing.expectEqualStrings("Desk", rt.state.title);
    try testing.expectEqual(0b0111_1111, rt.dirty);
}
