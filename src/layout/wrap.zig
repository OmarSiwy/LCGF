//! Wrapping rows. A row whose `Flex.Style.wrap` is set breaks its in-flow children into lines once
//! their widths are resolved, then stacks the lines down its cross axis. The line a node sits on
//! is a column (`Flex.Columns.line`), and lines are rows of their own columns, so wrapping adds no
//! pass that depends on the data: the frame stays the fixed sequence of `layout.runFlex`.
//!
//!   resolveFlex(.x)    widths, as if every child were on one line
//!   wrap               forward   assign children to lines (this file)
//!   fitFlex(.y)        reverse   line height = tallest child; row height = sum of lines
//!   resolveFlex(.y)    forward   a stretching child fills its line, not the row
//!   placeFlex          forward   lines stacked down the row, children along their line
//!
//! Rows only: a column's main axis (y) is resolved after its cross axis (x), so the widths its
//! lines need are not known when they would have to be. Tier 0.

const std = @import("std");
const layout = @import("layout.zig");
const flex = @import("flex.zig");
const mem = @import("../core/mem.zig");
const simd = @import("../core/simd.zig");
const Tree = @import("../core/tree.zig").Tree;
const Texts = @import("../core/texts.zig").Texts;
const Flex = flex.Flex;

const b01 = simd.b2f;

/// Forward sweep, after `resolveFlex(.x)`: puts every in-flow child of a wrapping row on a line,
/// greedily, as CSS does: a child that would end past the row's inner width starts a new line,
/// unless it is the first on its line. Fills `line`, `head`, `nlines` and each line's
/// `line_main` and `line_count`, and clears the lines' `line_cross` and `line_cursor` for the
/// passes after it. Each row writes always; "does it wrap" and "does it break" are 0/1 factors.
pub fn wrap(t: *const Tree, fx: *const Flex) void {
    if (t.len == 0) return;
    const c = &t.c;
    const f = &fx.c;
    const sink = fx.sink();
    var lines: u32 = 0;
    f.line[0] = sink;
    f.head[0] = 0;
    openLines(c, f, 0, &lines);
    for (1..t.len) |i| {
        // As a child: stay on the parent's open line or break to a new one.
        const p = c.parent[i];
        const w = f.wrap[p] * c.main[0][p] * c.flow[i];
        const l = f.open[p];
        const extent = c.size[0][i] + f.margin_lo[0][i] + f.margin_hi[0][i];
        const inner = c.size[0][p] - c.pad_lo[0][p] - c.pad_hi[0][p];
        const empty = b01(f.line_count[l] == 0);
        const past = b01(f.line_main[l] + c.gap[p] + extent > inner);
        const brk = w * (1 - empty) * past;
        const bu: u32 = @intFromFloat(brk);
        clearLine(f, lines);
        const l2 = l +% bu *% (lines -% l);
        lines += bu;
        f.nlines[p] += brk;
        const first = @max(brk, empty);
        f.line_main[l2] += w * (extent + c.gap[p] * (1 - first));
        f.line_count[l2] += w;
        f.head[i] = w * first;
        const wu: u32 = @intFromFloat(w);
        f.line[i] = sink +% wu *% (l2 -% sink);
        f.open[p] = l2;
        // As a row, once its own line is known.
        openLines(c, f, i, &lines);
    }
}

/// A wrapping row opens its first line; every other node points its children at the sink.
inline fn openLines(c: *const Tree.Columns, f: *const Flex.Columns, i: usize, lines: *u32) void {
    const wraps: u32 = @intFromFloat(f.wrap[i] * c.main[0][i]);
    const sink: u32 = @intCast(f.line.len - 1);
    f.open[i] = sink +% wraps *% (lines.* -% sink);
    f.nlines[i] = @floatFromInt(wraps);
    clearLine(f, lines.*);
    lines.* += wraps;
}

/// Zeroes line `l`'s accumulators. Called for the next free line whether or not it is used, so
/// no line is ever read before it is written.
inline fn clearLine(f: *const Flex.Columns, l: u32) void {
    f.line_main[l] = 0;
    f.line_count[l] = 0;
    f.line_cross[l] = 0;
    f.line_cursor[l] = 0;
}

const testing = std.testing;

