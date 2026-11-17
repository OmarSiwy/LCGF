//! Paint for a comptime UI: the draw list `paint.emit` (src/draw/paint.zig) gives for the same
//! UI pushed into a runtime tree, built from read-only tables. Tier 1. Ported from
//! prototype/ui.zig (`paint.emit`, `Quad`); only where the inputs live is new.
//!
//! Every field of a node's `Quad` but `rect` and `clip` comes from its look, its paint extras
//! and the opacity and clip radii it inherits, and in a comptime UI all of those are constant.
//! So the compiler builds one **template** per node that can paint (a colour with alpha, not
//! fully transparent), in paint order, and a frame only copies the template and writes the two
//! rectangles from the layout outputs in `Dynamic`. Rows that paint nothing cost nothing.
//!
//! Not here yet: text runs (the comptime front end has no text measurement; lane
//! ct-layout-text) and custom draws (a custom widget makes every column dynamic, and `Layout`
//! refuses it). A transform needs the laid-out rect for its centre: a spec with one is a
//! compile error.

const std = @import("std");
const tree = @import("../core/tree.zig");
const columns = @import("columns.zig");
const draw_list = @import("../draw/draw_list.zig");
const encode = @import("../draw/paint.zig").encode;
const Spec = @import("spec.zig").Spec;
const Options = @import("validate.zig").Options;
const Quad = draw_list.Quad;
const none = @import("../core/types.zig").none;
const DrawList = draw_list.DrawList;

const V4 = @Vector(4, f32);
const sign: V4 = .{ 1, 1, -1, -1 };
const identity: [6]f32 = .{ 1, 0, 0, 1, 0, 0 };

