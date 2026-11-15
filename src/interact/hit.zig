//! hit: which node is under a point. One SIMD sweep over the visible rects, no early exit.
//! Tier 0: no allocator, no I/O. Ported from prototype/ui.zig ("hit").

const std = @import("std");
const simd = @import("../core/simd.zig");
const types = @import("../core/types.zig");
const Tree = @import("../core/tree.zig").Tree;
const Sense = types.Sense;
const none = types.none;

const W = simd.lanes;

/// Topmost node under (x, y) that takes part in any interaction in `want`, or `none`. Tests
/// `lanes` nodes per step and never exits early; later rows are drawn later, so the highest
/// matching row wins. Reads `vis` and `sense` as `layout.finalize` left them (padding rows have
/// sense 0, so they never match).
pub fn at(t: *const Tree, x: f32, y: f32, want: Sense) u32 {
    const c = &t.c;
    const px = simd.f(x);
    const py = simd.f(y);
    const wantv: simd.Bytes = @splat(@as(u8, @bitCast(want)));
    const zero: simd.Bytes = @splat(0);
    var found: u32 = none;
    const n = simd.padded(t.len);
    var i: usize = 0;
    while (i < n) : (i += W) {
        const inside = (px >= simd.loadF(c.vis[0], i)) & (px < simd.loadF(c.vis[2], i)) &
            (py >= simd.loadF(c.vis[1], i)) & (py < simd.loadF(c.vis[3], i));
        const senses: simd.Bytes = c.sense[i..][0..W].*;
        const m = simd.bits(inside & ((senses & wantv) != zero));
        // Highest set lane. Wraps when m == 0, and is then discarded.
        const top = @as(u32, W - 1) -% @as(u32, @clz(m));
        found = simd.selU(m != 0, @as(u32, @intCast(i)) +% top, found);
    }
    return found;
}
