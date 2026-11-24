//! Cross-module navigation is data. The application shell owns the selected page and
//! interprets these requests; leaf modules never hold pointers to one another.

pub const Page = enum {
    all,
    running,
    completed,

    pub fn title(self: Page) []const u8 {
        return switch (self) {
            .all => "All items",
            .running => "Running",
            .completed => "Completed",
        };
    }
};

/// A small, exhaustive command vocabulary shared at module boundaries. Business data
/// remains in its owning module; navigation carries a value rather than a callback.
pub const Request = union(enum) {
    navigate: Page,
    advance: void,
    toggle_sidebar: void,
};