/// Paint of `spec` laid out by `ct_layout.Layout(spec, options)` (see the file comment).
pub fn Paint(comptime spec: Spec, comptime options: Options) type {
    const C = columns.Columns(spec, options);
    const n = C.node_count;
    const p = C.pushed;
    for ([_][]const u8{ "look", "extra", "scope", "clips" }) |name|
        if (C.classOf(name) != .constant) @compileError("column '" ++ name ++ "' is dynamic (a custom widget builds its rows at run time): paint it with the runtime tree");

    // `draw.inherit`'s opacity and clip sweeps over the extras rows, while compiling.
    const Inherited = struct { alpha: [n + 1]f32, clip_radii: [n + 1][4]f32 };
    const inh: Inherited = blk: {
        @setEvalBranchQuota(10_000 + 200 * n);
        var out: Inherited = undefined;
        out.alpha[0] = tree.Extra.defaults.alpha;
        out.clip_radii[0] = tree.Extra.defaults.clip_radii;
        for (1..p.xlen) |r| {
            const i = p.x.node[r];
            const x = p.x.row[r];
            if (!std.mem.eql(f32, &x.transform, &identity))
                @compileError("a comptime UI with a transform needs its laid-out rect to paint: paint it with the runtime tree");
            const up = if (i == 0) 0 else p.c.scope[p.c.parent[i]];
            out.alpha[r] = x.opacity * out.alpha[up];
            const own: [4]f32 = @max(@as(V4, x.radii) - @as(V4, @splat(x.border)), @as(V4, @splat(0)));
            out.clip_radii[r] = if (p.c.clips[i] != 0) own else out.clip_radii[up];
        }
        break :blk out;
    };

    // The rows that paint a quad, in row order: `paint.emit`'s condition without `visible`.
    const in_row_order: []const u32 = blk: {
        @setEvalBranchQuota(10_000 + 200 * n);
        var rows: []const u32 = &.{};
        for (0..n) |i| {
            const look = p.c.look[i];
            if (((look.fill | look.border_color) >> 24) != 0 and inh.alpha[p.c.scope[i]] > 0) rows = rows ++ [_]u32{i};
        }
        break :blk rows;
    };
    const m = in_row_order.len;
    const painted: [m]u32 = sortByKey(C, spec, options, in_row_order[0..m].*);
    const nb = blk: {
        var b = 0;
        for (painted, 0..) |i, k| {
            const key = keyOf(p.c.look[i]);
            if (k == 0 or key != keyOf(p.c.look[painted[k - 1]])) b += 1;
        }
        break :blk b;
    };

    return struct {
        pub const Cols = C;
        /// Nodes that can paint a quad: the most quads a frame emits.
        pub const quad_count = m;

        /// Row k: the node of template k, in paint order.
        pub const node: [m]u32 = painted;
        /// Every row in the order this UI paints them: `node`, then the rows that paint
        /// nothing. `paint.emitLayered` with this order gives the same draw list as `emit`.
        pub const order: [n]u32 = blk: {
            @setEvalBranchQuota(10_000 + 20 * n * m);
            var out: [n]u32 = undefined;
            var k = 0;
            for (painted) |i| {
                out[k] = i;
                k += 1;
            }
            for (0..n) |i| if (std.mem.indexOfScalar(u32, &painted, i) == null) {
                out[k] = i;
                k += 1;
            };
            break :blk out;
        };
        /// Row k: the node whose `child_clip` clips template k, its parent.
        pub const clip_node: [m]u32 = blk: {
            var out: [m]u32 = undefined;
            for (&out, node) |*o, i| o.* = p.c.parent[i];
            break :blk out;
        };
        /// Row k: the quad template k paints, `rect` and `clip` zero. Read-only data.
        pub const templates: [m]Quad = blk: {
            @setEvalBranchQuota(10_000 + 200 * n);
            var out: [m]Quad = undefined;
            for (&out, node) |*q, i| {
                const look = p.c.look[i];
                const own = p.x.row[p.c.extra[i]];
                q.* = .{
                    .rect = @splat(0),
                    .clip = @splat(0),
                    .params = look.params,
                    .uv = own.uv,
                    .fill = look.fill,
                    .border_color = look.border_color,
                    .radii = tree.radiiOf(own.radii, look.radius),
                    .border = own.border,
                    .opacity = inh.alpha[p.c.scope[i]],
                    .xform = identity,
                    .clip_radii = inh.clip_radii[p.c.scope[p.c.parent[i]]],
                };
            }
            break :blk out;
        };
        /// Row k: template k's batch key, texture << 16 | material, as `DrawList.op.key`.
        pub const keys: [m]u32 = blk: {
            var out: [m]u32 = undefined;
            for (&out, node) |*o, i| o.* = keyOf(p.c.look[i]);
            break :blk out;
        };

        /// The commands when every template is visible, as `paint.encode` would build them:
        /// consecutive templates with equal keys form one batch. Read-only data.
        pub const Batches = struct { first: [nb]u32, count: [nb]u32, key: [nb]u32 };
        pub const batch_count = nb;
        pub const batches: Batches = blk: {
            @setEvalBranchQuota(10_000 + 200 * n);
            var out: Batches = undefined;
            var b = 0;
            for (keys, 0..) |key, k| {
                if (k == 0 or key != keys[k - 1]) {
                    out.first[b] = k;
                    out.count[b] = 0;
                    out.key[b] = key;
                    b += 1;
                }
                out.count[b - 1] += 1;
            }
            break :blk out;
        };

        pub const Dirty = std.bit_set.Static(m);
        /// Payload fields independent of visibility, batch keys, layout and inherited styles.
        /// RGB preserves template alpha. Material data preserves the static feature selector.
        pub const Target = enum { fill_rgb, border_rgb, material_data, uv };

        pub fn Binding(comptime State: type) type {
            return struct { field: std.meta.FieldEnum(State), node: u32, target: Target };
        }

        /// Resolve state fields to template indices while compiling. A field setter visits
        /// just its own entries. For clipped layouts, advance through visibility once to
        /// translate sorted template indices into the compacted draw list.
        pub fn Patches(comptime State: type, comptime bindings: []const Binding(State)) type {
            const Field = std.meta.FieldEnum(State);
            const Entry = struct { template: u32, target: Target };
            for (bindings, 0..) |b, k| {
                if (std.mem.indexOfScalar(u32, &painted, b.node) == null)
                    @compileError("paint binding must target a painted node");
                const Value = switch (b.target) {
                    .fill_rgb, .border_rgb => types.Color,
                    .material_data => [3]f32,
                    .uv => [4]f32,
                };
                if (@FieldType(State, @tagName(b.field)) != Value)
                    @compileError("invalid paint binding type for field '" ++ @tagName(b.field) ++ "'");
                for (bindings[0..k]) |prev| if (prev.node == b.node and prev.target == b.target)
                    @compileError("multiple paint bindings write one quad field");
            }
            return struct {
                pub fn list(comptime field: Field) []const Entry {
                    comptime var entries: []const Entry = &.{};
                    inline for (painted, 0..) |i, k| inline for (bindings) |b| {
                        if (b.node == i and b.field == field)
                            entries = entries ++ [_]Entry{.{ .template = k, .target = b.target }};
                    };
                    return entries;
                }

                pub fn apply(comptime field: Field, state: *const State, ram: *const C.Dynamic, d: *DrawList, dirty: *Dirty) void {
                    const value = @field(state, @tagName(field));
                    var cursor: usize = 0;
                    var visible: usize = 0;
                    inline for (comptime list(field)) |entry| {
                        const k = entry.template;
                        const row: ?usize = if (d.quad_len == m) k else blk: {
                            for (node[cursor..k]) |i| visible += ram.visible[i];
                            cursor = k;
                            break :blk if (ram.visible[node[k]] != 0) visible else null;
                        };
                        if (row) |i| {
                            const q = &d.quads[i];
                            switch (entry.target) {
                                .fill_rgb => q.fill = (q.fill & 0xff000000) | (value.bitsOf() & 0xffffff),
                                .border_rgb => q.border_color = (q.border_color & 0xff000000) | (value.bitsOf() & 0xffffff),
                                .material_data => q.params[1..4].* = value,
                                .uv => q.uv = value,
                            }
                            dirty.set(i);
                        }
                    }
                }

                /// Rebuild after layout/visibility changes or before the first upload.
                pub fn rebuild(state: *const State, ram: *const C.Dynamic, d: *DrawList, dirty: *Dirty) void {
                    emit(ram, d);
                    inline for (@typeInfo(State).@"struct".field_names) |name|
                        apply(@field(Field, name), state, ram, d, dirty);
                    dirty.* = .full;
                }
            };
        }

        /// One frame's draw list from the layout outputs in `ram`: every template whose node is
        /// visible, with its rect and its parent's clip; then the commands: `batches` when every
        /// template is visible, else `paint.encode` over the ops (a hidden quad shifts the
        /// batches after it and may join its neighbours). `d` comes from
        /// `DrawList.init(carver, quad_count, 0, 0)` or larger.
        pub fn emit(ram: *const C.Dynamic, d: *DrawList) void {
            var q: u32 = 0;
            for (0..m) |k| {
                const i = node[k];
                var quad = templates[k];
                quad.rect = .{ f32Of(ram.rect[0][i]), f32Of(ram.rect[1][i]), f32Of(ram.rect[2][i]), f32Of(ram.rect[3][i]) };
                quad.clip = clipOf(ram, clip_node[k]);
                d.quads[q] = quad;
                d.op.kind[q] = @backingInt(DrawList.Kind.quads);
                d.op.key[q] = keys[k];
                d.op.ref[q] = q;
                q += ram.visible[i];
            }
            d.quad_len = q;
            d.op_len = q;
            d.run_len = 0;
            d.custom_len = 0;
            d.strings = "";
            // Once per frame, not per row.
            if (q == m) {
                @memset(d.cmd.kind[0..nb], @backingInt(DrawList.Kind.quads));
                @memcpy(d.cmd.first[0..nb], &batches.first);
                @memcpy(d.cmd.count[0..nb], &batches.count);
                @memcpy(d.cmd.key[0..nb], &batches.key);
                d.cmd_len = nb;
            } else encode(d);
        }

        /// The clip `paint.emit` gives node `i`'s children, as x0, y0, x1, y1. With no clipping
        /// node `child_clip` is not kept: every row is "no clip".
        inline fn clipOf(ram: *const C.Dynamic, i: u32) [4]f32 {
            if (comptime !@hasField(C.Dynamic, "child_clip")) return @as(V4, @splat(-std.math.inf(f32))) * sign;
            return @as(V4, ram.child_clip[i]) * sign;
        }
    };
}

