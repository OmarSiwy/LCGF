//! expect: col > col[1]: content needs 128 px along y, the node is 100 px and does not clip
const s = @import("lcgf").spec;

// Two 60 px rows and a 4 px pad on each side do not fit a 100 px column; the whole UI would
// fit the viewport, so the error is at the column, not the root.
const item = s.row(.{ .size = .{ .fill, .px(60) } }, .{});

comptime {
    @import("lcgf").validate.check(struct {}, s.col(.{}, .{
        s.row(.{}, .{}),
        s.col(.{ .size = .{ .px(100), .px(100) }, .pad = @splat(4) }, .{ item, item }),
    }), .{ .viewport = .{ 320, 240 } });
}
