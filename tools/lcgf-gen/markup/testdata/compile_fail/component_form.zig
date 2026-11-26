//! expect: page.html:18:5: <sfy-tool> is used inside lcgf-each, so its namespace needs `pub fn frame(f: *lcgf.frame.Frame, th: *const lcgf.widgets_base.Theme, props: anytype) …`
const page = @import("components_wrong");

const H = struct {
    pub fn save(_: *H, _: *page.Ui) void {}
    pub fn zoom(_: *H, _: *page.Ui) void {}
    pub fn pick(_: *H, _: *page.Ui, _: u32) void {}
    pub fn row_zoom(_: *H, _: *page.Ui, _: u32) void {}
};

const Net = struct { name: []const u8 };

fn probe(p: *page.Page(H), h: *H, in: *const @import("lcgf").input.Input) void {
    _ = p.frame(h, in, .{ .nets = @as([]const Net, &.{}) });
}

comptime {
    _ = &probe;
}