/// `rows` (the nodes that paint, in row order) reordered so that equal batch keys follow each
/// other where that cannot change the picture. A comptime UI has one stacking layer (it has no
/// overlay), so the order within it is row order, and a quad may move before an earlier one
/// only when their rects provably never overlap: both lie in one subtree that `Layout` folds
/// (its positions relative to the subtree's root and its sizes are the same in every viewport)
/// and their rects, from the compiler's layout, are at least 1 px apart on some axis (a margin
/// for rounding and antialiased edges). Clips only shrink what a quad covers. Greedy: emit the
/// earliest quad that may go next with the key of the one just emitted, else the earliest
/// that may go next. Quads with the same key keep their order, so do any two that may overlap.
fn sortByKey(comptime C: type, comptime spec: Spec, comptime options: Options, comptime rows: anytype) @TypeOf(rows) {
    const m = rows.len;
    if (m < 3) return rows;
    // With one batch key the input is already in its final order.
    if (for (rows[1..]) |r| {
        if (keyOf(C.pushed.c.look[r]) != keyOf(C.pushed.c.look[rows[0]])) break false;
    } else true) return rows;
    const n = C.node_count;
    const p = C.pushed;
    const plan = @import("layout.zig").FoldPlan(C);
    @setEvalBranchQuota(100_000 + 1_000 * n + 50 * m * m * m);
    // The fold root each row lies under (itself for a root), or `none`.
    var group: [n]u32 = @splat(none);
    for (0..n) |i| if (plan.root[i]) for (i..p.c.end[i]) |j| {
        group[j] = i;
    };
    const P = @import("layout.zig").Plain(spec, options);
    var scratch: P.Scratch = undefined;
    P.passes(&scratch, .{ 1000, 1000 });
    const apart = struct {
        fn f(a: u32, b: u32, comptime gr: [n]u32, sc: anytype) bool {
            if (gr[a] == none or gr[a] != gr[b]) return false;
            const shadow = @backingInt(@import("../draw/features.zig").Kind.shadow);
            for ([_]u32{ a, b }) |i| {
                if (@as(u32, @bitCast(p.c.look[i].params[0])) == shadow) return false;
            }
            for (0..2) |ax| {
                const a0 = sc.pos[ax][a];
                const b0 = sc.pos[ax][b];
                if (a0 + sc.size[ax][a] + 1 <= b0 or b0 + sc.size[ax][b] + 1 <= a0) return true;
            }
            return false;
        }
    }.f;
    var out: [m]u32 = undefined;
    var done: [m]bool = @splat(false);
    var last: u32 = none;
    for (&out) |*o| {
        var pick: u32 = none;
        var first_ready: u32 = none;
        for (0..m) |k| {
            if (done[k]) continue;
            const ready = for (0..k) |j| {
                if (!done[j] and !apart(rows[j], rows[k], group, &scratch)) break false;
            } else true;
            if (!ready) continue;
            if (first_ready == none) first_ready = k;
            if (keyOf(p.c.look[rows[k]]) == last) {
                pick = k;
                break;
            }
        }
        if (pick == none) pick = first_ready;
        done[pick] = true;
        o.* = rows[pick];
        last = keyOf(p.c.look[rows[pick]]);
    }
    return out;
}

