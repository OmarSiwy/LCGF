//! grid: two-dimensional layout in rows and columns of tracks, after CSS Grid
//! (https://www.w3.org/TR/css-grid-1/, track sizing), cut down to what bounded passes can do:
//! every track is sized once, with no re-measure loop. Tier 0: no allocator, no I/O.
//!
//!   Track        a track's size as three coefficients: fixed pixels, content, fraction
//!   Grids        side tables: grid containers and their tracks
//!   sizeTracks   one grid's track sizes and starts on one axis
//!   autoPlace    cells for items pushed without one, in row order
//!   fit          `layout.fit` with each grid's content size set from its tracks
//!   resolve      `layout.resolve` with each grid item sized to its cell
//!   run          every pass in order, as `layout.run`, for trees with grids
//!   Decl, Item   a grid and an item as one value each, for the front ends (`Grids.declare`,
//!                `Grids.place`, `implicitTracks`)
//!
//! A grid item is a child of the grid node pushed with `Style.float = true`, so the flow passes
//! leave it alone; the grid owns its size and its `offset` (the cell's place in the grid). The
//! layout passes are run in pieces around grid rows (`layout.fitSpan`, `layout.resolveSpan`):
//! a grid's tracks need its items' natural sizes before the grid is folded into its parent, and
//! its items need the grid's final size before their own children are resolved.

const std = @import("std");
const simd = @import("../core/simd.zig");
const mem = @import("../core/mem.zig");
const types = @import("../core/types.zig");
const layout = @import("layout.zig");
const Tree = @import("../core/tree.zig").Tree;
const Texts = @import("../core/texts.zig").Texts;
const Axis = types.Axis;
const none = types.none;

/// The size of one track (a column or a row). Like `types.Size`, the kind is data turned into
/// coefficients, so sizing a track is `k_px + content * (k_fit + k_fr)` with no switch.
pub const Track = struct {
    k_px: f32 = 0,
    k_fit: f32 = 0,
    k_fr: f32 = 0,
    min: f32 = 0,
    max: f32 = std.math.floatMax(f32),
    /// Fraction tracks normally keep their content as a minimum. Explicit minmaxFr can opt
    /// out, allowing minmax(0, 1fr)-like tracks to contain overflowing/wrapping content.
    content_floor: f32 = 1,

    /// Exactly `v` pixels.
    pub fn px(v: f32) Track {
        return .{ .k_px = v };
    }
    /// As large as the largest item in it (CSS `auto` / `max-content`).
    pub const fit: Track = .{ .k_fit = 1 };
    /// A share `w` of the space the other tracks leave (CSS `fr`), never less than its content.
    pub fn fr(w: f32) Track {
        return .{ .k_fr = w };
    }
    /// Content-sized track bounded by explicit logical-pixel minimum and maximum.
    pub fn minmax(minimum: f32, maximum: f32) Track {
        return .{ .k_fit = 1, .min = @max(minimum, 0), .max = @max(@max(maximum, minimum), 0) };
    }
    /// Fractional growth above an explicit minimum, independently of intrinsic content.
    pub fn minmaxFr(minimum: f32, weight: f32, maximum: f32) Track {
        return .{ .k_fr = @max(weight, 0), .min = @max(minimum, 0), .max = @max(@max(maximum, minimum), 0), .content_floor = 0 };
    }
    /// Fit content up to a pixel limit. This is a bounded max-content track; callers needing
    /// a distinct min-content floor can supply it with minmax instead.
    pub fn fitContent(maximum: f32) Track {
        return minmax(0, maximum);
    }
};

pub const AutoFlow = enum(u8) { row = 0, column = 1, row_dense = 2, column_dense = 3 };
pub const Distribution = enum(u8) { start, center, end, space_between, space_around, space_evenly };

/// Where an item sits inside its cell on one axis (CSS `justify-self` / `align-self`). Stored
/// as two coefficients, so the resolve step blends instead of switching.
pub const Justify = enum(u8) {
    /// Fill the cell (within the item's own min and max). The default.
    stretch,
    start,
    center,
    end,

    pub const k_stretch = [4]f32{ 1, 0, 0, 0 };
    pub const factor = [4]f32{ 0, 0, 0.5, 1 };
};

