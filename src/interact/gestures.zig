//! gestures: wheel and scroll routing, and the gestures built from pointer and touch input.
//! Tier 0: no allocator, no I/O. Reads `Input.wheel` and `Input.scroll` (prototype/ui.zig
//! `Input.wheel`) and last frame's tree, as `Interaction.step` does.

const std = @import("std");
const simd = @import("../core/simd.zig");
const types = @import("../core/types.zig");
const mem = @import("../core/mem.zig");
const Tree = @import("../core/tree.zig").Tree;
const Input = @import("../core/input.zig").Input;
const none = types.none;

const W = simd.lanes;

/// Which nodes scroll, and on which axes. One row per node of the tree it describes; the
/// caller keeps it with that tree (last frame's, for `route`).
pub const Scrollables = struct {
    c: Columns,

    /// `axes` bits.
    pub const x: u8 = 1;
    pub const y: u8 = 2;

    pub const Columns = struct {
        /// Set by the caller: `x`, `y` or both for a node that scrolls its content.
        axes: []u8,
    };

    pub fn init(carver: *mem.Carver, cap: u32) Scrollables {
        std.debug.assert(cap > 0);
        return .{ .c = carver.columns(Columns, simd.rows(cap)) };
    }
    /// Nothing scrolls, for the next frame.
    pub fn reset(sc: *Scrollables) void {
        @memset(sc.c.axes, 0);
    }
};

/// Where this frame's wheel goes, per axis.
pub const Wheel = struct {
    /// Row in the tree passed to `route` of the innermost node that scrolls on that axis and
    /// is under the pointer, or `none`.
    node: [2]u32 = .{ none, none },
    /// That node's id, or 0, to find its scroll state in the application.
    id: [2]u32 = .{ 0, 0 },
    /// Logical pixels on each axis, `wheel * line + scroll`, in `Input`'s sign; zero on an axis
    /// with no target, so nothing else scrolls by it.
    delta: [2]f32 = .{ 0, 0 },
};

/// Routes the wheel and pixel scroll of `in` on each axis to the innermost node that scrolls on
/// that axis and whose visible rect holds the pointer: a horizontal strip inside a vertical
/// list takes x and leaves y to the list. "Innermost" is the latest row: a descendant comes
/// after its ancestors, and of two overlapping siblings the later is on top. `line` is the
/// pixels one wheel notch moves. One SIMD sweep for both axes, no early exit.
pub fn route(t: *const Tree, sc: *const Scrollables, in: *const Input, line: f32) Wheel {
    const c = &t.c;
    const px = simd.f(in.pointer[0]);
    const py = simd.f(in.pointer[1]);
    const zero8: simd.Bytes = @splat(0);
    var best: [2]simd.U = .{ simd.u(none), simd.u(none) };
    const n = simd.padded(t.len);
    var i: usize = 0;
    while (i < n) : (i += W) {
        const inside = (px >= simd.loadF(c.vis[0], i)) & (px < simd.loadF(c.vis[2], i)) &
            (py >= simd.loadF(c.vis[1], i)) & (py < simd.loadF(c.vis[3], i));
        const axes: simd.Bytes = sc.c.axes[i..][0..W].*;
        const r = simd.iota + simd.u(@intCast(i));
        inline for (0..2) |a| {
            const take = inside & ((axes & @as(simd.Bytes, @splat(1 << a))) != zero8);
            best[a] = @select(u32, take, r, best[a]);
        }
    }
    var out: Wheel = .{};
    inline for (0..2) |a| {
        // Latest row per lane, then across lanes; `none +% 1` is 0, so empty lanes lose.
        const node = @reduce(.Max, best[a] +% simd.u(1)) -% 1;
        const found = node != none;
        out.node[a] = node;
        // Select the address, then load: a select (or a multiply) on the loaded id became a
        // branch around the load (docs/CHECKS.md, as in `Interaction.step`).
        const id_at = [2]*const u32{ &zero_id, &c.id[@min(node, t.cap - 1)] };
        out.id[a] = id_at[@intFromBool(found)].*;
        out.delta[a] = (in.wheel[a] * line + in.scroll[a]) * simd.b2f(found);
    }
    return out;
}