fn keyOf(look: tree.Look) u32 {
    return (@as(u32, look.texture) << 16) | look.material;
}

inline fn f32Of(x: anytype) f32 {
    return if (@TypeOf(x) == f32) x else @floatFromInt(x);
}

// ---- tests -------------------------------------------------------------------------------------

const testing = std.testing;
const sp = @import("spec.zig");
const examples = @import("examples.zig");
const ct_layout = @import("layout.zig");
const layout = @import("../layout/layout.zig");
const paint = @import("../draw/paint.zig");
const mem = @import("../core/mem.zig");
const Texts = @import("../core/texts.zig").Texts;
const Customs = @import("../core/customs.zig").Customs;
const types = @import("../core/types.zig");
const Id = types.Id;
const Layers = @import("../layout/overlay.zig").Layers;

/// A clipping, rounded, bordered panel of tiles on two textures and two materials, one faded,
/// one unfilled, one floated: every template field and both visibility cases.
pub const tiles = blk: {
    const tex: types.Texture = @fromBackingInt(3);
    const mat: types.Material = @fromBackingInt(2);
    const red: types.Color = .rgb(200, 0, 0);
    break :blk sp.col(.{ .pad = @splat(4), .gap = 2, .fill = .rgb(20, 20, 30), .clip = true, .radius = 6, .border = 1, .border_color = .white }, .{
        sp.row(.{ .gap = 2 }, .{
            tile(.{ .fill = red }),
            tile(.{ .fill = red, .texture = tex, .uv = .{ 0, 0, 0.5, 0.5 } }),
            tile(.{ .fill = red }),
            tile(.{ .fill = red, .material = mat, .params = .{ 1, 2, 3, 4 } }),
        }),
        sp.row(.{ .gap = 2, .opacity = 0.5 }, .{
            tile(.{ .fill = red, .texture = tex, .radii = .{ 1, -1, 3, -1 }, .radius = 2 }),
            tile(.{}),
            tile(.{ .fill = .transparent, .border = 2, .border_color = red }),
            tile(.{ .fill = red, .opacity = 0 }),
        }),
        tile(.{ .fill = red, .float = true, .offset = .{ 40, 2 } }),
    });
};

