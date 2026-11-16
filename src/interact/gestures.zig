//! gestures: wheel and scroll routing, and the gestures built from pointer and touch input.
//! Tier 0: no allocator, no I/O. Reads `Input.wheel` and `Input.scroll` (prototype/ui.zig
//! `Input.wheel`) and last frame's tree, as `Interaction.step` does.

const std = @import("std");
const simd = @import("../core/simd.zig");
const types = @import("../core/types.zig");
const mem = @import("../core/mem.zig");
const Tree = @import("../core/tree.zig").Tree;
const Input = @import("../core/input.zig").Input;
const Interaction = @import("interaction.zig").Interaction;
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

/// Kinetic scrolling: one row per scroll axis that moves on its own after a fling, stepped
/// together as prototype/ui.zig `Anims.step` steps its springs. Inside its range a row coasts
/// and slows by `friction`; past either end a spring (`Anims`' stiffness and damping) pulls it
/// back to the end, so a fling overshoots and settles and a drag past the end rubber-bands.
pub const Kinetic = struct {
    len: u32 = 0,
    cap: u32,
    c: Columns,
    /// Velocity lost per second while coasting, as a fraction: v *= exp(-friction * dt).
    friction: f32 = 4,
    /// The pull back from past an end (prototype `Spring` defaults).
    stiffness: f32 = 170,
    damping: f32 = 26,
    /// A drag past an end moves the content by this fraction of the pointer's movement.
    resistance: f32 = 0.5,

    pub const Columns = struct {
        /// The scroller's id and axis, as the caller chooses to key them.
        id: []u32,
        /// Scroll offset in logical pixels.
        x: []f32,
        /// Pixels per second.
        v: []f32,
        /// Range the offset rests in: 0 and content minus viewport, usually.
        lo: []f32,
        hi: []f32,
        /// 1.0 while a finger or the mouse holds the content: no coasting, no spring.
        held: []f32,
    };

    pub fn init(carver: *mem.Carver, cap: u32) Kinetic {
        std.debug.assert(cap > 0);
        return .{ .cap = cap, .c = carver.columns(Columns, simd.rows(cap)) };
    }

    /// Row for `id`, created at rest at offset `initial` with range [lo, hi] on first use; the
    /// range is updated every call (content and viewport change). SIMD lookup. A full table
    /// reuses its last row.
    pub fn slot(k: *Kinetic, id: u32, initial: f32, lo: f32, hi: f32) u32 {
        const c = &k.c;
        const found = simd.find(c.id, k.len, id);
        const is_new = found == none;
        const i = simd.selU(is_new, @min(k.len, k.cap - 1), found);
        k.len = @min(k.len + @intFromBool(is_new), k.cap);
        c.id[i] = id;
        c.x[i] = simd.selF(is_new, initial, c.x[i]);
        c.v[i] = simd.selF(is_new, 0, c.v[i]);
        c.held[i] = simd.selF(is_new, 0, c.held[i]);
        c.lo[i] = lo;
        c.hi[i] = @max(lo, hi);
        return i;
    }

    /// A wheel notch or touchpad delta (`Wheel.delta`): moves at once, kept in range, and stops
    /// any coasting.
    pub fn scroll(k: *Kinetic, i: u32, delta: f32) void {
        const c = &k.c;
        c.x[i] = std.math.clamp(c.x[i] + delta, c.lo[i], c.hi[i]);
        c.v[i] = 0;
    }

    /// The content is held and moved by `delta` this frame of `dt` seconds (a finger or a
    /// mouse drag, in scroll direction). Past an end it moves by `resistance` of that. The
    /// velocity follows the movement, so `release` flings at the speed of the last frames.
    pub fn drag(k: *Kinetic, i: u32, delta: f32, dt: f32) void {
        const c = &k.c;
        const x = c.x[i];
        const out = simd.orB(x < c.lo[i], x > c.hi[i]);
        const d = delta * simd.selF(out, k.resistance, 1);
        c.x[i] = x + d;
        // Half the last estimate, half this frame: smooths one-frame jitter.
        c.v[i] = 0.5 * c.v[i] + 0.5 * d / @max(dt, 1e-4);
        c.held[i] = 1;
    }

    /// Lets go: the row coasts at its velocity (a fling), or springs back if past an end.
    pub fn release(k: *Kinetic, i: u32) void {
        k.c.held[i] = 0;
    }

    /// SIMD. Advances every free row by `dt` seconds. Returns how much is still moving, in
    /// pixels plus pixels per second; 0 means every row is at rest (the host may sleep).
    pub fn step(k: *Kinetic, dt: f32) f32 {
        const c = &k.c;
        const h = @min(dt, 1.0 / 30.0);
        const hv = simd.f(h);
        const decay = simd.f(@exp(-k.friction * h));
        const stiff = simd.f(k.stiffness);
        const damp = simd.f(k.damping);
        const zero = simd.f(0);
        var motion = zero;
        const n = simd.padded(k.len);
        var i: usize = 0;
        while (i < n) : (i += W) {
            const x = simd.loadF(c.x, i);
            const v = simd.loadF(c.v, i);
            const lo = simd.loadF(c.lo, i);
            const hi = simd.loadF(c.hi, i);
            const free = simd.loadF(c.held, i) == zero;
            const end = @min(@max(x, lo), hi);
            const out = end != x;
            const pulled = v + (stiff * (end - x) - damp * v) * hv;
            const v1 = @select(f32, out, pulled, v * decay);
            const x1 = x + v1 * hv;
            const end1 = @min(@max(x1, lo), hi);
            const left = @abs(end1 - x1);
            const speed = @abs(v1);
            // At rest: inside (or within a thousandth of an end) and slower than a pixel per
            // ten seconds. Snaps to the end and stops.
            const rest = (left < simd.f(1e-3)) & (speed < simd.f(0.1));
            simd.storeF(c.x, i, @select(f32, free, @select(f32, rest, end1, x1), x));
            simd.storeF(c.v, i, @select(f32, free, @select(f32, rest, zero, v1), v));
            motion = @max(motion, @select(f32, free & !rest, left + speed, zero));
        }
        return @reduce(.Max, motion);
    }
};

