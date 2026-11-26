//! expect: handler 'toggled' must be `pub fn toggled(h: *H, ui: *Ui, index: u32, value: bool) void`
const page = @import("intents");

const H = struct {
    pub fn toggled(_: *H, _: *page.Ui, _: u32, _: f32) void {}
    pub fn leveled(_: *H, _: *page.Ui, _: u32, _: f32) void {}
};

comptime {
    _ = page.Page(H);
}