fn tile(comptime st: types.Style) Spec {
    var x = st;
    x.size = .{ .px(16), .px(16) };
    return sp.col(x, .{});
}

const paint_examples = examples.all ++ [_]examples.Example{.{ .name = "tiles", .State = struct {}, .spec = tiles }};

fn pushAll(t: anytype, comptime s: Spec, parent: u32) void {
    const id: Id = if (s.id) |name| .hash(name) else .none;
    const i = t.push(parent, id, &s.style);
    inline for (s.children) |c| pushAll(t, c, i);
    t.seal(i);
}

/// `a` equals `b`: quad bytes, text runs, custom draws and commands.
fn expectSameDraw(a: *const DrawList, b: *const DrawList) !void {
    try testing.expectEqual(a.quad_len, b.quad_len);
    try testing.expectEqualSlices(u8, a.quadBytes(), b.quadBytes());
    try testing.expectEqual(a.run_len, b.run_len);
    try testing.expectEqual(a.custom_len, b.custom_len);
    try testing.expectEqualSlices(u8, a.strings, b.strings);
    try testing.expectEqual(a.op_len, b.op_len);
    try testing.expectEqualSlices(u8, a.op.kind[0..a.op_len], b.op.kind[0..b.op_len]);
    try testing.expectEqualSlices(u32, a.op.key[0..a.op_len], b.op.key[0..b.op_len]);
    try testing.expectEqualSlices(u32, a.op.ref[0..a.op_len], b.op.ref[0..b.op_len]);
    try testing.expectEqual(a.cmd_len, b.cmd_len);
    for (0..a.cmd_len) |k| try testing.expectEqual(a.command(@intCast(k)), b.command(@intCast(k)));
}