/// Pinch zoom, from two fingers on a touch screen (`Input.contacts`) or from Ctrl+wheel, which
/// is how touchpad pinches reach a window on Windows, on Linux and in browsers. Plain data the
/// caller keeps and steps once per frame; the outputs describe this frame only.
pub const Pinch = struct {
    /// Pointer ids of the two fingers followed, or `none`.
    fingers: [2]u32 = .{ none, none },
    /// Their distance and midpoint last frame.
    spread: f32 = 0,
    mid: [2]f32 = .{ 0, 0 },
    /// Zoom per wheel notch with Ctrl held.
    notch: f32 = 1.1,

    /// A pinch (two fingers) is in progress this frame.
    active: bool = false,
    /// Zoom this frame as a factor: 1 for none, 2 for twice as large. Apply it about `center`.
    scale: f32 = 1,
    /// Where to zoom about, in logical pixels: the fingers' midpoint, or the mouse pointer.
    center: [2]f32 = .{ 0, 0 },
    /// Movement of the fingers' midpoint this frame: two-finger pan, in logical pixels.
    pan: [2]f32 = .{ 0, 0 },

    pub fn step(p: *Pinch, in: *const Input) void {
        // Keep the two fingers already followed while both are down; otherwise start over
        // with the first two touches that are down. A new pair gives no zoom on its first
        // frame, only a baseline, so a third finger landing does not jump.
        const a = in.contact(p.fingers[0]);
        const b = in.contact(p.fingers[1]);
        const kept = a != none and b != none and in.contacts[a].down and in.contacts[b].down;
        var pair: [2]u32 = .{ a, b };
        if (!kept) {
            // Write always, advance by 0 or 1; the third slot takes the rest.
            var first: [3]u32 = .{ none, none, none };
            var n: u32 = 0;
            for (in.contacts, 0..) |c, i| {
                first[@min(n, 2)] = @intCast(i);
                n += @intFromBool(simd.andB(c.down, c.kind == .touch));
            }
            pair = if (n >= 2) .{ first[0], first[1] } else .{ none, none };
        }
        p.active = pair[0] != none;
        p.scale = 1;
        p.pan = .{ 0, 0 };
        p.center = in.pointer;
        if (p.active) {
            const c0 = in.contacts[pair[0]].pos;
            const c1 = in.contacts[pair[1]].pos;
            const spread = @max(std.math.hypot(c1[0] - c0[0], c1[1] - c0[1]), 1e-3);
            const mid = [2]f32{ (c0[0] + c1[0]) / 2, (c0[1] + c1[1]) / 2 };
            if (kept) {
                p.scale = spread / p.spread;
                p.pan = .{ mid[0] - p.mid[0], mid[1] - p.mid[1] };
            }
            p.fingers = .{ in.contacts[pair[0]].id, in.contacts[pair[1]].id };
            p.spread = spread;
            p.mid = mid;
            p.center = mid;
        } else {
            p.fingers = .{ none, none };
            // Ctrl+wheel: one notch up (positive y) zooms in by `notch`.
            p.scale = std.math.pow(f32, p.notch, in.wheel[1] * simd.b2f(in.mods.ctrl));
        }
    }
};

