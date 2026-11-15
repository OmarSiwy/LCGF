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

const testing = std.testing;

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
