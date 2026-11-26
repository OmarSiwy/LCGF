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
    fx.spaceShares(t, 0);
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
        fx.spaceShares(t, i);
        openLines(c, f, i, &lines);
    }
}

/// A wrapping row opens its first line; every other node points its children at the sink.
inline fn openLines(c: *const Tree.Columns, f: *const Flex.Columns, i: usize, lines: *u32) void {
    const opens: u32 = @intFromFloat(f.wrap[i] * c.main[0][i]);
    const sink: u32 = @intCast(f.line.len - 1);
    f.open[i] = sink +% opens *% (lines.* -% sink);
    f.nlines[i] = @floatFromInt(opens);
    clearLine(f, lines.*);
    lines.* += opens;
}

/// Zeroes line `l`'s accumulators. Called for the next free line whether or not it is used, so
/// no line is ever read before it is written.
inline fn clearLine(f: *const Flex.Columns, l: u32) void {
    f.line_main[l] = 0;
    f.line_count[l] = 0;
    f.line_cross[l] = 0;
    f.line_cursor[l] = 0;
}

/// 1.0 when node `p` is a wrapping row, in flex form.
inline fn wraps(t: *const Tree, fx: *const Flex, p: usize) f32 {
    return fx.c.wrap[p] * t.c.main[0][p];
}

/// fitFlex: the gaps between a wrapping row's lines, on y. Zero for every other node and axis.
pub inline fn linesGap(t: *const Tree, fx: *const Flex, a: u1, i: usize) f32 {
    const on_y: f32 = @floatFromInt(a);
    return on_y * wraps(t, fx, i) * @max(fx.c.nlines[i] - 1, 0) * t.c.gap[i];
}

/// fitFlex: on y, child `i` of a wrapping row raises its line's cross size to its own extent,
/// and the line joins the row's sum when its first child (the last one the reverse sweep sees)
/// folds in. Otherwise `folded`, the plain fold.
pub inline fn foldLine(t: *const Tree, fx: *const Flex, a: u1, i: usize, p: usize, contrib: f32, folded: f32) f32 {
    const f = &fx.c;
    const l = f.line[i];
    f.line_cross[l] = @max(f.line_cross[l], contrib);
    const stacked = t.c.fit[a][p] + f.head[i] * f.line_cross[l];
    const on_y: f32 = @floatFromInt(a);
    return folded + on_y * wraps(t, fx, p) * (stacked - folded);
}

/// resolveFlex: how much more than the parent's inner size a stretching child of a wrapping
/// row gets on y: its line's cross size instead of the whole row. Zero otherwise.
pub inline fn lineCross(t: *const Tree, fx: *const Flex, a: u1, i: usize, p: usize, inner: f32) f32 {
    const on_y: f32 = @floatFromInt(a);
    return on_y * wraps(t, fx, p) * (fx.c.line_cross[fx.c.line[i]] + fx.c.line_extra[p] - inner);
}

/// placeFlex, before child `i` is placed: the first child of a line sets the line's offset
/// down the row: the row's cursor (which for a wrapping row runs across it) plus the share of
/// the row's spare height that `Style.lines` (or `Style.line_space`) puts before its lines.
pub inline fn openLine(t: *const Tree, fx: *const Flex, i: usize, p: usize) void {
    const c = &t.c;
    const f = &fx.c;
    const l = f.line[i];
    const h = f.head[i];
    f.line_off[l] += h * (c.cursor[p] + f.line_lead[p] - f.line_off[l]);
}

/// placeFlex: child `i`'s offset inside a wrapping row's content box. Along x: its line's
/// cursor after the line's own lead (the row's `Style.main` applied to each line's spare
/// width). Down y: its line's offset plus its cross alignment (`cross`, the row's or its own)
/// inside the line's height. `inner` is the row's inner size on axis `a`. Otherwise `in_flow`.
pub inline fn inLine(t: *const Tree, fx: *const Flex, comptime a: u1, i: usize, p: usize, inner: f32, cross: f32, in_flow: f32) f32 {
    const c = &t.c;
    const f = &fx.c;
    const l = f.line[i];
    const at = if (a == 0)
        @max(inner - f.line_main[l], 0) * c.align_main[p] + f.line_cursor[l]
    else
        f.line_off[l] + @max(f.line_cross[l] + f.line_extra[p] - c.size[1][i] - fx.margin(1, i), 0) * cross;
    return in_flow + wraps(t, fx, p) * (at + f.margin_lo[a][i] - in_flow);
}