/// Drop targets: which kinds of dragged payload each node accepts. One row per node of the tree
/// it describes; the caller keeps it with that tree (last frame's, for `DragDrop.step`).
pub const Targets = struct {
    c: Columns,

    pub const Columns = struct {
        /// Set by the caller: a bit set of the application's payload kinds the node accepts;
        /// 0 for none.
        accept: []u32,
    };

    pub fn init(carver: *mem.Carver, cap: u32) Targets {
        std.debug.assert(cap > 0);
        return .{ .c = carver.columns(Columns, simd.rows(cap)) };
    }
    pub fn reset(tg: *Targets) void {
        @memset(tg.c.accept, 0);
    }
};

/// Drag and drop inside the application, on top of `Interaction`'s drag: the application
/// starts it (`begin`) when a widget it wants to drag shows up in `Interaction.dragging`, with a
/// payload kind; `step` then follows the pointer to the topmost node that accepts that kind,
/// and on release reports the drop. The payload itself stays with the application.
pub const DragDrop = struct {
    /// Id being dragged, or 0.
    source: u32 = 0,
    /// The payload's kind bits, as given to `begin`.
    kind: u32 = 0,
    /// Id of the accepting node under the pointer, or 0; for drop highlighting.
    over: u32 = 0,
    /// Its row in the tree `step` read, or `none`.
    over_node: u32 = none,
    /// Id the payload was dropped on this frame, or 0. A release elsewhere drops nothing.
    dropped: u32 = 0,
    /// The kind of what was dropped this frame (`kind` at the drop), or 0.
    dropped_kind: u32 = 0,

    /// Starts dragging `source` (an id) with payload `kind`. Ignored while another drag runs.
    pub fn begin(d: *DragDrop, source: types.Id, kind: u32) void {
        const idle = d.source == 0;
        d.source = simd.selU(idle, @backingInt(source), d.source);
        d.kind = simd.selU(idle, kind, d.kind);
    }
    /// Drops nothing and ends the drag (Escape, say).
    pub fn cancel(d: *DragDrop) void {
        d.source = 0;
        d.kind = 0;
        d.over = 0;
        d.over_node = none;
    }

    /// Advances by one frame, after `it.step(prev, in)`. The source and its subtree are never
    /// their own target. The drag ends on the frame `it` releases the source, with `dropped`
    /// set, or when `it` stops dragging it for any other reason.
    pub fn step(d: *DragDrop, it: *const Interaction, prev: *const Tree, tg: *const Targets, in: *const Input) void {
        const c = &prev.c;
        const src = prev.find(@fromBackingInt(d.source));
        const src_lo = simd.selU(src != none, src, 0);
        // Address select, then load (a select on the loaded `end` became a branch).
        const end_at = [2]*const u32{ &zero_id, &c.end[@min(src, prev.cap - 1)] };
        const src_hi = end_at[@intFromBool(src != none)].*;
        // With no drag `kind` is 0 and nothing accepts it.
        const node = accepting(prev, tg, in.pointer, d.kind, src_lo, src_hi);
        const over = idOf(prev, node);
        const active = d.source != 0;
        const released = simd.andB(active, it.released == d.source);
        d.dropped = simd.selU(released, over, 0);
        d.dropped_kind = simd.selU(simd.andB(released, over != 0), d.kind, 0);
        const going = simd.andB(active, simd.andB(!released, it.dragging == d.source));
        d.over = simd.selU(going, over, 0);
        d.over_node = simd.selU(going, node, none);
        d.source = simd.selU(going, d.source, 0);
        d.kind = simd.selU(going, d.kind, 0);
    }
};

