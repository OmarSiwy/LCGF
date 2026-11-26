//! expect: tools/lcgf-gen/markup/testdata/counter/page.html:10:32: handler 'inc' is missing: add `pub fn inc(h: *missing_handler.H, ui: *Ui) void`
const page = @import("counter");

const H = struct {
    pub fn dec(_: *H, _: *page.Ui) void {}
};

comptime {
    _ = page.Page(H);
}
