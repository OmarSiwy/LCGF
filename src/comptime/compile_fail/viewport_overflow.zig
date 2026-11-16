//! expect: row: needs at least 616x40 px, the viewport is 480x272
const s = @import("lcgr").spec;

// Three 200 px buttons, two 8 px gaps: 616 px on a 480x272 display.
const button = s.col(.{ .size = .{ .px(200), .px(40) } }, .{});

comptime {
    @import("lcgr").validate.check(struct {}, s.row(.{ .gap = 8 }, .{ button, button, button }), .{ .viewport = .{ 480, 272 } });
}
