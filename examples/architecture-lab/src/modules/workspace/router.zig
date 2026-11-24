//! A routing seam is explicit even when this module has only local actions.
//! Add a navigation.Request here when a future workspace action opens a different
//! page. The application shell executes it; the view never imports another module.

const entity = @import("entity.zig");
const navigation = @import("../../core/navigation.zig");

pub fn route(action: entity.Action) ?navigation.Request {
    return switch (action) {
        .select, .scroll, .advance, .reset_scroll => null,
    };
}
