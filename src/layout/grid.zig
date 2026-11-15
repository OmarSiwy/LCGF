//! grid: two-dimensional layout in rows and columns of tracks, after CSS Grid
//! (https://www.w3.org/TR/css-grid-1/, track sizing), cut down to what bounded passes can do:
//! every track is sized once, with no re-measure loop. Tier 0: no allocator, no I/O.
//!
//!   Track        a track's size as three coefficients: fixed pixels, content, fraction
//!   Grids        side tables: grid containers and their tracks
//!   sizeTracks   one grid's track sizes and starts on one axis

const std = @import("std");
const simd = @import("../core/simd.zig");
const mem = @import("../core/mem.zig");

/// The size of one track (a column or a row). Like `types.Size`, the kind is data turned into
/// coefficients, so sizing a track is `k_px + content * (k_fit + k_fr)` with no switch.
pub const Track = struct {
    k_px: f32 = 0,
    k_fit: f32 = 0,
    k_fr: f32 = 0,

    /// Exactly `v` pixels.
    pub fn px(v: f32) Track {
        return .{ .k_px = v };
    }
    /// As large as the largest item in it (CSS `auto` / `max-content`).
    pub const fit: Track = .{ .k_fit = 1 };
    /// A share `w` of the space the other tracks leave (CSS `fr`). Until fractions are
    /// resolved it is sized like `fit`.
    pub fn fr(w: f32) Track {
        return .{ .k_fr = w };
    }
};

/// The grid side tables. A grid row describes one container node; its tracks on axis `a` are
/// rows `first[a][g] .. first[a][g] + count[a][g]` of the track columns.
pub const Grids = struct {
    len: u32 = 0,
    tracks_len: u32 = 0,
    /// A push ran out of grid or track rows. Nothing is written out of bounds.
    overflow: bool = false,
    cap: Capacity,
    g: GridColumns,
    tr: TrackColumns,

    pub const Capacity = struct { grids: u32, tracks: u32 };

    pub const GridColumns = struct {
        node: []u32,
        first: [2][]u32,
        count: [2][]u32,
    };

    pub const TrackColumns = struct {
        k_px: []f32,
        k_fit: []f32,
        k_fr: []f32,
        /// Largest item extent in the track, written by the fit step.
        content: []f32,
        /// Written by `sizeTracks`: final size, and start inside the container's content box.
        size: []f32,
        start: []f32,
    };

    pub fn init(carver: *mem.Carver, cap: Capacity) Grids {
        std.debug.assert(cap.grids > 0 and cap.tracks > 0);
        return .{
            .cap = cap,
            .g = carver.columns(GridColumns, simd.rows(cap.grids)),
            .tr = carver.columns(TrackColumns, simd.rows(cap.tracks)),
        };
    }
    pub fn reset(gs: *Grids) void {
        gs.len = 0;
        gs.tracks_len = 0;
        gs.overflow = false;
    }

    /// Makes `node` a grid with these columns (tracks along x) and rows (along y). Push grids
    /// in row order. Returns the grid's row.
    pub fn grid(gs: *Grids, node: u32, columns: []const Track, rows: []const Track) u32 {
        const k = @min(gs.len, gs.cap.grids - 1);
        const need = gs.tracks_len + columns.len + rows.len;
        gs.overflow = simd.orB(gs.overflow, simd.orB(gs.len >= gs.cap.grids, need > gs.cap.tracks));
        // On overflow the grid keeps no tracks, so nothing is written out of bounds.
        const fits = need <= gs.cap.tracks;
        gs.len = k + 1;
        gs.g.node[k] = node;
        inline for (.{ columns, rows }, 0..) |list, a| {
            const n: u32 = if (fits) @intCast(list.len) else 0;
            gs.g.first[a][k] = gs.tracks_len;
            gs.g.count[a][k] = n;
            for (list[0..n], gs.tracks_len..) |tk, j| {
                gs.tr.k_px[j] = tk.k_px;
                gs.tr.k_fit[j] = tk.k_fit;
                gs.tr.k_fr[j] = tk.k_fr;
                gs.tr.content[j] = 0;
            }
            gs.tracks_len += n;
        }
        return k;
    }
};

/// Sizes the tracks of grid `k` on axis `a` from their coefficients and `content`, writes each
/// track's `size` and `start` (a running sum), and returns the total: the grid's content size
/// on that axis. One pass over the grid's tracks.
pub fn sizeTracks(gs: *Grids, k: u32, a: u1) f32 {
    const first = gs.g.first[a][k];
    const n = gs.g.count[a][k];
    const tr = &gs.tr;
    var at: f32 = 0;
    for (first..first + n) |j| {
        const s = tr.k_px[j] + tr.content[j] * (tr.k_fit[j] + b01(tr.k_fr[j] > 0));
        tr.size[j] = s;
        tr.start[j] = at;
        at += s;
    }
    return at;
}

const b01 = simd.b2f;
const testing = std.testing;

test "sizeTracks: fixed tracks take their pixels, fit and fraction tracks their content" {
    var raw: [8192]u8 align(mem.column_align) = undefined;
    var carver: mem.Carver = .{ .buf = &raw };
    var gs = Grids.init(&carver, .{ .grids = 2, .tracks = 8 });
    const k = gs.grid(7, &.{ .px(100), .fit, .fr(2) }, &.{ .fit, .px(30) });
    try testing.expectEqual(0, k);
    try testing.expectEqual(5, gs.tracks_len);
    try testing.expectEqual(7, gs.g.node[k]);
    try testing.expectEqualSlices(u32, &.{ 0, 3 }, &.{ gs.g.first[0][k], gs.g.first[1][k] });
    try testing.expectEqualSlices(u32, &.{ 3, 2 }, &.{ gs.g.count[0][k], gs.g.count[1][k] });

    // Content as the fit step leaves it: the fixed track's content does not count.
    @memcpy(gs.tr.content[0..5], &[_]f32{ 500, 40, 25, 12, 99 });
    try testing.expectEqual(165, sizeTracks(&gs, k, 0));
    try testing.expectEqualSlices(f32, &.{ 100, 40, 25 }, gs.tr.size[0..3]);
    try testing.expectEqualSlices(f32, &.{ 0, 100, 140 }, gs.tr.start[0..3]);
    try testing.expectEqual(42, sizeTracks(&gs, k, 1));
    try testing.expectEqualSlices(f32, &.{ 12, 30 }, gs.tr.size[3..5]);
    try testing.expectEqualSlices(f32, &.{ 0, 12 }, gs.tr.start[3..5]);
}

test "Grids: running out of grid or track rows is reported and writes nothing out of bounds" {
    var raw: [8192]u8 align(mem.column_align) = undefined;
    var carver: mem.Carver = .{ .buf = &raw };
    var gs = Grids.init(&carver, .{ .grids = 1, .tracks = 3 });
    _ = gs.grid(0, &.{ .fit, .fit }, &.{.fit});
    try testing.expect(!gs.overflow);
    // Too many tracks: the grid is kept with none.
    gs.reset();
    const k = gs.grid(0, &.{ .fit, .fit }, &.{ .fit, .fit });
    try testing.expect(gs.overflow);
    try testing.expectEqual(0, gs.g.count[0][k] + gs.g.count[1][k]);
    try testing.expectEqual(0, sizeTracks(&gs, k, 0));
    // Too many grids: the last row is reused.
    gs.reset();
    _ = gs.grid(0, &.{.fit}, &.{});
    try testing.expectEqual(0, gs.grid(1, &.{.fit}, &.{}));
    try testing.expect(gs.overflow);
    try testing.expectEqual(1, gs.len);
}