/// Files dragged in from outside the application, filled by the host each frame beside `Input`
/// (Input has no file field): the paths while files hover over the window, and the frame they
/// are dropped. Paths are UTF-8 joined in `names`; path `k` is `names[ends[k-1]..ends[k]]`.
/// The host owns the bytes; they are read during the frame only.
pub const Files = struct {
    names: []const u8 = "",
    ends: []const u32 = &.{},
    /// Where the files are, in logical pixels (the pointer is not reported during an OS drag).
    pos: [2]f32 = .{ -1, -1 },
    /// Files are over the window this frame (also on the drop frame).
    hover: bool = false,
    /// The user let go of them this frame.
    drop: bool = false,

    pub fn count(fs: *const Files) usize {
        return fs.ends.len;
    }
    /// Path `k`, for `k < count()`.
    pub fn path(fs: *const Files, k: usize) []const u8 {
        const start = if (k == 0) 0 else fs.ends[k - 1];
        return fs.names[start..fs.ends[k]];
    }

    /// Where these files go: the topmost node under `pos` whose `Targets.accept` includes
    /// `kind` (the application's bit for files). One SIMD sweep, as `DragDrop.step`'s.
    pub fn route(fs: *const Files, prev: *const Tree, tg: *const Targets, kind: u32) FileDrop {
        const active = simd.andB(fs.hover, fs.count() > 0);
        const node = accepting(prev, tg, fs.pos, simd.selU(active, kind, 0), 0, 0);
        const id = idOf(prev, node);
        return .{
            .over = simd.selU(fs.drop, 0, id),
            .over_node = simd.selU(fs.drop, none, node),
            .dropped = simd.selU(fs.drop, id, 0),
        };
    }
};

/// Where external files are this frame (`Files.route`).
pub const FileDrop = struct {
    /// Id of the accepting node they hover over, or 0; for drop highlighting.
    over: u32 = 0,
    over_node: u32 = none,
    /// Id they were dropped on this frame, or 0.
    dropped: u32 = 0,
};

/// The topmost (latest) row of `t` whose visible rect holds `p` and whose `accept` shares a
/// bit with `kind`, rows [lo, hi) excluded; `none` if there is none. One SIMD sweep.
fn accepting(t: *const Tree, tg: *const Targets, p: [2]f32, kind: u32, lo: u32, hi: u32) u32 {
    const c = &t.c;
    const px = simd.f(p[0]);
    const py = simd.f(p[1]);
    const kv = simd.u(kind);
    var best = simd.u(none);
    const n = simd.padded(t.len);
    var i: usize = 0;
    while (i < n) : (i += W) {
        const inside = (px >= simd.loadF(c.vis[0], i)) & (px < simd.loadF(c.vis[2], i)) &
            (py >= simd.loadF(c.vis[1], i)) & (py < simd.loadF(c.vis[3], i));
        const r = simd.iota + simd.u(@intCast(i));
        const skip = (r >= simd.u(lo)) & (r < simd.u(hi));
        const take = inside & ((simd.loadU(tg.c.accept, i) & kv) != simd.u(0)) & !skip;
        best = @select(u32, take, r, best);
    }
    // Latest row wins, as in `route`.
    return @reduce(.Max, best +% simd.u(1)) -% 1;
}

