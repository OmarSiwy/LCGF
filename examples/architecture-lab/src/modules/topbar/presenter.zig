//! Project app summaries into a compact view value; borrow no mutable domain data.

const entity = @import("entity.zig");
const Page = @import("../../core/navigation.zig").Page;

pub const Model = struct {
    page: Page,
    dark: bool,
    total: u32,
    completed: u32,
};

pub fn make(state: *const entity.State, page: Page, total: u32, completed: u32) Model {
    return .{ .page = page, .dark = state.dark, .total = total, .completed = completed };
}