/// The grid side tables. A grid row describes one container node; its tracks on axis `a` are
/// rows `first[a][g] .. first[a][g] + count[a][g]` of the track columns.
pub const Grids = struct {
    len: u32 = 0,
    tracks_len: u32 = 0,
    items_len: u32 = 0,
    /// A push ran out of grid or track rows. Nothing is written out of bounds.
    overflow: bool = false,
    cap: Capacity,
    g: GridColumns,
    tr: TrackColumns,

    it: ItemColumns,
    /// Scratch for `autoPlace`: one byte per cell of the grid being placed.
    occupied: []u8,

    /// `cells` bounds columns x rows of any one grid that has auto-placed items.
    pub const Capacity = struct { grids: u32, tracks: u32, items: u32, cells: u32 = 1 };

    pub const GridColumns = struct {
        node: []u32,
        first: [2][]u32,
        count: [2][]u32,
        /// The grid's items as a chain through `ItemColumns.next`, so the fit and resolve steps
        /// visit only their own items; `none` when it has none.
        first_item: []u32,
        last_item: []u32,
        /// Space between columns (x) and between rows (y).
        gap: [2][]f32,
        flow: []u8,
        /// Opt-in bounded fractional solver, preserving the original single-pass default.
        bounded: []u8,
        distribution: [2][]u8,
        /// Tracks given by the caller, and tracks reserved for auto-placement to add after
        /// them (`declare`); `autoPlace` sets `count` between the two.
        explicit: [2][]u32,
        reserved: [2][]u32,
        /// `Justify` of the grid's items that `place` gets none for (CSS `justify-items`,
        /// `align-items`).
        justify: [2][]u8,
        /// Optional parent grid whose resolved tracks this axis shares.
        parent: [2][]u32,
        parent_first: [2][]u32,
    };

    pub const TrackColumns = struct {
        k_px: []f32,
        k_fit: []f32,
        k_fr: []f32,
        min: []f32,
        max: []f32,
        content_floor: []f32,
        /// Largest item extent in the track, written by the fit step.
        content: []f32,
        /// Written by `sizeTracks`: final size, and start inside the container's content box.
        size: []f32,
        start: []f32,
    };

    pub const ItemColumns = struct {
        node: []u32,
        /// Row of the item's grid.
        grid: []u32,
        /// Column (x) and row (y) of the item's cell, counted from 0 inside its grid.
        cell: [2][]u32,
        /// Number of columns and rows the item covers, at least 1.
        span: [2][]u32,
        /// 1 when `autoPlace` chooses the cell.
        auto: []u8,
        /// Next item of the same grid, or `none`.
        next: []u32,
        /// Written by the resolve step of the item's grid: the cell's size.
        cell_size: [2][]f32,
        /// Written by the same step: where the cell starts in the grid's content box.
        cell_start: [2][]f32,
        /// From `Justify`: 1.0 to fill the cell, and the share of the leftover placed before.
        stretch: [2][]f32,
        factor: [2][]f32,
        /// Child grid supplying individual intrinsic contributions on this item's axis.
        subgrid: [2][]u32,
    };

    pub fn init(carver: *mem.Carver, cap: Capacity) Grids {
        std.debug.assert(cap.grids > 0 and cap.tracks > 0);
        return .{
            .cap = cap,
            .g = carver.columns(GridColumns, simd.rows(cap.grids)),
            .tr = carver.columns(TrackColumns, simd.rows(cap.tracks)),
            .it = carver.columns(ItemColumns, simd.rows(cap.items)),
            .occupied = carver.slice(u8, cap.cells),
        };
    }
    pub fn reset(gs: *Grids) void {
        gs.len = 0;
        gs.tracks_len = 0;
        gs.items_len = 0;
        gs.overflow = false;
    }

    /// Makes `node` a grid with these columns (tracks along x) and rows (along y). Push grids
    /// in row order. Returns the grid's row.
    pub fn grid(gs: *Grids, node: u32, columns: []const Track, rows: []const Track) u32 {
        return gs.pushGrid(node, .{ columns, rows }, .{ 0, 0 }, .{ .fit, .fit });
    }

    /// `grid` with `extra[a]` tracks of size `auto[a]` after the given ones on axis `a`.
    fn pushGrid(gs: *Grids, node: u32, lists: [2][]const Track, extra: [2]u32, auto: [2]Track) u32 {
        const k = @min(gs.len, gs.cap.grids - 1);
        const need = gs.tracks_len + lists[0].len + lists[1].len + extra[0] + extra[1];
        gs.overflow = simd.orB(gs.overflow, simd.orB(gs.len >= gs.cap.grids, need > gs.cap.tracks));
        // On overflow the grid keeps no tracks, so nothing is written out of bounds.
        const fits = need <= gs.cap.tracks;
        gs.len = k + 1;
        gs.g.node[k] = node;
        gs.g.first_item[k] = none;
        gs.g.gap[0][k] = 0;
        gs.g.gap[1][k] = 0;
        gs.g.last_item[k] = none;
        gs.g.flow[k] = 0;
        gs.g.bounded[k] = 0;
        inline for (lists, 0..) |list, a| {
            gs.g.distribution[a][k] = 0;
            gs.g.justify[a][k] = @backingInt(Justify.stretch);
            gs.g.parent[a][k] = none;
            gs.g.parent_first[a][k] = 0;
            const given: u32 = if (fits) @intCast(list.len) else 0;
            const n: u32 = if (fits) given + extra[a] else 0;
            gs.g.explicit[a][k] = given;
            gs.g.reserved[a][k] = n;
            // A grid with no tracks on an axis points at the spare row past `cap.tracks`, which
            // its items may write and no other grid owns.
            gs.g.first[a][k] = if (n == 0) gs.cap.tracks else gs.tracks_len;
            gs.g.count[a][k] = n;
            for (0..n, gs.tracks_len..) |i, j| {
                const tk = if (i < given) list[i] else auto[a];
                gs.tr.k_px[j] = tk.k_px;
                gs.tr.k_fit[j] = tk.k_fit;
                gs.tr.k_fr[j] = tk.k_fr;
                gs.tr.min[j] = tk.min;
                gs.tr.max[j] = tk.max;
                gs.tr.content_floor[j] = tk.content_floor;
                gs.tr.content[j] = 0;
            }
            gs.tracks_len += n;
        }
        return k;
    }

    /// Places `node`, a floating child of grid `k`'s node, in the cell at column `cell[0]`,
    /// row `cell[1]`. A cell past the last track is clamped to it. Push items in row order
    /// (the order they are pushed to the tree). Returns the item's row.
    pub fn item(gs: *Grids, k: u32, node: u32, cell: [2]u32) u32 {
        const r = @min(gs.items_len, gs.cap.items - 1);
        gs.overflow = simd.orB(gs.overflow, gs.items_len >= gs.cap.items);
        std.debug.assert(r == 0 or gs.it.node[r - 1] < node or gs.items_len >= gs.cap.items);
        gs.items_len = r + 1;
        const it = &gs.it;
        it.node[r] = node;
        it.grid[r] = k;
        it.next[r] = none;
        it.auto[r] = 0;
        inline for (0..2) |a| {
            it.cell[a][r] = @min(cell[a], gs.g.count[a][k] -| 1);
            it.span[a][r] = 1;
            it.stretch[a][r] = 1;
            it.factor[a][r] = 0;
            it.subgrid[a][r] = none;
        }
        // Append to the grid's chain. On overflow the reused row may already be the tail.
        if (gs.g.last_item[k] == none) {
            gs.g.first_item[k] = r;
        } else if (gs.g.last_item[k] != r) {
            it.next[gs.g.last_item[k]] = r;
        }
        gs.g.last_item[k] = r;
        return r;
    }
    /// Places `node`, a floating child of grid `k`'s node, in the next free cell in row order,
    /// chosen by `autoPlace`. Returns the item's row.
    pub fn autoItem(gs: *Grids, k: u32, node: u32) u32 {
        const r = gs.item(k, node, .{ 0, 0 });
        gs.it.auto[r] = 1;
        return r;
    }
    /// Makes `node` the grid `decl` describes, with `implicit` more tracks of `decl.auto` on
    /// the axis auto-placement grows (`implicitTracks` gives a bound). An axis with no tracks
    /// gets one `auto` track, as CSS's implicit grid. Push grids in row order. Returns the
    /// grid's row.
    pub fn declare(gs: *Grids, node: u32, decl: Decl, implicit: u32) u32 {
        const g = decl.growAxis();
        var extra: [2]u32 = .{ @intFromBool(decl.columns.len == 0), @intFromBool(decl.rows.len == 0) };
        extra[g] = @max(extra[g], implicit);
        const k = gs.pushGrid(node, .{ decl.columns, decl.rows }, extra, decl.auto);
        gs.gaps(k, decl.gap);
        gs.autoFlow(k, decl.flow);
        gs.distribute(k, decl.distribution);
        inline for (0..2) |a| gs.g.justify[a][k] = @backingInt(decl.justify[a]);
        return k;
    }

    /// Makes `node`, a floating child of grid `k`'s node, the grid item `at` describes.
    /// Push items in row order; a front end places an item before pushing its subtree, as
    /// the item's row is then the tree's next row. Returns the item's row.
    pub fn place(gs: *Grids, k: u32, node: u32, at: Item) u32 {
        const r = if (at.cell) |c| gs.item(k, node, c) else gs.autoItem(k, node);
        gs.span(r, at.span);
        const def: [2]Justify = .{ @fromBackingInt(gs.g.justify[0][k]), @fromBackingInt(gs.g.justify[1][k]) };
        gs.justify(r, at.justify orelse def);
        return r;
    }

    /// Sets grid `k`'s space between columns (`g[0]`) and between rows (`g[1]`).
    pub fn gaps(gs: *Grids, k: u32, g: [2]f32) void {
        gs.g.gap[0][k] = g[0];
        gs.g.gap[1][k] = g[1];
    }
    /// Auto-placement traverses rows or columns, with optional hole filling from the start
    /// for every item. Tracks remain explicit and capacity-bounded.
    pub fn autoFlow(gs: *Grids, k: u32, flow: AutoFlow) void {
        gs.g.flow[k] = @backingInt(flow);
    }
    /// Distribute fractional tracks subject to their minima/maxima. The solver performs 32
    /// bounded bisection sweeps, with no allocation or convergence-dependent loop count.
    pub fn boundedFractions(gs: *Grids, k: u32, enabled: bool) void {
        gs.g.bounded[k] = @intFromBool(enabled);
    }
    /// Align the group of tracks inside free content-box space on each axis.
    pub fn distribute(gs: *Grids, k: u32, modes: [2]Distribution) void {
        inline for (0..2) |a| gs.g.distribution[a][k] = @backingInt(modes[a]);
    }
    /// Sets where item `r` sits in its cell across (`j[0]`) and down (`j[1]`). An item that
    /// does not stretch takes its natural size, which may overflow the cell.
    pub fn justify(gs: *Grids, r: u32, j: [2]Justify) void {
        inline for (0..2) |a| {
            gs.it.stretch[a][r] = Justify.k_stretch[@backingInt(j[a])];
            gs.it.factor[a][r] = Justify.factor[@backingInt(j[a])];
        }
    }
    /// Makes item `r` cover `n[0]` columns and `n[1]` rows from its cell, clamped to the tracks
    /// the grid has.
    pub fn span(gs: *Grids, r: u32, n: [2]u32) void {
        const k = gs.it.grid[r];
        inline for (0..2) |a| {
            const left = @max(gs.g.count[a][k] -| gs.it.cell[a][r], 1);
            gs.it.span[a][r] = @min(@max(n[a], 1), left);
        }
    }

    /// Shares an existing parent item's tracks with its child grid. Call after span and
    /// before run. Parent grids precede children, and the child axis has exactly the span's
    /// track count, preventing cycles and unbounded implicit expansion. The shared content
    /// edges coincide: use zero padding on this child axis, or inset its children instead.
    /// Both intrinsic child contributions and resolved parent lines are shared.
    pub fn shareAxis(gs: *Grids, child: u32, parent_item: u32, axis: Axis) error{InvalidSubgrid}!void {
        if (child >= gs.len or parent_item >= gs.items_len) return error.InvalidSubgrid;
        const a = @backingInt(axis);
        const parent = gs.it.grid[parent_item];
        if (parent >= child or gs.it.auto[parent_item] != 0 or gs.it.node[parent_item] != gs.g.node[child] or gs.g.count[a][child] != gs.it.span[a][parent_item]) return error.InvalidSubgrid;
        gs.g.parent[a][child] = parent;
        gs.g.parent_first[a][child] = gs.it.cell[a][parent_item];
        gs.g.gap[a][child] = gs.g.gap[a][parent];
        gs.it.subgrid[a][parent_item] = child;
    }
};

