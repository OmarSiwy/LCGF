//! Optional named grid authoring, resolved once into existing bounded numeric grid rows.
//! Names are borrowed strings, not interned handles. Repeated line names have explicit
//! occurrences; rectangular area templates validate before any grid item is appended.

const std = @import("std");
const grid = @import("grid.zig");

pub const Error = error{ NoSpace, MissingName, InvalidLine, InvalidArea, InvalidGrid };
pub const Line = struct { name: []const u8, index: u32 };
pub const Named = struct {
    name: []const u8,
    /// One-based occurrence; negative values count from the final matching named line.
    occurrence: i32 = 1,
};
pub const Reference = union(enum) {
    /// Numeric grid line, zero-based; negative values count from the terminal line (-1).
    index: i32,
    named: Named,
};
pub const Cell = struct { first: [2]u32, span: [2]u32 };
pub const Area = struct { name: []const u8, cell: Cell };
pub const Names = struct { lines: [2][]const Line = .{ &.{}, &.{} }, areas: []const Area = &.{} };

pub fn line(names: []const Line, reference: Reference, track_count: u32) Error!u32 {
    return switch (reference) {
        .index => |index| blk: {
            const at: i64 = if (index < 0) @as(i64, track_count) + 1 + index else index;
            if (at < 0 or at > track_count) return error.InvalidLine;
            break :blk @intCast(at);
        },
        .named => |name| blk: {
            if (name.occurrence == 0 or name.name.len == 0) return error.InvalidLine;
            var count: i64 = 0;
            for (names) |entry| if (std.mem.eql(u8, entry.name, name.name)) {
                if (entry.index > track_count) return error.InvalidLine;
                count += 1;
            };
            const wanted = if (name.occurrence < 0) count + 1 + name.occurrence else name.occurrence;
            if (wanted <= 0 or wanted > count) return error.MissingName;
            count = 0;
            for (names) |entry| if (std.mem.eql(u8, entry.name, name.name)) {
                count += 1;
                if (count == wanted) break :blk entry.index;
            };
            unreachable;
        },
    };
}

pub fn between(names: Names, counts: [2]u32, first: [2]Reference, end: [2]Reference) Error!Cell {
    var result: Cell = undefined;
    inline for (0..2) |axis| {
        result.first[axis] = try line(names.lines[axis], first[axis], counts[axis]);
        const stop = try line(names.lines[axis], end[axis], counts[axis]);
        if (stop <= result.first[axis]) return error.InvalidArea;
        result.span[axis] = stop - result.first[axis];
    }
    return result;
}

pub fn area(names: Names, name: []const u8) Error!Cell {
    for (names.areas) |entry| if (std.mem.eql(u8, entry.name, name)) return entry.cell;
    return error.MissingName;
}

/// A row-major template with one borrowed name per cell. Empty strings and "." are holes.
/// Each area's occurrences must fill exactly one rectangle; disjoint/L-shaped areas fail.
/// No CSS tokenizer or implicit track growth is hidden in this pass.
pub fn template(cells: []const []const u8, columns: u32, out: []Area) Error![]const Area {
    if (columns == 0 or cells.len % columns != 0 or cells.len / columns > std.math.maxInt(u32)) return error.InvalidArea;
    var n: usize = 0;
    for (cells, 0..) |name, index| {
        if (name.len == 0 or std.mem.eql(u8, name, ".")) continue;
        var found: usize = 0;
        while (found < n and !std.mem.eql(u8, out[found].name, name)) found += 1;
        const x: u32 = @intCast(index % columns);
        const y: u32 = @intCast(index / columns);
        if (found == n) {
            if (n == out.len) return error.NoSpace;
            out[n] = .{ .name = name, .cell = .{ .first = .{ x, y }, .span = .{ 1, 1 } } };
            n += 1;
        } else {
            const c = &out[found].cell;
            const right = @max(c.first[0] + c.span[0], x + 1);
            const bottom = @max(c.first[1] + c.span[1], y + 1);
            c.first = .{ @min(c.first[0], x), @min(c.first[1], y) };
            c.span = .{ right - c.first[0], bottom - c.first[1] };
        }
    }
    for (out[0..n]) |entry| {
        const c = entry.cell;
        for (c.first[1]..c.first[1] + c.span[1]) |y| for (c.first[0]..c.first[0] + c.span[0]) |x| {
            if (!std.mem.eql(u8, cells[y * columns + x], entry.name)) return error.InvalidArea;
        };
    }
    return out[0..n];
}

