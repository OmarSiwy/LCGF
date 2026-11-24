//! Sidebar-owned state and its typed user intentions. Navigation belongs to the app.

const Page = @import("../../core/navigation.zig").Page;

pub const State = struct {
    collapsed: bool = false,
};

pub const Action = union(enum) {
    navigate: Page,
    toggle: void,
};
