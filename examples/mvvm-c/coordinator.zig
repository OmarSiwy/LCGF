//! The coordinator owns application flow: the page shown. Only it changes the page, and it
//! knows nothing of frames, widgets or the model.
const Page = @import("model.zig").Page;

pub const Coordinator = struct {
    page: Page = .all,

    pub fn show(c: *Coordinator, page: Page) void {
        c.page = page;
    }
};