/// A grid container as one value (CSS `grid-template-*`, `grid-auto-*`, `gap`,
/// `grid-auto-flow`, `justify-content`/`align-content`, `justify-items`/`align-items`), for
/// `Grids.declare`. Index 0 is the column axis (x), 1 the row axis (y).
pub const Decl = struct {
    columns: []const Track = &.{},
    rows: []const Track = &.{},
    /// Size of the tracks auto-placement adds past the given ones (`grid-auto-columns`,
    /// `grid-auto-rows`).
    auto: [2]Track = .{ .fit, .fit },
    gap: [2]f32 = .{ 0, 0 },
    flow: AutoFlow = .row,
    distribution: [2]Distribution = .{ .start, .start },
    justify: [2]Justify = .{ .stretch, .stretch },

    /// The axis auto-placement adds tracks on: rows for row flow, columns for column flow.
    pub fn growAxis(d: Decl) u1 {
        return @intFromBool(@backingInt(d.flow) & 1 == 0);
    }
};

/// A grid item as one value (CSS `grid-column`, `grid-row`, `grid-area`, `justify-self`,
/// `align-self`), for `Grids.place`.
pub const Item = struct {
    /// Column and row of its first cell, from 0; null lets `autoPlace` choose.
    cell: ?[2]u32 = null,
    span: [2]u32 = .{ 1, 1 },
    /// Null takes the grid's `Decl.justify`.
    justify: ?[2]Justify = null,
};

/// How many tracks past `decl`'s own auto-placement of `items` can need on `decl.growAxis()`,
/// at most: every item past the last explicit cell, one after another. `declare` reserves them
/// and `autoPlace` keeps the ones it used.
pub fn implicitTracks(decl: Decl, items: []const Item) u32 {
    const g = decl.growAxis();
    const given: u32 = @intCast(if (g == 0) decl.columns.len else decl.rows.len);
    var end = given;
    var auto: u32 = 0;
    for (items) |it| {
        if (it.cell) |c| end = @max(end, c[g] + @max(it.span[g], 1)) else auto += @max(it.span[g], 1);
    }
    return end + auto - given;
}

pub const Repeat = enum { auto_fill, auto_fit };

/// Resolves an automatic repeat against a definite content extent, before constructing the
/// grid. Auto-fit removes empty trailing tracks; auto-fill retains them. The caller supplies
/// occupied track count (including spans), so explicit holes are not silently collapsed.
pub fn repeatAuto(extent: f32, gap: f32, minimum: f32, occupied_tracks: u32, mode: Repeat, track: Track, out: []Track) error{ NoSpace, InvalidGeometry }![]const Track {
    if (!std.math.isFinite(extent) or !std.math.isFinite(gap) or !std.math.isFinite(minimum) or extent < 0 or gap < 0 or minimum <= 0) return error.InvalidGeometry;
    const fitting = @max(@floor((extent + gap) / (minimum + gap)), 1);
    const count_float = if (mode == .auto_fit) @min(fitting, @as(f32, @floatFromInt(occupied_tracks))) else fitting;
    if (count_float >= 4294967296 or count_float > @as(f32, @floatFromInt(out.len))) return error.NoSpace;
    const count: u32 = @intFromFloat(count_float);
    if (out.len < count) return error.NoSpace;
    @memset(out[0..count], track);
    return out[0..count];
}

/// Materializes bounded implicit tracks by repeating the caller's pattern after explicit
/// tracks. No registry, retained style or allocator is needed; pass the result to grid().
pub fn expandTracks(explicit: []const Track, required: u32, pattern: []const Track, out: []Track) error{ NoSpace, MissingPattern }![]const Track {
    const count = @max(explicit.len, required);
    if (out.len < count) return error.NoSpace;
    if (count > explicit.len and pattern.len == 0) return error.MissingPattern;
    @memcpy(out[0..explicit.len], explicit);
    for (explicit.len..count) |i| out[i] = pattern[(i - explicit.len) % pattern.len];
    return out[0..count];
}

/// Sizes the tracks of grid `k` on axis `a` inside `inner`, the grid's content size, writes
/// each track's `size` and `start` (a running sum), and returns the total.
///
/// Fixed and fit tracks are sized first; what they leave of `inner` is shared out among the
/// fraction tracks by weight, in one pass: a fraction track is `max(content, share)`. CSS
/// instead repeats the share without the tracks whose content exceeds it ("find the size of
/// an fr"); here such a track keeps its content and the grid may come out wider than `inner`.
/// With `inner` 0 every fraction track is its content, which is the grid's natural size.
/// The grid's gap on that axis separates the tracks and is taken before the share.
pub fn sizeTracks(gs: *Grids, k: u32, a: u1, inner: f32) f32 {
    const first = gs.g.first[a][k];
    const n = gs.g.count[a][k];
    const tr = &gs.tr;
    const gap = gs.g.gap[a][k];
    const gaps_total = gap * @as(f32, @floatFromInt(n -| 1));
    var taken: f32 = gaps_total;
    var weight: f32 = 0;
    for (first..first + n) |j| {
        const is_fr = b01(tr.k_fr[j] > 0);
        taken += std.math.clamp(tr.k_px[j] + tr.content[j] * tr.k_fit[j], tr.min[j], tr.max[j]) * (1 - is_fr);
        weight += tr.k_fr[j];
    }
    const per_weight = if (gs.g.bounded[k] > 0)
        boundedShare(gs, first, n, @max(inner - taken, 0))
    else
        @max(inner - taken, 0) / @max(weight, 1e-6);
    var at: f32 = 0;
    for (first..first + n) |j| {
        const fixed = tr.k_px[j] + tr.content[j] * tr.k_fit[j];
        const flexed = @max(tr.content[j] * tr.content_floor[j], tr.k_fr[j] * per_weight);
        const s = std.math.clamp(fixed + b01(tr.k_fr[j] > 0) * (flexed - fixed), tr.min[j], tr.max[j]);
        tr.size[j] = s;
        tr.start[j] = at;
        at += s + gap;
    }
    const total = at - gap * b01(n > 0);
    const free_space = @max(inner - total, 0);
    const mode: Distribution = @fromBackingInt(gs.g.distribution[a][k]);
    const count: f32 = @floatFromInt(n);
    const between = switch (mode) {
        .space_between => free_space / @max(count - 1, 1) * b01(n > 1),
        .space_around => free_space / @max(count, 1),
        .space_evenly => free_space / (count + 1),
        else => 0,
    };
    const edge = switch (mode) {
        .center => free_space * 0.5,
        .end => free_space,
        .space_around => between * 0.5,
        .space_evenly => between,
        else => 0,
    };
    for (first..first + n, 0..) |j, index| tr.start[j] += edge + between * @as(f32, @floatFromInt(index));
    return total;
}

fn boundedShare(gs: *const Grids, first: u32, n: u32, available: f32) f32 {
    const tr = gs.tr;
    var min_weight = std.math.floatMax(f32);
    for (first..first + n) |j| min_weight = @min(min_weight, if (tr.k_fr[j] > 0) tr.k_fr[j] else std.math.floatMax(f32));
    var lo: f32 = 0;
    var hi = available / @max(min_weight, 1e-6);
    for (0..32) |_| {
        const mid = lo + (hi - lo) * 0.5;
        var total: f32 = 0;
        for (first..first + n) |j| {
            const lower = std.math.clamp(tr.content[j] * tr.content_floor[j], tr.min[j], tr.max[j]);
            const sized = std.math.clamp(mid * tr.k_fr[j], lower, tr.max[j]);
            total += sized * b01(tr.k_fr[j] > 0);
        }
        const over = total > available;
        hi = if (over) mid else hi;
        lo = if (over) lo else mid;
    }
    return lo + (hi - lo) * 0.5;
}

