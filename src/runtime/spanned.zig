//! spanned: the text leaves of a frame drawn in several styles (`Frame.textSpans`). Tier 1.
//!
//! A paragraph with bold, italic and code in it is one text leaf and a list of
//! `protocol.Span`s: from byte `start` of its text on, another `TextStyle` (size, colour,
//! font). The core lays such runs out as `protocol.Styled` rows: `MonoParagraphs` for the
//! bundled font, `Frame.endTextStyled` for a shaper. A frame collects them here, in rows the
//! host carved once (`init`) and handed to the context (`Context.enableSpans`); the host ends
//! the frame with `styled`. A frame past `rows` draws the rest in their base style.

const std = @import("std");
const mem = @import("../core/mem.zig");
const protocol = @import("../text/protocol.zig");
const Paragraph = @import("../text/layout/stack.zig").Paragraph;

pub const Spanned = struct {
    /// Per styled leaf: its row of `Texts`, its row of `table` and `spans` (itself).
    rows: []u32,
    styles: []u16,
    table: []Paragraph,
    spans: [][]const protocol.Span,
    len: u32 = 0,
    /// A leaf with spans did not fit: drawn in its base style.
    overflow: bool = false,

    pub fn requiredBytes(n: u32) usize {
        var counter: mem.Carver = .{ .buf = null };
        _ = init(&counter, n);
        return counter.off;
    }

    pub fn init(carver: *mem.Carver, n: u32) Spanned {
        std.debug.assert(n > 0);
        std.debug.assert(n <= std.math.maxInt(u16));
        return .{
            .rows = carver.slice(u32, n),
            .styles = carver.slice(u16, n),
            .table = carver.slice(Paragraph, n),
            .spans = carver.slice([]const protocol.Span, n),
        };
    }

    /// Text row `row` takes `spans` over its base style; false when there is no room.
    pub fn add(s: *Spanned, row: u32, spans: []const protocol.Span) bool {
        std.debug.assert(s.len == 0 or s.rows[s.len - 1] < row);
        if (s.len == s.rows.len) {
            s.overflow = true;
            return false;
        }
        const i = s.len;
        s.rows[i] = row;
        s.styles[i] = @intCast(i);
        s.table[i] = .{};
        s.spans[i] = spans;
        s.len += 1;
        return true;
    }

    /// The frame's styled runs, every one with the paragraph `p` (the host's default).
    pub fn styled(s: *Spanned, p: Paragraph) protocol.Styled {
        std.debug.assert(s.len <= s.rows.len);
        @memset(s.table[0..s.len], p);
        return .{
            .rows = s.rows[0..s.len],
            .styles = s.styles[0..s.len],
            .table = s.table[0..s.len],
            .spans = s.spans[0..s.len],
        };
    }

    /// The bundled font over the frame's styled runs (`Frame.endParagraphs`, and its `quads`).
    pub fn mono(s: *Spanned) protocol.MonoParagraphs {
        const st = s.styled(.{});
        return .{ .rows = st.rows, .styles = st.styles, .table = st.table, .spans = st.spans };
    }
};

test "add: rows in order, one table row each; past the rows, the base style" {
    var buf: [Spanned.requiredBytes(2)]u8 align(mem.column_align) = undefined;
    var carver: mem.Carver = .{ .buf = &buf };
    var s = Spanned.init(&carver, 2);
    const bold = [_]protocol.Span{.{ .start = 2, .style = .{ .px = 20 } }};
    try std.testing.expect(s.add(1, &bold));
    try std.testing.expect(s.add(4, &.{}));
    try std.testing.expect(!s.add(5, &bold));
    try std.testing.expect(s.overflow);
    const st = s.styled(.{});
    try std.testing.expectEqualSlices(u32, &.{ 1, 4 }, st.rows);
    try std.testing.expectEqualSlices(u16, &.{ 0, 1 }, st.styles);
    try std.testing.expectEqual(@as(usize, 1), st.spans[0].len);
}