/// Paints `e` with the runtime tree (`Tree.push`, `layout.run`, `paint.emitLayered` in
/// `Paint.order`: row order but for the quads `sortByKey` moved) and with `Layout` and
/// `Paint`, and requires the same draw list.
fn expectSamePaint(comptime e: examples.Example, viewport: [2]f32) !void {
    const L = ct_layout.Layout(e.spec, e.options);
    const P = Paint(e.spec, e.options);
    const C = P.Cols;
    var buf: [1 << 18]u8 align(64) = undefined;
    var carver: mem.Carver = .{ .buf = &buf };
    var t = tree.Tree.init(&carver, C.node_count);
    var tx = Texts.init(&carver, 1);
    var cu = Customs.init(&carver, 1);
    var want = DrawList.init(&carver, C.node_count, 1, 1);
    var got = DrawList.init(&carver, P.quad_count, 0, 0);
    pushAll(&t, e.spec, 0);
    layout.run(&t, &tx, viewport);
    // Independent painter-order oracle: every inversion must be disjoint in the actual
    // runtime layout. Equal commands in a shared order alone cannot establish this.
    for (P.node, 0..) |i, k| for (P.node[k + 1 ..]) |j| {
        if (i < j or t.c.visible[i] == 0 or t.c.visible[j] == 0) continue;
        const a = t.rect(i);
        const b = t.rect(j);
        try testing.expect(a.x1 <= b.x0 or b.x1 <= a.x0 or a.y1 <= b.y0 or b.y1 <= a.y0);
    };
    var order = P.order;
    const ly: Layers = .{ .c = .{ .own = &.{}, .layer = &.{}, .order = &order } };
    paint.emitLayered(&t, &tx, &cu, "", &ly, &want);

    var scratch: L.Scratch = undefined;
    var ram: C.Dynamic = undefined;
    L.run(&scratch, &ram, viewport);
    P.emit(&ram, &got);
    try expectSameDraw(&want, &got);
}

test "Paint.templates: one read-only quad per node that can paint, every field but the rects" {
    const P = Paint(tiles, .{});
    // The panel and seven tiles: not the rows, the unfilled tile or the transparent one.
    try testing.expectEqual(8, P.quad_count);
    // In paint order: the second white tile of the first row is sorted before the textured one.
    try testing.expectEqualSlices(u32, &.{ 0, 2, 4, 3, 5, 7, 9, 11 }, &P.node);
    try testing.expectEqual([4]f32{ 0, 0, 0.5, 0.5 }, P.templates[3].uv);
    try testing.expectEqual(3 << 16, P.keys[3]);
    try testing.expectEqual(2, P.keys[4]);
    try testing.expectEqual([4]f32{ 1, 2, 3, 4 }, P.templates[4].params);
    // The faded row's tiles take its opacity; the corner radii fill in from `radius`.
    try testing.expectEqual(0.5, P.templates[5].opacity);
    try testing.expectEqual([4]f32{ 1, 2, 3, 2 }, P.templates[5].radii);
    // Children of the clipping panel get its radii less its border as clip radii.
    try testing.expectEqual([4]f32{ 5, 5, 5, 5 }, P.templates[1].clip_radii);
    // The root is its own parent, so it is clipped by its own clip, as `paint.emit` does.
    try testing.expectEqual([4]f32{ 5, 5, 5, 5 }, P.templates[0].clip_radii);
}

test "Paint.emit: equals paint.emit over the runtime tree, every example and viewport" {
    inline for (paint_examples) |e| if (comptime !std.mem.eql(u8, e.name, "custom")) {
        inline for (.{ [2]f32{ 800, 600 }, [2]f32{ 320, 240 }, [2]f32{ 96, 64 }, [2]f32{ 30, 20 }, [2]f32{ 1, 1 }, [2]f32{ 333.5, 21.25 } }) |vp| {
            const max = e.options.viewport orelse .{ std.math.inf(f32), std.math.inf(f32) };
            if (vp[0] <= max[0] and vp[1] <= max[1]) try expectSamePaint(e, vp);
        }
    };
}

test "Paint.emit: a node outside its parent's clip paints nothing" {
    const P = Paint(tiles, .{});
    const L = ct_layout.Layout(tiles, .{});
    var buf: [1 << 14]u8 align(64) = undefined;
    var carver: mem.Carver = .{ .buf = &buf };
    var d = DrawList.init(&carver, P.quad_count, 0, 0);
    var scratch: L.Scratch = undefined;
    var ram: P.Cols.Dynamic = undefined;
    L.run(&scratch, &ram, .{ 800, 600 });
    P.emit(&ram, &d);
    try testing.expectEqual(P.quad_count, d.quad_len);
    // In a 30 x 20 panel (clip 1..29 x 1..19) only the first two tiles of the first row show,
    // the second in part.
    L.run(&scratch, &ram, .{ 30, 20 });
    P.emit(&ram, &d);
    try testing.expectEqual(3, d.quad_len);
}