/// placeFlex, after child `i` is placed: it moves its line's cursor along x, and a line's first
/// child moves the row's cursor down past the line. Returns the row's cursor step.
pub inline fn advance(t: *const Tree, fx: *const Flex, i: usize, p: usize, plain: f32) f32 {
    const f = &fx.c;
    const l = f.line[i];
    const w = wraps(t, fx, p);
    f.line_cursor[l] += w * t.c.flow[i] * (t.c.size[0][i] + fx.margin(0, i) + t.c.gap[p]);
    const down = f.head[i] * (f.line_cross[l] + t.c.gap[p] + f.line_extra[p] + f.line_step[p]);
    return plain + w * (down - plain);
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

test "stack: a line is as tall as its tallest child; the row sums its lines and their gaps" {
    var s: Scene = .{};
    const t = s.init();
    const root = t.push(0, .none, &.{ .size = .{ .px(200), .px(200) } });
    const r = s.row(root, &.{ .dir = .x, .size = .{ .px(70), .fit }, .gap = 4, .pad = .{ 0, 3, 0, 2 } }, &.{ .{ 30, 10 }, .{ 30, 20 }, .{ 30, 15 }, .{ 30, 5 }, .{ 30, 8 } });
    s.run(200, 200);
    const f = &s.fx.c;
    // Lines: 30 + 4 + 30 = 64 fits 70, so two per line: heights 20, 15, 8.
    try testing.expectEqualSlices(f32, &.{ 20, 15, 8 }, f.line_cross[0..3]);
    try testing.expectEqual(3, f.nlines[r]);
    // 20 + 15 + 8 + two 4 px gaps + 3 + 2 padding.
    try testing.expectEqual(20 + 15 + 8 + 2 * 4 + 5, s.t.c.size[1][r]);
}

test "stack: lines go down the row, children along each line from its start" {
    var s: Scene = .{};
    const t = s.init();
    const root = t.push(0, .none, &.{ .size = .{ .px(200), .px(200) }, .pad = @splat(10) });
    const r = s.row(root, &.{ .dir = .x, .size = .{ .px(70), .fit }, .gap = 4, .pad = .{ 1, 3, 0, 0 } }, &.{ .{ 30, 10 }, .{ 30, 20 }, .{ 30, 15 }, .{ 30, 5 }, .{ 30, 8 } });
    s.run(200, 200);
    const x = t.c.pos[0][r + 1 ..][0..5];
    const y = t.c.pos[1][r + 1 ..][0..5];
    try testing.expectEqualSlices(f32, &.{ 11, 45, 11, 45, 11 }, x);
    // Row content starts at 10 + 3; lines at +0, +20 + 4, +24 + 15 + 4.
    try testing.expectEqualSlices(f32, &.{ 13, 13, 37, 37, 56 }, y);
}

test "stack: a stretching child fills its line, not the row; children do not shrink along it" {
    var s: Scene = .{};
    const t = s.init();
    const root = t.push(0, .none, &.{ .size = .{ .px(200), .px(200) } });
    const r = t.push(root, .none, &.{ .dir = .x, .size = .{ .px(60), .px(100) } });
    s.fx.set(r, &.{ .wrap = true });
    const a = t.push(r, .none, &.{ .size = .{ .px(40), .px(30) } });
    const b = t.push(r, .none, &.{ .size = .{ .px(10), .fill } });
    const c = t.push(r, .none, &.{ .shrink = true });
    _ = t.push(c, .none, &.{ .size = .{ .px(50), .px(10) } });
    t.seal(c);
    t.seal(r);
    s.run(200, 200);
    // Line 0 holds a and b (40 + 10); c (50) breaks to line 1 at its natural width.
    try testing.expectEqual(30, s.t.c.size[1][b]);
    try testing.expectEqual(50, s.t.c.size[0][c]);
    try testing.expectEqual(30, s.t.c.pos[1][c]);
    try testing.expectEqual(0, s.t.c.pos[1][a]);
}

test "align: the row's main alignment applies to each line's own spare width" {
    var s: Scene = .{};
    const t = s.init();
    const root = t.push(0, .none, &.{ .size = .{ .px(200), .px(200) } });
    const r = s.row(root, &.{ .dir = .x, .size = .{ .px(100), .fit }, .gap = 10, .main = .end }, &.{ .{ 40, 10 }, .{ 40, 10 }, .{ 30, 10 } });
    s.run(200, 200);
    // Line 0: 40 + 10 + 40 = 90, 10 spare; line 1: 30, 70 spare.
    try testing.expectEqualSlices(f32, &.{ 10, 60, 70 }, t.c.pos[0][r + 1 ..][0..3]);
    t.c.align_main[r] = 0.5;
    s.run(200, 200);
    try testing.expectEqualSlices(f32, &.{ 5, 55, 35 }, t.c.pos[0][r + 1 ..][0..3]);
}

test "align: children sit inside their line by the row's cross alignment or their own" {
    var s: Scene = .{};
    const t = s.init();
    const root = t.push(0, .none, &.{ .size = .{ .px(200), .px(200) } });
    const r = s.row(root, &.{ .dir = .x, .size = .{ .px(100), .fit }, .cross = .end }, &.{ .{ 30, 20 }, .{ 30, 10 }, .{ 30, 4 }, .{ 30, 6 } });
    s.fx.set(r + 3, &.{ .cross = .center });
    s.run(200, 200);
    // Line 0 is 20 high (the 30-wide fourth box breaks): ends at 20, centre at 8.
    try testing.expectEqualSlices(f32, &.{ 0, 10, 8 }, t.c.pos[1][r + 1 ..][0..3]);
    try testing.expectEqual(20, t.c.pos[1][r + 4]);
}

test "align: lines sit across the row by Style.lines when it is taller than they are" {
    var s: Scene = .{};
    const t = s.init();
    const root = t.push(0, .none, &.{ .size = .{ .px(200), .px(200) } });
    const r = t.push(root, .none, &.{ .dir = .x, .size = .{ .px(50), .px(100) }, .gap = 5 });
    s.fx.set(r, &.{ .wrap = true, .lines = .end });
    _ = t.push(r, .none, &.{ .size = .{ .px(40), .px(20) } });
    _ = t.push(r, .none, &.{ .size = .{ .px(40), .px(30) } });
    t.seal(r);
    s.run(200, 200);
    // 20 + 5 + 30 = 55 of 100: 45 before the first line.
    try testing.expectEqualSlices(f32, &.{ 45, 70 }, t.c.pos[1][r + 1 ..][0..2]);
    s.fx.set(r, &.{ .wrap = true, .lines = .center });
    s.run(200, 200);
    try testing.expectEqualSlices(f32, &.{ 22.5, 47.5 }, t.c.pos[1][r + 1 ..][0..2]);
}

test "wrap: when everything fits on one line the rects are those of a row that does not wrap" {
    var a: Scene = .{};
    var b: Scene = .{};
    inline for (.{ &a, &b }, .{ true, false }) |s, wraps_| {
        const t = s.init();
        const root = t.push(0, .none, &.{ .size = .{ .px(300), .px(200) }, .pad = @splat(6) });
        const r = t.push(root, .none, &.{ .dir = .x, .size = .{ .fill, .fit }, .gap = 3, .pad = @splat(2), .main = .center, .cross = .end });
        s.fx.set(r, &.{ .wrap = wraps_ });
        _ = t.push(r, .none, &.{ .size = .{ .px(40), .px(12) } });
        const m = t.push(r, .none, &.{ .size = .{ .px(25), .px(30) } });
        s.fx.set(m, &.{ .margin = .{ 4, 1, 2, 3 }, .cross = .center });
        _ = t.push(r, .none, &.{ .size = .{ .px(60), .px(7) } });
        t.seal(r);
    }
    a.run(300, 200);
    b.run(300, 200);
    inline for (0..4) |k| try testing.expectEqualSlices(f32, b.t.c.rect[k][0..b.t.len], a.t.c.rect[k][0..a.t.len]);
    try testing.expectEqual(1, a.fx.c.nlines[1]);
}

test "wrap: a child per line uses one line per child and never reaches the sink" {
    var s: Scene = .{};
    const t = s.init();
    const root = t.push(0, .none, &.{ .dir = .x, .size = .{ .px(10), .fit } });
    s.fx.set(root, &.{ .wrap = true });
    for (1..s.t.cap) |_| _ = t.push(root, .none, &.{ .size = .{ .px(8), .px(2) } });
    s.run(10, 1000);
    const n = s.t.len - 1;
    try testing.expectEqual(@as(f32, @floatFromInt(n)), s.fx.c.nlines[root]);
    for (s.fx.c.line[1..s.t.len], 0..) |l, k| try testing.expectEqual(@as(u32, @intCast(k)), l);
    try testing.expect(s.fx.sink() > n);
    // Lines stack with no gap: child k at y = 2k; the row's natural height is 2n (the root
    // itself always takes the viewport).
    for (1..s.t.len) |k| try testing.expectEqual(@as(f32, @floatFromInt(2 * (k - 1))), s.t.c.pos[1][k]);
    try testing.expectEqual(@as(f32, @floatFromInt(2 * n)), s.t.c.nat[1][root]);
}

test "wrap: a tag cloud in a column, end to end through finalize" {
    var s: Scene = .{};
    const t = s.init();
    const root = t.push(0, .none, &.{ .size = .{ .px(120), .px(200) }, .pad = @splat(10), .gap = 6 });
    const title = t.push(root, .none, &.{ .size = .{ .fill, .px(20) } });
    const tags = t.push(root, .none, &.{ .dir = .x, .size = .{ .fill, .fit }, .gap = 4, .main = .center });
    s.fx.set(tags, &.{ .wrap = true });
    var tag: [5]u32 = undefined;
    for (&tag, [5]f32{ 30, 50, 20, 60, 40 }) |*row, w| row.* = t.push(tags, .none, &.{ .size = .{ .px(w), .px(16) } });
    t.seal(tags);
    const foot = t.push(root, .none, &.{ .size = .{ .fill, .px(10) } });
    s.run(120, 200);
    // inner 100: [30 50] = 84 | [20 60] = 84 | [40]; each line centred, 8 px lead on the first two.
    try testing.expectEqualSlices(u32, &.{ 0, 0, 1, 1, 2 }, s.lineOf(tag[0], 5));
    const R = @import("../core/types.zig").Rect;
    try testing.expectEqual(R{ .x0 = 10, .y0 = 10, .x1 = 110, .y1 = 30 }, t.rect(title));
    try testing.expectEqual(R{ .x0 = 10, .y0 = 36, .x1 = 110, .y1 = 92 }, t.rect(tags));
    try testing.expectEqual(R{ .x0 = 18, .y0 = 36, .x1 = 48, .y1 = 52 }, t.rect(tag[0]));
    try testing.expectEqual(R{ .x0 = 52, .y0 = 36, .x1 = 102, .y1 = 52 }, t.rect(tag[1]));
    try testing.expectEqual(R{ .x0 = 18, .y0 = 56, .x1 = 38, .y1 = 72 }, t.rect(tag[2]));
    try testing.expectEqual(R{ .x0 = 42, .y0 = 56, .x1 = 102, .y1 = 72 }, t.rect(tag[3]));
    try testing.expectEqual(R{ .x0 = 40, .y0 = 76, .x1 = 80, .y1 = 92 }, t.rect(tag[4]));
    // The footer follows the three 16 px lines and their two 4 px gaps.
    try testing.expectEqual(R{ .x0 = 10, .y0 = 98, .x1 = 110, .y1 = 108 }, t.rect(foot));
}

test "line_space: between, around and evenly share a wrapping row's spare height; stretch grows its lines" {
    var s: Scene = .{};
    const t = s.init();
    const root = t.push(0, .none, &.{ .dir = .x, .size = .{ .px(400), .px(200) } });
    const kinds = [_]Flex.LineSpace{ .between, .around, .evenly };
    var rows: [3]u32 = undefined;
    for (&rows, kinds) |*r, k| {
        // One 60 px box per line in 100: three lines of 10 leave 70 of 100.
        r.* = s.row(root, &.{ .dir = .x, .size = .{ .px(100), .px(100) } }, &.{ .{ 60, 10 }, .{ 60, 10 }, .{ 60, 10 } });
        s.fx.set(r.*, &.{ .wrap = true, .line_space = k });
    }
    const st = t.push(root, .none, &.{ .dir = .x, .size = .{ .px(100), .px(100) } });
    const a = t.push(st, .none, &.{ .size = .{ .px(60), .fill }, .min = .{ 0, 10 } });
    const b = t.push(st, .none, &.{ .size = .{ .px(60), .px(10) } });
    t.seal(st);
    s.fx.set(st, &.{ .wrap = true, .line_space = .stretch });
    s.run(400, 200);
    const want = [3][3]f32{ .{ 0, 45, 90 }, .{ 70.0 / 6.0, 10 + 70.0 / 2.0, 20 + 70.0 * 5.0 / 6.0 }, .{ 17.5, 45, 72.5 } };
    for (rows, want) |r, ys| for (0..3) |k| try testing.expectApproxEqAbs(ys[k], t.c.pos[1][r + 1 + k], 1e-4);
    // Stretch: two lines of 10 leave 80, 40 each; the filling box takes its line's 50.
    try testing.expectEqual(50, t.c.size[1][a]);
    try testing.expectEqual(50, t.c.pos[1][b]);
}