/// Chooses cells for the items pushed with `autoItem`, grid by grid, as CSS auto-placement in
/// row order (sparse): items with a cell take theirs first; then each auto item, in push
/// order, takes the first position at or after the previous auto item's end where its whole
/// span is free. A cursor, not a search from the start, so earlier holes stay empty. The grid
/// does not grow implicit rows: an item that finds no room goes in the last cell and sets
/// `overflow`, as does a grid with more cells than `cap.cells`.
/// A build step, run once after the items are pushed and before `fit`; `run` calls it.
// ponytail: the free-span test scans the span's cells at each candidate, O(cells * span area)
// per grid at worst; a per-row run-length of free cells would make it O(cells) if grids get big.
pub fn autoPlace(gs: *Grids) void {
    for (0..gs.len) |k| {
        // Reserved implicit tracks are all open to placement, then trimmed to what it used.
        inline for (0..2) |a| gs.g.count[a][k] = gs.g.reserved[a][k];
        defer trim(gs, @intCast(k));
        const cols = gs.g.count[0][k];
        const rows = gs.g.count[1][k];
        const cells = cols * rows;
        if (cells == 0) continue;
        const column = gs.g.flow[k] & 1 != 0;
        const dense = gs.g.flow[k] & 2 != 0;
        const minor = if (column) rows else cols;
        if (cells > gs.occupied.len) {
            gs.overflow = true;
            continue;
        }
        const occ = gs.occupied[0..cells];
        @memset(occ, 0);
        var it = gs.g.first_item[k];
        while (it != none) : (it = gs.it.next[it]) {
            if (gs.it.auto[it] == 0) mark(gs, occ, cols, it);
        }
        var cursor: u32 = 0;
        it = gs.g.first_item[k];
        while (it != none) : (it = gs.it.next[it]) {
            if (gs.it.auto[it] == 0) continue;
            const sc = gs.it.span[0][it];
            const sr = gs.it.span[1][it];
            var at: u32 = if (dense) 0 else cursor;
            while (at < cells) : (at += 1) {
                const col = if (column) at / minor else at % minor;
                const row = if (column) at % minor else at / minor;
                if (col + sc > cols or row + sr > rows) continue;
                if (free(occ, cols, col, row, sc, sr)) break;
            }
            const found = at < cells;
            gs.overflow = simd.orB(gs.overflow, !found);
            gs.it.cell[0][it] = if (found) (if (column) at / minor else at % minor) else cols -| sc;
            gs.it.cell[1][it] = if (found) (if (column) at % minor else at / minor) else rows -| sr;
            mark(gs, occ, cols, it);
            cursor = if (found) at + (if (column) sr else sc) else cells;
        }
    }
}

/// Grid `k`'s track count on each axis: its explicit tracks, or as many as its items reach
/// when it reserved more.
fn trim(gs: *Grids, k: u32) void {
    for (0..2) |a| {
        if (gs.g.reserved[a][k] == gs.g.explicit[a][k]) continue;
        var used = gs.g.explicit[a][k];
        var it = gs.g.first_item[k];
        while (it != none) : (it = gs.it.next[it]) used = @max(used, gs.it.cell[a][it] + gs.it.span[a][it]);
        gs.g.count[a][k] = @min(used, gs.g.reserved[a][k]);
    }
}

fn mark(gs: *const Grids, occ: []u8, cols: u32, it: u32) void {
    const col = gs.it.cell[0][it];
    for (gs.it.cell[1][it]..gs.it.cell[1][it] + gs.it.span[1][it]) |row| {
        @memset(occ[row * cols + col ..][0..gs.it.span[0][it]], 1);
    }
}

fn free(occ: []const u8, cols: u32, col: u32, row: u32, sc: u32, sr: u32) bool {
    for (row..row + sr) |r| {
        for (occ[r * cols + col ..][0..sc]) |o| if (o != 0) return false;
    }
    return true;
}

/// `layout.fit` for a tree with grids. Before each grid row is folded into its parent (the
/// sweep runs last row first, so all its items are done), its tracks take their content from
/// the items' natural sizes and the grid's `fit` becomes the tracks' total.
pub fn fit(t: *Tree, gs: *Grids, axis: Axis) void {
    if (t.len == 0) return;
    const a = @backingInt(axis);
    const nat = t.c.nat[a];
    var to = t.len;
    var k = gs.len;
    while (k > 0) {
        k -= 1;
        const node = gs.g.node[k];
        // Folds rows (node, to); `node` itself is folded by the next piece, after its fit is set.
        layout.fitSpan(t, axis, node, to);
        to = node + 1;
        const first = gs.g.first[a][k];
        @memset(gs.tr.content[first..][0..gs.g.count[a][k]], 0);
        var it = gs.g.first_item[k];
        while (it != none) : (it = gs.it.next[it]) {
            // A spanning item asks each of its tracks for an equal share. Not CSS's
            // distribution of the excess over the tracks' other content, which needs items
            // sorted by span; this is one pass.
            const j = first + gs.it.cell[a][it];
            const n = gs.it.span[a][it];
            // A subgrid item takes its child grid's track contents instead. One loop for both:
            // contents are never below 0, so a share of 0 leaves the child's tracks alone, and
            // reading its own tracks leaves a plain item's share alone.
            const child = gs.it.subgrid[a][it];
            const sub = child != none;
            const source = simd.selU(sub, gs.g.first[a][simd.selU(sub, child, k)], j);
            const gap = gs.g.gap[a][k];
            const share = @max(nat[gs.it.node[it]] - gap * @as(f32, @floatFromInt(n - 1)), 0) / @as(f32, @floatFromInt(n));
            const floor = simd.selF(sub, 0, share);
            for (0..n) |offset| gs.tr.content[j + offset] = @max(gs.tr.content[j + offset], @max(gs.tr.content[source + offset], floor));
        }
        t.c.fit[a][node] = sizeTracks(gs, k, a, 0);
    }
    layout.fitSpan(t, axis, 0, to);
}

/// `layout.resolve` for a tree with grids. Rows are resolved in order, in pieces: after a grid
/// row is sized, its tracks are sized inside it and each item gets its cell's size and start;
/// an item row then takes its cell size (within its own min and max) instead of the flow
/// formula, and its children are resolved inside it as usual.
pub fn resolve(t: *Tree, gs: *Grids, axis: Axis, viewport: f32) void {
    if (t.len == 0) return;
    const a = @backingInt(axis);
    const c = &t.c;
    c.size[a][0] = viewport;
    var from: u32 = 1;
    var k: u32 = 0;
    var r: u32 = 0;
    while (true) {
        const grid_row = if (k < gs.len) gs.g.node[k] else none;
        const item_row = if (r < gs.items_len) gs.it.node[r] else none;
        if (grid_row == none and item_row == none) break;
        if (item_row <= grid_row) {
            // An item that is also a grid is sized as an item first.
            resolveRows(t, axis, from, item_row);
            const min = c.min[a][item_row];
            const max = c.max[a][item_row];
            const cell = gs.it.cell_size[a][r];
            const natural = @min(@max(c.nat[a][item_row], min), max);
            const filled = @min(@max(cell, min), max);
            const sz = natural + gs.it.stretch[a][r] * (filled - natural);
            c.size[a][item_row] = sz;
            c.offset[a][item_row] = gs.it.cell_start[a][r] + (cell - sz) * gs.it.factor[a][r];
            from = item_row + 1;
            r += 1;
        } else {
            resolveRows(t, axis, from, grid_row + 1);
            from = grid_row + 1;
            const node = gs.g.node[k];
            const parent = gs.g.parent[a][k];
            if (parent == none) {
                _ = sizeTracks(gs, k, a, c.size[a][node] - c.pad_lo[a][node] - c.pad_hi[a][node]);
            } else {
                const source = gs.g.first[a][parent] + gs.g.parent_first[a][k];
                const destination = gs.g.first[a][k];
                for (0..gs.g.count[a][k]) |offset| {
                    gs.tr.size[destination + offset] = gs.tr.size[source + offset];
                    gs.tr.start[destination + offset] = gs.tr.start[source + offset] - gs.tr.start[source];
                }
            }
            const first = gs.g.first[a][k];
            var it = gs.g.first_item[k];
            while (it != none) : (it = gs.it.next[it]) {
                const j = first + gs.it.cell[a][it];
                const last = j + gs.it.span[a][it] - 1;
                gs.it.cell_size[a][it] = gs.tr.start[last] + gs.tr.size[last] - gs.tr.start[j];
                gs.it.cell_start[a][it] = gs.tr.start[j];
            }
            k += 1;
        }
    }
    resolveRows(t, axis, from, t.len);
}

