//! Layout animation (tier 0): a node whose laid-out position changes between frames slides there
//! on a spring instead of jumping. The springs live in `Anims`, keyed by the node's id; the start
//! of a slide is where the node was shown last frame (its rect in the previous tree, as
//! `Frame.lastRect` reads it). `apply` runs between `layout.place` and `layout.finalize` and
//! moves each registered subtree by (shown - laid out), so finalize derives rects, clips and
//! visibility from the shown position and hit testing matches what is drawn.

const mem = @import("../core/mem.zig");
const simd = @import("../core/simd.zig");
const types = @import("../core/types.zig");
const Tree = @import("../core/tree.zig").Tree;
const anims = @import("anims.zig");
const Anims = anims.Anims;
const Spring = anims.Spring;
const Id = types.Id;
const none = types.none;

/// The nodes asked to animate their layout this frame. Emptied by the frame's `begin`.
pub const Flips = struct {
    len: u32 = 0,
    cap: u32,
    c: Columns,

    pub const Columns = struct {
        node: []u32,
        id: []u32,
        stiffness: []f32,
        damping: []f32,
        /// Shown minus laid-out position, written by `apply`.
        delta: [2][]f32,
    };

    pub fn init(carver: *mem.Carver, cap: u32) Flips {
        return .{ .cap = cap, .c = carver.columns(Columns, simd.rows(cap)) };
    }

    /// Registers row `node`, whose id `id` must be stable across frames, for this frame. Past `cap` the last
    /// registration is overwritten.
    pub fn add(fl: *Flips, node: u32, id: Id, spring: Spring) void {
        const k = @min(fl.len, fl.cap - 1);
        fl.c.node[k] = node;
        fl.c.id[k] = @backingInt(id);
        fl.c.stiffness[k] = spring.stiffness;
        fl.c.damping[k] = spring.damping;
        fl.len = k + 1;
    }
};

/// Moves every registered subtree of `t` (positions laid out by `place`) to where its springs
/// show it, and points the springs at the new layout. A node new to the springs starts at its
/// rect in `prev` if it was there, else at its laid-out position (no slide on first
/// appearance). Returns how far any node is from its layout, for `Context.motion`. Two springs
/// per node, ids `id.with(0)` (x) and `id.with(1)` (y); size changes are not animated.
pub fn apply(t: *Tree, prev: *const Tree, fl: *Flips, an: *Anims, frame: u32) f32 {
    const pos = t.c.pos;
    const end = t.c.end;
    const c = &fl.c;
    var moving: f32 = 0;
    // Every offset first, from the unshifted layout: a registered node inside another must
    // not read its parent's shift as its own layout.
    for (0..fl.len) |k| {
        const n = c.node[k];
        const id: Id = @fromBackingInt(c.id[k]);
        const was = prev.find(id);
        const row = @min(was, prev.cap - 1);
        inline for (0..2) |a| {
            const target = pos[a][n];
            const key = id.with(a);
            const known = simd.find(an.c.id, an.len, @backingInt(key));
            const i = an.slotScan(key, target);
            // A spring new this frame for a node shown last frame starts at the shown rect.
            // Select the row to write, not the value (a value select re-branches on Zig 0.18;
            // docs/CHECKS.md): otherwise the rect goes to the spare row no pass reads.
            const restart = simd.andB(known == none, was != none);
            an.c.x[simd.selU(restart, i, @intCast(an.c.x.len - 1))] = prev.c.rect[a][row];
            an.c.target[i] = target;
            an.c.stiffness[i] = c.stiffness[k];
            an.c.damping[i] = c.damping[k];
            an.c.seen[i] = frame;
            c.delta[a][k] = an.c.x[i] - target;
            moving = @max(moving, @abs(c.delta[a][k]));
        }
    }
    for (0..fl.len) |k| {
        const n = c.node[k];
        inline for (0..2) |a| {
            const d = c.delta[a][k];
            for (pos[a][n..end[n]]) |*v| v.* += d;
        }
    }
    return moving;
}
