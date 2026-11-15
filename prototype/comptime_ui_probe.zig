//! comptime_ui_probe.zig: a UI declared as a comptime value, flattened into
//! read-only tables. A probe for the comptime front end; `zig test` it on 0.17.1.
const std = @import("std");

pub const Kind = enum(u8) { col, row, label, checkbox, slider };

/// One node of the declaration. Exists only at compile time.
pub const Spec = struct {
    kind: Kind,
    id: ?[:0]const u8 = null,
    /// Name of the state field this node shows.
    bind: ?[]const u8 = null,
    pad: u8 = 0,
    gap: u8 = 0,
    children: []const Spec = &.{},
};

fn kids(comptime tuple: anytype) []const Spec {
    const arr: [tuple.len]Spec = tuple;
    const final = arr;
    return &final;
}
pub fn col(comptime s: struct { pad: u8 = 0, gap: u8 = 0 }, comptime children: anytype) Spec {
    return .{ .kind = .col, .pad = s.pad, .gap = s.gap, .children = kids(children) };
}
pub fn row(comptime s: struct { pad: u8 = 0, gap: u8 = 0 }, comptime children: anytype) Spec {
    return .{ .kind = .row, .pad = s.pad, .gap = s.gap, .children = kids(children) };
}
pub fn label(comptime bind: []const u8) Spec {
    return .{ .kind = .label, .bind = bind };
}
pub fn checkbox(comptime id: [:0]const u8, comptime bind: []const u8) Spec {
    return .{ .kind = .checkbox, .id = id, .bind = bind };
}
pub fn slider(comptime id: [:0]const u8, comptime bind: []const u8) Spec {
    return .{ .kind = .slider, .id = id, .bind = bind };
}

fn count(comptime s: Spec) comptime_int {
    var n = 1;
    for (s.children) |c| n += count(c);
    return n;
}

/// Everything about `spec` that can be known before the program runs.
pub fn Ui(comptime State: type, comptime spec: Spec) type {
    @setEvalBranchQuota(100_000);
    const n = count(spec);
    const fields = @typeInfo(State).@"struct";
    return struct {
        pub const node_count = n;
        /// The smallest integer that can index every node.
        pub const Index = std.math.IntFittingRange(0, n);
        /// One bit per node.
        pub const Mask = @Int(.unsigned, n);
        pub const Field = std.meta.FieldEnum(State);

        const Tables = struct {
            parent: [n]Index,
            end: [n]Index,
            kind: [n]Kind,
            pad: [n]u8,
            gap: [n]u8,
            /// For each state field: the nodes that must be laid out and
            /// painted again when it changes (the bound node and its ancestors).
            dirty: [fields.field_names.len]Mask,
            id_names: []const [:0]const u8,
            id_nodes: []const comptime_int,
        };

        const tables: Tables = blk: {
            var t: Tables = undefined;
            t.dirty = @splat(0);
            var names: []const [:0]const u8 = &.{};
            var nodes: []const comptime_int = &.{};
            var next: comptime_int = 0;
            flatten(spec, 0, &next, &t, &names, &nodes);
            t.id_names = names;
            t.id_nodes = nodes;
            break :blk t;
        };

        fn flatten(comptime s: Spec, comptime parent_ix: comptime_int, comptime next: *comptime_int, comptime t: *Tables, comptime names: *[]const [:0]const u8, comptime nodes: *[]const comptime_int) void {
            const i = next.*;
            next.* += 1;
            t.parent[i] = parent_ix;
            t.kind[i] = s.kind;
            t.pad[i] = s.pad;
            t.gap[i] = s.gap;
            if (s.id) |name| {
                for (names.*) |seen| if (std.mem.eql(u8, seen, name)) @compileError("duplicate widget id '" ++ name ++ "'");
                names.* = names.* ++ [_][:0]const u8{name};
                nodes.* = nodes.* ++ [_]comptime_int{i};
            }
            if (s.bind) |field| {
                const f = fieldIndex(field);
                const FT = fields.field_types[f];
                // Bindings are type-checked while compiling.
                if (s.kind == .slider and FT != f32) @compileError("slider '" ++ field ++ "' needs an f32 field");
                if (s.kind == .checkbox and FT != bool) @compileError("checkbox '" ++ field ++ "' needs a bool field");
                var a = i;
                while (true) : (a = t.parent[a]) {
                    t.dirty[f] |= @as(Mask, 1) << a;
                    if (a == 0) break;
                }
            }
            for (s.children) |c| flatten(c, i, next, t, names, nodes);
            t.end[i] = next.*;
        }

        fn fieldIndex(comptime name: []const u8) comptime_int {
            for (fields.field_names, 0..) |fname, k| if (std.mem.eql(u8, fname, name)) return k;
            @compileError("state has no field '" ++ name ++ "'");
        }

        // Read-only tables: these land in .rodata, not in RAM that the UI owns.
        pub const parent: [n]Index = tables.parent;
        pub const end: [n]Index = tables.end;
        pub const kind: [n]Kind = tables.kind;
        pub const dirty_masks: [fields.field_names.len]Mask = tables.dirty;

        /// Interactive widgets as an enum, so event handling is an exhaustive switch.
        const id_values: [tables.id_nodes.len]Index = blk: {
            var v: [tables.id_nodes.len]Index = undefined;
            for (tables.id_nodes, 0..) |node, k| v[k] = node;
            break :blk v;
        };
        pub const Widget = @Enum(Index, .exhaustive, tables.id_names, &id_values);

        /// All run-time memory this UI needs. No allocator, no capacity limits.
        pub const Runtime = struct {
            state: State = .{},
            dirty: Mask = std.math.maxInt(Mask),
            /// i16 is enough for the screens this profile targets.
            rect: [n][4]i16 = @splat(@splat(0)),

            /// The whole "signal graph": one store and one OR with a constant.
            pub fn set(self: *Runtime, comptime field: Field, value: @FieldType(State, @tagName(field))) void {
                @field(self.state, @tagName(field)) = value;
                self.dirty |= dirty_masks[@backingInt(field)];
            }
        };
    };
}

