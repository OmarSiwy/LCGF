//! expect: tools/lcgf-gen/markup/testdata/counter/page.html:9:32: handler 'dec' must be `pub fn dec(h: *H, ui: *Ui) void`
const page = @import("counter");

const H = struct {
    pub fn dec(_: *H, _: *page.Ui, _: u32) void {}
    pub fn inc(_: *H, _: *page.Ui) void {}
};

comptime {
    _ = page.Page(H);
}
