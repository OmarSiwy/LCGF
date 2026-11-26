//! Optional document/table geometry over caller-measured lines and cells. Width-dependent
//! shaping happens before these passes. Outputs are ordinary placements or the existing
//! text Lines columns; pagination never invokes the application or allocates storage.

const std = @import("std");
const special = @import("special.zig");
const Rect = @import("../core/types.zig").Rect;
const text_lines = @import("../text/layout/lines.zig");
pub const Error = error{ NoSpace, InvalidGeometry, InvalidSpan };

pub const Cell = struct { column: u32, row: u32, columns: u32 = 1, rows: u32 = 1, size: [2]f32 };
pub const Track = struct { min: f32 = 0, max: f32 = std.math.floatMax(f32), grow: f32 = 0 };

/// Auto table track contributions, shortest spans first. Spanning excess is distributed
/// only to tracks below their maximum, with bounded freezing. Remaining available width
/// goes to explicit grow weights. Cell content is measured by the caller at its final width
/// before a second row-axis invocation when wrapping changes row heights.
pub fn tableAxis(cells: []const Cell, axis: u1, tracks: []const Track, available: f32, gap: f32, sizes: []f32, starts: []f32) Error!f32 {
    if (sizes.len < tracks.len or starts.len < tracks.len) return error.NoSpace;
    if (!std.math.isFinite(available) or !std.math.isFinite(gap) or available < 0 or gap < 0) return error.InvalidGeometry;
    for (tracks, sizes[0..tracks.len]) |track, *value| {
        if (!std.math.isFinite(track.min) or !std.math.isFinite(track.max) or !std.math.isFinite(track.grow) or track.min < 0 or track.max < track.min or track.grow < 0) return error.InvalidGeometry;
        value.* = track.min;
    }
    for (cells) |cell| {
        const first = if (axis == 0) cell.column else cell.row;
        const span = if (axis == 0) cell.columns else cell.rows;
        if (span == 0 or first >= tracks.len or span > tracks.len - first) return error.InvalidSpan;
        if (!std.math.isFinite(cell.size[axis]) or cell.size[axis] < 0) return error.InvalidGeometry;
    }
    for (1..tracks.len + 1) |span| for (cells) |cell| {
        const n = if (axis == 0) cell.columns else cell.rows;
        if (n != span) continue;
        const first = if (axis == 0) cell.column else cell.row;
        var current = gap * @as(f32, @floatFromInt(n - 1));
        for (sizes[first..][0..n]) |value| current += value;
        grow(tracks[first..][0..n], sizes[first..][0..n], @max(cell.size[axis] - current, 0), false);
    };
    var occupied = gap * @as(f32, @floatFromInt(tracks.len -| 1));
    for (sizes[0..tracks.len]) |value| occupied += value;
    grow(tracks, sizes[0..tracks.len], @max(available - occupied, 0), true);
    var at: f32 = 0;
    for (sizes[0..tracks.len], starts[0..tracks.len]) |value, *start| {
        start.* = at;
        at += value + gap;
    }
    return @max(at - gap, 0);
}

fn grow(tracks: []const Track, sizes: []f32, amount: f32, weighted: bool) void {
    var remaining = amount;
    for (0..tracks.len) |_| {
        var weight: f32 = 0;
        for (tracks, sizes) |track, size| if (size < track.max) {
            weight += if (weighted) track.grow else 1;
        };
        if (weight == 0 or remaining <= 0.0001) break;
        var spent: f32 = 0;
        for (tracks, sizes) |track, *size| {
            const extra = @min(track.max - size.*, remaining * (if (weighted) track.grow else 1) / weight);
            size.* += extra;
            spent += extra;
        }
        remaining -= spent;
    }
}

pub fn table(cells: []const Cell, column_sizes: []const f32, column_starts: []const f32, row_sizes: []const f32, row_starts: []const f32, origin: [2]f32, out: []special.Placement) Error!void {
    if (out.len < cells.len or column_sizes.len != column_starts.len or row_sizes.len != row_starts.len) return error.NoSpace;
    for (cells, out[0..cells.len]) |cell, *p| {
        if (cell.columns == 0 or cell.rows == 0 or cell.column >= column_sizes.len or cell.row >= row_sizes.len or cell.columns > column_sizes.len - cell.column or cell.rows > row_sizes.len - cell.row) return error.InvalidSpan;
        const x = cell.column + cell.columns - 1;
        const y = cell.row + cell.rows - 1;
        p.rect = .{ .x0 = origin[0] + column_starts[cell.column], .y0 = origin[1] + row_starts[cell.row], .x1 = origin[0] + column_starts[x] + column_sizes[x], .y1 = origin[1] + row_starts[y] + row_sizes[y] };
    }
}