/// Applies a resolved named placement to real Grids item rows. Validation happens before
/// append, so a miss/invalid area does not silently clamp to an unrelated numeric track.
pub fn item(grids: *grid.Grids, grid_index: u32, node: u32, cell: Cell) Error!u32 {
    if (grid_index >= grids.len) return error.InvalidGrid;
    inline for (0..2) |axis| {
        const count = grids.g.count[axis][grid_index];
        if (cell.first[axis] >= count or cell.span[axis] == 0 or cell.span[axis] > count - cell.first[axis]) return error.InvalidArea;
    }
    if (grids.items_len >= grids.cap.items) return error.NoSpace;
    const row = grids.item(grid_index, node, cell.first);
    grids.span(row, cell.span);
    return row;
}

test "named lines and rectangular areas resolve to actual grid node geometry" {
    const mem = @import("../core/mem.zig");
    const Tree = @import("../core/tree.zig").Tree;
    const Texts = @import("../core/texts.zig").Texts;
    var storage: [32768]u8 align(mem.column_align) = undefined;
    var carver: mem.Carver = .{ .buf = &storage };
    var tree: Tree = .init(&carver, 8);
    var texts: Texts = .init(&carver, 1);
    var grids: grid.Grids = .init(&carver, .{ .grids = 1, .tracks = 5, .items = 3 });
    const parent = tree.push(0, .none, &.{ .size = .{ .px(120), .px(70) } });
    const header = tree.push(parent, .none, &.{ .float = true });
    tree.seal(header);
    const main = tree.push(parent, .none, &.{ .float = true });
    tree.seal(main);
    const footer = tree.push(parent, .none, &.{ .float = true });
    tree.seal(footer);
    tree.seal(parent);
    const k = grids.grid(parent, &.{ .px(30), .px(80) }, &.{ .px(15), .px(25), .px(20) });
    grids.gaps(k, .{ 10, 5 });
    var areas: [3]Area = undefined;
    const resolved = try template(&.{ "header", "header", "sidebar", "main", ".", "main" }, 2, &areas);
    const names: Names = .{ .areas = resolved, .lines = .{ &.{ .{ .name = "content", .index = 1 }, .{ .name = "content", .index = 2 } }, &.{.{ .name = "footer", .index = 2 }} } };
    _ = try item(&grids, k, header, try area(names, "header"));
    _ = try item(&grids, k, main, try area(names, "main"));
    const footer_cell = try between(names, .{ 2, 3 }, .{ .{ .index = 0 }, .{ .named = .{ .name = "footer" } } }, .{ .{ .named = .{ .name = "content", .occurrence = 1 } }, .{ .index = -1 } });
    _ = try item(&grids, k, footer, footer_cell);
    grid.run(&tree, &texts, &grids, .{ 120, 70 });
    try std.testing.expectEqual(@as(f32, 120), tree.c.size[0][header]);
    try std.testing.expectEqual(@as(f32, 40), tree.c.pos[0][main]);
    try std.testing.expectEqual(@as(f32, 20), tree.c.pos[1][main]);
    try std.testing.expectEqual(@as(f32, 50), tree.c.size[1][main]);
    try std.testing.expectEqual(@as(f32, 50), tree.c.pos[1][footer]);
    try std.testing.expectEqual(@as(u32, 2), try line(names.lines[0], .{ .named = .{ .name = "content", .occurrence = -1 } }, 2));
    try std.testing.expectError(error.InvalidArea, template(&.{ "bad", ".", "bad", "bad" }, 2, &areas));
    try std.testing.expectError(error.MissingName, area(names, "missing"));
}