// ---- usage -------------------------------------------------------------------
const Mixer = struct { title: []const u8 = "Mixer", volume: f32 = 0.5, muted: bool = false, pan: f32 = 0 };

const App = Ui(Mixer, col(.{ .pad = 8, .gap = 4 }, .{
    label("title"),
    row(.{ .gap = 8 }, .{ checkbox("mute", "muted"), slider("volume", "volume") }),
    row(.{ .gap = 8 }, .{ label("title"), slider("pan", "pan") }),
}));

export fn set_volume(rt: *App.Runtime, v: f32) void {
    rt.set(.volume, v);
}

test "everything structural is known at compile time" {
    try std.testing.expectEqual(8, App.node_count);
    try std.testing.expectEqual(u4, App.Index);
    try std.testing.expectEqual(u8, App.Mask);
    // parent links, as 4-bit indices
    try std.testing.expectEqualSlices(App.Index, &.{ 0, 0, 0, 2, 2, 0, 5, 5 }, &App.parent);
    try std.testing.expectEqualSlices(App.Index, &.{ 8, 2, 5, 4, 5, 8, 7, 8 }, &App.end);
    // volume -> slider (4), its row (2), root (0)
    try std.testing.expectEqual(@as(App.Mask, 0b0001_0101), App.dirty_masks[@backingInt(App.Field.volume)]);
    // title is shown twice: nodes 1 and 6, row 5, root
    try std.testing.expectEqual(@as(App.Mask, 0b0110_0011), App.dirty_masks[@backingInt(App.Field.title)]);
    try std.testing.expectEqual(4, @backingInt(App.Widget.volume));

    var rt: App.Runtime = .{};
    rt.dirty = 0;
    rt.set(.volume, 0.9);
    try std.testing.expectEqual(@as(App.Mask, 0b0001_0101), rt.dirty);
    const hit: App.Widget = .mute;
    switch (hit) { // forgetting a widget here is a compile error
        .mute => rt.set(.muted, true),
        .volume, .pan => {},
    }
    try std.testing.expectEqual(@as(App.Mask, 0b0001_1101), rt.dirty);
    std.debug.print("nodes={d} Index={s} Runtime bytes={d} (state {d} + rects {d} + mask {d})\n", .{
        App.node_count, @typeName(App.Index), @sizeOf(App.Runtime), @sizeOf(Mixer), @sizeOf([App.node_count][4]i16), @sizeOf(App.Mask),
    });
}
