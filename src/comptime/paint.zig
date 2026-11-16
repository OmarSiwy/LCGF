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
    const painted: []const u32 = blk: {
        @setEvalBranchQuota(10_000 + 200 * n);
        var rows: []const u32 = &.{};
        for (0..n) |i| {
            const look = p.c.look[i];
            if (((look.fill | look.border_color) >> 24) != 0 and inh.alpha[p.c.scope[i]] > 0) rows = rows ++ [_]u32{i};
        }
        break :blk rows;
    };
    const m = painted.len;

    return struct {
        pub const Cols = C;
        /// Nodes that can paint a quad: the most quads a frame emits.
        pub const quad_count = m;

        /// Row k: the node of template k.
        pub const node: [m]u32 = painted[0..m].*;
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
            for (&out, node) |*o, i| o.* = (@as(u32, p.c.look[i].texture) << 16) | p.c.look[i].material;
            break :blk out;
        };

        /// One frame's draw list from the layout outputs in `ram`: every template whose node is
        /// visible, with its rect and its parent's clip; then the commands. `d` comes from
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
            encode(d);
        }

        /// The clip `paint.emit` gives node `i`'s children, as x0, y0, x1, y1. With no clipping
        /// node `child_clip` is not kept: every row is "no clip".
        inline fn clipOf(ram: *const C.Dynamic, i: u32) [4]f32 {
            if (comptime !@hasField(C.Dynamic, "child_clip")) return @as(V4, @splat(-std.math.inf(f32))) * sign;
            return @as(V4, ram.child_clip[i]) * sign;
        }
    };
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

/// A clipping, rounded, bordered panel of tiles on two textures and two materials, one faded,
/// one unfilled, one floated out of the clip: every template field and both visibility cases.
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
        tile(.{ .fill = red, .float = true, .offset = .{ 5000, 0 } }),
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
    try testing.expectEqual(a.cmd_len, b.cmd_len);
    for (0..a.cmd_len) |k| try testing.expectEqual(a.command(@intCast(k)), b.command(@intCast(k)));
}

/// Paints `e` with the runtime tree (`Tree.push`, `layout.run`, `paint.emit`) and with
/// `Layout` and `Paint`, and requires the same draw list.
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
    paint.emit(&t, &tx, &cu, "", &want);

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
    try testing.expectEqualSlices(u32, &.{ 0, 2, 3, 4, 5, 7, 9, 11 }, &P.node);
    try testing.expectEqual([4]f32{ 0, 0, 0.5, 0.5 }, P.templates[2].uv);
    try testing.expectEqual(3 << 16, P.keys[2]);
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

test "Paint.emit: a node outside its clip paints nothing, as in the runtime tree" {
    const P = Paint(tiles, .{});
    const L = ct_layout.Layout(tiles, .{});
    var buf: [1 << 14]u8 align(64) = undefined;
    var carver: mem.Carver = .{ .buf = &buf };
    var d = DrawList.init(&carver, P.quad_count, 0, 0);
    var scratch: L.Scratch = undefined;
    var ram: P.Cols.Dynamic = undefined;
    L.run(&scratch, &ram, .{ 800, 600 });
    P.emit(&ram, &d);
    // The floated tile is template 7; it is clipped out, so one quad fewer.
    try testing.expectEqual(P.quad_count - 1, d.quad_len);
}