/// The id of row `node`, or 0 for `none`. Selects the address, then loads: a select on the
/// loaded id became a branch (docs/CHECKS.md).
fn idOf(t: *const Tree, node: u32) u32 {
    const id_at = [2]*const u32{ &zero_id, &t.c.id[@min(node, t.cap - 1)] };
    return id_at[@intFromBool(node != none)].*;
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

/// Steps `k` at 60 Hz until it rests or `max` frames pass; returns the frames taken.
fn settle(k: *Kinetic, max: u32) u32 {
    var f: u32 = 0;
    while (f < max) : (f += 1) if (k.step(1.0 / 60.0) == 0) return f + 1;
    return max;
}

test "Kinetic: a fling coasts, slows and rests inside the range" {
    var raw: [4096]u8 align(mem.column_align) = undefined;
    var carver: mem.Carver = .{ .buf = &raw };
    var k = Kinetic.init(&carver, 4);
    const r = k.slot(1, 100, 0, 1000);
    k.c.v[r] = 600;
    try testing.expect(k.step(1.0 / 60.0) > 0);
    try testing.expect(k.c.x[r] > 100);
    const frames = settle(&k, 600);
    try testing.expect(frames < 600);
    // Frame by frame it moves v * h * d^n with d = exp(-friction * h): a geometric sum of
    // v * h * d / (1 - d) = 145.0 px (the continuous v / friction is 150). It stays inside
    // the range and stops.
    const d = @exp(-4.0 / 60.0);
    try testing.expectApproxEqAbs(100 + 600.0 / 60.0 * d / (1 - d), k.c.x[r], 0.5);
    try testing.expectEqual(0, k.c.v[r]);
    try testing.expectEqual(0, k.step(1.0 / 60.0));
}

test "Kinetic: a fling past the end overshoots, springs back and rests on the end" {
    var raw: [4096]u8 align(mem.column_align) = undefined;
    var carver: mem.Carver = .{ .buf = &raw };
    var k = Kinetic.init(&carver, 4);
    const r = k.slot(1, 950, 0, 1000);
    k.c.v[r] = 2000;
    var peak: f32 = 0;
    var f: u32 = 0;
    while (f < 600 and k.step(1.0 / 60.0) != 0) : (f += 1) peak = @max(peak, k.c.x[r]);
    try testing.expect(f < 600);
    try testing.expect(peak > 1000);
    try testing.expectEqual(1000, k.c.x[r]);
    try testing.expectEqual(0, k.c.v[r]);
}

test "Kinetic: a drag rubber-bands past the end, holds while held, returns when released" {
    var raw: [4096]u8 align(mem.column_align) = undefined;
    var carver: mem.Carver = .{ .buf = &raw };
    var k = Kinetic.init(&carver, 4);
    const r = k.slot(7, 0, 0, 500);
    // Pull 40 px before the start in two frames: the first 20 at full rate takes it to -20,
    // the second, already past the end, moves half: -30.
    k.drag(r, -20, 1.0 / 60.0);
    _ = k.step(1.0 / 60.0);
    try testing.expectEqual(-20, k.c.x[r]);
    k.drag(r, -20, 1.0 / 60.0);
    try testing.expectEqual(-30, k.c.x[r]);
    // Held: stepping does not move it.
    for (0..10) |_| _ = k.step(1.0 / 60.0);
    try testing.expectEqual(-30, k.c.x[r]);
    k.release(r);
    try testing.expect(settle(&k, 600) < 600);
    try testing.expectEqual(0, k.c.x[r]);
    // A wheel moves at once inside the range and never past it.
    k.scroll(r, 120);
    try testing.expectEqual(120, k.c.x[r]);
    k.scroll(r, 9000);
    try testing.expectEqual(500, k.c.x[r]);
    // `slot` finds the row again and takes the new range.
    try testing.expectEqual(r, k.slot(7, 0, 0, 300));
    try testing.expectEqual(500, k.c.x[r]);
    try testing.expect(settle(&k, 600) < 600);
    try testing.expectEqual(300, k.c.x[r]);
}

test "Kinetic: rows step independently, across vectors" {
    var raw: [16 * 1024]u8 align(mem.column_align) = undefined;
    var carver: mem.Carver = .{ .buf = &raw };
    var k = Kinetic.init(&carver, 40);
    for (0..37) |j| {
        const r = k.slot(@intCast(j + 1), @floatFromInt(j * 8), 0, 300);
        k.c.v[r] = @floatFromInt(@as(i32, @intCast(j % 7)) * 300 - 900);
    }
    var x0: [37]f32 = undefined;
    @memcpy(&x0, k.c.x[0..37]);
    try testing.expect(settle(&k, 1200) < 1200);
    for (0..37) |j| {
        // Each row rests inside its range, on the side its velocity pushed it.
        try testing.expect(k.c.x[j] >= 0 and k.c.x[j] <= 300);
        const v0: f32 = @floatFromInt(@as(i32, @intCast(j % 7)) * 300 - 900);
        if (v0 > 0) try testing.expect(k.c.x[j] >= x0[j]);
        if (v0 < 0) try testing.expect(k.c.x[j] <= x0[j]);
        if (v0 == 0) try testing.expect(k.c.x[j] == x0[j]);
    }
}

test "Pinch: two fingers spreading zoom about their midpoint and pan it" {
    var p: Pinch = .{};
    var c: [3]Input.Contact = undefined;
    // Frame 1: fingers 4 and 9 land 100 apart, centred on (100, 100): a baseline, no zoom.
    c[0] = .{ .id = 4, .pos = .{ 50, 100 } };
    c[1] = .{ .id = 9, .pos = .{ 150, 100 } };
    p.step(&.{ .contacts = c[0..2] });
    try testing.expect(p.active);
    try testing.expectEqual(1, p.scale);
    try testing.expectEqual([2]f32{ 100, 100 }, p.center);
    // Frame 2: 200 apart and moved 10 right, listed in the other order: twice as large.
    c[0] = .{ .id = 9, .pos = .{ 210, 100 } };
    c[1] = .{ .id = 4, .pos = .{ 10, 100 } };
    p.step(&.{ .contacts = c[0..2] });
    try testing.expectEqual(2, p.scale);
    try testing.expectEqual([2]f32{ 110, 100 }, p.center);
    try testing.expectEqual([2]f32{ 10, 0 }, p.pan);
    // Frame 3: a third finger lands; the pair is kept, they pinch in to 100 apart.
    c[0] = .{ .id = 9, .pos = .{ 160, 100 } };
    c[1] = .{ .id = 4, .pos = .{ 60, 100 } };
    c[2] = .{ .id = 2, .pos = .{ 0, 0 } };
    p.step(&.{ .contacts = c[0..3] });
    try testing.expectEqual(0.5, p.scale);
    // Frame 4: finger 4 lifts: 9 and 2 are a new pair, which only sets a baseline.
    c[1] = .{ .id = 4, .pos = .{ 60, 100 }, .down = false };
    p.step(&.{ .contacts = c[0..3] });
    try testing.expect(p.active);
    try testing.expectEqual(1, p.scale);
    try testing.expectEqual([2]u32{ 9, 2 }, p.fingers);
    // Frame 5: one finger: no pinch.
    p.step(&.{ .contacts = c[0..1] });
    try testing.expect(!p.active);
    try testing.expectEqual(1, p.scale);
    try testing.expectEqual([2]u32{ none, none }, p.fingers);
}

test "Pinch: Ctrl+wheel zooms about the pointer; a plain wheel does not" {
    var p: Pinch = .{};
    p.step(&.{ .pointer = .{ 30, 40 }, .wheel = .{ 0, 2 }, .mods = .{ .ctrl = true } });
    try testing.expect(!p.active);
    try testing.expectApproxEqAbs(@as(f32, 1.21), p.scale, 1e-5);
    try testing.expectEqual([2]f32{ 30, 40 }, p.center);
    p.step(&.{ .pointer = .{ 30, 40 }, .wheel = .{ 0, -1 }, .mods = .{ .ctrl = true } });
    try testing.expectApproxEqAbs(@as(f32, 1.0 / 1.1), p.scale, 1e-5);
    p.step(&.{ .wheel = .{ 0, 3 } });
    try testing.expectEqual(1, p.scale);
}

/// root 300 x 100, across: a list of two cards (40 x 40 each, stacked), a "files" bin and a
/// "trash" bin (80 x 80 each).
const Board = struct {
    raw: [64 * 1024]u8 align(mem.column_align) = undefined,
    t: Tree = undefined,
    tg: Targets = undefined,

    const card = 1;
    const folder = 2;

    fn build(f: *Board) void {
        const layout = @import("../layout/layout.zig");
        const Texts = @import("../core/texts.zig").Texts;
        var carver: mem.Carver = .{ .buf = &f.raw };
        f.t = Tree.init(&carver, 16);
        var tx = Texts.init(&carver, 1);
        f.tg = Targets.init(&carver, 16);
        const t = &f.t;
        const root = t.push(0, .none, &.{ .dir = .x, .size = .{ .px(300), .px(100) }, .gap = 10 });
        const list = t.push(root, types.Id.from("list"), &.{});
        // The list accepts cards too: dropping a card back onto the list (not onto itself).
        f.tg.c.accept[list] = card;
        for ([_]types.Id{ types.Id.from("c1"), types.Id.from("c2") }) |id| {
            const n = t.push(list, id, &.{ .size = .{ .px(40), .px(40) } });
            t.seal(n);
            t.c.sense[n] = @bitCast(types.Sense.any);
        }
        t.seal(list);
        const files = t.push(root, types.Id.from("files"), &.{ .size = .{ .px(80), .px(80) } });
        t.seal(files);
        f.tg.c.accept[files] = card | folder;
        const trash = t.push(root, types.Id.from("trash"), &.{ .size = .{ .px(80), .px(80) } });
        t.seal(trash);
        f.tg.c.accept[trash] = folder;
        t.seal(root);
        layout.run(t, &tx, .{ 300, 100 });
    }
};

test "DragDrop: a card dragged over the bins highlights the one that accepts it and drops there" {
    var f: Board = .{};
    f.build();
    const Replay = @import("../core/input.zig").Replay;
    var text: [8]u8 = undefined;
    var events: [4]Input.Event = undefined;
    var contacts: [1]Input.Contact = undefined;
    const buf: Replay.Buffers = .{ .text = &text, .events = &events, .contacts = &contacts };
    // Cards at x 0..40 (c1 y 0..40, c2 y 40..80); files at 50..130, trash at 140..220.
    var r: Replay = .{ .src =
        \\frame
        \\pointer 20 20
        \\buttons left
        \\# still on c1 itself, then on c2 (the list accepts cards; c2 does not)
        \\frame
        \\pointer 20 30
        \\frame
        \\pointer 20 60
        \\# trash does not take cards; files does
        \\frame
        \\pointer 180 50
        \\frame
        \\pointer 90 50
        \\frame
        \\buttons
        \\frame
        \\pointer 100 50
    };
    var it: Interaction = .{};
    var dd: DragDrop = .{};
    var over: [8]u32 = undefined;
    var dropped: [8]u32 = undefined;
    var n: usize = 0;
    while (try r.next(buf)) |in| : (n += 1) {
        it.step(&f.t, in);
        // The app drags cards: when one starts dragging, it begins a drop with kind `card`.
        if (it.dragging != 0 and dd.source == 0 and it.pressed == 0) dd.begin(@fromBackingInt(it.dragging), Board.card);
        dd.step(&it, &f.t, &f.tg, in);
        over[n] = dd.over;
        dropped[n] = dd.dropped;
    }
    const list = @backingInt(types.Id.from("list"));
    const files = @backingInt(types.Id.from("files"));
    try testing.expectEqual(7, n);
    // Frame 1 starts the drag (moved 10 > 4) over c1 itself: c1 is never its own target, so
    // the list around it is. Frame 2 is over c2, which accepts nothing: the list again.
    try testing.expectEqualSlices(u32, &.{ 0, list, list, 0, files, 0, 0 }, over[0..n]);
    try testing.expectEqualSlices(u32, &.{ 0, 0, 0, 0, 0, files, 0 }, dropped[0..n]);
    try testing.expectEqual(0, dd.source);
}

test "DragDrop: release on nothing drops nothing; cancel ends it; one drag at a time" {
    var f: Board = .{};
    f.build();
    var it: Interaction = .{ .dragging = @backingInt(types.Id.from("c1")) };
    var dd: DragDrop = .{};
    dd.begin(types.Id.from("c1"), Board.folder);
    dd.begin(types.Id.from("c2"), Board.card);
    try testing.expectEqual(@backingInt(types.Id.from("c1")), dd.source);
    try testing.expectEqual(Board.folder, dd.kind);
    // A folder over files and over trash: both accept it.
    dd.step(&it, &f.t, &f.tg, &.{ .pointer = .{ 180, 50 } });
    try testing.expectEqual(@backingInt(types.Id.from("trash")), dd.over);
    // Released in the gap between the bins.
    it.released = it.dragging;
    dd.step(&it, &f.t, &f.tg, &.{ .pointer = .{ 135, 50 } });
    try testing.expectEqual(0, dd.dropped);
    try testing.expectEqual(0, dd.dropped_kind);
    try testing.expectEqual(0, dd.source);
    // Cancel.
    it.released = 0;
    dd.begin(types.Id.from("c1"), Board.card);
    dd.cancel();
    dd.step(&it, &f.t, &f.tg, &.{ .pointer = .{ 90, 50 } });
    try testing.expectEqual(0, dd.over);
    try testing.expectEqual(0, dd.source);
}

test "Files: dragged in from outside, they hover over the bin that takes files and drop there" {
    var f: Board = .{};
    f.build();
    const file_kind = 4;
    f.tg.c.accept[f.t.find(types.Id.from("files"))] |= file_kind;
    const files = @backingInt(types.Id.from("files"));
    const names = "/tmp/a.png/home/u/notes.txt";
    const ends = [_]u32{ 10, 27 };
    var fs: Files = .{ .names = names, .ends = &ends, .pos = .{ 90, 50 }, .hover = true };
    try testing.expectEqual(2, fs.count());
    try testing.expectEqualStrings("/tmp/a.png", fs.path(0));
    try testing.expectEqualStrings("/home/u/notes.txt", fs.path(1));
    // Hovering over files: highlighted, not dropped.
    try testing.expectEqual(FileDrop{ .over = files, .over_node = f.t.find(types.Id.from("files")) }, fs.route(&f.t, &f.tg, file_kind));
    // Over trash, which does not take files, and over the list, which takes only cards.
    fs.pos = .{ 180, 50 };
    try testing.expectEqual(FileDrop{}, fs.route(&f.t, &f.tg, file_kind));
    fs.pos = .{ 20, 20 };
    try testing.expectEqual(FileDrop{}, fs.route(&f.t, &f.tg, file_kind));
    // Dropped on files.
    fs.pos = .{ 90, 50 };
    fs.drop = true;
    try testing.expectEqual(FileDrop{ .dropped = files }, fs.route(&f.t, &f.tg, file_kind));
    // No files, or not over the window: nothing.
    try testing.expectEqual(FileDrop{}, (Files{ .pos = .{ 90, 50 }, .hover = true, .drop = true }).route(&f.t, &f.tg, file_kind));
    fs.hover = false;
    try testing.expectEqual(FileDrop{}, fs.route(&f.t, &f.tg, file_kind));
}