pub const Break = enum { auto, column, page, left, right };
pub const Block = struct {
    heights: []const f32,
    before: f32 = 0,
    after: f32 = 0,
    break_before: Break = .auto,
    break_after: Break = .auto,
    keep_next: bool = false,
    avoid_split: bool = false,
    orphans: u32 = 2,
    widows: u32 = 2,
};
pub const Page = struct { size: [2]f32, margin: [4]f32 = @splat(0), columns: u32 = 1, column_gap: f32 = 0, page_gap: f32 = 0, discard_leading_space: bool = true };
pub const Fragment = struct { block: u32, first: u32, count: u32, page: u32, column: u32, rect: Rect };
pub const Result = struct { fragments: u32, pages: u32, relaxed_constraints: bool };

fn total(heights: []const f32) f32 {
    var sum: f32 = 0;
    for (heights) |height| sum += height;
    return sum;
}

fn nextSlot(slot: *u32, cursor: *f32, columns: u32, mode: Break) void {
    switch (mode) {
        .auto => return,
        .column => slot.* += 1,
        .page, .left, .right => {
            slot.* = (slot.* / columns + 1) * columns;
            const parity: u32 = if (mode == .left) 1 else 0;
            if ((mode == .left or mode == .right) and (slot.* / columns) % 2 != parity) slot.* += columns;
        },
    }
    cursor.* = 0;
}

/// Splits only at already-shaped line boundaries, honoring widow/orphan, keep-next and
/// page/column/parity breaks where the constraints fit one column. Oversized indivisible
/// lines still make progress; the explicit relaxed flag reports an impossible constraint.
pub fn paginate(blocks: []const Block, page: Page, out: []Fragment) Error!Result {
    for (page.size ++ page.margin ++ [2]f32{ page.column_gap, page.page_gap }) |v| if (!std.math.isFinite(v) or v < 0) return error.InvalidGeometry;
    if (page.columns == 0) return error.InvalidGeometry;
    const height = page.size[1] - page.margin[1] - page.margin[3];
    const width = (page.size[0] - page.margin[0] - page.margin[2] - page.column_gap * @as(f32, @floatFromInt(page.columns - 1))) / @as(f32, @floatFromInt(page.columns));
    if (height <= 0 or width <= 0) return error.InvalidGeometry;
    var result: Result = .{ .fragments = 0, .pages = 0, .relaxed_constraints = false };
    var slot: u32 = 0;
    var cursor: f32 = 0;
    for (blocks, 0..) |block, bi| {
        for (block.heights) |h| if (!std.math.isFinite(h) or h <= 0) return error.InvalidGeometry;
        if (!std.math.isFinite(block.before) or !std.math.isFinite(block.after) or block.before < 0 or block.after < 0) return error.InvalidGeometry;
        if (block.heights.len == 0) continue;
        if (result.fragments > 0) nextSlot(&slot, &cursor, page.columns, block.break_before);
        var before = if (cursor == 0 and page.discard_leading_space) @as(f32, 0) else block.before;
        const own_height = total(block.heights);
        var kept_height = own_height;
        if (block.keep_next and bi + 1 < blocks.len) {
            const next = blocks[bi + 1];
            kept_height += block.after + next.before + total(next.heights[0..@min(next.heights.len, @max(next.orphans, 1))]);
        }
        if (cursor > 0 and ((block.avoid_split and own_height <= height and cursor + before + own_height > height) or (block.keep_next and kept_height <= height and cursor + before + kept_height > height))) {
            nextSlot(&slot, &cursor, page.columns, .column);
            before = if (page.discard_leading_space) 0 else block.before;
        }
        cursor += before;
        var first: u32 = 0;
        while (first < block.heights.len) {
            var end = first;
            var taken: f32 = 0;
            while (end < block.heights.len and cursor + taken + block.heights[end] <= height + 0.0001) : (end += 1) taken += block.heights[end];
            const remaining: u32 = @intCast(block.heights.len - first);
            var count = end - first;
            if (count < remaining) {
                if (count < @max(block.orphans, 1) and cursor > 0) {
                    nextSlot(&slot, &cursor, page.columns, .column);
                    continue;
                }
                if (remaining - count < block.widows) {
                    const candidate = remaining -| block.widows;
                    if (candidate >= @max(block.orphans, 1)) {
                        count = candidate;
                        taken = total(block.heights[first..][0..count]);
                    } else if (cursor > 0) {
                        nextSlot(&slot, &cursor, page.columns, .column);
                        continue;
                    } else result.relaxed_constraints = true;
                }
                if (count == 0) {
                    count = 1;
                    taken = block.heights[first];
                    result.relaxed_constraints = true;
                }
            }
            if (result.fragments >= out.len) return error.NoSpace;
            const p = slot / page.columns;
            const column = slot % page.columns;
            const x = page.margin[0] + @as(f32, @floatFromInt(column)) * (width + page.column_gap);
            const y = @as(f32, @floatFromInt(p)) * (page.size[1] + page.page_gap) + page.margin[1] + cursor;
            out[result.fragments] = .{ .block = @intCast(bi), .first = first, .count = count, .page = p, .column = column, .rect = .{ .x0 = x, .y0 = y, .x1 = x + width, .y1 = y + taken } };
            result.fragments += 1;
            result.pages = @max(result.pages, p + 1);
            cursor += taken;
            first += count;
            if (first < block.heights.len) nextSlot(&slot, &cursor, page.columns, .column);
        }
        cursor += block.after;
        nextSlot(&slot, &cursor, page.columns, block.break_after);
    }
    return result;
}