/// `layout.resolve`'s sweep over rows [from, to), `from` >= 1 and `from` <= `to`: the parents
/// of those rows are sized already. `resolveSpan` resolves the rows after its `first`, and
/// reads nothing of `first` itself but as a parent.
inline fn resolveRows(t: *Tree, axis: Axis, from: u32, to: u32) void {
    layout.resolveSpan(t, axis, from - 1, to);
}

/// Every pass in order, as `layout.run`, with `fit` and `resolve` taken from this file.
pub fn run(t: *Tree, tx: *Texts, gs: *Grids, viewport: [2]f32) void {
    autoPlace(gs);
    layout.prepare(t);
    layout.applyText(t, tx, .x);
    fit(t, gs, .x);
    resolve(t, gs, .x, viewport[0]);
    layout.textAvail(t, tx);
    layout.applyText(t, tx, .y);
    fit(t, gs, .y);
    resolve(t, gs, .y, viewport[1]);
    layout.place(t);
    layout.finalize(t);
}

const b01 = simd.b2f;

test "bounded grid fractions honor minima caps and redistribution in actual cell geometry" {
    var s: Scene = .{};
    s.init();
    const t = &s.t;
    const g = t.push(0, .none, &.{});
    const k = s.gs.grid(g, &.{
        .minmaxFr(80, 1, 1000), .minmaxFr(0, 1, 30), .minmaxFr(0, 2, 1000),
    }, &.{.minmax(10, 20)});
    s.gs.boundedFractions(k, true);
    const a = s.cell(g, k, .{ 0, 0 }, .{ 200, 100 });
    const b = s.cell(g, k, .{ 1, 0 }, .{ 200, 10 });
    const c = s.cell(g, k, .{ 2, 0 }, .{ 200, 10 });
    t.seal(g);
    run(t, &s.tx, &s.gs, .{ 200, 50 });
    try testing.expectApproxEqAbs(80, t.c.size[0][a], 1e-4);
    try testing.expectApproxEqAbs(30, t.c.size[0][b], 1e-4);
    try testing.expectApproxEqAbs(90, t.c.size[0][c], 1e-4);
    try testing.expectEqual(20, t.c.size[1][a]);
    try testing.expectApproxEqAbs(200, s.gs.tr.start[2] + s.gs.tr.size[2], 1e-4);
}

test "grid content distribution and bounded fit tracks set cell starts" {
    var s: Scene = .{};
    s.init();
    const g = s.t.push(0, .none, &.{});
    const k = s.gs.grid(g, &.{ .px(10), .fitContent(20) }, &.{.px(10)});
    s.gs.gaps(k, .{ 10, 0 });
    s.gs.distribute(k, .{ .space_evenly, .center });
    const a = s.cell(g, k, .{ 0, 0 }, .{ 5, 5 });
    const b = s.cell(g, k, .{ 1, 0 }, .{ 100, 5 });
    s.t.seal(g);
    run(&s.t, &s.tx, &s.gs, .{ 100, 30 });
    try testing.expectEqual(rect(20, 10, 30, 20), s.t.rect(a));
    try testing.expectEqual(rect(60, 10, 80, 20), s.t.rect(b));
}

test "dense and column auto flow use bounded existing cells" {
    var s: Scene = .{};
    s.init();
    const g = s.t.push(0, .none, &.{});
    const k = s.gs.grid(g, &.{ .px(10), .px(10), .px(10) }, &.{ .px(10), .px(10) });
    _ = s.gs.item(k, 1, .{ 1, 0 });
    const wide = s.gs.autoItem(k, 2);
    s.gs.span(wide, .{ 2, 1 });
    const small = s.gs.autoItem(k, 3);
    autoPlace(&s.gs);
    try testing.expectEqual([2]u32{ 2, 1 }, [2]u32{ s.gs.it.cell[0][small], s.gs.it.cell[1][small] });
    s.gs.autoFlow(k, .row_dense);
    autoPlace(&s.gs);
    try testing.expectEqual([2]u32{ 0, 0 }, [2]u32{ s.gs.it.cell[0][small], s.gs.it.cell[1][small] });
    s.gs.autoFlow(k, .column_dense);
    autoPlace(&s.gs);
    try testing.expectEqual([2]u32{ 0, 1 }, [2]u32{ s.gs.it.cell[0][wide], s.gs.it.cell[1][wide] });
    try testing.expectEqual([2]u32{ 0, 0 }, [2]u32{ s.gs.it.cell[0][small], s.gs.it.cell[1][small] });
    try testing.expect(!s.gs.overflow);
}
const testing = std.testing;

test "sizeTracks: fixed tracks take their pixels, fit and fraction tracks their content" {
    var raw: [8192]u8 align(mem.column_align) = undefined;
    var carver: mem.Carver = .{ .buf = &raw };
    var gs = Grids.init(&carver, .{ .grids = 2, .tracks = 8, .items = 1 });
    const k = gs.grid(7, &.{ .px(100), .fit, .fr(2) }, &.{ .fit, .px(30) });
    try testing.expectEqual(0, k);
    try testing.expectEqual(5, gs.tracks_len);
    try testing.expectEqual(7, gs.g.node[k]);
    try testing.expectEqualSlices(u32, &.{ 0, 3 }, &.{ gs.g.first[0][k], gs.g.first[1][k] });
    try testing.expectEqualSlices(u32, &.{ 3, 2 }, &.{ gs.g.count[0][k], gs.g.count[1][k] });

    // Content as the fit step leaves it: the fixed track's content does not count.
    @memcpy(gs.tr.content[0..5], &[_]f32{ 500, 40, 25, 12, 99 });
    try testing.expectEqual(165, sizeTracks(&gs, k, 0, 0));
    try testing.expectEqualSlices(f32, &.{ 100, 40, 25 }, gs.tr.size[0..3]);
    try testing.expectEqualSlices(f32, &.{ 0, 100, 140 }, gs.tr.start[0..3]);
    try testing.expectEqual(42, sizeTracks(&gs, k, 1, 0));
    try testing.expectEqualSlices(f32, &.{ 12, 30 }, gs.tr.size[3..5]);
    try testing.expectEqualSlices(f32, &.{ 0, 12 }, gs.tr.start[3..5]);
}

test "Grids: running out of grid or track rows is reported and writes nothing out of bounds" {
    var raw: [8192]u8 align(mem.column_align) = undefined;
    var carver: mem.Carver = .{ .buf = &raw };
    var gs = Grids.init(&carver, .{ .grids = 1, .tracks = 3, .items = 1 });
    _ = gs.grid(0, &.{ .fit, .fit }, &.{.fit});
    try testing.expect(!gs.overflow);
    // Too many tracks: the grid is kept with none.
    gs.reset();
    const k = gs.grid(0, &.{ .fit, .fit }, &.{ .fit, .fit });
    try testing.expect(gs.overflow);
    try testing.expectEqual(0, gs.g.count[0][k] + gs.g.count[1][k]);
    try testing.expectEqual(0, sizeTracks(&gs, k, 0, 0));
    // Too many grids: the last row is reused.
    gs.reset();
    _ = gs.grid(0, &.{.fit}, &.{});
    try testing.expectEqual(0, gs.grid(1, &.{.fit}, &.{}));
    try testing.expect(gs.overflow);
    try testing.expectEqual(1, gs.len);
}

/// A tree, an empty text list and grid tables in a caller-owned buffer, for the tests.
const Scene = struct {
    raw: [256 * 1024]u8 align(mem.column_align) = undefined,
    t: Tree = undefined,
    tx: Texts = undefined,
    gs: Grids = undefined,

    fn init(s: *Scene) void {
        var carver: mem.Carver = .{ .buf = &s.raw };
        s.t = Tree.init(&carver, 64);
        s.tx = Texts.init(&carver, 1);
        s.gs = Grids.init(&carver, .{ .grids = 4, .tracks = 16, .items = 32, .cells = 32 });
    }
    /// A floating grid item holding one fixed-size child, so its natural size is the child's.
    fn cell(s: *Scene, grid_node: u32, k: u32, at: [2]u32, content: [2]f32) u32 {
        const n = s.t.push(grid_node, .none, &.{ .float = true });
        s.t.seal(s.t.push(n, .none, &.{ .size = .{ .px(content[0]), .px(content[1]) } }));
        s.t.seal(n);
        _ = s.gs.item(k, n, at);
        return n;
    }
};

