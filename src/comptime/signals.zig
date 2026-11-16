//! Signals: the comptime front end's signal graph, resolved by the compiler. Each state field is
//! a signal; what it affects is a constant, so a setter needs no subscriber list. Tier 1. Ported
//! from prototype/comptime_ui_probe.zig (`Ui().Field`, `Ui().dirty_masks`, `Runtime.set`).
//!
//! Effects are named reactions the caller runs. `State` declares them as
//! `pub const effects = .{ .save = .{ .volume, .muted } };`: an effect is pending once a field it
//! watches changes, directly or through a derived field. The setter ORs a constant into a
//! pending mask; `takeEffect` hands pending effects back as a generated `Effect` enum, so running
//! them is the caller's exhaustive switch, with no callbacks and no subscriber lists.
//!
//! Derived fields (Floem's memos) are state fields computed from other fields. `State` declares
//! them as `pub const derived = .{ .total = .{ .from = .{ .a, .b }, .compute = sum } };` where
//! `compute` is `fn (*const State) T` for the field's type T. Inputs may be derived themselves;
//! the compiler orders them topologically (a cycle is a compile error), and setting an input
//! recomputes exactly the derived fields that depend on it, in that order. Because which fields
//! depend on which is constant, a setter's work is fixed at compile time: a field nothing derives
//! from still compiles to one store and one OR.

const std = @import("std");
const Spec = @import("spec.zig").Spec;
const flatten = @import("flatten.zig");