/// What `route` reads as the id when an axis has no target.
const zero_id: u32 = 0;

const testing = std.testing;

/// root 300 x 300 { list (scrolls y, 200 x 100, clips) { strip (scrolls x, 200 x 40, clips)
/// { 4 cards 80 x 40 }, row 200 x 40, row, row } }. The list's content is 160 high.
const Feed = struct {
    raw: [64 * 1024]u8 align(mem.column_align) = undefined,
    t: Tree = undefined,
    sc: Scrollables = undefined,
    list: u32 = 0,
    strip: u32 = 0,

    fn build(f: *Feed, list_scroll: f32) void {
        const layout = @import("../layout/layout.zig");
        const Texts = @import("../core/texts.zig").Texts;
        var carver: mem.Carver = .{ .buf = &f.raw };
        f.t = Tree.init(&carver, 16);
        var tx = Texts.init(&carver, 1);
        f.sc = Scrollables.init(&carver, 16);
        const t = &f.t;
        const root = t.push(0, .none, &.{ .size = .{ .px(300), .px(300) } });
        f.list = t.push(root, types.Id.from("list"), &.{ .size = .{ .px(200), .px(100) }, .clip = true, .scroll = .{ 0, list_scroll } });
        f.sc.c.axes[f.list] = Scrollables.y;
        f.strip = t.push(f.list, types.Id.from("strip"), &.{ .dir = .x, .size = .{ .px(200), .px(40) }, .clip = true });
        f.sc.c.axes[f.strip] = Scrollables.x;
        for (0..4) |_| t.seal(t.push(f.strip, .none, &.{ .size = .{ .px(80), .px(40) } }));
        t.seal(f.strip);
        for (0..3) |_| t.seal(t.push(f.list, .none, &.{ .size = .{ .px(200), .px(40) } }));
        t.seal(f.list);
        t.seal(root);
        layout.run(t, &tx, .{ 300, 300 });
    }
};

test "route: each axis goes to the innermost node that scrolls on it" {
    var f: Feed = .{};
    f.build(0);
    const list_id = @backingInt(types.Id.from("list"));
    const strip_id = @backingInt(types.Id.from("strip"));
    // Over a card in the strip: x to the strip, y to the list.
    var in: Input = .{ .pointer = .{ 50, 20 }, .wheel = .{ 1, -2 }, .scroll = .{ 3, 0.5 } };
    var w = route(&f.t, &f.sc, &in, 16);
    try testing.expectEqual([2]u32{ f.strip, f.list }, w.node);
    try testing.expectEqual([2]u32{ strip_id, list_id }, w.id);
    try testing.expectEqual([2]f32{ 19, -31.5 }, w.delta);
    // Over a row below the strip: only y has a target; x is dropped.
    in.pointer = .{ 50, 60 };
    w = route(&f.t, &f.sc, &in, 16);
    try testing.expectEqual([2]u32{ none, f.list }, w.node);
    try testing.expectEqual([2]u32{ 0, list_id }, w.id);
    try testing.expectEqual([2]f32{ 0, -31.5 }, w.delta);
    // Outside the list, and outside the window: nothing.
    in.pointer = .{ 250, 20 };
    try testing.expectEqual(Wheel{}, route(&f.t, &f.sc, &in, 16));
    in.pointer = .{ -1, -1 };
    try testing.expectEqual(Wheel{}, route(&f.t, &f.sc, &in, 16));
}

test "route: a strip scrolled out of its list's clip no longer takes the wheel" {
    var f: Feed = .{};
    // The list scrolled down 50: the strip (40 high) is above the list's top edge.
    f.build(50);
    const in: Input = .{ .pointer = .{ 50, 20 }, .wheel = .{ 1, 1 } };
    const w = route(&f.t, &f.sc, &in, 10);
    try testing.expectEqual([2]u32{ none, f.list }, w.node);
    // A node that is not scrollable takes nothing, whatever it covers.
    f.sc.reset();
    try testing.expectEqual(Wheel{}, route(&f.t, &f.sc, &in, 10));
}