fn rect(x0: f32, y0: f32, x1: f32, y1: f32) types.Rect {
    return .{ .x0 = x0, .y0 = y0, .x1 = x1, .y1 = y1 };
}

test "shared subgrid contributes individual intrinsic tracks and reuses resolved lines" {
    var s: Scene = .{};
    s.init();
    const parent = s.t.push(0, .none, &.{});
    const pg = s.gs.grid(parent, &.{ .fit, .fit, .fit }, &.{.fit});
    s.gs.gaps(pg, .{ 5, 0 });
    const child = s.t.push(parent, .none, &.{ .float = true });
    const item = s.gs.item(pg, child, .{ 0, 0 });
    s.gs.span(item, .{ 2, 1 });
    const cg = s.gs.grid(child, &.{ .fit, .fit }, &.{.fit});
    try s.gs.shareAxis(cg, item, .x);
    const a = s.cell(child, cg, .{ 0, 0 }, .{ 60, 10 });
    const b = s.cell(child, cg, .{ 1, 0 }, .{ 10, 10 });
    s.t.seal(child);
    const c = s.cell(parent, pg, .{ 2, 0 }, .{ 30, 10 });
    s.t.seal(parent);
    run(&s.t, &s.tx, &s.gs, .{ 200, 100 });
    try testing.expectEqual(60, s.t.c.size[0][a]);
    try testing.expectEqual(65, s.t.c.pos[0][b]);
    try testing.expectEqual(80, s.t.c.pos[0][c]);
    try testing.expectEqual(75, s.t.c.size[0][child]);
    try testing.expectError(error.InvalidSubgrid, s.gs.shareAxis(pg, item, .x));
}

test "automatic repeats and bounded implicit patterns feed actual grid track sizing" {
    var repeated: [8]Track = undefined;
    const filled = try repeatAuto(320, 10, 100, 2, .auto_fill, .minmaxFr(100, 1, 1000), &repeated);
    try testing.expectEqual(3, filled.len);
    const fitted = try repeatAuto(320, 10, 100, 2, .auto_fit, .minmaxFr(100, 1, 1000), &repeated);
    try testing.expectEqual(2, fitted.len);
    var expanded: [8]Track = undefined;
    const rows = try expandTracks(&.{.px(5)}, 4, &.{ .px(10), .px(20) }, &expanded);
    var s: Scene = .{};
    s.init();
    const g = s.gs.grid(0, fitted, rows);
    s.gs.gaps(g, .{ 10, 2 });
    s.gs.boundedFractions(g, true);
    _ = sizeTracks(&s.gs, g, 0, 320);
    _ = sizeTracks(&s.gs, g, 1, 100);
    try testing.expectApproxEqAbs(155, s.gs.tr.size[0], 0.001);
    try testing.expectApproxEqAbs(165, s.gs.tr.start[1], 0.001);
    const first = s.gs.g.first[1][g];
    try testing.expectEqualSlices(f32, &.{ 5, 10, 20, 10 }, s.gs.tr.size[first..][0..4]);
    try testing.expectError(error.NoSpace, repeatAuto(1000, 0, 1, 1000, .auto_fill, .fit, &repeated));
}

test "grid: items in explicit cells; fit tracks take the largest item, items fill their cell" {
    var s: Scene = .{};
    s.init();
    const t = &s.t;
    const root = t.push(0, .none, &.{ .size = .{ .px(400), .px(300) }, .pad = @splat(10) });
    const g = t.push(root, .none, &.{ .pad = @splat(5) });
    const k = s.gs.grid(g, &.{ .px(100), .fit }, &.{ .fit, .px(30) });
    const a = s.cell(g, k, .{ 0, 0 }, .{ 40, 15 });
    const b = s.cell(g, k, .{ 1, 0 }, .{ 70, 25 });
    const c = s.cell(g, k, .{ 0, 1 }, .{ 20, 10 });
    const d = s.cell(g, k, .{ 1, 1 }, .{ 60, 50 });
    // A cell past the last track is clamped to it.
    const e = s.cell(g, k, .{ 9, 9 }, .{ 5, 5 });
    t.seal(g);
    const after = t.push(root, .none, &.{ .size = .{ .px(20), .px(20) } });
    t.seal(root);
    run(t, &s.tx, &s.gs, .{ 400, 300 });

    // Columns 100 and max(70, 60, 5) = 70; rows max(15, 25) = 25 and 30. Plus padding 5.
    try testing.expectEqual(rect(10, 10, 190, 75), t.rect(g));
    try testing.expectEqual(rect(15, 15, 115, 40), t.rect(a));
    try testing.expectEqual(rect(115, 15, 185, 40), t.rect(b));
    try testing.expectEqual(rect(15, 40, 115, 70), t.rect(c));
    try testing.expectEqual(rect(115, 40, 185, 70), t.rect(d));
    try testing.expectEqual(t.rect(d), t.rect(e));
    // An item's children are laid out inside it as usual; d's taller child overflows its row.
    try testing.expectEqual(rect(115, 40, 175, 90), t.rect(d + 1));
    // The grid takes part in its parent's flow with its tracks' size.
    try testing.expectEqual(rect(10, 75, 30, 95), t.rect(after));
}

test "grid: a grid inside a grid cell, and a fixed-size item kept to its own size" {
    var s: Scene = .{};
    s.init();
    const t = &s.t;
    const root = t.push(0, .none, &.{ .size = .{ .px(400), .px(300) } });
    const outer = t.push(root, .none, &.{});
    const ko = s.gs.grid(outer, &.{ .fit, .fit }, &.{.fit});
    // Cell (0, 0) holds a 2 x 1 grid of 30x10 and 50x20 items.
    const inner = t.push(outer, .none, &.{ .float = true });
    _ = s.gs.item(ko, inner, .{ 0, 0 });
    const ki = s.gs.grid(inner, &.{ .fit, .fit }, &.{.fit});
    const p = s.cell(inner, ki, .{ 0, 0 }, .{ 30, 10 });
    const q = s.cell(inner, ki, .{ 1, 0 }, .{ 50, 20 });
    t.seal(inner);
    // Cell (1, 0): a px item keeps its size; it is not stretched to the 20 px row.
    const fixed = t.push(outer, .none, &.{ .size = .{ .px(15), .px(8) }, .float = true });
    _ = s.gs.item(ko, fixed, .{ 1, 0 });
    t.seal(fixed);
    t.seal(outer);
    t.seal(root);
    run(t, &s.tx, &s.gs, .{ 400, 300 });
    try testing.expectEqual(rect(0, 0, 80, 20), t.rect(inner));
    try testing.expectEqual(rect(0, 0, 30, 20), t.rect(p));
    try testing.expectEqual(rect(30, 0, 80, 20), t.rect(q));
    try testing.expectEqual(rect(80, 0, 95, 8), t.rect(fixed));
    try testing.expectEqual(rect(0, 0, 95, 20), t.rect(outer));
}

test "grid: with no grids, fit and resolve are the layout passes" {
    var a: Scene = .{};
    var b: Scene = .{};
    a.init();
    b.init();
    inline for (.{ &a, &b }) |s| {
        const t = &s.t;
        const root = t.push(0, .none, &.{ .size = .{ .px(200), .px(100) }, .pad = @splat(4), .gap = 3 });
        t.seal(t.push(root, .none, &.{ .size = .{ .fill, .px(20) } }));
        t.seal(t.push(root, .none, &.{ .size = .{ .px(50), .fill }, .shrink = true }));
        t.seal(root);
    }
    run(&a.t, &a.tx, &a.gs, .{ 200, 100 });
    layout.run(&b.t, &b.tx, .{ 200, 100 });
    for (0..3) |i| try testing.expectEqual(b.t.rect(@intCast(i)), a.t.rect(@intCast(i)));
}

