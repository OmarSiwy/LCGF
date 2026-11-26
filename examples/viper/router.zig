//! VIPER router: owns navigation, the page shown. Only the presenter asks it to move.
const Page = @import("entity.zig").Page;

pub const Router = struct {
    page: Page = .all,

    pub fn show(r: *Router, page: Page) void {
        r.page = page;
    }
};