test "Paint.batches: the commands of a frame with every quad visible, computed while compiling" {
    const P = Paint(tiles, .{});
    // Keys in paint order: white x3, texture 3, material 2, texture 3, white x2.
    try testing.expectEqual(5, P.batch_count);
    try testing.expectEqualSlices(u32, &.{ 0, 3, 4, 5, 6 }, &P.batches.first);
    try testing.expectEqualSlices(u32, &.{ 3, 1, 1, 1, 2 }, &P.batches.count);
    const L = ct_layout.Layout(tiles, .{});
    var buf: [1 << 14]u8 align(64) = undefined;
    var carver: mem.Carver = .{ .buf = &buf };
    var d = DrawList.init(&carver, P.quad_count, 0, 0);
    var scratch: L.Scratch = undefined;
    var ram: P.Cols.Dynamic = undefined;
    L.run(&scratch, &ram, .{ 800, 600 });
    P.emit(&ram, &d);
    try testing.expectEqual(P.batch_count, d.cmd_len);
    // The same as encoding the op stream at run time.
    const table = d.command(1);
    encode(&d);
    try testing.expectEqual(P.batch_count, d.cmd_len);
    try testing.expectEqual(table, d.command(1));
}

test "sortByKey: quads join their key's batch only past quads they cannot overlap" {
    // In row order the tiles give 6 batches; sorted, the first row's two white tiles run on
    // into the panel's batch. The textured tile of the second row stays after the first row's
    // material tile: they lie in different folded subtrees, so nothing proves them apart.
    try testing.expectEqual(5, Paint(tiles, .{}).batch_count);
    // Overlapping tiles (floated onto each other) keep row order: white, texture, white.
    const tex: types.Texture = @fromBackingInt(3);
    const stacked = comptime sp.col(.{}, .{sp.row(.{}, .{
        tile(.{ .fill = .white }),
        tile(.{ .fill = .white, .texture = tex, .float = true, .offset = .{ 4, 4 } }),
        tile(.{ .fill = .white, .float = true, .offset = .{ 8, 8 } }),
    })});
    const P = Paint(stacked, .{});
    try testing.expectEqualSlices(u32, &.{ 2, 3, 4 }, &P.node);
    try testing.expectEqual(3, P.batch_count);
    try expectSamePaint(.{ .name = "stacked", .State = struct {}, .spec = stacked }, .{ 100, 100 });
}

test "Paint.Patches: per-field lists target visible compacted instances" {
    const P = Paint(tiles, .{});
    const L = ct_layout.Layout(tiles, .{});
    const State = struct { color: types.Color, sample: [4]f32, unrelated: bool };
    const Patch = P.Patches(State, &.{
        .{ .field = .color, .node = 3, .target = .fill_rgb },
        .{ .field = .color, .node = 4, .target = .fill_rgb },
        .{ .field = .sample, .node = 3, .target = .uv },
    });
    try testing.expectEqual(2, Patch.list(.color).len);
    try testing.expectEqual(0, Patch.list(.unrelated).len);
    var buf: [1 << 14]u8 align(64) = undefined;
    var carver: mem.Carver = .{ .buf = &buf };
    var d = DrawList.init(&carver, P.quad_count, 0, 0);
    var scratch: L.Scratch = undefined;
    var ram: P.Cols.Dynamic = undefined;
    var dirty: P.Dirty = .empty;
    var state: State = .{ .color = .rgba(10, 20, 30, 0), .sample = .{ 1, 2, 3, 4 }, .unrelated = false };
    L.run(&scratch, &ram, .{ 30, 20 });
    Patch.rebuild(&state, &ram, &d, &dirty);
    try testing.expectEqual(types.Color.rgb(10, 20, 30).bitsOf(), d.quads[2].fill);
    try testing.expectEqual(state.sample, d.quads[2].uv);
    dirty = .empty;
    state.color = .white;
    Patch.apply(.color, &state, &ram, &d, &dirty);
    try testing.expectEqual(1, dirty.count());
    try testing.expect(dirty.isSet(2));
    try testing.expectEqual(types.Color.white.bitsOf(), d.quads[2].fill);
}