test "grid: spanning items cover several tracks and share their size among them" {
    var s: Scene = .{};
    s.init();
    const t = &s.t;
    const root = t.push(0, .none, &.{ .size = .{ .px(400), .px(300) } });
    const g = t.push(root, .none, &.{});
    const k = s.gs.grid(g, &.{ .fit, .fit, .fit }, &.{ .fit, .fit });
    const a = s.cell(g, k, .{ 0, 0 }, .{ 100, 10 });
    s.gs.span(s.gs.items_len - 1, .{ 2, 1 });
    const d = s.cell(g, k, .{ 2, 0 }, .{ 40, 60 });
    s.gs.span(s.gs.items_len - 1, .{ 5, 2 }); // 5 columns from the last one: clamped to 1
    const b = s.cell(g, k, .{ 0, 1 }, .{ 30, 10 });
    const c = s.cell(g, k, .{ 1, 1 }, .{ 20, 10 });
    t.seal(g);
    t.seal(root);
    run(t, &s.tx, &s.gs, .{ 400, 300 });
    try testing.expectEqualSlices(u32, &.{ 2, 1 }, &.{ s.gs.it.span[0][0], s.gs.it.span[0][1] });
    // Columns: a's 100 split over two gives 50, 50 (b and c are smaller); d's 40.
    // Rows: d's 60 split over two gives 30, 30 (a, b and c are 10).
    try testing.expectEqual(rect(0, 0, 100, 30), t.rect(a));
    try testing.expectEqual(rect(100, 0, 140, 60), t.rect(d));
    try testing.expectEqual(rect(0, 30, 50, 60), t.rect(b));
    try testing.expectEqual(rect(50, 30, 100, 60), t.rect(c));
    try testing.expectEqual(rect(0, 0, 140, 60), t.rect(g));
}

test "autoPlace: row order around explicit items, spans that do not fit move on" {
    var s: Scene = .{};
    s.init();
    const t = &s.t;
    const g = t.push(0, .none, &.{});
    // 3 columns of 10, 3 rows of 10.
    const k = s.gs.grid(g, &.{ .px(10), .px(10), .px(10) }, &.{ .px(10), .px(10), .px(10) });
    var nodes: [6]u32 = undefined;
    var rows: [6]u32 = undefined;
    for (&nodes, &rows, 0..) |*n, *r, i| {
        n.* = t.push(g, .none, &.{ .float = true });
        t.seal(n.*);
        // Item 1 is explicit at (1, 0); the others are auto.
        r.* = if (i == 1) s.gs.item(k, n.*, .{ 1, 0 }) else s.gs.autoItem(k, n.*);
    }
    t.seal(g);
    s.gs.span(rows[3], .{ 2, 1 }); // two columns wide
    s.gs.span(rows[4], .{ 1, 2 }); // two rows high
    autoPlace(&s.gs);
    const at = struct {
        fn f(gs: *const Grids, r: u32) [2]u32 {
            return .{ gs.it.cell[0][r], gs.it.cell[1][r] };
        }
    }.f;
    //   row 0:  0  1  2
    //   row 1:  3  3  4
    //   row 2:  5  .  4
    try testing.expectEqual([2]u32{ 0, 0 }, at(&s.gs, rows[0]));
    try testing.expectEqual([2]u32{ 1, 0 }, at(&s.gs, rows[1]));
    try testing.expectEqual([2]u32{ 2, 0 }, at(&s.gs, rows[2]));
    try testing.expectEqual([2]u32{ 0, 1 }, at(&s.gs, rows[3]));
    try testing.expectEqual([2]u32{ 2, 1 }, at(&s.gs, rows[4]));
    // After item 4 at (2, 1) the cursor is at (0, 2), so (1, 2) stays empty.
    try testing.expectEqual([2]u32{ 0, 2 }, at(&s.gs, rows[5]));
    try testing.expect(!s.gs.overflow);
    run(t, &s.tx, &s.gs, .{ 100, 100 });
    try testing.expectEqual(rect(0, 10, 20, 20), t.rect(nodes[3]));
    try testing.expectEqual(rect(20, 10, 30, 30), t.rect(nodes[4]));

    // One more auto item than there is room for: it goes in the last cell, flagged.
    const extra = t.push(g, .none, &.{ .float = true });
    t.seal(extra);
    s.gs.span(s.gs.autoItem(k, extra), .{ 2, 2 });
    autoPlace(&s.gs);
    try testing.expect(s.gs.overflow);
    try testing.expectEqual([2]u32{ 1, 1 }, at(&s.gs, s.gs.items_len - 1));
}

test "sizeTracks: fraction tracks share what fixed and fit tracks leave, by weight, once" {
    var raw: [8192]u8 align(mem.column_align) = undefined;
    var carver: mem.Carver = .{ .buf = &raw };
    var gs = Grids.init(&carver, .{ .grids = 1, .tracks = 8, .items = 1 });
    const k = gs.grid(0, &.{ .px(50), .fr(1), .fr(2), .fit }, &.{.fr(1)});
    @memcpy(gs.tr.content[0..5], &[_]f32{ 0, 10, 20, 40, 5 });
    // 300 - 50 - 40 = 210 left: 70 and 140.
    try testing.expectEqual(300, sizeTracks(&gs, k, 0, 300));
    try testing.expectEqualSlices(f32, &.{ 50, 70, 140, 40 }, gs.tr.size[0..4]);
    try testing.expectEqualSlices(f32, &.{ 0, 50, 120, 260 }, gs.tr.start[0..4]);
    // Natural size (inner 0): every fraction track is its content.
    try testing.expectEqual(120, sizeTracks(&gs, k, 0, 0));
    // A fraction track whose content exceeds its share keeps its content; the others are not
    // shared out again, so the total passes the inner size.
    gs.tr.content[1] = 100;
    try testing.expectEqual(330, sizeTracks(&gs, k, 0, 300));
    try testing.expectEqualSlices(f32, &.{ 50, 100, 140, 40 }, gs.tr.size[0..4]);
    // Less room than the fixed tracks take: fractions get their content only.
    try testing.expectEqual(210, sizeTracks(&gs, k, 0, 60));
}

test "grid: fraction columns split the grid's width; a growing grid stretches them" {
    var s: Scene = .{};
    s.init();
    const t = &s.t;
    const root = t.push(0, .none, &.{ .size = .{ .px(400), .px(300) }, .pad = @splat(10) });
    const g = t.push(root, .none, &.{ .size = .{ .fill, .fit }, .pad = .{ 5, 0, 5, 0 } });
    const k = s.gs.grid(g, &.{ .px(70), .fr(1), .fr(3) }, &.{.fit});
    const a = s.cell(g, k, .{ 0, 0 }, .{ 10, 20 });
    const b = s.cell(g, k, .{ 1, 0 }, .{ 10, 20 });
    const c = s.cell(g, k, .{ 2, 0 }, .{ 10, 20 });
    t.seal(g);
    t.seal(root);
    run(t, &s.tx, &s.gs, .{ 400, 300 });
    // The grid fills 380 across; inside its padding 370 - 70 = 300 is shared 1 : 3.
    try testing.expectEqual(rect(10, 10, 390, 30), t.rect(g));
    try testing.expectEqual(rect(15, 10, 85, 30), t.rect(a));
    try testing.expectEqual(rect(85, 10, 160, 30), t.rect(b));
    try testing.expectEqual(rect(160, 10, 385, 30), t.rect(c));
}

test "grid: gaps between tracks, spans across gaps, and items aligned in their cells" {
    var s: Scene = .{};
    s.init();
    const t = &s.t;
    const root = t.push(0, .none, &.{ .size = .{ .px(400), .px(300) } });
    const g = t.push(root, .none, &.{ .size = .{ .px(230), .fit } });
    const k = s.gs.grid(g, &.{ .px(50), .fr(1), .fr(1) }, &.{ .px(40), .fit });
    s.gs.gaps(k, .{ 10, 4 });
    // Row 0: three 20x10 items aligned start, centre, end on both axes.
    const a = s.cell(g, k, .{ 0, 0 }, .{ 20, 10 });
    s.gs.justify(s.gs.items_len - 1, .{ .start, .start });
    const b = s.cell(g, k, .{ 1, 0 }, .{ 20, 10 });
    s.gs.justify(s.gs.items_len - 1, .{ .center, .center });
    const c = s.cell(g, k, .{ 2, 0 }, .{ 20, 10 });
    s.gs.justify(s.gs.items_len - 1, .{ .end, .end });
    // Row 1: one stretched item over all three columns, gaps included; its 26 px height
    // makes the fit row 26.
    const d = s.cell(g, k, .{ 0, 1 }, .{ 30, 26 });
    s.gs.span(s.gs.items_len - 1, .{ 3, 1 });
    t.seal(g);
    t.seal(root);
    run(t, &s.tx, &s.gs, .{ 400, 300 });
    // Columns: 230 - 50 - 2 gaps of 10 = 160 shared, 80 each, starting at 0, 60, 150.
    try testing.expectEqualSlices(f32, &.{ 50, 80, 80 }, s.gs.tr.size[0..3]);
    try testing.expectEqualSlices(f32, &.{ 0, 60, 150 }, s.gs.tr.start[0..3]);
    // Rows 40 and 26 with a 4 px gap.
    try testing.expectEqual(rect(0, 0, 230, 70), t.rect(g));
    try testing.expectEqual(rect(0, 0, 20, 10), t.rect(a));
    try testing.expectEqual(rect(90, 15, 110, 25), t.rect(b));
    try testing.expectEqual(rect(210, 30, 230, 40), t.rect(c));
    try testing.expectEqual(rect(0, 44, 230, 70), t.rect(d));
}