/// A tree, an empty text list and its Flex rows in one caller-owned buffer.
const Scene = struct {
    raw: [96 * 1024]u8 align(mem.column_align) = undefined,
    t: Tree = undefined,
    tx: Texts = undefined,
    fx: Flex = undefined,

    fn init(s: *Scene) *Tree {
        var carver: mem.Carver = .{ .buf = &s.raw };
        s.t = Tree.init(&carver, 24);
        s.tx = Texts.init(&carver, 1);
        s.fx = Flex.init(&carver, 24);
        return &s.t;
    }
    fn run(s: *Scene, w: f32, h: f32) void {
        s.t.seal(0);
        layout.runFlex(&s.t, &s.fx, &s.tx, .{ w, h });
    }
    /// A wrapping row of `n` px-sized boxes under `parent`.
    fn row(s: *Scene, parent: u32, style: *const @import("../core/types.zig").Style, boxes: []const [2]f32) u32 {
        const r = s.t.push(parent, .none, style);
        s.fx.set(r, &.{ .wrap = true });
        for (boxes) |b| _ = s.t.push(r, .none, &.{ .size = .{ .px(b[0]), .px(b[1]) } });
        s.t.seal(r);
        return r;
    }
    fn lineOf(s: *const Scene, first: u32, n: usize) []const u32 {
        return s.fx.c.line[first..][0..n];
    }
};

test "line columns: one row per node, a sink row past cap, and set writes the wrap inputs" {
    var raw: [64 * 1024]u8 align(mem.column_align) = undefined;
    var carver: mem.Carver = .{ .buf = &raw };
    var fx = Flex.init(&carver, 10);
    try testing.expectEqual(simd.rows(10), fx.c.line.len);
    try testing.expectEqual(simd.rows(10), fx.c.line_cross.len);
    // Lines are numbered below len <= cap, so the sink never collides with a real line.
    try testing.expect(fx.sink() >= 10);
    try testing.expectEqual(0, fx.c.wrap[3]);
    fx.set(3, &.{ .wrap = true, .lines = .end });
    try testing.expectEqual(1, fx.c.wrap[3]);
    try testing.expectEqual(1, fx.c.align_lines[3]);
    fx.set(3, &.{ .lines = .center });
    try testing.expectEqual(0, fx.c.wrap[3]);
    try testing.expectEqual(0.5, fx.c.align_lines[3]);
}

test "wrap: children go on the current line until the next would end past the inner width" {
    var s: Scene = .{};
    const t = s.init();
    const root = t.push(0, .none, &.{ .size = .{ .px(200), .px(200) } });
    // inner 100: 30 + 5 + 30 + 5 + 30 = 100 fits exactly; the fourth breaks.
    const r = s.row(root, &.{ .dir = .x, .size = .{ .px(110), .fit }, .pad = .{ 5, 0, 5, 0 }, .gap = 5 }, &.{ .{ 30, 10 }, .{ 30, 10 }, .{ 30, 10 }, .{ 30, 10 }, .{ 30, 10 } });
    s.run(200, 200);
    const f = &s.fx.c;
    try testing.expectEqualSlices(u32, &.{ 0, 0, 0, 1, 1 }, s.lineOf(r + 1, 5));
    try testing.expectEqualSlices(f32, &.{ 1, 0, 0, 1, 0 }, f.head[r + 1 ..][0..5]);
    try testing.expectEqual(2, f.nlines[r]);
    try testing.expectEqualSlices(f32, &.{ 100, 65 }, f.line_main[0..2]);
    try testing.expectEqualSlices(f32, &.{ 3, 2 }, f.line_count[0..2]);
    try testing.expectEqual(s.fx.sink(), f.line[root]);
    try testing.expectEqual(s.fx.sink(), f.line[r]);
}

test "wrap: a child wider than the row gets a line of its own; margins count" {
    var s: Scene = .{};
    const t = s.init();
    const root = t.push(0, .none, &.{ .size = .{ .px(200), .px(200) } });
    const r = s.row(root, &.{ .dir = .x, .size = .{ .px(50), .fit } }, &.{ .{ 20, 10 }, .{ 80, 10 }, .{ 20, 10 }, .{ 20, 10 } });
    s.fx.set(r + 4, &.{ .margin = .{ 6, 0, 5, 0 } });
    s.run(200, 200);
    // 20 | 80 (too wide, alone) | 20 + (6 + 20 + 5) = 51 > 50, so the last breaks too.
    try testing.expectEqualSlices(u32, &.{ 0, 1, 2, 3 }, s.lineOf(r + 1, 4));
    try testing.expectEqual(4, s.fx.c.nlines[r]);
    try testing.expectEqualSlices(f32, &.{ 20, 80, 20, 31 }, s.fx.c.line_main[0..4]);
}