test "sortByKey: shadow expansion preserves the original painter order" {
    const features = @import("../draw/features.zig");
    const spec = comptime sp.row(.{ .gap = 2 }, .{
        tile(.{ .fill = .white }),
        tile(.{ .fill = .white, .texture = @fromBackingInt(1), .params = features.shadow(5) }),
        tile(.{ .fill = .white }),
    });
    try testing.expectEqualSlices(u32, &.{ 1, 2, 3 }, &Paint(spec, .{}).node);
}

test "paint patches across clipped, resized and unchanged frames match the runtime tree" {
    const P = Paint(tiles, .{});
    const L = ct_layout.Layout(tiles, .{});
    const State = struct { color: types.Color, sample: [4]f32, material: [3]f32 };
    const Patch = P.Patches(State, &.{
        .{ .node = 2, .field = .color, .target = .fill_rgb },
        .{ .node = 3, .field = .color, .target = .fill_rgb },
        .{ .node = 9, .field = .color, .target = .border_rgb },
        .{ .node = 3, .field = .sample, .target = .uv },
        .{ .node = 5, .field = .material, .target = .material_data },
    });
    var buf: [1 << 16]u8 align(64) = undefined;
    var carver: mem.Carver = .{ .buf = &buf };
    var t = tree.Tree.init(&carver, P.Cols.node_count);
    var tx = Texts.init(&carver, 1);
    var cu = Customs.init(&carver, 1);
    var want = DrawList.init(&carver, P.Cols.node_count, 1, 1);
    var got = DrawList.init(&carver, P.quad_count, 0, 0);
    pushAll(&t, tiles, 0);
    var order = P.order;
    const ly: Layers = .{ .c = .{ .own = &.{}, .layer = &.{}, .order = &order } };
    var scratch: L.Scratch = undefined;
    var ram: P.Cols.Dynamic = undefined;
    var state: State = .{ .color = .white, .sample = .{ 0, 0, 1, 1 }, .material = .{ 1, 2, 3 } };
    var dirty: P.Dirty = .empty;
    var uploaded: [P.quad_count]Quad = undefined;
    for ([_][2]f32{ .{ 800, 600 }, .{ 30, 20 }, .{ 1, 1 }, .{ 800, 600 } }) |vp| {
        L.run(&scratch, &ram, vp);
        layout.run(&t, &tx, vp);
        Patch.rebuild(&state, &ram, &got, &dirty);
        for (0..3) |frame| {
            if (frame == 1) {
                state.color = .rgb(state.color.b +% 15, state.color.r +% 37, state.color.g);
                state.sample[0] += 0.125;
                state.material[1] += 2.5;
                Patch.apply(.sample, &state, &ram, &got, &dirty);
                Patch.apply(.material, &state, &ram, &got, &dirty);
                Patch.apply(.color, &state, &ram, &got, &dirty);
            }
            for ([_]u32{ 2, 3 }) |i| t.c.look[i].fill = state.color.bitsOf();
            t.c.look[9].border_color = state.color.bitsOf();
            t.x.row[t.c.extra[3]].uv = state.sample;
            t.c.look[5].params[1..4].* = state.material;
            paint.emitLayered(&t, &tx, &cu, "", &ly, &want);
            try expectSameDraw(&want, &got);

            var changed = dirty.iterator(.{});
            while (changed.next()) |i| {
                if (i < got.quad_len) uploaded[i] = got.quads[i];
            }
            try testing.expectEqualSlices(u8, want.quadBytes(), std.mem.sliceAsBytes(uploaded[0..got.quad_len]));
            dirty = .empty;
        }
    }
}