test "grid: a spanning item's natural size leaves out the gaps it covers" {
    var s: Scene = .{};
    s.init();
    const t = &s.t;
    const g = t.push(0, .none, &.{});
    const k = s.gs.grid(g, &.{ .fit, .fit }, &.{.fit});
    s.gs.gaps(k, .{ 10, 0 });
    const w = s.cell(g, k, .{ 0, 0 }, .{ 110, 10 });
    s.gs.span(s.gs.items_len - 1, .{ 2, 1 });
    t.seal(g);
    run(t, &s.tx, &s.gs, .{ 400, 300 });
    // (110 - 10) / 2 = 50 per column: 50 + 10 + 50 is exactly the item.
    try testing.expectEqualSlices(f32, &.{ 50, 50 }, s.gs.tr.size[0..2]);
    try testing.expectEqual(rect(0, 0, 110, 10), t.rect(w));
    // The grid is the root, so it is the viewport's size; its natural width is the tracks'.
    try testing.expectEqual(110, t.c.nat[0][g]);
}

test "grid: a settings form of text labels and fields, auto-placed, inside a flow column" {
    const Mono = @import("../text/protocol.zig").Mono;
    const Strings = @import("../core/strings.zig").Strings;
    var s: Scene = .{};
    s.init();
    var carver: mem.Carver = .{ .buf = s.raw[200 * 1024 ..] };
    s.tx = Texts.init(&carver, 4);
    var strings: Strings = .{ .buf = carver.slice(u8, 256) };
    const t = &s.t;
    // column 300 wide { title 20 high, form grid [fit, fr(1)] x [fit, fit, fit], footer }
    const root = t.push(0, .none, &.{ .size = .{ .px(300), .px(400) }, .pad = @splat(10), .gap = 6 });
    const title = t.push(root, .none, &.{ .size = .{ .fill, .px(20) } });
    t.seal(title);
    const form = t.push(root, .none, &.{ .size = .{ .fill, .fit } });
    const k = s.gs.grid(form, &.{ .fit, .fr(1) }, &.{ .fit, .fit, .fit });
    s.gs.gaps(k, .{ 8, 4 });
    const words = [_][]const u8{ "Name", "E-mail", "Notes" };
    var labels: [3]u32 = undefined;
    var fields: [3]u32 = undefined;
    for (words, &labels, &fields) |w, *l, *f| {
        l.* = t.push(form, .none, &.{ .float = true });
        t.c.text[l.*] = s.tx.push(l.*, strings.add(w), &.{ .px = 10 });
        t.seal(l.*);
        s.gs.justify(s.gs.autoItem(k, l.*), .{ .end, .center });
        f.* = t.push(form, .none, &.{ .float = true, .size = .{ .fit, .px(18) } });
        t.seal(f.*);
        _ = s.gs.autoItem(k, f.*);
    }
    // The notes field spans down two rows' worth of height: make it taller instead.
    t.c.min[1][fields[2]] = 40;
    t.c.max[1][fields[2]] = 40;
    t.seal(form);
    const footer = t.push(root, .none, &.{ .size = .{ .fill, .px(10) } });
    t.seal(footer);
    t.seal(root);

    // Mono at 10 px: 5 px per byte, 12 px lines.
    const font: Mono = .{ .advance = 0.5, .line = 1.2 };
    font.measure(&s.tx);
    run(t, &s.tx, &s.gs, .{ 300, 400 });

    // Labels column: "E-mail" is 30 px; fields take 280 - 30 - 8 = 242.
    try testing.expectEqualSlices(f32, &.{ 30, 242 }, s.gs.tr.size[0..2]);
    // Rows: 18, 18, 40 (fields are taller than the 12 px labels), with 4 px gaps.
    try testing.expectEqualSlices(f32, &.{ 18, 18, 40 }, s.gs.tr.size[2..5]);
    try testing.expectEqual(rect(10, 36, 290, 120), t.rect(form));
    // Labels sit at the end of their column and in the middle of their row.
    try testing.expectEqual(rect(20, 39, 40, 51), t.rect(labels[0]));
    try testing.expectEqual(rect(10, 61, 40, 73), t.rect(labels[1]));
    try testing.expectEqual(rect(15, 94, 40, 106), t.rect(labels[2]));
    try testing.expectEqual(rect(48, 36, 290, 54), t.rect(fields[0]));
    try testing.expectEqual(rect(48, 80, 290, 120), t.rect(fields[2]));
    // The flow after the grid continues below it.
    try testing.expectEqual(rect(10, 126, 290, 136), t.rect(footer));
    try testing.expect(!s.gs.overflow);
}

test "declare, place: a table of auto-placed cells grows rows, and only as many as it uses" {
    var s: Scene = .{};
    s.init();
    const decl: Decl = .{ .columns = &.{ .px(30), .px(40), .px(50) }, .gap = .{ 2, 3 } };
    // Seven cells, the second two columns wide: rows of 3, 2 + 1 (the span), 1.
    const items = [_]Item{ .{}, .{ .span = .{ 2, 1 } }, .{}, .{}, .{}, .{}, .{} };
    const implicit = implicitTracks(decl, &items);
    try testing.expectEqual(7, implicit);
    const g = s.t.push(0, .none, &.{});
    const k = s.gs.declare(g, decl, implicit);
    var nodes: [items.len]u32 = undefined;
    for (items, &nodes) |it, *n| {
        _ = s.gs.place(k, s.t.len, it);
        n.* = s.t.push(g, .none, &.{ .float = true, .size = .{ .fit, .px(10) } });
        s.t.seal(n.*);
    }
    s.t.seal(g);
    run(&s.t, &s.tx, &s.gs, .{ 200, 200 });
    try testing.expectEqual(3, s.gs.g.count[1][k]);
    // Row 0: 0 1(span 2); row 1: 2 3 4; row 2: 5 6.
    try testing.expectEqual(rect(0, 0, 30, 10), s.t.rect(nodes[0]));
    try testing.expectEqual(rect(32, 0, 124, 10), s.t.rect(nodes[1]));
    try testing.expectEqual(rect(0, 13, 30, 23), s.t.rect(nodes[2]));
    try testing.expectEqual(rect(32, 26, 72, 36), s.t.rect(nodes[6]));
    try testing.expectEqual(rect(0, 26, 30, 36), s.t.rect(nodes[5]));
    // A second placement opens the reserve again and keeps the same rows.
    autoPlace(&s.gs);
    try testing.expectEqual(3, s.gs.g.count[1][k]);
}

test "declare: no tracks on an axis is one auto track; items take the grid's justify" {
    var s: Scene = .{};
    s.init();
    const g = s.t.push(0, .none, &.{});
    const k = s.gs.declare(g, .{ .justify = .{ .center, .end } }, 0);
    try testing.expectEqualSlices(u32, &.{ 1, 1 }, &.{ s.gs.g.count[0][k], s.gs.g.count[1][k] });
    const r = s.gs.place(k, 1, .{});
    try testing.expectEqualSlices(f32, &.{ 0, 0, 0.5, 1 }, &.{ s.gs.it.stretch[0][r], s.gs.it.stretch[1][r], s.gs.it.factor[0][r], s.gs.it.factor[1][r] });
    const r2 = s.gs.place(k, 2, .{ .cell = .{ 0, 0 }, .justify = .{ .stretch, .start } });
    try testing.expectEqual(1, s.gs.it.stretch[0][r2]);
}