test "wrap: floating children, rows that do not wrap and columns stay off the lines" {
    var s: Scene = .{};
    const t = s.init();
    const root = t.push(0, .none, &.{ .size = .{ .px(200), .px(200) } });
    const r = s.row(root, &.{ .dir = .x, .size = .{ .px(50), .fit } }, &.{ .{ 40, 10 }, .{ 40, 10 } });
    t.c.flow[r + 1] = 0; // floats: takes no part, so the second box starts the first line
    const plain = t.push(root, .none, &.{ .dir = .x, .size = .{ .px(50), .fit } });
    _ = t.push(plain, .none, &.{ .size = .{ .px(40), .px(10) } });
    _ = t.push(plain, .none, &.{ .size = .{ .px(40), .px(10) } });
    t.seal(plain);
    const col = t.push(root, .none, &.{ .size = .{ .px(50), .fit } });
    s.fx.set(col, &.{ .wrap = true });
    _ = t.push(col, .none, &.{ .size = .{ .px(40), .px(10) } });
    t.seal(col);
    s.run(200, 200);
    const sink = s.fx.sink();
    try testing.expectEqualSlices(u32, &.{ sink, 0 }, s.lineOf(r + 1, 2));
    try testing.expectEqual(1, s.fx.c.nlines[r]);
    try testing.expectEqualSlices(u32, &.{ sink, sink }, s.lineOf(plain + 1, 2));
    try testing.expectEqual(sink, s.fx.c.line[col + 1]);
    try testing.expectEqual(0, s.fx.c.nlines[col]);
}

test "wrap: nested wrapping rows number their lines in row order and do not mix" {
    var s: Scene = .{};
    const t = s.init();
    const outer = t.push(0, .none, &.{ .dir = .x, .size = .{ .px(100), .px(200) } });
    s.fx.set(outer, &.{ .wrap = true });
    _ = t.push(outer, .none, &.{ .size = .{ .px(60), .px(10) } });
    const inner = s.row(outer, &.{ .dir = .x, .size = .{ .px(60), .fit } }, &.{ .{ 40, 10 }, .{ 40, 10 } });
    _ = t.push(outer, .none, &.{ .size = .{ .px(30), .px(10) } });
    s.run(100, 200);
    const f = &s.fx.c;
    // outer opens line 0; its second child (inner) breaks to line 1, and inner opens line 2,
    // whose second box breaks to 3; outer's last child fits after inner, on line 1.
    try testing.expectEqualSlices(u32, &.{ 0, 1 }, &.{ f.line[outer + 1], f.line[inner] });
    try testing.expectEqualSlices(u32, &.{ 2, 3 }, s.lineOf(inner + 1, 2));
    try testing.expectEqual(1, f.line[inner + 3]);
    try testing.expectEqual(2, f.nlines[outer]);
    try testing.expectEqual(2, f.nlines[inner]);
}

test "runFlex: one fixed sequence of passes, whatever the lines" {
    var a: Scene = .{};
    var b: Scene = .{};
    inline for (.{ &a, &b }) |s| {
        const t = s.init();
        const root = t.push(0, .none, &.{ .size = .{ .px(200), .px(200) } });
        _ = s.row(root, &.{ .dir = .x, .size = .{ .px(70), .fit }, .gap = 2 }, &.{ .{ 30, 10 }, .{ 30, 12 }, .{ 30, 14 }, .{ 50, 8 } });
        t.seal(0);
    }
    layout.runFlex(&a.t, &a.fx, &a.tx, .{ 200, 200 });
    // The same frame spelled out: eleven tier-0 calls, none repeated, none conditional.
    layout.prepare(&b.t);
    layout.applyText(&b.t, &b.tx, .x);
    layout.fitFlex(&b.t, &b.fx, .x);
    layout.resolveFlex(&b.t, &b.fx, .x, 200);
    wrap(&b.t, &b.fx);
    layout.textAvail(&b.t, &b.tx);
    layout.applyText(&b.t, &b.tx, .y);
    layout.fitFlex(&b.t, &b.fx, .y);
    layout.resolveFlex(&b.t, &b.fx, .y, 200);
    layout.placeFlex(&b.t, &b.fx);
    layout.finalize(&b.t);
    inline for (0..4) |k| try testing.expectEqualSlices(f32, b.t.c.rect[k][0..b.t.len], a.t.c.rect[k][0..a.t.len]);
    try testing.expectEqualSlices(u32, b.fx.c.line[0..b.t.len], a.fx.c.line[0..a.t.len]);
}
