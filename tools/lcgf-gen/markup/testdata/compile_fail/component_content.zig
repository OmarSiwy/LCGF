//! expect: page.html:19:5: <sfy-chip> has content inside lcgf-each, so it is a namespace with `pub fn open(f: *lcgf.frame.Frame, th: *const lcgf.widgets_base.Theme, props: anytype) …` and `pub fn close(f: *lcgf.frame.Frame, th: *const lcgf.widgets_base.Theme) void`, which build what goes before and after it
const page = @import("components_chip");

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
