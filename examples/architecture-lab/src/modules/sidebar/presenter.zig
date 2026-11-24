//! A small read-only projection: the view receives values, never the app owner.

const entity = @import("entity.zig");
const Page = @import("../../core/navigation.zig").Page;

pub const Model = struct {
    collapsed: bool,
    page: Page,
};

pub fn make(state: *const entity.State, page: Page) Model {
    return .{ .collapsed = state.collapsed, .page = page };
}
