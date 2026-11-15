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

        /// One bit per node, bit i for row i of the flattened spec. Up to `word_bits` nodes it
        /// is the smallest integer that fits (u8 for the probe's 8 nodes); past that a bit-set
        /// array of `word_bits` words, bit i in word i / word_bits. Words are u32 so every word
        /// of a constant mask is an OR with an immediate on x86-64, which takes at most 32 bits.
        pub const Mask = if (n <= word_bits) @Int(.unsigned, n) else [mask_words]Word;
        pub const word_bits = 32;
        const Word = @Int(.unsigned, word_bits);
        const mask_words = (n + word_bits - 1) / word_bits;
        const is_array = n > word_bits;

        /// No node dirty.
        pub const empty: Mask = if (is_array) @splat(0) else 0;
        /// Every node dirty, and no bit past the last node.
        pub const full: Mask = blk: {
            @setEvalBranchQuota(1000 + 2 * n);
            var m = empty;
            for (0..n) |i| m = withBit(m, i);
            break :blk m;
        };

        /// Whether node `i` is set in `m`.
        pub fn isSet(m: Mask, i: usize) bool {
            return if (is_array)
                (m[i / word_bits] >> @intCast(i % word_bits)) & 1 != 0
            else
                (m >> @intCast(i)) & 1 != 0;
        }

        /// `m` with node `i` set.
        fn withBit(m: Mask, i: usize) Mask {
            var r = m;
            if (is_array) r[i / word_bits] |= @as(Word, 1) << @intCast(i % word_bits) else r |= @as(Mask, 1) << @intCast(i);
            return r;
        }

        /// `dst |= m` for a constant `m`: one OR for an integer mask, one per nonzero word for an
        /// array, so a field's setter touches only the words its nodes are in.
        pub inline fn orInto(dst: *Mask, comptime m: Mask) void {
            if (is_array) {
                inline for (m, 0..) |w, k| if (w != 0) {
                    dst[k] |= w;
                };
            } else dst.* |= m;
        }

        /// For each state field: the nodes to lay out and paint again when it changes, which are
        /// every node bound to it and their ancestors. Read-only data, indexed by
        /// `@backingInt(field)`.
        pub const dirty_masks: [field_count]Mask = blk: {
            // Per node: the walk, a field lookup and an ancestor walk up to `levels` steps.
            @setEvalBranchQuota(1000 + 4 * n * (F.levels + field_count + 2));
            var masks: [field_count]Mask = @splat(empty);
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
                const f = fieldNamed(name);
                var a: usize = i;
                while (true) : (a = F.parent[a]) {
                    masks[@backingInt(f)] = withBit(masks[@backingInt(f)], a);
                    if (a == 0) break;
                }
            }
            for (node.children) |c| bindWalk(c, next, masks);
        }

        fn fieldNamed(comptime name: []const u8) Field {
            for (@typeInfo(Field).@"enum".field_names, 0..) |fname, k|
                if (std.mem.eql(u8, fname, name)) return @fromBackingInt(@intCast(k));
            @compileError("state " ++ @typeName(State) ++ " has no field '" ++ name ++ "'");
        }

        /// The run-time half of the signals: the state and the nodes it has made dirty. The
        /// caller owns it; no allocator, no subscriber lists.
        pub const Runtime = struct {
            state: State = .{},
            /// Every node starts dirty, so the first frame lays out and paints everything.
            dirty: Mask = full,

            /// The whole signal graph: one store and one OR with a constant mask (one OR per
            /// touched word when the mask is an array).
            pub fn set(rt: *Runtime, comptime field: Field, value: FieldType(field)) void {
                @field(rt.state, @tagName(field)) = value;
                orInto(&rt.dirty, dirty_masks[@backingInt(field)]);
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
            for (0..F.node_count) |i|
                try testing.expectEqual((want >> @intCast(i)) & 1 != 0, S.isSet(S.dirty_masks[k], i));
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

/// One root over `n` leaves; leaf k (row k + 1) shows field `x` when k is `bound`, `y` otherwise.
fn wideBound(comptime leaves: comptime_int, comptime bound: comptime_int) Spec {
    var kids: [leaves]Spec = undefined;
    for (&kids, 0..) |*l, k| l.* = if (k == bound) s.label(.x) else s.label(.y);
    return s.row(.{}, kids);
}
const XYState = struct { x: u8 = 0, y: u8 = 0 };

test "Mask: an integer up to word_bits nodes, a bit-set array past that" {
    try testing.expectEqual(u8, App.Mask);
    try testing.expectEqual(u1, Signals(XYState, s.label(.x)).Mask);
    try testing.expectEqual(u32, Signals(XYState, wideBound(31, 0)).Mask);
    try testing.expectEqual([2]u32, Signals(XYState, wideBound(32, 0)).Mask);
    try testing.expectEqual([4]u32, Signals(XYState, wideBound(127, 0)).Mask);
    try testing.expectEqual(0xff, App.full);
    const B = Signals(XYState, wideBound(99, 98)); // 100 nodes
    try testing.expectEqual([4]u32{ 0xffff_ffff, 0xffff_ffff, 0xffff_ffff, 0xf }, B.full);
    // x is shown by row 99 only: the root (word 0, bit 0) and word 3, bit 3.
    try testing.expectEqual([4]u32{ 1, 0, 0, 0b1000 }, B.dirty_masks[@backingInt(B.Field.x)]);
    for (0..100) |i| try testing.expectEqual(i == 0 or i == 99, B.isSet(B.dirty_masks[0], i));
    // y: the root and every other leaf.
    for (0..100) |i| try testing.expectEqual(i != 99, B.isSet(B.dirty_masks[1], i));
}

test "Runtime.set: an array mask ORs in only the words the field touches" {
    const B = Signals(XYState, wideBound(99, 98));
    var rt: B.Runtime = .{};
    try testing.expectEqual(B.full, rt.dirty);
    rt.dirty = B.empty;
    rt.set(.x, 7);
    try testing.expectEqual(7, rt.state.x);
    try testing.expectEqual([4]u32{ 1, 0, 0, 0b1000 }, rt.dirty);
    rt.set(.y, 1);
    try testing.expectEqual(B.full, rt.dirty);
}
