//! expect: tools/lcgf-gen/markup/testdata/mixer/page.html:7:77: handler 'mute_changed' must be `pub fn mute_changed(h: *H, ui: *Ui, value: bool) void`
const page = @import("mixer");

const H = struct {
    pub fn mute_changed(_: *H, _: *page.Ui, _: f32) void {}
    pub fn volume_changed(_: *H, _: *page.Ui, _: f32) void {}
};

comptime {
    _ = page.Page(H);
}