/// The signals of a UI over `State` declared by `spec`.
pub fn Signals(comptime State: type, comptime spec: Spec) type {
    if (@typeInfo(State) != .@"struct") @compileError("state must be a struct, not " ++ @typeName(State));
    const F = flatten.Flat(spec);
    const n = F.node_count;
    const field_count = @typeInfo(State).@"struct".field_names.len;
    const derived_decl = if (@hasDecl(State, "derived")) State.derived else .{};
    const derived_names = @typeInfo(@TypeOf(derived_decl)).@"struct".field_names;
    const derived_count = derived_names.len;
    const effects_decl = if (@hasDecl(State, "effects")) State.effects else .{};
    const effect_names = @typeInfo(@TypeOf(effects_decl)).@"struct".field_names;
    const effect_count = effect_names.len;
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

        /// For each state field: every node a change can touch in either pass, which is every
        /// node bound to it or to a field derived from it, and their ancestors (the probe's
        /// `dirty_masks`; `layout_masks | paint_masks` is a subset). Read-only data, indexed by
        /// `@backingInt(field)`.
        pub const dirty_masks: [field_count]Mask = withDerived(bindMasks(.ancestors));

        /// For each state field: the nodes to lay out again (and so paint again) when it
        /// changes. A bound node whose size follows its value (a label's text) and its
        /// ancestors; a checkbox or slider keeps its size, so it adds nothing here.
        pub const layout_masks: [field_count]Mask = withDerived(bindMasks(.layout));

        /// For each state field: the nodes to paint again, without layout, when it changes: its
        /// bound nodes that `layout_masks` does not already cover. Damage tracking repaints
        /// `layout | paint` and nothing else.
        pub const paint_masks: [field_count]Mask = blk: {
            var masks = withDerived(bindMasks(.nodes));
            for (&masks, layout_masks) |*m, l| m.* = andNot(m.*, l);
            break :blk masks;
        };

        /// Kinds whose size depends on the bound value.
        fn sizedByValue(comptime kind: @import("spec.zig").Kind) bool {
            return switch (kind) {
                .label => true,
                .checkbox, .slider, .button, .col, .row => false,
            };
        }

        /// Which nodes of a binding a mask takes: every bound node and its ancestors; only the
        /// ones `sizedByValue`, with ancestors; or the bound nodes alone.
        const Reach = enum { ancestors, layout, nodes };

        /// For each state field, the nodes `reach` takes of the bindings to it.
        fn bindMasks(comptime reach: Reach) [field_count]Mask {
            // Per node: the walk, a field lookup and an ancestor walk up to `levels` steps.
            @setEvalBranchQuota(1000 + 4 * n * (F.levels + field_count + 2));
            var masks: [field_count]Mask = @splat(empty);
            var next: usize = 0;
            bindWalk(spec, reach, &next, &masks);
            return masks;
        }

        /// Visits `node` and its subtree depth-first from row `next.*`, as `Flat` numbers rows,
        /// and ORs the nodes `reach` takes of each binding into its field's mask.
        fn bindWalk(comptime node: Spec, comptime reach: Reach, comptime next: *usize, comptime masks: *[field_count]Mask) void {
            const i = next.*;
            next.* += 1;
            if (node.bind) |name| {
                const m = &masks[@backingInt(fieldNamed(name))];
                switch (reach) {
                    .nodes => m.* = withBit(m.*, i),
                    .ancestors, .layout => if (reach == .ancestors or sizedByValue(node.kind)) {
                        var a: usize = i;
                        while (true) : (a = F.parent[a]) {
                            m.* = withBit(m.*, a);
                            if (a == 0) break;
                        }
                    },
                }
            }
            for (node.children) |c| bindWalk(c, reach, next, masks);
        }

        /// `masks` with each field's mask ORed with the masks of the derived fields it reaches.
        fn withDerived(comptime masks: [field_count]Mask) [field_count]Mask {
            @setEvalBranchQuota(1000 + 4 * field_count * (derived_count + 1) * mask_len);
            var out = masks;
            for (0..field_count) |f| for (0..derived_count) |d| if (reaches[f][d]) {
                const own = masks[@backingInt(derived_field[d])];
                if (is_array) {
                    for (&out[f], own) |*w, o| w.* |= o;
                } else out[f] |= own;
            };
            return out;
        }
        const mask_len = if (is_array) mask_words else 1;

        /// `a` without the nodes of `b`.
        fn andNot(a: Mask, b: Mask) Mask {
            if (!is_array) return a & ~b;
            var r = a;
            for (&r, b) |*w, o| w.* &= ~o;
            return r;
        }

        /// The derived fields in declaration order of `State.derived`.
        const derived_field: [derived_count]Field = blk: {
            var out: [derived_count]Field = undefined;
            for (derived_names, &out) |name, *f| f.* = fieldNamed(name);
            break :blk out;
        };

        /// Index into `derived_field` of `field`, or null for a field that is set directly.
        fn derivedIndex(comptime field: Field) ?usize {
            for (derived_field, 0..) |f, d| if (f == field) return d;
            return null;
        }

        /// `inputs[d][f]`: derived field d reads field f directly.
        const inputs: [derived_count][field_count]bool = blk: {
            var out: [derived_count][field_count]bool = @splat(@splat(false));
            for (derived_names, 0..) |name, d| {
                const entry = @field(derived_decl, name);
                const FT = FieldType(derived_field[d]);
                if (@TypeOf(entry.compute) != fn (*const State) FT)
                    @compileError("derived field '" ++ name ++ "' needs compute: fn (*const " ++ @typeName(State) ++ ") " ++ @typeName(FT));
                for (entry.from) |input| {
                    const f = fieldNamed(@tagName(input));
                    if (f == derived_field[d]) @compileError("derived field '" ++ name ++ "' reads itself");
                    out[d][@backingInt(f)] = true;
                }
            }
            break :blk out;
        };

        /// Derived fields, every input before the fields that read it (Kahn's algorithm,
        /// declaration order among the ready ones).
        pub const topo_order: [derived_count]Field = blk: {
            @setEvalBranchQuota(1000 + 4 * derived_count * derived_count * (derived_count + field_count));
            var out: [derived_count]Field = undefined;
            var placed: [derived_count]bool = @splat(false);
            for (0..derived_count) |k| {
                const ready = for (0..derived_count) |d| {
                    if (placed[d]) continue;
                    const waits = for (0..derived_count) |e| {
                        if (!placed[e] and inputs[d][@backingInt(derived_field[e])]) break true;
                    } else false;
                    if (!waits) break d;
                } else @compileError("derived fields of " ++ @typeName(State) ++ " form a cycle");
                placed[ready] = true;
                out[k] = derived_field[ready];
            }
            break :blk out;
        };

        /// `reaches[f][d]`: changing field f changes derived field d, directly or through other
        /// derived fields.
        const reaches: [field_count][derived_count]bool = blk: {
            @setEvalBranchQuota(1000 + 4 * field_count * derived_count * derived_count);
            var out: [field_count][derived_count]bool = @splat(@splat(false));
            for (0..field_count) |f| {
                // In topological order, so a derived input's reach is final when it is read.
                for (topo_order) |field| {
                    const d = derivedIndex(field).?;
                    if (inputs[d][f]) out[f][d] = true;
                    for (0..derived_count) |e| if (out[f][e] and inputs[d][@backingInt(derived_field[e])]) {
                        out[f][d] = true;
                    };
                }
            }
            break :blk out;
        };

        /// One bit per derived field, bit d for `State.derived` entry d.
        const Stale = @Int(.unsigned, derived_count);
        /// For each field: the derived fields it reaches, as `Stale` bits.
        const stale_bits: [field_count]Stale = blk: {
            var out: [field_count]Stale = @splat(0);
            for (0..field_count) |f| for (0..derived_count) |d| if (reaches[f][d]) {
                out[f] |= @as(Stale, 1) << d;
            };
            break :blk out;
        };

        /// One tag per declared effect, in declaration order: tag e is bit e of `Pending`.
        pub const Effect = if (effect_count == 0) enum {} else blk: {
            var values: [effect_count]u32 = undefined;
            for (&values, 0..) |*v, e| v.* = e;
            break :blk @Enum(u32, .exhaustive, effect_names, &values);
        };
        /// One bit per effect.
        pub const Pending = @Int(.unsigned, effect_count);

        /// For each field: the effects a change makes pending, those watching the field itself
        /// or a derived field it reaches.
        pub const effect_masks: [field_count]Pending = blk: {
            var watch: [field_count]Pending = @splat(0);
            for (effect_names, 0..) |name, e| {
                for (@field(effects_decl, name)) |field|
                    watch[@backingInt(fieldNamed(@tagName(field)))] |= @as(Pending, 1) << e;
            }
            var out = watch;
            for (0..field_count) |f| for (0..derived_count) |d| if (reaches[f][d]) {
                out[f] |= watch[@backingInt(derived_field[d])];
            };
            break :blk out;
        };

        fn fieldNamed(comptime name: []const u8) Field {
            for (@typeInfo(Field).@"enum".field_names, 0..) |fname, k|
                if (std.mem.eql(u8, fname, name)) return @fromBackingInt(@intCast(k));
            @compileError("state " ++ @typeName(State) ++ " has no field '" ++ name ++ "'");
        }

        /// The run-time half of the signals: the state and the nodes it has made dirty. The
        /// caller owns it; no allocator, no subscriber lists.
        pub const Runtime = struct {
            state: State = .{},
            /// Nodes to lay out (and paint) again. Every node starts dirty, so the first frame lays
            /// out and paints everything.
            layout_dirty: Mask = full,
            /// Nodes to paint again whose layout has not changed.
            paint_dirty: Mask = full,
            /// Derived fields whose inputs were staged since the last `commit`, bit d for
            /// `State.derived` entry d. Zero-sized without derived fields.
            stale: Stale = 0,
            /// Effects to run, bit e for `Effect` tag e. Zero-sized without effects; nothing is
            /// pending at start, since no field has changed yet.
            pending: Pending = 0,

            /// The whole signal graph: one store and one OR with a constant mask per pass the
            /// field touches (one OR per touched word when the mask is an array; none for a pass
            /// whose mask is 0, so a slider's setter is one OR into `paint_dirty`), then the derived fields that read
            /// `field`, recomputed in topological order. A derived field cannot be set.
            pub fn set(rt: *Runtime, comptime field: Field, value: FieldType(field)) void {
                if (comptime derivedIndex(field) != null)
                    @compileError("'" ++ @tagName(field) ++ "' is derived; set its inputs instead");
                @field(rt.state, @tagName(field)) = value;
                orInto(&rt.layout_dirty, layout_masks[@backingInt(field)]);
                orInto(&rt.paint_dirty, paint_masks[@backingInt(field)]);
                if (comptime effect_masks[@backingInt(field)] != 0) rt.pending |= effect_masks[@backingInt(field)];
                recompute(&rt.state, reaches[@backingInt(field)]);
            }

            /// A batched `set`: stores and marks the nodes dirty, but only marks the derived fields
            /// that read `field` stale. Stage any number of changes, then `commit` once, so each
            /// derived field is recomputed once per batch however many of its inputs changed.
            /// The dirty mask coalesces as with `set`: one layout and one paint per batch.
            pub fn stage(rt: *Runtime, comptime field: Field, value: FieldType(field)) void {
                if (comptime derivedIndex(field) != null)
                    @compileError("'" ++ @tagName(field) ++ "' is derived; set its inputs instead");
                @field(rt.state, @tagName(field)) = value;
                orInto(&rt.layout_dirty, layout_masks[@backingInt(field)]);
                orInto(&rt.paint_dirty, paint_masks[@backingInt(field)]);
                if (comptime effect_masks[@backingInt(field)] != 0) rt.pending |= effect_masks[@backingInt(field)];
                if (comptime stale_bits[@backingInt(field)] != 0) rt.stale |= stale_bits[@backingInt(field)];
            }

            /// Ends a batch: recomputes every stale derived field once, in topological order.
            pub fn commit(rt: *Runtime) void {
                inline for (topo_order) |field| {
                    const d = comptime derivedIndex(field).?;
                    if ((rt.stale >> d) & 1 != 0)
                        @field(rt.state, @tagName(field)) = @field(derived_decl, derived_names[d]).compute(&rt.state);
                }
                rt.stale = 0;
            }

            /// What one frame redoes: `layout`, the nodes to lay out again, and `paint`, every
            /// node to paint again (`layout` included).
            pub const Dirty = struct { layout: Mask, paint: Mask };

            /// The dirty nodes since the last call, cleared.
            pub fn takeDirty(rt: *Runtime) Dirty {
                var paint = rt.paint_dirty;
                if (is_array) {
                    for (&paint, rt.layout_dirty) |*w, l| w.* |= l;
                } else paint |= rt.layout_dirty;
                defer rt.layout_dirty = empty;
                defer rt.paint_dirty = empty;
                return .{ .layout = rt.layout_dirty, .paint = paint };
            }

            /// The pending effect with the lowest tag, now no longer pending, or null. The caller
            /// runs it: `while (rt.takeEffect()) |e| switch (e) { ... }`.
            pub fn takeEffect(rt: *Runtime) ?Effect {
                if (comptime effect_count == 0) return null;
                if (rt.pending == 0) return null;
                const e = @ctz(rt.pending);
                rt.pending &= rt.pending - 1;
                return @fromBackingInt(@intCast(e));
            }

            /// Recomputes, in topological order, every derived field marked in `which`.
            inline fn recompute(state: *State, comptime which: [derived_count]bool) void {
                inline for (topo_order) |field| {
                    const d = comptime derivedIndex(field).?;
                    if (comptime which[d])
                        @field(state, @tagName(field)) = @field(derived_decl, derived_names[d]).compute(state);
                }
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

test "Runtime.set: stores the value and ORs in the field's masks" {
    var rt: App.Runtime = .{};
    try testing.expectEqual(0xff, rt.layout_dirty);
    try testing.expectEqual(0xff, rt.paint_dirty);
    rt.layout_dirty = 0;
    rt.paint_dirty = 0;
    rt.set(.volume, 0.9);
    try testing.expectEqual(0.9, rt.state.volume);
    // A slider keeps its size: repaint node 4, lay out nothing.
    try testing.expectEqual(0, rt.layout_dirty);
    try testing.expectEqual(0b0001_0000, rt.paint_dirty);
    const hit: enum { mute, volume, pan } = .mute;
    switch (hit) {
        .mute => rt.set(.muted, true),
        .volume, .pan => {},
    }
    try testing.expect(rt.state.muted);
    try testing.expectEqual(0b0001_1000, rt.paint_dirty);
    // A label's text sizes it: lay out both title labels (1, 6), row 5 and the root.
    rt.set(.title, "Desk");
    try testing.expectEqualStrings("Desk", rt.state.title);
    try testing.expectEqual(0b0110_0011, rt.layout_dirty);
    const d = rt.takeDirty();
    try testing.expectEqual(0b0110_0011, d.layout);
    try testing.expectEqual(0b0111_1011, d.paint);
    try testing.expectEqual(0, rt.layout_dirty);
    try testing.expectEqual(0, rt.paint_dirty);
}

test "layout_masks, paint_masks: split the probe's dirty mask by pass" {
    const L = App.layout_masks;
    const P = App.paint_masks;
    inline for (.{ .volume, .muted, .pan, .title }, .{ 0, 0, 0, 0b0110_0011 }, .{ 0b0001_0000, 0b0000_1000, 0b1000_0000, 0 }) |f, l, p| {
        try testing.expectEqual(l, L[@backingInt(@as(App.Field, f))]);
        try testing.expectEqual(p, P[@backingInt(@as(App.Field, f))]);
    }
    for (App.dirty_masks, L, P) |d, l, p| {
        // Never more than the probe's mask, never overlapping, always the bound nodes.
        try testing.expectEqual(0, (l | p) & ~d);
        try testing.expectEqual(0, l & p);
    }
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
    try testing.expectEqual(B.full, rt.layout_dirty);
    rt.layout_dirty = B.empty;
    rt.paint_dirty = B.empty;
    rt.set(.x, 7);
    try testing.expectEqual(7, rt.state.x);
    try testing.expectEqual([4]u32{ 1, 0, 0, 0b1000 }, rt.layout_dirty);
    try testing.expectEqual(B.empty, rt.paint_dirty);
    rt.set(.y, 1);
    try testing.expectEqual(B.full, rt.layout_dirty);
    try testing.expectEqual(B.full, rt.takeDirty().paint);
}

/// A mixer with derived fields: `gain` from volume and muted, `left` from gain and pan, and
/// `caption` from title, declared out of order so the topological sort has work to do.
const Derived = struct {
    title: []const u8 = "Mixer",
    volume: f32 = 0.5,
    muted: bool = false,
    pan: f32 = 0,
    left: f32 = 0.25,
    gain: f32 = 0.5,
    caption_len: usize = 5,

    pub const derived = .{
        .left = .{ .from = .{ .gain, .pan }, .compute = leftOf },
        .gain = .{ .from = .{ .volume, .muted }, .compute = gainOf },
        .caption_len = .{ .from = .{.title}, .compute = captionLen },
    };
    fn leftOf(m: *const Derived) f32 {
        return m.gain * (1 - m.pan) / 2;
    }
    fn gainOf(m: *const Derived) f32 {
        return if (m.muted) 0 else m.volume;
    }
    fn captionLen(m: *const Derived) usize {
        return m.title.len;
    }
};
/// The mixer with a label for each derived field: left (row 8) and caption_len (row 9).
const derived_mixer = s.col(.{ .pad = @splat(8), .gap = 4 }, .{
    s.label(.title),
    s.row(.{ .gap = 8 }, .{ s.checkbox(.mute, .muted), s.slider(.volume, .volume) }),
    s.row(.{ .gap = 8 }, .{ s.label(.title), s.slider(.pan, .pan) }),
    s.label(.left),
    s.label(.caption_len),
});
const D = Signals(Derived, derived_mixer);

test "derived: topological order puts every input before its readers" {
    try testing.expectEqualSlices(D.Field, &.{ .gain, .left, .caption_len }, &D.topo_order);
    try testing.expectEqual(0, Signals(Mixer, mixer).topo_order.len);
}

test "derived: an input's mask covers the nodes of every field derived from it" {
    const m = D.dirty_masks;
    // volume: its slider (4), row 2, root, and through gain -> left the label at row 8.
    try testing.expectEqual(0b01_0001_0101, m[@backingInt(D.Field.volume)]);
    // pan: slider 7, row 5, root, and left at row 8.
    try testing.expectEqual(0b01_1010_0001, m[@backingInt(D.Field.pan)]);
    // title: both labels, row 5, root, and caption_len at row 9.
    try testing.expectEqual(0b10_0110_0011, m[@backingInt(D.Field.title)]);
    // gain is shown nowhere, but left reads it.
    try testing.expectEqual(0b01_0000_0001, m[@backingInt(D.Field.gain)]);
    try testing.expectEqual(0b01_0000_0001, m[@backingInt(D.Field.left)]);
}

test "derived: set recomputes exactly the dependent fields, inputs first" {
    var rt: D.Runtime = .{};
    _ = rt.takeDirty();
    rt.set(.volume, 0.8);
    try testing.expectEqual(0.8, rt.state.gain);
    try testing.expectEqual(0.4, rt.state.left);
    try testing.expectEqual(5, rt.state.caption_len);
    // The slider repaints; the derived `left` label (row 8) is laid out again with the root.
    try testing.expectEqual(0b00_0001_0000, rt.paint_dirty);
    try testing.expectEqual(0b01_0000_0001, rt.layout_dirty);
    rt.set(.muted, true);
    try testing.expectEqual(0, rt.state.gain);
    try testing.expectEqual(0, rt.state.left);
    rt.set(.muted, false);
    rt.set(.pan, -1);
    try testing.expectEqual(0.8, rt.state.left);
    // A field read by no derived field leaves them alone.
    rt.state.left = 123;
    rt.set(.title, "Main bus");
    try testing.expectEqual(8, rt.state.caption_len);
    try testing.expectEqual(123, rt.state.left);
}

/// `Derived` with a counter in each compute function, to see how often a batch recomputes.
const Counted = struct {
    volume: f32 = 0.5,
    muted: bool = false,
    pan: f32 = 0,
    gain: f32 = 0.5,
    left: f32 = 0.25,

    var gain_calls: u32 = 0;
    var left_calls: u32 = 0;
    pub const derived = .{
        .gain = .{ .from = .{ .volume, .muted }, .compute = gainOf },
        .left = .{ .from = .{ .gain, .pan }, .compute = leftOf },
    };
    fn gainOf(m: *const Counted) f32 {
        gain_calls += 1;
        return if (m.muted) 0 else m.volume;
    }
    fn leftOf(m: *const Counted) f32 {
        left_calls += 1;
        return m.gain * (1 - m.pan) / 2;
    }
};

test "stage, commit: a batch recomputes each derived field once and dirties the union" {
    const C = Signals(Counted, s.row(.{}, .{ s.slider(.v, .volume), s.checkbox(.m, .muted), s.slider(.p, .pan), s.label(.left) }));
    var rt: C.Runtime = .{};
    _ = rt.takeDirty();
    Counted.gain_calls = 0;
    Counted.left_calls = 0;
    rt.stage(.volume, 0.8);
    rt.stage(.muted, false);
    rt.stage(.pan, -1);
    rt.stage(.volume, 0.6);
    // Nothing recomputed yet: the batch is not committed.
    try testing.expectEqual(0, Counted.gain_calls);
    try testing.expectEqual(0.5, rt.state.gain);
    rt.commit();
    try testing.expectEqual(1, Counted.gain_calls);
    try testing.expectEqual(1, Counted.left_calls);
    try testing.expectEqual(0.6, rt.state.gain);
    try testing.expectEqual(0.6, rt.state.left);
    // One mask for the whole batch: lay out the label and the root, repaint them and every
    // slider and the checkbox.
    const d = rt.takeDirty();
    try testing.expectEqual(0b1_0001, d.layout);
    try testing.expectEqual(0b1_1111, d.paint);
    try testing.expectEqual(0, rt.layout_dirty);
    try testing.expectEqual(0, rt.paint_dirty);
    // A commit with nothing staged recomputes nothing; staging pan alone skips gain.
    rt.commit();
    rt.stage(.pan, 0);
    rt.commit();
    try testing.expectEqual(1, Counted.gain_calls);
    try testing.expectEqual(2, Counted.left_calls);
    try testing.expectEqual(0.3, rt.state.left);
    // The same changes through set recompute after every call.
    rt.set(.volume, 0.6);
    rt.set(.muted, false);
    try testing.expectEqual(3, Counted.gain_calls);
    try testing.expectEqual(4, Counted.left_calls);
}

test "stage: without derived fields it is set" {
    var a: App.Runtime = .{};
    var b: App.Runtime = .{};
    _ = a.takeDirty();
    _ = b.takeDirty();
    a.set(.volume, 0.9);
    b.stage(.volume, 0.9);
    b.commit();
    try testing.expectEqual(a, b);
    try testing.expectEqual(0, @sizeOf(@TypeOf(b.stale)));
}

/// The mixer with effects: `save` when anything persisted changes, `meter` when the derived
/// gain changes (so through volume and muted), `retitle` when the title changes.
const Effects = struct {
    title: []const u8 = "Mixer",
    volume: f32 = 0.5,
    muted: bool = false,
    pan: f32 = 0,
    gain: f32 = 0.5,

    pub const derived = .{ .gain = .{ .from = .{ .volume, .muted }, .compute = gainOf } };
    pub const effects = .{ .save = .{ .volume, .muted, .pan }, .meter = .{.gain}, .retitle = .{.title} };
    fn gainOf(m: *const Effects) f32 {
        return if (m.muted) 0 else m.volume;
    }
};

test "effects: a change makes its watchers pending, and the caller runs them by switch" {
    const E = Signals(Effects, mixer);
    try testing.expectEqual(0b011, E.effect_masks[@backingInt(E.Field.volume)]);
    try testing.expectEqual(0b001, E.effect_masks[@backingInt(E.Field.pan)]);
    try testing.expectEqual(0b100, E.effect_masks[@backingInt(E.Field.title)]);
    var rt: E.Runtime = .{};
    try testing.expectEqual(null, rt.takeEffect());
    rt.set(.volume, 0.7);
    rt.stage(.muted, true);
    rt.commit();
    var saved: u32 = 0;
    var metered: f32 = -1;
    var retitled = false;
    // An effect set twice runs once.
    while (rt.takeEffect()) |e| switch (e) { // forgetting an effect here is a compile error
        .save => saved += 1,
        .meter => metered = rt.state.gain,
        .retitle => retitled = true,
    };
    try testing.expectEqual(1, saved);
    try testing.expectEqual(0, metered);
    try testing.expect(!retitled);
    rt.set(.title, "Bus");
    try testing.expectEqual(E.Effect.retitle, rt.takeEffect().?);
    try testing.expectEqual(null, rt.takeEffect());
    // Without effects, nothing is ever pending and the mask takes no room.
    var plain: App.Runtime = .{};
    plain.set(.volume, 1);
    try testing.expectEqual(null, plain.takeEffect());
    try testing.expectEqual(0, @sizeOf(App.Pending));
}