/// Applies one paragraph's document fragments to its existing positioned Lines. Glyph
/// emission, bidi selections and carets now use exactly the same page/column coordinates.
/// Call once after ordinary line placement/reordering, with TextRun.rect at document origin.
pub fn placeLines(lines: *text_lines.Lines, block: u32, fragments: []const Fragment) error{InvalidSpan}!void {
    for (fragments) |fragment| {
        if (fragment.block != block) continue;
        if (fragment.first > lines.len or fragment.count > lines.len - fragment.first) return error.InvalidSpan;
        var y = fragment.rect.y0;
        for (fragment.first..fragment.first + fragment.count) |i| {
            lines.baseline[i] = y + lines.baseline[i] - lines.top[i];
            lines.top[i] = y;
            lines.x[i] += fragment.rect.x0;
            y += lines.height[i];
        }
    }
}

/// Minimum balanced column height for whole measured blocks, with a fixed 32-step solve.
/// This is an explicit measurement result; paginate can then use it as the content height.
pub fn balancedHeight(heights: []const f32, columns: u32, gap: f32) Error!f32 {
    if (columns == 0 or !std.math.isFinite(gap) or gap < 0) return error.InvalidGeometry;
    var lo: f32 = 0;
    var hi: f32 = gap * @as(f32, @floatFromInt(heights.len -| 1));
    for (heights) |h| {
        if (!std.math.isFinite(h) or h < 0) return error.InvalidGeometry;
        lo = @max(lo, h);
        hi += h;
    }
    for (0..32) |_| {
        const mid = lo + (hi - lo) * 0.5;
        var n: u32 = 1;
        var used: f32 = 0;
        for (heights) |h| {
            if (used > 0 and used + gap + h > mid) {
                n += 1;
                used = 0;
            }
            used += (if (used > 0) gap else 0) + h;
        }
        if (n > columns) lo = mid else hi = mid;
    }
    return hi;
}

test "table spans and page fragments drive the real placement and glyph-line columns" {
    const cells: [3]Cell = .{ .{ .column = 0, .row = 0, .size = .{ 60, 10 } }, .{ .column = 1, .row = 0, .size = .{ 20, 20 } }, .{ .column = 0, .row = 1, .columns = 2, .size = .{ 120, 15 } } };
    var widths: [2]f32 = undefined;
    var xs: [2]f32 = undefined;
    var heights: [2]f32 = undefined;
    var ys: [2]f32 = undefined;
    _ = try tableAxis(&cells, 0, &.{ .{}, .{} }, 0, 10, &widths, &xs);
    _ = try tableAxis(&cells, 1, &.{ .{}, .{} }, 0, 2, &heights, &ys);
    var placements: [3]special.Placement = undefined;
    try table(&cells, &widths, &xs, &heights, &ys, .{ 0, 0 }, &placements);
    try std.testing.expectEqual(@as(f32, 120), placements[2].rect.x1);
    try std.testing.expectEqual(@as(f32, 22), placements[2].rect.y0);
    const lowered = special.style(placements[2], .{}, .{ 0, 0 });
    try std.testing.expectEqual(@as(f32, 120), lowered.size[0].v);

    var p: @import("../text/layout/golden.zig").Para = .{};
    p.fixed("a\nb\nc\nd\ne", 10);
    try text_lines.breakLines(&p.g, "a\nb\nc\nd\ne", 30, &p.l);
    text_lines.place(&p.l, &p.g, "a\nb\nc\nd\ne", &.{.{ .ascent = 8, .descent = 2 }}, .{});
    var fragments: [8]Fragment = undefined;
    const result = try paginate(&.{.{ .heights = p.l.height[0..p.l.len] }}, .{ .size = .{ 100, 40 }, .margin = .{ 0, 5, 0, 5 }, .columns = 2, .column_gap = 10 }, &fragments);
    try std.testing.expectEqual(2, result.fragments);
    try std.testing.expectEqual(3, fragments[0].count);
    try std.testing.expectEqual(2, fragments[1].count);
    try placeLines(&p.l, 0, fragments[0..result.fragments]);
    try std.testing.expectEqual(@as(f32, 55), p.l.x[3]);
    try std.testing.expectEqual(@as(f32, 5), p.l.top[3]);
    try std.testing.expectEqual(@as(f32, 13), p.l.baseline[3]);
    try std.testing.expectApproxEqAbs(@as(f32, 30), try balancedHeight(&.{ 10, 20, 10, 20 }, 2, 0), 0.001);
}
